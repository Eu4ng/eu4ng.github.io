#!/usr/bin/env python3
"""조립 PC(NVIDIA GPU)를 LLM 수요가 충분할 때만 WOL 로 켜고, 수요가 줄면 PC 에이전트에 내려도 된다고 알린다.

PC 는 사용자 데스크톱이라 유휴 전력(약 110W)이 크다. 그래서 꺼져 있을 때는 다음 때만 켠다:
  - 30B 급 요청(라우터 backend big)이 새로 오거나 PC 로 옮길 수 있는 30B 요청이 있을 때(클라이언트 무관)
  - 보통 모델의 동시 요청(처리 중 + 대기 + 클라이언트 신고)이 2개 이상인 상태가 60초 이어질 때
자동으로 켠 부팅에서, 옮길 수 있는 30B 요청이 없고 보통 동시 요청이 1 이하인 상태가 5분 이어지면 `/release` 를 보낸다.
PC 에이전트(windows-agent.ps1 -AutoPower)는 새 요청을 받지 않고(drain), 처리 중인 일이 끝나고 아무도 로그인하지
않았을 때만 스스로 종료한다. 사용자가 켰거나 로그인한 부팅은 끄지 않는다 — 그 판단의 원본은 PC 에이전트다.

입력:
  - 라우터 파드 전부(종료 중 포함)의 HAProxy 통계 CSV(:8404/;csv). 롤링 업데이트 중 옛 파드가 쥔 요청도 센다.
  - 클라이언트(wiki-papers)의 수요 신고(:9112 POST/DELETE /demand). 라우터에 아직 보내지 않은 요청이다.
  - PC 에이전트 상태(:11437/status).
출력:
  - WOL 매직 패킷(hostNetwork 라 LAN 브로드캐스트가 나간다), PC 에이전트 제어(:11438 /auto·/release·/hint)
  - 지표(:9111/metrics), 판단 기록(stdout JSON 한 줄씩)
WOL 을 보낸 시각은 ConfigMap 에 남긴다(재시작해도 '내가 켠 부팅'을 확정할 수 있게). 자동 켜짐 표시는 PC 에이전트가 가진다.
"""

from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import logging
import os
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
MAX_REPORTS = 32
REPORT_TTL = 60.0  # 신고 하나의 최대 수명(초). 클라이언트는 15초마다 갱신한다
HANDOFF_SECONDS = 5.0  # 해제된 신고를 켜기 판정에만 더 세는 시간(라우터 도착까지의 틈)
TOMBSTONE_SECONDS = (
    120.0  # 지운 신고 id 를 기억하는 시간(늦게 온 갱신이 되살리지 못하게)
)

log = logging.getLogger("power")


# ---- 라우터 통계


@dataclass
class Row:
    qcur: int = 0
    scur: int = 0
    slim: int = 0
    stot: int = 0
    status: str = ""
    addr: str = ""


def parse_csv(text: str) -> dict[tuple[str, str], Row]:
    """HAProxy 통계 CSV(`/;csv` 나 `show stat`)를 (backend, server) → Row 로. FRONTEND·BACKEND 줄도 담는다."""
    rows: dict[tuple[str, str], Row] = {}
    for rec in csv.DictReader(text.lstrip("# ").splitlines()):
        px, sv = rec.get("pxname") or "", rec.get("svname") or ""
        if not px or not sv:
            continue
        rows[(px, sv)] = Row(
            qcur=int(rec.get("qcur") or 0),
            scur=int(rec.get("scur") or 0),
            slim=int(rec.get("slim") or 0),
            stot=int(rec.get("stot") or 0),
            status=rec.get("status") or "",
            addr=rec.get("addr") or "",
        )
    return rows


@dataclass
class Load:
    """모든 라우터 파드를 합친 부하."""

    big_qcur: int = 0
    big_active: int = 0
    servers_qcur: int = 0
    servers_active: int = 0
    pc_big_active: int = 0
    pc_servers_active: int = 0
    pc_big_up: bool = False  # 어느 파드에서든 PC 가 big 에서 UP(drain 아님)
    big_new: int = 0  # 지난 판정 뒤 big 에 새로 온 요청 수(stot 증가)


class StotTracker:
    """라우터 파드별 big backend 누적 요청 수(stot)로 새 30B 요청을 센다.

    - 컨트롤러가 뜬 뒤 생긴 파드는 기준 0 에서 센다(새 라우터의 첫 요청도 놓치지 않는다).
    - 컨트롤러보다 먼저 있던 파드는 이전 값을 모르므로, 첫 관측 때 big 에 처리 중·대기 요청이 있으면 1건으로 친다.
    - 값이 줄면(같은 이름으로 HAProxy 가 다시 시작) 기준을 그 값으로 다시 잡는다.
    """

    def __init__(self) -> None:
        self.base: dict[str, int] = {}
        self.preexisting: set[str] | None = None

    def update(self, per_pod: dict[str, dict[tuple[str, str], Row]]) -> int:
        """이번에 새로 온 big 요청 수."""
        first_round = self.preexisting is None
        if first_round:
            self.preexisting = set(per_pod)
        new = 0
        for pod, rows in per_pod.items():
            backend = rows.get(("big", "BACKEND"), Row())
            if pod not in self.base:
                if pod in self.preexisting:
                    new += 1 if backend.scur + backend.qcur > 0 else 0
                    self.base[pod] = backend.stot
                    continue
                self.base[pod] = 0
            prev = self.base[pod]
            if backend.stot < prev:
                prev = 0
            new += backend.stot - prev
            self.base[pod] = backend.stot
        for gone in set(self.base) - set(per_pod):
            del self.base[gone]
        return new


def aggregate(per_pod: dict[str, dict[tuple[str, str], Row]], pc: str) -> Load:
    """파드별 통계를 합친다(big_new 는 StotTracker 가 채운다)."""
    load = Load()
    for rows in per_pod.values():
        for (px, sv), row in rows.items():
            if sv == "FRONTEND":
                continue
            if sv == "BACKEND":
                if px == "big":
                    load.big_qcur += row.qcur
                elif px == "servers":
                    load.servers_qcur += row.qcur
                continue
            if px == "big":
                load.big_active += row.scur
                if sv == pc:
                    load.pc_big_active += row.scur
                    load.pc_big_up |= row.status == "UP"
            elif px == "servers":
                load.servers_active += row.scur
                if sv == pc:
                    load.pc_servers_active += row.scur
    return load


# ---- 클라이언트 수요 신고


class Reports:
    """라우터에 아직 보내지 않은 요청의 신고. 스레드 안전."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.live: dict[str, tuple[str, float]] = {}  # id → (backend, 만료 시각)
        self.handoff: dict[str, tuple[str, float]] = {}  # 해제됨, 켜기 판정에만 센다
        self.tombstones: dict[str, float] = {}

    def _expire(self, now: float) -> None:
        self.live = {k: v for k, v in self.live.items() if v[1] > now}
        self.handoff = {k: v for k, v in self.handoff.items() if v[1] > now}
        self.tombstones = {k: t for k, t in self.tombstones.items() if t > now}

    def put(self, rid: str, backend: str, now: float) -> bool:
        """신고하거나 갱신한다. 지운 id 이거나 상한을 넘으면 False."""
        with self.lock:
            self._expire(now)
            if rid in self.tombstones:
                return False
            if rid not in self.live and len(self.live) >= MAX_REPORTS:
                return False
            self.live[rid] = (backend, now + REPORT_TTL)
            return True

    def delete(self, rid: str, now: float) -> None:
        """해제한다. 켜기 판정에는 HANDOFF_SECONDS 동안 더 센다."""
        with self.lock:
            self._expire(now)
            item = self.live.pop(rid, None)
            if item is not None:
                self.handoff[rid] = (item[0], now + HANDOFF_SECONDS)
            self.tombstones[rid] = now + TOMBSTONE_SECONDS

    def count(self, backend: str, now: float, *, handoff: bool) -> int:
        with self.lock:
            self._expire(now)
            n = sum(1 for b, _ in self.live.values() if b == backend)
            if handoff:
                n += sum(1 for b, _ in self.handoff.values() if b == backend)
            return n


# ---- 판단


@dataclass
class Config:
    wake_seconds: float = 60.0
    release_seconds: float = 300.0
    cooldown_seconds: float = 600.0
    boot_timeout: float = 300.0
    wol_retry_seconds: float = 60.0
    wol_retries: int = 3
    boot_window_before: float = 30.0
    boot_window_after: float = 150.0  # 실측 WOL→부팅 지연 + 여유. 1단계 실측으로 맞춘다
    agent_off_seconds: float = 60.0
    # PC 가 30B(backend big)를 받는가. RTX 4080(16GB)은 30B 가중치가 VRAM 을 넘어 절반이 CPU 로 가고 생성이 780m 보다
    # 느리다(2026-10-08 실측: qwen3.8:27b 생성 1.87 tok/s, 780m 5.0). 그래서 기본은 받지 않는다 — 30B 요청은 PC 를 켜지도,
    # 켜 둔 채 붙잡지도 않고, 신고 응답도 "n/a" 라 클라이언트가 PC 를 기다리지 않는다.
    serve_big: bool = False


@dataclass
class Brain:
    """판단만 한다(입출력 없음). tick·on_demand 가 할 일을 돌려준다."""

    cfg: Config = field(default_factory=Config)
    wol_sent_at: float | None = None  # 벽시계(epoch). ConfigMap 에 남긴다
    wol_attempts: int = 0
    last_wol_try: float = 0.0
    agent: dict | None = None
    agent_seen_at: float = 0.0
    wake_since: float | None = None
    keep_low_since: float | None = None
    last_load: Load = field(default_factory=Load)
    last_counts: dict[str, int] = field(default_factory=dict)

    # 상태

    def pc_on(self, now: float) -> bool:
        return (
            self.agent is not None
            and now - self.agent_seen_at < self.cfg.agent_off_seconds
        )

    def waking(self, now: float) -> bool:
        return (
            not self.pc_on(now)
            and self.wol_sent_at is not None
            and now - self.wol_sent_at < self.cfg.boot_timeout
        )

    def auto_boot(self) -> bool:
        return bool(self.agent and self.agent.get("auto_boot"))

    def released(self) -> bool:
        return bool(self.agent and self.agent.get("released"))

    def state(self, now: float) -> str:
        if self.waking(now):
            return "waking"
        if not self.pc_on(now):
            return "off"
        if not self.auto_boot():
            return "user"
        return "released" if self.released() else "auto"

    def cooled(self, now: float) -> bool:
        return (
            self.wol_sent_at is None
            or now - self.wol_sent_at >= self.cfg.cooldown_seconds
        )

    # 입력

    def see_agent(self, status: dict | None, now: float) -> None:
        if status is not None:
            self.agent = status
            self.agent_seen_at = now

    def _wol(self, now: float) -> list[tuple]:
        self.wol_sent_at = now
        self.wol_attempts = 1
        self.last_wol_try = now
        return [("save", now), ("wol",)]

    def _boot_is_mine(self) -> bool:
        if self.wol_sent_at is None or not self.agent:
            return False
        boot = self.agent.get("boot_id")
        if not isinstance(boot, (int, float)):
            return False
        return (
            self.wol_sent_at - self.cfg.boot_window_before
            <= boot
            <= self.wol_sent_at + self.cfg.boot_window_after
        ) and not self.agent.get("user_seen")

    def on_demand(
        self, backend: str, now: float, counts: dict[str, int]
    ) -> tuple[str, list[tuple]]:
        """신고를 받은 순간의 판단. 30B 신고는 바로 켜거나 되살린다. (응답 상태, 할 일)."""
        actions: list[tuple] = []
        if backend == "big" and not self.cfg.serve_big:
            return "n/a", actions
        if backend == "big":
            if not self.pc_on(now) and not self.waking(now) and self.cooled(now):
                actions += self._wol(now)
            elif self.pc_on(now) and self.auto_boot() and self.released():
                actions.append(("auto", self.agent.get("boot_id")))
                return "resuming", actions
        state = self.state(now)
        if state == "waking":
            return "waking", actions
        if (
            state in {"auto", "released"}
            and backend == "big"
            and not self.last_load.pc_big_up
        ):
            return "resuming", actions
        return ("off" if state == "off" else "on"), actions

    def tick(self, load: Load, counts: dict[str, int], now: float) -> list[tuple]:
        """주기 판단. counts: big·servers 의 살아 있는 신고, servers_handoff."""
        self.last_load = load
        self.last_counts = counts
        actions: list[tuple] = []
        big_movable = load.big_qcur + counts.get("big", 0) + load.pc_big_active
        if not self.cfg.serve_big:
            big_movable = 0
        normal_keep = load.servers_active + load.servers_qcur + counts.get("servers", 0)
        normal_wake = normal_keep + counts.get("servers_handoff", 0)
        big_wake = big_movable > 0 or (self.cfg.serve_big and load.big_new > 0)

        if normal_wake >= 2:
            self.wake_since = self.wake_since if self.wake_since is not None else now
        else:
            self.wake_since = None
        normal_wake_ok = (
            self.wake_since is not None
            and now - self.wake_since >= self.cfg.wake_seconds
        )
        want = big_wake or normal_wake_ok

        on = self.pc_on(now)
        if not on:
            if self.waking(now):
                if (
                    self.wol_attempts <= self.cfg.wol_retries
                    and now - self.last_wol_try >= self.cfg.wol_retry_seconds
                ):
                    self.wol_attempts += 1
                    self.last_wol_try = now
                    actions.append(("wol",))
            elif want and self.cooled(now):
                actions += self._wol(now)
            self.keep_low_since = None
            return actions

        # 켜져 있다: 내가 켠 부팅인지 확정
        if not self.auto_boot() and self._boot_is_mine():
            actions.append(("auto", self.agent.get("boot_id")))
        if self.auto_boot():
            if big_movable == 0 and normal_keep <= 1:
                self.keep_low_since = (
                    self.keep_low_since if self.keep_low_since is not None else now
                )
            else:
                self.keep_low_since = None
            if self.released():
                if want:
                    actions.append(("auto", self.agent.get("boot_id")))
            elif (
                self.keep_low_since is not None
                and now - self.keep_low_since >= self.cfg.release_seconds
            ):
                actions.append(("release", self.agent.get("boot_id")))
        if now - self.agent_seen_at > 15:
            return actions  # 방금 응답이 없던 PC 에는 힌트를 보내지 않는다(꺼지는 중)
        actions.append(
            (
                "hint",
                {
                    "big_pending": load.big_qcur + counts.get("big", 0) > 0,
                    "pc_big_active": load.pc_big_active,
                    "pc_servers_active": load.pc_servers_active,
                },
            )
        )
        return actions


# ---- 바깥 세계


def magic_packet(mac: str) -> bytes:
    """WOL 매직 패킷: FF×6 + MAC×16."""
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError(f"MAC 주소가 아니다: {mac}")
    return b"\xff" * 6 + raw * 16


def send_wol(mac: str, targets: list[str]) -> None:
    packet = magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for target in targets:
            host, _, port = target.rpartition(":")
            sock.sendto(packet, (host, int(port)))


class Kube:
    """서비스 어카운트로 쿠버네티스 API 를 부른다(표준 라이브러리만)."""

    def __init__(self, namespace: str) -> None:
        self.ns = namespace
        self.base = "https://kubernetes.default.svc"
        with open(f"{SA_DIR}/token") as fh:
            self.token = fh.read().strip()
        self.ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")

    def call(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        ctype: str = "application/json",
    ) -> dict:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            req.add_header("Content-Type", ctype)
        with urllib.request.urlopen(req, context=self.ctx, timeout=10) as resp:
            return json.load(resp)

    def router_pods(self, selector: str) -> dict[str, str]:
        """라벨이 맞는 파드 이름 → IP(종료 중 포함, IP 없는 것 제외)."""
        q = urllib.request.quote(selector)
        items = self.call(
            "GET", f"/api/v1/namespaces/{self.ns}/pods?labelSelector={q}"
        )["items"]
        return {
            p["metadata"]["name"]: p["status"]["podIP"]
            for p in items
            if p.get("status", {}).get("podIP")
        }

    def load_state(self, name: str) -> float | None:
        try:
            cm = self.call("GET", f"/api/v1/namespaces/{self.ns}/configmaps/{name}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        value = (cm.get("data") or {}).get("wol_sent_at")
        return float(value) if value else None

    def save_state(self, name: str, wol_sent_at: float) -> None:
        data = {"wol_sent_at": f"{wol_sent_at:.0f}"}
        try:
            self.call(
                "PATCH",
                f"/api/v1/namespaces/{self.ns}/configmaps/{name}",
                {"data": data},
                "application/merge-patch+json",
            )
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            self.call(
                "POST",
                f"/api/v1/namespaces/{self.ns}/configmaps",
                {"metadata": {"name": name}, "data": data},
            )


def http_get(url: str, timeout: float = 5.0) -> bytes:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def agent_post(base: str, path: str, token: str, body: dict) -> int:
    req = urllib.request.Request(
        base + path, data=json.dumps(body).encode(), method="POST"
    )
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


def missing_models(tags: dict, wanted: list[str]) -> list[str]:
    """`/api/tags` 응답에 없는 모델."""
    have = set()
    for m in tags.get("models", []):
        for key in ("name", "model"):
            if m.get(key):
                have.add(m[key])
                have.add(m[key].removesuffix(":latest"))
    return [w for w in wanted if w not in have]


def allowed(addr: str, networks: list[ipaddress.IPv4Network]) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in net for net in networks)


# ---- 지표


class Metrics:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.wakes: dict[str, int] = {}
        self.state = "off"
        self.demand: dict[str, int] = {}
        self.reports = 0
        self.missing: dict[tuple[str, str], int] = {}

    def render(self) -> str:
        with self.lock:
            lines = [
                "# HELP gpu_pc_wake_total WOL 시도 수(결과별)",
                "# TYPE gpu_pc_wake_total counter",
            ]
            lines += [
                f'gpu_pc_wake_total{{result="{k}"}} {v}'
                for k, v in sorted(self.wakes.items())
            ]
            lines += [
                "# HELP gpu_pc_state 조립 PC 상태(값이 1인 state)",
                "# TYPE gpu_pc_state gauge",
            ]
            for s in ("off", "waking", "auto", "released", "user"):
                lines.append(
                    f'gpu_pc_state{{state="{s}"}} {1 if self.state == s else 0}'
                )
            lines += [
                "# HELP gpu_pc_demand 판정에 쓴 수요",
                "# TYPE gpu_pc_demand gauge",
            ]
            lines += [
                f'gpu_pc_demand{{kind="{k}"}} {v}'
                for k, v in sorted(self.demand.items())
            ]
            lines += [
                "# HELP gpu_pc_demand_reports 살아 있는 클라이언트 신고 수",
                "# TYPE gpu_pc_demand_reports gauge",
                f"gpu_pc_demand_reports {self.reports}",
                "# HELP ollama_meta_missing_models meta 서버에 없는 라우터 모델(1 이면 없음)",
                "# TYPE ollama_meta_missing_models gauge",
            ]
            lines += [
                f'ollama_meta_missing_models{{server="{s}",model="{m}"}} {v}'
                for (s, m), v in sorted(self.missing.items())
            ]
            return "\n".join(lines) + "\n"


# ---- 실행


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="조립 PC 를 LLM 수요가 충분할 때만 WOL 로 켜고, 수요가 줄면 PC 에이전트에 내려도 된다고 알린다.",
        epilog=(
            "예:\n"
            "  python3 power.py --mac [GPUPC_MAC] --agent-host [GPUPC_IP] --pc-server pc-custom \\\n"
            "      --models gemma4:12b,qwen3.5:9b --meta-servers pve02-780m,pve01-610m\n"
            "  python3 power.py --mac [GPUPC_MAC] --agent-host [GPUPC_IP] --once --dry-run \\\n"
            "      --stats-url http://ollama.ollama.svc:8404/\\;csv   # 한 번 판단만 출력\n\n"
            "환경 변수: GPU_PC_CONTROL_TOKEN(PC 에이전트 제어), GPU_PC_DEMAND_TOKEN(수요 신고 인증)\n"
            '출력: 판단마다 stdout 에 JSON 한 줄 {"state", "load", "counts", "actions"}\n'
            "exit code: 0 정상 종료(--once), 1 통계를 못 읽음(--once), 2 필요한 값 없음"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--mac", required=True, help="PC 의 MAC 주소(WOL)")
    parser.add_argument(
        "--wol-target",
        action="append",
        default=None,
        help="매직 패킷 목적지 host:port (여러 번, 기본 255.255.255.255:9). 서브넷 브로드캐스트(예: 192.168.1.255:9)를 더하면 확실하다",
    )
    parser.add_argument("--agent-host", required=True, help="PC 주소")
    parser.add_argument(
        "--status-port", type=int, default=11437, help="PC 에이전트 상태 포트"
    )
    parser.add_argument(
        "--control-port", type=int, default=11438, help="PC 에이전트 제어 포트"
    )
    parser.add_argument(
        "--pc-server", default="pc-custom", help="haproxy.cfg 에서 PC 서버 이름"
    )
    parser.add_argument("--namespace", default="ollama")
    parser.add_argument(
        "--router-selector", default="app=ollama-router", help="라우터 파드 라벨"
    )
    parser.add_argument(
        "--stats-url",
        default=None,
        help="파드 목록 대신 이 통계 주소 하나만 읽는다(시험용, 쿠버네티스 API 를 쓰지 않음)",
    )
    parser.add_argument("--state-configmap", default="gpu-pc-power-state")
    parser.add_argument(
        "--models", default="", help="meta 서버가 모두 가져야 할 모델(쉼표)"
    )
    parser.add_argument(
        "--meta-servers", default="", help="모델을 확인할 meta backend 서버 이름(쉼표)"
    )
    parser.add_argument("--interval", type=float, default=10.0, help="판단 간격(초)")
    parser.add_argument("--listen-metrics", type=int, default=9111)
    parser.add_argument("--listen-demand", type=int, default=9112)
    parser.add_argument(
        "--allow",
        default="10.244.0.0/16,127.0.0.1/32",
        help="수요 신고를 받을 출발지 대역(쉼표, 기본 flannel 파드 대역과 루프백)",
    )
    parser.add_argument(
        "--boot-window-after",
        type=float,
        default=150.0,
        help="WOL 뒤 이 초 안의 부팅만 내가 켠 것",
    )
    parser.add_argument(
        "--serve-big",
        action="store_true",
        help="PC 가 30B(backend big)도 받는다(켜기·붙잡기 조건에 30B 를 넣음). 기본은 보통 모델만",
    )
    parser.add_argument("--once", action="store_true", help="한 번 판단하고 끝낸다")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="WOL·제어·저장을 하지 않고 판단만 출력한다",
    )
    return parser


class Service:
    """판단과 바깥 세계를 잇는다."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.cfg = Config(
            boot_window_after=args.boot_window_after, serve_big=args.serve_big
        )
        self.brain = Brain(self.cfg)
        self.reports = Reports()
        self.metrics = Metrics()
        self.stot = StotTracker()
        self.lock = threading.Lock()
        self.control_token = os.environ.get("GPU_PC_CONTROL_TOKEN", "")
        self.demand_token = os.environ.get("GPU_PC_DEMAND_TOKEN", "")
        self.networks = [
            ipaddress.ip_network(n.strip()) for n in args.allow.split(",") if n.strip()
        ]
        self.kube = None if args.stats_url else Kube(args.namespace)
        self._stats_warned: set[str] = set()
        self.agent_base = f"http://{args.agent_host}:{args.control_port}"
        self.wol_targets = args.wol_target or ["255.255.255.255:9"]
        if self.kube and not args.dry_run:
            try:
                self.brain.wol_sent_at = self.kube.load_state(args.state_configmap)
            except (OSError, urllib.error.URLError) as exc:
                log.warning(
                    "상태 ConfigMap 을 읽지 못했다(켠 기록 없음으로 본다): %s", exc
                )

    def read_stats(self) -> dict[str, dict[tuple[str, str], Row]]:
        if self.args.stats_url:
            return {"single": parse_csv(http_get(self.args.stats_url).decode())}
        pods = self.kube.router_pods(self.args.router_selector)
        result = {}
        for name, ip in pods.items():
            try:
                result[name] = parse_csv(http_get(f"http://{ip}:8404/;csv").decode())
            except OSError as exc:
                # 종료 중인 옛 파드는 soft-stop 으로 통계 포트를 먼저 닫는다(진행 중 요청은 끝까지 간다). 파드마다 한 번만 알린다.
                # 그 파드가 쥔 요청은 셀 수 없으므로, PC 를 내리는 판단은 에이전트의 연결 수(11434 연결 0)가 마지막으로 막는다.
                if name not in self._stats_warned:
                    self._stats_warned.add(name)
                    log.warning(
                        "라우터 파드 %s 통계를 못 읽었다(종료 중이면 정상): %s",
                        name,
                        exc,
                    )
        return result

    def read_agent(self) -> dict | None:
        try:
            return json.loads(
                http_get(
                    f"http://{self.args.agent_host}:{self.args.status_port}/status", 3
                )
            )
        except (OSError, ValueError):
            return None

    def counts(self, now: float) -> dict[str, int]:
        return {
            "big": self.reports.count("big", now, handoff=False),
            "servers": self.reports.count("servers", now, handoff=False),
            "servers_handoff": self.reports.count("servers", now, handoff=True)
            - self.reports.count("servers", now, handoff=False),
        }

    def run_actions(self, actions: list[tuple]) -> None:
        for action in actions:
            kind = action[0]
            if self.args.dry_run:
                continue
            try:
                if kind == "save" and self.kube:
                    self.kube.save_state(self.args.state_configmap, action[1])
                elif kind == "wol":
                    send_wol(self.args.mac, self.wol_targets)
                    self._wake_metric("sent")
                elif kind in {"auto", "release"}:
                    code = agent_post(
                        self.agent_base,
                        f"/{kind}",
                        self.control_token,
                        {"boot_id": action[1]},
                    )
                    log.info("PC 에이전트 /%s → %s", kind, code)
                elif kind == "hint":
                    agent_post(self.agent_base, "/hint", self.control_token, action[1])
            except (OSError, urllib.error.URLError) as exc:
                log.warning("%s 실패: %s", kind, exc)

    def _wake_metric(self, result: str) -> None:
        with self.metrics.lock:
            self.metrics.wakes[result] = self.metrics.wakes.get(result, 0) + 1

    def demand(self, rid: str, backend: str) -> tuple[int, dict]:
        """POST /demand 처리."""
        now = time.time()
        if backend not in {"big", "servers"}:
            return 400, {"error": "backend 는 big 또는 servers"}
        if not self.reports.put(rid, backend, now):
            return 429, {"error": "신고가 너무 많거나 이미 지운 id"}
        with self.lock:
            state, actions = self.brain.on_demand(backend, now, self.counts(now))
            if actions:
                self.emit(now, None, actions, "demand")
                self.run_actions(actions)
        return 200, {"pc": state}

    def emit(
        self, now: float, load: Load | None, actions: list[tuple], source: str
    ) -> None:
        record = {
            "at": round(now),
            "source": source,
            "state": self.brain.state(now),
            "counts": self.counts(now),
            "actions": [a for a in actions if a[0] != "hint"],
        }
        if load is not None:
            record["load"] = load.__dict__
        print(json.dumps(record, ensure_ascii=False, default=str), flush=True)

    def tick(self) -> bool:
        now = time.time()
        try:
            per_pod = self.read_stats()
        except (OSError, urllib.error.URLError, KeyError) as exc:
            log.warning("라우터 통계를 못 읽었다: %s", exc)
            return False
        load = aggregate(per_pod, self.args.pc_server)
        load.big_new = self.stot.update(per_pod)
        agent = self.read_agent()
        with self.lock:
            self.brain.see_agent(agent, now)
            counts = self.counts(now)
            actions = self.brain.tick(load, counts, now)
            if [a for a in actions if a[0] != "hint"] or self.args.once:
                self.emit(now, load, actions, "tick")
            self.run_actions(actions)
            with self.metrics.lock:
                self.metrics.state = self.brain.state(now)
                self.metrics.reports = counts["big"] + counts["servers"]
                self.metrics.demand = {
                    "big_movable": (load.big_qcur + counts["big"] + load.pc_big_active)
                    if self.cfg.serve_big
                    else 0,
                    "normal_keep": load.servers_active
                    + load.servers_qcur
                    + counts["servers"],
                    "normal_wake": load.servers_active
                    + load.servers_qcur
                    + counts["servers"]
                    + counts["servers_handoff"],
                }
        self.check_models(per_pod)
        return True

    _models_checked = 0.0

    def check_models(self, per_pod: dict[str, dict[tuple[str, str], Row]]) -> None:
        """1분마다 meta 서버의 /api/tags 를 라우터 모델 목록과 맞댄다."""
        wanted = [m for m in self.args.models.split(",") if m]
        servers = [s for s in self.args.meta_servers.split(",") if s]
        if not wanted or not servers or time.time() - self._models_checked < 60:
            return
        self._models_checked = time.time()
        addrs = {
            sv: row.addr
            for rows in per_pod.values()
            for (px, sv), row in rows.items()
            if px == "meta"
        }
        missing: dict[tuple[str, str], int] = {}
        for server in servers:
            addr = addrs.get(server)
            if not addr:
                continue
            try:
                tags = json.loads(http_get(f"http://{addr}/api/tags"))
            except (OSError, ValueError):
                continue  # 꺼진 서버(PC)는 확인하지 않는다
            lacking = set(missing_models(tags, wanted))
            for model in wanted:
                missing[(server, model)] = 1 if model in lacking else 0
        with self.metrics.lock:
            self.metrics.missing.update(missing)


def make_handler(service: Service):
    class Handler(BaseHTTPRequestHandler):
        def _send(
            self, code: int, body: dict | str, ctype: str = "application/json"
        ) -> None:
            data = (
                body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
            ).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorized(self) -> bool:
            if not allowed(self.client_address[0], service.networks):
                self._send(403, {"error": "허용하지 않은 출발지"})
                return False
            token = service.demand_token
            if not token or self.headers.get("Authorization") != f"Bearer {token}":
                self._send(401, {"error": "토큰이 맞지 않음"})
                return False
            return True

        def do_GET(self) -> None:
            if self.path == "/metrics":
                self._send(200, service.metrics.render(), "text/plain; version=0.0.4")
            elif self.path == "/healthz":
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "없음"})

        def do_POST(self) -> None:
            if self.path != "/demand" or not self._authorized():
                if self.path != "/demand":
                    self._send(404, {"error": "없음"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                rid = str(body.get("id") or uuid.uuid4())
                code, reply = service.demand(rid, str(body.get("backend", "")))
            except (ValueError, TypeError):
                code, reply = 400, {"error": "JSON 이 아님"}
            self._send(code, reply)

        def do_DELETE(self) -> None:
            if not self.path.startswith("/demand/"):
                self._send(404, {"error": "없음"})
                return
            if not self._authorized():
                return
            service.reports.delete(self.path.removeprefix("/demand/"), time.time())
            self._send(200, {"ok": True})

        def log_message(self, fmt: str, *args) -> None:
            return

    return Handler


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(message)s")
    if not args.dry_run and not os.environ.get("GPU_PC_CONTROL_TOKEN"):
        log.error("GPU_PC_CONTROL_TOKEN 환경 변수가 필요하다(--dry-run 이 아니면)")
        return EXIT_USAGE
    service = Service(args)
    if args.once:
        return EXIT_OK if service.tick() else EXIT_FAIL
    for port in {args.listen_metrics, args.listen_demand}:
        server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info(
        "시작: PC %s(%s), 판단 %ss 마다", args.agent_host, args.pc_server, args.interval
    )
    while True:
        service.tick()
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())

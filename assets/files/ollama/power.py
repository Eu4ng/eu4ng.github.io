#!/usr/bin/env python3
"""조립 PC(NVIDIA GPU)를 LLM 수요가 충분할 때만 WOL 로 켜고, 수요가 줄면 PC 에이전트에 내려도 된다고 알린다.
워크플로가 동시에 보낼 일의 수를 정하도록 서버 등급(상시·대기)과 자리 임대(lease)도 맡는다.

PC 는 사용자 데스크톱이라 유휴 전력(약 106W)이 크다. 그래서 꺼져 있을 때는 다음 때만 켠다(보통 모델, backend servers):
  - 새 수요 구간: 전역 보통 동시 요청(처리 중 + 대기 + 클라이언트 신고)이 2건 이상인 상태가 60초 이어질 때. 한 구간에 한 번만
    (그 구간에 PC 가 켜졌던 적이 있으면 2건 미만으로 내려갔다가 다시 2건이 되어야 새 구간이다)
  - 기다리는 일(라우터 대기열 + `waiting=true` 신고)이 1건 이상인 상태가 60초 이어질 때
  - 상시 서버가 모두 꺼져 켜진 자리가 0 이면 기다리는 일이 생기는 즉시
자동으로 켠 부팅에서 PC 몫(PC 처리 중 + 기다리는 일)이 1건 이하인 상태가 2분 이어지면 `/release` 를 보낸다. release 뒤에는
그 뒤 새로 생긴 기다리는 일이 60초 이어질 때만 되살린다. 쿨다운은 WOL 이 실패했을 때(부팅 시간 초과)만 둔다.
PC 에이전트(windows-agent.ps1 -AutoPower)는 새 요청을 받지 않고(drain), 처리 중인 일이 끝나고 아무도 로그인하지
않았을 때만 스스로 종료한다. 사용자가 켰거나 로그인한 부팅은 끄지 않는다 — 그 판단의 원본은 PC 에이전트다.

서버 등급: PC(--pc-server)는 대기(standby) 서버다. 꺼져 있어도 WOL 로 깨울 수 있으면(wakeable) 그 자리(라우터 maxconn)를
용량으로 친다. 나머지는 상시(online) 서버이고, 상시인데 DOWN 이면 장애다. 자리 임대는 워크플로가 job 마다 자리 하나를
예약하는 것이다. 남은 자리 = 그 backend 서버들의 자리(켜진 상시 + 깨울 수 있는 대기) − 살아 있는 임대. 임대는 자리만
확보하고 PC 를 켜지 않는다(켜는 것은 위의 실제 수요다).

입력:
  - 라우터 파드 전부(종료 중 포함)의 HAProxy 통계 CSV(:8404/;csv). 롤링 업데이트 중 옛 파드가 쥔 요청도 센다.
  - 클라이언트(wiki-papers)의 수요 신고(:9112 POST/DELETE /demand). 라우터에 아직 보내지 않은 요청이다.
  - 워크플로의 자리 예약(:9112 POST /reserve, POST /lease/<id>/activate·renew, DELETE /lease/<id>).
  - PC 에이전트 상태(:11437/status).
출력:
  - WOL 매직 패킷(hostNetwork 라 LAN 브로드캐스트가 나간다), PC 에이전트 제어(:11438 /auto·/release·/hint)
  - 서버 등급(:9112 GET /servers), 임대 목록(GET /leases)
  - 지표(:9111/metrics), 판단 기록(stdout JSON 한 줄씩)
WOL 을 보낸 시각(부팅을 판정할 때까지)과 임대는 ConfigMap 에 남긴다(재시작해도 이어지게). 자동 켜짐 표시는 PC 에이전트가 가진다.
"""

from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import logging
import os
import secrets
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
LEASE_FRESH_TTL = (
    1800.0  # 갓 만든(job 이 아직 시작 안 한) 임대의 수명. 러너 대기를 덮는다
)
LEASE_ACTIVE_TTL = (
    300.0  # job 이 시작한 임대의 수명. 갱신(60초마다)할 때마다 다시 잡는다
)
LEASE_SAVE_SECONDS = 10.0  # 갱신은 이 간격으로 모아 저장한다
MAX_LEASES = 64
MAX_WANT = 32
BACKENDS = ("servers", "big")

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
    # PC 를 뺀 servers 의 켜진 자리(maxconn 합). None 이면 아직 통계를 못 봄
    servers_online_slots: int | None = None


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


def is_online(status: str) -> bool:
    """HAProxy 서버 상태가 새 요청을 받는 상태인가(UP, 내려가는 중인 UP 1/2, 검사 없음). DRAIN·MAINT·DOWN 은 아니다."""
    return status.startswith("UP") or status == "no check"


@dataclass
class Server:
    """라우터의 추론 서버 하나(모든 파드·backend 를 합침)."""

    backends: set[str] = field(default_factory=set)
    slots: int = 1  # backend 별 maxconn(slim) 가운데 최대. 서버의 자리는 backend 가 여럿이어도 한 번만 센다
    online: bool = False  # 어느 파드에서든 새 요청을 받는 상태


def server_table(per_pod: dict[str, dict[tuple[str, str], Row]]) -> dict[str, Server]:
    """추론 backend(servers·big)의 서버 → 자리·상태."""
    table: dict[str, Server] = {}
    for rows in per_pod.values():
        for (px, sv), row in rows.items():
            if px not in BACKENDS or sv in {"FRONTEND", "BACKEND"}:
                continue
            server = table.get(sv)
            if server is None:
                server = table[sv] = Server(slots=0)
            server.backends.add(px)
            server.slots = max(server.slots, row.slim or 1)
            server.online |= is_online(row.status)
    return table


def usable_slots(
    table: dict[str, Server], pc: str, pc_wakeable: bool
) -> dict[str, tuple[frozenset[str], int, str]]:
    """서버 → (backend 들, 쓸 수 있는 자리, 등급별 상태). 켜진 서버는 online, 깨울 수 있는 대기 서버는 standby, 나머지는 0."""
    usable = {}
    for name, server in table.items():
        if server.online:
            usable[name] = (frozenset(server.backends), server.slots, "online")
        elif name == pc and pc_wakeable:
            usable[name] = (frozenset(server.backends), server.slots, "standby")
        else:
            usable[name] = (frozenset(server.backends), 0, "down")
    return usable


def free_slots(
    backend: str,
    usable: dict[str, tuple[frozenset[str], int, str]],
    used: dict[str, int],
) -> int:
    """backend 에 더 줄 수 있는 임대 수.

    서버 하나가 여러 backend 에 있으면(780m 은 servers·big) 그 자리를 backend 들이 나눠 쓴다. 공급·수요 정리(Hall)대로,
    backend 를 포함하는 모든 backend 묶음 T 에 대해 'T 가 닿는 서버의 자리 − T 의 임대' 의 최솟값이 남은 자리다.
    """
    others = sorted(
        ({b for bs, _, _ in usable.values() for b in bs} | set(used)) - {backend}
    )
    best: int | None = None
    for mask in range(1 << len(others)):
        group = {backend} | {o for i, o in enumerate(others) if mask >> i & 1}
        cap = sum(n for bs, n, _ in usable.values() if bs & group)
        left = cap - sum(used.get(b, 0) for b in group)
        best = left if best is None else min(best, left)
    return max(0, best or 0)


def aggregate(per_pod: dict[str, dict[tuple[str, str], Row]], pc: str) -> Load:
    """파드별 통계를 합친다(big_new 는 StotTracker 가 채운다)."""
    load = Load(servers_online_slots=0)
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
    load.servers_online_slots = sum(
        s.slots
        for name, s in server_table(per_pod).items()
        if name != pc and s.online and "servers" in s.backends
    )
    return load


# ---- 클라이언트 수요 신고


class Reports:
    """라우터에 아직 보내지 않은 요청의 신고. 스레드 안전.

    waiting: 클라이언트가 자리가 없어 실제로 기다리는 중(켜기·되살리기의 '기다리는 일'). 보내기 전 준비 중이면 false.
    """

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.live: dict[
            str, tuple[str, float, bool]
        ] = {}  # id → (backend, 만료, waiting)
        self.handoff: dict[str, tuple[str, float]] = {}  # 해제됨, 켜기 판정에만 센다
        self.tombstones: dict[str, float] = {}

    def _expire(self, now: float) -> None:
        self.live = {k: v for k, v in self.live.items() if v[1] > now}
        self.handoff = {k: v for k, v in self.handoff.items() if v[1] > now}
        self.tombstones = {k: t for k, t in self.tombstones.items() if t > now}

    def put(self, rid: str, backend: str, now: float, waiting: bool = False) -> bool:
        """신고하거나 갱신한다. 지운 id 이거나 상한을 넘으면 False."""
        with self.lock:
            self._expire(now)
            if rid in self.tombstones:
                return False
            if rid not in self.live and len(self.live) >= MAX_REPORTS:
                return False
            self.live[rid] = (backend, now + REPORT_TTL, waiting)
            return True

    def delete(self, rid: str, now: float) -> None:
        """해제한다. 켜기 판정에는 HANDOFF_SECONDS 동안 더 센다."""
        with self.lock:
            self._expire(now)
            item = self.live.pop(rid, None)
            if item is not None:
                self.handoff[rid] = (item[0], now + HANDOFF_SECONDS)
            self.tombstones[rid] = now + TOMBSTONE_SECONDS

    def count(
        self, backend: str, now: float, *, handoff: bool, waiting: bool = False
    ) -> int:
        """살아 있는 신고 수. handoff 면 인계 중인 것도, waiting 이면 기다리는 신고만."""
        with self.lock:
            self._expire(now)
            n = sum(
                1
                for b, _, w in self.live.values()
                if b == backend and (w or not waiting)
            )
            if handoff:
                n += sum(1 for b, _ in self.handoff.values() if b == backend)
            return n


class Leases:
    """워크플로 job 의 자리 임대. 스레드 안전. 발급은 저장이 성공해야 확정한다.

    save: 임대 전체(dict)를 남기는 함수(실패하면 예외). None 이면 저장하지 않는다(시험·--stats-url).
    """

    def __init__(self, save=None) -> None:
        self.lock = threading.Lock()
        self.items: dict[str, dict] = {}
        self.save = save
        self.dirty = False
        self.saved_at = 0.0

    def load(self, data: dict, now: float) -> None:
        with self.lock:
            self.items = {
                k: dict(v)
                for k, v in data.items()
                if isinstance(v, dict) and float(v.get("expires", 0)) > now
            }

    def _expire(self, now: float) -> None:
        alive = {k: v for k, v in self.items.items() if v["expires"] > now}
        if len(alive) != len(self.items):
            self.items = alive
            self.dirty = True

    def _persist(self) -> None:
        if self.save is not None:
            self.save({k: dict(v) for k, v in self.items.items()})
        self.dirty = False

    def used(self, now: float) -> dict[str, int]:
        with self.lock:
            self._expire(now)
            out: dict[str, int] = {}
            for v in self.items.values():
                out[v["backend"]] = out.get(v["backend"], 0) + 1
            return out

    def reserve(
        self,
        run: str,
        workflow: str,
        backend: str,
        want: int,
        usable: dict[str, tuple[frozenset[str], int, str]],
        now: float,
    ) -> tuple[int, dict]:
        """남은 자리만큼(최대 want) 임대를 만든다. (HTTP 코드, 응답)."""
        with self.lock:
            self._expire(now)
            used: dict[str, int] = {}
            for v in self.items.values():
                used[v["backend"]] = used.get(v["backend"], 0) + 1
            free = free_slots(backend, usable, used)
            n = max(0, min(want, MAX_WANT, free, MAX_LEASES - len(self.items)))
            new = {
                secrets.token_hex(16): {
                    "run": run[:64],
                    "workflow": workflow[:64],
                    "backend": backend,
                    "expires": now + LEASE_FRESH_TTL,
                    "active": False,
                }
                for _ in range(n)
            }
            if new:
                self.items.update(new)
                try:
                    self._persist()
                except Exception as exc:  # noqa: BLE001 — 저장 실패는 종류와 상관없이 발급 취소
                    for k in new:
                        del self.items[k]
                    log.warning("임대를 저장하지 못해 발급하지 않았다: %s", exc)
                    return 503, {"error": "임대를 저장하지 못했다"}
            return 200, {
                "leases": list(new),
                "granted": n,
                "free": free - n,
                "ttl": LEASE_FRESH_TTL,
            }

    def renew(self, lid: str, now: float) -> bool:
        """job 이 시작했거나 살아 있다. 수명을 LEASE_ACTIVE_TTL 로 다시 잡는다. 없으면 False."""
        with self.lock:
            self._expire(now)
            item = self.items.get(lid)
            if item is None:
                return False
            item["expires"] = now + LEASE_ACTIVE_TTL
            item["active"] = True
            self.dirty = True
            return True

    def delete(self, lid: str, now: float) -> None:
        """돌려준다(없어도 성공, 멱등)."""
        with self.lock:
            self._expire(now)
            if self.items.pop(lid, None) is not None:
                try:
                    self._persist()
                except Exception as exc:  # noqa: BLE001
                    self.dirty = True
                    log.warning(
                        "임대 반환을 저장하지 못했다(다음 판정에 다시): %s", exc
                    )

    def flush(self, now: float, force: bool = False) -> None:
        """만료를 정리하고, 바뀐 것을 LEASE_SAVE_SECONDS 간격으로 모아 저장한다."""
        with self.lock:
            self._expire(now)
            if not self.dirty or (
                not force and now - self.saved_at < LEASE_SAVE_SECONDS
            ):
                return
            try:
                self._persist()
                self.saved_at = now
            except Exception as exc:  # noqa: BLE001
                log.warning("임대를 저장하지 못했다(다음 판정에 다시): %s", exc)

    def summary(self, now: float) -> list[dict]:
        """id 를 뺀 목록(조회용)."""
        with self.lock:
            self._expire(now)
            return [
                {
                    "run": v["run"],
                    "workflow": v["workflow"],
                    "backend": v["backend"],
                    "active": v["active"],
                    "expires_in": round(v["expires"] - now),
                }
                for v in self.items.values()
            ]


# ---- 판단


@dataclass
class Config:
    wake_seconds: float = 60.0  # 켜기·되살리기 조건이 이만큼 이어져야 한다
    release_seconds: float = 120.0  # PC 몫이 1건 이하인 상태가 이만큼 이어지면 release
    cooldown_seconds: float = (
        600.0  # WOL 이 실패했을 때만, 보낸 때부터 이만큼 다시 보내지 않는다
    )
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
    # WOL 을 보낸 벽시계(epoch). ConfigMap 에 남긴다. 켜진 부팅을 판정하면(자동 켜짐 확정 또는 사용자 부팅) 지운다.
    # 남아 있는데 PC 가 boot_timeout 안에 안 켜졌으면 실패라 그때부터 쿨다운이다.
    wol_sent_at: float | None = None
    wol_attempts: int = 0
    last_wol_try: float = 0.0
    agent: dict | None = None
    agent_seen_at: float = 0.0
    wake_since: float | None = None  # 전역 보통 수요 2건 이상이 시작된 때(수요 구간)
    episode_woke: bool = False  # 이 수요 구간에 PC 가 켜졌거나 켜는 중이었다
    waiting_since: float | None = None  # 기다리는 일 1건 이상이 시작된 때
    keep_low_since: float | None = None
    cleared_after_release: bool = False  # release 뒤 기다리는 일이 0 이 된 적이 있다
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
        """WOL 을 보내도 되는가. 판정을 마친 WOL 은 지우므로, 남은 wol_sent_at 은 진행 중이거나 실패한 것이다."""
        return (
            self.wol_sent_at is None
            or now - self.wol_sent_at >= self.cfg.cooldown_seconds
        )

    def wakeable(self, now: float) -> bool:
        """대기 서버로서 자리를 쳐도 되는가: 꺼져 있고 깨울 수 있음, 켜는 중, 켜졌거나 되살릴 수 있는 자동 부팅.

        사용자 부팅은 켜져 있으면 상시처럼 라우터 상태(UP)로만 친다. 꺼져 있는데 WOL 실패 쿨다운 중이면 False(장애).
        """
        state = self.state(now)
        if state == "off":
            return self.cooled(now)
        return state in {"waking", "auto", "released"}

    # 입력

    def see_agent(self, status: dict | None, now: float) -> None:
        if status is not None:
            self.agent = status
            self.agent_seen_at = now

    def _wol(self, now: float) -> list[tuple]:
        self.wol_sent_at = now
        self.wol_attempts = 1
        self.last_wol_try = now
        self.episode_woke = self.wake_since is not None
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

    def _can_wol(self, now: float) -> bool:
        return not self.pc_on(now) and not self.waking(now) and self.cooled(now)

    def on_demand(
        self, backend: str, now: float, counts: dict[str, int], waiting: bool = False
    ) -> tuple[str, list[tuple]]:
        """신고를 받은 순간의 판단. (응답 상태, 할 일).

        - 30B 신고(serve_big 일 때)는 바로 켜거나 되살린다.
        - 보통 신고가 기다리는 중(waiting)인데 상시 서버의 켜진 자리가 0 이면 바로 켠다.
        """
        actions: list[tuple] = []
        if backend == "big" and not self.cfg.serve_big:
            return "n/a", actions
        if backend == "big":
            if self._can_wol(now):
                actions += self._wol(now)
            elif self.pc_on(now) and self.auto_boot() and self.released():
                actions.append(("auto", self.agent.get("boot_id")))
                return "resuming", actions
        elif (
            waiting and self.last_load.servers_online_slots == 0 and self._can_wol(now)
        ):
            actions += self._wol(now)
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
        """주기 판단. counts: big·servers 의 살아 있는 신고, servers_handoff, servers_waiting."""
        self.last_load = load
        self.last_counts = counts
        actions: list[tuple] = []
        big_movable = load.big_qcur + counts.get("big", 0) + load.pc_big_active
        if not self.cfg.serve_big:
            big_movable = 0
        big_wake = big_movable > 0 or (self.cfg.serve_big and load.big_new > 0)
        normal_wake = (
            load.servers_active
            + load.servers_qcur
            + counts.get("servers", 0)
            + counts.get("servers_handoff", 0)
        )
        waiting = load.servers_qcur + counts.get("servers_waiting", 0)
        pc_load = load.pc_servers_active + waiting
        on = self.pc_on(now)

        # 수요 구간: 전역 보통 수요 2건 이상이 이어지는 동안. 그 구간에 PC 가 켜졌던 적이 있으면 이 규칙으로 다시 켜지 않는다
        if normal_wake >= 2:
            if self.wake_since is None:
                self.wake_since = now
            if on or self.waking(now):
                self.episode_woke = True
        else:
            self.wake_since = None
            self.episode_woke = False
        episode_ok = (
            self.wake_since is not None
            and now - self.wake_since >= self.cfg.wake_seconds
            and not self.episode_woke
        )
        if waiting >= 1:
            if self.waiting_since is None:
                self.waiting_since = now
        else:
            self.waiting_since = None
        waiting_ok = (
            self.waiting_since is not None
            and now - self.waiting_since >= self.cfg.wake_seconds
        )
        urgent = waiting >= 1 and load.servers_online_slots == 0

        if not on:
            if self.waking(now):
                if (
                    self.wol_attempts <= self.cfg.wol_retries
                    and now - self.last_wol_try >= self.cfg.wol_retry_seconds
                ):
                    self.wol_attempts += 1
                    self.last_wol_try = now
                    actions.append(("wol",))
            elif (big_wake or episode_ok or waiting_ok or urgent) and self.cooled(now):
                actions += self._wol(now)
            self.keep_low_since = None
            return actions

        # 켜져 있다: 내 WOL 이 남아 있으면 이 부팅을 판정한다. 자동 켜짐이 확정되거나 사용자 부팅이면 WOL 기록을 지운다
        if self.wol_sent_at is not None:
            if self.auto_boot() or not self._boot_is_mine():
                self.wol_sent_at = None
                actions.append(("save", None))
            else:
                actions.append(("auto", self.agent.get("boot_id")))
        if self.auto_boot():
            if big_movable == 0 and pc_load <= 1:
                self.keep_low_since = (
                    self.keep_low_since if self.keep_low_since is not None else now
                )
            else:
                self.keep_low_since = None
            if self.released():
                if waiting == 0:
                    self.cleared_after_release = True
                if big_wake or (self.cleared_after_release and waiting_ok):
                    actions.append(("auto", self.agent.get("boot_id")))
            else:
                self.cleared_after_release = False
                if (
                    self.keep_low_since is not None
                    and now - self.keep_low_since >= self.cfg.release_seconds
                ):
                    actions.append(("release", self.agent.get("boot_id")))
        else:
            self.keep_low_since = None
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

    def load_state(self, name: str) -> dict[str, str]:
        """상태 ConfigMap 의 data(없으면 빈 dict)."""
        try:
            cm = self.call("GET", f"/api/v1/namespaces/{self.ns}/configmaps/{name}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {}
            raise
        return cm.get("data") or {}

    def save_state(self, name: str, data: dict[str, str | None]) -> None:
        """data 의 키만 바꾼다(merge-patch, None 은 키를 지움). ConfigMap 이 없으면 만든다."""
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
                {
                    "metadata": {"name": name},
                    "data": {k: v for k, v in data.items() if v is not None},
                },
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
        self.server_class: dict[str, str] = {}  # 서버 → online·standby
        self.wakeable = 0
        self.leases: dict[str, int] = {}  # backend → 살아 있는 임대
        self.slots: dict[tuple[str, str], int] = {}  # (backend, online·standby) → 자리
        self.free: dict[str, int] = {}  # backend → 남은 자리

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
            lines += [
                "# HELP ollama_server_class 추론 서버 등급(online 상시, standby 대기 — 꺼져 있어도 WOL 로 깨움)",
                "# TYPE ollama_server_class gauge",
            ]
            lines += [
                f'ollama_server_class{{server="{s}",class="{c}"}} 1'
                for s, c in sorted(self.server_class.items())
            ]
            lines += [
                "# HELP gpu_pc_wakeable 조립 PC 를 대기 서버로 칠 수 있는가(꺼져 있고 깨울 수 있음·켜는 중·자동 부팅). 0 이면 WOL 실패 쿨다운 또는 사용자 부팅",
                "# TYPE gpu_pc_wakeable gauge",
                f"gpu_pc_wakeable {self.wakeable}",
                "# HELP ollama_leases 살아 있는 자리 임대(backend 별)",
                "# TYPE ollama_leases gauge",
            ]
            lines += [
                f'ollama_leases{{backend="{b}"}} {self.leases.get(b, 0)}'
                for b in BACKENDS
            ]
            lines += [
                "# HELP ollama_capacity_slots 임대에 쓰는 자리(backend·등급별, 서버가 여러 backend 에 있으면 각 backend 에 센다)",
                "# TYPE ollama_capacity_slots gauge",
            ]
            lines += [
                f'ollama_capacity_slots{{backend="{b}",class="{c}"}} {v}'
                for (b, c), v in sorted(self.slots.items())
            ]
            lines += [
                "# HELP ollama_capacity_free 지금 더 줄 수 있는 임대 수(backend 별)",
                "# TYPE ollama_capacity_free gauge",
            ]
            lines += [
                f'ollama_capacity_free{{backend="{b}"}} {v}'
                for b, v in sorted(self.free.items())
            ]
            return "\n".join(lines) + "\n"


# ---- 실행


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="조립 PC 를 LLM 수요가 충분할 때만 WOL 로 켜고, 수요가 줄면 PC 에이전트에 내려도 된다고 알린다. "
        "서버 등급(GET /servers)과 워크플로 자리 임대(POST /reserve)도 맡는다.",
        epilog=(
            "예:\n"
            "  python3 power.py --mac [GPUPC_MAC] --agent-host [GPUPC_IP] --pc-server pc-custom \\\n"
            "      --models gemma4:12b,qwen3.5:9b --meta-servers pve02-780m,pve01-610m\n"
            "  python3 power.py --mac [GPUPC_MAC] --agent-host [GPUPC_IP] --once --dry-run \\\n"
            "      --stats-url http://ollama.ollama.svc:8404/\\;csv   # 한 번 판단만 출력\n\n"
            "환경 변수: GPU_PC_CONTROL_TOKEN(PC 에이전트 제어), GPU_PC_DEMAND_TOKEN(수요 신고·임대 인증)\n"
            "HTTP(:9112, --allow 대역만. /metrics·/healthz 는 예외): GET /servers·/leases, POST /demand {id, backend, waiting},\n"
            "  POST /reserve {run, workflow, backend, want} → {leases, granted, free}, POST /lease/<id>/activate·renew,\n"
            "  DELETE /demand/<id>·/lease/<id> (POST·DELETE 는 Bearer GPU_PC_DEMAND_TOKEN)\n"
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
        help="수요 신고·임대·서버 등급 조회를 받을 출발지 대역(쉼표, 기본 flannel 파드 대역과 루프백)",
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
        self.save_lock = threading.Lock()
        self.control_token = os.environ.get("GPU_PC_CONTROL_TOKEN", "")
        self.demand_token = os.environ.get("GPU_PC_DEMAND_TOKEN", "")
        self.networks = [
            ipaddress.ip_network(n.strip()) for n in args.allow.split(",") if n.strip()
        ]
        self.kube = None if args.stats_url else Kube(args.namespace)
        self._stats_warned: set[str] = set()
        self.agent_base = f"http://{args.agent_host}:{args.control_port}"
        self.wol_targets = args.wol_target or ["255.255.255.255:9"]
        self.table: dict[str, Server] | None = None  # 마지막으로 읽은 라우터 서버 표
        persist = self.kube is not None and not args.dry_run
        self.leases = Leases(self._save_leases if persist else None)
        if persist:
            try:
                data = self.kube.load_state(args.state_configmap)
                if data.get("wol_sent_at"):
                    self.brain.wol_sent_at = float(data["wol_sent_at"])
                self.leases.load(json.loads(data.get("leases") or "{}"), time.time())
            except (OSError, urllib.error.URLError, ValueError) as exc:
                log.warning(
                    "상태 ConfigMap 을 읽지 못했다(켠 기록·임대 없음으로 본다): %s", exc
                )

    def _save(self, data: dict[str, str | None]) -> None:
        with self.save_lock:
            self.kube.save_state(self.args.state_configmap, data)

    def _save_leases(self, items: dict) -> None:
        self._save({"leases": json.dumps(items, separators=(",", ":"))})

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
            "servers_waiting": self.reports.count(
                "servers", now, handoff=False, waiting=True
            ),
        }

    def run_actions(self, actions: list[tuple]) -> None:
        for action in actions:
            kind = action[0]
            if self.args.dry_run:
                continue
            try:
                if kind == "save" and self.kube:
                    value = action[1]
                    self._save(
                        {"wol_sent_at": None if value is None else f"{value:.0f}"}
                    )
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

    def demand(self, rid: str, backend: str, waiting: bool = False) -> tuple[int, dict]:
        """POST /demand 처리."""
        now = time.time()
        if backend not in BACKENDS:
            return 400, {"error": "backend 는 big 또는 servers"}
        if not self.reports.put(rid, backend, now, waiting):
            return 429, {"error": "신고가 너무 많거나 이미 지운 id"}
        with self.lock:
            state, actions = self.brain.on_demand(
                backend, now, self.counts(now), waiting
            )
            if actions:
                self.emit(now, None, actions, "demand")
                self.run_actions(actions)
        return 200, {"pc": state}

    def usable(self, now: float) -> dict[str, tuple[frozenset[str], int, str]] | None:
        """임대에 쓰는 서버별 자리. 라우터 통계를 아직 못 읽었으면 None."""
        with self.lock:
            if self.table is None:
                return None
            return usable_slots(
                self.table, self.args.pc_server, self.brain.wakeable(now)
            )

    def reserve(self, body: dict) -> tuple[int, dict]:
        """POST /reserve {run, workflow, backend, want}."""
        backend = str(body.get("backend", ""))
        if backend not in BACKENDS:
            return 400, {"error": "backend 는 big 또는 servers"}
        try:
            want = int(body.get("want", 1))
        except (TypeError, ValueError):
            return 400, {"error": "want 는 정수"}
        now = time.time()
        usable = self.usable(now)
        if usable is None:
            return 503, {"error": "라우터 통계를 아직 읽지 못했다"}
        code, reply = self.leases.reserve(
            str(body.get("run", "")),
            str(body.get("workflow", "")),
            backend,
            want,
            usable,
            now,
        )
        if code == 200:
            log.info(
                "임대 %s/%s %s: %d건 요청 → %d건(남은 자리 %d)",
                body.get("workflow"),
                body.get("run"),
                backend,
                want,
                reply["granted"],
                reply["free"],
            )
        return code, reply

    def servers(self, now: float) -> dict:
        """GET /servers: 대기 서버의 등급·전원 상태·깨울 수 있는지. 여기 없는 서버는 상시다."""
        with self.lock:
            table = self.table or {}
            pc = self.args.pc_server
            return {
                pc: {
                    "class": "standby",
                    "backends": sorted(table[pc].backends) if pc in table else [],
                    "power": self.brain.state(now),
                    "wakeable": self.brain.wakeable(now),
                }
            }

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
            if per_pod:
                self.table = server_table(per_pod)
            self.brain.see_agent(agent, now)
            counts = self.counts(now)
            actions = self.brain.tick(load, counts, now)
            if [a for a in actions if a[0] != "hint"] or self.args.once:
                self.emit(now, load, actions, "tick")
            self.run_actions(actions)
            self._update_metrics(load, counts, now)
        self.leases.flush(now)
        self.check_models(per_pod)
        return True

    def _update_metrics(self, load: Load, counts: dict[str, int], now: float) -> None:
        pc = self.args.pc_server
        usable = (
            usable_slots(self.table, pc, self.brain.wakeable(now)) if self.table else {}
        )
        used = self.leases.used(now)
        slots: dict[tuple[str, str], int] = {}
        for bs, n, cls in usable.values():
            if cls == "down":
                continue
            for b in bs:
                slots[(b, cls)] = slots.get((b, cls), 0) + n
        waiting = load.servers_qcur + counts["servers_waiting"]
        with self.metrics.lock:
            self.metrics.state = self.brain.state(now)
            self.metrics.reports = counts["big"] + counts["servers"]
            self.metrics.demand = {
                "big_movable": (load.big_qcur + counts["big"] + load.pc_big_active)
                if self.cfg.serve_big
                else 0,
                "normal_wake": load.servers_active
                + load.servers_qcur
                + counts["servers"]
                + counts["servers_handoff"],
                "waiting": waiting,
                "pc_load": load.pc_servers_active + waiting,
            }
            self.metrics.server_class = {
                name: "standby" if name == pc else "online" for name in self.table or {}
            }
            self.metrics.wakeable = int(self.brain.wakeable(now))
            self.metrics.leases = used
            self.metrics.slots = slots
            self.metrics.free = {b: free_slots(b, usable, used) for b in BACKENDS}

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

        def _source_ok(self) -> bool:
            if not allowed(self.client_address[0], service.networks):
                self._send(403, {"error": "허용하지 않은 출발지"})
                return False
            return True

        def _authorized(self) -> bool:
            if not self._source_ok():
                return False
            token = service.demand_token
            if not token or self.headers.get("Authorization") != f"Bearer {token}":
                self._send(401, {"error": "토큰이 맞지 않음"})
                return False
            return True

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise TypeError("객체가 아님")
            return body

        def do_GET(self) -> None:
            if self.path == "/metrics":
                self._send(200, service.metrics.render(), "text/plain; version=0.0.4")
            elif self.path == "/healthz":
                self._send(200, {"ok": True})
            elif self.path in {"/servers", "/leases"}:
                if not self._source_ok():
                    return
                now = time.time()
                if self.path == "/servers":
                    self._send(200, service.servers(now))
                else:
                    self._send(200, {"leases": service.leases.summary(now)})
            else:
                self._send(404, {"error": "없음"})

        def do_POST(self) -> None:
            parts = self.path.strip("/").split("/")
            known = self.path in {"/demand", "/reserve"} or (
                len(parts) == 3
                and parts[0] == "lease"
                and parts[2] in {"activate", "renew"}
            )
            if not known:
                self._send(404, {"error": "없음"})
                return
            if not self._authorized():
                return
            if parts[0] == "lease":
                if service.leases.renew(parts[1], time.time()):
                    self._send(200, {"ok": True, "ttl": LEASE_ACTIVE_TTL})
                else:
                    self._send(404, {"error": "임대가 없다(만료되었거나 반환됨)"})
                return
            try:
                body = self._body()
                if self.path == "/reserve":
                    code, reply = service.reserve(body)
                else:
                    rid = str(body.get("id") or uuid.uuid4())
                    code, reply = service.demand(
                        rid, str(body.get("backend", "")), bool(body.get("waiting"))
                    )
            except (ValueError, TypeError):
                code, reply = 400, {"error": "JSON 객체가 아님"}
            self._send(code, reply)

        def do_DELETE(self) -> None:
            for prefix, target in (
                ("/demand/", service.reports),
                ("/lease/", service.leases),
            ):
                if self.path.startswith(prefix) and "/" not in self.path.removeprefix(
                    prefix
                ):
                    if self._authorized():
                        target.delete(self.path.removeprefix(prefix), time.time())
                        self._send(200, {"ok": True})
                    return
            self._send(404, {"error": "없음"})

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

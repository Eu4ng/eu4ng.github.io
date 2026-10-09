#!/usr/bin/env python3
"""ollama 라우터의 요청 로그와 모델 서버의 상태를 Prometheus 지표로 낸다.

라우터(haproxy.cfg)는 요청마다 `log-format` 의 한 줄(key=value: backend, server, status, queue_ms, total_ms, bytes_out, model, role …)을
UDP 로 이 프로그램에 보낸다. HAProxy 자체 익스포터는 서버 단위까지만 세므로, "어느 모델이 어느 서버에서 얼마나" 는 여기서 센다.
그리고 HAProxy runtime API(`show stat`)로 서버 주소를 알아내 서버마다 `/api/ps` 를 읽어 지금 올라간 모델·크기를 내고, 올라간
모델이 바뀐 횟수(교체)를 센다 — 라우터를 거치지 않은 직접 호출도 "모델이 올라감" 수준으로는 잡힌다.
윈도우 PC 의 상태 보고 에이전트(windows-agent.ps1)에 `stats` 를 보내면 여유 메모리·GPU 사용률을 JSON 으로 답하므로 그것도 낸다.
서버마다 상태 보고 에이전트의 `:11437/status`(LXC: proxmox-ansible ollama-agent.py, 윈도우: windows-agent.ps1)를 읽어 러너가 지금
계산 중인지·GPU 사용률을 낸다 — 라우터가 롤링 재시작되면 진행 중 요청은 옛 파드가 쥐고 통계는 새 파드가 답해 HAProxy 지표의
'처리 중'이 0 으로 비는데(2026-10-07 11:47), 서버 쪽 값은 라우터와 무관하게 남는다.
표준 라이브러리만 쓴다(라우터 파드의 python:alpine 이미지).
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import socket
import sys
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXIT_OK = 0
EXIT_FAIL = 1
# 처리 시간(초) 버킷. 30B 요약 한 건이 36분까지 걸렸다(2026-10-06)
DURATION_BUCKETS = (5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600)
QUEUE_BUCKETS = (1, 10, 30, 60, 300, 600, 1200, 1800, 3600)

log = logging.getLogger("metrics")


def _label_str(labels: dict[str, str]) -> str:
    if not labels:
        return ""
    body = ",".join(
        f'{k}="{str(v).replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34))}"'
        for k, v in labels.items()
    )
    return "{" + body + "}"


class Registry:
    """카운터·게이지·히스토그램을 들고 Prometheus 텍스트 형식으로 쓴다. 스레드 여럿이 쓰므로 잠근다."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, dict[tuple, float]] = {}
        self._gauges: dict[str, dict[tuple, float]] = {}
        self._hists: dict[str, dict[tuple, list[float]]] = {}
        self._meta: dict[str, tuple[str, str, tuple[str, ...], tuple[float, ...]]] = {}

    def declare(
        self,
        name: str,
        kind: str,
        help_text: str,
        labels: tuple[str, ...],
        buckets: tuple[float, ...] = (),
    ) -> None:
        self._meta[name] = (kind, help_text, labels, buckets)
        {"counter": self._counters, "gauge": self._gauges, "histogram": self._hists}[
            kind
        ].setdefault(name, {})

    def _key(self, name: str, labels: dict[str, str]) -> tuple:
        return tuple(str(labels.get(k, "")) for k in self._meta[name][2])

    def inc(self, name: str, labels: dict[str, str], value: float = 1.0) -> None:
        with self._lock:
            store = self._counters[name]
            store[self._key(name, labels)] = (
                store.get(self._key(name, labels), 0.0) + value
            )

    def set(self, name: str, labels: dict[str, str], value: float) -> None:
        with self._lock:
            self._gauges[name][self._key(name, labels)] = value

    def clear_gauge(self, name: str, prefix: dict[str, str]) -> None:
        """앞쪽 라벨이 prefix 와 같은 게이지를 모두 지운다(서버의 모델 목록을 새로 쓸 때)."""
        with self._lock:
            want = tuple(str(v) for v in prefix.values())
            store = self._gauges[name]
            for key in [k for k in store if k[: len(want)] == want]:
                del store[key]

    def observe(self, name: str, labels: dict[str, str], value: float) -> None:
        buckets = self._meta[name][3]
        with self._lock:
            row = self._hists[name].setdefault(
                self._key(name, labels), [0.0] * (len(buckets) + 3)
            )  # 버킷들, +Inf, sum, count
            for i, bound in enumerate(buckets):
                if value <= bound:
                    row[i] += 1
            row[len(buckets)] += 1
            row[len(buckets) + 1] += value
            row[len(buckets) + 2] += 1

    def render(self) -> str:
        lines: list[str] = []
        with self._lock:
            for name, (kind, help_text, label_names, buckets) in self._meta.items():
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} {kind}")
                if kind == "histogram":
                    for key, row in sorted(self._hists[name].items()):
                        base = dict(zip(label_names, key))
                        for i, bound in enumerate(buckets):
                            lines.append(
                                f"{name}_bucket{_label_str({**base, 'le': _fmt(bound)})} {_fmt(row[i])}"
                            )
                        lines.append(
                            f"{name}_bucket{_label_str({**base, 'le': '+Inf'})} {_fmt(row[len(buckets)])}"
                        )
                        lines.append(
                            f"{name}_sum{_label_str(base)} {_fmt(row[len(buckets) + 1])}"
                        )
                        lines.append(
                            f"{name}_count{_label_str(base)} {_fmt(row[len(buckets) + 2])}"
                        )
                    continue
                store = (
                    self._counters[name] if kind == "counter" else self._gauges[name]
                )
                for key, value in sorted(store.items()):
                    lines.append(
                        f"{name}{_label_str(dict(zip(label_names, key)))} {_fmt(value)}"
                    )
        return "\n".join(lines) + "\n"


def _fmt(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else repr(float(value))


def build_registry() -> Registry:
    reg = Registry()
    reg.declare(
        "ollama_requests_total",
        "counter",
        "라우터를 거친 요청 수",
        ("backend", "server", "model", "role", "status"),
    )
    reg.declare(
        "ollama_request_duration_seconds",
        "histogram",
        "서버가 요청을 처리한 시간(대기열 제외)",
        ("backend", "server", "model", "role"),
        DURATION_BUCKETS,
    )
    reg.declare(
        "ollama_queue_duration_seconds",
        "histogram",
        "라우터 대기열에서 기다린 시간",
        ("backend", "model", "role"),
        QUEUE_BUCKETS,
    )
    reg.declare(
        "ollama_response_bytes_total",
        "counter",
        "서버가 내보낸 응답 바이트",
        ("backend", "server", "model", "role"),
    )
    reg.declare(
        "ollama_retries_total",
        "counter",
        "다른 서버로 다시 보낸 횟수",
        ("backend", "server"),
    )
    reg.declare("ollama_log_lines_total", "counter", "받은 로그 줄 수", ("result",))
    reg.declare(
        "ollama_loaded_model_bytes",
        "gauge",
        "서버에 지금 올라간 모델의 크기(/api/ps size)",
        ("server", "model"),
    )
    reg.declare(
        "ollama_loaded_model_vram_bytes",
        "gauge",
        "서버에 지금 올라간 모델이 GPU 에 올린 크기(/api/ps size_vram)",
        ("server", "model"),
    )
    reg.declare(
        "ollama_model_loads_total",
        "counter",
        "서버에 모델이 새로 올라간 횟수(교체 포함)",
        ("server", "model"),
    )
    reg.declare("ollama_server_up", "gauge", "/api/ps 에 답했으면 1", ("server",))
    reg.declare(
        "ollama_server_working",
        "gauge",
        "상태 에이전트(:11437/status)가 러너가 계산 중이라 답했으면 1(라우터 재시작과 무관한 서버 쪽 '처리 중')",
        ("server",),
    )
    reg.declare(
        "ollama_server_gpu_busy_percent",
        "gauge",
        "상태 에이전트가 답한 GPU 사용률(%)",
        ("server",),
    )
    reg.declare(
        "ollama_server_runner_cpu_percent",
        "gauge",
        "상태 에이전트가 답한 러너 CPU 사용률 가운데 가장 큰 값(%, 코어 하나 = 100)",
        ("server",),
    )
    reg.declare("ollama_server_status_up", "gauge", "상태 에이전트가 답했으면 1", ("server",))
    reg.declare(
        "ollama_agent_free_gb",
        "gauge",
        "상태 보고 에이전트가 답한, Ollama 가 쓸 수 있는 메모리(GB)",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_other_gpu_percent",
        "gauge",
        "상태 보고 에이전트가 답한, Ollama 가 아닌 프로세스의 GPU 사용률 합(%)",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_drain",
        "gauge",
        "상태 보고 에이전트가 drain 이라 답했으면 1",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_up",
        "gauge",
        "상태 보고 에이전트가 답했으면 1",
        ("server", "port"),
    )
    return reg


def parse_log_line(line: str) -> dict[str, str] | None:
    """haproxy.cfg 의 log-format 한 줄에서 key=value 를 뽑는다. 라우터 요청 로그가 아니면 None."""
    marker = " ollama "
    at = line.find(marker)
    if at < 0:
        return None
    fields: dict[str, str] = {}
    for token in line[at + len(marker) :].split(" "):
        if token.startswith('"'):
            break  # 요청 줄(%{+Q}r)부터는 보지 않는다
        key, sep, value = token.partition("=")
        if sep:
            fields[key] = value
    return fields if "server" in fields and "status" in fields else None


def record(reg: Registry, fields: dict[str, str]) -> bool:
    """로그 한 줄을 지표에 더한다. 숫자가 깨진 줄은 거짓."""
    try:
        queue_ms = max(int(fields.get("queue_ms", "0")), 0)  # 끊긴 요청은 -1
        total_ms = max(int(fields.get("total_ms", "0")), 0)
        bytes_out = int(fields.get("bytes_out", "0"))
        retries = max(int(fields.get("retries", "0")), 0)
    except ValueError:
        return False
    server = fields["server"] or "-"
    labels = {
        "backend": fields.get("backend", "-") or "-",
        "server": server,
        "model": fields.get("model") or "-",
        "role": fields.get("role") or "-",
    }
    reg.inc("ollama_requests_total", {**labels, "status": fields["status"]})
    reg.inc("ollama_response_bytes_total", labels, bytes_out)
    if retries:
        reg.inc("ollama_retries_total", labels, retries)
    reg.observe("ollama_queue_duration_seconds", labels, queue_ms / 1000)
    if server != "<NOSRV>" and fields["status"].startswith("2"):
        # 처리 시간은 끝까지 간 요청만 센다. 끊긴 요청(-1, 5xx)은 요청 수와 상태로만 남긴다
        reg.observe(
            "ollama_request_duration_seconds",
            labels,
            max(total_ms - queue_ms, 0) / 1000,
        )
    return True


def serve_logs(reg: Registry, bind: tuple[str, int], stop: threading.Event) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(bind)
    sock.settimeout(1.0)
    while not stop.is_set():
        try:
            data, _ = sock.recvfrom(65535)
        except TimeoutError:
            continue
        for line in data.decode("utf-8", "replace").splitlines():
            fields = parse_log_line(line)
            if fields is None:
                reg.inc("ollama_log_lines_total", {"result": "ignored"})
            elif record(reg, fields):
                reg.inc("ollama_log_lines_total", {"result": "parsed"})
            else:
                reg.inc("ollama_log_lines_total", {"result": "invalid"})


def runtime_command(address: tuple[str, int], line: str, timeout: float = 5.0) -> str:
    """HAProxy runtime API 에 명령 하나를 보내고 답을 받는다."""
    with socket.create_connection(address, timeout=timeout) as sock:
        sock.sendall(line.encode() + b"\n")
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return b"".join(chunks).decode()


def server_addresses(stat_csv: str) -> dict[str, str]:
    """`show stat` CSV 에서 서버 이름 → host:port. 여러 백엔드에 같은 이름이 있으면 하나로 본다."""
    rows = csv.DictReader(stat_csv.lstrip("# ").splitlines())
    found: dict[str, str] = {}
    for row in rows:
        name, addr = row.get("svname"), row.get("addr") or ""
        if name in {"FRONTEND", "BACKEND"} or not name or ":" not in addr:
            continue
        found.setdefault(name, addr)
    return found


def loaded_models(ps: dict) -> dict[str, tuple[int, int]]:
    """/api/ps 응답에서 모델 → (size, size_vram)."""
    out: dict[str, tuple[int, int]] = {}
    for item in ps.get("models") or []:
        name = item.get("model") or item.get("name")
        if name:
            out[name] = (int(item.get("size") or 0), int(item.get("size_vram") or 0))
    return out


class ModelWatcher:
    """서버마다 올라간 모델을 추적하고, 새로 올라간 모델을 교체로 센다."""

    def __init__(self, reg: Registry) -> None:
        self.reg = reg
        self.seen: dict[str, set[str]] = {}

    def update(self, server: str, models: dict[str, tuple[int, int]] | None) -> None:
        self.reg.set("ollama_server_up", {"server": server}, 0 if models is None else 1)
        if models is None:
            return
        before = self.seen.get(server)
        for model in models:
            if before is not None and model not in before:
                self.reg.inc(
                    "ollama_model_loads_total", {"server": server, "model": model}
                )
        self.seen[server] = set(models)
        self.reg.clear_gauge("ollama_loaded_model_bytes", {"server": server})
        self.reg.clear_gauge("ollama_loaded_model_vram_bytes", {"server": server})
        for model, (size, vram) in models.items():
            self.reg.set(
                "ollama_loaded_model_bytes", {"server": server, "model": model}, size
            )
            self.reg.set(
                "ollama_loaded_model_vram_bytes",
                {"server": server, "model": model},
                vram,
            )


def fetch_ps(addr: str, timeout: float) -> dict[str, tuple[int, int]] | None:
    try:
        with urllib.request.urlopen(f"http://{addr}/api/ps", timeout=timeout) as resp:
            return loaded_models(json.load(resp))
    except (OSError, ValueError):
        return None


def fetch_status(addr: str, port: int, timeout: float) -> dict | None:
    """서버 주소(host:port)의 호스트에서 상태 에이전트 `/status` JSON 을 읽는다. 에이전트가 없거나 못 읽으면 None."""
    host = addr.rpartition(":")[0]
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/status", timeout=timeout) as resp:
            data = json.load(resp)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def public_status(status: dict | None) -> dict | None:
    """쓰는 쪽(wiki-papers)이 멈춤 판정에 쓰는 칸만 고른다. 윈도우 에이전트의 세션·접속 칸은 내보내지 않는다.
    `working` 이 불리언이 아니면(빈 객체 포함) 상태를 모르는 것으로 본다 — 쉬고 있다고 오판하지 않게."""
    if not status or not isinstance(status.get("working"), bool):
        return None
    runners = [
        {"cpu_percent": r["cpu_percent"]}
        for r in status.get("runners") or []
        if isinstance(r, dict) and isinstance(r.get("cpu_percent"), (int, float))
    ]
    out: dict = {"working": status["working"], "runners": runners}
    for key in ("stuck", "gpu_busy_percent"):
        if key in status:
            out[key] = status[key]
    return out


class ServerBook:
    """poll_servers 가 마지막으로 읽은 서버 이름 → 주소. HTTP 스레드가 읽으므로 dict 를 통째로 바꿔 끼운다."""

    def __init__(self) -> None:
        self.addresses: dict[str, str] = {}


def update_status(reg: Registry, server: str, status: dict | None) -> None:
    """상태 JSON 을 지표로. 못 읽은 서버는 값을 지워 옛 값이 남지 않게 한다."""
    reg.set("ollama_server_status_up", {"server": server}, 0 if status is None else 1)
    for name in ("ollama_server_working", "ollama_server_gpu_busy_percent", "ollama_server_runner_cpu_percent"):
        reg.clear_gauge(name, {"server": server})
    if status is None:
        return
    reg.set("ollama_server_working", {"server": server}, 1 if status.get("working") else 0)
    if isinstance(status.get("gpu_busy_percent"), (int, float)):
        reg.set("ollama_server_gpu_busy_percent", {"server": server}, float(status["gpu_busy_percent"]))
    cpus = [float(r["cpu_percent"]) for r in status.get("runners") or [] if isinstance(r.get("cpu_percent"), (int, float))]
    reg.set("ollama_server_runner_cpu_percent", {"server": server}, max(cpus, default=0.0))


def query_agent(address: tuple[str, int], timeout: float) -> dict | None:
    """windows-agent.ps1 에 stats 를 보내 JSON 한 줄을 받는다. 옛 에이전트는 ready/drain 만 답한다."""
    try:
        with socket.create_connection(address, timeout=timeout) as sock:
            sock.sendall(b"stats\n")
            data = b""
            while b"\n" not in data and len(data) < 4096:
                chunk = sock.recv(1024)
                if not chunk:
                    break
                data += chunk
    except OSError:
        return None
    line = data.decode("utf-8", "replace").strip()
    if line.startswith("{"):
        try:
            return json.loads(line)
        except ValueError:
            return None
    return {"state": line.split()[0]} if line else None


def poll_servers(
    reg: Registry,
    args: argparse.Namespace,
    stop: threading.Event,
    book: ServerBook | None = None,
) -> None:
    runtime = args.socket.rpartition(":")
    address = (runtime[0], int(runtime[2]))
    watcher = ModelWatcher(reg)
    agents = dict(item.split("=", 1) for item in args.agent)
    while not stop.is_set():
        try:
            servers = server_addresses(runtime_command(address, "show stat"))
        except OSError as exc:
            log.warning("runtime API 에 연결하지 못했다: %s", exc)
            servers = {}
        if book is not None:
            book.addresses = servers
        for name, addr in servers.items():
            watcher.update(name, fetch_ps(addr, args.timeout))
            if args.status_port:
                update_status(reg, name, fetch_status(addr, args.status_port, args.timeout))
        for name, target in agents.items():
            host, _, port = target.rpartition(":")
            reply = query_agent((host, int(port)), args.timeout)
            labels = {"server": name, "port": port}
            reg.set("ollama_agent_up", labels, 0 if reply is None else 1)
            if reply is None:
                continue
            reg.set(
                "ollama_agent_drain", labels, 1 if reply.get("state") == "drain" else 0
            )
            for key, metric in (
                ("free_gb", "ollama_agent_free_gb"),
                ("other_gpu_percent", "ollama_agent_other_gpu_percent"),
            ):
                if isinstance(reply.get(key), (int, float)):
                    reg.set(metric, labels, float(reply[key]))
        stop.wait(args.interval)


def make_handler(
    reg: Registry,
    book: ServerBook | None = None,
    status_port: int = 0,
    timeout: float = 3.0,
):
    """`/metrics` 와 `/status[/<서버>]`. 상태는 요청 때 에이전트에서 바로 읽어(캐시 없음) 판정에 쓰는 칸만 준다.
    쓰는 쪽이 서버 목록·주소를 몰라도 라우터에 서버 이름(X-Ollama-Server)으로 물으면 된다."""

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            path = self.path.split("?")[0]
            if path == "/metrics":
                self._send(200, reg.render().encode(), "text/plain; version=0.0.4; charset=utf-8")
                return
            if book is not None and status_port and path == "/status":
                body = {
                    name: public_status(fetch_status(addr, status_port, timeout))
                    for name, addr in book.addresses.items()
                }
                self._send(200, json.dumps(body).encode(), "application/json")
                return
            if book is not None and status_port and path.startswith("/status/"):
                addr = book.addresses.get(urllib.parse.unquote(path[len("/status/"):]))
                status = public_status(fetch_status(addr, status_port, timeout)) if addr else None
                if status is not None:
                    self._send(200, json.dumps(status).encode(), "application/json")
                    return
            self._send(404, b"", "text/plain")

        def log_message(
            self, *_: object
        ) -> None:  # 긁을 때마다 찍히는 접근 로그를 끈다
            return

    return Handler


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="ollama 라우터의 요청 로그(UDP)와 모델 서버의 /api/ps 를 Prometheus 지표로 낸다.",
        epilog=(
            "예:\n"
            "  python3 metrics.py --socket 127.0.0.1:9999 --agent winpc-780m=192.168.0.15:11436\n"
            "  python3 metrics.py --once                 # 서버 상태를 한 번 읽고 지표 텍스트를 stdout 에 낸다\n\n"
            "exit code: 0 정상, 1 runtime API 에 연결 실패(--once)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--socket",
        default="127.0.0.1:9999",
        help="HAProxy runtime API 주소 (기본 127.0.0.1:9999)",
    )
    parser.add_argument(
        "--log-port",
        type=int,
        default=5514,
        help="HAProxy 로그를 받을 UDP 포트 (기본 5514)",
    )
    parser.add_argument(
        "--port", type=int, default=9100, help="/metrics 를 열 포트 (기본 9100)"
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=5.0,
        help="서버 /api/ps 를 읽는 간격(초, 기본 5)",
    )
    parser.add_argument(
        "--timeout", type=float, default=3.0, help="서버·에이전트 응답 상한(초, 기본 3)"
    )
    parser.add_argument(
        "--agent",
        action="append",
        default=[],
        metavar="SERVER=HOST:PORT",
        help="상태 보고 에이전트(windows-agent.ps1) 주소. 여러 번 줄 수 있다",
    )
    parser.add_argument(
        "--status-port",
        type=int,
        default=11437,
        help="서버의 상태 에이전트 /status 포트 (기본 11437, 0 이면 읽지 않음)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="서버 상태를 한 번 읽고 지표를 출력한 뒤 끝낸다",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(message)s")
    reg = build_registry()
    stop = threading.Event()
    if args.once:
        runtime = args.socket.rpartition(":")
        try:
            servers = server_addresses(
                runtime_command((runtime[0], int(runtime[2])), "show stat")
            )
        except OSError as exc:
            log.error("runtime API 에 연결하지 못했다: %s", exc)
            return EXIT_FAIL
        watcher = ModelWatcher(reg)
        for name, addr in servers.items():
            watcher.update(name, fetch_ps(addr, args.timeout))
            if args.status_port:
                update_status(reg, name, fetch_status(addr, args.status_port, args.timeout))
        print(reg.render(), end="")
        return EXIT_OK
    threading.Thread(
        target=serve_logs, args=(reg, ("0.0.0.0", args.log_port), stop), daemon=True
    ).start()
    book = ServerBook()
    threading.Thread(target=poll_servers, args=(reg, args, stop, book), daemon=True).start()
    server = ThreadingHTTPServer(
        ("0.0.0.0", args.port), make_handler(reg, book, args.status_port, args.timeout)
    )
    log.info("로그 UDP :%d, /metrics·/status :%d", args.log_port, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

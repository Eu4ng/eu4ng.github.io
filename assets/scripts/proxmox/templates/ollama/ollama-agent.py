#!/usr/bin/env python3
"""모델 서버(LXC)의 상태를 라우터(HAProxy agent-check)에 알려 주는 작은 서버. 접속마다 한 줄로 답한다.

  ready  요청을 보내도 된다
  drain  새 요청을 보내지 마라(처리 중인 것은 끝까지). GPU 가 멈춰 llama-server 가 커널 안(D 상태)에 걸려 있을 때다 —
         ollama 자체는 /api/version 에 답하므로 헬스체크로는 안 걸러진다(그대로 두면 라우터가 계속 보내
         호출마다 수십 분씩 매달린다)

상태 JSON(:AGENT_STATUS_PORT, 기본 11437, GET /status)도 낸다 — 쓰는 쪽(Ollama 를 부르는 애플리케이션)이 호출 중에 "서버가 지금
계산하고 있는가"를 묻는 용도다. 느린 것과 멈춘 것을 시간으로는 가를 수 없어서(30B prefill 15분, 생성 30분이 정상) 러너의 CPU 사용률과
GPU 사용률을 본다. 계산 중이면 기다리고, 대기도 계산도 아니면 멈춘 것이다. 모델을 올리는 중(러너가 모델 파일을 읽는 중)도 계산 중으로
본다 — 모델 저장소가 NFS 인 서버는 8GB 모델을 1분 넘게 읽는 동안 CPU·GPU 가 놀아 '쉼'으로 보였다.
  {"state": "ready"|"drain", "working": true|false, "runners": [{"pid", "state", "cpu_percent", "read_mib_s"}], "gpu_busy_percent": 0~100|null,
   "stuck": [pid…], "ollama_alive": bool, "sampled_at": epoch}

표준 라이브러리만 쓴다(CT 안에 pip 없음). systemd 가 띄운다(ollama-agent.service). 옵션은 환경 변수:
  AGENT_PORT(기본 11435)  AGENT_STATUS_PORT(기본 11437)  AGENT_STUCK_SECONDS(기본 60: 이만큼 D 상태가 이어지면 멈춘 것)
"""
import json
import os
import socketserver
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("AGENT_PORT", "11435"))
STATUS_PORT = int(os.environ.get("AGENT_STATUS_PORT", "11437"))
STUCK_SECONDS = float(os.environ.get("AGENT_STUCK_SECONDS", "60"))
OLLAMA = os.environ.get("AGENT_OLLAMA_URL", "http://127.0.0.1:11434")
SAMPLE_SECONDS = 5.0           # 러너 CPU 사용률을 재는 간격
WORKING_PERCENT = 5.0          # 러너 CPU 또는 GPU 사용률이 이보다 크면 계산 중
READING_MIB_S = 1.0            # 러너가 초당 이만큼 넘게 읽으면(모델 적재) 계산 중
GPU_BUSY_FILES = ("/sys/class/drm/card0/device/gpu_busy_percent", "/sys/class/drm/renderD128/device/gpu_busy_percent")
_stuck_since: dict[int, float] = {}
_cpu_last: dict[int, tuple[float, float, float]] = {}    # pid -> (누적 CPU 초, 누적 읽은 MiB, 잰 시각)
_sample: dict = {"runners": [], "gpu_busy_percent": None, "sampled_at": 0.0}
_lock = threading.Lock()
CLK_TCK = os.sysconf("SC_CLK_TCK")


def read_mib(pid: int) -> float:
    """프로세스가 읽은 누적 MiB(/proc/<pid>/io 의 rchar — NFS 읽기도 센다). 못 읽으면 0."""
    try:
        with open(f"/proc/{pid}/io") as f:
            for line in f:
                if line.startswith("rchar:"):
                    return int(line.split()[1]) / 1048576
    except (OSError, ValueError):
        pass
    return 0.0


def runner_procs() -> dict[int, tuple[str, float]]:
    """{pid: (상태 문자, 누적 CPU 초)} — llama-server 프로세스들."""
    found = {}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        comm = stat[stat.index("(") + 1:stat.rindex(")")]
        if not comm.startswith("llama-server"):
            continue
        fields = stat[stat.rindex(")") + 2:].split()
        cpu_seconds = (int(fields[11]) + int(fields[12])) / CLK_TCK    # utime + stime
        found[int(pid)] = (fields[0], cpu_seconds)
    return found


def gpu_busy() -> int | None:
    for path in GPU_BUSY_FILES:
        try:
            with open(path) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            continue
    return None


def sample_forever() -> None:
    """SAMPLE_SECONDS 마다 러너 CPU 사용률(%)과 GPU 사용률을 잰다."""
    while True:
        now = time.monotonic()
        runners = []
        procs = runner_procs()
        for pid, (state, cpu) in procs.items():
            read = read_mib(pid)
            prev = _cpu_last.get(pid)
            span = max(now - prev[2], 1e-6) if prev else 1.0
            percent = round((cpu - prev[0]) / span * 100, 1) if prev else 0.0
            reading = round((read - prev[1]) / span, 1) if prev else 0.0
            _cpu_last[pid] = (cpu, read, now)
            runners.append({"pid": pid, "state": state, "cpu_percent": percent, "read_mib_s": reading})
        for pid in list(_cpu_last):
            if pid not in procs:
                del _cpu_last[pid]
        with _lock:
            _sample.update(runners=runners, gpu_busy_percent=gpu_busy(), sampled_at=time.time())
        time.sleep(SAMPLE_SECONDS)


def stuck_runners() -> list[int]:
    """D 상태(uninterruptible)가 STUCK_SECONDS 넘게 이어지면서 CPU 를 쓰지 않는 llama-server 프로세스. GPU 를 기다리는 정상 러너도
    D 를 자주 지나지만 CPU 는 쓴다(실측 37%). 디스크 I/O 로 잠깐 D 가 되는 것도 거른다."""
    now = time.monotonic()
    seen = set()
    with _lock:
        cpu = {r["pid"]: r["cpu_percent"] for r in _sample.get("runners", [])}
        reading = {r["pid"]: r.get("read_mib_s", 0.0) for r in _sample.get("runners", [])}
    for pid, (state, _) in runner_procs().items():
        # NFS 에서 모델을 읽는 러너도 D 상태로 CPU 를 안 쓴다 — 읽고 있으면 멈춘 것이 아니다
        if state == "D" and cpu.get(pid, 0.0) < 1.0 and reading.get(pid, 0.0) < READING_MIB_S:
            seen.add(pid)
            _stuck_since.setdefault(pid, now)
    for pid in list(_stuck_since):
        if pid not in seen:
            del _stuck_since[pid]
    return [pid for pid, since in _stuck_since.items() if now - since >= STUCK_SECONDS]


def ollama_alive() -> bool:
    try:
        with urllib.request.urlopen(f"{OLLAMA}/api/version", timeout=3) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001 — 어떤 이유든 답이 없으면 살아 있지 않은 것
        return False


def state() -> str:
    if stuck_runners():
        return "drain"
    return "ready" if ollama_alive() else "drain"


def status() -> dict:
    stuck = stuck_runners()
    with _lock:
        sample = dict(_sample)
    gpu = sample.get("gpu_busy_percent")
    working = any(r["cpu_percent"] > WORKING_PERCENT or r.get("read_mib_s", 0.0) > READING_MIB_S for r in sample.get("runners", [])) \
        or (gpu is not None and gpu > WORKING_PERCENT)
    alive = ollama_alive()
    return {"state": "drain" if (stuck or not alive) else "ready", "working": working, "stuck": stuck,
            "ollama_alive": alive, **sample}


class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 — http.server 의 이름
        body = json.dumps(status()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # 조용히
        pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.sendall((state() + "\n").encode())
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    if os.environ.get("AGENT_CHECK"):   # 한 번 보고 끝: D 상태인 러너(지속 시간 무관)와 지금 답할 상태
        stuck_runners()
        print(state(), "D 상태 llama-server:", sorted(_stuck_since), f"(서비스는 {STUCK_SECONDS:.0f}초 이어지면 drain)")
        raise SystemExit(0)
    threading.Thread(target=sample_forever, daemon=True).start()
    status_server = ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    threading.Thread(target=status_server.serve_forever, daemon=True).start()
    with Server(("0.0.0.0", PORT), Handler) as server:
        server.serve_forever()

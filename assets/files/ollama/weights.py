#!/usr/bin/env python3
"""HAProxy 서버 가중치를 실제 처리 속도에 맞춰 계속 고친다.

라우터(haproxy.cfg)는 빈 서버 가운데 가중치 비율로 요청을 보낸다. 이 프로그램은 HAProxy 통계에서 서버마다
"요청을 처리하던 시간"과 "그동안 내보낸 응답 바이트"를 모아 속도(바이트/초)를 구하고, 가장 빠른 서버를 256 으로 둔
가중치를 runtime API 로 넣는다. 서버 순서를 설정이나 문서에 적지 않아도 서버 사정이 바뀌면 가중치가 따라간다.
아직 충분히 재지 못한 서버는 가장 높은 가중치를 줘서 요청을 받아 재 볼 수 있게 한다.
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import socket
import sys
import time

EXIT_OK = 0
EXIT_FAIL = 1
MAX_WEIGHT = 256

log = logging.getLogger("weights")


def parse_stat(text: str, backend: str) -> dict[str, dict[str, int]]:
    """`show stat` CSV 에서 그 백엔드의 서버별 현재 연결 수(scur)와 누적 응답 바이트(bout)를 뽑는다."""
    rows = csv.DictReader(text.lstrip("# ").splitlines())
    servers: dict[str, dict[str, int]] = {}
    for row in rows:
        if row.get("pxname") != backend or row.get("svname") in {"FRONTEND", "BACKEND"}:
            continue
        servers[row["svname"]] = {
            "scur": int(row.get("scur") or 0),
            "bout": int(row.get("bout") or 0),
            "weight": int(row.get("weight") or 0),
        }
    return servers


class Meter:
    """서버 하나의 속도. 오래된 측정은 처리 시간 기준 반감기로 흐려진다(쉬는 동안에는 흐려지지 않는다)."""

    def __init__(self, half_life: float) -> None:
        self.half_life = half_life
        self.busy = 0.0
        self.sent = 0.0
        self.last_bout: int | None = None

    def update(self, scur: int, bout: int, elapsed: float) -> None:
        delta = 0 if self.last_bout is None else bout - self.last_bout
        self.last_bout = bout
        delta = max(delta, 0)  # HAProxy 가 다시 시작해 누적값이 0 부터 다시 센다
        if scur <= 0 and delta == 0:
            return
        keep = 0.5 ** (elapsed / self.half_life)
        self.busy = self.busy * keep + elapsed
        self.sent = self.sent * keep + delta

    def speed(self, min_busy: float) -> float | None:
        """바이트/초. 처리 시간이 min_busy 초에 못 미치면 아직 모른다(None)."""
        if self.busy < min_busy or self.sent <= 0:
            return None
        return self.sent / self.busy


def weights(speeds: dict[str, float | None], exponent: float) -> dict[str, int]:
    """가장 빠른 서버를 256 으로 두고 속도 비율의 거듭제곱으로 낮춘다. 속도를 모르는 서버는 256."""
    known = [s for s in speeds.values() if s is not None]
    best = max(known, default=None)
    result = {}
    for name, speed in speeds.items():
        if speed is None or best is None:
            result[name] = MAX_WEIGHT
        else:
            result[name] = max(1, round(MAX_WEIGHT * (speed / best) ** exponent))
    return result


def command(address: tuple[str, int], line: str, timeout: float = 5.0) -> str:
    """runtime API 에 명령 하나를 보내고 답을 받는다."""
    with socket.create_connection(address, timeout=timeout) as sock:
        sock.sendall(line.encode() + b"\n")
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return b"".join(chunks).decode()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="HAProxy 서버 가중치를 서버별 실제 처리 속도(응답 바이트/처리 시간)에 맞춰 계속 고친다.",
        epilog=(
            "예:\n"
            "  python3 weights.py --socket 127.0.0.1:9999 --backend servers\n"
            "  python3 weights.py --once --dry-run      # 한 번 읽고 넣을 가중치만 출력\n\n"
            '출력: 가중치를 바꿀 때마다 stdout 에 JSON 한 줄 {"weights": {...}, "speeds": {...}}\n'
            "exit code: 0 정상 종료(--once), 1 runtime API 에 연결 실패(--once)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--socket",
        default="127.0.0.1:9999",
        help="HAProxy runtime API 주소 (기본 127.0.0.1:9999)",
    )
    parser.add_argument(
        "--backend", default="servers", help="가중치를 고칠 백엔드 이름 (기본 servers)"
    )
    parser.add_argument(
        "--interval", type=float, default=5.0, help="통계를 읽는 간격(초, 기본 5)"
    )
    parser.add_argument(
        "--half-life",
        type=float,
        default=1800.0,
        help="측정이 절반으로 흐려지는 처리 시간(초, 기본 1800)",
    )
    parser.add_argument(
        "--min-busy",
        type=float,
        default=120.0,
        help="속도를 믿기 시작하는 처리 시간(초, 기본 120)",
    )
    parser.add_argument(
        "--exponent",
        type=float,
        default=3.0,
        help="속도 비율에 거는 거듭제곱. 클수록 빠른 서버에 몰린다 (기본 3)",
    )
    parser.add_argument("--once", action="store_true", help="한 번만 읽고 끝낸다")
    parser.add_argument(
        "--dry-run", action="store_true", help="가중치를 넣지 않고 출력만 한다"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(message)s")
    host, _, port = args.socket.rpartition(":")
    address = (host, int(port))
    meters: dict[str, Meter] = {}
    applied: dict[str, int] = {}
    last = time.monotonic()
    while True:
        try:
            stat = parse_stat(command(address, "show stat"), args.backend)
        except OSError as exc:
            log.warning("runtime API 에 연결하지 못했다: %s", exc)
            if args.once:
                return EXIT_FAIL
            time.sleep(args.interval)
            continue
        now = time.monotonic()
        for name, row in stat.items():
            meters.setdefault(name, Meter(args.half_life)).update(
                row["scur"], row["bout"], now - last
            )
        last = now
        speeds = {name: meters[name].speed(args.min_busy) for name in stat}
        wanted = weights(speeds, args.exponent)
        changed = {
            n: w for n, w in wanted.items() if applied.get(n, stat[n]["weight"]) != w
        }
        if changed or args.once:
            if not args.dry_run:
                try:
                    for name, weight in changed.items():
                        command(address, f"set weight {args.backend}/{name} {weight}")
                    applied.update(changed)
                except OSError as exc:
                    log.warning("가중치를 넣지 못했다: %s", exc)
            rounded = {n: None if s is None else round(s, 1) for n, s in speeds.items()}
            print(
                json.dumps({"weights": wanted, "speeds": rounded}, ensure_ascii=False),
                flush=True,
            )
        if args.once:
            return EXIT_OK
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())

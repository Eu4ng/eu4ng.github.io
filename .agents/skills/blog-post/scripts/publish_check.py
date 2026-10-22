#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""발행 전 검증을 차례로 돌린다: 새 글 permalink 부여 → 운영 모드 사이트 빌드 → htmlproofer 링크 검사(CI 와 같은 인자).

저장소 루트에서 실행한다(또는 --root). 새 글에 permalink 를 쓰는 것 말고는 저장소를 바꾸지 않는다. 빌드 폴더는
캐시 폴더 아래 임시 폴더에 만들고 끝나면 지운다(/tmp 가 메모리일 수 있어서). 각 단계 출력은 로그 파일로 남긴다.
htmlproofer 가 `HTML-Proofer finished successfully` 를 낼 때만 ok 다. 표준 라이브러리만 쓴다.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

PROOFER_ARGS = [
    "--disable-external",
    "--ignore-urls",
    r"/^http:\/\/127.0.0.1/,/^http:\/\/0.0.0.0/,/^http:\/\/localhost/",
]
PROOFER_OK = "HTML-Proofer finished successfully"
PERMALINK_RE = re.compile(r"^\[설정 변경\] (.+?) -> permalink: (\S+)")
MAX_LINES = 30
STEP_TIMEOUT = 900

log = logging.getLogger(Path(__file__).stem)


def permalinks_added(output: str) -> list[str]:
    """add_permalinks.py 출력에서 permalink 를 새로 쓴 글을 `파일 → 주소` 로 모은다."""
    return [
        f"{m.group(1)} -> {m.group(2)}"
        for m in map(PERMALINK_RE.match, output.splitlines())
        if m
    ]


def error_lines(output: str) -> list[str]:
    """빌드 출력의 마지막 오류 줄. 태그 `Conflict` 경고는 예전부터 있던 것이라 뺀다."""
    lines = [
        line.rstrip()
        for line in output.splitlines()
        if line.strip() and "Conflict:" not in line
    ]
    marked = [
        line
        for line in lines
        if re.search(r"error|exception|fatal", line, re.IGNORECASE)
    ]
    return (marked or lines)[-MAX_LINES:]


def proofer_failures(output: str) -> list[str]:
    """htmlproofer 실패 목록. `* At <파일>:<줄>:` 과 그 아래 설명 줄을 한 항목으로 묶는다."""
    failures: list[str] = []
    lines = output.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("* "):
            detail = next((n.strip() for n in lines[i + 1 : i + 4] if n.strip()), "")
            failures.append(f"{line[2:].strip()} {detail}".strip())
    if not failures and PROOFER_OK not in output:
        failures = [line for line in lines if line.strip()][-MAX_LINES:]
    return failures[:MAX_LINES]


def run_step(
    argv: list[str], root: Path, log_path: Path, env: dict[str, str] | None = None
) -> tuple[int, str]:
    """명령을 실행해 출력을 로그 파일로 받고, (exit code, 출력)을 돌려준다."""
    with log_path.open("w", encoding="utf-8") as handle:
        try:
            code = subprocess.run(
                argv,
                cwd=root,
                stdout=handle,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                env=env,
                timeout=STEP_TIMEOUT,
                check=False,
            ).returncode
        except FileNotFoundError:
            handle.write(f"실행할 수 없다: {argv[0]}\n")
            code = 127
        except subprocess.TimeoutExpired:
            handle.write(f"{STEP_TIMEOUT}초 안에 끝나지 않았다\n")
            code = 124
    return code, log_path.read_text(encoding="utf-8", errors="replace")


def find_root(start: Path) -> Path | None:
    """_config.yml 과 scripts/add_permalinks.py 가 있는 블로그 저장소 루트를 위로 찾는다."""
    for path in [start, *start.parents]:
        if (path / "_config.yml").is_file() and (
            path / "scripts" / "add_permalinks.py"
        ).is_file():
            return path
    return None


def cache_dir() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "blog-publish-check"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="블로그 발행 전 검증(permalink 부여 → 운영 모드 빌드 → htmlproofer)을 차례로 돌린다.",
        epilog=(
            "예:\n"
            "  uv run --script .agents/skills/blog-post/scripts/publish_check.py\n"
            "  uv run --script <스킬 폴더>/scripts/publish_check.py --root ~/github/<블로그> --keep-site\n\n"
            '출력: {"ok", "stage", "root", "permalinks_added":[파일 -> 주소], "build_errors":[…],\n'
            '       "proofer_failures":[…], "site"(--keep-site), "logs":{permalinks,build,proofer}}\n'
            "  stage: permalinks | build | proofer (실패한 단계) | done\n"
            "exit code: 0 통과, 1 단계 실패, 2 사용법 오류(블로그 저장소가 아님)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--root", type=Path, help="블로그 저장소 루트 (기본: 현재 폴더에서 위로 찾음)")  # fmt: skip
    parser.add_argument("--keep-site", action="store_true", help="빌드 폴더를 지우지 않고 경로를 낸다")  # fmt: skip
    parser.add_argument("--log-dir", type=Path, help="로그 폴더 (기본: 캐시 폴더의 blog-publish-check/logs)")  # fmt: skip
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stderr
    )
    root = find_root((args.root or Path.cwd()).expanduser().resolve())
    if root is None:
        log.error(
            "블로그 저장소 루트를 찾지 못했다(_config.yml·scripts/add_permalinks.py). --root 로 준다"
        )
        return EXIT_USAGE
    log_dir = args.log_dir or cache_dir() / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    cache_dir().mkdir(parents=True, exist_ok=True)
    site = Path(tempfile.mkdtemp(prefix="site-", dir=cache_dir()))
    logs = {k: str(log_dir / f"{k}.log") for k in ("permalinks", "build", "proofer")}
    result: dict[str, object] = {
        "root": str(root),
        "permalinks_added": [],
        "logs": logs,
    }

    def finish(stage: str) -> int:
        ok = stage == "done"
        if args.keep_site:
            result["site"] = str(site)
        else:
            shutil.rmtree(site, ignore_errors=True)
        print(json.dumps({"ok": ok, "stage": stage, **result}, ensure_ascii=False))
        return EXIT_OK if ok else EXIT_FAILED

    log.info("1/3 permalink 부여")
    code, out = run_step([sys.executable, "scripts/add_permalinks.py"], root, Path(logs["permalinks"]))  # fmt: skip
    result["permalinks_added"] = permalinks_added(out)
    if code != 0 or "Error:" in out:
        result["build_errors"] = error_lines(out)
        return finish("permalinks")

    log.info("2/3 사이트 빌드")
    env = {**os.environ, "JEKYLL_ENV": "production"}
    code, out = run_step(
        ["bundle", "exec", "jekyll", "b", "-d", str(site)],
        root,
        Path(logs["build"]),
        env,
    )
    if code != 0:
        result["build_errors"] = error_lines(out)
        return finish("build")

    log.info("3/3 htmlproofer")
    code, out = run_step(
        ["bundle", "exec", "htmlproofer", str(site), *PROOFER_ARGS],
        root,
        Path(logs["proofer"]),
    )
    if code != 0 or PROOFER_OK not in out:
        result["proofer_failures"] = proofer_failures(out)
        return finish("proofer")
    return finish("done")


if __name__ == "__main__":
    sys.exit(main())

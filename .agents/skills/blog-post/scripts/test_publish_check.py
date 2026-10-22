"""publish_check.py 의 출력 파싱 시험. 외부 명령은 실행하지 않는다."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "publish_check", Path(__file__).with_name("publish_check.py")
)
pc = importlib.util.module_from_spec(SPEC)
sys.modules["publish_check"] = pc
SPEC.loader.exec_module(pc)


def test_permalinks_added():
    out = (
        "[설정 변경] 2026-10-01-a.md -> permalink: /posts/41/ (date 아래 위치)\n"
        "처리가 완료되었습니다! 변경/추가된 파일 개수: 1개\n"
    )
    assert pc.permalinks_added(out) == ["2026-10-01-a.md -> /posts/41/"]
    assert (
        pc.permalinks_added("처리가 완료되었습니다! 변경/추가된 파일 개수: 0개\n") == []
    )


def test_error_lines_skip_conflict():
    out = (
        "Conflict: The following destination is shared by multiple files.\n"
        "  Liquid Exception: undefined method in _posts/x.md\n"
        "jekyll build failed\n"
    )
    lines = pc.error_lines(out)
    assert lines == ["  Liquid Exception: undefined method in _posts/x.md"]
    assert all("Conflict" not in line for line in lines)


def test_proofer_failures():
    out = (
        "Running 3 checks\n"
        "For the Links check, the following failures were found:\n\n"
        "* At /site/posts/3/index.html:120:\n\n"
        "  internally linking to /posts/99/, which does not exist\n\n"
        "HTML-Proofer found 1 failure!\n"
    )
    assert pc.proofer_failures(out) == [
        "At /site/posts/3/index.html:120: internally linking to /posts/99/, which does not exist"
    ]
    assert pc.proofer_failures("HTML-Proofer finished successfully.\n") == []


def test_find_root(tmp_path):
    (tmp_path / "_config.yml").write_text("")
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "add_permalinks.py").write_text("")
    sub = tmp_path / "_posts" / "deep"
    sub.mkdir(parents=True)
    assert pc.find_root(sub) == tmp_path
    assert pc.find_root(tmp_path.parent) is None


def test_main_stops_at_build(tmp_path, monkeypatch, capsys):
    (tmp_path / "_config.yml").write_text("")
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "add_permalinks.py").write_text("")
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    calls = []

    def fake_run_step(argv, root, log_path, env=None):
        calls.append(argv)
        if "jekyll" in argv:
            return 1, "  Liquid Exception: boom\n"
        return 0, "처리가 완료되었습니다! 변경/추가된 파일 개수: 0개\n"

    monkeypatch.setattr(pc, "run_step", fake_run_step)
    code = pc.main(["--root", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 1
    assert '"stage": "build"' in out and '"ok": false' in out
    assert len(calls) == 2
    assert not list((tmp_path / "cache" / "blog-publish-check").glob("site-*"))

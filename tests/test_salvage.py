#!/usr/bin/env python3
"""Failure-path salvage (#2007 F3).

Two runs have lost ALL their work to a wall-clock timeout. The defence was
velo-dispatch refusing a brief that lacks an incremental-commit instruction —
the harness ASKING THE MODEL to checkpoint. These pin the version the system
enforces itself.
"""
from __future__ import annotations

import json, pathlib, subprocess, sys, tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "bin"))
from velo_runner_lib import salvage_on_failure, worktree_is_dirty  # noqa: E402

failures: list[str] = []


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        failures.append(label)


def repo(tmp: str, dirty: bool) -> str:
    subprocess.run(["git", "init", "-q", tmp], check=True)
    for k, v in (("user.email", "t@t"), ("user.name", "t")):
        subprocess.run(["git", "-C", tmp, "config", k, v], check=True)
    pathlib.Path(tmp, "base.txt").write_text("base")
    subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
    subprocess.run(["git", "-C", tmp, "commit", "-qm", "base"], check=True)
    if dirty:
        pathlib.Path(tmp, "WORK.md").write_text("half-finished work\n")
    return tmp


class FakeAgent:
    def __init__(self, messages):
        self._engine = type("E", (), {"messages": messages})()


def commits(root: str) -> int:
    r = subprocess.run(["git", "-C", root, "log", "--oneline"], capture_output=True, text=True)
    return len(r.stdout.strip().splitlines())


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        # An implementation run killed mid-edit: the uncommitted work is exactly
        # what vanished twice before.
        r = repo(f"{td}/impl", dirty=True)
        log = f"{td}/impl.log"
        out = salvage_on_failure(root=r, agent=FakeAgent([{"role": "user", "content": "x"}]),
                                 log_path=log, reason="RuntimeError", read_only=False)
        check("implementation: checkpoint made", out["checkpoint"] is not None, True)
        check("implementation: work is committed", commits(r), 2)
        check("implementation: worktree left clean", worktree_is_dirty(r), False)
        check("implementation: transcript written", pathlib.Path(log + ".transcript.json").exists(), True)

        # A review that dirties the tree it reviews is the failure the read-only
        # declaration exists to prevent; salvage must not manufacture it.
        r2 = repo(f"{td}/ro", dirty=True)
        out2 = salvage_on_failure(root=r2, agent=FakeAgent([{"role": "user", "content": "y"}]),
                                  log_path=f"{td}/ro.log", reason="timeout", read_only=True)
        check("read-only: no checkpoint", out2["checkpoint"], None)
        check("read-only: nothing committed", commits(r2), 1)
        check("read-only: transcript still written", out2["transcript"] is not None, True)

        # Nothing to save is not an error.
        r3 = repo(f"{td}/clean", dirty=False)
        out3 = salvage_on_failure(root=r3, agent=FakeAgent([]), log_path=f"{td}/c.log",
                                  reason="x", read_only=False)
        check("clean tree: no empty commit", commits(r3), 1)
        check("clean tree: no transcript for no messages", out3["transcript"], None)

        # Salvage must never mask the original failure.
        out4 = salvage_on_failure(root="/nonexistent-repo", agent=object(),
                                  log_path="/nonexistent/dir/x.log", reason="x", read_only=False)
        check("bad input: returns instead of raising", isinstance(out4, dict), True)

        # The transcript must be readable JSON — it is for a human.
        data = json.loads(pathlib.Path(log + ".transcript.json").read_text())
        check("transcript is valid JSON", isinstance(data, list), True)

    print()
    if failures:
        print(f"FAILED: {len(failures)}: {', '.join(failures)}")
        return 1
    print("all salvage checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

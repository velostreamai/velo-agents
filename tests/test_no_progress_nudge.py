#!/usr/bin/env python3
"""The no-progress continue-nudge in velo-openai-agents-runner.py (#2291).

openai-agents takes any reply without a tool call as the final output, so a
worker that answers in prose mid-task ends the run. On #2291 two velo-local runs
of a 7-step apply plan ended that way with zero edits and were recorded as
successes. The runner now nudges an implementation run whose worktree is
unchanged since it started; these cases pin which finishes are nudged and which
are accepted.

The two predicates are extracted from the runner's source with `ast`, so this
runs without the openai-agents SDK installed.

Run:  .agents/tests/run.sh   (or: python3 .agents/tests/test_no_progress_nudge.py)
"""
from __future__ import annotations

import ast
import pathlib
import re
import subprocess
import sys
import tempfile

RUNNER = pathlib.Path(__file__).resolve().parent.parent / "bin" / "velo-openai-agents-runner.py"
SRC = RUNNER.read_text()

failures: list[str] = []


def check(label: str, got, want) -> None:
    if got == want:
        print(f"  PASS  {label}: {got}")
    else:
        print(f"  FAIL  {label}: got {got!r}, want {want!r}")
        failures.append(label)


def extract(*names: str) -> dict:
    tree = ast.parse(SRC)
    body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    assert len(body) == len(names), f"runner is missing one of {names}"
    ns: dict = {"re": re, "subprocess": subprocess}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(RUNNER), "exec"), ns)
    return ns


ns = extract("worktree_state", "ended_without_progress")
state, stalled = ns["worktree_state"], ns["ended_without_progress"]


def git(repo: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


with tempfile.TemporaryDirectory() as tmp:
    repo = pathlib.Path(tmp)
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "t@t")
    git(repo, "config", "user.name", "t")
    (repo / ".gitignore").write_text("agent.log\n")
    (repo / "f").write_text("base\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    # Dirty at start: an earlier run's uncommitted edit. `git status` shows the
    # same " M f" line however much more is edited, so it cannot measure progress.
    (repo / "f").write_text("base\nearlier run\n")

    start = state(str(repo))
    report = "Summary: plan reviewed, steps 1-7 identified. Next I will apply step 1."

    print("which finishes are nudged")
    (repo / "agent.log").write_text("the runner's own trail\n")
    check("unchanged tree + prose reply -> nudged (the #2291 case)",
          stalled(False, report, start, state(str(repo))), True)
    check("read-only run is never nudged",
          stalled(True, report, start, state(str(repo))), False)
    check("a declared STOP is accepted",
          stalled(False, "Findings so far.\nSTOP: brief requires deleting a test", start, state(str(repo))), False)
    check("a bold **STOP** is accepted",
          stalled(False, "**STOP** — run-commit.sh --fast failed", start, state(str(repo))), False)
    check("git unavailable -> no guess of 'no progress'",
          stalled(False, report, None, state(str(repo))), False)

    print("what counts as progress")
    (repo / "f").write_text("base\nearlier run\nthis run\n")
    check("further edit to an already-dirty file is progress",
          stalled(False, report, start, state(str(repo))), False)
    (repo / "f").write_text("base\nearlier run\n")
    check("reverting that edit is back to no progress",
          stalled(False, report, start, state(str(repo))), True)
    (repo / "new.rs").write_text("fn main() {}\n")
    check("an untracked new file is progress",
          stalled(False, report, start, state(str(repo))), False)
    (repo / "new.rs").unlink()
    git(repo, "commit", "-qam", "run commit")
    check("a commit is progress",
          stalled(False, report, start, state(str(repo))), False)

print("wiring")
# The predicates are only worth anything if the retry loop consults them.
loop = SRC[SRC.index("async def _run_with_empty_final_retry"):SRC.index("res, empty_status = await")]
check("the retry loop calls ended_without_progress", "ended_without_progress(" in loop, True)
check("the retry loop sends NO_PROGRESS_NUDGE", "NO_PROGRESS_NUDGE" in loop, True)
check("the start state is taken before the first Runner.run",
      SRC.index("start_state = worktree_state(a.cwd)") < SRC.index("r = await Runner.run("), True)

if failures:
    print(f"FAILED: {len(failures)} check(s)")
    sys.exit(1)
print("all no-progress nudge checks passed")

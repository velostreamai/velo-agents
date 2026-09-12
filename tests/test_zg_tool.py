#!/usr/bin/env python3
"""ZgQuery: declared as a tool, and honest about every way it can fail.

Measured over 24 runs: our worker used `zg` ZERO times while `velo-impl.md`
documented it six times, and an arm that DECLARED the same capability as a tool
used it on every single run. Prose is not a capability. That is why this exists.

The failure cases matter more than the happy path. A discovery tool that answers
"nothing" when it actually BROKE teaches the agent a false fact about the
repository — the exact mechanic that made a silently-degraded Grep waste 68% of
its calls. So each failure mode gets its own distinguishable message, and each
one is pinned here.

Run:  .agents/tests/run.sh   (or: python3 .agents/tests/test_zg_tool.py)
"""
from __future__ import annotations

import asyncio
import importlib.util
import pathlib
import subprocess
import sys

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

from open_agent_sdk.types import ToolContext  # noqa: E402

failures: list[str] = []


def load(name: str):
    path = BIN / name
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else f': {detail}'}")
    if not ok:
        failures.append(label)


class FakeProc:
    def __init__(self, out="", err="", rc=0):
        self.stdout, self.stderr, self.returncode = out, err, rc


def main() -> int:
    zt = load("velo_zg_tool.py")
    REAL_HOME = zt.pathlib.Path.home   # restored after the missing-binary case
    tool = zt.ZgQueryTool()
    ctx = ToolContext(cwd=".")
    run = lambda inp: asyncio.run(tool.call(inp, ctx))

    print("\ndeclared as a real tool — the whole point")
    check("has a name", tool.name == "ZgQuery", tool.name)
    desc = tool.description
    check("description tells the model to use it FIRST", "USE THIS FIRST" in desc)
    check("description says plain english", "PLAIN ENGLISH" in desc)
    check("description explains WHY over Grep", "before" in desc and "Grep" in desc)
    check("schema requires a question", tool.input_schema.required == ["question"],
          str(tool.input_schema.required))
    check("read-only", tool.is_read_only() is True)
    check("concurrency safe", tool.is_concurrency_safe() is True)

    print("\nhappy path")
    hit = ("#3 src/…/coordinator/mod.rs:4181-4224\n"
           "symbol: function merge_left_with_nulls_batch scope: JoinCoordinator")
    zt.subprocess.run = lambda *a, **k: FakeProc(out=hit)
    zt.shutil.which = lambda n: sys.executable   # a path that really exists
    r = run({"question": "where is the null pad decided"})
    check("returns the hits", "merge_left_with_nulls_batch" in r.content)
    check("not an error", not r.is_error)

    print("\nevery failure is DISTINGUISHABLE from 'no results'")
    # This is the crux. Each of these must be an error the agent can act on,
    # never an empty-looking answer it would read as a fact about the code.
    zt.subprocess.run = lambda *a, **k: FakeProc(
        err="Error: No zvec-grep index found for this workspace\n"
            "Code: ZVEC_GREP.ENGINE.SERVICE.WORKSPACE_INDEX_NOT_FOUND", rc=1)
    r = run({"question": "x"})
    check("missing index is an error", r.is_error)
    check("missing index says it is NOT a claim about the code",
          "NOT a statement about whether the code exists" in r.content, r.content[:90])
    check("missing index names the fallback", "Grep" in r.content)
    check("missing index forbids self-indexing", "not run `zg index`" in r.content)

    zt.subprocess.run = lambda *a, **k: FakeProc(err="boom", rc=2)
    r = run({"question": "x"})
    check("other non-zero exit is an error", r.is_error)
    check("other non-zero reports the detail", "boom" in r.content, r.content[:80])

    def timeout(*a, **k):
        raise subprocess.TimeoutExpired(cmd="zg", timeout=zt.TIMEOUT_SECONDS)
    zt.subprocess.run = timeout
    r = run({"question": "x"})
    check("timeout is an error", r.is_error)
    check("timeout names the fallback", "Grep" in r.content, r.content[:80])

    def oserr(*a, **k):
        raise OSError("exec format error")
    zt.subprocess.run = oserr
    r = run({"question": "x"})
    check("OSError is an error", r.is_error and "exec format error" in r.content)

    zt.shutil.which = lambda n: None
    zt.pathlib.Path.home = staticmethod(lambda: pathlib.Path("/nonexistent"))
    r = run({"question": "x"})
    check("missing binary is an error", r.is_error)
    check("missing binary is distinct from missing index",
          "not installed" in r.content and "index found" not in r.content, r.content[:90])

    print("\na genuine empty result is NOT an error")
    # The one case that legitimately means "nothing matched" must be clearly
    # separated from the five above, and must say the index was present.
    zt.shutil.which = lambda n: sys.executable
    zt.pathlib.Path.home = REAL_HOME   # undo the missing-binary stub above
    zt.subprocess.run = lambda *a, **k: FakeProc(out="   ")
    r = run({"question": "x"})
    check("empty result is not an error", not r.is_error)
    check("empty result confirms the query RAN", "index IS present" in r.content, r.content[:80])

    print("\ninput validation and caps")
    for bad in ({}, {"question": ""}, {"question": "   "}, {"question": None}):
        r = run(bad)
        check(f"rejects {bad!r}", r.is_error, r.content[:60])

    zt.subprocess.run = lambda *a, **k: FakeProc(out="z" * (zt.MAX_OUTPUT_CHARS + 3_000))
    r = run({"question": "x"})
    check("large output truncated", len(r.content) < zt.MAX_OUTPUT_CHARS + 400,
          f"len={len(r.content)}")
    check("truncation is announced", "truncated" in r.content)
    check("truncation states the amount", "3000" in r.content, r.content[-90:])
    check("truncation says hits are ranked", "ranked" in r.content)

    print("\nthe runner actually registers it")
    src = (BIN / "velo_worker_runner.py").read_text()
    check("ZgQuery in allowed_tools", '"ZgQuery"' in src)
    check("tool instance passed to the SDK", "ZgQueryTool()" in src)
    check("listed before Grep, so it reads as the first choice",
          src.index('"ZgQuery"') < src.index('"Grep"'))

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("all ZgQuery checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

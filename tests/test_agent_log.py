#!/usr/bin/env python3
"""agent.log must be written by the RUNNER, for every delegated dispatch (#2075).

velo-impl.md mandates `agent.log` in the worktree root: real timestamps, a WHY
line before each material change, and an AST-GREP-DECISION line for every
structural edit. Its absence is declared a brief violation and a STOP trigger.

Checked 2026-09-20: no delegated dispatch had ever produced one. The #1940
worktree had none, and the only agent.log on the machine was in the main
checkout, last written 2026-08-26, whose 13 AST-GREP-DECISION lines all came
from native Claude agents. The section was dead letter for every worker this
tooling dispatches.

Self-reporting is the wrong fix and the emptiness is the proof: a worker that
skips ast-grep is the same worker that skips logging that it skipped. The
runner already sees every tool call, so it writes the trail from ground truth.
"""
import sys, pathlib, re, tempfile

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"
src = (BIN / "velo-openai-agents-runner.py").read_text()

ns: dict = {"time": __import__("time"), "pathlib": pathlib, "sys": sys}
start = src.index("class AgentLog:")
end = src.index("class BudgetExceeded")
exec(compile(src[start:end], "x", "exec"), ns)
AgentLog = ns["AgentLog"]

FAIL = 0


def check(desc, cond):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
    if not cond:
        FAIL += 1


print("agent.log")

with tempfile.TemporaryDirectory() as d:
    al = AgentLog(d)
    check("writes agent.log into the WORKTREE root, where the policy says",
          (pathlib.Path(d) / "agent.log").exists())

    al.tool("zg_query", 'question="where is X"')
    al.tool("ast_grep", 'pattern="foo", apply=False')
    al.tool("ast_grep", 'pattern="foo", rewrite="bar", apply=True')
    al.why("  renaming foo to bar   because the trait moved\n")
    al.close("success", 3)
    body = (pathlib.Path(d) / "agent.log").read_text()

check("ast_grep calls are counted from ground truth", al.ast_grep_calls == 2)
check("an ast_grep call emits AST-GREP-DECISION", "AST-GREP-DECISION" in body)
# apply=False changes nothing. Calling that "applied" would put a false
# compliance claim in the file that exists to evidence compliance.
check("a dry run is recorded as dry-run, not applied", "result=dry-run" in body)
check("a real apply is recorded as applied", "result=applied" in body)
check("a non-ast_grep tool is logged as TOOL", "TOOL zg_query" in body)
check("assistant reasoning becomes the WHY line", "WHY: renaming foo to bar" in body)
check("WHY collapses whitespace to stay one line",
      "WHY: renaming foo to bar because the trait moved" in body)
check("timestamps are real UTC, not fabricated",
      re.search(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z ", body, re.M) is not None)

# --- the check nothing has ever run ---------------------------------------
with tempfile.TemporaryDirectory() as d:
    al2 = AgentLog(d)
    al2.tool("edit_file", 'file_path="a.rs"')
    al2.tool("edit_file", 'file_path="b.rs"')
    al2.close("success", 2)
    viol = (pathlib.Path(d) / "agent.log").read_text()
check("2+ files with no ast_grep is flagged for review", "VERDICT=review" in viol)
check("the flag cites the policy section it comes from", "trigger-list" in viol)

with tempfile.TemporaryDirectory() as d:
    al3 = AgentLog(d)
    al3.tool("ast_grep", 'pattern="x", apply=True')
    al3.close("success", 5)
    ok = (pathlib.Path(d) / "agent.log").read_text()
check("2+ files WITH ast_grep passes", "VERDICT=ok" in ok)

with tempfile.TemporaryDirectory() as d:
    al4 = AgentLog(d)
    al4.tool("edit_file", 'file_path="only.rs"')
    al4.close("success", 1)
    one = (pathlib.Path(d) / "agent.log").read_text()
check("a ONE-file change without ast_grep is not flagged", "VERDICT=ok" in one)

# --- appended, never truncated: a resumed dispatch is one history ----------
with tempfile.TemporaryDirectory() as d:
    AgentLog(d).emit("FIRST RUN")
    AgentLog(d).emit("SECOND RUN")
    both = (pathlib.Path(d) / "agent.log").read_text()
check("a second run appends rather than truncating",
      "FIRST RUN" in both and "SECOND RUN" in both)

# --- wiring: a trail nothing writes to is the bug this file exists for -----
check("the runner constructs it from the worktree path", "AgentLog(a.cwd)" in src)
check("hooks receive it", "agent_log=agent_log" in src)
check("every tool call is recorded", "self.agent_log.tool(" in src)
check("assistant text is recorded", "self.agent_log.why(" in src)
check("files_changed comes from git, not the worker's report",
      '"git", "-C", a.cwd, "diff", "--name-only"' in src)
check("a failed git diff is surfaced, not recorded as a confident 0",
      "VERDICT=unknown" in src)


# --- searching is not doing -----------------------------------------------
# Found by this check's own first end-to-end run: the worker dry-ran ast_grep
# three times, never passed apply=True, changed nothing, and reported
# status=success. The first version scored that VERDICT=ok purely because
# ast_grep_calls > 0 — counting SEARCHES as evidence of WORK.
with tempfile.TemporaryDirectory() as d:
    al5 = AgentLog(d)
    al5.tool("ast_grep", 'pattern="x", apply=False')
    al5.tool("ast_grep", 'pattern="y", apply=False')
    al5.close("success", 0)
    dry = (pathlib.Path(d) / "agent.log").read_text()
check("all-dry-run with no change is flagged on a write task", "VERDICT=review" in dry)
check("the flag says the edit did not happen", "the edit did not" in dry)
check("applied vs dry_run counts are broken out", "applied=0, dry_run=2" in dry)

# A read-only gate legitimately changes nothing — flagging it would make every
# review run look like a failure.
with tempfile.TemporaryDirectory() as d:
    al6 = AgentLog(d)
    al6.tool("ast_grep", 'pattern="x", apply=False')
    al6.close("success", 0, read_only=True)
    ro = (pathlib.Path(d) / "agent.log").read_text()
check("a read-only run changing nothing is NOT flagged", "VERDICT=ok" in ro)

print()
print("all agent.log checks passed" if FAIL == 0 else f"FAILURES: {FAIL}")
sys.exit(1 if FAIL else 0)

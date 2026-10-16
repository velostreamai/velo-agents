#!/usr/bin/env python3
"""The empty-final-turn retry in velo-openai-agents-runner.py.

Two defects, both found on the Sushi backend (2026-10-10/11), where four
velo-local runs ended `error_empty_final`:

1. The counter never reset. The failure says "4 consecutive turns", but it
   counted empty turns across the WHOLE run: #2440 had three, recovered, did 28
   more tool calls of real work over 21 minutes, and was failed on its fourth.
2. The evidence was thrown away. openai-agents files a chat-completions
   `reasoning_content` under a reasoning item's `summary`; the transcript read
   only `content`, so every reasoning turn was recorded as "" and nothing showed
   what the model wrote on the turns that killed the run.

The retry loop is extracted from the runner's source with `ast` and driven by a
scripted fake Runner, so this runs the real loop without the SDK or a model.

Run:  .agents/tests/run.sh   (or: python3 .agents/tests/test_empty_final_retry.py)
"""
from __future__ import annotations

import ast
import asyncio
import pathlib
import re
import sys
import textwrap
from types import SimpleNamespace as NS

RUNNER = pathlib.Path(__file__).resolve().parent.parent / "bin" / "velo-openai-agents-runner.py"
SRC = RUNNER.read_text()
TREE = ast.parse(SRC)
failures: list[str] = []


def check(label: str, got, want) -> None:
    if got == want:
        print(f"  PASS  {label}: {got!r}")
    else:
        print(f"  FAIL  {label}: got {got!r}, want {want!r}")
        failures.append(label)


def top_level(*names: str) -> dict:
    body = [n for n in TREE.body if isinstance(n, (ast.FunctionDef, ast.Assign)) and (
        getattr(n, "name", None) in names or
        any(isinstance(t, ast.Name) and t.id in names for t in getattr(n, "targets", [])))]
    ns: dict = {"re": re}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(RUNNER), "exec"), ns)
    return ns


# --- the retry loop, driven -----------------------------------------------------
loop_node = next(n for n in ast.walk(TREE)
                 if isinstance(n, ast.AsyncFunctionDef) and n.name == "_run_with_empty_final_retry")
LOOP_SRC = textwrap.dedent(ast.get_source_segment(SRC, loop_node))
consts = top_level("EMPTY_FINAL_RETRIES", "EMPTY_FINAL_NUDGE", "NO_PROGRESS_RETRIES", "NO_PROGRESS_NUDGE")


class MaxTurnsExceeded(Exception):
    pass


def drive(script: list[tuple[int, str]]):
    """Each script step is one Runner.run: (tool calls it makes, final output).
    Returns (status, number of Runner.run calls, nudges logged)."""
    steps = iter(script)
    hooks = NS(turns=0, tool_calls=0)
    logged: list[str] = []

    class Runner:
        @staticmethod
        async def run(agent, inp, max_turns, run_config, hooks):
            calls, final = next(steps)
            hooks.turns += calls + 1
            hooks.tool_calls += calls
            return NS(final_output=final, to_input_list=lambda: [])

    ns = dict(consts, Runner=Runner, MaxTurnsExceeded=MaxTurnsExceeded, hooks=hooks,
              a=NS(max_turns=10_000, cwd="."), agent=None, cfg=None, task="t", budget="",
              log=NS(emit=logged.append), read_only=True, start_state=None,
              worktree_state=lambda cwd: None, ended_without_progress=lambda *a: False)
    exec(LOOP_SRC, ns)
    _, status = asyncio.run(ns["_run_with_empty_final_retry"]())
    return status or "success", sum("empty final turn" in m for m in logged)


N = consts["EMPTY_FINAL_RETRIES"]
print("the empty-final retry counts CONSECUTIVE empty turns")
check(f"{N + 1} empty turns in a row -> error_empty_final",
      drive([(5, "")] + [(0, "")] * N)[0], "error_empty_final")
check("a recovery between empty turns restarts the count (the #2440 shape)",
      drive([(18, ""), (0, ""), (1, ""), (28, ""), (3, "done")]), ("success", 4))
check("recovered after N, then N+1 more in a row still fails",
      drive([(5, "")] + [(0, "")] * (N - 1) + [(4, "")] + [(0, "")] * N)[0], "error_empty_final")
check("a real final answer is accepted at once", drive([(7, "report")]), ("success", 0))

# --- the evidence ---------------------------------------------------------------
item_text = top_level("item_text")["item_text"]
print("item_text reads every place a reply's text can be")
check("reasoning_content lands in summary — read it",
      item_text(NS(type="reasoning", content=None, summary=[NS(text="thinking about it")])),
      "thinking about it")
check("content parts are read",
      item_text(NS(type="reasoning", content=[NS(text="a"), NS(text="b")], summary=[])), "a\nb")
check("a message's output_text parts are read",
      item_text(NS(type="message", content=[NS(text="hello", type="output_text")])), "hello")
check("a function call has no text", item_text(NS(type="function_call", arguments="{}")), "")

print("wiring")
check("the transcript records item_text, not .content alone",
      '"text": item_text(item)[:4000]' in SRC, True)
hook = SRC[SRC.index("async def on_llm_end"):SRC.index("async def on_tool_end")]
check("on_llm_end counts tool calls for the loop", "self.tool_calls += len(calls)" in hook, True)
check("an empty turn logs its reasoning tail", "empty turn reasoning tail" in hook, True)
check("an empty turn scans its reasoning for a tool call",
      "scan_for_leaked_tool_calls(reasoning)" in hook, True)

if failures:
    print(f"FAILED: {len(failures)} check(s)")
    sys.exit(1)
print("all empty-final retry checks passed")

#!/usr/bin/env python3
"""Leaked tool calls must be COUNTED, not assumed absent (#2075).

A leaked tool call is the model emitting its native tool-call syntax as plain
assistant TEXT. The SDK's parser does not recognise it, so the call never runs
— while the turn still reports success. The intended edit does not happen and
the worker says it is done.

The incumbent runtime detected these. The openai-agents runtime, which became
the default in #2088, did not — and the field was hardcoded to `0`, so every
run since 2026-09-12 displayed the absence of evidence as evidence of absence.
velo-record ranks this field above every other outcome and velo-status paints
it red, so three consumers were reading a constant as a measurement.

These checks pin the detector and the two guards that stop it firing on a
worker that legitimately QUOTES the syntax — such as a report about this very
failure mode.
"""
import sys, pathlib, re

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"
src = (BIN / "velo-openai-agents-runner.py").read_text()

ns: dict = {"re": re}
start = src.index("CODE_FENCE_RE = re.compile")
end = src.index("def tool_contract")
exec(compile(src[start:end], "x", "exec"), ns)
scan = ns["scan_for_leaked_tool_calls"]

FAIL = 0


def check(desc, cond):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
    if not cond:
        FAIL += 1


print("leaked tool calls")

# --- the four shapes actually observed in the wild -------------------------
check("DeepSeek fullwidth-pipe DSML is caught", scan("<｜DSML<tool>") == ["DSML"])
check("ASCII-pipe DSML is caught", scan("<|DSML blah") == ["DSML"])
check("Qwen <tool_call> is caught", scan("<tool_call>{}</tool_call>") == ["tool_call"])
check("<function_calls> is caught", "function_calls" in scan("<function_calls>"))
check("<invoke name= is caught", "invoke" in scan('<invoke name="bash">'))

# --- guard 1: quoted syntax is a REPORT, not a leak ------------------------
check("fenced code is not a leak", scan("here is the bug:\n```\n<tool_call>\n```\n") == [])
check("inline code is not a leak", scan("the `<tool_call>` marker leaked") == [])
check("a leak OUTSIDE a fence still counts",
      scan("```\nsafe\n```\nand then <tool_call> bare") == ["tool_call"])

# --- guard 2: prose naming the thing is not the thing ----------------------
check("prose saying DSML is not a leak", scan("the DSML markers are the tell") == [])
check("prose saying invoke is not a leak", scan("we invoke the tool directly") == [])
check("empty text is not a leak", scan("") == [])
check("None-ish text does not crash", scan(None) == [])

# --- wiring: a detector nothing calls is the bug this file exists for ------
check("the counter is initialised", "self.leaked = 0" in src)
check("the counter is incremented", "self.leaked += 1" in src)
check("the scan runs on assistant output", "scan_for_leaked_tool_calls(blob)" in src)
check("a leak is logged, not just counted", "LEAKED TOOL CALL kind=" in src)
check("TOTALS reports the real count", "leaked_tool_calls={hooks.leaked}" in src)
check("TOTALS no longer hardcodes a value",
      "leaked_tool_calls=0 " not in src and "leaked_tool_calls=unmeasured" not in src)
check("re is imported, or the detector NameErrors mid-dispatch",
      re.search(r"^import re$", src, re.M) is not None)

print()
print("all leaked-tool-call checks passed" if FAIL == 0 else f"FAILURES: {FAIL}")
sys.exit(1 if FAIL else 0)

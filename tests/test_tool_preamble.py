#!/usr/bin/env python3
"""The SDK worker must be told its tools do not replace the mandated ones (#2075).

Measured across both dispatch paths, same policy, same repo:

                    ast-grep     zg
    codex   15 runs      894    179
    SDK     14 runs        0      2

Codex runs the mandated commands because the shell is its only interface. The
SDK worker has registered tools that look equivalent, uses those, and never
reaches ast-grep — in a policy that makes it mandatory for any change across two
or more files and a STOP trigger to skip.
"""
import sys, pathlib

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"

# Tool names are parsed from SOURCE, not imported. velo_oai_tools imports
# `agents`, which lives only in the openai-agents venv, while run.sh drives the
# Python suites through a different interpreter. Importing would make this file
# SKIP on the runner everyone actually uses — and a suite that skips is how
# #2134 shipped a regression green. Parsing keeps it running everywhere.
import re
_tools_src = (BIN / "velo_oai_tools.py").read_text()

def _names(var: str) -> list[str]:
    m = re.search(rf"^{var} = \[([^\]]*)\]", _tools_src, re.M)
    assert m, f"{var} not found in velo_oai_tools.py"
    return [n.strip() for n in m.group(1).split(",") if n.strip()]

class T:  # noqa: N801 - stands in for the module
    ALL_TOOLS = _names("ALL_TOOLS")
    READ_ONLY_TOOLS = _names("READ_ONLY_TOOLS")

src = (BIN / "velo-openai-agents-runner.py").read_text()
ns: dict = {}
exec(compile(src[src.index("def tool_preamble"):src.index("async def main")], "x", "exec"), ns)
preamble = ns["tool_preamble"]

FAIL = 0
def check(desc, cond):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
    if not cond:
        FAIL += 1

print("tool preamble")

full = preamble(T.ALL_TOOLS)
ro = preamble(T.READ_ONLY_TOOLS)

# Every registered tool must be named, or the worker cannot know its limits.
for name in T.ALL_TOOLS:
    if name == "bash":
        continue
    check(f"{name} is named", name in full)

# DERIVED, not hardcoded: a read-only run must not be offered write tools.
check("read-only omits edit_file", "edit_file" not in ro)
check("read-only omits write_file", "write_file" not in ro)

# THE POINT (#2075). Measured across both paths on the same policy:
#     codex 15 runs -> ast-grep 894, zg 179
#     SDK   14 runs -> ast-grep   0, zg   2
# The SDK worker substitutes its registered tools for the mandated shell ones.
# An earlier version of this preamble said "prefer your tools over bash", which
# would have entrenched exactly that. These pin the corrected direction.
check("ast-grep is named as mandated", "ast-grep" in full)
check("ast_grep is named as a registered TOOL", "ast_grep and zg_query" in full or "are TOOLS here" in full)
check("bash is not required for the mandated tools", "do not need" in full)
check("grep is explicitly not a structural search",
      "does NOT replace ast_grep" in full)
check("two-file edits are called a violation, not a shortcut",
      "brief violation, not a shortcut" in full)
check("the AST-GREP-DECISION log line is demanded", "AST-GREP-DECISION" in full)
check("zg is offered by either route", "either is fine" in full)

# CLAUDE.md names tools this worker does not have (LSP, Grep, Read, Edit); its
# RULES still bind. Getting that distinction wrong either way is worse than
# silence.
check("CLAUDE.md tool names are disclaimed", "IGNORE tool names" in full)
check("LSP is called out as absent", "no LSP on this runtime" in full)
check("their RULES are still binding", "RULES still apply" in full)

# Wired in, and built from the selected set.
check("appended to the system prompt", "tool_preamble(_tools)" in src)
check("tools selected before the prompt", src.index("_tools = T.") < src.index("system = ("))

print()
print("all tool-preamble checks passed" if FAIL == 0 else f"FAILURES: {FAIL}")
sys.exit(1 if FAIL else 0)

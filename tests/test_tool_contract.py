#!/usr/bin/env python3
"""The tool contract must come BEFORE the policy, not after it (#2075).

Two attempts failed before position was identified as the defect:

  1. "prefer your tools over bash" — wrong direction entirely.
  2. #2166 registered ast_grep as a real tool and APPENDED the guidance after
     the policy. A live deepseek dispatch on #1940 then ran 45 tool calls, all
     bash, ast_grep and zg_query at zero — and zero `ast-grep` even through
     bash. The mandated tooling never entered the run at all.

The measurement that explains it: velo-impl.md is ~45KB and teaches every
mandated tool as a shell command line. Appended after it, the guidance was
3.27% of the system prompt, in last position. So the contract now leads and
translates the policy's shell idioms up front.

Do NOT cite #2088's runtime benchmark here. It measured cost, wall clock and
tool-call COUNT, never which tools, and 0 of its 15 runs used zg at all
because no index existed in those worktrees. An earlier version of this
docstring claimed it as evidence for tool-first prompting. It is not.

Position fixed the bash substitution — 45/45 bash became 14/50, with
read_file and grep taking over — and did NOT fix zg_query, which stayed at
zero. The forced opening move at the end of this file is what addresses that.
"""
import sys, pathlib, re

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"

# Tool names are parsed from SOURCE, not imported. velo_oai_tools imports
# `agents`, which lives only in the openai-agents venv, while run.sh drives the
# Python suites through a different interpreter. Importing would make this file
# SKIP on the runner everyone actually uses — and a suite that skips is how
# #2134 shipped a regression green. Parsing keeps it running everywhere.
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
exec(compile(src[src.index("def tool_contract"):src.index("async def main")], "x", "exec"), ns)
contract = ns["tool_contract"]
reminder = ns["tool_contract_reminder"]

FAIL = 0


def check(desc, cond):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
    if not cond:
        FAIL += 1


print("tool contract")

full = contract(T.ALL_TOOLS)
ro = contract(T.READ_ONLY_TOOLS)

# --- POSITION. The whole point of this change. ---------------------------
# Asserted against the real assembly expression, so reordering the prompt back
# to policy-first fails here.
# .find(), not .index(): a missing call is a FAILURE to report, not a traceback
# that buries the other checks.
i_contract = src.find("+ tool_contract(_tools)")
i_policy = src.find("VELO-IMPL POLICY ================")
i_reminder = src.find("+ tool_contract_reminder(_tools)")
check("contract is wired into the prompt", i_contract >= 0)
check("reminder is wired into the prompt", i_reminder >= 0)
check("contract is emitted BEFORE the policy", 0 <= i_contract < i_policy)
check("a reminder follows the policy", 0 <= i_policy < i_reminder)
check("tools selected before the prompt", src.index("_tools = T.") < src.index("system = ("))

# --- The benchmark shape that is known to work ---------------------------
check("an explicit tool COUNT is given", "You have EXACTLY" in full)
check("the contract leads the block", full.lstrip().startswith("=== YOUR TOOLS"))
check("it tells the worker to read it before the policy", "before the policy" in full)
check("zg_query is named as the starting move", "Start with zg_query" in full)

# --- The translation the #1940 run needed and did not get ----------------
# The policy spells these as command lines; the worker meets them below.
check("the policy's shell spelling is translated", "COMMAND LINE" in full)
check("ast-grep run maps to the tool", re.search(r"ast-grep run .*-> *ast_grep", full) is not None)
check("zg query maps to the tool", re.search(r"zg query .*-> *zg_query", full) is not None)
check("cat/sed map to read_file", re.search(r"cat / sed .*-> *read_file", full) is not None)
check("the bash-stays-in-bash failure is named", "stays in bash" in full)

# --- Substance carried over from the preamble it replaces ----------------
for name in T.ALL_TOOLS:
    if name == "bash":
        continue
    check(f"{name} is named", name in full)
check("read-only omits edit_file", "edit_file" not in ro)
check("read-only omits write_file", "write_file" not in ro)
check("grep is explicitly not a structural search", "does NOT replace ast_grep" in full)
check("two-file edits are called a violation, not a shortcut",
      "brief violation, not a shortcut" in full)
check("the AST-GREP-DECISION log line is demanded", "AST-GREP-DECISION" in full)

# CLAUDE.md names tools this worker does not have (LSP, Grep, Read, Edit); its
# RULES still bind. Getting that distinction wrong either way is worse than
# silence.
check("CLAUDE.md tool names are disclaimed", "IGNORE tool names" in full)
check("LSP is called out as absent", "no LSP on this runtime" in full)
check("their RULES are still binding", "RULES still apply" in full)

# --- The reminder is an anchor, not a second copy -------------------------
rem = reminder(T.ALL_TOOLS)
check("reminder names the mandated tools", "ast_grep" in rem and "zg_query" in rem)
check("reminder stays short", len(rem) < 300)
check("reminder is derived, not hardcoded", "ast_grep" not in reminder(["bash", "grep"]))

# --- Forced opening move (#2075) -----------------------------------------
# Prompt position moved the worker off bash but not onto the index. This is
# the mechanism that does, and reset_tool_choice keeps it to the first call.
check("the first tool call is forced to zg_query",
      'force_first = "zg_query"' in src)
check("only when zg_query is actually registered", '"zg_query" in' in src)
check("not forced on read-only gates", "not read_only and" in src)
check("tool_choice is passed to ModelSettings",
      '"tool_choice": force_first' in src)
check("reset_tool_choice is left at the SDK default (auto after one call)",
      "reset_tool_choice=False" not in src)
check("the forced tool is logged", "force_first_tool=" in src)
# The control arm of the matrix, and an escape hatch if a provider mishandles
# tool_choice. Measured with it: unforced hit ast_grep 8x and produced the same
# correct diff for half the cost, so this is not a vestigial flag.
check("forcing can be turned off", "--no-force-first-tool" in src)
check("the off-switch actually gates the forcing", "not a.no_force_first_tool" in src)

print()
print("all tool-contract checks passed" if FAIL == 0 else f"FAILURES: {FAIL}")
sys.exit(1 if FAIL else 0)

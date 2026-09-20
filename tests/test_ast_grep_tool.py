#!/usr/bin/env python3
"""ast_grep must be a registered TOOL, and must behave (#2075).

Measured across both dispatch paths on the same policy:

                    ast-grep     zg
    codex   15 runs      894    179
    SDK     14 runs        0      2

velo-impl.md MANDATES ast-grep for any rename, signature, match-arm or trait
change across 2+ files, and makes skipping it a STOP trigger. The SDK worker
never ran it — every convenience action had a first-class tool and the mandated
one did not, so it found sites with `grep` and changed them with `edit_file`.
Asking it in prose to reach past its tools into bash is weaker than giving it
the tool.

Loaded from SOURCE with the decorator stripped: importing needs the `agents`
package, which lives only in the openai-agents venv while run.sh drives Python
suites through another. An import would make this SKIP on the interpreter
everyone actually uses, and a skipped suite is how #2134 shipped green.
"""
import pathlib, sys, types

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"
src = (BIN / "velo_oai_tools.py").read_text()

FAIL = 0
def check(desc, cond, extra=""):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} {desc}{'' if cond else ' :: ' + str(extra)[:90]}")
    if not cond:
        FAIL += 1

print("ast_grep tool")

# Registered, and in BOTH sets — a read-only review still needs structural search.
check("ast_grep is in ALL_TOOLS", "ast_grep," in src.split("ALL_TOOLS = [")[1].split("]")[0])
check("ast_grep is in READ_ONLY_TOOLS", "ast_grep" in src.split("READ_ONLY_TOOLS = [")[1].split("]")[0])

# Stub `agents` before exec: the module imports it at top level, and stripping
# the decorator does not remove the import. See the docstring for why importing
# for real is not an option here.
_stub = types.ModuleType("agents")
_stub.function_tool = lambda f: f
sys.modules.setdefault("agents", _stub)

m = types.ModuleType("plain")
exec(compile(src.replace("@function_tool", ""), "velo_oai_tools", "exec"), m.__dict__)
repo = pathlib.Path(__file__).resolve().parents[2]
m.set_cwd(str(repo))
P = "src/velostream/sql/execution/processors"

if not (repo / P).is_dir():
    print(f"  FAIL fixture path missing: {P}")
    sys.exit(1)

# A real structural match.
r = m.ast_grep(pattern="fn $NAME(&self) -> $RET", path=P)
check("finds a real structural match", "src/" in r, r)

# rc=1 means NO MATCHES, not failure — ast-grep follows grep's convention. An
# earlier version reported it as "ast-grep failed", so the zero-match guidance
# never fired and a wrong pattern looked like a broken tool. That is the single
# most common ast-grep mistake and it is otherwise SILENT: with -U a zero-match
# pattern rewrites nothing and reports success.
r = m.ast_grep(pattern="struct ZzNoSuchStructAnywhere { $$$F }", path=P)
check("zero matches is reported as a wrong PATTERN", "0 matches" in r, r)
check("zero matches is not reported as a failure", "failed" not in r, r)

# rc>=2 is a genuine error and must surface.
r = m.ast_grep(pattern="$X", path=P, lang="notalang")
check("a real error still surfaces", "failed" in r and "notalang" in r, r)

# A rewrite must NOT write unless asked: an accidental -U on a live worktree is
# unrecoverable mid-dispatch.
r = m.ast_grep(pattern="$X.len()", rewrite="$X.len()", path=P)
check("rewrite without apply is a dry run", "DRY RUN" in r, r)

# Missing binary must name the policy consequence, not just the error: the
# tempting substitute (grep + edit_file) is the brief violation.
check("absent binary warns against substituting grep + edit_file",
      "brief violation" in src.split("def ast_grep")[1].split("cmd = [")[0])

print()
print("all ast_grep checks passed" if FAIL == 0 else f"FAILURES: {FAIL}")
sys.exit(1 if FAIL else 0)

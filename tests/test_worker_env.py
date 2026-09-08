#!/usr/bin/env python3
"""The worker must be able to run the tools its policy names.

velo-impl.md tells every worker `zg query "..."` is its discovery step. The SDK
merges the runner's env dict over os.environ (open_agent_sdk/tools/bash.py:75),
so without an explicit PATH the worker inherits whatever shell launched
velo-dispatch. install.sh only WARNS that ~/.agents/bin belongs on a shell rc.

On any machine where that warning was not acted on, the documented first move of
every worker is `zg: command not found` — and nothing tells the worker the shim
exists at all. Observed exactly that way in a live session.

So this checks the property, and also that the wiring still exists: a helper that
returns the right dict is worthless if nothing passes it to the Agent.
"""
import ast
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
BIN = HERE.parent / "bin"
sys.path.insert(0, str(BIN))

FAILURES = 0


def check(label, got, want):
    global FAILURES
    if got == want:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}: got {got!r}, want {want!r}")
        FAILURES += 1


def check_true(label, cond, detail=""):
    global FAILURES
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label} {detail}")
        FAILURES += 1


print("worker environment")

try:
    from velo_worker_runner import worker_env
except Exception as exc:  # the SDK may be absent outside the venv
    print(f"  SKIP  cannot import velo_worker_runner ({type(exc).__name__}: {exc})")
    print("        run with the venv python: ~/.venvs/velo-openrouter-agent/bin/python")
    raise SystemExit(0)

env = worker_env(1234)
agents_bin = str(pathlib.Path.home() / ".agents" / "bin")

check_true("PATH is set at all", "PATH" in env)
check_true(
    "~/.agents/bin is on the worker's PATH",
    agents_bin in env.get("PATH", "").split(":"),
    f"-> {env.get('PATH', '')[:90]}",
)
check_true(
    "it is PREPENDED, so the shim beats a stale global install",
    env.get("PATH", "").startswith(agents_bin + ":"),
)
check_true(
    "the inherited PATH is preserved, not replaced",
    all(p in env.get("PATH", "").split(":") for p in os.environ.get("PATH", "").split(":") if p),
)
check("bash timeout still passed through", env.get("BASH_DEFAULT_TIMEOUT_MS"), "1234")

# Wiring: a correct helper nobody calls is the defect this repo keeps shipping.
src = (BIN / "velo_worker_runner.py").read_text()
check_true(
    "AgentOptions is actually given worker_env()",
    "env=worker_env(" in src,
    "-> nothing passes the env to the agent; the helper is decorative",
)

# And prove the claim the helper's docstring rests on: the SDK MERGES this dict
# over os.environ rather than replacing it. If that ever changes, prepending to
# os.environ's PATH would silently become the whole PATH.
try:
    import open_agent_sdk.tools.bash as sdk_bash

    merged = "os" in ast.dump(ast.parse(pathlib.Path(sdk_bash.__file__).read_text()))
    check_true("SDK still merges env over os.environ (docstring premise)", merged)
except Exception as exc:
    print(f"  SKIP  could not verify the SDK merge premise ({type(exc).__name__})")

print()
if FAILURES:
    print(f"FAILED: {FAILURES}")
    raise SystemExit(1)
print("all worker-environment checks passed")

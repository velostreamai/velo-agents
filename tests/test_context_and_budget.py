#!/usr/bin/env python3
"""Context windows and turn budget (#2007 F4/F5)."""
from __future__ import annotations
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "bin"))
from velo_sdk_patches import (CONTEXT_WINDOWS, install_context_windows,  # noqa: E402
                              turn_budget_notice)
from open_agent_sdk.utils.tokens import (get_auto_compact_threshold,  # noqa: E402
                                         get_context_window_size)

failures: list[str] = []
def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok: failures.append(label)

print("context windows (#2007 F4)")
# Before the patch every worker model missed the SDK's Anthropic/OpenAI table and
# took DEFAULT_CONTEXT_WINDOW=200_000, tripping the 187k threshold with ~5x the
# headroom still unused — wasted failed round-trips and a FALSE COMPACT_BOUNDARY
# event, which engine.py:208 yields whether or not anything was compacted.
check("registers", install_context_windows(), True)
for model, want in CONTEXT_WINDOWS.items():
    check(f"{model.split('/')[-1]} window", get_context_window_size(model), want)
    check(f"{model.split('/')[-1]} threshold > 900k",
          get_auto_compact_threshold(model) > 900_000, True)
# An unknown model must still fall back safely, not inherit someone else's window.
check("unknown model keeps the default", get_context_window_size("some/unknown"), 200_000)
check("idempotent", install_context_windows(), True)

print("turn budget (#2007 F5)")
n = turn_budget_notice(150)
check("names the cap", "150 tool-use turns" in n, True)
check("sets a deadline before the cap", "by turn 146" in n, True)
check("says the run is killed", "KILLED" in n, True)
# The failure it exists to prevent: exhausting the budget and returning nothing.
check("prefers a partial report to silence", "silence is not" in n, True)
small = turn_budget_notice(20)
check("small budget reserves less", "by turn 18" in small, True)
check("never a non-positive deadline", "by turn 1," in turn_budget_notice(1), True)

print()
if failures:
    print(f"FAILED: {len(failures)}: {', '.join(failures)}"); raise SystemExit(1)
print("all context/budget checks passed")

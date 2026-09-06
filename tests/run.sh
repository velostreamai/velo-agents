#!/bin/bash
# Run the .agents tooling tests (#1992).
#
#   ./.agents/tests/run.sh
#
# These exist because `velo-gate` classifies an .agents/-only diff as
# "tooling-only, no gate required", so this code gets no review and no CI by
# default. That default is wrong for the recorder in particular: a bug in it does
# not crash anything, it silently writes a wrong number into the records that
# worker-routing decisions are later read from. Every case pinned here is a
# defect that already shipped once and passed inspection.
#
# Not wired into run-commit.sh: that gate builds the Rust workspace, and these
# are seconds-long checks on shell and Python. Run them when touching .agents/.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The runners import open_agent_sdk, which lives in the worker venv rather than
# the system interpreter.
PY="${VELO_TEST_PYTHON:-$HOME/.venvs/velo-openrouter-agent/bin/python}"
[[ -x "$PY" ]] || { echo "python with open_agent_sdk not found at $PY"; echo "set VELO_TEST_PYTHON"; exit 1; }

RC=0
echo "── sdk patches ────────────────────────────────────────"
"$PY" "$HERE/test_sdk_patches.py" || RC=1
echo
echo "── runner accounting ──────────────────────────────────"
"$PY" "$HERE/test_runner_accounting.py" || RC=1
echo
echo "── record writing ─────────────────────────────────────"
bash "$HERE/test_record.sh" || RC=1

echo
[[ $RC -eq 0 ]] && echo "✅ .agents tests passed" || echo "❌ .agents tests FAILED"
exit $RC

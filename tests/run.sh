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
echo "── fail_to_pass validation ────────────────────────────"
bash "$HERE/test_fail_to_pass.sh" || RC=1
echo
echo "── velo-status ────────────────────────────────────────"
bash "$HERE/test_status.sh" || RC=1
bash "$HERE/test_zg_hidden.sh" || RC=1
echo
echo "── spec review loop ───────────────────────────────────"
bash "$HERE/test_spec_review.sh" || RC=1
echo
echo "── discovery-index exclusion ──────────────────────────"
bash "$HERE/test_index_exclude.sh" || RC=1
echo
echo "── gate health (end-to-end) ───────────────────────────"
bash "$HERE/test_gate_health.sh" || RC=1
bash "$HERE/test_gate_post_sha.sh" || RC=1
bash "$HERE/test_gate_template_guard.sh" || RC=1
bash "$HERE/test_spec_review_worker.sh" || RC=1
bash "$HERE/test_gate_routing.sh" || RC=1
echo
echo "── dispatch preflight (end-to-end) ────────────────────"
bash "$HERE/test_dispatch_preflight.sh" || RC=1
echo
echo "── brief fields ───────────────────────────────────────"
bash "$HERE/test_brief_fields.sh" || RC=1
echo
echo "── sdk patches ────────────────────────────────────────"
"$PY" "$HERE/test_sdk_patches.py" || RC=1
echo
echo "── context + turn budget ──────────────────────────────"
"$PY" "$HERE/test_context_and_budget.py" || RC=1
echo
echo "── failure salvage ────────────────────────────────────"
"$PY" "$HERE/test_salvage.py" || RC=1

echo "── worker environment ─────────────────────────────────"
"$PY" "$HERE/test_worker_env.py" || RC=1
echo
echo
echo "── runner accounting ──────────────────────────────────"
"$PY" "$HERE/test_runner_accounting.py" || RC=1
echo
echo "── tool-input logging ─────────────────────────────────"
"$PY" "$HERE/test_tool_input_log.py" || RC=1
echo
echo "── runner path resolution ─────────────────────────────"
bash "$HERE/test_runner_path.sh" || RC=1
echo
echo "── install --check drift (pyc artifacts) ──────────────"
bash "$HERE/test_install_check.sh" || RC=1
echo
echo "── zg discovery tool ──────────────────────────────────"
"$PY" "$HERE/test_zg_tool.py" || RC=1
echo
echo "── merge gate staleness ───────────────────────────────"
bash "$HERE/test_merge_gates.sh" || RC=1
echo
echo "── routing: label vs spec ─────────────────────────────"
bash "$HERE/test_routing.sh" || RC=1
echo
echo "── policy single source ───────────────────────────────"
bash "$HERE/test_policy_single_source.sh" || RC=1
echo
echo "── openai-agents backend ──────────────────────────────"
bash "$HERE/test_oai_backend.sh" || RC=1
echo
echo "── record writing ─────────────────────────────────────"
bash "$HERE/test_record.sh" || RC=1
bash "$HERE/test_billed_invariant.sh" || RC=1
echo
echo "── tool preamble ─────────────────────────────────────"
"$PY" "$HERE/test_tool_contract.py" || RC=1
"$PY" "$HERE/test_leaked_tool_calls.py" || RC=1
"$PY" "$HERE/test_agent_log.py" || RC=1
python3 "$HERE/test_ast_grep_tool.py" || RC=1
bash "$HERE/test_history_routing.sh" || RC=1

echo
[[ $RC -eq 0 ]] && echo "✅ .agents tests passed" || echo "❌ .agents tests FAILED"
exit $RC

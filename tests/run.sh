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
# Each failing suite is named again at the end. The bare FAILED line used to be
# the only summary, so `run.sh | tail` showed passing suites above it and the
# failure scrolled out of view: a worker re-ran the whole 8-minute suite just to
# find which one had failed.
FAILED=()
fail() { RC=1; FAILED+=("$1"); }
echo "── fail_to_pass validation ────────────────────────────"
bash "$HERE/test_fail_to_pass.sh" || fail test_fail_to_pass.sh
echo
echo "── velo-status ────────────────────────────────────────"
bash "$HERE/test_status.sh" || fail test_status.sh
bash "$HERE/test_zg_hidden.sh" || fail test_zg_hidden.sh
echo
echo "── spec review loop ───────────────────────────────────"
bash "$HERE/test_spec_review.sh" || fail test_spec_review.sh
echo
echo "── discovery-index exclusion ──────────────────────────"
bash "$HERE/test_index_exclude.sh" || fail test_index_exclude.sh
echo
echo "── gate health (end-to-end) ───────────────────────────"
bash "$HERE/test_gate_health.sh" || fail test_gate_health.sh
bash "$HERE/test_second_opinion.sh" || fail test_second_opinion.sh
bash "$HERE/test_local_backend.sh" || fail test_local_backend.sh
bash "$HERE/test_llama_server_run.sh" || fail test_llama_server_run.sh
bash "$HERE/test_gate_post_sha.sh" || fail test_gate_post_sha.sh
bash "$HERE/test_gate_post_once.sh" || fail test_gate_post_once.sh
bash "$HERE/test_gate_template_guard.sh" || fail test_gate_template_guard.sh
bash "$HERE/test_spec_review_worker.sh" || fail test_spec_review_worker.sh
bash "$HERE/test_gate_routing.sh" || fail test_gate_routing.sh
bash "$HERE/test_gate_check_code_mode.sh" || fail test_gate_check_code_mode.sh
bash "$HERE/test_gate_substitution.sh" || fail test_gate_substitution.sh
bash "$HERE/test_gate_run.sh" || fail test_gate_run.sh
bash "$HERE/test_gate_finish.sh" || fail test_gate_finish.sh
echo
echo "── dispatch preflight (end-to-end) ────────────────────"
bash "$HERE/test_dispatch_preflight.sh" || fail test_dispatch_preflight.sh
echo
echo "── check-code skill inlining (#2301) ──────────────────"
bash "$HERE/test_check_code_skill.sh" || fail test_check_code_skill.sh
echo
echo "── skill inlining (#2301) ─────────────────────────────"
# velo_skills has no SDK dependency, so plain python3 runs it — same interpreter
# install.sh copies it to, which is the one whose behaviour matters here.
python3 "$HERE/test_skill_inlining.py" || fail test_skill_inlining.py
echo
echo "── --wait / detached-work enforcement ──────────────────"
bash "$HERE/test_require_wait_hook.sh" || fail test_require_wait_hook.sh
bash "$HERE/test_dispatch_wait.sh" || fail test_dispatch_wait.sh
bash "$HERE/test_pr_gate_wait.sh" || fail test_pr_gate_wait.sh
bash "$HERE/test_pr_gate_launch.sh" || fail test_pr_gate_launch.sh
echo
echo "── brief fields ───────────────────────────────────────"
bash "$HERE/test_brief_fields.sh" || fail test_brief_fields.sh
echo
echo "── sdk patches ────────────────────────────────────────"
"$PY" "$HERE/test_sdk_patches.py" || fail test_sdk_patches.py
echo
echo "── context + turn budget ──────────────────────────────"
"$PY" "$HERE/test_context_and_budget.py" || fail test_context_and_budget.py
echo
echo "── failure salvage ────────────────────────────────────"
"$PY" "$HERE/test_salvage.py" || fail test_salvage.py

echo "── worker environment ─────────────────────────────────"
"$PY" "$HERE/test_worker_env.py" || fail test_worker_env.py
echo
echo
echo "── runner accounting ──────────────────────────────────"
"$PY" "$HERE/test_runner_accounting.py" || fail test_runner_accounting.py
echo
echo "── tool-input logging ─────────────────────────────────"
"$PY" "$HERE/test_tool_input_log.py" || fail test_tool_input_log.py
echo
echo "── runner path resolution ─────────────────────────────"
bash "$HERE/test_runner_path.sh" || fail test_runner_path.sh
echo
echo "── install --check drift (pyc artifacts) ──────────────"
bash "$HERE/test_install_check.sh" || fail test_install_check.sh
echo
echo "── zg discovery tool ──────────────────────────────────"
"$PY" "$HERE/test_zg_tool.py" || fail test_zg_tool.py
echo
echo "── merge gate staleness ───────────────────────────────"
bash "$HERE/test_merge_gates.sh" || fail test_merge_gates.sh
bash "$HERE/test_merge_once.sh" || fail test_merge_once.sh
echo
echo "── routing: label vs spec ─────────────────────────────"
bash "$HERE/test_routing.sh" || fail test_routing.sh
echo
echo "── policy single source ───────────────────────────────"
bash "$HERE/test_policy_single_source.sh" || fail test_policy_single_source.sh
echo
echo "── openai-agents backend ──────────────────────────────"
bash "$HERE/test_oai_backend.sh" || fail test_oai_backend.sh
python3 "$HERE/test_no_progress_nudge.py" || fail test_no_progress_nudge.py
# The SDK-wiring half needs the openai-agents venv; with plain python3 it skips.
OAI_PY="${VELO_OAI_PY:-$HOME/.venvs/velo-openai-agents/bin/python}"
[[ -x "$OAI_PY" ]] || OAI_PY=python3
"$OAI_PY" "$HERE/test_context_compaction.py" || fail test_context_compaction.py
echo
echo "── record writing ─────────────────────────────────────"
bash "$HERE/test_record.sh" || fail test_record.sh
bash "$HERE/test_billed_invariant.sh" || fail test_billed_invariant.sh
echo
echo "── orchestrator daemon (#2285 PR2 + Round 2 integration) ─"
bash "$HERE/test_orchestrd.sh" || fail test_orchestrd.sh
bash "$HERE/test_attention.sh" || fail test_attention.sh
bash "$HERE/test_watch_attention.sh" || fail test_watch_attention.sh
bash "$HERE/test_session_start_attention.sh" || fail test_session_start_attention.sh
echo
echo "── tool preamble ─────────────────────────────────────"
"$PY" "$HERE/test_tool_contract.py" || fail test_tool_contract.py
"$PY" "$HERE/test_leaked_tool_calls.py" || fail test_leaked_tool_calls.py
"$PY" "$HERE/test_agent_log.py" || fail test_agent_log.py
python3 "$HERE/test_ast_grep_tool.py" || fail test_ast_grep_tool.py
bash "$HERE/test_history_routing.sh" || fail test_history_routing.sh
bash "$HERE/test_run_sh_summary.sh" || fail test_run_sh_summary.sh

echo
if [[ $RC -eq 0 ]]; then
  echo "✅ .agents tests passed"
else
  echo "❌ .agents tests FAILED (${#FAILED[@]}): ${FAILED[*]}"
fi
exit $RC

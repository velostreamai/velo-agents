#!/bin/bash
# Run the .agents tooling tests (#1992).
#
#   ./tests/run.sh               every suite, one after another
#   ./tests/run.sh --shard I/N   only the I-th of N weight-balanced slices of the suites (1 <= I <= N), so CI can spread them
#                                over N runners; the slices partition the suites (tests/shard-plan.sh, held to that by
#                                tests/test_run_sh_shards.sh), so running all N of them runs every suite exactly once
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
# The slice is planned before anything is created, so a bad request leaves nothing behind. It is an argument and not an
# environment variable on purpose: every suite inherits the environment, and the two that run run.sh itself (on stubs) must see
# a whole run unless they ask for a slice.
SHARD=""
SHARD_SUITES=""
ALL_SUITES=""
case "${1:-}" in
  "") ;;
  --shard)
    SHARD="${2:-}"
    [[ -n $SHARD && $# -eq 2 ]] || { echo "usage: run.sh [--shard I/N]" >&2; exit 2; }
    SHARD_SUITES=$("$HERE/shard-plan.sh" "$SHARD" "$HERE/run.sh") || exit 1
    ALL_SUITES=$("$HERE/shard-plan.sh" --all "$HERE/run.sh") || exit 1
    ;;
  *) echo "usage: run.sh [--shard I/N]" >&2; exit 2 ;;
esac
# Test mode: production waits shortened for stubs, inherited by every suite.
. "$HERE/test-timeouts.sh"
# A private agent-state dir per run. Several agents run this suite at once on one
# host; a suite that forgets its own sandbox must not write the live
# ~/.agents/state the dispatched workers read, nor another run's.
#
# Temp files go in THIS worktree, not the system temp dir: every mktemp (and
# python tempfile) in every suite follows TMPDIR. Two agents' runs can never
# share a path, a leftover shows which worktree and run made it, and removing
# the worktree removes it. Gitignored (.agents/tests/.tmp/) so a run never
# makes the tree look dirty to velo-dispatch's records or the zg index.
RUN_TMP="$HERE/.tmp/run-$$"
rm -rf "$RUN_TMP"; mkdir -p "$RUN_TMP"
export TMPDIR="$RUN_TMP"
RUN_STATE="$RUN_TMP/agent-state"
export VELO_STATE="$RUN_STATE/state"
mkdir -p "$VELO_STATE"

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
# Every suite's wall time is printed after it and the slowest are listed at the
# end, so a slow run can be explained from its own log instead of a re-run.
# SECONDS, not EPOCHREALTIME: /bin/bash on macOS is 3.2.
TIMES=()
# Wall-clock UTC start and end too, so a suite's lines can be matched against a
# worker's dispatch log or the llama-server log from the same minutes.
utc() { date -u +%H:%M:%SZ; }
RUN_START=$(date -u +%FT%TZ)
echo "run.sh started $RUN_START"
SHARD_PLANNED=0
RAN=0
if [[ -n $SHARD ]]; then
  SHARD_PLANNED=$(grep -c . <<<"$SHARD_SUITES")
  echo "shard $SHARD: $SHARD_PLANNED suites; every other suite belongs to another shard"
  sed 's/^/  /' <<<"$SHARD_SUITES"
fi
# Each suite runs in its own process group (set -m gives a background job its own
# pgid). Anything still in that group once the suite has exited is a leaked fake
# or poll loop: it is named, killed, and the suite fails. A leaked loop from one
# suite once ran for 43 minutes and slowed the local model it shared cores with.
CUR=""
trap '[[ -n $CUR ]] && kill -- -"$CUR" 2>/dev/null; exit 130' INT TERM
trap 'rm -rf "$RUN_TMP"' EXIT
suite() {  # <name> <command...>
  # A sharded run starts only the suites of its slice; the rest are some other runner's. A suite the plan has never heard of
  # (a call that does not start its line, where tests/shard-plan.sh cannot see it) would belong to NO runner and silently never
  # run, so it fails here instead.
  if [[ -n $SHARD && $'\n'"$SHARD_SUITES"$'\n' != *$'\n'"$1"$'\n'* ]]; then
    if [[ $'\n'"$ALL_SUITES"$'\n' != *$'\n'"$1"$'\n'* ]]; then
      echo "  FAIL $1 is called where tests/shard-plan.sh cannot see it (a suite call must start its line), so no shard would run it"
      RC=1; FAILED+=("$1")
    fi
    return 0
  fi
  RAN=$((RAN + 1))
  local name=$1 t0=$SECONDS w0 rc left; w0=$(utc); shift
  set -m; "$@" & CUR=$!; set +m
  wait "$CUR"; rc=$?
  left=$(pgrep -g "$CUR" 2>/dev/null)
  [[ -n $left ]] && { sleep 0.5; left=$(pgrep -g "$CUR" 2>/dev/null); }
  if [[ -n $left ]]; then
    echo "  LEAK $name left $(wc -l <<<"$left" | tr -d ' ') process(es) running:"
    ps -o pid=,command= -p "$(tr '\n' ',' <<<"$left" | sed 's/,$//')" | cut -c1-140 | sed 's/^/    /'
    kill -- -"$CUR" 2>/dev/null
    rc=1
  fi
  CUR=""
  [[ $rc -eq 0 ]] || { RC=1; FAILED+=("$name"); }
  local dt=$((SECONDS - t0))
  echo "  [${dt}s $w0-$(utc)] $name"
  TIMES+=("$dt $name")
}
echo "── fail_to_pass validation ────────────────────────────"
suite test_fail_to_pass.sh bash "$HERE/test_fail_to_pass.sh"
echo
echo "── velo-status ────────────────────────────────────────"
suite test_status.sh bash "$HERE/test_status.sh"
suite test_zg_hidden.sh bash "$HERE/test_zg_hidden.sh"
suite test_native_workers.sh bash "$HERE/test_native_workers.sh"
echo
echo "── spec review loop ───────────────────────────────────"
suite test_spec_review.sh bash "$HERE/test_spec_review.sh"
suite test_spec_review_lint.sh bash "$HERE/test_spec_review_lint.sh"
echo
echo "── discovery-index exclusion ──────────────────────────"
suite test_index_exclude.sh bash "$HERE/test_index_exclude.sh"
echo
echo "── gate health (end-to-end) ───────────────────────────"
suite test_gate_health.sh bash "$HERE/test_gate_health.sh"
suite test_second_opinion.sh bash "$HERE/test_second_opinion.sh"
suite test_local_backend.sh bash "$HERE/test_local_backend.sh"
suite test_llama_server_run.sh bash "$HERE/test_llama_server_run.sh"
suite test_llm_bench.sh bash "$HERE/test_llm_bench.sh"
suite test_gate_post_sha.sh bash "$HERE/test_gate_post_sha.sh"
suite test_gate_post_once.sh bash "$HERE/test_gate_post_once.sh"
suite test_gate_template_guard.sh bash "$HERE/test_gate_template_guard.sh"
suite test_spec_review_worker.sh bash "$HERE/test_spec_review_worker.sh"
suite test_gate_routing.sh bash "$HERE/test_gate_routing.sh"
suite test_gate_check_code_mode.sh bash "$HERE/test_gate_check_code_mode.sh"
suite test_gate_substitution.sh bash "$HERE/test_gate_substitution.sh"
suite test_gate_comments.sh bash "$HERE/test_gate_comments.sh"
suite test_gate_run.sh bash "$HERE/test_gate_run.sh"
suite test_gate_finish.sh bash "$HERE/test_gate_finish.sh"
suite test_gate_no_silent_skip.sh bash "$HERE/test_gate_no_silent_skip.sh"
suite test_gate_sweep.sh bash "$HERE/test_gate_sweep.sh"
echo
echo "── dispatch preflight (end-to-end) ────────────────────"
suite test_dispatch_preflight.sh bash "$HERE/test_dispatch_preflight.sh"
echo
echo "── VELO_REPO: the tools on another repo (velo-agents#17) ─"
suite test_repo_env.sh bash "$HERE/test_repo_env.sh"
suite test_repo_env_workers.sh bash "$HERE/test_repo_env_workers.sh"
echo
echo "── check-code skill inlining (#2301) ──────────────────"
suite test_check_code_skill.sh bash "$HERE/test_check_code_skill.sh"
echo
echo "── skill inlining (#2301) ─────────────────────────────"
# velo_skills has no SDK dependency, so plain python3 runs it — same interpreter
# install.sh copies it to, which is the one whose behaviour matters here.
suite test_skill_inlining.py python3 "$HERE/test_skill_inlining.py"
echo
echo "── --wait / detached-work enforcement ──────────────────"
suite test_require_wait_hook.sh bash "$HERE/test_require_wait_hook.sh"
suite test_dispatch_wait.sh bash "$HERE/test_dispatch_wait.sh"
suite test_pr_gate_wait.sh bash "$HERE/test_pr_gate_wait.sh"
suite test_pr_gate_launch.sh bash "$HERE/test_pr_gate_launch.sh"
echo
echo "── velo-task guard hooks (vanth prune/restore, pgrep wait loops) ──"
suite test_velo_task_hooks.sh bash "$HERE/test_velo_task_hooks.sh"
echo
echo "── velo-task B14: bash 3.2 sweep ─────────────────────"
suite test_velo_task_bash32.sh bash "$HERE/test_velo_task_bash32.sh"
echo
echo "── brief fields ───────────────────────────────────────"
suite test_brief_fields.sh bash "$HERE/test_brief_fields.sh"
suite test_brief_ste.sh bash "$HERE/test_brief_ste.sh"
suite test_brief_sweep.sh bash "$HERE/test_brief_sweep.sh"
echo
echo "── fence grammar parity (brief_prose awk vs extract_attack python) ──"
suite test_fence_parity.py python3 "$HERE/test_fence_parity.py"
echo
echo "── sdk patches ────────────────────────────────────────"
suite test_sdk_patches.py "$PY" "$HERE/test_sdk_patches.py"
echo
echo "── context + turn budget ──────────────────────────────"
suite test_context_and_budget.py "$PY" "$HERE/test_context_and_budget.py"
echo
echo "── failure salvage ────────────────────────────────────"
suite test_salvage.py "$PY" "$HERE/test_salvage.py"

echo "── worker environment ─────────────────────────────────"
suite test_worker_env.py "$PY" "$HERE/test_worker_env.py"
echo
echo
echo "── runner accounting ──────────────────────────────────"
suite test_runner_accounting.py "$PY" "$HERE/test_runner_accounting.py"
suite test_transient_retry.py python3 "$HERE/test_transient_retry.py"
echo
echo "── tool-input logging ─────────────────────────────────"
suite test_tool_input_log.py "$PY" "$HERE/test_tool_input_log.py"
echo
echo "── runner path resolution ─────────────────────────────"
suite test_runner_path.sh bash "$HERE/test_runner_path.sh"
echo
echo "── install --check drift (pyc artifacts) ──────────────"
suite test_install_check.sh bash "$HERE/test_install_check.sh"
echo
echo "── velo-task v2 (install, daemon, run/status/wait/cancel, hooks) ──"
suite test_velo_task.sh bash "$HERE/test_velo_task.sh"
echo
echo "── zg discovery tool ──────────────────────────────────"
suite test_zg_tool.py "$PY" "$HERE/test_zg_tool.py"
echo
echo "── merge gate staleness ───────────────────────────────"
suite test_merge_gates.sh bash "$HERE/test_merge_gates.sh"
suite test_merge_once.sh bash "$HERE/test_merge_once.sh"
suite test_merge_aggregate.sh bash "$HERE/test_merge_aggregate.sh"
echo
echo "── ci rollup: the latest run of each check ────────────"
suite test_ci_rollup_latest.sh bash "$HERE/test_ci_rollup_latest.sh"
echo
echo "── routing: label vs spec ─────────────────────────────"
suite test_routing.sh bash "$HERE/test_routing.sh"
echo
echo "── policy single source ───────────────────────────────"
suite test_policy_single_source.sh bash "$HERE/test_policy_single_source.sh"
echo
echo "── openai-agents backend ──────────────────────────────"
suite test_oai_backend.sh bash "$HERE/test_oai_backend.sh"
suite test_no_progress_nudge.py python3 "$HERE/test_no_progress_nudge.py"
suite test_empty_final_retry.py python3 "$HERE/test_empty_final_retry.py"
# The SDK-wiring half needs the openai-agents venv; with plain python3 it skips.
OAI_PY="${VELO_OAI_PY:-$HOME/.venvs/velo-openai-agents/bin/python}"
[[ -x "$OAI_PY" ]] || OAI_PY=python3
suite test_context_compaction.py "$OAI_PY" "$HERE/test_context_compaction.py"
echo
echo "── record writing ─────────────────────────────────────"
suite test_record.sh bash "$HERE/test_record.sh"
suite test_billed_invariant.sh bash "$HERE/test_billed_invariant.sh"
echo
echo "── orchestrator daemon (#2285 PR2 + Round 2 integration) ─"
suite test_orchestrd.sh bash "$HERE/test_orchestrd.sh"
suite test_attention.sh bash "$HERE/test_attention.sh"
suite test_verdict_of.sh bash "$HERE/test_verdict_of.sh"
suite test_watch_attention.sh bash "$HERE/test_watch_attention.sh"
suite test_session_start_attention.sh bash "$HERE/test_session_start_attention.sh"
echo
echo "── tool preamble ─────────────────────────────────────"
suite test_tool_contract.py "$PY" "$HERE/test_tool_contract.py"
suite test_leaked_tool_calls.py "$PY" "$HERE/test_leaked_tool_calls.py"
suite test_agent_log.py "$PY" "$HERE/test_agent_log.py"
suite test_ast_grep_tool.py python3 "$HERE/test_ast_grep_tool.py"
suite test_history_routing.sh bash "$HERE/test_history_routing.sh"
suite test_run_sh_summary.sh bash "$HERE/test_run_sh_summary.sh"
suite test_run_sh_shards.sh bash "$HERE/test_run_sh_shards.sh"

echo
echo "slowest suites (total ${SECONDS}s, $RUN_START to $(date -u +%FT%TZ)):"
printf '%s\n' "${TIMES[@]}" | sort -rn | head -5 | sed -E 's/^([0-9]+) /  \1s  /'
# The plan and the calls above are read from the same file; if they disagree (a suite called where the plan could not see it) the
# slice did not run what it said it would, and a runner that quietly ran fewer tests must not report success.
if [[ -n $SHARD && $RAN -ne $SHARD_PLANNED ]]; then
  echo "shard $SHARD planned $SHARD_PLANNED suites and ran $RAN"
  RC=1
fi
if [[ $RC -eq 0 ]]; then
  echo "✅ .agents tests passed${SHARD:+ (shard $SHARD: $RAN suites)}"
else
  echo "❌ .agents tests FAILED (${#FAILED[@]}): ${FAILED[*]}${SHARD:+ (shard $SHARD)}"
fi
exit $RC

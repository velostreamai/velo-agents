#!/bin/bash
# test_gate_run_task.sh — velo-gate-run's run step is a velo-task job (#31 part B).
#
# The long step — `velo-pr-gate <pr> <scope> --exec --wait`, tens of minutes of Codex —
# used to run as a foreground child of the wrapper, invisible to everything that answers
# "what is this session running": `velo-task status` (Vanth's jobs table), the Stop guard
# and the Claude task list. It is now a job the wrapper polls. What is pinned here, with a
# mutant copy of the wrapper proving each one goes RED when it is removed:
#
#   G1 the command line the wrapper asks velo-task for — the job id and its shape, HOME and
#      PATH as arguments to /usr/bin/env, the gate's combined output in the file the script
#      already reads (gate-run.run.out), the same args the direct call used to get;
#   G2 a verdict that is not `ok` IS the step failure: non-zero exit, the verdict and the
#      out file's tail shown;
#   G3 a `velo-task run` that fails is FATAL with its message — no fallback to the direct
#      call, and the gate is NOT started;
#   G4 `in-flight` is not a verdict: the wrapper keeps polling until it has one.
#
# The mutants are the brief's three (the direct call, any-verdict-is-ok, a fallback) plus
# the one G4 adds: break on the first poll, which would read a job that is still running
# as a finished one.
# No daemon here: the fake velo-task runs the job synchronously (the wrapper's job shell
# does the redirecting, so the command runs exactly as the real one would) and records the
# exit status as the verdict `velo-task status` would print.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
RUN_REAL="$BIN/velo-gate-run"
PREAMBLE_REAL="$(cd "$HERE/.." && pwd)/rules/gate-attack-preamble.md"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$RUN_REAL" ]] || { fail "velo-gate-run not found or not executable at $RUN_REAL"; exit 1; }
[[ -s "$PREAMBLE_REAL" ]] || { fail "the shipped preamble is missing or empty: $PREAMBLE_REAL"; exit 1; }

TPR=$(( 800000 + ($$ % 90000) ))
TMPD=$(mktemp -d)
export VELO_STATE="$TMPD/state"
export VELO_SECOND_OPINION=0
export VELO_CHECK_CODE=sonnet
GATE_DIR="$VELO_STATE/gate/$TPR"
STUB_DIR="$TMPD/stub"; export STUB_DIR
FAKE_GATE="$TMPD/bin/velo-pr-gate"
FAKE_TASK="$TMPD/bin/velo-task"
export VELO_TASK_BIN="$FAKE_TASK"
TASK_CALLS="$TMPD/task-calls.log";      export TASK_CALLS
TASK_VERDICTS="$TMPD/task-verdicts";    export TASK_VERDICTS
TASK_FAIL="$TMPD/task-run-fail";        export TASK_FAIL
TASK_INFLIGHT="$TMPD/task-inflight";    export TASK_INFLIGHT
GATE_CALLS="$TMPD/gate-calls.log";      export GATE_CALLS
SCOPE="$TMPD/scope.md"
SC_FAILS=""

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT
# The preamble as the script reads it. The mutant copy lives in $TMPD/mut and looks for it
# at ../rules, so the real file is laid out there too (same as tests/test_gate_run.sh).
mkdir -p "$TMPD/bin" "$TMPD/rules" "$TMPD/stub"
cp "$PREAMBLE_REAL" "$TMPD/rules/gate-attack-preamble.md"

sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has_out()  { grep -qF -- "$1" "$TMPD/wrapper.out" 2>/dev/null; }   # <fixed string>
# A call that never happened is a count of 0, not stderr noise (the mutants hit it).
ncalls()   { local n; n=$(grep -cF -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }   # <fixed string> <log> -> matching lines
job_line() { head -1 "$TASK_CALLS" 2>/dev/null; }

# Fake velo-pr-gate: just enough of the three steps the wrapper walks to reach the run
# step, and two marker lines so the suite can tell the out file was printed.
cat > "$FAKE_GATE" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GATE_CALLS"
PRN="$1"; shift
GD="$VELO_STATE/gate/$PRN"; mkdir -p "$GD"
mode=run
for a in "$@"; do
  case "$a" in
    --plan)       mode=plan ;;
    --brief-only) mode=brief ;;
  esac
done
case "$mode" in
  plan)
    printf '#%s fake pr\n  gates needed:\n    - code-review  (independent reviewer)\n' "$PRN" ;;
  brief)
    cat > "$GD/review-brief.md" <<BRIEF
READ-ONLY review of the PR.

## ATTACK

<<< FILL THIS IN — what is worth this reviewer's effort. >>>

## Also confirm

- nothing
BRIEF
    printf '  ok --brief-only: brief ready at %s\n' "$GD/review-brief.md" ;;
  run)
    printf 'gate run: %s --exec --wait\n' "$PRN"
    printf '%s\n' a1b2c3d > "$GD/gated.sha"
    printf 'codex\n' > "$GD/review.log"
    printf '**Verdict:** approve | approve-with-findings | blocked\n' >> "$GD/review.log"
    ( : ) & p=$!; wait "$p"
    printf '%s\n' "$p" > "$GD/review.log.pid"
    if [[ -s "$STUB_DIR/run.rc" ]]; then
      printf '\033[31mERROR:\033[0m the gate step failed: GATE-RUN-FAILED-MARKER\n' >&2
      exit "$(cat "$STUB_DIR/run.rc")"
    fi
    printf 'GATE-RUN-OUTPUT-MARKER\n' ;;
esac
EOF
chmod +x "$FAKE_GATE"

# Fake velo-task: `run` executes the job here and now (no daemon in an automated suite)
# and remembers its exit status; `status` prints `<id> <verdict>`, the shape cmd_status
# prints, so the wrapper's poll has a real answer to parse. G4 asks it for that many
# `in-flight` answers first — a job still running must not be read as a finished one.
cat > "$FAKE_TASK" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TASK_CALLS"
case "$1" in
  run)
    id="$2"; shift 2
    if [[ -s "$TASK_FAIL" ]]; then cat "$TASK_FAIL" >&2; exit 6; fi
    # cmd_run's shape: flags and their values, then `--`, then the command.
    while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
    [[ $# -gt 0 ]] && shift
    "$@"; rc=$?
    if [[ $rc -eq 0 ]]; then v=ok; else v="failed($rc)"; fi
    mkdir -p "$TASK_VERDICTS"
    printf '%s\n' "$v" > "$TASK_VERDICTS/$id"
    printf '%s\n' "$id"
    ;;
  status)
    id="${2:-}"
    if [[ -s "$TASK_INFLIGHT" ]]; then
      n=$(cat "$TASK_INFLIGHT")
      if [[ "$n" -gt 0 ]]; then
        printf '%s\n' "$((n - 1))" > "$TASK_INFLIGHT"
        printf '%s in-flight\n' "$id"; exit 0
      fi
    fi
    v=$(cat "$TASK_VERDICTS/$id" 2>/dev/null)
    printf '%s %s\n' "$id" "${v:-in-flight}"
    ;;
esac
EOF
chmod +x "$FAKE_TASK"

reset() {
  rm -rf "$GATE_DIR" "$STUB_DIR" "$TASK_VERDICTS"
  mkdir -p "$STUB_DIR" "$VELO_STATE/gate"
  rm -f "$GATE_CALLS" "$TASK_CALLS" "$TASK_FAIL" "$TASK_INFLIGHT"
  cat > "$SCOPE" <<'EOF'
# Scope

## Why

The run step, under a velo-task job.

## ATTACK

- G1 the command line the wrapper asks velo-task for.
EOF
}

RUN_UNDER_TEST="$RUN_REAL"
run_wrapper() {   # [args...] -> $OUT $RC (and $TMPD/wrapper.out)
  OUT=$(VELO_PR_GATE_BIN="$FAKE_GATE" bash "$RUN_UNDER_TEST" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/wrapper.out"
}

run_scenarios() {
  local s fn name
  for s in "$@"; do
    fn="${s%%::*}"; name="${s#*::}"
    SC_FAILS=""
    "$fn"
    if [[ -z "$SC_FAILS" ]]; then ok "$name"; else fail "$name — failures:$SC_FAILS"; fi
  done
}

echo "velo-gate-run: the run step as a velo-task job (#31 part B)"

# ── G1: the command line the wrapper asks velo-task for ──────────────────────
sc_g1_job_command_line() {
  local line
  SC_FAILS=""
  reset
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                      sc_check round-exits-0 $?
  [[ "$(ncalls "$SCOPE --exec --wait" "$GATE_CALLS")" == "1" ]]
                                                        sc_check the-gate-ran-with-exec-and-wait $?
  line=$(job_line)
  [[ "$line" == "run gate-$TPR --issue $TPR --stage gate --rerun --timeout 7200 -- /usr/bin/env HOME="* ]]
                                                        sc_check job-asked-for-in-the-pinned-shape $?
  [[ "$line" == *" PATH="* ]];                          sc_check PATH-passed $?
  [[ "$line" == *" OUT=$GATE_DIR/gate-run.run.out "* ]]; sc_check out-file-is-the-one-the-wrapper-reads $?
  [[ "$line" == *"/bin/bash -c "* ]];                   sc_check run-through-a-shell $?
  [[ "$line" == *" _ $FAKE_GATE $TPR $SCOPE --exec --wait" ]]
                                                        sc_check gate-called-with-the-same-args $?
  [[ "$(ncalls "status gate-$TPR" "$TASK_CALLS")" == "1" ]]
                                                        sc_check the-verdict-is-polled $?
  has_out "GATE-RUN-OUTPUT-MARKER";                     sc_check the-gates-output-is-printed $?
}

# ── G2: a verdict that is not `ok` is the step failure ───────────────────────
sc_g2_failed_verdict_is_the_step_failure() {
  SC_FAILS=""
  reset
  printf '1\n' > "$STUB_DIR/run.rc"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                      sc_check exits-non-zero $?
  has_out "failed(1)";                                  sc_check prints-the-verdict $?
  has_out "GATE-RUN-FAILED-MARKER";                     sc_check prints-the-out-tail $?
  [[ "$(ncalls "$SCOPE --exec --wait" "$GATE_CALLS")" == "1" ]]
                                                        sc_check not-retried-a-real-failure $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];               sc_check no-verdict-from-a-failed-job $?
}

# ── G3: a velo-task run that fails is fatal, no fallback ─────────────────────
sc_g3_task_run_failure_is_fatal() {
  SC_FAILS=""
  reset
  printf 'velo-task: failed to reach daemon (velo-task run gate-%s)\n' "$TPR" > "$TASK_FAIL"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                      sc_check exits-non-zero $?
  has_out "failed to reach daemon";                     sc_check names-velo-tasks-reason $?
  has_out "The gate was NOT started";                   sc_check says-the-gate-was-not-started $?
  [[ "$(ncalls "$SCOPE --exec --wait" "$GATE_CALLS")" == "0" ]]
                                                        sc_check the-direct-gate-was-NOT-started $?
}

# ── G4: in-flight is not a verdict — the wrapper waits for one ───────────────
sc_g4_inflight_is_not_a_verdict() {
  SC_FAILS=""
  reset
  printf '2\n' > "$TASK_INFLIGHT"     # the job answers in-flight twice, then ok
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                      sc_check round-exits-0 $?
  [[ "$(ncalls "status gate-$TPR" "$TASK_CALLS")" == "3" ]]
                                                        sc_check polled-until-the-verdict $?
  [[ "$(ncalls "$SCOPE --exec --wait" "$GATE_CALLS")" == "1" ]]
                                                        sc_check the-job-was-not-started-twice $?
  has_out "GATE-RUN-OUTPUT-MARKER";                     sc_check the-gates-output-is-printed $?
}

run_scenarios \
  "sc_g1_job_command_line::G1 the run step asks velo-task for the job, in the pinned shape" \
  "sc_g2_failed_verdict_is_the_step_failure::G2 a verdict that is not ok IS the step failure, with the out tail" \
  "sc_g3_task_run_failure_is_fatal::G3 a velo-task run that fails is fatal, and the direct gate is not started" \
  "sc_g4_inflight_is_not_a_verdict::G4 in-flight is not a verdict — the wrapper polls until it has one"

# ═════════════════════════════════════════════════════════════════════════════
# MUTATION-PROOF — each behaviour goes red when it is removed
# ═════════════════════════════════════════════════════════════════════════════
echo
echo "mutation proofs"
mutate_run() {   # <anchor> <replacement> [<anchor> <replacement>]... -> $TMPD/mut/velo-gate-run
  mkdir -p "$TMPD/mut"
  python3 - "$RUN_REAL" "$TMPD/mut/velo-gate-run" "$@" <<'PY'
import sys
src, dst, *pairs = sys.argv[1:]
assert len(pairs) % 2 == 0, "mutation anchors come as (anchor, replacement) pairs"
t = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
    t = t.replace(old, new, 1)
open(dst, "w").write(t)
PY
}
prove_run() {   # <label> <scenario> <anchor> <replacement>
  local label="$1" fn="$2" red; shift 2
  if ! mutate_run "$@"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  RUN_UNDER_TEST="$TMPD/mut/velo-gate-run"; "$fn"; red="$SC_FAILS"
  RUN_UNDER_TEST="$RUN_REAL"; "$fn"
  if [[ -n "$red" && -z "$SC_FAILS" ]]; then
    ok "MUTATION-PROOF $label: red with the behaviour removed ($red ), green restored"
  elif [[ -z "$red" ]]; then
    fail "MUTATION-PROOF $label: stayed GREEN with the behaviour removed — $fn does not pin it"
  else
    fail "MUTATION-PROOF $label: the real script is red too:$SC_FAILS"
  fi
}

prove_run "the run step is a velo-task job" sc_g1_job_command_line \
  'run_gate_task "$SCOPE" --exec --wait' 'run_gate_step run "$SCOPE" --exec --wait'
prove_run "a verdict that is not ok is the step failure" sc_g2_failed_verdict_is_the_step_failure \
  'if [[ "$verdict" == ok ]]; then' 'if [[ -n "$verdict" ]]; then'
prove_run "a velo-task run that fails is fatal (no fallback to the direct call)" sc_g3_task_run_failure_is_fatal \
  '[[ $task_rc -eq 0 ]] || die "velo-task run' 'if [[ $task_rc -ne 0 ]]; then
      "$PR_GATE" "$PR" "$@" 2>&1 | tee "$out"; return "${PIPESTATUS[0]}"; fi
    [[ $task_rc -eq 0 ]] || die "velo-task run'
prove_run "in-flight is not a verdict" sc_g4_inflight_is_not_a_verdict \
  '[[ "$verdict" == in-flight ]] || break' 'break'

echo
[[ $FAILED -eq 0 ]] && echo "all velo-gate-run velo-task-job checks passed" || echo "FAILURES"
exit $FAILED
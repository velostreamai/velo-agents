#!/bin/bash
# velo-merge reads ONE state from MANY rows, and must read it conservatively (#2380 round 3
# class sweep).
#
# The merge decision rests on three states, each of which GitHub hands over as a list:
#
#   the gate's verdict   a label — but a PR can carry several `gate:*` labels at once (a
#                        `gh pr edit --remove-label` that failed, or a label added by hand in the
#                        UI), and the check was a bare `",$LABELS," == *",gate:passed,"*`: any
#                        `gate:passed` among them won, so a PR labelled both `gate:blocked` and
#                        `gate:passed` read as passed;
#   CI                   statusCheckRollup, one row per check;
#   the gate comments    one comment per gate run.
#
# Every behaviour is pinned twice: green on the real script, and red on a copy of it with that
# one behaviour mutated out — and the red must be for the pinned reason, so a broken stub or a
# typo in the mutation cannot pass for a proof. The mutants are copies in a temp dir; the repo's
# scripts are never edited.
#
# Drives the REAL velo-merge under a stub `gh`, and a stub `velo-gate` in a private $HOME (the
# script runs ~/.agents/bin/velo-gate for the gate plan; the installed copy is not ours to run).
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
MERGE_REAL="$BIN/velo-merge"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "velo-merge reads one state from many rows, conservatively"

[[ -f "$MERGE_REAL" ]] || { fail "velo-merge not found under $BIN"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin" "$TMPD/tmp" "$TMPD/home/.agents/bin"
export TMPDIR="$TMPD/tmp"
export VELO_STATE="$TMPD/state"
export HOME="$TMPD/home"
export PATH="$TMPD/bin:$PATH"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
H9="${HEAD_SHA:0:9}"
export STUB_PR_JSON="$TMPD/pr.json"
export STUB_COMMENTS_JSON="$TMPD/comments.json"
export STUB_CALLS="$TMPD/calls.txt"
export STUB_PLAN="code-review check-code"

# `gh`: the PR payload for `pr view` (whatever --json asks for — velo-merge reads the fields it
# needs), the CALLER'S OWN jq run over the comments for `pr view --json comments --jq`, a recorded
# `pr merge`. STUB_COMMENTS_FAIL makes the comments read fail with that text on stderr.
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_CALLS"
jqexpr() { local prev="" a; for a in "$@"; do [[ "$prev" == "--jq" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json comments"*)
        if [[ -n "${STUB_COMMENTS_FAIL:-}" ]]; then printf '%s\n' "$STUB_COMMENTS_FAIL" >&2; exit 1; fi
        if [[ -n "${STUB_COMMENTS_RAW:-}" ]]; then printf '%s\n' "$STUB_COMMENTS_RAW"; exit 0; fi
        jq -r "$(jqexpr "$@")" <<<"{\"comments\": $(cat "$STUB_COMMENTS_JSON")}"
        exit $? ;;
    esac
    cat "$STUB_PR_JSON"; exit 0 ;;
  "pr merge") exit 0 ;;
esac
exit 0
EOF
# The plan the real velo-gate would print: one bullet per gate STUB_PLAN names.
cat > "$TMPD/home/.agents/bin/velo-gate" <<'EOF'
#!/bin/bash
printf '#1  stub pr\n  files: 1\n  gates needed:\n'
for g in $STUB_PLAN; do printf '    - %s\n' "$g"; done
EOF
chmod +x "$TMPD/bin/gh" "$TMPD/home/.agents/bin/velo-gate"

# The PR the stub serves. Labels, files and CI rows come from the arguments.
DEFAULT_CI='[{"conclusion":"SUCCESS","name":"Build"}]'
set_pr() {   # <label names, space separated> <files json> [<ci rows json>]
  local labels="[]" l
  for l in $1; do labels=$(jq -c --arg l "$l" '. + [{name: $l}]' <<<"$labels"); done
  jq -nc --arg head "$HEAD_SHA" --argjson labels "$labels" --argjson files "$2" --argjson ci "${3:-$DEFAULT_CI}" \
    '{headRefOid: $head, state: "OPEN", title: "stub pr", mergeable: "MERGEABLE",
      labels: $labels, files: $files, statusCheckRollup: $ci}' > "$STUB_PR_JSON"
}
set_comments() {   # <gate name> <sha> ... — one gate comment each, oldest first
  local json='[]'
  while [[ $# -ge 2 ]]; do
    json=$(jq -c --arg b "gate: $1 @ $2"$'\n\n## report\n**Verdict:** approve' '. + [{body: $b}]' <<<"$json"); shift 2
  done
  printf '%s\n' "$json" > "$STUB_COMMENTS_JSON"
}
SRC_FILES='[{"path":"src/x.rs"}]'
DOCS_FILES='[{"path":"docs/x.md"}]'

MERGE_UNDER_TEST="$MERGE_REAL"
SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has()   { grep -qF -- "$2" "$1" 2>/dev/null; }                  # <file> <fixed string>; a missing file has nothing
merges() { grep -c '^pr merge' "$STUB_CALLS" 2>/dev/null || true; }
reset() {   # a fresh PR number's worth of state: no markers, no locks, no calls
  PRN=$(( ${PRN:-4000} + 1 ))
  rm -rf "$VELO_STATE" "$STUB_CALLS"; : > "$STUB_CALLS"
  set_pr "" "$SRC_FILES"; set_comments
}
merge() {   # <velo-merge args...> -> $OUT $RC ; the scenario's STUB_* variables are in the environment
  OUT=$(bash "$MERGE_UNDER_TEST" "$PRN" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/merge.out"
}

# ── gate labels: ONE verdict from MANY labels ─────────────────────────────────
# A positive control first: with every precondition met and a lone gate:passed the harness DOES
# merge, so the refusals below are the labels' doing and not a stub that cannot merge.
sc_label_lone_passed_merges() {
  SC_FAILS=""; reset
  set_pr "gate:passed" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  merge
  [[ $RC -eq 0 ]];                                         sc_check merges-exit-0 $?
  [[ "$(merges)" == 1 ]];                                  sc_check gh-pr-merge-called-once $?
  ! has "$TMPD/merge.out" "ambiguous gate labels";         sc_check does-not-call-one-label-ambiguous $?
}

# Every other precondition is met in the scenarios below (gate comments for both gates at head,
# CI green), so the ONLY thing standing between the PR and a merge is the labels.
sc_label_blocked_beside_passed_refuses() {
  SC_FAILS=""; reset
  set_pr "gate:blocked gate:passed" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "ambiguous gate labels";           sc_check says-the-labels-are-ambiguous $?
  has "$TMPD/merge.out" "gate:blocked gate:passed";        sc_check names-both-labels $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}

# gate:passed left behind by an earlier round, a new gate:running on top: no verdict either.
sc_label_running_beside_passed_refuses() {
  SC_FAILS=""; reset
  set_pr "gate:running gate:passed" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "ambiguous gate labels";           sc_check says-the-labels-are-ambiguous $?
  has "$TMPD/merge.out" "gate:running gate:passed";        sc_check names-both-labels $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}

# The gate label is read only for a PR that is gated: a docs-only PR has no verdict to be
# ambiguous about, and refusing it would widen the check past the PRs it exists for.
sc_label_ambiguity_is_scoped_to_gated_prs() {
  SC_FAILS=""; reset
  set_pr "gate:blocked gate:passed" "$DOCS_FILES"
  merge
  [[ $RC -eq 0 ]];                                         sc_check docs-only-pr-still-merges $?
  has "$TMPD/merge.out" "docs only";                       sc_check says-the-gate-was-not-required $?
  ! has "$TMPD/merge.out" "ambiguous gate labels";         sc_check does-not-refuse-an-ungated-pr $?
}

# --force overrides, and says so: the refusal is a check like the others.
sc_label_ambiguous_under_force_warns() {
  SC_FAILS=""; reset
  set_pr "gate:blocked gate:passed" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  merge --force
  [[ $RC -eq 0 ]];                                         sc_check force-proceeds $?
  has "$TMPD/merge.out" "ambiguous gate labels";           sc_check says-the-labels-are-ambiguous $?
  has "$TMPD/merge.out" "proceeding under --force";        sc_check says-it-is-proceeding-under-force $?
  [[ "$(merges)" == 1 ]];                                  sc_check force-merged $?
}

# Waiting cannot make two labels one: --wait must stop at once, not poll for six hours.
sc_label_ambiguous_wait_is_definitive() {
  SC_FAILS=""; reset
  set_pr "gate:running gate:passed" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=2 merge --wait
  [[ $RC -ne 0 ]];                                         sc_check wait-refuses $?
  has "$TMPD/merge.out" "definitive failure";              sc_check wait-calls-it-definitive $?
  [[ "$(grep -c -- '--json headRefOid' "$STUB_CALLS")" == 1 ]]; sc_check wait-stopped-after-the-first-attempt $?
}

# A single gate label that is not gate:passed is refused as before, naming it.
sc_label_lone_blocked_refuses() {
  SC_FAILS=""; reset
  set_pr "gate:blocked" "$SRC_FILES"; set_comments code-review "$H9" check-code "$H9"
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "is 'gate:blocked', not gate:passed"; sc_check names-the-label $?
  ! has "$TMPD/merge.out" "ambiguous gate labels";         sc_check one-label-is-not-ambiguous $?
}

# ── CI: ONE state from MANY rows ──────────────────────────────────────────────
# The PR is as green as its WORST check, so every row is read — never the first, never the ones
# that happen to carry a conclusion. The PR here touches only docs, so the labels and the gate
# comments are out of the picture and the CI rows alone decide.
CI_OK='{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"}'
CI_SKIPPED='{"__typename":"CheckRun","name":"Optional lane","status":"COMPLETED","conclusion":"SKIPPED"}'
CI_NEUTRAL='{"__typename":"CheckRun","name":"Advisory lane","status":"COMPLETED","conclusion":"NEUTRAL"}'
ci_merge() {   # <extra rows, comma separated> [<velo-merge args>...] -> $OUT $RC ; CI_OK is always the first row
  local extra="$1"; shift
  reset; set_pr "" "$DOCS_FILES" "[$CI_OK${extra:+,$extra}]"
  merge "$@"
}
# Green beside a skipped lane: the control, so the refusals below are the rows' doing.
sc_ci_green_beside_skipped_merges() {
  SC_FAILS=""; reset; set_pr "" "$DOCS_FILES" "[$CI_SKIPPED,$CI_SKIPPED,$CI_OK]"
  merge
  [[ $RC -eq 0 ]];                                         sc_check merges-exit-0 $?
  has "$TMPD/merge.out" "CI green on current head: Build"; sc_check says-ci-is-green $?
  [[ "$(merges)" == 1 ]];                                  sc_check gh-pr-merge-called-once $?
}
# A check that has not finished refuses the merge as PENDING (which --wait retries), whichever
# way the row says so: gh exports the absent conclusion of a running CheckRun as "" (null from the
# API), a queued one may carry no conclusion key, a commit status carries a state and nothing else.
ci_pending_case() {   # <the unfinished row>
  SC_FAILS=""; ci_merge "$1"
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "CI still pending";                sc_check says-ci-is-pending $?
  has "$TMPD/merge.out" "Build & Test";                    sc_check names-the-unfinished-check $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_ci_running_empty_conclusion()      { ci_pending_case '{"__typename":"CheckRun","name":"Build & Test","status":"IN_PROGRESS","conclusion":""}'; }
sc_ci_running_null_conclusion()       { ci_pending_case '{"__typename":"CheckRun","name":"Build & Test","status":"IN_PROGRESS","conclusion":null}'; }
sc_ci_queued_without_conclusion_key() { ci_pending_case '{"__typename":"CheckRun","name":"Build & Test","status":"QUEUED"}'; }
sc_ci_row_without_status_or_conclusion() { ci_pending_case '{"name":"Build & Test"}'; }
sc_ci_commit_status_pending()         { ci_pending_case '{"__typename":"StatusContext","context":"Build & Test","state":"PENDING"}'; }
# A check that finished badly refuses the merge as FAILING (definitive: --wait stops), however
# GitHub spells the failure and whichever kind of row carries it.
ci_failing_case() {   # <the failed row> <what the refusal must name>
  SC_FAILS=""; ci_merge "$1"
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "CI FAILING";                      sc_check says-ci-is-failing $?
  has "$TMPD/merge.out" "$2";                              sc_check names-the-failed-check $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_ci_startup_failure()  { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"STARTUP_FAILURE"}' Lint; }
sc_ci_action_required()  { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}' Lint; }
sc_ci_stale()            { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"STALE"}' Lint; }
sc_ci_failure()          { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"FAILURE"}' Lint; }
sc_ci_cancelled()        { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"CANCELLED"}' Lint; }
sc_ci_timed_out()        { ci_failing_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"TIMED_OUT"}' Lint; }
sc_ci_commit_status_failure() { ci_failing_case '{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}' ci/legacy; }
sc_ci_commit_status_error()   { ci_failing_case '{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}' ci/legacy; }
# The state is decided over ROWS. A failed check with no name used to vanish — its name joined to
# the empty string, and "no failing names" was read as "nothing failed".
sc_ci_unnamed_failed_row()   { ci_failing_case '{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}' "(unnamed check)"; }
# A row this script does not recognise is neither green nor "pending" (waiting does not make it
# recognised): it refuses, and says WHAT it did not recognise.
ci_unknown_case() {   # <the row> <what the refusal must say it did not recognise>
  SC_FAILS=""; ci_merge "$1"
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "cannot classify";                 sc_check says-it-cannot-classify $?
  has "$TMPD/merge.out" "$2";                              sc_check says-what-it-did-not-recognise $?
  ! has "$TMPD/merge.out" "CI green";                      sc_check does-not-say-green $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_ci_unrecognised_conclusion() { ci_unknown_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"MYSTERY"}' 'conclusion "MYSTERY"'; }
sc_ci_unrecognised_commit_state() { ci_unknown_case '{"__typename":"StatusContext","context":"ci/legacy","state":"WEIRD"}' 'state "WEIRD"'; }
sc_ci_unrecognised_row_type()   { ci_unknown_case '{"__typename":"Mystery","name":"Lint"}' 'type "Mystery"'; }
sc_ci_completed_without_conclusion() { ci_unknown_case '{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":""}' 'conclusion ""'; }
sc_ci_row_that_is_not_an_object()    { ci_unknown_case '"oops"' 'not an object'; }
# Worst first: failing > unrecognised > pending > success.
sc_ci_failing_outranks_everything() {
  SC_FAILS=""
  ci_merge '{"name":"Slow","status":"IN_PROGRESS","conclusion":""},{"__typename":"Mystery","name":"Odd"},{"name":"Lint","status":"COMPLETED","conclusion":"FAILURE"}'
  has "$TMPD/merge.out" "CI FAILING";                      sc_check failing-wins $?
  ! has "$TMPD/merge.out" "still pending";                 sc_check pending-does-not-mask-it $?
  ! has "$TMPD/merge.out" "cannot classify";               sc_check unrecognised-does-not-mask-it $?
}
sc_ci_unrecognised_outranks_pending() {
  SC_FAILS=""
  ci_merge '{"name":"Slow","status":"IN_PROGRESS","conclusion":""},{"__typename":"Mystery","name":"Odd"}'
  has "$TMPD/merge.out" "cannot classify";                 sc_check unrecognised-wins $?
  ! has "$TMPD/merge.out" "still pending";                 sc_check pending-does-not-mask-it $?
}
# Only skipped lanes: nothing ran, and "nothing ran" is not "green". A docs PR may merge with the
# no-CI warning (ci.yml's paths-ignore); a PR that touches code may not.
sc_ci_only_skipped_is_not_green() {
  SC_FAILS=""; reset; set_pr "" "$DOCS_FILES" "[$CI_SKIPPED,$CI_NEUTRAL]"
  merge
  [[ $RC -eq 0 ]];                                         sc_check docs-pr-merges-with-a-warning $?
  has "$TMPD/merge.out" "no CI checks";                    sc_check says-no-ci-ran $?
  ! has "$TMPD/merge.out" "CI green";                      sc_check does-not-say-green $?
  reset; set_pr "" "$SRC_FILES" "[$CI_SKIPPED,$CI_NEUTRAL]"
  merge
  [[ $RC -ne 0 ]];                                         sc_check code-pr-refuses $?
  has "$TMPD/merge.out" "no CI checks reported";           sc_check code-pr-says-nothing-verified-it $?
}
# --wait: an unrecognised row and a failure are definitive; a check still running is not.
sc_ci_unrecognised_wait_is_definitive() {
  SC_FAILS=""; reset; set_pr "" "$DOCS_FILES" "[$CI_OK,{\"__typename\":\"Mystery\",\"name\":\"Odd\"}]"
  VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=2 merge --wait
  [[ $RC -ne 0 ]];                                         sc_check wait-refuses $?
  has "$TMPD/merge.out" "definitive failure";              sc_check wait-calls-it-definitive $?
  [[ "$(grep -c -- '--json headRefOid' "$STUB_CALLS")" == 1 ]]; sc_check wait-stopped-after-the-first-attempt $?
}
sc_ci_pending_wait_keeps_polling() {
  SC_FAILS=""; reset; set_pr "" "$DOCS_FILES" "[$CI_OK,{\"name\":\"Slow\",\"status\":\"IN_PROGRESS\",\"conclusion\":\"\"}]"
  VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=1 merge --wait
  [[ $RC -ne 0 ]];                                         sc_check wait-gives-up-at-the-timeout $?
  has "$TMPD/merge.out" "TIMEOUT";                         sc_check says-it-timed-out $?
  ! has "$TMPD/merge.out" "definitive failure";            sc_check pending-is-not-definitive $?
  [[ "$(grep -c -- '--json headRefOid' "$STUB_CALLS")" -gt 1 ]]; sc_check wait-polled-more-than-once $?
}
# A rollup definition that cannot be read, or cannot be run, is a refusal that names it — never
# "no checks failed". The script is copied to a directory of its own so that the sibling file
# is the thing that is wrong.
with_rollup_file() {   # <content of velo-ci-rollup.jq, or the word MISSING> -> runs velo-merge from a private copy
  local d="$TMPD/nojq.$$.$RANDOM"; mkdir -p "$d"
  cp "$MERGE_UNDER_TEST" "$d/velo-merge"
  [[ "$1" == MISSING ]] || printf '%s\n' "$1" > "$d/velo-ci-rollup.jq"
  MERGE_UNDER_TEST_SAVED="$MERGE_UNDER_TEST"; MERGE_UNDER_TEST="$d/velo-merge"
  reset; set_pr "" "$DOCS_FILES"
  merge
  MERGE_UNDER_TEST="$MERGE_UNDER_TEST_SAVED"
}
sc_ci_missing_rollup_definition_refuses() {
  SC_FAILS=""; with_rollup_file MISSING
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "cannot read the CI rollup definition"; sc_check says-it-cannot-read-it $?
  has "$TMPD/merge.out" "velo-ci-rollup.jq";               sc_check names-the-file $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_ci_broken_rollup_definition_refuses() {
  SC_FAILS=""; with_rollup_file 'def ci_rollup: this is not jq ;'
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "could not classify the CI rows";  sc_check says-it-could-not-classify $?
  has "$TMPD/merge.out" "jq said";                         sc_check says-what-jq-said $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
# A state the script has no arm for must not fall through the case as if it were green.
sc_ci_state_the_script_does_not_know_refuses() {
  SC_FAILS=""; with_rollup_file 'def ci_rollup: {state: "weird", fail: "", pass: "", pending: "", unknown: ""};'
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "'weird'";                         sc_check names-the-state $?
  has "$TMPD/merge.out" "could not classify the CI rows";  sc_check says-it-could-not-classify $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}

# ── the gate comments: ONE read, ONE grammar ──────────────────────────────────
# What the merge decides about gates — which are RECORDED (the plan's gates must all be) and which
# are CURRENT (every gate's freshest comment must name head) — comes from one read of the
# comments and one parse of them. It was two reads with two grammars: a gate name with a digit,
# or a header with no readable sha, was "recorded" to one and invisible to the other, so it counted
# as a report that nothing ever compared to head. And a read that FAILED was reported as "no
# recorded report", whichever way gh failed.
gated_pr() {   # <gate comment pairs: name sha ...> — a code PR that is gate:passed, CI green
  reset; set_pr "gate:passed" "$SRC_FILES"; set_comments "$@"
}
reads() { grep -c -- '--json comments' "$STUB_CALLS" 2>/dev/null || true; }
sc_gates_control_both_current_merges() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  merge
  [[ $RC -eq 0 ]];                                         sc_check merges-exit-0 $?
  [[ "$(merges)" == 1 ]];                                  sc_check gh-pr-merge-called-once $?
  has "$TMPD/merge.out" "reports recorded: check-code code-review"; sc_check names-what-was-recorded $?
}
sc_gates_comments_are_read_once() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  merge
  [[ "$(reads)" == 1 ]];                                   sc_check one-read-of-the-comments $?
}
sc_gates_digit_named_stale_gate_refuses() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9" check-code2 "${OLD_SHA:0:9}"
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "STALE GATE";                      sc_check says-stale $?
  has "$TMPD/merge.out" "check-code2 ran at ${OLD_SHA:0:9}"; sc_check names-the-digit-named-gate $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
# A needed gate whose only comment has no readable sha is not a recorded report: nothing can say
# which commit it ran against.
sc_gates_needed_gate_without_a_sha_refuses() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code pending
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "check-code names no commit";      sc_check names-the-gate-that-names-no-commit $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_gates_freshest_comment_without_a_sha_refuses() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9" check-code pending
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "check-code names no commit";      sc_check names-the-gate-that-names-no-commit $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_gates_a_rerun_clears_an_old_comment_without_a_sha() {
  SC_FAILS=""; gated_pr check-code pending code-review "$H9" check-code "$H9"
  merge
  [[ $RC -eq 0 ]];                                         sc_check merges-exit-0 $?
  [[ "$(merges)" == 1 ]];                                  sc_check gh-pr-merge-called-once $?
}
sc_gates_a_missing_needed_gate_is_named() {
  SC_FAILS=""; gated_pr code-review "$H9"
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "NO recorded report for: check-code"; sc_check names-the-missing-gate $?
  has "$TMPD/merge.out" "Recorded so far: code-review";    sc_check says-what-is-recorded $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_gates_a_review_alias_satisfies_code_review() {
  SC_FAILS=""; gated_pr codex-review "$H9" check-code "$H9"
  merge
  [[ $RC -eq 0 ]];                                         sc_check merges-exit-0 $?
}
sc_gates_no_comment_at_all_refuses() {
  SC_FAILS=""; gated_pr
  merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
# A read that FAILS is not "no recorded report": the refusal says the comments could not be read,
# and gh's own reason.
sc_gates_unreadable_comments_are_named() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "could not read PR #$PRN (network)"; sc_check says-it-could-not-read-it $?
  has "$TMPD/merge.out" "gate comments";                   sc_check says-what-it-could-not-read $?
  has "$TMPD/merge.out" "HTTP 502: Bad Gateway";           sc_check shows-ghs-own-error $?
  ! has "$TMPD/merge.out" "NO recorded report";            sc_check does-not-call-it-a-missing-report $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
}
sc_gates_unreadable_comments_under_force_warn() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" merge --force
  [[ $RC -eq 0 ]];                                         sc_check force-proceeds $?
  has "$TMPD/merge.out" "could not read the gate comments for #$PRN"; sc_check says-it-could-not-read-them $?
  has "$TMPD/merge.out" "HTTP 502: Bad Gateway";           sc_check shows-ghs-own-error $?
  has "$TMPD/merge.out" "proceeding under --force";        sc_check says-it-is-proceeding-under-force $?
}
# gh exited 0 but what it printed is not a gate list: no blip, so it is refused as a payload
# problem, and --wait does not poll it.
sc_gates_a_garbled_answer_is_refused() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_RAW="<html>Service Unavailable</html>" merge
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/merge.out" "could not read PR #$PRN (payload)"; sc_check says-payload $?
  has "$TMPD/merge.out" "Service Unavailable";             sc_check shows-what-gh-printed $?
  [[ "$(merges)" == 0 ]];                                  sc_check no-merge-was-attempted $?
  gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_RAW="<html>Service Unavailable</html>" VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=2 merge --wait
  has "$TMPD/merge.out" "definitive failure";              sc_check wait-calls-it-definitive $?
}
sc_gates_a_garbled_answer_under_force_warns() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_RAW="<html>Service Unavailable</html>" merge --force
  [[ $RC -eq 0 ]];                                         sc_check force-proceeds $?
  has "$TMPD/merge.out" "not a gate list";                 sc_check says-what-it-got $?
  has "$TMPD/merge.out" "proceeding under --force";        sc_check says-it-proceeds $?
}
# --wait: a blip is retried, a dead token is not.
sc_gates_unreadable_comments_wait_retries_a_blip() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=1 merge --wait
  has "$TMPD/merge.out" "TIMEOUT";                         sc_check keeps-polling-until-the-timeout $?
  ! has "$TMPD/merge.out" "definitive failure";            sc_check a-blip-is-not-definitive $?
}
sc_gates_unreadable_comments_wait_stops_on_auth() {
  SC_FAILS=""; gated_pr code-review "$H9" check-code "$H9"
  STUB_COMMENTS_FAIL="gh: HTTP 401: Bad credentials" VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=2 merge --wait
  has "$TMPD/merge.out" "could not read PR #$PRN (auth)";  sc_check says-auth $?
  has "$TMPD/merge.out" "definitive failure";              sc_check a-dead-token-is-definitive $?
}

run_scenarios() {   # "<function>::<what it pins>" ...
  local entry fn what
  for entry in "$@"; do
    fn="${entry%%::*}"; what="${entry#*::}"
    "$fn"
    if [[ -z "$SC_FAILS" ]]; then ok "$what"; else fail "$what:$SC_FAILS"; fi
  done
}

echo
echo "gate labels: one verdict from many labels"
run_scenarios \
  "sc_label_lone_passed_merges::control: a lone gate:passed with every other check met merges" \
  "sc_label_blocked_beside_passed_refuses::gate:blocked beside gate:passed has no verdict: refused, both named" \
  "sc_label_running_beside_passed_refuses::gate:running beside gate:passed has no verdict: refused, both named" \
  "sc_label_ambiguity_is_scoped_to_gated_prs::a docs-only PR has no gate verdict to be ambiguous about" \
  "sc_label_ambiguous_under_force_warns::--force overrides the refusal and says so" \
  "sc_label_ambiguous_wait_is_definitive::--wait stops at the first attempt: ambiguity does not clear by waiting" \
  "sc_label_lone_blocked_refuses::a lone gate:blocked is refused by name, not as ambiguous"

echo
echo "CI: one state from many rows"
run_scenarios \
  "sc_ci_green_beside_skipped_merges::control: a green check beside skipped lanes merges" \
  "sc_ci_running_empty_conclusion::a running check (conclusion \"\") beside a green one is pending, not green" \
  "sc_ci_running_null_conclusion::a running check (conclusion null) beside a green one is pending" \
  "sc_ci_queued_without_conclusion_key::a queued check with no conclusion key is pending" \
  "sc_ci_row_without_status_or_conclusion::a row with neither a status nor a conclusion is pending" \
  "sc_ci_commit_status_pending::a commit status in state PENDING is pending" \
  "sc_ci_failure::a FAILURE beside a green check is FAILING" \
  "sc_ci_cancelled::a CANCELLED check is FAILING" \
  "sc_ci_timed_out::a TIMED_OUT check is FAILING" \
  "sc_ci_startup_failure::a STARTUP_FAILURE beside a green check is FAILING" \
  "sc_ci_action_required::an ACTION_REQUIRED check beside a green one is FAILING" \
  "sc_ci_stale::a STALE check beside a green one is FAILING" \
  "sc_ci_commit_status_failure::a commit status in state FAILURE beside a green check is FAILING" \
  "sc_ci_commit_status_error::a commit status in state ERROR beside a green check is FAILING" \
  "sc_ci_unnamed_failed_row::a failed check with no name is still a failure" \
  "sc_ci_unrecognised_conclusion::an unrecognised conclusion is refused, not read as green" \
  "sc_ci_unrecognised_commit_state::an unrecognised commit-status state is refused" \
  "sc_ci_unrecognised_row_type::an unrecognised row type is refused" \
  "sc_ci_completed_without_conclusion::a COMPLETED check with no conclusion is refused" \
  "sc_ci_row_that_is_not_an_object::a check row that is not an object is refused" \
  "sc_ci_failing_outranks_everything::failing outranks pending and unrecognised" \
  "sc_ci_unrecognised_outranks_pending::unrecognised outranks pending" \
  "sc_ci_only_skipped_is_not_green::only skipped lanes is no CI at all, not green" \
  "sc_ci_unrecognised_wait_is_definitive::--wait stops on an unrecognised row" \
  "sc_ci_pending_wait_keeps_polling::--wait keeps polling a check that is still running" \
  "sc_ci_missing_rollup_definition_refuses::a missing rollup definition is refused, naming the file" \
  "sc_ci_broken_rollup_definition_refuses::a rollup definition that cannot run is refused" \
  "sc_ci_state_the_script_does_not_know_refuses::a rollup state the script has no arm for is refused, not read as green"

echo
echo "gate comments: one read, one grammar"
run_scenarios \
  "sc_gates_control_both_current_merges::control: both gates recorded at head merges, and says what was recorded" \
  "sc_gates_comments_are_read_once::the comments are read once, not once for 'recorded' and again for 'current'" \
  "sc_gates_digit_named_stale_gate_refuses::a stale gate whose name has a digit is seen, and refuses" \
  "sc_gates_needed_gate_without_a_sha_refuses::a needed gate whose only comment names no commit is not a recorded report" \
  "sc_gates_freshest_comment_without_a_sha_refuses::a gate whose FRESHEST comment names no commit refuses, whatever it said before" \
  "sc_gates_a_rerun_clears_an_old_comment_without_a_sha::a re-run at head clears an older comment that named no commit" \
  "sc_gates_a_missing_needed_gate_is_named::a needed gate with no report is named, with what is recorded" \
  "sc_gates_a_review_alias_satisfies_code_review::codex-review satisfies the code-review gate" \
  "sc_gates_no_comment_at_all_refuses::no gate comment at all refuses" \
  "sc_gates_unreadable_comments_are_named::a failed comments read says so, with gh's reason — it is not a missing report" \
  "sc_gates_unreadable_comments_under_force_warn::--force proceeds past an unreadable read and says so" \
  "sc_gates_a_garbled_answer_is_refused::an answer that is not a gate list is refused as a payload problem, and --wait stops" \
  "sc_gates_a_garbled_answer_under_force_warns::--force proceeds past an answer that is not a gate list and says so" \
  "sc_gates_unreadable_comments_wait_retries_a_blip::--wait retries a network blip on the comments read" \
  "sc_gates_unreadable_comments_wait_stops_on_auth::--wait stops on a dead token"

# ── MUTATION-PROOF ────────────────────────────────────────────────────────────
MUT="$TMPD/mut"; mkdir -p "$MUT"
JQ_REAL="$BIN/velo-ci-rollup.jq"
_mutate() {   # <real file> <mutant file> <anchor> <replacement> [<anchor> <replacement>]... ; each anchor occurs exactly once
  python3 - "$@" <<'PY'
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
# A mutant is a PAIR of files in $MUT — velo-merge reads its CI rollup definition from beside itself
# — and each mutation starts from copies of both real files and changes exactly one of them.
mutate()    { cp "$JQ_REAL" "$MUT/velo-ci-rollup.jq" && _mutate "$MERGE_REAL" "$MUT/velo-merge" "$@"; }
mutate_jq() { cp "$MERGE_REAL" "$MUT/velo-merge" && _mutate "$JQ_REAL" "$MUT/velo-ci-rollup.jq" "$@"; }
# The mutant's red must NAME the check that pins the behaviour: an unrelated red (a broken stub,
# a typo in the mutation) is not a proof.
_prove() {   # <mutator> <label> <scenario fn> <the check that must go red> <anchor> <replacement> [<anchor> <replacement>]...
  local mutator="$1" label="$2" fn="$3" want="$4" red; shift 4
  if ! "$mutator" "$@"; then fail "MUTATION-PROOF $label: anchor not found — did the file change shape?"; return; fi
  MERGE_UNDER_TEST="$MUT/velo-merge"
  "$fn"; red="$SC_FAILS"
  MERGE_UNDER_TEST="$MERGE_REAL"
  "$fn"
  if [[ -n "$SC_FAILS" ]]; then
    fail "MUTATION-PROOF $label: the real script is red too:$SC_FAILS"
  elif [[ -z "$red" ]]; then
    fail "MUTATION-PROOF $label: stayed GREEN with the behaviour removed — $fn does not pin it"
  elif [[ " $red " != *" $want "* ]]; then
    fail "MUTATION-PROOF $label: red, but not for the pinned reason ($want): $red"
  else
    ok "MUTATION-PROOF $label: red with the behaviour removed ($red ), green restored"
  fi
}
prove()    { _prove mutate "$@"; }      # <label> <scenario fn> <check> <anchor in velo-merge> <replacement>...
prove_jq() { _prove mutate_jq "$@"; }   # the same, the anchor in velo-ci-rollup.jq

echo
echo "mutation proofs"
prove "two gate labels are refused" sc_label_blocked_beside_passed_refuses refuses \
  '  if [[ "$N_GATE_LABELS" -gt 1 ]]; then' '  if false; then'
prove "the refusal names both labels" sc_label_running_beside_passed_refuses names-both-labels \
  '$(tr '"'"'\n'"'"' '"'"' '"'"' <<<"$GATE_LABELS" | sed '"'"'s/ $//'"'"') — at most one.' 'labels — at most one.'
prove "the refusal is scoped to gated PRs" sc_label_ambiguity_is_scoped_to_gated_prs docs-only-pr-still-merges \
  'if [[ "$CODE" -eq 0 ]]; then
  ok "docs only — no code, no orchestration; gate not required"' 'if [[ "$N_GATE_LABELS" -gt 1 ]]; then die "ambiguous gate labels (mutant)"; fi
if [[ "$CODE" -eq 0 ]]; then
  ok "docs only — no code, no orchestration; gate not required"'
prove "--force overrides the refusal" sc_label_ambiguous_under_force_warns force-proceeds \
  '    [[ $FORCE -eq 1 ]] || die "#$PR has ambiguous gate labels:' '    die "#$PR has ambiguous gate labels:'
prove "--wait treats ambiguous labels as definitive" sc_label_ambiguous_wait_is_definitive wait-calls-it-definitive \
  '|ambiguous gate labels|cannot classify|' '|cannot classify|'
prove "exactly one label is not ambiguous (control)" sc_label_lone_passed_merges merges-exit-0 \
  '  if [[ "$N_GATE_LABELS" -gt 1 ]]; then' '  if [[ "$N_GATE_LABELS" -gt 0 ]]; then'
prove "a lone non-passed label is refused by name" sc_label_lone_blocked_refuses one-label-is-not-ambiguous \
  '  if [[ "$N_GATE_LABELS" -gt 1 ]]; then' '  if [[ "$N_GATE_LABELS" -gt 0 ]]; then'

# velo-merge's own handling of the rollup.
prove "--wait treats a check it cannot classify as definitive" sc_ci_unrecognised_wait_is_definitive wait-calls-it-definitive \
  '|cannot classify|cannot read the CI rollup definition|' '|cannot read the CI rollup definition|'
prove "an unrecognised check is refused" sc_ci_unrecognised_conclusion refuses \
  '  unknown) die "CI has a check this script cannot classify against $SHORT: $UNKNOWN' '  unknown) ok "CI green (mutant)"; : "$UNKNOWN'
prove "a rollup state with no arm is refused" sc_ci_state_the_script_does_not_know_refuses refuses \
  '  *) die "could not classify the CI rows of #$PR: the rollup returned the state' '  *) : "could not classify the CI rows of #$PR: the rollup returned the state'
prove "an unreadable rollup definition is refused by name" sc_ci_missing_rollup_definition_refuses says-it-cannot-read-it \
  '  || die "cannot read the CI rollup definition $CI_ROLLUP_JQ — it is what decides whether CI is green:' '  || : ; : "cannot read the CI rollup definition $CI_ROLLUP_JQ — it is what decides whether CI is green:'
prove "a rollup definition that cannot run says what jq said" sc_ci_broken_rollup_definition_refuses says-what-jq-said \
  '  || die "could not classify the CI rows of #$PR (jq said:' '  || : ; : "could not classify the CI rows of #$PR (jq said:'

# The gate comments: one read, one grammar.
prove "a gate name may carry a digit" sc_gates_digit_named_stale_gate_refuses refuses \
  'capture("gate: *(?<n>[a-z0-9-]+) *@ *(?<s>[0-9a-f]{7,40})?")]' 'capture("gate: *(?<n>[a-z-]+) *@ *(?<s>[0-9a-f]{7,40})?")]'
prove "a header with no readable sha is still a gate comment" sc_gates_freshest_comment_without_a_sha_refuses refuses \
  '(?<s>[0-9a-f]{7,40})?")]' '(?<s>[0-9a-f]{7,40})")]'
prove "a header with no readable sha is named as naming no commit" sc_gates_needed_gate_without_a_sha_refuses names-the-gate-that-names-no-commit \
  '      if [[ "$GS" == "-" ]]; then' '      if false; then'
prove "a gate behind head is stale" sc_gates_digit_named_stale_gate_refuses says-stale \
  '      elif [[ "$HEAD" != "$GS"* ]]; then' '      elif false; then'
prove "the comments are read once" sc_gates_comments_are_read_once one-read-of-the-comments \
  '    RECORDED=$(awk' \
  $'    RECORDED=$(gh pr view "$PR" --repo "$REPO" --json comments --jq \'[.comments[].body | capture("gate: *(?<n>[a-z0-9-]+) *@")] | map(.n) | unique | join(" ")\' 2>/dev/null); : $(awk'
prove "a failed read is reported as a failed read" sc_gates_unreadable_comments_are_named says-it-could-not-read-it \
  '        network)    die "could not read PR #$PR (network): the gate comments' '        network)    : "could not read PR #$PR (network): the gate comments'
prove "a dead token is reported as auth" sc_gates_unreadable_comments_wait_stops_on_auth says-auth \
  '        auth)       die "could not read PR #$PR (auth): the gate comments' '        auth)       die "could not read PR #$PR (network): the gate comments'
prove "--force says it proceeds past an unreadable read" sc_gates_unreadable_comments_under_force_warn says-it-could-not-read-them \
  '      warn "could not read the gate comments for #$PR — proceeding under --force. gh said: $GATES_ERR"' '      :'
prove "an answer that is not a gate list is refused as a payload problem" sc_gates_a_garbled_answer_is_refused says-payload \
  '      [[ "$GLINE" =~ $GATE_LINE_RE ]] && continue' '      continue'
prove "--force says what it proceeds past: an answer that is not a gate list" sc_gates_a_garbled_answer_under_force_warns says-what-it-got \
  '      warn "could not read the gate comments for #$PR — proceeding under --force. gh said: $GATES_ERR"' '      :'
prove "codex-review satisfies the code-review gate" sc_gates_a_review_alias_satisfies_code_review merges-exit-0 \
  'for alias in code-review codex-review opus-review sonnet-review; do' 'for alias in code-review opus-review sonnet-review; do'
prove "a needed gate that is not recorded refuses" sc_gates_a_missing_needed_gate_is_named refuses \
  '        *) [[ " $RECORDED " == *" $g "* ]] || MISSING="$MISSING $g" ;;' '        *) : ;;'

# The classification itself, velo-ci-rollup.jq: every conclusion, state and row shape it names.
prove_jq "a commit status in state FAILURE is a failure" sc_ci_commit_status_failure says-ci-is-failing \
  '"SUCCESS": "pass", "FAILURE": "fail", "ERROR": "fail", "PENDING"' '"SUCCESS": "pass", "PENDING"'
prove_jq "a commit status in state ERROR is a failure" sc_ci_commit_status_error says-ci-is-failing \
  '"ERROR": "fail", "PENDING"' '"PENDING"'
prove_jq "a commit status in state PENDING is pending" sc_ci_commit_status_pending says-ci-is-pending \
  '"PENDING": "pending", "EXPECTED": "pending"}' '"EXPECTED": "pending"}'
prove_jq "a running check (conclusion \"\") is pending by its status" sc_ci_running_empty_conclusion says-ci-is-pending \
  'if has("status") then .status != "COMPLETED" else' 'if has("status") then false else'
prove_jq "a running check (conclusion null) is pending by its status" sc_ci_running_null_conclusion says-ci-is-pending \
  'if has("status") then .status != "COMPLETED" else' 'if has("status") then false else'
prove_jq "a queued check with no conclusion key is pending by its status" sc_ci_queued_without_conclusion_key says-ci-is-pending \
  'if has("status") then .status != "COMPLETED" else' 'if has("status") then false else'
prove_jq "a row with no status is pending while it has no conclusion" sc_ci_row_without_status_or_conclusion says-ci-is-pending \
  'else ((.conclusion // "") == "") end) then "pending"' 'else false end) then "pending"'
prove_jq "an unrecognised conclusion is not green" sc_ci_unrecognised_conclusion refuses \
  '"STALE": "fail"}[(.conclusion // "") | tostring]) // "unknown"' '"STALE": "fail"}[(.conclusion // "") | tostring]) // "pass"'
prove_jq "a COMPLETED check with no conclusion is not green" sc_ci_completed_without_conclusion refuses \
  '"STALE": "fail"}[(.conclusion // "") | tostring]) // "unknown"' '"STALE": "fail"}[(.conclusion // "") | tostring]) // "pass"'
prove_jq "an unrecognised commit-status state is not green" sc_ci_unrecognised_commit_state refuses \
  '"EXPECTED": "pending"}[(.state // "") | tostring]) // "unknown"' '"EXPECTED": "pending"}[(.state // "") | tostring]) // "pass"'
prove_jq "an unrecognised row type is not green" sc_ci_unrecognised_row_type refuses \
  'elif (.__typename // "CheckRun") != "CheckRun" then "unknown"' 'elif (.__typename // "CheckRun") != "CheckRun" then "pass"'
prove_jq "a row that is not an object is not green" sc_ci_row_that_is_not_an_object refuses \
  '  if type != "object" then "unknown"' '  if type != "object" then "pass"'
prove_jq "FAILURE is a failure" sc_ci_failure says-ci-is-failing \
  '"FAILURE": "fail", "CANCELLED": "fail",' '"CANCELLED": "fail",'
prove_jq "CANCELLED is a failure" sc_ci_cancelled says-ci-is-failing \
  '"CANCELLED": "fail", ' ''
prove_jq "TIMED_OUT is a failure" sc_ci_timed_out says-ci-is-failing \
  '"TIMED_OUT": "fail", ' ''
prove_jq "STARTUP_FAILURE is a failure" sc_ci_startup_failure says-ci-is-failing \
  '"STARTUP_FAILURE": "fail",' ''
prove_jq "ACTION_REQUIRED is a failure" sc_ci_action_required says-ci-is-failing \
  '"ACTION_REQUIRED": "fail", "STALE": "fail"}' '"STALE": "fail"}'
prove_jq "STALE is a failure" sc_ci_stale says-ci-is-failing \
  '"ACTION_REQUIRED": "fail", "STALE": "fail"}' '"ACTION_REQUIRED": "fail"}'
prove_jq "SKIPPED is not green" sc_ci_only_skipped_is_not_green says-no-ci-ran \
  '"SKIPPED": "neutral"' '"SKIPPED": "pass"'
prove_jq "NEUTRAL is not green" sc_ci_only_skipped_is_not_green says-no-ci-ran \
  '"NEUTRAL": "neutral"' '"NEUTRAL": "pass"'
prove_jq "the state is decided over rows, not over their names" sc_ci_unnamed_failed_row refuses \
  'any($rows[]; .k == "fail")    then "FAILING"' '(names("fail") != "") then "FAILING"' \
  'if . == "" then "(unnamed check)" else . end' '.'
prove_jq "failing outranks pending" sc_ci_failing_outranks_everything failing-wins \
  'if   any($rows[]; .k == "fail")    then "FAILING"' 'if   any($rows[]; .k == "pending") then "pending"
              elif any($rows[]; .k == "fail")    then "FAILING"'
prove_jq "unrecognised outranks pending" sc_ci_unrecognised_outranks_pending unrecognised-wins \
  'elif any($rows[]; .k == "unknown") then "unknown"' 'elif false then "unknown"'
prove_jq "the refusal names the failed check" sc_ci_failure names-the-failed-check \
  'fail: names("fail"), ' 'fail: "", '
prove_jq "the refusal names the unfinished check" sc_ci_running_empty_conclusion names-the-unfinished-check \
  'pending: names("pending"), ' 'pending: "", '
prove_jq "the refusal says what it did not recognise" sc_ci_unrecognised_conclusion says-what-it-did-not-recognise \
  '"\(.l) (\(.d))"' '"\(.l)"'

echo
if [[ $FAILED -eq 0 ]]; then echo "all merge-aggregation checks passed"; else echo "FAILED"; fi
exit $FAILED

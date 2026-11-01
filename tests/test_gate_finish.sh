#!/bin/bash
# velo-gate-finish: post the round's reports, then record the verdict.
#
# By hand that was three commands — velo-gate-post for check-code, for code-review,
# then velo-gate --pass|--block — and each had a way to go quietly wrong: a verdict
# labelled after a report failed to post, a report stamped with the head instead of
# the sha the gates ran against, a gh timeout read as a refusal, a retried post
# that landed twice, a re-run that posted everything again.
#
# Two layers:
#   1. the wrapper against STUB velo-gate-post / velo-gate / gh (every branch);
#   2. the wrapper over the REAL velo-gate-post and velo-gate under a stub gh, so
#      the substitution declaration, the stale-head refusal and the idempotent
#      re-run are exercised through the code that really implements them.
#
# Every behaviour is pinned twice: green on the real script, and RED on a copy
# with that one behaviour mutated out (the MUTATION-PROOF cases at the end). The
# mutants are copies in a temp dir — the repo's scripts are never edited.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FINISH_REAL="$BIN/velo-gate-finish"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$FINISH_REAL" ]] || { fail "velo-gate-finish not found or not executable at $FINISH_REAL"; exit 1; }

TMPD=$(mktemp -d)
export VELO_STATE="$TMPD/state"
PR=913579
SHA="abcdef0123456789abcdef0123456789abcdef01"
S9="${SHA:0:9}"
STUB_DIR="$TMPD/stub"; export STUB_DIR
mkdir -p "$TMPD/stub-bin"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }                  # <file> <fixed string>
diff() { command diff "$@" 2>/dev/null; }
ncalls() { local n; n=$(grep -cF -- "$1" "$STUB_DIR/calls.log" 2>/dev/null); echo "${n:-0}"; }   # <fixed string>

# ═════════════════════════════════════════════════════════════════════════════
# Layer 1 — stubs
# ═════════════════════════════════════════════════════════════════════════════
cat > "$TMPD/stub-bin/velo-gate-post" <<'EOF'
#!/bin/bash
# Stub velo-gate-post. Fails per fail.post.<name> ("<remaining> <message>"). When
# lost.<name> exists, a failing call has ALSO landed the comment: the response was
# lost on the wire, the post was not.
printf 'post %s\n' "$*" >> "$STUB_DIR/calls.log"
PRN="$1"; NAME="$2"; shift 3
SHA=""
while [[ $# -gt 0 ]]; do case "$1" in --sha) SHA="$2"; shift 2 ;; *) shift ;; esac; done
inj="$STUB_DIR/fail.post.$NAME"
if [[ -s "$inj" ]]; then
  read -r n msg < "$inj"
  if [[ "$n" -gt 0 ]]; then
    printf '%s %s\n' "$((n - 1))" "$msg" > "$inj"
    [[ -e "$STUB_DIR/lost.$NAME" ]] && printf 'gate: %s @ %s\n' "$NAME" "${SHA:0:9}" >> "$STUB_DIR/comments.txt"
    printf '\033[31mERROR:\033[0m %s\n' "$msg" >&2
    exit 1
  fi
fi
if [[ -e "$STUB_DIR/noop.$NAME" ]]; then
  # The real poster's answer when its own done-marker exists: OK, and nothing posted.
  echo "  ok '$NAME' @ ${SHA:0:9} already posted (pid 1 at now) — skipping (idempotent)"
  exit 0
fi
printf 'gate: %s @ %s\n' "$NAME" "${SHA:0:9}" >> "$STUB_DIR/comments.txt"
# lag.<name> holds N: the next N lookups of the PR's comments will not show it yet.
[[ -s "$STUB_DIR/lag.$NAME" ]] && cp "$STUB_DIR/lag.$NAME" "$STUB_DIR/hide"
echo "  ok posted '$NAME' to #$PRN @ ${SHA:0:9}"
echo "   https://github.com/x/y/pull/$PRN#issuecomment-$NAME"
echo
echo "   Next: record the VERDICT"
exit 0
EOF
cat > "$TMPD/stub-bin/velo-gate" <<'EOF'
#!/bin/bash
# Stub velo-gate. Fails per fail.gate ("<remaining> <message>").
printf 'gate %s\n' "$*" >> "$STUB_DIR/calls.log"
inj="$STUB_DIR/fail.gate"
if [[ -s "$inj" ]]; then
  read -r n msg < "$inj"
  if [[ "$n" -gt 0 ]]; then
    printf '%s %s\n' "$((n - 1))" "$msg" > "$inj"
    printf '\033[31mERROR:\033[0m %s\n' "$msg" >&2
    exit 1
  fi
fi
label=gate:passed; [[ "$2" == "--block" ]] && label=gate:blocked
printf '  ok #%s -> %s (head abcdef012)\n' "$1" "$label"
exit 0
EOF
cat > "$TMPD/stub-bin/gh" <<'EOF'
#!/bin/bash
# Stub gh for layer 1: the only call velo-gate-finish makes is the header check.
case "$*" in
  *"--json comments"*)
    if [[ -s "$STUB_DIR/hide" ]]; then   # read-after-write lag: answer "nothing yet" N times
      n=$(cat "$STUB_DIR/hide")
      if [[ "$n" -gt 1 ]]; then echo "$((n - 1))" > "$STUB_DIR/hide"; else rm -f "$STUB_DIR/hide"; fi
      exit 0
    fi
    # Run the CALLER'S own jq over the posted comments (one per line of comments.txt), so the anchored
    # header check is evaluated, never canned.
    expr=""; prev=""; for a in "$@"; do [[ "$prev" == "--jq" ]] && expr="$a"; prev="$a"; done
    [[ -n "$expr" ]] || exit 0
    { printf '{"comments":['; sep=""; while IFS= read -r l; do [[ -n "$l" ]] && { printf '%s' "$sep"; jq -Rn --arg b "$l" '{body:$b}'; sep=","; }; done < "$STUB_DIR/comments.txt" 2>/dev/null; printf ']}'; } | jq -r "$expr" 2>/dev/null
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/stub-bin/"*

CC="$TMPD/post-cc.md"; CR="$TMPD/post-cr.md"
reset() {
  rm -rf "$STUB_DIR" "$VELO_STATE"; mkdir -p "$STUB_DIR" "$VELO_STATE"
  printf '## check-code — PR %s @ %s\n**Verdict:** approve\n' "$PR" "$S9" > "$CC"
  printf '## Codex review — PR %s @ %s\n**Verdict:** approve-with-findings\n' "$PR" "$S9" > "$CR"
}

FINISH_UNDER_TEST="$FINISH_REAL"
run_finish() {   # args... -> $OUT $RC
  OUT=$(VELO_GATE_POST_BIN="$TMPD/stub-bin/velo-gate-post" VELO_GATE_BIN="$TMPD/stub-bin/velo-gate" \
        VELO_GATE_RETRY_DELAY=0 PATH="$TMPD/stub-bin:$PATH" bash "$FINISH_UNDER_TEST" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/finish.out"
}

sc_usage() {
  SC_FAILS=""
  reset
  run_finish
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "usage: velo-gate-finish"; sc_check no-args $?
  run_finish "$PR" "$SHA" "$CC" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "give --pass or --block"; sc_check no-verdict-flag $?
  run_finish "$PR" "$SHA" --pass --block "$CC" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "exactly one of --pass / --block"; sc_check both-verdict-flags $?
  run_finish notanumber "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "the PR must be a number"; sc_check bad-pr $?
  run_finish "$PR" nothex --pass "$CC" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "7-40 hex characters"; sc_check bad-sha $?
  run_finish "$PR" abc12 --pass "$CC" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "7-40 hex characters"; sc_check short-sha $?
  run_finish "$PR" "$SHA" --pass
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "no report to post"; sc_check no-reports $?
  run_finish "$PR" "$SHA" --pass "$CC"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "expected <pr> <sha>"; sc_check one-positional-report $?
  run_finish "$PR" "$SHA" --pass "$CC" "$CR" "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "expected <pr> <sha>"; sc_check three-positional-reports $?
  run_finish "$PR" "$SHA" --pass "$CC" "$CR" --code-review "$CR"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "not both"; sc_check positional-and-named $?
  run_finish "$PR" "$SHA" --pass --bogus
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "unknown flag: --bogus"; sc_check unknown-flag $?
  run_finish "$PR" "$SHA" --pass --check-code
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "--check-code needs a report file"; sc_check dangling-check-code $?
  [[ ! -e "$STUB_DIR/calls.log" ]]; sc_check nothing-was-called $?
}

sc_files_checked_first() {
  SC_FAILS=""
  reset
  run_finish "$PR" "$SHA" --pass "$CC" "$TMPD/missing.md"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "report file not found: $TMPD/missing.md"; sc_check missing-file $?
  : > "$TMPD/empty.md"
  run_finish "$PR" "$SHA" --pass "$CC" "$TMPD/empty.md"
  [[ $RC -ne 0 ]] && has "$TMPD/finish.out" "report file is empty: $TMPD/empty.md"; sc_check empty-file $?
  # The FIRST report is fine, the second is not: nothing may have been posted.
  [[ ! -e "$STUB_DIR/calls.log" ]]; sc_check nothing-posted-before-the-typo-was-found $?
}

sc_positional() {
  SC_FAILS=""
  reset
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  printf 'post %s check-code %s --sha %s\npost %s code-review %s --sha %s\ngate %s --pass\n' \
    "$PR" "$CC" "$SHA" "$PR" "$CR" "$SHA" "$PR" > "$TMPD/calls.expected"
  diff -q "$STUB_DIR/calls.log" "$TMPD/calls.expected" >/dev/null; sc_check check-code-then-code-review-then-verdict-all-at-the-gated-sha $?
  has "$TMPD/finish.out" "posted check-code @ $S9";  sc_check says-check-code-posted $?
  has "$TMPD/finish.out" "posted code-review @ $S9"; sc_check says-code-review-posted $?
  has "$TMPD/finish.out" "-> gate:passed";          sc_check shows-the-label-line $?
  # The flag may sit anywhere among the arguments.
  reset
  run_finish --pass "$PR" "$SHA" "$CC" "$CR"
  [[ $RC -eq 0 ]] && diff -q "$STUB_DIR/calls.log" "$TMPD/calls.expected" >/dev/null; sc_check flag-position-free $?
}

sc_named() {
  SC_FAILS=""
  reset
  run_finish "$PR" "$SHA" --pass --code-review "$CR"
  [[ $RC -eq 0 ]];                                 sc_check code-review-only-exits-0 $?
  printf 'post %s code-review %s --sha %s\ngate %s --pass\n' "$PR" "$CR" "$SHA" "$PR" > "$TMPD/calls.expected"
  diff -q "$STUB_DIR/calls.log" "$TMPD/calls.expected" >/dev/null; sc_check no-check-code-post-for-a-tooling-pr $?
  reset
  run_finish "$PR" "$SHA" --pass --check-code "$CC"
  [[ "$(ncalls 'post ')" == "1" ]] && has "$STUB_DIR/calls.log" "check-code $CC"; sc_check check-code-only $?
  reset
  run_finish "$PR" "$SHA" --pass --code-review "$CR" --check-code "$CC"
  head -1 "$STUB_DIR/calls.log" | grep -qF "check-code"; sc_check check-code-first-whatever-the-flag-order $?
  # check-spec is a planned leg for a [#N] PR touching src/: it has its own report and post.
  reset
  run_finish "$PR" "$SHA" --pass --check-code "$CC" --code-review "$CR" --check-spec "$CR"
  [[ $RC -eq 0 ]];                                 sc_check three-reports-exit-0 $?
  [[ "$(ncalls 'post '"$PR"' check-spec')" == "1" ]]; sc_check check-spec-posted-once $?
  tail -2 "$STUB_DIR/calls.log" | head -1 | grep -qF "check-spec"; sc_check check-spec-posted-before-the-verdict $?
}

sc_block() {
  SC_FAILS=""
  reset
  run_finish "$PR" "$SHA" --block "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  [[ "$(tail -1 "$STUB_DIR/calls.log")" == "gate $PR --block" ]]; sc_check records-block $?
  has "$TMPD/finish.out" "-> gate:blocked";        sc_check shows-the-label-line $?
  [[ "$(ncalls 'post ')" == "2" ]];                 sc_check still-posts-both $?
}

sc_fail_fast() {
  SC_FAILS=""
  reset
  printf '9 refusing to post — this is the BRIEF TEMPLATE, not a report.\n' > "$STUB_DIR/fail.post.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  [[ "$(ncalls 'post ')" == "1" ]];                 sc_check one-attempt-no-retry-for-a-deterministic-failure $?
  [[ "$(ncalls 'gate ')" == "0" ]];                 sc_check NO-verdict-label-when-a-report-failed $?
  has "$TMPD/finish.out" "BRIEF TEMPLATE";         sc_check shows-the-posters-message $?
  has "$TMPD/finish.out" "No verdict was recorded"; sc_check says-no-verdict-was-recorded $?
  reset
  printf '9 refusing to post — this is the BRIEF TEMPLATE, not a report.\n' > "$STUB_DIR/fail.post.code-review"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check second-report-failure-fails $?
  [[ "$(ncalls 'gate ')" == "0" ]];                 sc_check NO-label-when-the-second-report-failed $?
  [[ "$(ncalls 'post ')" == "2" ]];                 sc_check the-first-was-posted $?
}

sc_retry_post() {
  SC_FAILS=""
  reset
  printf '2 PR #%s not found\n' "$PR" > "$STUB_DIR/fail.post.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check recovers $?
  [[ "$(ncalls 'post '"$PR"' check-code')" == "3" ]]; sc_check check-code-posted-on-the-third-attempt $?
  [[ "$(ncalls 'post '"$PR"' code-review')" == "1" ]]; sc_check the-other-report-not-repeated $?
  [[ "$(grep -c 'transient failure' "$TMPD/finish.out")" == "2" ]]; sc_check each-retry-announced $?
  reset
  printf '99 PR #%s not found\n' "$PR" > "$STUB_DIR/fail.post.code-review"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check persistent-failure-fails $?
  [[ "$(ncalls 'post '"$PR"' code-review')" == "4" ]]; sc_check one-attempt-plus-three-retries $?
  [[ "$(ncalls 'gate ')" == "0" ]];                 sc_check no-label-after-giving-up $?
  # What gh actually says when the wire fails, and what it says when it will not improve.
  local msg
  for msg in "could not post to #$PR: Post \"https://api.github.com/x\": context deadline exceeded" \
             "could not post to #$PR: error connecting to api.github.com" \
             "could not post to #$PR: HTTP 502: Bad Gateway" \
             "could not post to #$PR: dial tcp: lookup api.github.com: no such host"; do
    reset
    printf '1 %s\n' "$msg" > "$STUB_DIR/fail.post.check-code"
    run_finish "$PR" "$SHA" --pass "$CC" "$CR"
    [[ $RC -eq 0 && "$(ncalls 'post '"$PR"' check-code')" == "2" ]]; sc_check "retried[$msg]" $?
  done
  for msg in "could not post to #$PR: HTTP 422: Validation Failed" \
             "could not post to #$PR: HTTP 401: Bad credentials" \
             "report file not found: x"; do
    reset
    printf '9 %s\n' "$msg" > "$STUB_DIR/fail.post.check-code"
    run_finish "$PR" "$SHA" --pass "$CC" "$CR"
    [[ $RC -ne 0 && "$(ncalls 'post '"$PR"' check-code')" == "1" ]]; sc_check "not-retried[$msg]" $?
  done
}

sc_lost_response() {
  SC_FAILS=""
  reset
  : > "$STUB_DIR/lost.check-code"
  printf '1 could not post to #%s: i/o timeout\n' "$PR" > "$STUB_DIR/fail.post.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  [[ "$(ncalls 'post '"$PR"' check-code')" == "1" ]]; sc_check NOT-posted-a-second-time $?
  [[ "$(grep -c 'gate: check-code @' "$STUB_DIR/comments.txt")" == "1" ]]; sc_check exactly-one-comment-on-the-pr $?
  has "$TMPD/finish.out" "landed despite the reported failure"; sc_check says-so $?
  [[ "$(ncalls 'gate ')" == "1" ]];                 sc_check verdict-still-recorded $?
}

sc_idempotent() {
  SC_FAILS=""
  reset
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ "$(ncalls 'post ')" == "2" ]];                 sc_check first-run-posts-both $?
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check second-run-exits-0 $?
  [[ "$(ncalls 'post ')" == "2" ]];                 sc_check second-run-posts-nothing $?
  [[ "$(grep -c '^gate: ' "$STUB_DIR/comments.txt")" == "2" ]]; sc_check still-two-comments-on-the-pr $?
  has "$TMPD/finish.out" "already on #$PR";        sc_check says-it-skipped $?
  has "$TMPD/finish.out" "not compared with $CC";  sc_check says-the-existing-comment-is-not-compared-with-the-file $?
  [[ "$(ncalls 'gate ')" == "2" ]];                 sc_check verdict-recorded-again-it-is-idempotent-too $?
  # Resuming after a failure: the first report is on the PR, the second is not.
  reset
  printf 'gate: check-code @ %s\n' "$S9" > "$STUB_DIR/comments.txt"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ "$(ncalls 'post '"$PR"' check-code')" == "0" && "$(ncalls 'post '"$PR"' code-review')" == "1" ]]; sc_check resumes-where-it-stopped $?
  # A header for a DIFFERENT sha is not this round's report.
  reset
  printf 'gate: check-code @ 123456789\n' > "$STUB_DIR/comments.txt"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ "$(ncalls 'post '"$PR"' check-code')" == "1" ]]; sc_check another-shas-header-is-not-this-rounds $?
  # Spacing the poster never writes, but velo-gate's own capture of the header accepts,
  # still makes it a gate comment.
  reset
  printf 'gate:check-code  @  %s\n' "$S9" > "$STUB_DIR/comments.txt"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ "$(ncalls 'post '"$PR"' check-code')" == "0" ]]; sc_check header-spacing-as-tolerant-as-velo-gates-own $?
}

sc_poster_noop() {
  SC_FAILS=""
  reset
  # The poster answers OK and posts nothing (its done-marker says it already did).
  : > "$STUB_DIR/noop.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  has "$TMPD/finish.out" "is not on #$PR";         sc_check says-the-report-is-not-on-the-pr $?
  has "$TMPD/finish.out" "No verdict was recorded"; sc_check says-no-verdict-was-recorded $?
  has "$TMPD/finish.out" "remove $VELO_STATE/gate/$PR/.posted-check-code-$S9"; sc_check names-the-marker-to-remove $?
  [[ "$(ncalls 'gate ')" == "0" ]];                 sc_check NO-label-over-a-missing-report $?
  [[ "$(ncalls 'post '"$PR"' code-review')" == "0" ]]; sc_check stops-before-the-next-report $?
  # The comment lands but the PR reads it back late: that is a slow read, not a failure.
  reset
  printf '2\n' > "$STUB_DIR/lag.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check slow-read-after-write-recovers $?
  [[ "$(ncalls 'post '"$PR"' check-code')" == "1" ]]; sc_check not-posted-again-while-waiting $?
  [[ "$(ncalls 'gate ')" == "1" ]];                 sc_check verdict-recorded-once-it-is-visible $?
  # ... but not forever: a comment that never appears fails after the retries.
  reset
  printf '99\n' > "$STUB_DIR/lag.check-code"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 && "$(ncalls 'gate ')" == "0" ]];    sc_check never-visible-fails-and-labels-nothing $?
}

sc_retry_verdict() {
  SC_FAILS=""
  reset
  printf '2 PR #%s not found\n' "$PR" > "$STUB_DIR/fail.gate"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check recovers $?
  [[ "$(ncalls 'gate ')" == "3" ]];                 sc_check verdict-attempted-three-times $?
  [[ "$(ncalls 'post ')" == "2" ]];                 sc_check reports-not-reposted-for-a-label-failure $?
  reset
  printf '1 could not set gate:passed\n' > "$STUB_DIR/fail.gate"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 && "$(ncalls 'gate ')" == "2" ]];    sc_check label-edit-failure-retried $?
  # velo-gate --pass refuses when it cannot READ the comments it checks head against; a read
  # that failed on the wire is retried like any other failure to get an answer from gh.
  reset
  printf '2 could not read the gate comments for #%s: HTTP 502: Bad Gateway\n' "$PR" > "$STUB_DIR/fail.gate"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -eq 0 && "$(ncalls 'gate ')" == "3" ]];    sc_check unreadable-comments-read-retried $?
  reset
  printf '99 PR #%s not found\n' "$PR" > "$STUB_DIR/fail.gate"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 && "$(ncalls 'gate ')" == "4" ]];    sc_check gives-up-after-four $?
  has "$TMPD/finish.out" "the label was NOT set";  sc_check says-the-label-was-not-set $?
  # A head that moved: velo-gate refuses, and that is not going to change.
  reset
  printf '9 refusing to mark passed: head is def, but: check-code ran at abc\n' > "$STUB_DIR/fail.gate"
  run_finish "$PR" "$SHA" --pass "$CC" "$CR"
  [[ $RC -ne 0 && "$(ncalls 'gate ')" == "1" ]];    sc_check stale-head-refusal-not-retried $?
  has "$TMPD/finish.out" "refusing to mark passed"; sc_check shows-the-refusal $?
  has "$TMPD/finish.out" "reports above are posted"; sc_check says-the-reports-landed $?
}

run_scenarios() {   # "<function>::<what it pins>" ...
  local entry fn what
  for entry in "$@"; do
    fn="${entry%%::*}"; what="${entry#*::}"
    "$fn"
    if [[ -z "$SC_FAILS" ]]; then ok "$what"; else fail "$what:$SC_FAILS"; fi
  done
}

echo "velo-gate-finish (stub velo-gate-post / velo-gate / gh)"
run_scenarios \
  "sc_usage::bad invocations are refused before anything is called" \
  "sc_files_checked_first::a missing or empty report is found before the first post" \
  "sc_positional::check-code, then code-review, then the verdict — every post at the gated sha" \
  "sc_named::a PR needing one report finishes with --code-review / --check-code alone" \
  "sc_block::--block records block and still posts both reports" \
  "sc_fail_fast::a failed post stops the run and no verdict label is set" \
  "sc_retry_post::transient post failures retry up to 3 times; deterministic ones do not" \
  "sc_lost_response::a post that failed on the wire but landed is not posted twice" \
  "sc_poster_noop::a poster that answers OK without posting is caught before the label; a slow read is waited out" \
  "sc_idempotent::a re-run posts nothing again and resumes where it stopped" \
  "sc_retry_verdict::the label step retries transient failures, not a stale-head refusal"

# ═════════════════════════════════════════════════════════════════════════════
# Layer 2 — the real velo-gate-post and velo-gate under a stub gh
# ═════════════════════════════════════════════════════════════════════════════
REAL_HEAD="1111111111111111111111111111111111111111"
export STUB_HEAD="$REAL_HEAD"
MOVED_HEAD="3333333333333333333333333333333333333333"
export STUB_POSTED="$TMPD/real.comments"       # every comment body ever posted, for grepping
export STUB_COMMENTS_JSON="$TMPD/real.comments.json"
export STUB_EDITS="$TMPD/real.edits"
mkdir -p "$TMPD/real-bin"
cat > "$TMPD/real-bin/gh" <<'EOF'
#!/bin/bash
# A PR faithful enough to be believed. Posted comments persist (flat text for greps,
# a JSON array for jq), and `--json comments --jq <expr>` runs the CALLER'S own jq
# over them — so velo-gate's freshest-comment-per-gate lookup and velo-gate-finish's header
# check are computed from what was really posted, never canned. The head is
# STUB_HEAD, which a scenario can move.
jqexpr() { local prev="" a; for a in "$@"; do [[ "$prev" == "--jq" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json headRefOid --jq"*)   echo "$STUB_HEAD"; exit 0 ;;
      *"--json comments"*)
        jq -r "$(jqexpr "$@")" <<<"{\"comments\": $(cat "$STUB_COMMENTS_JSON")}"
        exit 0 ;;
      *"--json headRefOid,labels"*)
        printf '{"headRefOid":"%s","labels":[],"files":[{"path":".agents/bin/x"}],"state":"OPEN","title":"stub pr","body":""}\n' "$STUB_HEAD"
        exit 0 ;;
    esac ;;
  "pr comment")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--body" ]]; then
        printf '%s\n--- comment ---\n' "$a" >> "$STUB_POSTED"
        jq --arg b "$a" '. + [{body: $b}]' "$STUB_COMMENTS_JSON" > "$STUB_COMMENTS_JSON.new" && mv "$STUB_COMMENTS_JSON.new" "$STUB_COMMENTS_JSON"
        break
      fi
      prev="$a"
    done
    echo "https://github.com/x/y/pull/1#issuecomment-stub"
    exit 0 ;;
  "pr edit") printf '%s\n' "$*" >> "$STUB_EDITS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/real-bin/gh"
RS="${REAL_HEAD:0:9}"

real_reset() {
  rm -rf "$VELO_STATE" "$STUB_POSTED" "$STUB_EDITS"; mkdir -p "$VELO_STATE/gate/$PR"
  printf '[]\n' > "$STUB_COMMENTS_JSON"
  printf '## check-code — PR %s @ %s\n**Verdict:** approve-with-findings\n- F1 a finding\n' "$PR" "$RS" > "$CC"
  printf '## Codex review — PR %s @ %s\n**Verdict:** approve\n' "$PR" "$RS" > "$CR"
}
run_real() {   # args... -> $OUT $RC   (the real siblings; only gh is a stub)
  OUT=$(VELO_GATE_POST_BIN="$BIN/velo-gate-post" VELO_GATE_BIN="$BIN/velo-gate" \
        VELO_GATE_RETRY_DELAY=0 PATH="$TMPD/real-bin:$PATH" bash "$FINISH_UNDER_TEST" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/real.out"
}

sc_real_round() {
  SC_FAILS=""
  real_reset
  printf 'sonnet\n' > "$VELO_STATE/gate/$PR/check-code.by"
  run_real "$PR" "$RS" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  [[ "$(grep -c '^gate: ' "$STUB_POSTED")" == "2" ]]; sc_check two-gate-comments-posted $?
  has "$STUB_POSTED" "gate: check-code @ $RS";     sc_check check-code-stamped-with-the-gated-sha $?
  has "$STUB_POSTED" "gate: code-review @ $RS";    sc_check code-review-stamped-with-the-gated-sha $?
  has "$STUB_POSTED" "Reviewer substitution (declared)"; sc_check the-sonnet-substitution-is-declared-on-the-comment $?
  [[ "$(grep -c 'Reviewer substitution' "$STUB_POSTED")" == "1" ]]; sc_check declared-once-not-on-code-review $?
  has "$STUB_EDITS" "--add-label gate:passed";     sc_check label-set $?
  has "$TMPD/real.out" "SUBSTITUTED reviewer";     sc_check the-verdict-line-repeats-the-substitution $?
  # Run it again: nothing is posted twice.
  run_real "$PR" "$RS" --pass "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check rerun-exits-0 $?
  [[ "$(grep -c '^gate: ' "$STUB_POSTED")" == "2" ]]; sc_check rerun-posts-nothing-new $?
  has "$TMPD/real.out" "already on #$PR";          sc_check rerun-says-so $?
}

sc_real_stale_head() {
  SC_FAILS=""
  real_reset
  # The gates ran at $RS; the PR has since moved to $MOVED_HEAD. Every report must be
  # stamped with the sha it was reviewed at — stamping the new head would claim
  # coverage the review never had, and velo-gate --pass would then accept it.
  STUB_HEAD="$MOVED_HEAD" run_real "$PR" "$RS" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  has "$TMPD/real.out" "refusing to mark passed";  sc_check velo-gates-refusal-surfaces $?
  [[ ! -e "$STUB_EDITS" ]];                        sc_check label-not-set $?
  has "$STUB_POSTED" "gate: check-code @ $RS";     sc_check check-code-stamped-with-the-sha-it-ran-against $?
  has "$STUB_POSTED" "gate: code-review @ $RS";    sc_check code-review-stamped-with-the-sha-it-ran-against $?
  ! has "$STUB_POSTED" "@ ${MOVED_HEAD:0:9}";      sc_check nothing-stamped-with-the-newer-head $?
  has "$TMPD/real.out" "reports above are posted"; sc_check says-the-reports-landed $?
}

sc_real_block_no_substitution() {
  SC_FAILS=""
  real_reset
  # #31: this round has no recorded runner (real_reset writes no check-code.by), and
  # the comment now says so. A bare `gate: check-code @ <sha>` header reads as the
  # routed reviewer's work, so the absence is declared — while no agent that did not
  # run is ever named.
  run_real "$PR" "$RS" --block "$CC" "$CR"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$STUB_POSTED" "runner not recorded";        sc_check no-marker-declares-nothing-was-recorded $?
  ! has "$STUB_POSTED" "run by a read-only";       sc_check no-runner-is-invented $?
  has "$STUB_EDITS" "--add-label gate:blocked";    sc_check blocked-label $?
}

sc_real_stale_marker() {
  SC_FAILS=""
  real_reset
  # A done-marker from a post whose comment has since been deleted: the real poster
  # answers "already posted — skipping" and exits 0, with nothing on the PR.
  printf 'pid 1 at 2026-01-01T00:00:00Z\n' > "$VELO_STATE/gate/$PR/.posted-check-code-$RS"
  run_real "$PR" "$RS" --pass "$CC" "$CR"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  has "$TMPD/real.out" "already posted";           sc_check the-real-poster-did-skip $?
  has "$TMPD/real.out" "is not on #$PR";           sc_check says-the-report-is-not-on-the-pr $?
  has "$TMPD/real.out" "remove $VELO_STATE/gate/$PR/.posted-check-code-$RS"; sc_check names-the-marker-to-remove $?
  [[ ! -e "$STUB_EDITS" ]];                        sc_check label-not-set $?
  ! has "$STUB_POSTED" "gate: code-review";        sc_check stops-before-the-next-report $?
}

echo
echo "velo-gate-finish over the real velo-gate-post and velo-gate"
run_scenarios \
  "sc_real_round::a Sonnet check-code round: stamped, declared, labelled, and safe to re-run" \
  "sc_real_stale_head::a head that moved refuses the label and leaves honestly-stamped reports" \
  "sc_real_block_no_substitution::an unrecorded check-code runner is declared, and no agent is invented" \
  "sc_real_stale_marker::a poster that skips on a stale done-marker cannot get a label over a missing report"

# ═════════════════════════════════════════════════════════════════════════════
# MUTATION-PROOF
# ═════════════════════════════════════════════════════════════════════════════
echo
echo "mutation proofs"
MUT="$TMPD/mut"; mkdir -p "$MUT"
mutate() {   # <anchor> <replacement> -> $MUT/velo-gate-finish ; the anchor must occur exactly once
  python3 - "$FINISH_REAL" "$MUT/velo-gate-finish" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
}
prove() {   # <label> <scenario> <anchor> <replacement>
  local label="$1" fn="$2" old="$3" new="$4" red
  if ! mutate "$old" "$new"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  FINISH_UNDER_TEST="$MUT/velo-gate-finish"
  "$fn"; red="$SC_FAILS"
  FINISH_UNDER_TEST="$FINISH_REAL"
  "$fn"
  if [[ -n "$red" && -z "$SC_FAILS" ]]; then
    ok "MUTATION-PROOF $label: red with the behaviour removed ($red ), green restored"
  elif [[ -z "$red" ]]; then
    fail "MUTATION-PROOF $label: stayed GREEN with the behaviour removed — $fn does not pin it"
  else
    fail "MUTATION-PROOF $label: the real script is red too:$SC_FAILS"
  fi
}

prove "retry up to 3 times" sc_retry_post \
  'MAX_RETRIES=3' 'MAX_RETRIES=0'
prove "only 3 retries" sc_retry_post \
  'MAX_RETRIES=3' 'MAX_RETRIES=9'
prove "only transient failures are retried" sc_retry_post \
  '  grep -qiE "PR #$PR not found|could not read the gate comments for #$PR:|could not set gate:|could not post' '  grep -qE ".|could not post'
prove "a label-edit failure is transient" sc_retry_verdict \
  '|could not set gate:|' '|'
prove "an unreadable gate-comments read is transient" sc_retry_verdict \
  '|could not read the gate comments for #$PR:|' '|'
prove "a deterministic post failure stops the run before the label" sc_fail_fast \
  '    die "velo-gate-post failed for $name' '    warn "velo-gate-post failed for $name'
prove "a lost post response is not posted twice" sc_lost_response \
  '      if header_on_pr "$name"; then
        ok "$name @ ${SHA:0:9} landed despite' '      if false; then
        ok "$name @ ${SHA:0:9} landed despite'
prove "a report already on the PR is not posted again" sc_idempotent \
  '  if header_on_pr "$name"; then
    ok "$name @ ${SHA:0:9} is already on' '  if false; then
    ok "$name @ ${SHA:0:9} is already on'
prove "every post carries the gated sha" sc_positional \
  '"$GATE_POST" "$PR" "$name" "$file" --sha "$SHA"' '"$GATE_POST" "$PR" "$name" "$file"'
prove "the verdict flag is passed to velo-gate" sc_block \
  '"$GATE" "$PR" "$VERDICT"' '"$GATE" "$PR" --pass'
prove "check-code is posted before code-review" sc_positional \
  '[[ -n "$CC" ]] && post_gate check-code "$CC"
[[ -n "$CR" ]] && post_gate code-review "$CR"' '[[ -n "$CR" ]] && post_gate code-review "$CR"
[[ -n "$CC" ]] && post_gate check-code "$CC"'
prove "reports are checked before the first post" sc_files_checked_first \
  '  [[ -s "$f" ]] || die "report file is empty: $f"' '  :'
prove "--code-review is parsed" sc_named \
  '      CR="$2"; shift 2 ;;' '      shift 2 ;;'
prove "--check-code is parsed" sc_named \
  '      CC="$2"; shift 2 ;;' '      shift 2 ;;'
prove "exactly one verdict flag" sc_usage \
  '      [[ -z "$VERDICT" ]] || die "give exactly one of --pass / --block' '      [[ -z "$VERDICT" ]] || : "give exactly one of --pass / --block'
prove "the sha must be a real sha" sc_usage \
  '[[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] || die' '[[ "$SHA" =~ ^.*$ ]] || die'
# The same two behaviours again, through the real siblings: without --sha the real
# velo-gate-post stamps the moved head, and the real velo-gate then labels it passed.
prove "a post the poster calls OK is confirmed on the PR" sc_poster_noop \
  '      if ! confirm_on_pr "$name"; then' '      if false; then'
prove "the confirmation waits out a slow read" sc_poster_noop \
  '    [[ $i -ge $MAX_RETRIES ]] && return 1' '    return 1'
prove "a skipped report says its file was not compared" sc_idempotent \
  ' — not posted again (what that comment holds is not compared with $file)"' ' — not posted again"'
prove "the header check tolerates velo-gates own spacing" sc_idempotent \
  'gate: *$1 *@ *${SHA:0:9}' 'gate: $1 @ ${SHA:0:9}'
prove "a stale marker cannot get a label (real velo-gate-post)" sc_real_stale_marker \
  '      if ! confirm_on_pr "$name"; then' '      if false; then'
prove "every post carries the gated sha (real velo-gate-post)" sc_real_stale_head \
  '"$GATE_POST" "$PR" "$name" "$file" --sha "$SHA"' '"$GATE_POST" "$PR" "$name" "$file"'
prove "the verdict flag is passed to velo-gate (real velo-gate)" sc_real_block_no_substitution \
  '"$GATE" "$PR" "$VERDICT"' '"$GATE" "$PR" --pass'

echo
[[ $FAILED -eq 0 ]] && echo "all velo-gate-finish checks passed" || echo "FAILURES"
exit $FAILED

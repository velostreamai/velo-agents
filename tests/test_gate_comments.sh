#!/bin/bash
# velo-gate reads the gate comments honestly: a read that FAILS is not "no gate comment",
# and ONE state is reduced from MANY comments conservatively (#2380 round 3). The same holds for
# the PR's gate LABELS (one verdict from possibly several) — see "the gate label" below.
#
# `velo-gate <pr> --pass` refuses to label a PR passed when a gate comment names a commit
# other than head. That guard keys on the recorded sha being non-empty, and the read behind
# it discarded gh's stderr and never looked at its exit status — so a FAILED read (network
# down, API 5xx, an expired token) came back empty, read as "nothing recorded, nothing to
# compare", skipped the guard, and a stale head got gate:passed. The same read also took
# `| last | .s`: the newest gate comment alone, so a check-code result for a commit that no
# longer existed passed whenever a later code-review comment named the head.
#
# Drives the real velo-gate against a stub gh that runs the CALLER'S OWN jq over a comments
# array (so the expression under test is evaluated, never canned) and can fail the read or
# answer with garbage. Every behaviour is pinned twice: green on the real script and red on
# a copy with that one behaviour mutated out, and the red must be for the pinned reason —
# the mutants are copies in a temp dir; the repo's scripts are never edited.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
GATE_REAL="$BIN/velo-gate"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "velo-gate reads the gate comments honestly"

[[ -f "$GATE_REAL" ]] || { fail "velo-gate not found under $BIN"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin" "$TMPD/tmp"
# velo-gate's scratch file for gh's stderr goes here, so a leftover is seen, not guessed at.
export TMPDIR="$TMPD/tmp"
export VELO_STATE="$TMPD/state"
export PATH="$TMPD/bin:$PATH"
PR=913245
HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"
H9="${HEAD_SHA:0:9}"
O9="${OLD_SHA:0:9}"

export STUB_COMMENTS_JSON="$TMPD/comments.json"
export STUB_META="$TMPD/meta.json"
export STUB_EDITS="$TMPD/edits.txt"
export STUB_CALLS="$TMPD/calls.txt"
export STUB_ISSUE_BODY="$TMPD/issue-body.md"

# Only the calls velo-gate makes: the PR view (head, labels, files, body), the comments read, the
# linked issue's body, label edits.
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
      *"--json headRefOid,labels"*) cat "$STUB_META"; exit 0 ;;
    esac ;;
  "issue view")
    # $3 is the issue number. STUB_ISSUE_FAIL fails every issue, STUB_ISSUE_FAIL_N only that one; an
    # issue has its own body in "$STUB_ISSUE_BODY.<n>" when that file exists, else the shared one.
    if [[ -n "${STUB_ISSUE_FAIL:-}" ]]; then printf '%s\n' "$STUB_ISSUE_FAIL" >&2; exit 1; fi
    if [[ -n "${STUB_ISSUE_FAIL_N:-}" && "$3" == "$STUB_ISSUE_FAIL_N" ]]; then
      printf 'gh: HTTP 502: Bad Gateway\n' >&2; exit 1
    fi
    if [[ -f "$STUB_ISSUE_BODY.$3" ]]; then cat "$STUB_ISSUE_BODY.$3"; else cat "$STUB_ISSUE_BODY"; fi
    exit 0 ;;
  "pr edit")
    printf '%s\n' "$*" >> "$STUB_EDITS"
    # STUB_EDIT_FAIL_REMOVE=<label>: removing that label fails, as a dropped connection would.
    if [[ -n "${STUB_EDIT_FAIL_REMOVE:-}" && "$*" == *"--remove-label ${STUB_EDIT_FAIL_REMOVE}"* ]]; then
      printf 'gh: HTTP 502: Bad Gateway\n' >&2; exit 1
    fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/bin/gh"

# The PR the stub serves: labels from the argument; its files and body from META_FILES / META_BODY
# (a PR touching .agents/bin and closing nothing, by default).
DEFAULT_FILES='[{"path":".agents/bin/x"}]'
set_labels() {   # <label json array, e.g. '[]' or '[{"name":"gate:passed"}]'>
  jq -nc --arg head "$HEAD_SHA" --argjson labels "$1" \
    --argjson files "${META_FILES:-$DEFAULT_FILES}" --arg body "${META_BODY:-}" \
    '{headRefOid: $head, labels: $labels, files: $files, state: "OPEN", title: "stub pr", body: $body}' > "$STUB_META"
}
set_comments() {   # <body> ... — one PR comment each, oldest first
  local json='[]' b
  for b in "$@"; do json=$(jq -c --arg b "$b" '. + [{body: $b}]' <<<"$json"); done
  printf '%s\n' "$json" > "$STUB_COMMENTS_JSON"
}
gate_comment() { printf 'gate: %s @ %s\n\n## report\n**Verdict:** approve\n' "$1" "$2"; }   # <name> <sha>

GATE_UNDER_TEST="$GATE_REAL"
SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has()   { grep -qF -- "$2" "$1" 2>/dev/null; }                  # <file> <fixed string>; a missing file has nothing
scratch_left() { ls -A "$TMPDIR" | grep -F 'velo-gate-err' || true; }
gate() {   # <mode> -> $OUT $RC ; the scenario's STUB_* variables are in the environment
  rm -f "$STUB_EDITS" "$STUB_CALLS"
  OUT=$(bash "$GATE_UNDER_TEST" "$PR" "$1" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/gate.out"
}
# A --pass needs every planned leg reported at head; the stub PR is tooling-only (code-review), so a
# scenario that is not ABOUT the comments starts with that one comment at head.
reset() { set_labels '[]'; set_comments "$(gate_comment code-review "$H9")"; rm -f "$STUB_EDITS" "$STUB_CALLS" "$TMPDIR"/velo-gate-err.*; }

# ── --pass: the guard ─────────────────────────────────────────────────────────
sc_pass_current() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")"
  gate --pass
  [[ $RC -eq 0 ]];                                         sc_check passes $?
  has "$STUB_EDITS" "--add-label gate:passed";             sc_check sets-the-label $?
  [[ -z "$(scratch_left)" ]];                              sc_check no-scratch-file-left $?
}

# The newest comment names head, an older gate's does not: judging the newest alone passed it.
sc_pass_stale_older_leg() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$O9")" "$(gate_comment code-review "$H9")"
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check older-leg-stale-refuses $?
  has "$TMPD/gate.out" "refusing to mark passed";          sc_check says-it-refused $?
  has "$TMPD/gate.out" "check-code ran at $O9";            sc_check names-the-stale-gate-and-its-sha $?
  ! has "$TMPD/gate.out" "code-review ran at";             sc_check does-not-name-the-current-gate $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}

sc_pass_stale_newer_leg() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$O9")"
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check newer-leg-stale-refuses $?
  has "$TMPD/gate.out" "code-review ran at $O9";           sc_check names-the-stale-gate $?
  ! has "$TMPD/gate.out" "check-code ran at";              sc_check does-not-name-the-current-gate $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}

# A gate that was re-run posts a second comment; the first must not condemn it.
sc_pass_rerun_clears_old() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$O9")" "$(gate_comment code-review "$O9")" \
               "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")"
  gate --pass
  [[ $RC -eq 0 ]];                                         sc_check a-rerun-clears-the-old-comment $?
  has "$STUB_EDITS" "--add-label gate:passed";             sc_check sets-the-label $?
}

# velo-merge reads the same comments by the same grammar: `[a-z0-9-]+` is what velo-gate-post mints
# as a gate name, and a header with no readable sha is a gate that names no commit. Both used to be
# invisible here — a stale `check-code2`, or a `check-code @ pending` posted over a good one, was no
# comment at all, so --pass labelled the PR while velo-merge counted the gate as recorded.
sc_pass_digit_named_stale_gate_refuses() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")" "$(gate_comment check-code2 "$O9")"
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/gate.out" "check-code2 ran at $O9";           sc_check names-the-digit-named-gate $?
  ! has "$TMPD/gate.out" "not a gate list";                sc_check does-not-call-it-a-garbled-answer $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}
sc_pass_freshest_gate_without_a_sha_refuses() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")" "$(gate_comment check-code pending)"
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/gate.out" "check-code names no commit";       sc_check names-the-gate-that-names-no-commit $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}
sc_pass_a_rerun_clears_an_old_comment_without_a_sha() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code pending)" "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")"
  gate --pass
  [[ $RC -eq 0 ]];                                         sc_check passes $?
  has "$STUB_EDITS" "--add-label gate:passed";             sc_check sets-the-label $?
}
sc_show_digit_named_and_sha_less_gates_are_stale() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:passed"}]'
  set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code2 "$O9")" "$(gate_comment check-code pending)"
  gate --show
  has "$TMPD/gate.out" "STALE — head is now $H9, but:";    sc_check says-stale $?
  has "$TMPD/gate.out" "check-code2 ran at $O9";           sc_check names-the-digit-named-gate $?
  has "$TMPD/gate.out" "check-code names no commit";       sc_check names-the-gate-that-names-no-commit $?
  ! has "$TMPD/gate.out" "every gate comment matches the current head"; sc_check does-not-say-current $?
}

# No gate comment at all is a successful read of nothing — and a PR with a planned leg and no report
# for it is not passed (a leg that never ran must never read as a pass). The refusal is for the
# MISSING LEG; it must not be mistaken for the unreadable-comments refusal this file also pins.
sc_pass_nothing_recorded() {
  SC_FAILS=""; reset; set_comments
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check refuses-a-planned-leg-with-no-report $?
  has "$TMPD/gate.out" "has no report at head";            sc_check says-the-leg-has-no-report $?
  has "$TMPD/gate.out" "code-review";                      sc_check names-the-missing-leg $?
  ! has "$TMPD/gate.out" "could not read the gate comments"; sc_check does-not-call-it-an-unreadable-read $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}

# ── --pass: a read that cannot be trusted ─────────────────────────────────────
sc_pass_unreadable() {
  SC_FAILS=""; reset
  set_comments "$(gate_comment check-code "$O9")"          # stale — the guard would refuse it, if it could see it
  STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" gate --pass
  [[ $RC -ne 0 ]];                                         sc_check unreadable-read-refuses-the-label $?
  has "$TMPD/gate.out" "could not read the gate comments for #$PR:"; sc_check says-what-it-could-not-do $?
  has "$TMPD/gate.out" "HTTP 502: Bad Gateway";            sc_check shows-ghs-own-error $?
  has "$TMPD/gate.out" "Nothing was changed";              sc_check says-nothing-was-changed $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
  [[ -z "$(scratch_left)" ]];                              sc_check no-scratch-file-left $?
}

# gh's message cannot be captured without a scratch file; the failure must still be a failure.
sc_pass_unreadable_no_scratch() {
  SC_FAILS=""; reset
  mkdir -p "$TMPD/nomktemp"; printf '#!/bin/bash\nexit 1\n' > "$TMPD/nomktemp/mktemp"; chmod +x "$TMPD/nomktemp/mktemp"
  PATH="$TMPD/nomktemp:$PATH" STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" gate --pass
  [[ $RC -ne 0 ]];                                         sc_check unreadable-read-without-a-scratch-file-refuses $?
  has "$TMPD/gate.out" "gh's own message was not captured"; sc_check says-why-there-is-no-message $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
}

# rc 0 with an answer that is not a gate list (a proxy's error page; `null`, which is what the
# expression this one replaced printed for "no gate comment"): not "no gate comment" either.
# `null` is the sharper case — a line with a name and no sha is "not stale" to the comparison,
# so only the shape check stops it.
sc_pass_garbled() {
  SC_FAILS=""; reset
  STUB_COMMENTS_RAW="<html>502 Bad Gateway</html>" gate --pass
  [[ $RC -ne 0 ]];                                         sc_check garbled-answer-refuses-the-label $?
  has "$TMPD/gate.out" "not a gate list";                  sc_check says-what-it-got $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check no-label-was-touched $?
  reset
  STUB_COMMENTS_RAW="null" gate --pass
  [[ $RC -ne 0 ]];                                         sc_check a-null-answer-refuses-the-label $?
  has "$TMPD/gate.out" "not a gate list: 'null'";          sc_check says-it-got-null $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check null-touched-no-label $?
}

# ── --show ────────────────────────────────────────────────────────────────────
sc_show_states() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:passed"}]'
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")"
  gate --show
  [[ $RC -eq 0 ]];                                         sc_check current-exits-0 $?
  has "$TMPD/gate.out" "every gate comment matches the current head"; sc_check current-says-so $?
  set_labels '[]'
  gate --show
  has "$TMPD/gate.out" "but the label is 'gate:none'";     sc_check current-but-unlabelled-says-the-label-is-missing $?
  set_comments "$(gate_comment check-code "$O9")" "$(gate_comment code-review "$H9")"
  gate --show
  [[ $RC -eq 0 ]];                                         sc_check stale-exits-0 $?
  has "$TMPD/gate.out" "STALE — head is now $H9, but:";    sc_check one-stale-leg-is-STALE $?
  has "$TMPD/gate.out" "check-code ran at $O9";            sc_check names-the-stale-leg $?
  set_comments
  gate --show
  [[ $RC -eq 0 ]];                                         sc_check none-exits-0 $?
  has "$TMPD/gate.out" "nothing has been recorded";        sc_check none-says-nothing-recorded $?
}

sc_show_unreadable() {
  SC_FAILS=""; reset
  STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway" gate --show
  [[ $RC -eq 1 ]];                                         sc_check unreadable-exits-1 $?
  has "$TMPD/gate.out" "could not read the gate comments for #$PR: gh: HTTP 502: Bad Gateway"; sc_check says-it-could-not-read-them $?
  has "$TMPD/gate.out" "Cannot say whether the gate is current"; sc_check says-it-cannot-tell $?
  ! has "$TMPD/gate.out" "nothing has been recorded";      sc_check does-not-claim-nothing-was-recorded $?
  has "$TMPD/gate.out" "gates needed:";                    sc_check still-shows-the-rest $?
}

# ── the other modes never needed the comments ─────────────────────────────────
sc_other_modes_do_not_read_comments() {
  SC_FAILS=""; reset
  export STUB_COMMENTS_FAIL="gh: HTTP 502: Bad Gateway"
  gate --block
  [[ $RC -eq 0 ]];                                         sc_check block-needs-no-comments $?
  has "$STUB_EDITS" "--add-label gate:blocked";            sc_check block-sets-the-label $?
  ! has "$STUB_CALLS" "--json comments";                   sc_check block-does-not-read-the-comments $?
  gate --running
  [[ $RC -eq 0 ]];                                         sc_check running-needs-no-comments $?
  ! has "$STUB_CALLS" "--json comments";                   sc_check running-does-not-read-the-comments $?
  gate --plan
  [[ $RC -eq 0 ]];                                         sc_check plan-needs-no-comments $?
  has "$TMPD/gate.out" "gates needed:";                    sc_check plan-prints-the-plan $?
  ! has "$STUB_CALLS" "--json comments";                   sc_check plan-does-not-read-the-comments $?
  unset STUB_COMMENTS_FAIL
}

# ── --plan / --show: the linked issue's acceptance bars ───────────────────────
# An issue that cannot be READ is not an issue with no acceptance bars: counted as 0 it dropped
# check-spec from the plan, and velo-pr-gate / velo-merge act on the plan they are given.
code_pr()  { META_FILES='[{"path":"src/x.rs"}]'; META_BODY='Closes #777'; }   # a code PR that closes #777
plain_pr() { unset META_FILES META_BODY; }

sc_plan_counts_bars() {
  SC_FAILS=""; code_pr; reset
  printf '## Acceptance\n\n- a\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  gate --plan
  [[ $RC -eq 0 ]];                                         sc_check plan-exits-0 $?
  has "$TMPD/gate.out" "check-spec   (#777 has 3 acceptance bars)"; sc_check three-bars-plans-check-spec $?
  printf '## Acceptance\n\n- a\n- b\n' > "$STUB_ISSUE_BODY"
  gate --plan
  [[ $RC -eq 0 ]];                                         sc_check two-bars-plan-exits-0 $?
  ! has "$TMPD/gate.out" "check-spec";                     sc_check two-bars-do-not-plan-check-spec $?
  has "$TMPD/gate.out" "code-review";                      sc_check the-plan-still-has-code-review $?
  plain_pr
}

# The CONSEQUENCE of the fence grammar (test_fence_parity.py pins the grammar itself): a "# comment"
# line inside a fenced shell block, under ## Acceptance, is not a heading that ends the section. A
# tilde fence, or a fence indented inside a bullet whose comment sits at column 0, used to be no
# fence to the counter: the comment closed the section and the bullets after it were not counted,
# so check-spec silently left the plan.
sc_plan_bars_ignore_fenced_comments() {
  SC_FAILS=""; code_pr; reset
  printf '## Acceptance\n\n- a\n~~~bash\n# build it\ncargo build\n~~~\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  gate --plan
  has "$TMPD/gate.out" "check-spec   (#777 has 3 acceptance bars)"; sc_check a-comment-in-a-tilde-fence-does-not-end-the-section $?
  printf '## Acceptance\n\n- a\n   ```bash\n# build it\ncargo build\n   ```\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  gate --plan
  has "$TMPD/gate.out" "check-spec   (#777 has 3 acceptance bars)"; sc_check a-comment-in-an-indented-fence-does-not-end-the-section $?
  printf '## Acceptance\n\n- a\n```bash\n# build it\ncargo build\n```\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  gate --plan
  has "$TMPD/gate.out" "check-spec   (#777 has 3 acceptance bars)"; sc_check a-comment-in-a-plain-fence-does-not-end-the-section $?
  printf '## Acceptance\n\n- a\n# build it\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  gate --plan
  ! has "$TMPD/gate.out" "check-spec";                     sc_check a-heading-outside-any-fence-still-ends-the-section $?
  plain_pr
}

sc_plan_unreadable_issue() {
  SC_FAILS=""; code_pr; reset
  printf '## Acceptance\n\n- a\n- b\n- c\n' > "$STUB_ISSUE_BODY"
  STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway" gate --plan
  [[ $RC -ne 0 ]];                                         sc_check unreadable-issue-refuses-the-plan $?
  has "$TMPD/gate.out" "could not read issue #777, which #$PR closes"; sc_check says-what-it-could-not-do $?
  has "$TMPD/gate.out" "HTTP 502: Bad Gateway";            sc_check shows-ghs-own-error $?
  has "$TMPD/gate.out" "may be missing check-spec";        sc_check says-why-it-refuses $?
  ! has "$TMPD/gate.out" "gates needed";                   sc_check prints-no-plan-at-all $?
  [[ -z "$(scratch_left)" ]];                              sc_check no-scratch-file-left $?
  plain_pr
}

# Docs-only and orchestration PRs never consult the issue: its failure cannot matter to them.
sc_plan_issue_read_only_where_needed() {
  SC_FAILS=""
  META_FILES='[{"path":"docs/x.md"}]'; META_BODY='Closes #777'; reset
  STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway" gate --plan
  [[ $RC -eq 0 ]];                                         sc_check docs-only-plan-needs-no-issue $?
  has "$TMPD/gate.out" "docs only";                        sc_check docs-only-plan-says-so $?
  ! has "$STUB_CALLS" "issue view";                        sc_check docs-only-does-not-read-the-issue $?
  META_FILES='[{"path":".agents/bin/x"}]'; reset
  STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway" gate --plan
  [[ $RC -eq 0 ]];                                         sc_check orchestration-plan-needs-no-issue $?
  ! has "$STUB_CALLS" "issue view";                        sc_check orchestration-does-not-read-the-issue $?
  plain_pr
}

sc_show_unreadable_issue() {
  SC_FAILS=""; code_pr; reset
  STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway" gate --show
  [[ $RC -eq 1 ]];                                         sc_check unreadable-issue-exits-1 $?
  has "$TMPD/gate.out" "could not read issue #777";        sc_check says-it-could-not-read-the-issue $?
  has "$TMPD/gate.out" "INCOMPLETE";                       sc_check says-the-plan-is-incomplete $?
  has "$TMPD/gate.out" "gates needed:";                    sc_check still-shows-the-plan-it-has $?
  has "$TMPD/gate.out" "code-review";                      sc_check including-what-it-knows $?
  plain_pr
}

# ── a PR that closes SEVERAL issues ───────────────────────────────────────────
# GitHub closes every issue the body names when the PR merges, so every one's acceptance bars are
# the PR's business. The body was scanned with `head -1`: the first issue decided check-spec, and
# a second issue that carried the bars was never read.
many_pr()  { META_FILES='[{"path":"src/x.rs"}]'; META_BODY=$'Closes #777\n\nAlso Closes #888'; }
bars_n()   { local n i body='## Acceptance\n\n'; for ((i = 1; i <= $2; i++)); do body="$body- bar $i\n"; done; printf "$body" > "$STUB_ISSUE_BODY.$1"; }   # <issue> <how many bars>
forget_issue_bodies() { rm -f "$STUB_ISSUE_BODY".[0-9]*; }

sc_plan_reads_every_closed_issue() {
  SC_FAILS=""; many_pr; reset; bars_n 777 1; bars_n 888 3
  gate --plan
  [[ $RC -eq 0 ]];                                         sc_check plan-exits-0 $?
  has "$TMPD/gate.out" "check-spec   (#888 has 3 acceptance bars)"; sc_check the-second-issues-bars-plan-check-spec $?
  ! has "$TMPD/gate.out" "#777 has";                       sc_check the-first-issue-has-too-few-to-be-named $?
  has "$STUB_CALLS" "issue view 777 ";                     sc_check read-the-first-issue $?
  has "$STUB_CALLS" "issue view 888 ";                     sc_check read-the-second-issue $?
  forget_issue_bodies; plain_pr
}
sc_plan_names_every_issue_that_warrants_check_spec() {
  SC_FAILS=""; many_pr; reset; bars_n 777 3; bars_n 888 4
  gate --plan
  has "$TMPD/gate.out" "check-spec   (#777 has 3 acceptance bars, #888 has 4 acceptance bars)"; sc_check names-both-issues $?
  [[ "$(grep -c 'check-spec' "$TMPD/gate.out")" == 1 ]];   sc_check one-check-spec-entry $?
  forget_issue_bodies; plain_pr
}
sc_plan_unreadable_second_issue() {
  SC_FAILS=""; many_pr; reset; bars_n 777 1; bars_n 888 3
  STUB_ISSUE_FAIL_N=888 gate --plan
  [[ $RC -ne 0 ]];                                         sc_check unreadable-second-issue-refuses-the-plan $?
  has "$TMPD/gate.out" "could not read issue #888, which #$PR closes"; sc_check names-the-issue-it-could-not-read $?
  ! has "$TMPD/gate.out" "issue #777";                     sc_check does-not-blame-the-issue-it-read $?
  has "$TMPD/gate.out" "HTTP 502: Bad Gateway";            sc_check shows-ghs-own-error $?
  ! has "$TMPD/gate.out" "gates needed";                   sc_check prints-no-plan-at-all $?
  forget_issue_bodies; plain_pr
}
sc_plan_every_unreadable_issue_is_named() {
  SC_FAILS=""; many_pr; reset
  STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway" gate --plan
  [[ $RC -ne 0 ]];                                         sc_check refuses-the-plan $?
  has "$TMPD/gate.out" "could not read issues #777, #888, which #$PR closes"; sc_check names-both-issues $?
  has "$TMPD/gate.out" "#888: gh: HTTP 502: Bad Gateway";  sc_check says-why-for-each $?
  plain_pr
}
sc_show_unreadable_second_issue() {
  SC_FAILS=""; many_pr; reset; bars_n 777 1
  STUB_ISSUE_FAIL_N=888 gate --show
  [[ $RC -eq 1 ]];                                         sc_check exits-1 $?
  has "$TMPD/gate.out" "could not read issue #888";        sc_check names-the-issue-it-could-not-read $?
  has "$TMPD/gate.out" "INCOMPLETE";                       sc_check says-the-plan-is-incomplete $?
  forget_issue_bodies; plain_pr
}
# The keywords are GitHub's own — it closes the issue on merge whichever spelling the body used —
# matched as whole words, in any case.
sc_plan_closing_keywords() {
  SC_FAILS=""; META_FILES='[{"path":"src/x.rs"}]'
  META_BODY=$'fixes #12\nResolved #13\nthis closes: #14\nprefixes #15 and refixes #16\nCLOSES #17'; reset
  printf '## Acceptance\n\n- a\n' > "$STUB_ISSUE_BODY"
  gate --plan
  local n
  for n in 12 13 14 17; do has "$STUB_CALLS" "issue view $n "; sc_check "reads-$n" $?; done
  for n in 15 16; do ! has "$STUB_CALLS" "issue view $n "; sc_check "does-not-read-$n-which-no-keyword-names" $?; done
  plain_pr
}
# A body that cannot be read is not a body that closes nothing.
sc_plan_unreadable_body_refuses() {
  SC_FAILS=""; many_pr; reset
  jq -c '.body = 5' "$STUB_META" > "$STUB_META.new" && mv "$STUB_META.new" "$STUB_META"
  gate --plan
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/gate.out" "could not read the body of #$PR";  sc_check says-what-it-could-not-do $?
  ! has "$TMPD/gate.out" "gates needed";                   sc_check prints-no-plan-at-all $?
  plain_pr
}
sc_plan_reads_each_issue_once() {
  SC_FAILS=""; META_FILES='[{"path":"src/x.rs"}]'; META_BODY=$'Closes #777\n\nCloses #777 again\nfixes #777'; reset
  printf '## Acceptance\n\n- a\n' > "$STUB_ISSUE_BODY"
  gate --plan
  [[ "$(grep -c 'issue view 777 ' "$STUB_CALLS")" == 1 ]]; sc_check reads-it-once $?
  plain_pr
}

sc_label_modes_do_not_read_the_issue() {
  SC_FAILS=""; code_pr; reset
  export STUB_ISSUE_FAIL="gh: HTTP 502: Bad Gateway"
  local m
  for m in --block --running; do
    gate "$m"
    [[ $RC -eq 0 ]];                                       sc_check "$m-needs-no-issue" $?
    ! has "$STUB_CALLS" "issue view";                      sc_check "$m-does-not-read-the-issue" $?
  done
  # --pass must know whether check-spec is planned, so it reads the issue — and fails CLOSED when it
  # cannot: an unknown plan is not an empty plan.
  gate --pass
  [[ $RC -ne 0 ]];                                         sc_check pass-refuses-an-unknown-plan $?
  has "$TMPD/gate.out" "Refusing to mark passed";          sc_check pass-says-why $?
  [[ ! -e "$STUB_EDITS" ]];                                sc_check pass-touched-no-label $?
  unset STUB_ISSUE_FAIL
  plain_pr
}

# ── the gate label: ONE verdict from MANY labels ──────────────────────────────
# A PR can carry two gate labels (a removal that failed, one added by hand in the UI). --show must
# say so, not report whichever the list happened to put first; --pass / --block / --running must
# leave exactly one behind.
sc_label_show_ambiguous() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:blocked"},{"name":"gate:passed"}]'
  set_comments "$(gate_comment check-code "$H9")" "$(gate_comment code-review "$H9")"
  gate --show
  [[ $RC -eq 1 ]];                                         sc_check ambiguous-exits-1 $?
  has "$TMPD/gate.out" "ambiguous gate labels (gate:blocked gate:passed)"; sc_check names-both-labels $?
  ! has "$TMPD/gate.out" "every gate comment matches the current head"; sc_check does-not-say-the-gate-is-current $?
  # the other listing order says the same: neither of them is "the" label
  set_labels '[{"name":"gate:passed"},{"name":"gate:blocked"}]'
  gate --show
  [[ $RC -eq 1 ]];                                         sc_check reversed-order-exits-1 $?
  has "$TMPD/gate.out" "ambiguous gate labels (gate:passed gate:blocked)"; sc_check reversed-order-names-both $?
  ! has "$TMPD/gate.out" "every gate comment matches the current head"; sc_check reversed-order-does-not-say-current $?
}

# --pass over an old verdict replaces it, and removes only what is there.
sc_label_pass_replaces_the_old_label() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:blocked"}]'
  gate --pass
  [[ $RC -eq 0 ]];                                         sc_check passes $?
  has "$STUB_EDITS" "--remove-label gate:blocked";         sc_check removes-the-old-label $?
  has "$STUB_EDITS" "--add-label gate:passed";             sc_check adds-the-new-label $?
  ! has "$STUB_EDITS" "--remove-label gate:running";       sc_check leaves-a-label-that-is-not-there-alone $?
  ! has "$STUB_EDITS" "--remove-label gate:none";          sc_check does-not-remove-gate-none-either $?
}

# A PR that already has two verdict labels comes out of --running with one.
sc_label_running_clears_every_other_gate_label() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:passed"},{"name":"gate:blocked"}]'
  gate --running
  [[ $RC -eq 0 ]];                                         sc_check running-succeeds $?
  has "$STUB_EDITS" "--remove-label gate:passed";          sc_check removes-passed $?
  has "$STUB_EDITS" "--remove-label gate:blocked";         sc_check removes-blocked $?
  has "$STUB_EDITS" "--add-label gate:running";            sc_check adds-running $?
}

# A removal that fails must not become an add: that is how gate:blocked and gate:passed ended up
# on one PR, and velo-merge read it as passed.
sc_label_failed_removal_refuses() {
  SC_FAILS=""; reset
  set_labels '[{"name":"gate:blocked"}]'
  STUB_EDIT_FAIL_REMOVE="gate:blocked" gate --pass
  [[ $RC -ne 0 ]];                                         sc_check refuses $?
  has "$TMPD/gate.out" "could not set gate:passed";        sc_check says-what-it-could-not-do $?
  has "$TMPD/gate.out" "gate:blocked could not be removed"; sc_check names-the-label-it-could-not-remove $?
  ! has "$STUB_EDITS" "--add-label";                       sc_check no-label-was-added $?
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
echo "velo-gate --pass / --show"
run_scenarios \
  "sc_pass_current::every gate current: --pass labels it, and leaves no scratch file" \
  "sc_pass_stale_older_leg::an OLDER gate that names another commit refuses --pass even when the newest comment names head" \
  "sc_pass_stale_newer_leg::the newest gate stale refuses --pass, naming only that gate" \
  "sc_pass_rerun_clears_old::a re-run gate's old comment does not condemn it" \
  "sc_pass_digit_named_stale_gate_refuses::a stale gate whose name has a digit is seen: --pass refuses it, by name" \
  "sc_pass_freshest_gate_without_a_sha_refuses::a gate whose freshest comment names no commit refuses --pass" \
  "sc_pass_a_rerun_clears_an_old_comment_without_a_sha::a re-run at head clears an older comment that named no commit" \
  "sc_show_digit_named_and_sha_less_gates_are_stale::--show reports a digit-named stale gate and a gate with no sha as stale" \
  "sc_pass_nothing_recorded::no gate comment at all is a successful read of nothing, not a refusal" \
  "sc_pass_unreadable::a FAILED read refuses --pass with gh's own error, and touches nothing" \
  "sc_pass_unreadable_no_scratch::...also when gh's message cannot be captured" \
  "sc_pass_garbled::an answer that is not a gate list refuses --pass" \
  "sc_show_states::--show: current, current-but-unlabelled, a stale leg, nothing recorded" \
  "sc_show_unreadable::--show says it could not read the comments (exit 1), never 'nothing has been recorded'" \
  "sc_other_modes_do_not_read_comments::--block / --running / --plan neither read the comments nor die on a failed read" \
  "sc_plan_counts_bars::three acceptance bars plan check-spec, two do not" \
  "sc_plan_bars_ignore_fenced_comments::a comment line in a fenced block does not end the Acceptance section, a heading outside one does" \
  "sc_plan_unreadable_issue::an issue that cannot be read refuses the plan — it is not an issue with no bars" \
  "sc_plan_issue_read_only_where_needed::docs-only and orchestration plans never read the issue" \
  "sc_show_unreadable_issue::--show flags an incomplete plan (exit 1) instead of dropping check-spec" \
  "sc_plan_reads_every_closed_issue::a PR that closes two issues plans check-spec for the SECOND one's bars" \
  "sc_plan_names_every_issue_that_warrants_check_spec::both issues over the bar are named in the one check-spec entry" \
  "sc_plan_unreadable_second_issue::the second issue failing to read refuses the plan, naming it" \
  "sc_plan_every_unreadable_issue_is_named::when several issues cannot be read, every one is named" \
  "sc_show_unreadable_second_issue::--show flags an incomplete plan when the second issue cannot be read" \
  "sc_plan_closing_keywords::every GitHub closing keyword links its issue, as a whole word, in any case" \
  "sc_plan_reads_each_issue_once::an issue the body names three times is read once" \
  "sc_plan_unreadable_body_refuses::a body that cannot be read is refused, not taken as closing nothing" \
  "sc_label_modes_do_not_read_the_issue::--block / --running never read the issue; --pass fails closed on an unreadable plan" \
  "sc_label_show_ambiguous::--show names two gate labels as ambiguous (exit 1), in either order, not as whichever is first" \
  "sc_label_pass_replaces_the_old_label::--pass removes the old verdict label — only if it is there — and adds the new one" \
  "sc_label_running_clears_every_other_gate_label::--running over two verdict labels leaves one" \
  "sc_label_failed_removal_refuses::a label removal that fails stops the run: nothing is added beside the old verdict"

# ── MUTATION-PROOF ────────────────────────────────────────────────────────────
MUT="$TMPD/mut"; mkdir -p "$MUT"
cp "$(dirname "$GATE_REAL")/velo-waiver.jq" "$MUT/velo-waiver.jq"   # the waiver definition sits beside the script, as in bin/
mutate() {   # <anchor> <replacement> [<anchor> <replacement>]... -> $MUT/velo-gate ; each anchor occurs exactly once
  python3 - "$GATE_REAL" "$MUT/velo-gate" "$@" <<'PY'
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
# The mutant's red must NAME the check that pins the behaviour: an unrelated red (a broken stub,
# a typo in the mutation) is not a proof.
prove() {   # <label> <scenario fn> <the check that must go red> <anchor> <replacement> [<anchor> <replacement>]...
  local label="$1" fn="$2" want="$3" red; shift 3
  if ! mutate "$@"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  GATE_UNDER_TEST="$MUT/velo-gate"
  "$fn"; red="$SC_FAILS"
  GATE_UNDER_TEST="$GATE_REAL"
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

echo
echo "mutation proofs"
prove "a failed read refuses --pass" sc_pass_unreadable says-what-it-could-not-do \
  '  if [[ $rc -ne 0 ]]; then' '  if false; then'
prove "a failed read refuses --pass without a scratch file too" sc_pass_unreadable_no_scratch says-why-there-is-no-message \
  'GH_OUT=$(gh "$@" 2>/dev/null); rc=$?' 'GH_OUT=$(gh "$@" 2>/dev/null); rc=0'
prove "the refusal shows gh's own error" sc_pass_unreadable shows-ghs-own-error \
  'die "could not read the gate comments for #$PR: $GATES_ERR' 'die "could not read the gate comments for #$PR'
prove "the scratch file is removed" sc_pass_unreadable no-scratch-file-left \
  'rm -f "$errf"' ':'
prove "a garbled answer refuses --pass" sc_pass_garbled says-what-it-got \
  '    if [[ ! "$line" =~ $GATE_LINE_RE ]]; then' '    if false; then'
prove "the newest comment alone is not the state" sc_pass_stale_older_leg older-leg-stale-refuses \
  '| reduce .[] as $g ({}; .[$g.n] = ($g.s // "-")) | to_entries[] | "\(.key) \(.value)"' '| (last // empty) | "\(.n) \(.s)"'
prove "a re-run gate's old comment does not condemn it" sc_pass_rerun_clears_old a-rerun-clears-the-old-comment \
  '| reduce .[] as $g ({}; .[$g.n] = ($g.s // "-")) | to_entries[] | "\(.key) \(.value)"' '| .[] | "\(.n) \(.s)"'
prove "a gate name may carry a digit" sc_pass_digit_named_stale_gate_refuses names-the-digit-named-gate \
  '*gate: *(?<n>[a-z0-9-]+) *@ *(?<s>[0-9a-f]{7,40})?")]' '*gate: *(?<n>[a-z-]+) *@ *(?<s>[0-9a-f]{7,40})?")]'
prove "the gate-list shape check accepts a digit in a name" sc_pass_digit_named_stale_gate_refuses names-the-digit-named-gate \
  "GATE_LINE_RE='^[a-z0-9-]+ ([0-9a-f]{7,40}|-)\$'" "GATE_LINE_RE='^[a-z-]+ ([0-9a-f]{7,40}|-)\$'"
prove "a header with no readable sha is still a gate comment" sc_pass_freshest_gate_without_a_sha_refuses refuses \
  '(?<s>[0-9a-f]{7,40})?")]' '(?<s>[0-9a-f]{7,40})")]'
prove "the gate-list shape check accepts a gate that names no commit" sc_pass_freshest_gate_without_a_sha_refuses names-the-gate-that-names-no-commit \
  "GATE_LINE_RE='^[a-z0-9-]+ ([0-9a-f]{7,40}|-)\$'" "GATE_LINE_RE='^[a-z0-9-]+ ([0-9a-f]{7,40})\$'"
prove "a gate that names no commit is named as such" sc_pass_freshest_gate_without_a_sha_refuses names-the-gate-that-names-no-commit \
  '    if [[ "$gsha" == "-" ]]; then' '    if false; then'
prove "--show reports a digit-named stale gate" sc_show_digit_named_and_sha_less_gates_are_stale names-the-digit-named-gate \
  '*gate: *(?<n>[a-z0-9-]+) *@ *(?<s>[0-9a-f]{7,40})?")]' '*gate: *(?<n>[a-z-]+) *@ *(?<s>[0-9a-f]{7,40})?")]'
prove "--show reports a gate that names no commit" sc_show_digit_named_and_sha_less_gates_are_stale names-the-gate-that-names-no-commit \
  '    if [[ "$gsha" == "-" ]]; then' '    if false; then'
prove "a stale gate refuses --pass" sc_pass_stale_newer_leg names-the-stale-gate \
  '      [[ -z "$STALE_GATES" ]] \' '      : \'
prove "a planned leg with no report refuses --pass" sc_pass_nothing_recorded refuses-a-planned-leg-with-no-report \
  '      [[ -z "$MISSING" ]] \' '      : \'
prove "--show says it could not read the comments" sc_show_unreadable says-it-cannot-tell \
  '    if ! read_gate_comments; then' '    if false; then'
prove "--show exits 1 on an unreadable read" sc_show_unreadable unreadable-exits-1 \
  "Cannot say whether the gate is current — this is not 'no gate comment'.\"
      SHOW_RC=1" "Cannot say whether the gate is current — this is not 'no gate comment'.\"
      SHOW_RC=0"
prove "--show exits 1 on an unreadable issue" sc_show_unreadable_issue unreadable-issue-exits-1 \
  "whether check-spec is needed is unknown, not 'no'.\"
      SHOW_RC=1" "whether check-spec is needed is unknown, not 'no'.\"
      SHOW_RC=0"
prove "--show names every stale leg" sc_show_states names-the-stale-leg \
  '        warn "STALE — head is now $SHORT, but:$STALE_GATES' '        warn "STALE — head is now $SHORT'
prove "the comments are read only where they are used" sc_other_modes_do_not_read_comments block-does-not-read-the-comments \
  'SHOW_RC=0
case "$MODE" in' 'SHOW_RC=0
read_gate_comments || die "eager read"
case "$MODE" in'
prove "a tilde fence is a fence to the bar counter" sc_plan_bars_ignore_fenced_comments a-comment-in-a-tilde-fence-does-not-end-the-section \
  'if (ind <= 3 && (ch == "`" || ch == "~"))' 'if (ind <= 3 && (ch == "`"))'
prove "an indented fence is a fence to the bar counter" sc_plan_bars_ignore_fenced_comments a-comment-in-an-indented-fence-does-not-end-the-section \
  'if (ind <= 3 && (ch == "`" || ch == "~"))' 'if (ind == 0 && (ch == "`" || ch == "~"))'
prove "a heading outside a fence ends the Acceptance section" sc_plan_bars_ignore_fenced_comments a-heading-outside-any-fence-still-ends-the-section \
  '               if (d <= depth) { inrange=0; next }' '               if (d <= depth) { next }'
prove "an unreadable issue refuses the plan" sc_plan_unreadable_issue unreadable-issue-refuses-the-plan \
  '  if [[ $rc -ne 0 ]]; then' '  if false; then'
prove "the plan is not printed without the bars" sc_plan_unreadable_issue unreadable-issue-refuses-the-plan \
  '      count_acceptance_bars || return 1' '      count_acceptance_bars || :'
prove "--show flags an incomplete plan" sc_show_unreadable_issue says-the-plan-is-incomplete \
  '    if ! build_need; then' '    if false; then'
prove "the issue is read only for a plan that needs it" sc_plan_issue_read_only_where_needed docs-only-does-not-read-the-issue \
  '    NEED+=("none — docs only, no buildable code and no orchestration")' '    NEED+=("none — docs only, no buildable code and no orchestration")
    count_acceptance_bars || return 1'
prove "the issue is read only where a plan is printed" sc_label_modes_do_not_read_the_issue --block-does-not-read-the-issue \
  'SHOW_RC=0
case "$MODE" in' 'SHOW_RC=0
build_need || die "eager read"
case "$MODE" in'
prove "three acceptance bars plan check-spec" sc_plan_counts_bars three-bars-plans-check-spec \
  '[[ "$BARS" -ge 3 ]] && hit=' '[[ "$BARS" -ge 4 ]] && hit='
prove "every closed issue is read, not the first" sc_plan_reads_every_closed_issue the-second-issues-bars-plan-check-spec \
  '  for n in $ISSUES; do' '  for n in $(head -n 1 <<<"$ISSUES"); do'
prove "an issue that cannot be read refuses the plan, whichever it is" sc_plan_unreadable_second_issue unreadable-second-issue-refuses-the-plan \
  '      nbad=$((nbad + 1)); bad="${bad:+$bad, }#$n"; lone="$GH_ERR"; errs="${errs:+$errs; }#$n: $GH_ERR"' '      :'
prove "every issue that cannot be read is named" sc_plan_every_unreadable_issue_is_named names-both-issues \
  'BARS_UNREADABLE="issues $bad"; BARS_ERR="$errs"; return 1' 'BARS_UNREADABLE="issue ${bad%%,*}"; BARS_ERR="$errs"; return 1'
prove "each unreadable issue says why" sc_plan_every_unreadable_issue_is_named says-why-for-each \
  'errs="${errs:+$errs; }#$n: $GH_ERR"' 'errs="${errs:+$errs; }$GH_ERR"'
prove "every issue over the bar is named" sc_plan_names_every_issue_that_warrants_check_spec names-both-issues \
  'hit="${hit:+$hit, }#$n has $BARS acceptance bars"' 'hit="#$n has $BARS acceptance bars"'
prove "the closing keywords are GitHub's, in any case" sc_plan_closing_keywords reads-12 \
  '\\b(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?):?\\s+#([0-9]+)"; "i")' '\\b(?:Closes|Fixes)\\s+#([0-9]+)"; "")'
prove "a keyword is matched as a whole word" sc_plan_closing_keywords does-not-read-15-which-no-keyword-names \
  'scan("\\b(?:close' 'scan("(?:close'
prove "a keyword is matched in any case" sc_plan_closing_keywords reads-17 \
  ':?\\s+#([0-9]+)"; "i")' ':?\\s+#([0-9]+)"; "")'
prove "an issue named twice is read once" sc_plan_reads_each_issue_once reads-it-once \
  '                | unique | .[]' '                | .[]'
prove "a body that cannot be read refuses" sc_plan_unreadable_body_refuses refuses \
  '  || die "could not read the body of #$PR to find the issues it closes"' '  || true'
prove "two gate labels are reported as ambiguous, not as the first listed" sc_label_show_ambiguous names-both-labels \
  '     CUR="$GATE_AMBIGUOUS  (AMBIGUOUS: a PR has one gate label)" ;;' '     CUR=$(head -n 1 <<<"$GATE_LABELS") ;;' \
  '  *) GATE_AMBIGUOUS=$(tr '"'"'\n'"'"' '"'"' '"'"' <<<"$GATE_LABELS" | sed '"'"'s/ $//'"'"')' '  *) GATE_AMBIGUOUS=""'
prove "--show exits 1 on ambiguous gate labels" sc_label_show_ambiguous ambiguous-exits-1 \
  '       replaces them: velo-gate $PR --pass | --block"
      SHOW_RC=1' '       replaces them: velo-gate $PR --pass | --block"
      SHOW_RC=0'
prove "--pass removes the old verdict label" sc_label_pass_replaces_the_old_label removes-the-old-label \
  '      [[ ",$LABELS," == *",$l,"* ]] || continue' '      continue'
prove "only labels that are on the PR are removed" sc_label_pass_replaces_the_old_label leaves-a-label-that-is-not-there-alone \
  '      [[ ",$LABELS," == *",$l,"* ]] || continue' '      :'
prove "--running removes every other verdict label" sc_label_running_clears_every_other_gate_label removes-blocked \
  '      [[ ",$LABELS," == *",$l,"* ]] || continue' '      [[ "$l" == "gate:passed" ]] || continue'
prove "a failed label removal stops the run" sc_label_failed_removal_refuses refuses \
  '      gh pr edit "$PR" --repo "$REPO" --remove-label "$l" >/dev/null 2>&1 \' '      gh pr edit "$PR" --repo "$REPO" --remove-label "$l" >/dev/null 2>&1; true \'

echo
[[ $FAILED -eq 0 ]] && echo "all gate-comment checks passed" || echo "FAILURES"
exit $FAILED

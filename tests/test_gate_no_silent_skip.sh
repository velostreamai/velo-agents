#!/bin/bash
# A gate leg that did not run must never read as a pass.
#
# #2756/#2758/#2761/#2762 went gate:passed with check-code posted as "NOT RUN (declared)" and
# check-spec never planned. Three holes let that through, and each is pinned here:
#   1. velo-gate-post stamped `gate: check-code @ <sha>` over a body saying the leg did not run.
#   2. velo-gate --pass compared only the gates that were RECORDED, so a planned leg with no
#      report at all was invisible to it.
#   3. velo-gate planned check-spec only from a closing keyword ("Fixes #N"); "Part B of #N" and
#      "Parent: #N" planned nothing.
# A waiver is the one sanctioned way past a leg: its own comment kind, a named approver.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "a gate leg that did not run never reads as a pass"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin" "$TMPD/tmp"
export TMPDIR="$TMPD/tmp" VELO_STATE="$TMPD/state" PATH="$TMPD/bin:$PATH"
PR=913246
HEAD_SHA="1111111111111111111111111111111111111111"; H9="${HEAD_SHA:0:9}"
export STUB_COMMENTS_JSON="$TMPD/comments.json" STUB_META="$TMPD/meta.json" \
       STUB_EDITS="$TMPD/edits.txt" STUB_POSTS="$TMPD/posts.txt"

cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
jqexpr() { local prev="" a; for a in "$@"; do [[ "$prev" == "--jq" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json comments"*) jq -r "$(jqexpr "$@")" <<<"{\"comments\": $(cat "$STUB_COMMENTS_JSON")}"; exit $? ;;
      *"--json headRefOid,labels"*) cat "$STUB_META"; exit 0 ;;
    esac ;;
  "issue view") exit 0 ;;
  "pr edit")    printf '%s\n' "$*" >> "$STUB_EDITS"; exit 0 ;;
  "pr comment") printf '%s\n' "$*" >> "$STUB_POSTS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/bin/gh"

set_pr() {   # <files json> <title>
  jq -nc --arg head "$HEAD_SHA" --argjson files "$1" --arg title "$2" \
    '{headRefOid:$head, labels:[], files:$files, state:"OPEN", title:$title, body:"Parent: #1. Part B of #2."}' > "$STUB_META"
}
# A comment body starting <NONE> is by a drive-by commenter (authorAssociation NONE); the rest are the owner's.
set_comments() { local json='[]' b assoc; for b in "$@"; do assoc=OWNER; if [[ "$b" == "<NONE>"* ]]; then assoc=NONE; b="${b#<NONE>}"; fi; json=$(jq -c --arg b "$b" --arg a "$assoc" '. + [{body:$b, authorAssociation:$a}]' <<<"$json"); done; printf '%s\n' "$json" > "$STUB_COMMENTS_JSON"; }
gate_comment() { printf 'gate: %s @ %s\n\n## report\n**Verdict:** approve\n' "$1" "$2"; }
waiver() { printf 'gate-waived: %s @ %s\nApproved by: %s\nReason: docs-only\n' "$1" "$2" "$3"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
run_gate() { rm -f "$STUB_EDITS"; OUT=$(bash "$BIN/velo-gate" "$PR" "$1" 2>&1); RC=$?; printf '%s\n' "$OUT" > "$TMPD/gate.out"; }
# Defined here, above every use: a call before the definition is "post: command not found", an empty $OUT, and a "not refused" that proves nothing.
post() { printf '%s\n' "$1" > "$TMPD/report.md"; bash "$BIN/velo-gate-post" 999999999 "$2" "$TMPD/report.md" --sha deadbeef 2>&1 || true; }

SRC_FILES='[{"path":"src/velostream/a.rs"},{"path":"tests/unit/a_test.rs"}]'

# --- 3. a parent-tracked PR plans check-spec -----------------------------------------------
set_pr "$SRC_FILES" "[#2231] #1: a child PR"; set_comments
run_gate --plan
if has "$TMPD/gate.out" "check-spec"; then ok "a [#N] child PR touching src plans check-spec without a closing keyword"
else fail "no check-spec planned for a [#N] child PR (output: $(tr '\n' ' ' <"$TMPD/gate.out"))"; fi

# A mixed PR (src/ AND .agents/) takes the orchestration branch of the planner; the child rule must still apply.
set_pr '[{"path":"src/velostream/a.rs"},{"path":".agents/bin/x"}]' "[#2231] #1: a mixed child PR"
run_gate --plan
if has "$TMPD/gate.out" "check-spec" && has "$TMPD/gate.out" "check-code"; then ok "a mixed src+.agents [#N] PR plans check-code AND check-spec"
else fail "mixed src+.agents [#N] PR lost a leg (output: $(tr '\n' ' ' <"$TMPD/gate.out"))"; fi

set_pr "$SRC_FILES" "an untracked change"
run_gate --plan
if has "$TMPD/gate.out" "check-spec"; then fail "check-spec planned for a PR with no parent tag and no closing issue"
else ok "a PR with no parent tag and no closing issue does not plan check-spec"; fi

# --- 2. --pass needs every planned leg --------------------------------------------------------
set_pr "$SRC_FILES" "[#2231] #1: a child PR"
set_comments "$(gate_comment code-review "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]] && has "$TMPD/gate.out" "check-code" && has "$TMPD/gate.out" "check-spec" && [[ ! -e "$STUB_EDITS" ]]; then
  ok "--pass refuses while planned check-code and check-spec have no report, and sets no label"
else fail "--pass accepted a PR with planned legs unreported (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-300)"; fi

set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(gate_comment check-spec "$H9")"
run_gate --pass
if [[ $RC -eq 0 ]] && has "$STUB_EDITS" "--add-label gate:passed"; then ok "--pass accepts once every planned leg has a report at head"
else fail "--pass refused a complete gate (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-300)"; fi

set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(waiver check-spec "$H9" "neil")"
run_gate --pass
if [[ $RC -eq 0 ]]; then ok "a waiver with a named approver, at head, stands in for a leg"
else fail "a valid waiver was refused (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-300)"; fi

set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(printf 'gate-waived: check-spec @ %s\nReason: cheap\n' "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a waiver with no named approver is refused"
else fail "a waiver with no approver passed the gate"; fi

set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(waiver check-spec "2222222222" "neil")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a waiver for an older head does not cover the current head"
else fail "a stale waiver passed the gate"; fi

# velo-merge accepts these reviewer-named aliases for code-review; --pass must not refuse what it accepts
set_pr "$SRC_FILES" "an untracked change"
set_comments "$(gate_comment codex-review "$H9")" "$(gate_comment check-code "$H9")"
run_gate --pass
if [[ $RC -eq 0 ]]; then ok "a codex-review report satisfies the planned code-review (the alias velo-merge accepts)"
else fail "codex-review alias refused (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-300)"; fi

# whitespace is not a name
set_pr "$SRC_FILES" "[#2231] #1: a child PR"
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(printf 'gate-waived: check-spec @ %s\nApproved by: \t \nReason: x\n' "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a tab/space-only approver does not count as a name"
else fail "a whitespace-only approver waived a leg"; fi

# the approver must be authenticated (a repo commenter), and a name is not Unicode whitespace
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "<NONE>$(waiver check-spec "$H9" "Alice")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a waiver posted by a non-collaborator does not count, whatever name it carries"
else fail "a drive-by commenter's waiver passed the gate"; fi
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(printf 'gate-waived: check-spec @ %s\nApproved by: \xe2\x80\x83\nReason: x\n' "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "an approver of only Unicode whitespace (U+2003) does not count"
else fail "a Unicode-whitespace approver waived a leg"; fi

# a waiver is its own comment, from its first line: an ordinary gate report that QUOTES waiver text is not one
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(printf 'gate: code-review @ %s\n\nQuoting an old thread:\ngate-waived: check-spec @ %s\nApproved by: Alice\n' "$H9" "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a gate report that merely quotes waiver text is not a waiver"
else fail "a quoted waiver in an ordinary report waived a leg"; fi

# the finish handoff names check-spec when the round produced a spec.log (grep-level: velo-gate-run's
# next_steps needs a whole stubbed round to run, which test_gate_run.sh owns)
if grep -q 'spec.log' "$BIN/velo-gate-run" && grep -q -- '--check-spec post-cs-' "$BIN/velo-gate-run"; then ok "velo-gate-run's Next section offers the check-spec report and the --check-spec finish"
else fail "velo-gate-run's handoff does not mention check-spec"; fi

# a short (ambiguous) sha cannot waive: 7 hex characters collide, so a waiver names 9+
set_pr "$SRC_FILES" "[#2231] #1: a child PR"
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(waiver check-spec "${H9:0:7}" "neil")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a waiver naming only a 7-character sha does not count"
else fail "a 7-character-sha waiver covered a leg"; fi

# a quoted gate header is not a report: it must open the comment
set_pr "$SRC_FILES" "an untracked change"
set_comments "$(gate_comment code-review "$H9")" "$(printf 'I did not run check-code.\n\ngate: check-code @ %s\n' "$H9")"
run_gate --pass
if [[ $RC -ne 0 ]]; then ok "a comment that merely QUOTES 'gate: check-code @ <head>' is not a check-code report"
else fail "a quoted gate header satisfied a planned leg"; fi

# control characters, vertical tab, NEL and zero-width characters are not names
set_pr "$SRC_FILES" "[#2231] #1: a child PR"
for esc in '\x0b' '\x0c' '\xc2\x85' '\xe2\x80\x8b'; do
  set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(printf "gate-waived: check-spec @ %s\nApproved by: $esc\nReason: x\n" "$H9")"
  run_gate --pass
  if [[ $RC -ne 0 ]]; then ok "an approver of only control/invisible characters ($esc) does not count"
  else fail "approver made of $esc waived a leg"; fi
done

# a leg reported at an OLD head and waived at the CURRENT head is covered by the waiver
set_comments "$(gate_comment code-review "$H9")" "$(gate_comment check-code "$H9")" "$(gate_comment check-spec "2222222222")" "$(waiver check-spec "$H9" "neil")"
run_gate --pass
if [[ $RC -eq 0 ]]; then ok "a current waiver covers a leg whose only report is for an older head"
else fail "a stale report blocked a validly waived leg (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-250)"; fi

# a stale reviewer-named alias (codex-review) is covered by a current code-review waiver
set_pr "$SRC_FILES" "an untracked change"
set_comments "$(gate_comment codex-review "2222222222")" "$(gate_comment check-code "$H9")" "$(waiver code-review "$H9" "neil")"
run_gate --pass
if [[ $RC -eq 0 ]]; then ok "a current code-review waiver covers a stale codex-review report"
else fail "stale codex-review alias blocked a waived code-review (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-250)"; fi

# a waiver names its head by 9+ hex characters; the producer refuses a shorter sha instead of posting a dead waiver
OUT=$(bash "$BIN/velo-gate-finish" "$PR" "${H9:0:7}" --pass --waive check-spec='tiny' --approved-by neil 2>&1 || true)
if grep -q 'sha of 9+ hex' <<<"$OUT"; then ok "velo-gate-finish --waive refuses a 7-character sha"
else fail "velo-gate-finish --waive accepted a 7-character sha: ${OUT:0:200}"; fi

# the daemon and finish read "already posted" the way velo-gate does: a header must OPEN a comment
LIBSH="$BIN/velo-orch-lib.sh"
quoted=$(printf 'I did not run it.\ngate: check-code @ %s\n---\ngate: code-review @ %s\nreport' "$H9" "$H9")
if ( set +u; . "$LIBSH" >/dev/null 2>&1; orch_comments_open_with "gate: code-review @ $H9" <<<"$quoted" && ! orch_comments_open_with "gate: check-code @ $H9" <<<"$quoted" ); then
  ok "orch_comments_open_with: a header that opens a comment counts, one quoted below the first line does not"
else fail "orch_comments_open_with does not anchor to the start of a comment"; fi

# NOT RUN naming a sub-check of the gate (or a longer gate name) is not a declaration about the gate
for body in 'NOT RUN: check-code integration tests due to credentials; static review completed.' \
            'NOT RUN: check-code-extra was skipped'; do
  OUT=$(post "$body" check-code)
  if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused: ${body:0:50}"
  else ok "not refused: ${body:0:50}"; fi
done

# a tooling-only PR still needs only code-review
set_pr '[{"path":".agents/bin/x"}]' "tooling"
set_comments "$(gate_comment code-review "$H9")"
run_gate --pass
if [[ $RC -eq 0 ]]; then ok "a tooling-only PR needs only its code-review"
else fail "a tooling-only PR was refused (rc=$RC): $(tr '\n' ' ' <"$TMPD/gate.out" | cut -c1-300)"; fi

# --- 1. velo-gate-post refuses a leg that did not run ------------------------------------------
for body in 'check-code leg NOT RUN (declared); covered by Codex.' \
            'NOT RUN: check-code was skipped to save tokens' \
            'The check-code gate was skipped.'; do
  OUT=$(post "$body" check-code)
  if grep -q 'says the leg did not run' <<<"$OUT"; then ok "refuses: ${body:0:46}"
  else fail "ACCEPTED a non-report: ${body:0:46}"; fi
done

OUT=$(post "## Findings
No P1. One note: the integration lane was not run locally; reasoning-only.
**Verdict:** approve-with-findings" check-code)
if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a real report that mentions an unrun test later on"
else ok "a real report that mentions an unrun test is not refused"; fi

# sub-checks skipped inside a report that DID run are not a declaration that the gate did not
OUT=$(post "Skipped: integration tests locally; check-code review completed.
**Verdict:** approve-with-findings" check-code)
if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a check-code report that lists a skipped sub-check"
else ok "a report listing a skipped sub-check is not a declaration that the gate did not run"; fi

# skipped TESTS inside a gate that ran are not a declaration that the gate did not run
OUT=$(post "check-code tests were skipped because CI has no credentials; the review itself completed.
**Verdict:** approve" check-code)
if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a check-code report about skipped tests"
else ok "a report about skipped tests (not the leg) is not refused"; fi

# only a declaration that the leg itself did not run is refused: "<gate> skipped <thing>" is a sub-check
OUT=$(post "Summary: check-code skipped the stale test fixture because it is unrelated; the review completed.
**Verdict:** approve" check-code)
if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a check-code report that says it skipped one fixture"
else ok "'<gate> skipped <a fixture>' is a sub-check, not a declaration that the gate did not run"; fi

# an unqualified "skipped" next to the gate name, or a "## Skipped" section, is not a declaration either
for body in 'check-code review skipped integration tests because credentials are unavailable; static review completed' \
            '## Skipped
Integration tests (no credentials). The check-code review itself completed.'; do
  OUT=$(post "$body" check-code)
  if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a report that only skipped a sub-check: ${body:0:40}"
  else ok "not refused: ${body:0:50}"; fi
done

# a report for ONE gate that documents ANOTHER gate's approved waiver is still a report
OUT=$(post "The check-code leg was skipped under an approved waiver; this code-review ran in full.
**Verdict:** approve" code-review)
if grep -q 'says the leg did not run' <<<"$OUT"; then fail "refused a code-review that mentions another leg's waiver"
else ok "a report that mentions ANOTHER leg's waiver is not refused"; fi

# --- waiving through velo-gate-finish
OUT=$(bash "$BIN/velo-gate-finish" "$PR" "$H9" --pass --waive check-spec='tiny' --approved-by "$(printf '\xe2\x80\x83')" 2>&1 || true)
if grep -q 'waive needs --approved-by' <<<"$OUT"; then ok "--approved-by of only Unicode whitespace is refused before anything is posted"
else fail "a Unicode-whitespace approver was accepted by velo-gate-finish: ${OUT:0:200}"; fi
printf '%s\n' "## ok" > "$TMPD/cr.md"
OUT=$(bash "$BIN/velo-gate-finish" "$PR" "$H9" --pass --waive check-spec='tiny' --approved-by '  ' 2>&1 || true)
if grep -q 'waive needs --approved-by' <<<"$OUT"; then ok "--approved-by with only whitespace is refused"
else fail "a whitespace approver was accepted by velo-gate-finish: ${OUT:0:200}"; fi
OUT=$(bash "$BIN/velo-gate-finish" "$PR" "$H9" --pass --waive check-spec='tiny' 2>&1 || true)
if grep -q 'waive needs --approved-by' <<<"$OUT"; then ok "--waive without --approved-by is refused"
else fail "--waive without an approver was accepted: ${OUT:0:200}"; fi

exit $FAILED

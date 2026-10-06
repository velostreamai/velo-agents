#!/usr/bin/env bash
# verdict_of (velo-orch-lib.sh) reduces a gate report to ONE verdict, and velo-orchestrd acts on
# it: approve may pass the PR, blocked blocks it, and "" ("missing or unparseable") escalates to a
# human — "never silently pass or block", in the function's own words.
#
# One verdict is derived from MANY `**Verdict:**` lines. It used to be the FIRST line's, so a
# report that opened with `approve` and later said `blocked` — a restated header, a re-check
# section, a quoted earlier round — was an approve to the daemon: an early line outvoting a later
# one. Every verdict line now has to agree, and one that does not parse is not an agreement.
#
# The function is sourced and called, not re-implemented; each behaviour is also pinned RED on a
# COPY of the library with that behaviour mutated out (the repo's file is never edited).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
LIB="$BIN/velo-orch-lib.sh"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -f "$LIB" ]] || { fail "velo-orch-lib.sh not found at $LIB"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export VELO_STATE="$T/state"; mkdir -p "$VELO_STATE/orch"

verdict_with() {   # <library file> <report text> -> what verdict_of returns for it
  ( source "$1"; verdict_of "$2" )
}

TEMPLATE='**Verdict:** approve | approve-with-findings | blocked'

# Every case runs against the library given; the names of the ones that fail land in CASE_FAILS.
CASE_FAILS=""
case_is() {   # <library> <name> <expected verdict, "" for none> <report text>
  local got
  got=$(verdict_with "$1" "$4")
  [[ "$got" == "$3" ]] || CASE_FAILS="$CASE_FAILS $2"
}
run_cases() {   # <library> -> CASE_FAILS
  local lib="$1"
  CASE_FAILS=""
  # one verdict line, the three words and the shapes models really write them in
  case_is "$lib" approve                   approve                $'## Codex review\n**Verdict:** approve\n\nno findings\n'
  case_is "$lib" approve-with-findings     approve-with-findings  $'**Verdict:** approve-with-findings\n\nsome nit\n'
  case_is "$lib" blocked                   blocked                $'**Verdict:** blocked\n'
  case_is "$lib" trailing-prose            blocked                $'**Verdict:** blocked. One wrong-topic defect.\n\n### Findings\n...\n'
  case_is "$lib" lower-case-label-and-word approve                $'**verdict:** Approve\n'
  # nothing usable: the caller escalates
  case_is "$lib" no-verdict-line           ""                     $'## Codex review\nlooks fine to me\n'
  case_is "$lib" unfilled-template         ""                     "$TEMPLATE"$'\n'
  case_is "$lib" unknown-word              ""                     $'**Verdict:** request-changes\n'
  case_is "$lib" empty-value               ""                     $'**Verdict:**\n'
  # several lines
  case_is "$lib" two-agreeing-lines        approve                $'**Verdict:** approve\n\n### Re-check\n**Verdict:** approve\n'
  case_is "$lib" approve-then-blocked      ""                     $'**Verdict:** approve\n\n### Re-check\n**Verdict:** blocked\n'
  case_is "$lib" blocked-then-approve      ""                     $'**Verdict:** blocked\n\n### Re-check\n**Verdict:** approve\n'
  case_is "$lib" approve-then-findings     ""                     $'**Verdict:** approve\n...\n**Verdict:** approve-with-findings\n'
  case_is "$lib" approve-then-unknown-word ""                     $'**Verdict:** approve\n...\n**Verdict:** needs-work\n'
  case_is "$lib" unknown-word-then-approve ""                     $'**Verdict:** pending\n...\n**Verdict:** approve\n'
}

echo "verdict_of: one verdict from many lines"
run_cases "$LIB"
if [[ -z "$CASE_FAILS" ]]; then
  ok "all cases hold against the real library"
else
  fail "cases that fail against the real library:$CASE_FAILS"
fi

# MUTATION-PROOF — each rule goes red on a copy with that rule removed. A mutation whose anchor
# is not in the library exactly once is a failed proof, never a skipped one.
prove() {   # <label> <must-be-red cases...> -- <anchor> <replacement>
  local label="$1"; shift
  local want=() a
  while [[ $# -gt 0 && "$1" != "--" ]]; do want+=("$1"); shift; done
  shift
  local anchor="$1" repl="$2"
  mkdir -p "$T/mut"
  if ! python3 - "$LIB" "$T/mut/velo-orch-lib.sh" "$anchor" "$repl" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
  then
    fail "MUTATION-PROOF $label: anchor not found — did the library change shape?"
    return
  fi
  run_cases "$T/mut/velo-orch-lib.sh"
  local missing=""
  for a in "${want[@]}"; do
    [[ " $CASE_FAILS " == *" $a "* ]] || missing="$missing $a"
  done
  if [[ -n "$missing" ]]; then
    fail "MUTATION-PROOF $label: these cases stayed GREEN with the rule removed:$missing (red was:$CASE_FAILS)"
  else
    run_cases "$LIB"
    if [[ -z "$CASE_FAILS" ]]; then
      ok "MUTATION-PROOF $label: red with the rule removed ($(printf '%s ' "${want[@]}")), green restored"
    else
      fail "MUTATION-PROOF $label: the real library is red too:$CASE_FAILS"
    fi
  fi
}

prove "two different verdicts are no verdict" approve-then-blocked blocked-then-approve approve-then-findings -- \
  '    elif [[ "$verdict" != "$val" ]]; then' '    elif false; then'
prove "a verdict line that does not parse is no verdict, wherever it is" approve-then-unknown-word unknown-word-then-approve -- \
  '      *) echo ""; return ;;' '      *) continue ;;'

echo
[[ $FAILED -eq 0 ]] && echo "all verdict_of checks passed" || echo "FAILURES"
exit $FAILED

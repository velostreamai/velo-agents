#!/bin/bash
# END-TO-END preflight checks, driving the REAL velo-dispatch (#2027 round 6).
#
# test_brief_fields.sh exercises the extractor HELPERS in isolation, and that is
# why it did not notice when a rewrite deleted the WORKTREE comparison entirely:
# every helper still returned the right value, and the script that consumes them
# no longer compared anything. `WORKTREE: /tmp/completely-wrong` printed
# "ok brief BRANCH/WORKTREE match what will be cut".
#
# Unit-testing the parts you are thinking about does not test the behaviour. This
# file runs `velo-dispatch --dry-run` and asserts on what it actually says.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# A spec-less, worker-labelled issue is needed to reach section 4. Without one,
# these are skipped rather than silently passing.
ISSUE="${VELO_TEST_ISSUE:-}"
if [[ -z "$ISSUE" ]]; then
  echo "  SKIP  set VELO_TEST_ISSUE to an OPEN issue with a worker:* label and no"
  echo "        .agents/tasks/<n>.json to run the end-to-end preflight checks"
  exit 0
fi

brief() {  # $1 = worktree line, $2 = branch line
  local f="$TMPD/b.md"
  { [[ -n "$1" ]] && echo "$1"; [[ -n "$2" ]] && echo "$2"
    echo "Do NOT cd into it."; echo "STOP and report if blocked."
    echo "commit after each section"; echo "cargo check --no-default-features"
    echo "You may commit. Do NOT push."; } > "$f"
  echo "$f"
}
run() { bash "$DISPATCH" "$ISSUE" "$1" --dry-run 2>&1; }
expect() {  # $1 label, $2 output, $3 substring
  if grep -qF "$3" <<<"$2"; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: output did not contain %q\n' "$1" "$3"; FAILURES=$((FAILURES+1)); fi
}

WTP="$HOME/RustroverProjects/velostream-$ISSUE"
echo "end-to-end preflight (issue #$ISSUE)"
expect "wrong WORKTREE refuses" \
  "$(run "$(brief "WORKTREE: /tmp/completely-wrong" "BRANCH: fix/$ISSUE-auto")")" \
  "brief WORKTREE does not match"
expect "wrong BRANCH refuses" \
  "$(run "$(brief "WORKTREE: $WTP" "BRANCH: fix/$ISSUE-WRONG")")" \
  "brief BRANCH does not match"
expect "both correct passes" \
  "$(run "$(brief "WORKTREE: $WTP" "BRANCH: fix/$ISSUE-auto")")" \
  "brief BRANCH/WORKTREE match"
expect "declared-but-empty WORKTREE refuses" \
  "$(run "$(brief "## Worktree" "## Branch")")" \
  "NOT READY"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all end-to-end preflight checks passed"

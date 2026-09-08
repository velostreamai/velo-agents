#!/bin/bash
# `velo-spec-review --check` — every verdict path, with a stub codex.
#
# The point of stubbing: the real reviewer is PAID, so a plumbing bug must never
# be discovered by spending a round on it. That is not hypothetical — the first
# cut stored the verdict as the whole matched string ("VERDICT: CLEAN") and
# compared it against the token ("CLEAN"), so the clean streak never incremented
# and EVERY clean round reported NOT CLEAN. A live round would have burned money
# to reveal a sed bug.
#
# Fail-closed is the theme: no verdict line, a timeout, or an unrecognised
# verdict all exit 2 rather than passing. A review that produced nothing is not
# a review that found nothing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

SPEC_ROOT="$HOME/RustroverProjects/velostream/.agents/tasks"
ISSUE=""
for f in "$SPEC_ROOT"/*.json; do
  [[ -f "$f" ]] || continue
  n=$(basename "$f" .json)
  [[ "$n" =~ ^[0-9]+$ ]] && { ISSUE="$n"; break; }
done
if [[ -z "$ISSUE" ]]; then
  echo "  SKIP  no task spec under $SPEC_ROOT to exercise --check against"
  exit 0
fi
SPEC="$SPEC_ROOT/$ISSUE.json"

export VELO_STATE="$TMPD/state"
export VELO_SPEC_TIMEOUT=15
mkdir -p "$TMPD/stub"
export PATH="$TMPD/stub:$PATH"

emit() {   # write a stub codex whose stdout is exactly $1 plus a newline
  # `printf %s\n "$1"` unquoted collapses to the format %sn — no newline and a
  # stray 'n' glued to the verdict. That made the FINDINGS capture "2n", which
  # crashed the ledger append and lost the round without a word.
  { echo '#!/bin/bash'; echo 'cat >/dev/null'; echo "cat <<'STUBEOF'"; echo "$1"; echo 'STUBEOF'; } \
    > "$TMPD/stub/codex"
  chmod +x "$TMPD/stub/codex"
}
run() { "$BIN/velo-spec-review" "$ISSUE" --check >"$TMPD/out.txt" 2>&1; echo $?; }
check() {  # label, got, want
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: got $2, want $3"; FAILURES=$((FAILURES+1)); fi
}

echo "spec review loop (stubbed reviewer)"

emit 'VERDICT: FINDINGS 2'
check "findings -> exit 1" "$(run)" 1

emit 'VERDICT: CLEAN'
check "first clean round is not enough -> exit 1" "$(run)" 1
grep -q '1 of 2' "$TMPD/out.txt" \
  && echo "  PASS  says how many consecutive rounds are still needed" \
  || { echo "  FAIL  did not report the streak"; FAILURES=$((FAILURES+1)); }

emit 'VERDICT: CLEAN'
check "second clean round on the same spec -> exit 0" "$(run)" 0

# An edit to the spec must reset the streak: the artefact under review changed,
# so two clean rounds against the OLD content prove nothing about the new one.
cp "$SPEC" "$TMPD/spec.bak"
python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p)); d['_probe']='x'; json.dump(d,open(p,'w'),indent=2)" "$SPEC"
emit 'VERDICT: CLEAN'
GOT=$(run)
cp "$TMPD/spec.bak" "$SPEC"
check "editing the spec resets the clean streak" "$GOT" 1

emit 'I had a look and it seems fine'
check "no VERDICT line -> fail closed, exit 2" "$(run)" 2

{ echo '#!/bin/bash'; echo 'cat >/dev/null; sleep 60'; } > "$TMPD/stub/codex"
chmod +x "$TMPD/stub/codex"
"$BIN/velo-spec-review" "$ISSUE" --check >"$TMPD/out.txt" 2>&1
check "timeout -> exit 2" "$?" 2

# The ledger is the audit trail: without it "was this spec ever reviewed?" is
# unanswerable, which is the gap that let a dead index ship (#2056).
ROUNDS="$VELO_STATE/spec/$ISSUE/rounds.jsonl"
N=$(wc -l < "$ROUNDS" 2>/dev/null | tr -d ' ')
check "every round is recorded in the ledger" "$N" 6

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all spec-review checks passed"

#!/usr/bin/env bash
# velo-merge must validate EVERY gate against head, not just the newest (#2078).
#
# The check ended `| last | .s`, so only the most recent gate comment was ever
# compared to HEAD:
#
#     gate: check-code  @ H1        posted
#     (commits pushed, head becomes H2)
#     gate: code-review @ H2        posted     -> merge allowed
#
# and the PR merged carrying a check-code result for a commit that no longer
# existed — the exact failure `gate: <name> @ <sha>` was introduced to prevent.
#
# velo-merge had NO test coverage at all, which is how a one-word jq filter held
# the whole merge gate. These drive the real script with a stubbed `gh`, so the
# logic under test is the shipped logic, not a copy of it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$HERE/../bin/velo-merge"
MERGE_DIR="$HERE/../bin"
RC=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

HEADSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLDSHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

check() {  # label, haystack, needle
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-170)"; RC=1; fi
}
check_not() {
  if [[ "$2" != *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: did NOT want '$3': $(tr '\n' ' ' <<<"$2" | cut -c1-170)"; RC=1; fi
}

# `gh` stub: COMMENTS holds the gate comment bodies, one per line.
#
# It APPLIES the --jq filter rather than returning raw JSON, so the real jq
# expression in velo-merge is under test too — that expression is half the fix.
make_gh() {
  cat > "$TMPD/bin/gh" <<'EOF'
#!/usr/bin/env bash
JQF=""; WANT=0
for A in "$@"; do
  [[ $WANT -eq 1 ]] && { JQF="$A"; WANT=0; continue; }
  [[ "$A" == "--jq" ]] && WANT=1
done
if [[ -n "$JQF" ]]; then
  python3 -c '
import json, os, sys
bodies = [b for b in os.environ.get("COMMENTS", "").split("\n") if b]
print(json.dumps({"comments": [{"body": b.replace("<NONE>", "").replace("<NL>", "\n"), "authorAssociation": ("NONE" if b.startswith("<NONE>") else "OWNER")} for b in bodies]}))' | jq -r "$JQF"
  exit 0
fi
echo ""; exit 0
EOF
  chmod +x "$TMPD/bin/gh"
}
make_gh

# Extract the gate-validation block and drive it directly. The block reads $HEAD,
# $SHORT, $PR, $REPO, $FORCE and calls die/ok — exercising it in isolation keeps
# the test on the logic #2078 is about, rather than on velo-merge's many other
# preconditions (labels, CI, review state) which have their own failure modes.
python3 - "$MERGE" "$TMPD/block.sh" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index("  # The stale-gate check")
end = src.index('ran against current head')
# "\n  fi\n" — the OUTER fi at two-space indent. Searching for "  fi\n" alone
# matches inside the four-space "    fi", truncating the block mid-if and
# producing a syntax error that then looks like a passing check_not.
end = src.index("\n  fi\n", end) + len("\n  fi\n")
block = src[start:end]
pathlib.Path(sys.argv[2]).write_text(
    '#!/usr/bin/env bash\n'
    'die() { echo "DIE: $*"; exit 1; }\n'
    'ok()  { echo "OK: $*"; }\n'
    'PR=1; REPO=x/y; FORCE=${FORCE:-0}\n'
    'HEAD="$HEADSHA"; SHORT="${HEADSHA:0:7}"\n'
    'WAIVER_EXPR=$(cat -- "$WAIVER_JQ_PATH")\n'
    + block)
print("  extracted the real gate block from velo-merge")
PYEOF

run() {  # COMMENTS via env
  COMMENTS="$1" FORCE="${2:-0}" HEADSHA="$HEADSHA" WAIVER_JQ_PATH="$MERGE_DIR/velo-waiver.jq" \
    PATH="$TMPD/bin:$PATH" bash "$TMPD/block.sh" 2>&1
}

echo
echo "the bug: an older gate must not be masked by a newer one"
OUT=$(run "gate: check-code @ $OLDSHA
gate: code-review @ $HEADSHA")
check     "stale check-code is caught even though code-review is fresh" "$OUT" "STALE GATE"
check     "the stale gate is named"                                     "$OUT" "check-code ran at $OLDSHA"
check_not "does not report success"                                     "$OUT" "OK:"

echo
echo "the cases that must still pass"
OUT=$(run "gate: check-code @ $HEADSHA
gate: code-review @ $HEADSHA")
check     "all gates fresh passes"        "$OUT" "OK: all 2 gate(s) ran against current head"
check_not "no false stale"                "$OUT" "STALE"

OUT=$(run "gate: check-code @ ${HEADSHA:0:7}")
check "an abbreviated sha matches head"   "$OUT" "OK: all 1 gate(s)"

echo
echo "a re-run gate must be able to clear the PR"
# Otherwise re-gating could never unblock a merge, and the fix would be worse
# than the bug it replaces.
OUT=$(run "gate: check-code @ $OLDSHA
gate: code-review @ $HEADSHA
gate: check-code @ $HEADSHA")
check     "freshest sha per gate name wins" "$OUT" "OK: all 2 gate(s)"
check_not "stale predecessor does not block" "$OUT" "STALE"

echo
echo "ordering and absence"
OUT=$(run "gate: code-review @ $HEADSHA
gate: check-code @ $OLDSHA")
check "stale LAST comment is caught too" "$OUT" "STALE GATE"

OUT=$(run "")
check "no gate comment blocks"            "$OUT" "no 'gate: <name> @ <sha>' comment"

OUT=$(run "some unrelated review chatter")
check "non-gate comments do not count"    "$OUT" "no 'gate: <name> @ <sha>' comment"

echo
echo "--force still overrides, and says so"
OUT=$(run "gate: check-code @ $OLDSHA" 1)
check_not "force does not die" "$OUT" "DIE:"

echo
echo "a planned leg must be recorded or WAIVED by a named approver, at head"
python3 - "$MERGE" "$TMPD/block.sh" "$TMPD/recorded.sh" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
first = pathlib.Path(sys.argv[2]).read_text()        # the single read + stale-gate check, as extracted above
start = src.index("  if [[ $GATE_PASSED -eq 1 ]]; then\n    RECORDED=")
end = src.index("\n  fi\nfi\n", start) + len("\n  fi\n")
pathlib.Path(sys.argv[3]).write_text(
    first.replace('die() {', 'warn() { echo "WARN: $*"; }\ndie() {', 1)
    + 'GATE_PASSED=1; NEEDED="$NEEDED_IN"\n' + src[start:end])
PYEOF
run_rec() {  # <recorded gates "name sha" lines> <NEEDED names> <extra COMMENTS: waivers etc.>
  # The recorded gates are given as `gate:` comments, so the real single read produces GATES and WAIVED_RAW.
  local c="" l
  while read -r n sh; do [[ -n "$n" ]] && c="$c
gate: $n @ $sh"; done <<<"$1"
  COMMENTS="${c#
}
$3" NEEDED_IN="$2" HEADSHA="$HEADSHA" WAIVER_JQ_PATH="$MERGE_DIR/velo-waiver.jq" PATH="$TMPD/bin:$PATH" bash "$TMPD/recorded.sh" 2>&1
}
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "")
check     "a planned leg with no report and no waiver blocks the merge"  "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate-waived: check-code @ $HEADSHA<NL>Approved by: neil<NL>Reason: docs-only")
check_not "a waiver by a named approver, at head, covers the leg"        "$OUT" "DIE:"
check     "and the merge says the leg was waived"                         "$OUT" "check-code was WAIVED"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate: code-review @ $HEADSHA<NL>quoting an old thread:<NL>gate-waived: check-code @ $HEADSHA<NL>Approved by: Alice")
check     "a gate report that merely quotes waiver text is not a waiver"  "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "I did not run check-code.<NL><NL>gate: check-code @ $HEADSHA")
check     "a comment that merely quotes a gate header is not a report"   "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA
check-code $OLDSHA" "code-review check-code" "gate-waived: check-code @ $HEADSHA<NL>Approved by: neil<NL>Reason: later")
check_not "a current waiver covers a leg reported only at an older head" "$OUT" "STALE"
check_not "and the merge does not die on it"                              "$OUT" "DIE:"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate-waived: check-code @ $OLDSHA<NL>Approved by: neil")
check     "a waiver for an older head does not cover the current head"   "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "<NONE>gate-waived: check-code @ $HEADSHA<NL>Approved by: Alice<NL>Reason: cheap")
check     "a waiver by a non-collaborator does not count"                "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate-waived: check-code @ $HEADSHA<NL>Approved by: $(printf '\xe2\x80\x83')<NL>Reason: cheap")
check     "a Unicode-whitespace approver does not count"                 "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate-waived: check-code @ $HEADSHA<NL>Approved by: 	 <NL>Reason: cheap")
check     "a whitespace-only approver does not count"                    "$OUT" "NO recorded report for: check-code"
OUT=$(run_rec "code-review $HEADSHA" "code-review check-code" "gate-waived: check-code @ $HEADSHA<NL>Reason: cheap")
check     "a waiver with no named approver does not count"               "$OUT" "NO recorded report for: check-code"

echo
[[ $RC -eq 0 ]] && echo "all merge-gate checks passed" || echo "FAILED"
exit $RC

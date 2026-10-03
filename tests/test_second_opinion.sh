#!/bin/bash
# velo-pr-gate's second-opinion leg must never be mistaken for a completed review.
#
# The review diff range is computed from the last `gate: *review @ <sha>` stamp on
# the PR. A non-blocking local second opinion stamped under a name that matches
# that pattern would silently move Codex's next range past code Codex never saw.
# Both halves are extracted from the script itself, so renaming the leg or
# widening the regex is caught here rather than on a PR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../bin/velo-pr-gate"
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }

RE=$(grep -oE 'capture\("gate:[^"]+"\)' "$GATE" | head -1 | sed -E 's/^capture\("//; s/"\)$//')
[[ -n "$RE" ]] || { echo "  FAIL could not extract the review-range regex from velo-pr-gate"; exit 1; }

matches() { jq -rn --arg b "$1" --arg re "$RE" '[$b | capture($re)] | length'; }

check "a code-review stamp moves the range"          "$(matches 'gate: code-review @ abc1234')"    "1"
check "the second-opinion stamp does NOT"            "$(matches 'gate: second-opinion @ abc1234')" "0"

# The name the script tells operators to post under is the name tested above.
POSTED=$(grep -oE 'velo-gate-post \$PR [a-z0-9-]+ <report>\$GPS   \(optional' "$GATE" | awk '{print $3}')
check "operators are told to post it as second-opinion" "$POSTED" "second-opinion"
check "the posted name does not match the range regex"  "$(matches "gate: ${POSTED:-x} @ abc1234")" "0"

# Read-only by construction: the dispatch must carry the runner's marker line.
# (check-code's OpenRouter route carries it too, over its own brief.)
check "the dispatch carries the read-only marker" \
  "$(grep -c "=== THIS IS A READ-ONLY REVIEW TASK ===.*cat \"\$OUT\"" "$GATE")" "1"

exit $FAIL

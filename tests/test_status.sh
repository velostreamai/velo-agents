#!/bin/bash
# velo-status — the operator's primary view, and until now untested.
#
# It had no coverage at all, which is how a rename shipped straight through it:
# the state migration moved worker logs from /tmp/<worker>-<issue>.log to
# $VELO_STATE/dispatch/<issue>/<worker>-<UTC>.log, and the worker-name rule
# still stripped from "-<issue>" onward. Nothing matched, so the WHOLE filename
# became the worker name and the table showed `codex-20260` for a codex run.
#
# The failure was cosmetic-looking and load-bearing: velo-status is how you tell
# which model ran, and a garbled name is indistinguishable from a worker you do
# not recognise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# Exercise the derivation the way the script does, against the REAL filename
# shapes it now sees. Kept in lockstep with velo-status by the wiring assertion
# at the end — a copy that drifts is worse than no test.
derive() {  # $1 = log basename
  local BN; BN=$(basename "$1" .log); echo "${BN%-*}"
}

check() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: got '$2', want '$3'"; FAILURES=$((FAILURES+1)); fi
}

echo "velo-status worker naming"

check "codex run"           "$(derive codex-20260908T035158Z.log)"       "codex"
check "deepseek run"        "$(derive deepseek-20260908T035158Z.log)"    "deepseek"
check "glm run"             "$(derive glm-20260908T035158Z.log)"         "glm"
# The one a naive "cut at the first hyphen" gets wrong.
check "velo-local keeps its hyphen" "$(derive velo-local-20260908T035158Z.log)" "velo-local"

# Wiring: the rule under test must still be the rule in the script. Without this
# the helper above can stay correct while velo-status drifts back.
if grep -q 'BN=$(basename "$LOG" .log); WORKER="${BN%-\*}"' "$BIN/velo-status" \
   || grep -qF 'BN=$(basename "$LOG" .log); WORKER="${BN%-*}"' "$BIN/velo-status"; then
  echo "  PASS  velo-status still uses this derivation"
else
  echo "  FAIL  velo-status's derivation changed — this test is now testing a copy"
  FAILURES=$((FAILURES+1))
fi

# And the whole command must still run. It reads real worktrees, so assert only
# that it succeeds and prints its header — not on the rows, which vary.
OUT=$("$BIN/velo-status" 2>&1)
if grep -q 'ISSUE.*WORKER.*STATE' <<<"$OUT"; then
  echo "  PASS  velo-status runs and prints its table"
else
  echo "  FAIL  velo-status did not produce a table"; FAILURES=$((FAILURES+1))
fi
# The column is TRUNCATED for display, so the full timestamp is not visible —
# 'codex-20260908T035158Z' renders as 'codex-20260'. Matching on the 'T' found
# nothing and the assertion was decorative. Match the year prefix instead, which
# survives truncation.
if grep -qE '^[0-9]+ +[a-z-]+-20[0-9][0-9]' <<<"$OUT"; then
  echo "  FAIL  a worker column still shows a raw timestamped filename"
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  no worker column shows a raw log filename"
fi

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all velo-status checks passed"

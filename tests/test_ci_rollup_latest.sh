#!/bin/bash
# velo-ci-rollup.jq — the LATEST run of each check, not every run on the sha (#2677).
#
# A head sha can carry several rows for the SAME check: a re-run leaves the superseded row
# behind, and a close/reopen republishes every check on the PR. ci_rollup reduced the WORST
# state over ALL of them, so an older FAILURE beside a newer SUCCESS of the same job said
# "FAILING" forever — velo-merge refused a green PR, and --wait polled a definitive failure
# it could never clear. The rows must be narrowed to one per check before the reduce.
#
# Executed against the real definition, the same way velo-merge and velo-status run it (the
# file is prepended to `.statusCheckRollup | ci_rollup`), so a change to either caller's
# program or to the definition shows up here rather than in CI.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
JQ="$BIN/velo-ci-rollup.jq"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
[[ -r "$JQ" ]] || { echo "FAIL  no rollup definition at $JQ"; exit 1; }

# The callers' program, verbatim shape: definitions prepended, then `.statusCheckRollup | ci_rollup`.
rollup() {   # <file holding the definition> <rows, a JSON array> -> the ci_rollup object (jq errors pass through)
  jq -c "$(cat -- "$1")"' .statusCheckRollup | ci_rollup' <<<"$2" 2>&1
}

LAST=""
check() {   # <label> <rows json> <state> [<field> <want>]... — the state, and any listed field of the result
  local label="$1" rows="$2" want="$3"; shift 3
  local out got
  out=$(rollup "$JQ" "$rows"); LAST="$out"
  if [[ "$out" != "{"* ]]; then
    echo "  FAIL  $label: jq said: $(head -n 1 <<<"$out" | cut -c1-200)"; FAILURES=$((FAILURES+1)); return
  fi
  got=$(jq -r .state <<<"$out")
  if [[ "$got" != "$want" ]]; then
    echo "  FAIL  $label: state '$got', want '$want' — $out"; FAILURES=$((FAILURES+1)); return
  fi
  local f w
  while [[ $# -gt 0 ]]; do
    f="$1"; w="$2"; shift 2
    got=$(jq -r --arg f "$f" '.[$f]' <<<"$out")
    if [[ "$got" != "$w" ]]; then
      echo "  FAIL  $label: .$f '$got', want '$w'"; FAILURES=$((FAILURES+1)); return
    fi
  done
  echo "  PASS  $label"
}

# ── the rows, as gh exports them ──────────────────────────────────────────────
# Same job, same workflow, two runs: the old one failed, the re-run passed.
CR_FAIL_OLD='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-08T03:00:00Z","completedAt":"2026-09-08T03:30:00Z"}'
CR_PASS_NEW='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-08T04:00:00Z","completedAt":"2026-09-08T04:30:00Z"}'
CR_PASS_OLD='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-08T03:00:00Z","completedAt":"2026-09-08T03:30:00Z"}'
CR_FAIL_NEW='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-08T04:00:00Z","completedAt":"2026-09-08T04:30:00Z"}'
# The same job, re-run and still going: no completedAt, a LATER startedAt than the failure it replaced.
CR_RUN_NEW='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-09-08T05:00:00Z","completedAt":null}'
# A queued re-run that has published no time at all.
CR_QUEUED='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"QUEUED"}'
# A second, DIFFERENT check on the same PR.
CR_OTHER_PASS='{"__typename":"CheckRun","workflowName":"Build & Test","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-08T03:00:00Z","completedAt":"2026-09-08T03:05:00Z"}'
CR_OTHER_FAIL='{"__typename":"CheckRun","workflowName":"Build & Test","name":"lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-08T03:00:00Z","completedAt":"2026-09-08T03:05:00Z"}'
# The same job name under two DIFFERENT workflows.
CR_WF2_PASS='{"__typename":"CheckRun","workflowName":"Release","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-08T04:00:00Z","completedAt":"2026-09-08T04:30:00Z"}'
# A commit status (the legacy API): no conclusion, no status, no timestamps.
CTX_ERROR_OLD='{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR","targetUrl":"https://example/1"}'
CTX_SUCCESS_NEW='{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":"https://example/2"}'
# Rows that are not a check this file knows.
MYSTERY='{"__typename":"Mystery","name":"build","workflowName":"Build & Test"}'
STALE_CONCLUSION='{"__typename":"CheckRun","workflowName":"Build & Test","name":"build","status":"COMPLETED","conclusion":"MYSTERY"}'
NOT_OBJECT='"oops"'
SKIPPED='{"__typename":"CheckRun","workflowName":"Build & Test","name":"optional lane","status":"COMPLETED","conclusion":"SKIPPED"}'

echo "velo-ci-rollup.jq: one row per check, the latest run on the sha"

# ── a superseded run must not decide the state ────────────────────────────────
check "older FAILURE + newer SUCCESS of the same check is SUCCESS" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_PASS_NEW]}" SUCCESS \
  fail "" pass "build" pending "" unknown ""
check "older SUCCESS + newer FAILURE of the same check is FAILING" \
  "{\"statusCheckRollup\":[$CR_PASS_OLD,$CR_FAIL_NEW]}" FAILING \
  fail "build" pass ""
# The kept row is chosen by the run's timestamp, not by where the rows happened to arrive, so
# the same pair read in the opposite order gives the same answer.
check "the newer run wins whichever order the rows arrive in" \
  "{\"statusCheckRollup\":[$CR_PASS_NEW,$CR_FAIL_OLD]}" SUCCESS \
  fail "" pass "build"
# A pending re-run replaces an older failure: the state is pending (--wait retries it), not the
# stale FAILING that --wait can never clear.
check "older FAILURE + a newer run still going is pending, not FAILING" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_RUN_NEW]}" pending \
  fail "" pending "build"
# A re-run that has published NO time of its own is not evidence that the failure is superseded:
# the older conclusion stays, which is the worst-state reading the design asks for.
check "a queued re-run with no timestamp does not clear the older FAILURE" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_QUEUED]}" FAILING \
  fail "build" pending ""
# An unrecognised CONCLUSION belongs to a check the file can key, so the newer run supersedes it
# too — but only after being read as a row: see the unrecognised-ROW cases below.
check "older unrecognised conclusion + newer SUCCESS is SUCCESS" \
  "{\"statusCheckRollup\":[$STALE_CONCLUSION,$CR_PASS_NEW]}" SUCCESS \
  fail "" unknown "" pass "build"

# ── the key is the CHECK, not the job name alone ──────────────────────────────
check "two DIFFERENT checks, one failed one passed, is still FAILING" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_OTHER_PASS]}" FAILING \
  fail "build" pass "lint"
check "the same job name in two WORKFLOWS is not one check" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_WF2_PASS]}" FAILING \
  fail "build" pass "build"
check "a job with no workflowName is not merged with one that has it" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,{\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"startedAt\":\"2026-09-08T04:00:00Z\",\"completedAt\":\"2026-09-08T04:30:00Z\"}]}" FAILING \
  fail "build" pass "build"

# ── ties, and rows the file cannot key ───────────────────────────────────────
check "tie on completedAt: the LATER array position wins (a failure)" \
  "{\"statusCheckRollup\":[$CR_PASS_OLD,{\"__typename\":\"CheckRun\",\"workflowName\":\"Build & Test\",\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\",\"startedAt\":\"2026-09-08T03:00:00Z\",\"completedAt\":\"2026-09-08T03:30:00Z\"}]}" FAILING \
  fail "build" pass ""
check "tie on completedAt: the LATER array position wins (a pass)" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,{\"__typename\":\"CheckRun\",\"workflowName\":\"Build & Test\",\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"startedAt\":\"2026-09-08T03:00:00Z\",\"completedAt\":\"2026-09-08T03:30:00Z\"}]}" SUCCESS \
  fail "" pass "build"
check "three runs of one check: the newest decides, the two older ones are gone" \
  "{\"statusCheckRollup\":[$CR_PASS_OLD,$CR_FAIL_NEW,$CR_PASS_NEW]}" SUCCESS \
  fail "" pass "build"

# A commit status carries no run time, so its check is decided by position: the later row is the
# freshest status GitHub reported for that context.
check "StatusContext: older ERROR + later SUCCESS of the same context is SUCCESS" \
  "{\"statusCheckRollup\":[$CTX_ERROR_OLD,$CTX_SUCCESS_NEW]}" SUCCESS \
  fail "" pass "ci/legacy"
check "StatusContext: older SUCCESS + later ERROR of the same context is FAILING" \
  "{\"statusCheckRollup\":[$CTX_SUCCESS_NEW,$CTX_ERROR_OLD]}" FAILING \
  fail "ci/legacy" pass ""
check "two DIFFERENT commit contexts are not one check" \
  "{\"statusCheckRollup\":[$CTX_ERROR_OLD,{\"__typename\":\"StatusContext\",\"context\":\"ci/other\",\"state\":\"SUCCESS\"}]}" FAILING \
  fail "ci/legacy" pass "ci/other"
# A CheckRun and a commit status that happen to share a name are different checks.
check "a commit status is never deduped with a check run of the same name" \
  "{\"statusCheckRollup\":[$CTX_ERROR_OLD,{\"__typename\":\"CheckRun\",\"workflowName\":\"\",\"name\":\"ci/legacy\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}" FAILING \
  fail "ci/legacy" pass "ci/legacy"

# ── a row this file does not recognise is KEPT, never dropped ─────────────────
check "an unrecognised row type is unknown" \
  "{\"statusCheckRollup\":[$MYSTERY]}" unknown \
  unknown "build (type \"Mystery\")"
# This is the shape the defect could have hidden: the row beside it shares its key, so a dedupe
# that dropped unkeyable rows would read the pair as one green check.
check "an unrecognised row is kept even beside a passing check run of the same name" \
  "{\"statusCheckRollup\":[$CR_PASS_NEW,$MYSTERY]}" unknown \
  fail "" pass "build" unknown "build (type \"Mystery\")"
check "a row that is not an object is kept, and is unknown" \
  "{\"statusCheckRollup\":[$CR_PASS_NEW,$NOT_OBJECT]}" unknown \
  fail "" pass "build" \
  unknown "(a check row that is not an object) (not an object)"
check "two unkeyable rows are both kept, neither deduped away" \
  "{\"statusCheckRollup\":[$NOT_OBJECT,$MYSTERY]}" unknown
# Unrecognised outranks pending, and a superseded failure no longer gets to outrank it.
check "an unrecognised row still outranks the pending run of a keyed check" \
  "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_RUN_NEW,$MYSTERY]}" unknown \
  fail ""

# ── nothing ran is still nothing ran ─────────────────────────────────────────
check "no rows is none"            '{"statusCheckRollup":[]}'    none
check "a null rollup is none"      '{"statusCheckRollup":null}'  none
check "a lane whose LATEST run is SKIPPED is none, not a pass" "{\"statusCheckRollup\":[$SKIPPED,$SKIPPED,$CR_OTHER_PASS,{\"__typename\":\"CheckRun\",\"workflowName\":\"Build & Test\",\"name\":\"lint\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\",\"startedAt\":\"2026-09-08T02:00:00Z\",\"completedAt\":\"2026-09-08T02:05:00Z\"}]}" SUCCESS \
  fail "" pending "" unknown "" pass "lint"
check "two SKIPPED runs of one lane collapse to one, and stay none" \
  "{\"statusCheckRollup\":[$SKIPPED,$SKIPPED]}" none

# ── MUTATION PROOF: the dedupe step is what these checks pin ─────────────────
# Revert ONLY the dedupe step — the reduce then reads every run on the sha again — and the
# older-FAILURE+newer-SUCCESS case above must go red on the state, for the reason the fix exists
# to remove. An anchor that no longer matches is reported as such rather than passing quietly.
MUT="$TMPD/velo-ci-rollup.jq"
if ! python3 - "$JQ" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1:]
old = "| only_latest_runs[] |"
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, "| .[] |", 1))
PY
then
  echo "  FAIL  MUTATION-PROOF the dedupe step: the anchor is gone — did ci_rollup change shape?"; FAILURES=$((FAILURES+1))
else
  MUT_OUT=$(rollup "$MUT" "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_PASS_NEW]}")
  REAL_OUT=$(rollup "$JQ"   "{\"statusCheckRollup\":[$CR_FAIL_OLD,$CR_PASS_NEW]}")
  if [[ "$MUT_OUT" != "{"* || "$(jq -r .state <<<"$MUT_OUT")" == "SUCCESS" ]]; then
    echo "  FAIL  MUTATION-PROOF the dedupe step: stayed GREEN with it removed — no check pins it (mutant said: $(head -n 1 <<<"$MUT_OUT" | cut -c1-160))"; FAILURES=$((FAILURES+1))
  elif [[ "$REAL_OUT" != "$MUT_OUT" ]] && [[ "$(jq -r .state <<<"$REAL_OUT")" == "SUCCESS" ]] && [[ "$(jq -r .state <<<"$MUT_OUT")" == "FAILING" ]]; then
    echo "  PASS  MUTATION-PROOF the dedupe step: red with it removed ($MUT_OUT), green restored ($REAL_OUT)"
  else
    echo "  FAIL  MUTATION-PROOF the dedupe step: unexpected states (real '$REAL_OUT' vs mutant '$MUT_OUT')"; FAILURES=$((FAILURES+1))
  fi
fi

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all ci-rollup latest-run checks passed"

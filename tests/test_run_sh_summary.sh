#!/bin/bash
# run.sh names every failing suite on its last line, and times every suite.
#
# The last line used to be a bare "❌ .agents tests FAILED". The failure itself
# was printed wherever that suite ran, so `run.sh | tail` showed passing suites
# and no name, and a worker re-ran the whole 8-minute suite to find it (#2354).
#
# Runs a copy of run.sh against stub suites: an empty file passes under both bash
# and python, and `exit 1` fails under both (python as a syntax error).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; RC=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp "$HERE/run.sh" "$T/run.sh"
P3=$(command -v python3)
cp "$HERE/test-timeouts.sh" "$T/"
grep -E '^suite ' "$HERE/run.sh" | grep -oE '"\$HERE/[^"]+"' | sed -E 's#"\$HERE/([^"]+)"#\1#' | sort -u |
  while read -r f; do : > "$T/$f"; done
n=$(ls "$T" | grep -vcE '^(run|test-timeouts)\.sh$')
[[ $n -ge 50 ]] && ok "stubbed $n suites" || bad "stubbed only $n suites"

echo 'sleep 2' > "$T/test_gate_run.sh"       # the one slow suite (bash only)
out=$(VELO_TEST_PYTHON="$P3" VELO_OAI_PY="$P3" bash "$T/run.sh" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "all suites passing exits 0" || bad "all passing exited $rc"
[[ $(tail -1 <<<"$out") == "✅ .agents tests passed" ]] && ok "passing summary line" \
  || bad "passing summary: $(tail -1 <<<"$out")"
W='[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
n_timed=$(grep -cE "^  \\[[0-9]+s $W-$W\\] test_" <<<"$out")
[[ $n_timed -eq $n ]] && ok "every suite prints its own wall time ($n_timed)" \
  || bad "$n_timed of $n suites printed a wall time"
grep -qE "^  \\[[2-9]s $W-$W\\] test_gate_run\\.sh\$" <<<"$out" && ok "the slow suite's own line shows >= 2s" \
  || bad "slow suite line: $(grep 'test_gate_run.sh' <<<"$out")"
grep -qE '^run\.sh started [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<<"$out" && ok "run start time printed" \
  || bad "no 'run.sh started <utc>' line"
slowest=$(grep -EA1 '^slowest suites \(total [0-9]+s, [0-9T:-]+Z to [0-9T:-]+Z\):$' <<<"$out" | tail -1)
[[ $slowest =~ ^\ \ [2-9]s\ \ test_gate_run\.sh$ ]] && ok "the slow suite heads the slowest list" \
  || bad "slowest list starts: '$slowest'"
: > "$T/test_gate_run.sh"

echo 'exit 1' > "$T/test_status.sh"          # bash suite
echo 'exit 1' > "$T/test_tool_contract.py"   # python suite, run via $PY
out=$(VELO_TEST_PYTHON="$P3" VELO_OAI_PY="$P3" bash "$T/run.sh" 2>&1); rc=$?
last=$(tail -1 <<<"$out")
[[ $rc -ne 0 ]] && ok "a failing suite exits non-zero" || bad "failing suite exited 0"
[[ $last == "❌ .agents tests FAILED (2): test_status.sh test_tool_contract.py" ]] \
  && ok "last line names both failing suites, in run order" || bad "last line: $last"

# A suite that exits but leaves a background process behind is a leak: named,
# killed, and failed, even though the suite itself exited 0.
: > "$T/test_status.sh"; : > "$T/test_tool_contract.py"
# The sleep's argument is unique to this run, so a concurrent run on the same
# host (other agents' worktrees) can never match or kill it.
LEAK_SECS="61.$$"
echo "sleep $LEAK_SECS >/dev/null 2>&1 & exit 0" > "$T/test_record.sh"   # off the pipe, so $(...) does not wait for it
out=$(VELO_TEST_PYTHON="$P3" VELO_OAI_PY="$P3" bash "$T/run.sh" 2>&1); rc=$?
grep -q '^  LEAK test_record.sh left 1 process(es) running:$' <<<"$out" && ok "a leaked process is reported against its suite" \
  || bad "no LEAK line for test_record.sh"
grep -qE "^ +[0-9]+ sleep $LEAK_SECS\$" <<<"$out" && ok "the leaked process is named" || bad "leaked process not listed"
[[ $(tail -1 <<<"$out") == "❌ .agents tests FAILED (1): test_record.sh" ]] && ok "a leaking suite fails the run" \
  || bad "leak summary: $(tail -1 <<<"$out")"
sleep 0.2
pgrep -f "^sleep $LEAK_SECS\$" >/dev/null && { bad "the leaked process was left running"; pkill -f "^sleep $LEAK_SECS\$"; } \
  || ok "the leaked process was killed"

echo
[[ $RC -eq 0 ]] && echo "all run.sh summary checks passed" || echo "run.sh summary checks FAILED"
exit $RC

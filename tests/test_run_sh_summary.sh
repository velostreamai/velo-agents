#!/bin/bash
# run.sh names every failing suite on its last line.
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
grep -oE '"\$HERE/[^"]+"' "$HERE/run.sh" | sed -E 's#"\$HERE/([^"]+)"#\1#' | sort -u |
  while read -r f; do : > "$T/$f"; done
n=$(ls "$T" | grep -vc '^run.sh$')
[[ $n -ge 50 ]] && ok "stubbed $n suites" || bad "stubbed only $n suites"

out=$(VELO_TEST_PYTHON="$P3" VELO_OAI_PY="$P3" bash "$T/run.sh" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "all suites passing exits 0" || bad "all passing exited $rc"
[[ $(tail -1 <<<"$out") == "✅ .agents tests passed" ]] && ok "passing summary line" \
  || bad "passing summary: $(tail -1 <<<"$out")"

echo 'exit 1' > "$T/test_status.sh"          # bash suite
echo 'exit 1' > "$T/test_tool_contract.py"   # python suite, run via $PY
out=$(VELO_TEST_PYTHON="$P3" VELO_OAI_PY="$P3" bash "$T/run.sh" 2>&1); rc=$?
last=$(tail -1 <<<"$out")
[[ $rc -ne 0 ]] && ok "a failing suite exits non-zero" || bad "failing suite exited 0"
[[ $last == "❌ .agents tests FAILED (2): test_status.sh test_tool_contract.py" ]] \
  && ok "last line names both failing suites, in run order" || bad "last line: $last"

echo
[[ $RC -eq 0 ]] && echo "all run.sh summary checks passed" || echo "run.sh summary checks FAILED"
exit $RC

#!/bin/bash
# velo-dispatch --wait's poll loop, extracted verbatim (like
# test_fail_to_pass.sh does for velo-dispatch's other marked block) and
# exercised in isolation. Driving the REAL end-to-end dispatch would need a
# live GH issue, a real worktree cut from origin/master, and a real model
# call — this proves the thing the brief actually asks for: the loop
# returns once a NEW line lands in the records file, using a fake records
# path (VELO_STATE-shaped, but pointed at a scratch dir rather than
# ~/.agents/state), reports the outcome from that line, and does NOT return
# before the line exists.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
FAILED=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

BLOCK=$(sed -n '/^# >>> velo-dispatch-wait/,/^# <<< velo-dispatch-wait/p' "$DISPATCH")
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL could not extract the --wait block from velo-dispatch — deleted or renamed."
  echo "        --wait would silently stop blocking, and a caller relying on it would"
  echo "        get control back immediately with no signal anything is wrong."
  exit 1
fi
echo "  ok   --wait block still present in velo-dispatch ($(wc -l <<<"$BLOCK" | tr -d ' ') lines)"

# A real (tiny) worktree, so the block's `git -C $WT log` and agent.log tail
# lines have something real to read rather than failing silently on a
# directory that was never a git repo.
WT="$TMPD/fake-worktree"; mkdir -p "$WT"
git -C "$WT" init -q .
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '2026-01-01T00:00:00Z STOP triggered: fake reason\n2026-01-01T00:00:01Z MUTATION-PROOF | test=fake | red=x | green=1/1\n' > "$WT/agent.log"

RECORD_FILE="$TMPD/records.jsonl"
# ok/warn stand in for velo-dispatch's real helpers (print-and-return, not
# exit) so the block's OWN exit 0 / exit 1 is what the caller observes below,
# exactly like test_fail_to_pass.sh's run_case() stubs die/ok/warn.
ok()   { echo "OK: $1"; }
warn() { echo "WARN: $1"; }

# Runs the extracted block in a background subshell so its own `while :; do
# ... sleep; done` cannot hang this test script. `echo $!` is captured via
# $(...), which means the pid is NOT a job-table child of THIS shell (the
# command substitution's own transient subshell was) — so its exit status is
# written to a sidecar file instead of read back with bash's `wait` builtin,
# which would otherwise fail with "pid N is not a child of this shell".
# `kill -0` has no such restriction: it is a plain existence check via the
# kill(2) syscall, so polling for exit with it is safe regardless.
run_wait_block_bg() {  # $1 = baseline line count, $2 = output file
  local baseline="$1" outfile="$2"
  (
    bash -c "
      set -uo pipefail
      ok()   { echo \"OK: \$1\"; }
      warn() { echo \"WARN: \$1\"; }
      ISSUE=9999 WT='$WT' WAIT=1 WAIT_RECORD_FILE='$RECORD_FILE' WAIT_BASELINE_LINES='$baseline' VELO_WAIT_INTERVAL=0
      $BLOCK
    "
    echo $? > "$outfile.rc"
  ) > "$outfile" 2>&1 &
  echo $!
}

# ---- it does NOT return before a new line exists ---------------------------
: > "$RECORD_FILE"   # baseline: file exists, 0 lines
OUT1="$TMPD/out1.txt"
PID=$(run_wait_block_bg 0 "$OUT1")
sleep 0.3
if kill -0 "$PID" 2>/dev/null; then
  echo "  ok   still blocked with no new record line after 0.3s"
else
  echo "  FAIL returned before any record line was appended — not blocking at all"
  FAILED=1
fi

# ---- it returns once a line is appended, and reports outcome=landed -------
printf '{"issue":9999,"outcome":"landed","branch":"fix/9999-auto"}\n' >> "$RECORD_FILE"
WAITED=0
while kill -0 "$PID" 2>/dev/null && [[ $WAITED -lt 50 ]]; do sleep 0.1; WAITED=$((WAITED+1)); done
if kill -0 "$PID" 2>/dev/null; then
  echo "  FAIL did not return within 5s of a new record line landing"
  kill "$PID" 2>/dev/null
  FAILED=1
else
  RC=$(cat "$OUT1.rc" 2>/dev/null || echo "?")
  OUT=$(cat "$OUT1")
  if [[ $RC -eq 0 ]]; then echo "  ok   returned exit 0 for outcome=landed"
  else echo "  FAIL exit $RC for outcome=landed, want 0"; FAILED=1; fi
  if grep -q 'outcome: landed' <<<"$OUT"; then echo "  ok   printed the outcome"
  else echo "  FAIL did not print the outcome:"; sed 's/^/        /' <<<"$OUT"; FAILED=1; fi
  if grep -q 'STOP triggered: fake reason' <<<"$OUT"; then echo "  ok   printed the agent.log STOP line"
  else echo "  FAIL did not surface the agent.log STOP/MUTATION-PROOF tail:"; sed 's/^/        /' <<<"$OUT"; FAILED=1; fi
  if grep -q 'MUTATION-PROOF' <<<"$OUT"; then echo "  ok   printed the agent.log MUTATION-PROOF line"
  else echo "  FAIL did not surface the MUTATION-PROOF line"; FAILED=1; fi
fi

# ---- a non-landed outcome exits non-zero -----------------------------------
: > "$RECORD_FILE"
OUT2="$TMPD/out2.txt"
PID2=$(run_wait_block_bg 0 "$OUT2")
printf '{"issue":9999,"outcome":"stopped","branch":"fix/9999-auto"}\n' >> "$RECORD_FILE"
WAITED=0
while kill -0 "$PID2" 2>/dev/null && [[ $WAITED -lt 50 ]]; do sleep 0.1; WAITED=$((WAITED+1)); done
if kill -0 "$PID2" 2>/dev/null; then
  echo "  FAIL did not return within 5s for outcome=stopped"; kill "$PID2" 2>/dev/null; FAILED=1
else
  RC2=$(cat "$OUT2.rc" 2>/dev/null || echo "?")
  if [[ "$RC2" != "0" ]]; then echo "  ok   returned non-zero exit ($RC2) for outcome=stopped"
  else echo "  FAIL exit 0 for outcome=stopped — a stopped worker must not read as success"; FAILED=1; fi
fi

# ---- the baseline is respected: pre-existing lines don't count as "new" ----
printf '{"issue":9999,"outcome":"landed"}\n{"issue":9999,"outcome":"landed"}\n' > "$RECORD_FILE"
OUT3="$TMPD/out3.txt"
PID3=$(run_wait_block_bg 2 "$OUT3")   # baseline=2: both existing lines are "old"
sleep 0.3
if kill -0 "$PID3" 2>/dev/null; then
  echo "  ok   2 pre-existing lines with baseline=2 do not satisfy the wait"
  kill "$PID3" 2>/dev/null
else
  echo "  FAIL returned immediately on PRE-EXISTING lines — baseline is not being respected,"
  echo "        which means a worker that already finished before --wait started would be"
  echo "        misread as the CURRENT dispatch's result"
  FAILED=1
fi

echo
[[ $FAILED -eq 0 ]] && echo "all velo-dispatch --wait checks passed" || echo "FAILURES"
exit $FAILED

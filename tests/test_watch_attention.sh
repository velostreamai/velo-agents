#!/bin/bash
# velo-watch --attention (#2285 Round 2): block until attention.jsonl has an
# event nobody has acked, then exit 0 and print it. Closes the gap the
# default mode does not cover — velo-orchestrd can detect and escalate a fact
# on its own schedule with nobody watching, and something still has to wake
# a human/session up when it does.
#
# Drives the REAL script against a sandboxed VELO_STATE, sourcing the same
# velo-orch-lib.sh the daemon and velo-attention use — "unhandled" must mean
# the same thing in all three places.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
WATCH="$BIN/velo-watch"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$WATCH" ]] || { fail "velo-watch not found at $WATCH"; exit 1; }

TMPD=$(mktemp -d)
LIVE_PID=""
kill_live() { [[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null; }
trap 'kill_live; rm -rf "$TMPD"' EXIT

VELO_STATE="$TMPD/state"
export VELO_STATE
ORCH_DIR="$VELO_STATE/orch"
mkdir -p "$ORCH_DIR"

now_s() { python3 -c 'import time; print(time.time())'; }

# ---- 1: an event already waiting -> exits 0 immediately, prints it -------
jq -cn '{id:"wedge:9001:1", kind:"wedge", pr:null, issue:9001, sha:"1", evidence:"agent.log stalled 40m"}' \
  > "$ORCH_DIR/attention.jsonl"
T0=$(now_s)
OUT1=$("$WATCH" --attention --interval 1 --max 20 2>&1); RC1=$?
T1=$(now_s)
if [[ $RC1 -eq 0 ]]; then ok "exits 0 when an unacked event already exists"
else fail "exited $RC1: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-200)"; fi
if grep -qF 'wedge' <<<"$OUT1" && grep -qF '9001' <<<"$OUT1"; then
  ok "prints the unacked event's kind and issue"
else
  fail "did not print the event: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-200)"
fi
ELAPSED1=$(python3 -c "print(f'{$T1 - $T0:.2f}')")
if python3 -c "exit(0 if ($T1 - $T0) < 1.0 else 1)"; then
  ok "returned immediately (${ELAPSED1}s) rather than waiting a full poll interval"
else
  fail "took ${ELAPSED1}s to report an event that was already there"
fi

# ---- 2: only an ACKED event exists -> times out, does not false-wake ------
: > "$ORCH_DIR/attention.jsonl"
jq -cn '{id:"wedge:9002:1", kind:"wedge", pr:null, issue:9002, sha:"1", evidence:"handled already"}' \
  > "$ORCH_DIR/attention.jsonl"
printf 'wedge:9002:1\n' > "$ORCH_DIR/acked-ids"
OUT2=$("$WATCH" --attention --interval 1 --max 2 2>&1); RC2=$?
if [[ $RC2 -ne 0 ]]; then ok "an already-acked event does not wake velo-watch (times out instead)"
else fail "woke on an ALREADY-ACKED event: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-200)"; fi
if grep -qi 'TIMEOUT' <<<"$OUT2"; then
  ok "the timeout is reported, not silent"
else
  fail "no TIMEOUT message: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-200)"
fi

# ---- 3: a NEW event appearing mid-wait wakes it before the timeout --------
: > "$ORCH_DIR/attention.jsonl"
rm -f "$ORCH_DIR/acked-ids"
OUT3_FILE="$TMPD/out3.txt"
T2=$(now_s)
"$WATCH" --attention --interval 1 --max 20 > "$OUT3_FILE" 2>&1 &
LIVE_PID=$!
sleep 1.5
jq -cn '{id:"gate-blocked:701:abcdef1", kind:"gate-blocked", pr:701, issue:null, sha:"abcdef1", evidence:"code-review returned blocked"}' \
  >> "$ORCH_DIR/attention.jsonl"
wait "$LIVE_PID"; RC3=$?
LIVE_PID=""
T3=$(now_s)
OUT3=$(cat "$OUT3_FILE")
if [[ $RC3 -eq 0 ]]; then ok "wakes once a new event appears mid-wait"
else fail "did not wake on the new event: rc=$RC3 $(tr '\n' ' ' <<<"$OUT3" | cut -c1-200)"; fi
if grep -qF 'gate-blocked' <<<"$OUT3" && grep -qF '701' <<<"$OUT3"; then
  ok "prints the newly-appeared event"
else
  fail "new event missing from output: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-200)"
fi
ELAPSED3=$(python3 -c "print(f'{$T3 - $T2:.2f}')")
if python3 -c "exit(0 if ($T3 - $T2) < 20.0 else 1)"; then
  ok "woke before the 20s timeout (took ${ELAPSED3}s)"
else
  fail "took the full timeout instead of waking on the new event"
fi

# ---- 4: MUTATION-PROOF — the already-waiting check is what avoids the wait -
BACKUP="$TMPD/velo-watch.backup"
cp "$WATCH" "$BACKUP"
python3 - "$WATCH" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = '  unhandled=$(attention_unhandled)\n  if [ -n "$unhandled" ]; then\n    echo "velo-watch: UNACKED event(s) already waiting $(date -u +%FT%TZ)"\n'
new = '  unhandled=""\n  if [ -n "$unhandled" ]; then\n    echo "velo-watch: UNACKED event(s) already waiting $(date -u +%FT%TZ)"\n'
assert old in t, "the already-waiting attention_unhandled call not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
: > "$ORCH_DIR/attention.jsonl"
jq -cn '{id:"wedge:9003:1", kind:"wedge", pr:null, issue:9003, sha:"1", evidence:"mutation-proof fixture"}' \
  > "$ORCH_DIR/attention.jsonl"
T4=$(now_s)
OUT4=$("$WATCH" --attention --interval 1 --max 20 2>&1); RC4=$?
T5=$(now_s)
cp "$BACKUP" "$WATCH"
if diff -q "$BACKUP" "$WATCH" >/dev/null; then
  ok "velo-watch restored byte-identical after the mutation"
else
  fail "velo-watch did NOT restore cleanly — check $WATCH by hand"
fi
ELAPSED4=$(python3 -c "print(f'{$T5 - $T4:.2f}')")
# The mutation blanks out only the PRE-LOOP check, not the loop's own —
# eventually correct behaviour (rc=0), but only after paying for a full
# sleep(interval) it should never have needed to wait for. The signal is the
# LATENCY the pre-loop check exists to remove, not a miss: scenario 1 above
# (unmutated) answered in well under a second; this must now take at least
# one full interval (~1s) to notice the SAME kind of already-there event.
if [[ $RC4 -eq 0 ]] && python3 -c "exit(0 if ($T5 - $T4) >= 0.9 else 1)"; then
  ok "MUTATION-PROOF red: with the already-waiting check blanked out, noticing the SAME kind of event now costs a full poll interval (${ELAPSED4}s vs <0.1s unmutated)"
else
  fail "mutation-proof did not go RED: rc=$RC4 elapsed=${ELAPSED4}s"
fi
: > "$ORCH_DIR/attention.jsonl"
jq -cn '{id:"wedge:9004:1", kind:"wedge", pr:null, issue:9004, sha:"1", evidence:"restore-verification fixture"}' \
  > "$ORCH_DIR/attention.jsonl"
T6=$(now_s)
OUT5=$("$WATCH" --attention --interval 1 --max 20 2>&1); RC5=$?
T7=$(now_s)
ELAPSED5=$(python3 -c "print(f'{$T7 - $T6:.2f}')")
if [[ $RC5 -eq 0 ]] && grep -qF '9004' <<<"$OUT5" && python3 -c "exit(0 if ($T7 - $T6) < 0.9 else 1)"; then
  ok "MUTATION-PROOF green: restored file sees the already-waiting event again, immediately (${ELAPSED5}s)"
else
  fail "restored file still misses/delays an existing event (rc=$RC5 elapsed=${ELAPSED5}s) — restore did not take"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all velo-watch --attention checks passed" || echo "FAILURES"
exit $FAILED

#!/bin/bash
# Verify velo-status's running_pid_for against the REAL codex process tree shape
# (#2101). Spawns the same three nested frames velo-dispatch creates —
#   bash -c supervisor  ->  timeout <n> codex exec ...  ->  codex exec ...
# — and asserts the helper returns the innermost runner, not either wrapper.
#
# Not a cargo test: the unit under test is a bash function whose input is the
# process table, so the fixture has to be real processes.
set -uo pipefail

STATUS="$(dirname "$0")/../bin/velo-status"
WT="/tmp/velostream-999999"
FAILED=0

ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

# Source only the helpers, not the whole script: velo-status draws a table and
# calls gh on load.
#
# Each extraction is FOLLOWED BY an existence assertion (#2102 review). Without
# it the suite reports false passes on the one input that matters most — a
# velo-status that lacks the helper. `sed` yields an empty string, `eval ""`
# succeeds, and the later `[[ -z "$(exit_record_for ...)" ]]` checks see the
# empty output of `command not found` and print `ok`. Absence of the unit under
# test read as correct behaviour, so running this against master scored 2 of
# its 3 record assertions green. A test that passes when its subject does not
# exist cannot tell you the subject works.
require_fn() {
  if declare -F "$1" >/dev/null; then
    ok "extracted $1 from velo-status"
  else
    fail "$1 NOT extracted — every assertion below it is meaningless"
    echo "  (a missing helper yields empty output, which the -z checks read as pass)"
    exit 1
  fi
}

eval "$(sed -n '/^ere_escape() {/,/^}/p' "$STATUS")"
require_fn ere_escape
eval "$(sed -n '/^running_pid_for() {/,/^}/p' "$STATUS")"
require_fn running_pid_for
eval "$(sed -n '/^exit_record_for() {/,/^}/p' "$STATUS")"
require_fn exit_record_for

# ── fixture: the real three-frame codex tree ────────────────────────────────
# `exec -a` renames the frame so the argv matches what codex actually presents
# without needing codex installed.
bash -c 'exec -a "timeout 14400 codex exec --dangerously-bypass-approvals-and-sandbox --cd '"$WT"' prompt" sleep 30' &
SUP=$!
bash -c 'exec -a "codex exec --dangerously-bypass-approvals-and-sandbox --cd '"$WT"' prompt" sleep 30' &
RUNNER=$!
sleep 1

PID=$(running_pid_for "$WT")

if [[ -n "$PID" ]]; then ok "codex exec --cd is detected (pid $PID)"
else fail "codex exec --cd NOT detected — the #2101 regression is back"; fi

if [[ "$PID" == "$RUNNER" ]]; then
  ok "returned the runner, not the timeout wrapper"
else
  fail "returned $PID; expected runner $RUNNER (wrapper was $SUP)"
fi

CMD=$(ps -o command= -p "$PID" 2>/dev/null)
case "$CMD" in
  *"codex exec"*) ok "argv matches the WORKER naming arm (-> codex)" ;;
  *)              fail "argv would fall through to running? : $CMD" ;;
esac

# Prefix safety: a worktree whose path is a prefix of another must not match it.
if [[ -z "$(running_pid_for "/tmp/velostream-99999")" ]]; then
  ok "prefix worktree does not match longer one"
else
  fail "prefix worktree matched — ( |\$) anchor is broken"
fi

kill "$SUP" "$RUNNER" 2>/dev/null
wait "$SUP" "$RUNNER" 2>/dev/null

# ── regression guard: the Python runners still match ────────────────────────
# The helper moved from `pgrep -af` to a `ps` snapshot, which changes detection
# for EVERY transport, not just codex. glm/deepseek/velo-local go through the
# --cwd arm and must be unaffected.
bash -c 'exec -a "python3 /Users/x/.agents/bin/velo-openrouter-agent-sdk.py --model z-ai/glm-5.3-flash --cwd '"$WT"'" sleep 30' &
PYR=$!
sleep 1
PYPID=$(running_pid_for "$WT")
if [[ "$PYPID" == "$PYR" ]]; then
  ok "python runner (--cwd arm) still detected — no transport regression"
else
  fail "python runner NOT detected (got '$PYPID', expected $PYR)"
fi
CMD=$(ps -o command= -p "$PYR" 2>/dev/null)
case "$CMD" in
  *z-ai/glm*) ok "python runner argv still hits the glm naming arm" ;;
  *)          fail "glm naming arm would not fire: $CMD" ;;
esac
kill "$PYR" 2>/dev/null; wait "$PYR" 2>/dev/null

# No worker at all for this worktree -> empty, so STATE falls through to the
# log-based branches rather than reporting a phantom `running`.
if [[ -z "$(running_pid_for "$WT")" ]]; then
  ok "no worker -> empty pid"
else
  fail "reported a pid with no worker running"
fi

# ── ere_escape ─────────────────────────────────────────────────────────────
# A worktree path is DATA. Spliced raw into the ERE, `/Users/a+b/...` failed to
# match its own literal path and matched `/Users/ab/...` instead (#2102 review).
META="/tmp/velostream-a+b.d"
bash -c 'exec -a "codex exec --dangerously-bypass-approvals-and-sandbox --cd '"$META"' prompt" sleep 30' &
MPID=$!
sleep 1
if [[ "$(running_pid_for "$META")" == "$MPID" ]]; then
  ok "worktree path with ERE metacharacters matches itself"
else
  fail "path with '+'/'.' did not match its own runner — escaping is broken"
fi
if [[ -z "$(running_pid_for "/tmp/velostream-ab.d")" ]]; then
  ok "'+' is not treated as a repeat operator (ab does not match a+b)"
else
  fail "'/tmp/velostream-ab.d' matched the a+b process — regex injection"
fi
kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null

# ── exit_record_for ────────────────────────────────────────────────────────
# Fixtures are BUILT here, in a temp root, rather than read from the author's
# own ~/.agents state (#2102 review). The original pointed at a real #1918
# record, so the assertions passed only on one machine and would rot the moment
# that file was pruned.
#
# `ROOT` is what exit_record_for resolves the record path against.
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.agents/tasks"
REC="$ROOT/.agents/tasks/4242.result.jsonl"
LOG_A="/tmp/dispatch/4242/glm-20260101T000000Z-111.log"
LOG_B="/tmp/dispatch/4242/glm-20260101T000000Z-222.log"
printf '{"issue":4242,"runner":{"log":"%s"},"outcome":"landed"}\n' "$LOG_A" > "$REC"

if [[ -n "$(exit_record_for 4242 "$LOG_A")" ]]; then
  ok "exit_record_for finds the row for a recorded log"
else
  fail "exit_record_for missed a recorded log"
fi

# The same-second re-dispatch case. Both logs share a timestamp to the second
# and differ only by the pid velo-dispatch now appends; the first run's record
# must NOT mark the second, still-live run as done.
if [[ -z "$(exit_record_for 4242 "$LOG_B")" ]]; then
  ok "same-second re-dispatch does not inherit the first run's record"
else
  fail "second run matched the first run's record — a live run reads as done"
fi

# Basename substring safety: a shorter log name must not match a longer row.
if [[ -z "$(exit_record_for 4242 "/tmp/dispatch/4242/glm-20260101T000000Z-11.log")" ]]; then
  ok "a log name that is a prefix of a recorded one does not match"
else
  fail "prefix log name cross-matched — exact-field matching is broken"
fi

if [[ -z "$(exit_record_for 999999 /tmp/nope.log)" ]]; then
  ok "exit_record_for is empty when no record file exists"
else
  fail "exit_record_for returned output with no record file"
fi

# JSON-escaping cases (#2102 review, round 2). `velo-record` serialises with
# json.dumps, so the bytes on disk are NOT the bytes we hold: `\` and `"` are
# escaped, and default ensure_ascii renders non-ASCII as \uXXXX. A raw grep for
# the path silently never matches, and a FINISHED run then reports live forever.
#
# The non-ASCII case is the reachable one — an accented character anywhere in
# $HOME is ordinary, whereas a backslash in a path is not.
python3 - "$ROOT/.agents/tasks/4343.result.jsonl" <<'PY'
import json, sys
rows = [
    {"issue": 4343, "runner": {"log": "/tmp/dispatch/4343/josé-20260101T000000Z-1.log"}},
    {"issue": 4343, "runner": {"log": "/tmp/dispatch/4343/back\\slash-2.log"}},
    {"issue": 4343, "runner": {"log": '/tmp/dispatch/4343/quo"te-3.log'}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, separators=(",", ":")) + "\n")
PY

for CASE in 'josé-20260101T000000Z-1' 'back\slash-2' 'quo"te-3'; do
  if [[ -n "$(exit_record_for 4343 "/tmp/dispatch/4343/${CASE}.log")" ]]; then
    ok "exit_record_for matches a JSON-escaped path: ${CASE}"
  else
    fail "exit_record_for missed JSON-escaped path ${CASE} — a finished run reads as live"
  fi
done

# And it must still REJECT a path that is merely similar to an escaped one.
if [[ -z "$(exit_record_for 4343 '/tmp/dispatch/4343/jose-20260101T000000Z-1.log')" ]]; then
  ok "decoded comparison does not match a near-miss ASCII path"
else
  fail "'jose' matched the 'josé' record — comparison is not exact"
fi

# ── "cannot determine" must not masquerade as "no record" ──────────────────
# With python3 unreachable the helper produced empty stdout, which the caller
# renders as `live?` — a finished run shown as running, on evidence that never
# existed (#2102 review, round 2). rc 2 now separates the cases.
OUT=$(PATH=/nonexistent exit_record_for 4343 "$LOG_A" 2>/dev/null); RC=$?
if [[ $RC -eq 2 ]]; then
  ok "unreachable python3 returns rc 2, not a silent empty result"
else
  fail "python3 absent gave rc=$RC out='$OUT' — an unknown reads as 'no record'"
fi
if [[ -n "$(PATH=/nonexistent exit_record_for 4343 "$LOG_A" 2>&1 >/dev/null)" ]]; then
  ok "the failure reason is reported on stderr, not swallowed"
else
  fail "no diagnostic on stderr — the error was swallowed"
fi

# ── worker-name parsing survives the -$$ suffix ────────────────────────────
# velo-status derives the worker from the log NAME. The `-$$` disambiguator
# added to velo-dispatch in this branch changes the hyphen count, and the old
# `${BN%-*}` rule would have rendered `glm-20260101T000000Z-1234` as the worker
# `glm-20260101T000000Z` — the identical regression the code comment says was
# already fixed once. Neither gate round caught this.
worker_of() { sed -E 's/-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$//' <<<"$1"; }
for PAIR in 'glm-20260101T000000Z-1234:glm' \
            'glm-20260101T000000Z:glm' \
            'velo-local-20260101T000000Z-1234:velo-local' \
            'codex-20260101T000000Z-9:codex'; do
  GOT=$(worker_of "${PAIR%%:*}"); WANT="${PAIR##*:}"
  if [[ "$GOT" == "$WANT" ]]; then
    ok "worker name from ${PAIR%%:*} -> $GOT"
  else
    fail "worker name from ${PAIR%%:*} -> '$GOT', expected '$WANT'"
  fi
done
# The rule must match what velo-status actually ships, not just this copy of it.
if grep -q "s/-\[0-9\]{8}T\[0-9\]{6}Z(-\[0-9\]+)?\$//" "$STATUS"; then
  ok "velo-status uses the anchored worker-name rule"
else
  fail "velo-status's worker-name rule differs from the one asserted here"
fi

# ── runner log is chosen over dispatch bookkeeping ─────────────────────────
# The dispatch dir holds `dispatch-<UTC>.log` and `zg-index.log` alongside the
# runner log, and dispatch writes its own log AFTER the runner starts — so the
# newest file is usually not the one we want (#2112). Everything velo-status
# reports is derived from this choice, so the fixture puts the decoys NEWER,
# which is the shape that actually occurs.
LOGDIR=$(mktemp -d)
printf 'runner\n' > "$LOGDIR/glm-20260101T000000Z-111.log"
sleep 1
printf 'dispatch bookkeeping\n' > "$LOGDIR/dispatch-20260101T000100Z.log"
printf 'index build\n'          > "$LOGDIR/zg-index.log"

# The selection rule as velo-status runs it.
pick_log() {
  ls -t "$1"/*.log 2>/dev/null \
    | grep -vE '/(dispatch-[0-9]{8}T[0-9]{6}Z|zg-index)\.log$' | head -1
}
PICKED=$(basename "$(pick_log "$LOGDIR")" 2>/dev/null)
if [[ "$PICKED" == "glm-20260101T000000Z-111.log" ]]; then
  ok "runner log chosen over a NEWER dispatch log"
else
  fail "picked '$PICKED' — expected the runner log, not dispatch bookkeeping"
fi

# The old rule must actually have been broken, or the assertion above proves
# nothing. Asserted as "picks something that is NOT the runner log" rather than
# naming a specific decoy — which of the two is newest depends on write order,
# and pinning one made this fail for the wrong reason.
OLD=$(basename "$(ls -t "$LOGDIR"/*.log | head -1)")
if [[ "$OLD" != "glm-20260101T000000Z-111.log" ]]; then
  ok "the unfiltered rule picks a non-runner log ('$OLD') — defect reproduced"
else
  fail "fixture does not reproduce the defect — unfiltered rule found the runner log"
fi

# A dir with ONLY decoys must yield empty, not a dispatch log. Empty makes the
# worktree read as `idle`, which is honest; substituting a bookkeeping file is
# what produced the worker named `dispatch`.
ONLYDIR=$(mktemp -d)
printf 'x\n' > "$ONLYDIR/dispatch-20260101T000100Z.log"
printf 'x\n' > "$ONLYDIR/zg-index.log"
if [[ -z "$(pick_log "$ONLYDIR")" ]]; then
  ok "no runner log -> empty, rather than substituting bookkeeping"
else
  fail "substituted a non-runner log: $(pick_log "$ONLYDIR")"
fi

# A future worker whose LOGTAG starts with "dispatch" must NOT be swallowed
# (#2113 review). `dispatch-[^/]*` would have discarded its runner log and shown
# the worktree as idle with a live worker — defeating the forward-compatibility
# this selection exists to preserve. The trailing `-<pid>` is what separates a
# runner log from bookkeeping, so the exclusion pins the exact bookkeeping shape.
TAGDIR=$(mktemp -d)
printf 'runner\n' > "$TAGDIR/dispatch-20260101T000000Z-777.log"
sleep 1
printf 'bookkeeping\n' > "$TAGDIR/dispatch-20260101T000100Z.log"
PICKED=$(basename "$(pick_log "$TAGDIR")" 2>/dev/null)
if [[ "$PICKED" == "dispatch-20260101T000000Z-777.log" ]]; then
  ok "a worker LOGTAG of 'dispatch' is not swallowed by the exclusion"
else
  fail "picked '$PICKED' — a 'dispatch' LOGTAG's runner log was discarded"
fi
rm -rf "$TAGDIR"

# And the rule asserted here must be the rule velo-status ships.
if grep -q 'dispatch-\[0-9\]{8}T\[0-9\]{6}Z|zg-index' "$STATUS"; then
  ok "velo-status ships the runner-log filter asserted here"
else
  fail "velo-status's log-selection rule differs from the one asserted here"
fi
rm -rf "$LOGDIR" "$ONLYDIR"

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $FAILED

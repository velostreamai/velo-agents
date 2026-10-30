#!/bin/bash
# Claude Code Stop hook: a session may not end while a job of its own is in flight (docs/velo-task-spec.md). Beside velo-task-session-start.sh.
#
# Blocks when Vanth's jobs.sqlite (read-only, no daemon needed) holds a job tagged session:<me> whose verdict is in-flight (queued, launching,
# running, paused, retrying, stopping, or failed/orphaned with a restart pending); each is printed with the command that clears it. Other
# sessions never block, a finished job does not, and a lost job does not (it shows as `lost` in `velo-task status`/`wait`).
# Fail closed: once a Vanth home exists, ANYTHING but a proven "nothing in flight" blocks, with the one way out, `velo-task stop-override
# --reason <text>`, which lets one Stop through: a missing database, a database that is garbled, locked past 2 s or of another schema, a
# library that is missing or does not load, a query that does not end in the success sentinel (a library that calls `exit 0` included).
# Only a Vanth HOME that is genuinely absent (no symlink, dangling or not; no non-directory) allows: nothing was ever started here. Nothing releases a block after N runs. No program is looked up on PATH.
# Contract: exit 0 lets the session stop, exit 2 blocks with the reason on stderr.
/bin/cat >/dev/null 2>&1 || true   # the Stop payload is not read: the session is velo-task's own resolution, not something a payload can name
HINT="to end this session anyway: velo-task stop-override --reason <text>"
block() { printf 'velo-task Stop guard: %s\n' "$1" >&2; exit 2; }
[ -n "${VELO_TASK_HOME:-}${VELO_STATE:-}${HOME:-}" ] || block "no HOME, VELO_STATE or VELO_TASK_HOME: the state directory cannot be located
$HINT"
STATE="${VELO_TASK_HOME:-${VELO_STATE:-$HOME/.agents/state}/velo-task}"
# "No Vanth home" is only a path that is genuinely absent: a dangling or live symlink, a non-directory, anything else goes on to the checks.
if [ ! -L "$STATE" ] && [ ! -L "$STATE/vanth" ] && [ ! -e "$STATE/vanth" ] && { [ ! -e "$STATE" ] || [ -d "$STATE" ]; }; then exit 0; fi
SELF="${BASH_SOURCE[0]}"; DIR="${SELF%/*}"; [ "$DIR" != "$SELF" ] || DIR=.
LIB="$DIR/../bin/velo-task-lib.sh"
OK=VELO_GUARD_QUERY_COMPLETE
# The library runs in a child (/bin/bash -c); only its sentinel, printed after everything succeeded, proves the query ran to the end.
deny() {  # <why>: a pending valid one-shot override is spent here, and only here
  local o
  o=$(/bin/bash -c '. "$1" && st override-take "$VELO_TASK_HOME" && echo '"$OK" x "$LIB" 2>/dev/null) || o=""
  if [ "${o##*$'\n'}" = "$OK" ]; then echo "velo-task Stop guard: stop-override used; allowing this Stop (see overrides.log in the velo-task state dir)"; exit 0; fi
  block "$1
$HINT"
}
[ -r "$LIB" ] || deny "the velo-task library beside this hook is missing, so jobs cannot be checked"
out=$(/bin/bash -c '. "$1" || exit 1; s=$(session_id) || exit 1; rows=$(inflight_of "$s") || exit 1
while read -r n j st; do [ -z "$n" ] || echo "ROW   $n ($j) $st: $(wait_hint "$n" "$j")"; done <<<"$rows"
echo '"$OK" x "$LIB" 2>&1) || deny "Vanth's database cannot be read, or the check did not complete: $out"
[ "${out##*$'\n'}" = "$OK" ] || deny "the check did not complete (no success marker): $out"
rows=$(printf '%s\n' "$out" | /usr/bin/grep '^ROW ' | /usr/bin/sed 's/^ROW //')
[ -n "$rows" ] || exit 0
deny "this session still has jobs in flight; waiting is the only way to end it:
$rows"

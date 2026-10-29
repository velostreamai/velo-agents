#!/bin/bash
# Claude Code Stop hook: a session may not end while a job of its own is in flight (docs/velo-task-spec.md). Beside velo-task-session-start.sh.
#
# Blocks when Vanth's jobs.sqlite (read-only, no daemon needed) holds a job tagged session:<me> in queued, launching, running, paused,
# retrying or stopping; each is printed with the command that clears it. Other sessions never block, a finished job does not, and a lost
# job does not (it shows as `lost` in `velo-task status`/`wait`).
# Fail closed: Vanth's home exists but its database cannot be read (garbled, locked past 2 s, another schema), or the library beside the
# hook is missing or does not load => BLOCK, with the one way out, `velo-task stop-override --reason <text>`, which lets one Stop through.
# No Vanth home => allow: nothing was ever started here. Nothing releases a block after N runs.
# Contract: exit 0 lets the session stop, exit 2 blocks with the reason on stderr.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
LIB="$HOOK_DIR/../bin/velo-task-lib.sh"
/bin/cat >/dev/null 2>&1 || true   # the Stop payload is not read: the session is velo-task's own resolution, not something a payload can name
STATE="${VELO_TASK_HOME:-${VELO_STATE:-$HOME/.agents/state}/velo-task}"
[ -d "$STATE/vanth" ] || exit 0
HINT="to end this session anyway: velo-task stop-override --reason <text>"
block() { printf 'velo-task Stop guard: %s\n' "$1" >&2; exit 2; }
{ [ -r "$LIB" ] && ( . "$LIB" ) >/dev/null 2>&1; } || block "the velo-task library beside this hook is missing or does not load, so jobs cannot be checked
$HINT"
. "$LIB"
deny() {  # <why>: a pending one-shot override is spent here, and only here
  if st override-take "$VELO_TASK_HOME"; then echo "velo-task Stop guard: stop-override used; allowing this Stop (see $VELO_TASK_HOME/overrides.log)"; exit 0; fi
  block "$1
$HINT"
}
session=$(session_id 2>&1) || deny "the session cannot be resolved: $session"
rows=$(inflight_of "$session" 2>&1) || deny "Vanth's database cannot be read: $rows"
[ -n "$rows" ] || exit 0
msg="this session still has jobs in flight; waiting is the only way to end it:"
while read -r name job status; do msg="$msg
  $name ($job) $status: $(wait_hint "$name" "$job")"; done <<<"$rows"
deny "$msg"

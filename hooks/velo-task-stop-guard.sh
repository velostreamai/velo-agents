#!/bin/bash
# Claude Code Stop hook for the velo-task session: blocks a session that still has jobs of its own in flight, or lost and not
# acknowledged (docs/velo-task-spec.md R8, R9; scope decision on velo-agents#7). Beside velo-task-session-start.sh.
#
# Blocking: a job tagged session:<me> whose verdict (the helper's, R1) is in flight -- queued, starting, running, stopping,
# cancelling, waiting -- or lost and without an ack marker. Each blocks with the one command that clears it:
# `velo-task wait <id>` for a job that is still running, `velo-task ack <job_id>` for one that stopped without a verdict.
# Not blocking: another session's jobs, anything that finished (ok, failed(n), timeout, killed, upstream-failed(<parent>)), a
# lost job that is acked, and a state directory that does not exist at all (nothing was ever started here).
#
# Fail closed (R8): a state path that is not yours, a jobs.sqlite that is missing while the name index or a pending record is
# there, one that is locked past its 2000 ms busy timeout, or one of another schema all BLOCK. A block prints what could not be
# read and the one way out, `velo-task stop-override --reason <text>`. Nothing releases a block after N runs, and a job that is
# acknowledged and then runs again blocks again: the ack marker closes a stopped row, never a running one.
#
# Read-only: jobs.sqlite through the state helper's verdict-of/job-info (read-only queries), no daemon, no writes. The Stop
# payload on stdin is not read: the session is velo-task's own resolution ($CLAUDE_SESSION_ID, else the state dir's token), so
# a payload from another tool cannot name the session this hook guards.
#
# Contract: exit 0 lets the session stop (silent when nothing blocks), exit 2 blocks with the reason on stderr. Anything else
# that goes wrong is turned into exit 2 by construction: a guard that cannot run is a guard that fails closed, and the message
# carries the override command. Fails open only when the library is not installed beside the hook, the same way the README
# registration line skips a hook that is not installed.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
LIB="${VELO_TASK_LIB:-$HOOK_DIR/../bin/velo-task-lib.sh}"
/usr/bin/cat >/dev/null 2>&1 || true   # drain the payload, read nothing from it (see above)
out=$(
  {
    . "$LIB" || exit 90                  # 90: no library beside the hook, so nothing to guard (fails open)
    hook_stop_guard
  } 2>&1
)
rc=$?
if [ "$rc" = 0 ] || [ "$rc" = 90 ]; then exit 0; fi
printf '%s\n' "$out" >&2
if [ "$rc" != 2 ]; then
  printf 'the Stop guard could not run (velo-task exit %s), so it blocks (R8)\n' "$rc" >&2
  printf 'to end this session anyway: velo-task stop-override --reason <text>\n' >&2
fi
exit 2
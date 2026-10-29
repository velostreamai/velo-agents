#!/bin/bash
# Claude Code SessionStart hook for the velo-task session: prints this session's unfinished jobs first, with the command that
# clears each, then one line on the other sessions (docs/velo-task-spec.md R8, R9; scope decision on velo-agents#7). Beside
# velo-task-stop-guard.sh, whose verdict it shows in advance.
#
# A job of session:<me> is listed when its verdict (the helper's, R1) is in flight -- queued, starting, running, stopping,
# cancelling, waiting -- with `velo-task wait <id>`, or lost and without an ack marker, with `velo-task ack <job_id>`. Then one
# line, `other sessions: N in flight`, which lists nothing and blocks nothing: another session's jobs are never this one's work.
#
# Never blocks: however unreadable the job state is, this prints what it could not read and exits 0, so a session always starts.
# It writes nothing and asks no daemon: jobs.sqlite through the state helper's read-only queries, like the Stop guard. The
# session is velo-task's own resolution ($CLAUDE_SESSION_ID, else the state dir's token); the payload on stdin is not read.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
LIB="${VELO_TASK_LIB:-$HOOK_DIR/../bin/velo-task-lib.sh}"
/usr/bin/cat >/dev/null 2>&1 || true   # drain the payload, read nothing from it (see above)
out=$(
  {
    . "$LIB" || exit 90                  # 90: no library beside the hook, so nothing to report (fails open, like the guard)
    hook_session_start
  } 2>&1
)
rc=$?
[ "$rc" = 90 ] && exit 0
[ -z "$out" ] || printf '%s\n' "$out"
exit 0
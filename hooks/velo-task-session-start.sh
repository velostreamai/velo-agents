#!/bin/bash
# Claude Code SessionStart hook: tells a new session which jobs of its own are in flight, from Vanth only (docs/velo-task-spec.md).
# Prints each as `<name> <job_id> <status>: <command that waits for it>`, then `other sessions: N in flight`. Silent when there is no Vanth
# home. Advisory, always exit 0: an unreadable database is said so on stdout, never an error that would obstruct the session start.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
STATE="${VELO_TASK_HOME:-${VELO_STATE:-$HOME/.agents/state}/velo-task}"
if [ ! -L "$STATE" ] && [ ! -L "$STATE/vanth" ] && [ ! -e "$STATE/vanth" ] && { [ ! -e "$STATE" ] || [ -d "$STATE" ]; }; then exit 0; fi  # only a genuinely absent home is silent
[ -r "$HOOK_DIR/../bin/velo-task-lib.sh" ] && . "$HOOK_DIR/../bin/velo-task-lib.sh" 2>/dev/null || exit 0
session=$(session_id 2>&1) || { echo "velo-task: the session cannot be resolved: $session"; exit 0; }
rows=$(inflight_of "$session" 2>&1) || { echo "velo-task: Vanth's database cannot be read, so in-flight jobs are unknown: $rows"; exit 0; }
others=$(inflight_elsewhere "$session" 2>&1) || others="unknown"
if [ -n "$rows" ]; then
  echo "velo-task: jobs of this session still in flight:"
  while read -r name job status; do echo "  $name $job $status: $(wait_hint "$name" "$job")"; done <<<"$rows"
fi
echo "other sessions: $others in flight"
exit 0

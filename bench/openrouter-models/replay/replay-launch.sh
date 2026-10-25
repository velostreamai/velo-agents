#!/bin/bash
# Replay one completed ticket on one model.
#   replay-launch.sh <issue> <arm> <model-id>
# Needs, beforehand:
#   - a detached worktree at the BASE (the parent of the merged PR's merge commit):
#       git worktree add --detach ~/RustroverProjects/velostream-replay-<issue>-<arm> <base-sha>
#   - a brief at ~/.agents/state/scratch/replay-<issue>/brief-<arm>.md that names
#     BRANCH: replay/<issue>-<arm> and that worktree (see README.md: the brief states the
#     problem from the issue; it does not contain the fix).
# Runs the runner directly — a replay has a historical base, which velo-dispatch (it always
# cuts from current origin/master) cannot give it. Nothing is pushed.
set -u
ISSUE="$1"; ARM="$2"; MODEL="$3"
WT="$HOME/RustroverProjects/velostream-replay-$ISSUE-$ARM"
OUT="$HOME/.agents/state/scratch/replay-$ISSUE"
git -C "$WT" switch -q -c "replay/$ISSUE-$ARM"
~/.agents/bin/zg --root "$WT" index > "$OUT/zg-$ARM.log" 2>&1
S=$(date -u +%s)
~/.agents/bin/velo-openrouter-agent --model "$MODEL" \
  --policy ~/.agents/rules/velo-impl.md --max-turns 250 --prompt-timeout 3600 \
  --max-budget-usd 1 --cwd "$WT" --task "$(cat "$OUT/brief-$ARM.md")" \
  --skill ~/.claude/commands/check-code.md > "$OUT/run-$ARM.log" 2>&1
echo "exit=$? wall_s=$(( $(date -u +%s) - S ))" >> "$OUT/run-$ARM.log"

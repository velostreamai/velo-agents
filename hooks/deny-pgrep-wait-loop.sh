#!/bin/bash
# Claude Code PreToolUse hook for Bash, beside require-wait.sh: denies hand-written `until/while pgrep` wait loops
# (docs/velo-task-spec.md R10, bar B13). It allows `velo-task wait`.
#
# Why: a loop that polls a process list infers completion from absence. A crash, a kill, a timeout and a success
# look the same to it, and six near-identical `until pgrep -f ...` loops stacked on one condition is how
# velo-task started. `velo-task wait` returns one verdict per id and its exit code mirrors it.
#
# Denied: a `pgrep` command, in command position, inside a `while` or `until` loop, in its condition or its body:
#   until pgrep -f x; do sleep 5; done          while ! pgrep -f x; do ...; done      while [ -n "$(pgrep -f x)" ]; do ...
#   while true; do pgrep -f x || break; sleep 5; done        and the same behind env, sudo, an absolute path, a pipe, a newline
# Not denied: pgrep outside a while/until loop (a plain test, `for p in $(pgrep -f x); do kill $p; done`,
# `pgrep -f x | xargs kill`), `velo-task wait` in any shape, and any mention of the words in a quoted string, a
# heredoc or a comment. Known false positive, accepted: a pgrep inside any while loop body, even a list producer:
# `while read n; do for p in $(pgrep -f "$n"); do ...`.
#
# Known false negatives (tests/test_velo_task_hooks.sh pins each one, so closing a gap makes that test say so):
# a loop in a string handed to bash -c / sh -c / eval, `for` and `watch` polls, other probes (ps | grep, pidof,
# kill -0, a pid or marker file), a variable holding the program name ($PGREP), a script file, a wrapper option
# that takes a word (sudo -u neil pgrep ...).
#
# Contract (same as require-wait.sh): stdin JSON {"tool_input":{"command":...}}; exit 0 allows, exit 2 + stderr blocks.
# Fails open: no jq, no lib beside it, malformed JSON or no command all exit 0, so a broken install never wedges Bash.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0
. "$HOOK_DIR/guard-lib.sh" || exit 0
guard_scan_payload || exit 0

# One letter per open loop, innermost first: W for while/until, F for for/select. `done` closes the innermost.
loops=""
while IFS= read -r seg; do
  guard_cmd_words "$seg"
  for kw in $GW_KW; do
    case $kw in
      while|until) loops="W$loops" ;;
      for|select)  loops="F$loops" ;;
      done)        loops="${loops#?}" ;;
    esac
  done
  case $loops in
    *W*) if [ "${GW[0]##*/}" = pgrep ]; then
           guard_deny "BLOCKED: a hand-written \`until/while pgrep\` wait loop (docs/velo-task-spec.md R10). A process list cannot
tell success from a crash, a kill or a timeout. Wait with one call per batch, as a Bash tool call with run_in_background: true:

  velo-task wait <id> [<id>...]

and run \`velo-task status\` when you are unsure what is in flight." "$seg"
         fi ;;
  esac
done <<<"$SEGS"
exit 0

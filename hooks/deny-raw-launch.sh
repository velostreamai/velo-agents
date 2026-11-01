#!/bin/bash
# Claude Code PreToolUse hook for Bash: denies a raw launch of a worker or of a Codex run outside velo-dispatch
# (docs/velo-task-spec.md R10).
#
# Why: bin/velo-dispatch is what puts a launch under velo-task: it picks the worktree and the brief, starts the runner
# under the runner's own venv, and records the job, so `velo-task status` and the Stop guard can see it and a verdict can
# be waited on. A raw
#   nohup velo-openrouter-agent --model ... --brief ... &        codex exec "..."        codex -c model=x exec "..."
# skips every one of those gates, is invisible to `velo-task status` and to the Stop guard, and leaves the orchestrating
# model polling a log file -- the shape velo-task exists to replace. This is a GUARDRAIL against the orchestrating LLM's
# own mistakes, not isolation: a job runs as the same uid and can still exec the runner (R15(i)).
#
# Denied, as a command in command position (guard-lib.sh): the worker runner `velo-openrouter-agent`, by name or by any
# path, and `codex` about to run its `exec` subcommand, in any of these shapes:
#   velo-openrouter-agent ...     /abs/or/relative/path/to/velo-openrouter-agent ...     "$HOME/.agents/bin/velo-openrouter-agent" ...
#   codex exec ...     codex -c model=x exec ...     and any of those behind VAR=value, env, sudo, nohup, time, timeout N,
#   xargs, command, exec, uv run, uvx, pipx run, or inside if/while/do/{ }/( )/$( )/&&/||/|/;
# Not denied: `velo-openrouter-agent --help` (and -h, --version), which only prints help or a version; every other codex
# subcommand (`codex login`, `codex --version`); any mention of the words in a quoted string, a heredoc or a comment
# (`git commit -m "nohup velo-openrouter-agent"`); and anything run by velo-dispatch, velo-gate-run or velo-pr-gate
# themselves: those are scripts, and the runner they start is started inside them, so the Bash tool call reads
# `velo-dispatch <issue> <brief> --wait` and this hook never sees the program.
#
# Known false negatives (tests/test_velo_task_hooks.sh pins each one, so closing a gap makes that test say so, and
# checks that each is listed here and in the README table):
# a string handed to bash -c / sh -c / eval, a variable or alias holding the program ($AGENT --model x), the
# output of a command substitution naming the program ("$(echo codex)" exec ...), xargs substitution (echo codex |
# xargs -I{} {} exec ...), a script file that launches it, find -exec, a wrapper option that takes a word (sudo -u neil),
# a codex option this hook does not know takes a word (codex --new-flag v exec ...), a differently cased name on a
# case-insensitive volume, the other raw entry points (bin/velo-openrouter-agent-sdk.py,
# bin/velo-openai-agents-runner.py, and the runner copied under another name), a redirection in front of the command name
# (>out velo-openrouter-agent --model x, 2>&1 codex exec ...), and more than 1 KB of text in front of the command in one
# segment (the scanner keeps a segment's first 1024 characters).
#
# Contract (same as require-wait.sh): stdin JSON {"tool_input":{"command":...}}; exit 0 allows, exit 2 + stderr blocks.
# Fails open: no jq, no lib beside it, malformed JSON or no command all exit 0, so a broken install never wedges Bash.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0
. "$HOOK_DIR/guard-lib.sh" || exit 0
guard_scan_payload || exit 0

# raw_launch_sub: succeeds when GW in command position is a program this hook denies -- the worker runner
# `velo-openrouter-agent`, or `codex` about to run its `exec` subcommand. Codex reads its global options first, and the
# options that take a word (codex -c model=x exec ..., codex -m gpt-5 exec ...) take theirs with them; the subcommand is
# the first word that is neither an option nor such a word. -h/--help and --version before `--` only print and stop, so
# they exempt.
raw_launch_sub() {
  local i=1 w base=${GW[0]##*/}
  case $base in
    velo-openrouter-agent) ;;
    codex)
      while [ "$i" -lt "${#GW[@]}" ]; do
        w=${GW[i]}
        case $w in
          -c|--config)       i=$((i + 2)) ;;   # -c model=x: the word after it is not the subcommand
          -m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|-i|--image|-o|--enable|--disable|--output-last-message)
                             i=$((i + 2)) ;;
          -*)                i=$((i + 1)) ;;   # --model=gpt-5 and -mgpt-5 carry their value themselves
          *)                 break ;;
        esac
      done
      [ "${GW[i]:-}" = exec ] || return 1
      ;;
    *) return 1 ;;
  esac
  i=1
  while [ "$i" -lt "${#GW[@]}" ]; do
    case ${GW[i]} in
      --)                  return 0 ;;
      -h|--help|--version) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

while IFS= read -r seg; do
  guard_cmd_words "$seg"
  if raw_launch_sub; then
    guard_deny "BLOCKED: a raw launch of a worker or of a Codex run (docs/velo-task-spec.md R10). It skips every gate
velo-dispatch applies and is invisible to \`velo-task status\` and to the Stop guard. Launch through the supported entry point:

  velo-dispatch <issue> <brief> --wait

for a worker, and \`velo-gate-run <pr> <scope>\` for a gate." "$seg"
  fi
done <<<"$SEGS"
exit 0
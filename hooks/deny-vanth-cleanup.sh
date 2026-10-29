#!/bin/bash
# Claude Code PreToolUse hook for Bash: denies the command forms `vanth prune` and `vanth restore`
# (docs/velo-task-spec.md R15(i), bar B29 hook half).
#
# Why: velo-task judges every job from Vanth's jobs.sqlite. `vanth prune` deletes terminal rows and `vanth restore`
# swaps the database for an older one, so a job velo-task has not yet reported can vanish from `velo-task status`
# and from the Stop guard. velo-task never calls either. This is a GUARDRAIL against the orchestrating LLM's own
# mistakes, not isolation: a job runs as the same uid and can reach jobs.sqlite and an absolute vanth, so a
# deliberately hostile job can still delete rows. Untrusted jobs are out of scope (R15(i)).
#
# Denied, as a command in command position (guard-lib.sh): vanth [--json] prune|restore, in any of these shapes:
#   vanth ...        /abs/or/relative/path/to/vanth ...        "$HOME/.../vanth" ...
#   python[3.x] [options] -m vanth[.cli] ...        and any of those behind VAR=value, env, sudo, nohup, time,
#   timeout N, xargs, command, exec, uv run, uvx, pipx run, or inside if/while/do/{ }/( )/$( )/&&/||/|/;
# Not denied: `vanth prune --help` (and -h), which only prints help; any other vanth subcommand; any mention of the
# words in a quoted string, a heredoc or a comment (git commit -m "..", gh pr create --body ..).
#
# Known false negatives (tests/test_velo_task_hooks.sh pins each one, so closing a gap makes that test say so, and
# checks that each is listed here and in the README table):
# a string handed to bash -c / sh -c / eval, a variable or alias or function holding the program ($VANTH prune), the
# output of a command substitution naming the program ("$(echo vanth)" prune), xargs substitution (echo vanth |
# xargs -I{} {} prune), a script file that runs it, find -exec, a wrapper option that takes a word (sudo -u neil), a
# differently cased name on a case-insensitive volume, a redirection in front of the command name (>out vanth prune,
# 2>&1 vanth prune), a quoted command path that contains a space ("/Users/me/My Venv/bin/vanth" prune), more than 1 KB
# of text in front of the command in one segment (the scanner keeps a segment's first 1024 characters), and the other
# cleanup paths of R15(i): POST /cleanup by curl, the MCP job_cleanup tool, `python -c 'from vanth.cli import main;
# ...'`, and automatic retention (VANTH_RETENTION_SECONDS).
#
# Contract (same as require-wait.sh): stdin JSON {"tool_input":{"command":...}}; exit 0 allows, exit 2 + stderr blocks.
# Fails open: no jq, no lib beside it, malformed JSON or no command all exit 0, so a broken install never wedges Bash.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0
. "$HOOK_DIR/guard-lib.sh" || exit 0
guard_scan_payload || exit 0

# vanth_cleanup_sub: succeeds and sets SUB to the subcommand when GW is the vanth CLI about to run prune or restore.
# Vanth reads its one global flag, --json, anywhere before `--`; the subcommand is the first other word. -h/--help
# before `--` makes it print help and stop.
vanth_cleanup_sub() {
  local i=1 j w mod="" base=${GW[0]##*/}
  case $base in
    vanth) ;;
    python*|pypy*)
      while [ "$i" -lt "${#GW[@]}" ]; do
        w=${GW[i]}
        case $w in
          -m|-[A-Za-z]*m) mod=${GW[i+1]:-}; i=$((i + 2)); break ;;   # -m, or a cluster ending in it: -Im
          -m?*)  mod=${w#-m}; i=$((i + 1)); break ;;
          -X|-W) i=$((i + 2)) ;;
          -*)    i=$((i + 1)) ;;
          *)     return 1 ;;
        esac
      done
      case $mod in vanth|vanth.cli|vanth.__main__) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  while [ "${GW[i]:-}" = "--json" ]; do i=$((i + 1)); done
  w=${GW[i]:-}
  case $w in prune|restore) ;; *) return 1 ;; esac
  for ((j = i + 1; j < ${#GW[@]}; j++)); do
    case ${GW[j]} in --) break ;; -h|--help) return 1 ;; esac
  done
  SUB=$w
}

while IFS= read -r seg; do
  guard_cmd_words "$seg"
  if vanth_cleanup_sub; then
    guard_deny "BLOCKED: \`vanth $SUB\` deletes job rows (or swaps the whole database) behind velo-task's back, so a job
it has not yet reported can vanish from \`velo-task status\` and from the Stop guard (docs/velo-task-spec.md R15(i)).
velo-task never calls prune or restore. If rows really must go, ask the owner to run it by hand outside this session." "$seg"
  fi
done <<<"$SEGS"
exit 0

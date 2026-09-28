#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash.
#
# Enforces that velo-dispatch, velo-pr-gate and velo-merge are only launched
# with --wait AND run_in_background: true.
#
# Why: all three launch detached work (nohup) and used to return the instant
# it was launched. The orchestrating Claude Code session is only woken by a
# run_in_background Bash command EXITING — so a launch without --wait (which
# now blocks until the work is actually done) and without
# run_in_background: true (which is what makes that block visible to the
# session as a wake-up rather than a stalled foreground call) went unnoticed
# for up to 8 hours, relying entirely on the orchestrator remembering to arm
# `velo-watch` afterwards. This hook removes the "remembering" step: the
# combination is enforced structurally, not by convention.
#
# Hook contract (per Claude Code docs, same as scripts/claude-hooks/git-pre-commit-fmt.sh):
#   stdin  = JSON {"tool_name": "Bash", "tool_input": {"command": "...", "run_in_background": bool}, ...}
#   exit 0             = allow, no message
#   exit 2 + stderr    = BLOCK the tool call; stderr is shown to Claude as feedback
#
# Exempt: --plan / --dry-run / --help calls (they dispatch nothing, so there
# is nothing to wait for or be woken up about), and any command that does not
# invoke one of the three gated entry points at all.

set -euo pipefail

payload=$(cat)

# If jq is unavailable, allow rather than block every Bash call in the
# session over a missing dependency this hook happens to need — the failure
# mode of "wedges all bash" is far worse than "this one enforcement is
# skipped once". Same fallback scripts/claude-hooks/git-pre-commit-fmt.sh uses.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")
bg=$(jq -r '.tool_input.run_in_background // false' <<<"$payload")

[[ -n "$cmd" ]] || exit 0

# Regexes are held in variables and matched via `[[ $x =~ $re ]]` rather than
# written inline: bash's OWN parser tokenizes an inline `(`/`|` inside `[[ ]]`
# before the string ever reaches the regex engine, which is ambiguous with
# subshell/pipe syntax and fails with "unexpected EOF" — a plain variable
# reference on the right of =~ sidesteps that parse step entirely.
EXEMPT_RE='(^|[[:space:]])--(plan|dry-run|help)([[:space:]]|$)'
WAIT_RE='(^|[[:space:]])--wait([[:space:]]|$)'

# Does this command invoke one of the three gated entry points? A naive
# substring/basename match false-positives on any MENTION of the name —
# `ls ~/.agents/bin/velo-dispatch`, `diff a/velo-merge b/velo-merge`, a
# heredoc body, or a quoted string argument to `gh pr comment --body "..."`
# — none of which EXECUTE the tool. Only a mention in COMMAND POSITION
# (start of string, or right after `;`, `&&`, `||`, `|`, `(`/`$(`, or a
# newline — optionally preceded by env assignments and a `bash`/`sh` runner,
# optionally path-prefixed) counts. The pipeline below: strip heredoc
# bodies, strip quoted strings, split on separators, then test only the
# first word of each resulting segment.
HEREDOC_DQ_RE='<<(-)?[[:space:]]*"([A-Za-z_][A-Za-z0-9_]*)"'
HEREDOC_SQ_RE="<<(-)?[[:space:]]*'([A-Za-z_][A-Za-z0-9_]*)'"
HEREDOC_BARE_RE='<<(-)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)'
ENV_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+'
BASH_SH_PREFIX_RE='^(bash|sh)[[:space:]]+'
GATE_TOOL_BASENAME_RE='^velo-(dispatch|pr-gate|merge)$'

# Strip heredoc BODY lines (from a "<<[-]DELIM" / "<<'DELIM'" / '<<"DELIM"'
# marker to the line that is exactly DELIM) so a mention of a gated tool
# inside heredoc DATA is never mistaken for an invocation.
strip_heredocs() {
  local line in_body=0 strip_leading_ws=0 delim="" probe
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_body" -eq 1 ]]; then
      probe="$line"
      if [[ "$strip_leading_ws" -eq 1 ]]; then
        probe="${probe#"${probe%%[![:space:]]*}"}"
      fi
      [[ "$probe" == "$delim" ]] && in_body=0
      continue
    fi
    printf '%s\n' "$line"
    if [[ "$line" =~ $HEREDOC_DQ_RE ]]; then
      delim="${BASH_REMATCH[2]}"
      [[ -n "${BASH_REMATCH[1]}" ]] && strip_leading_ws=1 || strip_leading_ws=0
      in_body=1
    elif [[ "$line" =~ $HEREDOC_SQ_RE ]]; then
      delim="${BASH_REMATCH[2]}"
      [[ -n "${BASH_REMATCH[1]}" ]] && strip_leading_ws=1 || strip_leading_ws=0
      in_body=1
    elif [[ "$line" =~ $HEREDOC_BARE_RE ]]; then
      delim="${BASH_REMATCH[2]}"
      [[ -n "${BASH_REMATCH[1]}" ]] && strip_leading_ws=1 || strip_leading_ws=0
      in_body=1
    fi
  done
}

# Strip single- and double-quoted string spans so a mention inside a quoted
# argument (e.g. `gh pr comment --body "... velo-merge ..."`) is never
# mistaken for an invocation, and so a separator character quoted inside a
# string is never mistaken for a real command separator.
strip_quotes() {
  sed "s/'[^']*'//g; s/\"[^\"]*\"//g"
}

# Insert a newline after every command separator (`;`, `&&`, `||`, `|`, `(` —
# `$(` is covered by the `(` case, since the split point is identical) so
# each resulting line is one command-position segment.
insert_separator_breaks() {
  awk '{
    line = $0
    out = ""
    n = length(line)
    i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      c2 = substr(line, i, 2)
      if (c2 == "&&" || c2 == "||") {
        out = out c2 "\n"
        i += 2
      } else if (c == ";" || c == "|" || c == "(") {
        out = out c "\n"
        i += 1
      } else {
        out = out c
        i += 1
      }
    }
    print out
  }'
}

# Does this ONE segment invoke a gated tool in command position? Strips
# leading whitespace, zero-or-more VAR=value assignments, and an optional
# `bash`/`sh` runner prefix, then tests the basename of the first remaining
# word. Prints the matched "velo-xxx" name and returns 0 on a match, else
# returns 1 with no output.
segment_first_word_tool() {
  local seg="$1" prev word base
  seg="${seg#"${seg%%[![:space:]]*}"}"
  while [[ "$seg" =~ $ENV_ASSIGN_RE ]]; do
    prev="$seg"
    seg="${seg:${#BASH_REMATCH[0]}}"
    [[ "$seg" == "$prev" ]] && break
  done
  if [[ "$seg" =~ $BASH_SH_PREFIX_RE ]]; then
    seg="${seg:${#BASH_REMATCH[0]}}"
  fi
  word="${seg%%[[:space:]]*}"
  base="${word##*/}"
  if [[ "$base" =~ $GATE_TOOL_BASENAME_RE ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  return 1
}

# Runs the full pipeline over $1 and tests every resulting segment. Prints
# the matched "velo-xxx" name and returns 0 on the first match, else returns
# 1 with no output.
detect_gate_tool() {
  local cleaned segment tool
  cleaned=$(strip_heredocs <<<"$1" | strip_quotes | insert_separator_breaks)
  while IFS= read -r segment || [[ -n "$segment" ]]; do
    if tool=$(segment_first_word_tool "$segment"); then
      printf '%s\n' "$tool"
      return 0
    fi
  done <<<"$cleaned"
  return 1
}

TOOL=$(detect_gate_tool "$cmd") || exit 0

# --plan / --dry-run / --help dispatch nothing — nothing to wait for.
if [[ "$cmd" =~ $EXEMPT_RE ]]; then
  exit 0
fi

HAS_WAIT=0
[[ "$cmd" =~ $WAIT_RE ]] && HAS_WAIT=1

# ALLOW only when both halves of the enforcement are present: --wait (so the
# call blocks until the work is done) and run_in_background: true (so that
# block is what wakes the orchestrating session rather than tying up a
# foreground turn for however long the gate/worker/merge takes).
if [[ "$HAS_WAIT" -eq 1 && "$bg" == "true" ]]; then
  exit 0
fi

SUGGESTION="$cmd"
[[ "$HAS_WAIT" -eq 0 ]] && SUGGESTION="$SUGGESTION --wait"

cat >&2 <<EOF
BLOCKED: $TOOL launches detached work (nohup) and must run with --wait AND
run_in_background: true — otherwise a finished gate/worker/merge goes
unnoticed until someone remembers to poll for it. See CLAUDE.md
"Delegating work to a cheap/local worker" / "Gating a PR".

Re-run as a Bash tool call with run_in_background: true and this command:
  $SUGGESTION

(--plan / --dry-run / --help calls are exempt from this.)
EOF
exit 2

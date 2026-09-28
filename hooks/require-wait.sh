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
#
# Does this command invoke one of the three gated entry points? Match the
# basename preceded by start-of-string / whitespace / a path separator / a
# shell metacharacter (so `~/.agents/bin/velo-dispatch ...`, a relative
# `.agents/bin/velo-pr-gate ...`, and a chained `foo && velo-merge ...` all
# match), and followed by whitespace or end-of-string, so an unrelated
# command that merely CONTAINS the substring (e.g. a comment mentioning
# "velo-dispatch-notes.md") does not false-positive.
GATE_CMD_RE='(^|[[:space:];&|(/])velo-(dispatch|pr-gate|merge)([[:space:]]|$)'
EXEMPT_RE='(^|[[:space:]])--(plan|dry-run|help)([[:space:]]|$)'
WAIT_RE='(^|[[:space:]])--wait([[:space:]]|$)'

if [[ ! "$cmd" =~ $GATE_CMD_RE ]]; then
  exit 0
fi
TOOL=$(grep -oE 'velo-(dispatch|pr-gate|merge)' <<<"$cmd" | head -1)

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

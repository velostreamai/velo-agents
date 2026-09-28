#!/bin/bash
# require-wait.sh must allow exactly the shapes CLAUDE.md's "Delegating work" /
# "Gating a PR" bullets now promise (--wait + run_in_background: true), and
# deny every other way to launch velo-dispatch/velo-pr-gate/velo-merge
# detached with nobody watching.
#
# Piped JSON in, exit code (+ stderr) out — this drives the REAL hook script
# under the REAL Claude Code PreToolUse contract (stdin JSON, exit 2 =
# block), not a re-implementation of its regex.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/hooks/require-wait.sh"
FAILED=0

[[ -x "$HOOK" ]] || { echo "  FAIL hook not found or not executable: $HOOK"; exit 1; }

# $1 = label, $2 = command, $3 = run_in_background (true/false/omit -> field
# absent), $4 = wanted exit code.
check() {
  local label="$1" cmd="$2" bg="$3" want="$4" rc out
  if [[ -n "$bg" ]]; then
    out=$(jq -n --arg c "$cmd" --argjson b "$bg" \
      '{tool_name:"Bash", tool_input:{command:$c, run_in_background:$b}}' | "$HOOK" 2>&1)
  else
    out=$(jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' | "$HOOK" 2>&1)
  fi
  rc=$?
  if [[ "$rc" == "$want" ]]; then
    echo "  ok   $label (exit $rc)"
  else
    echo "  FAIL $label: got exit $rc, want $want"
    sed 's/^/        /' <<<"$out"
    FAILED=1
  fi
}

echo "require-wait.sh hook shapes"

# ---- the 5 shapes the brief names explicitly --------------------------------
check "velo-dispatch --wait + background -> ALLOW" \
  "velo-dispatch 2999 brief.md --wait" true 0
check "velo-dispatch missing --wait -> DENY" \
  "velo-dispatch 2999 brief.md" true 2
check "velo-pr-gate --wait but FOREGROUND -> DENY" \
  "velo-pr-gate 2999 scope.md --wait" false 2
check "velo-pr-gate --plan (no --wait, no background) -> ALLOW" \
  "velo-pr-gate 2999 --plan" false 0
check "unrelated command -> ALLOW" \
  "git status" false 0

# ---- edge cases worth pinning alongside the 5 named shapes ------------------
check "velo-merge --dry-run -> ALLOW (exempt, no background needed)" \
  "velo-merge 2999 --dry-run" false 0
check "velo-merge --help -> ALLOW" \
  "velo-merge --help" false 0
check "path-prefixed invocation is still recognised" \
  "~/.agents/bin/velo-pr-gate 2999 scope.md" true 2
check "chained command (&&) is still recognised" \
  "cd /tmp && velo-merge 2999 --force" true 2
check "a command that merely MENTIONS the name is not caught" \
  "cat velo-dispatch-notes.md" true 0
check "background true but --wait missing entirely -> DENY" \
  "velo-dispatch 2999 brief.md --force" true 2
check "both present, --wait not the last token -> ALLOW" \
  "velo-pr-gate 2999 scope.md --wait --exec" true 0

# A malformed payload (no tool_input at all) must degrade to allow, not crash
# the hook and block every unrelated Bash call in the session.
out=$(echo '{}' | "$HOOK" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  echo "  ok   malformed payload (no tool_input) does not crash"
else
  echo "  FAIL malformed payload: exit $rc: $out"; FAILED=1
fi

# The brief requires the denial to give "the exact corrected invocation" —
# pin that it actually appends --wait to the real command, not a generic
# "add --wait somewhere" message a caller has to hand-translate.
out=$(jq -n '{tool_input:{command:"velo-dispatch 2999 brief.md", run_in_background:true}}' | "$HOOK" 2>&1)
if grep -qF -- "velo-dispatch 2999 brief.md --wait" <<<"$out"; then
  echo "  ok   denial names the exact corrected invocation"
else
  echo "  FAIL denial did not include the corrected command:"
  sed 's/^/        /' <<<"$out"
  FAILED=1
fi

echo
[[ $FAILED -eq 0 ]] && echo "all require-wait.sh hook checks passed" || echo "FAILURES"
exit $FAILED

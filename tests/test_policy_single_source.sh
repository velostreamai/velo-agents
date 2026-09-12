#!/usr/bin/env bash
# There must be ONE velo-impl.md, and the native agent must read it (#2086).
#
# It existed twice and the copies drifted:
#
#   ~/.claude/agents/velo-impl.md         33,676 B   Claude-harness agent
#   .agents/rules/velo-impl.md (tracked)  41,030 B   delegated workers, via --policy
#   cmp: differ at char 1
#
# The entire gap was two subsections added after the native copy was last synced,
# one of which is the zg discovery guidance — so the native agent had ZERO zg
# guidance (`grep -c 'zg query'`: 0 native, 6 tracked). An agent dispatched to
# analyse zg usage ran under that stale copy.
#
# The drift was not only stale, it silently decided the scope of #2080: a
# "16.4% inapplicable by construction" figure was computed from the assumption
# that only delegated workers read the tracked file, which was true ONLY because
# of this fork. Measured against the file's declared audiences it is 3%.
#
# The check is STRUCTURAL, not content-based, on purpose. Comparing bytes would
# fail on any branch that legitimately edits the policy (PR #2084 does), which
# would train everyone to ignore it. A symlink cannot drift at all.
set -uo pipefail
NATIVE="$HOME/.claude/agents/velo-impl.md"
RC=0

check()     { if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: $2"; RC=1; fi; }

echo
if [[ ! -e "$NATIVE" && ! -L "$NATIVE" ]]; then
  # Not every machine runs native agents. Absent is fine; a stale COPY is not.
  echo "  SKIP  no native agent policy at $NATIVE (machine does not run native agents)"
  echo
  echo "all policy-single-source checks passed"
  exit 0
fi

if [[ -L "$NATIVE" ]]; then
  TARGET=$(readlink "$NATIVE")
  echo "  symlink -> $TARGET"
  check "native policy points at a tracked velo-impl.md" "$TARGET" ".agents/rules/velo-impl.md"
  if [[ -e "$NATIVE" ]]; then
    echo "  PASS  the symlink resolves"
  else
    echo "  FAIL  the symlink is broken — the native agent has NO policy at all"
    RC=1
  fi
else
  echo "  FAIL  $NATIVE is a regular file, not a symlink to the tracked policy."
  echo "        A second hand-maintained copy is exactly what drifted 7,354 bytes"
  echo "        and left the native agent with no zg guidance. Fix with:"
  echo "          ln -sf <checkout>/.agents/rules/velo-impl.md $NATIVE"
  RC=1
fi

# Whatever the native agent reads must at least be a policy, not a stub or an
# empty file left behind by a failed sync.
if [[ -r "$NATIVE" ]]; then
  SIZE=$(wc -c < "$NATIVE" | tr -d ' ')
  if [[ "$SIZE" -gt 10000 ]]; then
    echo "  PASS  resolved policy is $SIZE bytes"
  else
    echo "  FAIL  resolved policy is only $SIZE bytes — truncated or a stub"
    RC=1
  fi
  if grep -q '^## STOP triggers' "$NATIVE"; then
    echo "  PASS  resolved policy still carries the STOP triggers"
  else
    echo "  FAIL  resolved policy has no STOP triggers section"
    RC=1
  fi
fi

echo
[[ $RC -eq 0 ]] && echo "all policy-single-source checks passed" || echo "FAILED"
exit $RC

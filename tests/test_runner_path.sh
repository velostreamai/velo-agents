#!/usr/bin/env bash
# The wrapper must exec the runner NEXT TO ITSELF (#2079).
#
# It used to exec an absolute installed path, so a worktree copy of .agents/bin
# ran INSTALLED code. Verifying the tool-argument logging in #2074, the first
# live run showed no arguments at all and looked exactly like a feature that did
# not work — it worked; the run was old code. That failure mode sends you
# debugging the wrong file, which is why this is a test and not a comment.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../bin/velo-openrouter-agent"
RC=0
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT

check() {  # name, got, want
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: got '$2', want to contain '$3'"; RC=1; fi
}

# A stand-in wrapper + runner in a throwaway dir: proves resolution is relative
# to the SCRIPT, without launching a real model.
mkdir -p "$FAKE/bin"
sed 's|^SDK_PY=.*|SDK_PY="/bin/echo"|' "$WRAPPER" > "$FAKE/bin/velo-openrouter-agent"
chmod +x "$FAKE/bin/velo-openrouter-agent"
echo "#!/bin/sh" > "$FAKE/bin/velo-openrouter-agent-sdk.py"

OUT=$("$FAKE/bin/velo-openrouter-agent" --probe 2>&1)
check "execs the runner beside the wrapper" "$OUT" "$FAKE/bin/velo-openrouter-agent-sdk.py"
check "announces which runner ran"          "$OUT" "runner="

# VELO_AGENTS_BIN wins, for the deliberate run-the-installed-one case.
mkdir -p "$FAKE/other"
echo "#!/bin/sh" > "$FAKE/other/velo-openrouter-agent-sdk.py"
OUT=$(VELO_AGENTS_BIN="$FAKE/other" "$FAKE/bin/velo-openrouter-agent" --probe 2>&1)
check "VELO_AGENTS_BIN overrides" "$OUT" "$FAKE/other/velo-openrouter-agent-sdk.py"

# A missing runner must fail LOUDLY, not exec something surprising.
rm "$FAKE/bin/velo-openrouter-agent-sdk.py"
OUT=$("$FAKE/bin/velo-openrouter-agent" --probe 2>&1); EXIT=$?
check "missing runner is reported"   "$OUT"  "runner not found"
check "missing runner is non-zero"   "$EXIT" "1"

echo
[[ $RC -eq 0 ]] && echo "all runner-path checks passed" || echo "FAILED"
exit $RC

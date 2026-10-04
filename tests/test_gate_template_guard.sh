#!/usr/bin/env bash
# velo-gate-post must refuse a BRIEF TEMPLATE posing as a report (#2107/#2171),
# and velo-pr-gate must not pass a flag the codex CLI rejects.
#
# PR #2170 round 3: velo-pr-gate passed
# `codex review --dangerously-bypass-approvals-and-sandbox`, which the current
# CLI rejects outright — the flag moved to the top level. The leg died at
# launch, its log held only the unfilled brief, zero findings was relayed as a
# clean review, and velo-gate-post stamped `gate: code-review @ a43c3aabe` for
# a review that never ran.
#
# velo-pr-gate's gate_health_check caught it and nothing downstream consulted
# the verdict. A hand-relayed report bypasses it completely — which is the path
# that most needs the check.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GP="$HERE/../bin/velo-gate-post"
PG="$HERE/../bin/velo-pr-gate"
FAILURES=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES+1)); }

echo "gate template guard"

# --- the flag that killed every code-review leg ----------------------------
if grep -q 'codex review --dangerously-bypass-approvals-and-sandbox' "$PG"; then
  fail "velo-pr-gate still passes the flag codex review rejects"
else
  pass "the rejected flag is gone from the review launch"
fi

# The real fix is not just dropping it. `codex review` is NOT sandboxed by
# default (probed: a bare invocation ran touch in the worktree), so without an
# explicit restriction --exec and non---exec issued the SAME command — the flag
# that grants execution granted nothing, and the branch that withholds it
# withheld nothing.
if grep -q 'codex review -c sandbox_mode=read-only -' "$PG"; then
  pass "the non---exec branch asks for read-only explicitly"
else
  fail "non---exec does not pass sandbox_mode=read-only, so it restricts nothing"
fi

if grep -q 'is sandboxed by default, and that is the right default' "$PG"; then
  fail "the false 'sandboxed by default' claim is still in the header"
else
  pass "the false sandbox claim is retracted"
fi

# --- velo-gate-post refuses an unfilled template ---------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

try_post() {  # $1 = body; echoes combined output, never posts (bad PR number)
  printf '%s\n' "$1" > "$TMP/report.md"
  "$GP" 999999999 code-review "$TMP/report.md" --sha deadbeef 2>&1 || true
}

for marker in '<<< FILL THIS IN — the specific things worth it. >>>' \
              '<!-- velo-gate-brief scope=x range=y -->' \
              '**Verdict:** approve | approve-with-findings | blocked'; do
  OUT=$(try_post "Some preamble.
$marker
More text.")
  if grep -q 'BRIEF TEMPLATE, not a report' <<<"$OUT"; then
    pass "refuses a report containing: ${marker:0:38}"
  else
    fail "ACCEPTED a report containing: ${marker:0:38}"
  fi
done

# --- and a CLI that never started ------------------------------------------
OUT=$(try_post "error: unexpected argument '--dangerously-bypass-approvals-and-sandbox' found
Usage: codex review [OPTIONS] [PROMPT]")
if grep -q 'CLI usage/error line' <<<"$OUT"; then
  pass "refuses a log that is a CLI usage error"
else
  fail "ACCEPTED a CLI usage error as a gate report"
fi

# --- a REAL report must still get through ----------------------------------
# The guard is worthless if it also blocks the thing it is meant to let past.
OUT=$(try_post "## Findings

P1 — coordinator/mod.rs:412 drops the null-pad envelope on the retry path.

**Verdict:** blocked")
if grep -q 'BRIEF TEMPLATE\|CLI usage/error' <<<"$OUT"; then
  fail "a real report was refused as a template"
else
  pass "a real report is not refused (it fails later, on the fake PR)"
fi

# A filled verdict line must not trip the template matcher: the template is the
# literal alternation, a real one names ONE verdict.
OUT=$(try_post "**Verdict:** approve-with-findings")
if grep -q 'BRIEF TEMPLATE' <<<"$OUT"; then
  fail "a filled-in verdict line was mistaken for the template"
else
  pass "a filled verdict line passes the template check"
fi

echo
if [[ $FAILURES -eq 0 ]]; then echo "all gate-template-guard checks passed"; else echo "FAILED: $FAILURES check(s)"; fi
exit $((FAILURES > 0))

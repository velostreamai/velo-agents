#!/bin/bash
# Two #2285 Round 2 changes to velo-merge, both exercised against the REAL
# script under a stubbed `gh` (same reason test_merge_gates.sh does it this
# way):
#
#   1. An .agents/-only PR (CODE>0 via the bin|rules|skills|tasks sum, so
#      gating still applies) with NO CI checks at all — the ci.yml
#      paths-ignore shape, not a broken build — now merges with a warn
#      instead of a die. Any OTHER code PR with no CI still dies.
#   2. The merge-once guard: two callers that can legitimately race (a
#      session's own --wait loop and velo-orchestrd's step_merge) must never
#      both call `gh pr merge` for the same (pr, head-sha).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
MERGE="$BIN/velo-merge"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$MERGE" ]] || { fail "velo-merge not found at $MERGE"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
CALLS_LOG="$TMPD/calls.log"
HEADSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# `gh` stub: PR_JSON (env) is the full `pr view` payload; `pr merge` records
# a call and succeeds unless GH_MERGE_RC is set nonzero.
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$CALLS_LOG"
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "$PR_JSON"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  exit "${GH_MERGE_RC:-0}"
fi
echo ""; exit 0
EOF
chmod +x "$TMPD/bin/gh"
export PATH="$TMPD/bin:$PATH"
export CALLS_LOG

VELO_STATE="$TMPD/state"
export VELO_STATE

# `grep -c` exits 1 (not 0) when the count is legitimately zero — its count
# convention is "print N", its EXIT convention is "were there matches at
# all". A `|| echo 0` fallback on that exit status would then print a SECOND
# "0" on top of the first, corrupting the very count it exists to normalize
# for the empty case. Not chaining on the exit status is the fix: the file
# always exists by the time this runs (created by `: > "$CALLS_LOG"` before
# every case below), so there is nothing left for a fallback to catch.
pr_merge_calls() { grep -c '^pr merge' "$CALLS_LOG"; }

mk_pr_json() {   # files_json labels_json mergeable ci_json
  jq -cn --arg head "$HEADSHA" --argjson files "$1" --argjson labels "$2" \
     --arg mergeable "$3" --argjson ci "$4" '
    { headRefOid: $head, state: "OPEN", title: "t",
      mergeable: $mergeable, files: $files, labels: $labels,
      statusCheckRollup: $ci }'
}

# ---- 1: an .agents/-only PR with NO CI merges (warn, not die) -------------
# CODE>0 needs bin/ (or rules|skills|tasks) in the diff, not just any
# .agents/ path — a hooks-only or docs-only PR already hits the PRE-EXISTING
# "CODE -eq 0" branch and proves nothing new. --force sidesteps this test's
# ONE unrelated dependency: the gate-name cross-check further down shells out
# to the REAL ~/.agents/bin/velo-gate (a hardcoded path, not overridable),
# which this sandboxed run has no business invoking. The CI-none/AGENTS_ONLY
# branch under test runs BEFORE that section and does not itself consult
# FORCE, so --force does not weaken what is actually being asserted here.
FILES1='["path"]'  # placeholder, replaced below via --argjson
PR_JSON=$(mk_pr_json '[{"path":".agents/bin/velo-example"}]' '["gate:passed"]' MERGEABLE '[]')
export PR_JSON
: > "$CALLS_LOG"
OUT1=$("$MERGE" 601 --force 2>&1); RC1=$?
if [[ $RC1 -eq 0 ]]; then
  ok ".agents/-only PR with no CI merges under --force"
else
  fail ".agents/-only PR with no CI was refused: rc=$RC1 $(tr '\n' ' ' <<<"$OUT1" | cut -c1-300)"
fi
if grep -qi 'expected for an .agents/-only PR' <<<"$OUT1"; then
  ok "the acceptance is a stated warn, not a silent pass"
else
  fail "no .agents/-only warn message found: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "1" ]]; then
  ok "gh pr merge was actually called for the accepted .agents/-only PR"
else
  fail "expected 1 pr-merge call, got $(pr_merge_calls)"
fi

# ---- 2: a NON-.agents/ code PR with no CI still dies -----------------------
PR_JSON=$(mk_pr_json '[{"path":"src/foo.rs"}]' '["gate:passed"]' MERGEABLE '[]')
export PR_JSON
: > "$CALLS_LOG"
OUT2=$("$MERGE" 602 --force 2>&1); RC2=$?
if [[ $RC2 -ne 0 ]]; then
  ok "a src/ PR with no CI still refuses — the exception is scoped to .agents/-only"
else
  fail "a src/ PR with no CI was allowed through: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "0" ]]; then
  ok "no merge attempted for the refused src/ PR"
else
  fail "a merge was attempted despite the refusal"
fi

# ---- 3: the merge-once guard — a sequential repeat is a silent no-op ------
PR_JSON=$(mk_pr_json '[{"path":"docs/x.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
OUT3=$("$MERGE" 603 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "first merge of a docs PR exits 0" || fail "first merge exited $RC3: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-300)"
OUT4=$("$MERGE" 603 2>&1); RC4=$?
[[ $RC4 -eq 0 ]] && ok "repeat merge call also exits 0" || fail "repeat merge exited $RC4: $(tr '\n' ' ' <<<"$OUT4" | cut -c1-300)"
if grep -qi 'already merged' <<<"$OUT4"; then
  ok "repeat merge reports it is skipping, not silent"
else
  fail "repeat merge gave no idempotency message: $(tr '\n' ' ' <<<"$OUT4" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "1" ]]; then
  ok "exactly one 'gh pr merge' call across both invocations — no double-merge"
else
  fail "expected exactly 1 pr-merge call across both calls, got $(pr_merge_calls)"
fi

# ---- 4: MUTATION-PROOF — the merge-once done-marker check ------------------
BACKUP="$TMPD/velo-merge.backup"
cp "$MERGE" "$BACKUP"
python3 - "$MERGE" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$MERGE_DONE" ]]; then\n  ok "already merged @ $SHORT ($(cat "$MERGE_DONE" 2>/dev/null)) — skipping (idempotent)"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert old in t, "merge-once done-marker check not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
PR_JSON=$(mk_pr_json '[{"path":"docs/y.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
"$MERGE" 604 >/dev/null 2>&1
"$MERGE" 604 >/dev/null 2>&1
MUT_CALLS=$(pr_merge_calls)
cp "$BACKUP" "$MERGE"
if diff -q "$BACKUP" "$MERGE" >/dev/null; then
  ok "velo-merge restored byte-identical after the mutation"
else
  fail "velo-merge did NOT restore cleanly — check $MERGE by hand"
fi
if [[ "$MUT_CALLS" -ge 2 ]]; then
  ok "MUTATION-PROOF red: with the done-marker check disabled, the same head merges twice ($MUT_CALLS calls)"
else
  fail "mutation-proof did not go RED: expected >=2 pr-merge calls with the guard disabled, got $MUT_CALLS"
fi
PR_JSON=$(mk_pr_json '[{"path":"docs/z.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
"$MERGE" 605 >/dev/null 2>&1
"$MERGE" 605 >/dev/null 2>&1
RESTORED_CALLS=$(pr_merge_calls)
if [[ "$RESTORED_CALLS" == "1" ]]; then
  ok "MUTATION-PROOF green: restored file merges exactly once again"
else
  fail "restored file still double-merges: $RESTORED_CALLS calls — restore did not take"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all merge once-only / .agents-only-CI checks passed" || echo "FAILURES"
exit $FAILED

#!/bin/bash
# velo-spec-review may substitute a reviewer, but never silently (#2151).
#
# The script required `codex` and died without it. Right in spirit — on #1988 a
# local model approved a diff carrying two P1s and asserted the opposite of one
# — but it left no legitimate path when codex is merely UNAVAILABLE, so the
# operator substitutes anyway, off the record. That happened on 2026-09-13:
# Codex hit its usage limit mid-run on #2123, returned no report, and the review
# was re-run on Sonnet through an Agent call — outside the gate trail entirely.
#
# The #1988 rule is about model CAPABILITY, not about the string "codex". So a
# frontier substitute is allowed and announces itself; anything weaker is
# refused outright.
#
# Only the REFUSAL paths are exercised here. The accept path would launch a real
# review — minutes and real money — and what matters for this guard is which
# invocations are turned away and what they say.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
ROOT="$(cd "$HERE/../.." && pwd)"
SR="$BIN/velo-spec-review"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "velo-spec-review reviewer substitution"

[[ -x "$SR" ]] || { fail "velo-spec-review not found at $SR"; exit 1; }

# An issue whose spec exists in the CANONICAL repo. `--worktree` cannot be used
# to supply a fixture: the unguarded check at velo-spec-review:67 reads
# $HOME/RustroverProjects/velostream before --worktree is applied at :80, so a
# spec that exists only in a temp tree is rejected before the override runs.
# That ordering bug is pre-existing (#2118) and filed separately; this test
# works within it rather than around it.
ISSUE=$(ls "$ROOT/.agents/tasks"/*.json 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.json$//')
if [[ -z "$ISSUE" ]]; then
  echo "  SKIP  no task spec in $ROOT/.agents/tasks — nothing to review against"
  echo "        (this suite needs one real spec; it asserts on refusals, not content)"
  exit 0
fi
ok "using existing spec for issue $ISSUE as the fixture"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

# A PATH with the system utilities but NEITHER reviewer CLI. Both refusals are
# about a missing binary, so the fixture has to actually be missing it — and
# inheriting $PATH would make the real codex/claude reachable and test the
# opposite branch.
BARE="$TMPD/bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_sr() {  # <args...> -> OUT, RC
  OUT=$(PATH="$BARE" "$SR" "$ISSUE" --check "$@" 2>&1); RC=$?
}

# ── an unknown worker is refused outright ──────────────────────────────────
# The allowed set is closed. "Anything weaker is refused" only means something
# if the script cannot be handed an arbitrary name.
run_sr --worker definitely-not-a-model
if [[ $RC -ne 0 ]] && grep -qi "unknown --worker" <<<"$OUT"; then
  ok "an unknown --worker is refused by name"
else
  fail "unknown worker was not refused: rc=$RC $(head -1 <<<"$OUT")"
fi
if grep -q '1988' <<<"$OUT"; then
  ok "the refusal cites #1988, so the rule is traceable"
else
  fail "refusal does not say why weaker models are barred"
fi

# ── codex missing: refuse, and NAME the legitimate alternative ─────────────
# This is the case that produced the off-the-record substitution. Refusing
# without naming the remedy is what sends an operator outside the tooling.
run_sr
if [[ $RC -ne 0 ]] && grep -qi "codex CLI not on PATH" <<<"$OUT"; then
  ok "codex absent is refused rather than silently substituted"
else
  fail "codex absent did not refuse: rc=$RC $(head -1 <<<"$OUT")"
fi
if grep -q -- '--worker opus' <<<"$OUT"; then
  ok "the refusal names --worker opus as the declared alternative"
else
  fail "refusal offers no legitimate path — this is what caused the #2123 workaround"
fi

# ── opus requested but claude missing: refuse too ──────────────────────────
# The substitute must be verified present, not assumed. Otherwise --worker opus
# becomes a way to get PAST the codex check and fail later, further in.
run_sr --worker opus
if [[ $RC -ne 0 ]] && grep -qi "claude CLI not on PATH" <<<"$OUT"; then
  ok "--worker opus with claude absent is refused"
else
  fail "--worker opus did not verify its own CLI: rc=$RC $(head -1 <<<"$OUT")"
fi

# ── --worktree must reach a spec that exists ONLY on the branch ────────────
# The whole point of --worktree is reviewing a spec that is not on master yet.
# The existence check used to run against the hardcoded canonical ROOT BEFORE
# --worktree was applied, so a branch-only spec was rejected with "no task spec:
# <canonical path>" — usable only for specs already on master, the precise
# opposite of its purpose. Nothing caught it because every hand-run had the spec
# in both trees.
WT="$TMPD/branch-only"; mkdir -p "$WT/.agents/tasks"
printf '{"issue":999777}\n' > "$WT/.agents/tasks/999777.json"
OUT=$(PATH="$BARE" "$SR" 999777 --check --worktree "$WT" 2>&1); RC=$?
# It must get PAST the spec lookup. With no reviewer CLI on PATH the next stop is
# the codex refusal — reaching that proves the spec was found.
if grep -qi "codex CLI not on PATH" <<<"$OUT"; then
  ok "a branch-only spec is found via --worktree"
elif grep -qi "no task spec" <<<"$OUT"; then
  fail "branch-only spec rejected — the canonical-ROOT check runs first again"
else
  fail "unexpected outcome for a branch-only spec: rc=$RC $(head -1 <<<"$OUT")"
fi

# A genuinely absent spec must still refuse — and name the tree it searched,
# because reporting the canonical path sends the reader to the wrong file.
OUT=$(PATH="$BARE" "$SR" 999778 --check --worktree "$WT" 2>&1); RC=$?
if [[ $RC -ne 0 ]] && grep -q "no task spec in that worktree" <<<"$OUT"; then
  ok "a missing spec still refuses, naming the worktree it searched"
else
  fail "missing spec not reported against the worktree: $(head -1 <<<"$OUT")"
fi

# ── the substitute must be loud where the verdict is read ──────────────────
# Source-level, because reaching the announcement requires launching a real
# review. The point of the change is that a substitution is visible in stdout,
# the round log and the ledger — if the announcement is deleted, the feature is
# gone even though the flag still works.
if grep -q 'SUBSTITUTE' "$SR"; then
  ok "a substitute run announces itself"
else
  fail "no SUBSTITUTE announcement — a substituted verdict would read as codex's"
fi
if grep -qi 'evidence, not proof' "$SR"; then
  ok "a CLEAN from a substitute is recorded as evidence, not proof"
else
  fail "substitute results are not qualified against the codex-calibrated bar"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all spec-review substitution checks passed" || echo "FAILURES"
exit $FAILED

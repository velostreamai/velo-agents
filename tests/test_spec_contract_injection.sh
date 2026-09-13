#!/bin/bash
# The worker must RECEIVE the sidecar contract, not just the brief.
#
# `velo-dispatch` built the worker's task as `cat <brief>` plus an index note, so
# anything in `.agents/tasks/<issue>.json` and not ALSO typed into the brief never
# reached the worker. `SCHEMA.md` claimed otherwise — "acceptance, forbidden,
# tests ... are written into the generated brief, so nothing is hand-transcribed"
# — which made the spec look safer than it was.
#
# The gap bites at MERGE, because `tests.fail_to_pass` is checked there. On #1918
# five of six required test names lived only in the sidecar: a worker could satisfy
# every word of its visible brief and still fail the gate on names it had never
# been shown. The previous attempt did exactly that, writing all three of its tests
# under names of its own choosing.
#
# The block is EXTRACTED from velo-dispatch between markers and evaluated here,
# not re-implemented — a copy keeps passing after the real code is deleted, which
# is the failure mode test_fail_to_pass.sh documents.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH="$ROOT/.agents/bin/velo-dispatch"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -f "$DISPATCH" ]] || { echo "velo-dispatch not found: $DISPATCH"; exit 1; }

# ---- the block must still be THERE -----------------------------------------
if grep -q '^CONTRACT=\$(SPEC_FILE=' "$DISPATCH"; then
  ok "velo-dispatch still builds a CONTRACT block"
else
  fail "CONTRACT block is GONE from velo-dispatch — the worker is back to brief-only"
  exit 1
fi

if grep -q '\$CONTRACT' "$DISPATCH"; then
  ok "CONTRACT is interpolated into the worker task"
else
  fail "CONTRACT is built but never used — rendered and thrown away"
fi

# ---- and it must still RENDER ----------------------------------------------
# A synthetic sidecar, so the test does not rot when #1918's spec is pruned and
# does not silently pass because some real spec happens to be well-formed.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/spec.json" <<'JSON'
{
  "issue": 424242,
  "tests": {
    "fail_to_pass": ["zz_must_fail_first_alpha", "zz_must_fail_first_beta"],
    "pass_to_stay": ["zz_stays_green"],
    "known_red": []
  },
  "acceptance": ["zz bar one holds", "zz bar two holds"],
  "forbidden": ["zz do not do the forbidden thing"],
  "stop_conditions": ["zz stop when the sky falls"]
}
JSON

HARNESS="$TMP/harness.sh"
{
  echo '#!/bin/bash'
  echo 'set -uo pipefail'
  echo 'die() { echo "DIE: $1" >&2; exit 1; }'
  echo 'SPEC="$1"'
  sed -n '/^CONTRACT=\$(SPEC_FILE=/,/^) || die/p' "$DISPATCH"
  echo 'printf "%s\n" "$CONTRACT"'
} > "$HARNESS"

OUT=$(bash "$HARNESS" "$TMP/spec.json" 2>&1) || { fail "harness failed: $OUT"; exit 1; }

for want in zz_must_fail_first_alpha zz_must_fail_first_beta zz_stays_green \
            "zz bar one holds" "zz bar two holds" "zz do not do the forbidden thing" \
            "zz stop when the sky falls"; do
  if grep -qF "$want" <<<"$OUT"; then
    ok "contract carries: $want"
  else
    fail "contract MISSING: $want"
  fi
done

# fail_to_pass is the one checked at merge, so it gets the use-these-names-exactly
# warning. Without it a worker reads the list as a suggestion, which is how the
# #1918 rename happened.
if grep -qF "EXACTLY" <<<"$OUT"; then
  ok "fail_to_pass block warns the names are matched literally"
else
  fail "no EXACTLY warning — the names read as suggestions"
fi

# An empty list must not emit an empty heading.
if grep -qF "Known-red" <<<"$OUT"; then
  fail "empty known_red emitted a heading with nothing under it"
else
  ok "empty list emits no heading"
fi

# The contract must assert its own precedence: the merge gate reads the sidecar,
# so where brief prose and sidecar disagree the sidecar governs. Without this a
# worker resolves a conflict by picking whichever it read first.
if grep -qF "governs" <<<"$OUT"; then
  ok "contract states it governs over brief prose"
else
  fail "contract does not state precedence over the brief"
fi

# ---- SCHEMA.md must not re-assert the false claim --------------------------
if grep -q "written into the generated brief, so nothing is hand-transcribed" "$ROOT/.agents/tasks/SCHEMA.md"; then
  fail "SCHEMA.md still claims injection happens 'into the generated brief' — the wording that was untrue"
else
  ok "SCHEMA.md describes the real mechanism"
fi

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $FAILED

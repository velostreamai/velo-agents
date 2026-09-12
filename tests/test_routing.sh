#!/usr/bin/env bash
# Routing reads both the label and the spec; the label OVERRIDES (#2085).
#
# Routing came from the GitHub label alone while SCHEMA.md documented a `worker:`
# spec field as "-> routing", so a spec proposing one worker while the label said
# another produced no signal at all.
#
# The label OVERRIDES the spec — they are not rival sources of truth. #2000 (spec
# glm, label deepseek, deepseek ran) was that override working. The fix is simply
# to SAY an override was applied. Two earlier cuts of this change did more than
# that: one made disagreement fatal (breaking re-routing by label), the other let
# a spec route with no label (weakening the exactly-one-label rule). Both are
# pinned against here.
#
# velo-dispatch had no routing coverage at all, which is how a documented field
# stayed inert long enough to drift. These drive the REAL routing block extracted
# from the shipped script, so the logic under test is the logic that runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/../bin/velo-dispatch"
RC=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/.agents/tasks"

check()     { if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-150)"; RC=1; fi; }
check_not() { if [[ "$2" != *"$3"* ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: did NOT want '$3': $(tr '\n' ' ' <<<"$2" | cut -c1-150)"; RC=1; fi; }

# Extract the shipped routing block and drive it with stubbed inputs.
python3 - "$DISPATCH" "$TMPD/route.sh" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index("# ---- 3. routing:")
end = src.index('ok "routed to $NAME')
end = src.index("\n", end) + 1
pathlib.Path(sys.argv[2]).write_text(
    '#!/usr/bin/env bash\n'
    'die() { echo "DIE: $*"; exit 1; }\n'
    'ok()  { echo "OK: $*"; }\n'
    'warn() { echo "WARN: $*"; }\n'
    + src[start:end])
print("  extracted the real routing block from velo-dispatch")
PYEOF

run() {  # $1 = labels csv, $2 = spec worker ("" = no spec file)
  rm -f "$TMPD/.agents/tasks/9999.json"
  [[ -n "$2" ]] && printf '{"worker": "%s", "design": "pinned"}\n' "$2" > "$TMPD/.agents/tasks/9999.json"
  LABELS="$1" ISSUE=9999 ROOT="$TMPD" bash "$TMPD/route.sh" 2>&1
}

echo
echo "the label OVERRIDES the spec — it does not conflict with it"
# The spec's `worker` is the proposal written before dispatch; the label is the
# operator's live control. #2000 (spec glm, label deepseek, deepseek ran) was the
# override working, not a defect. An earlier cut of this change made disagreement
# FATAL, which would have broken re-routing by label — the override is the point.
OUT=$(run "worker:deepseek,bug" "glm")
check     "label wins"                  "$OUT" "OK: routed to velo-deepseek"
check     "the override is announced"   "$OUT" "overrides spec proposal 'glm'"
check_not "does not refuse"             "$OUT" "DIE:"

echo
echo "agreement routes"
OUT=$(run "worker:glm" "glm");       check "label+spec agree"   "$OUT" "OK: routed to velo-glm"
OUT=$(run "worker:codex" "codex");   check "codex routes"       "$OUT" "OK: routed to codex"

echo
echo "the label is still required"
OUT=$(run "worker:deepseek" "")
check "label only (the old behaviour)"     "$OUT" "OK: routed to velo-deepseek"
OUT=$(run "" "codex")
check "spec alone does NOT route — the label stays required" "$OUT" "no 'worker:*' label"

echo
echo "neither, and unroutable values"
OUT=$(run "bug,tooling" "")
check     "no label at all is refused"     "$OUT" "no 'worker:*' label"
OUT=$(run "worker:opus" "")
check     "an unrouted label fails loudly" "$OUT" "unroutable worker 'opus'"

echo
echo "degenerate specs must not crash routing"
# A spec that is unreadable or malformed must fall back to the label, not abort:
# routing is too important to lose to a stray comma in an unrelated field.
printf '{ this is not json' > "$TMPD/.agents/tasks/9999.json"
OUT=$(LABELS="worker:glm" ISSUE=9999 ROOT="$TMPD" bash "$TMPD/route.sh" 2>&1)
check "malformed spec falls back to label" "$OUT" "OK: routed to velo-glm"
printf '{"design": "pinned"}' > "$TMPD/.agents/tasks/9999.json"
OUT=$(LABELS="worker:glm" ISSUE=9999 ROOT="$TMPD" bash "$TMPD/route.sh" 2>&1)
check "spec without a worker key is fine"  "$OUT" "OK: routed to velo-glm"

echo
echo "two labels are still refused"
OUT=$(run "worker:glm,worker:codex" "")
check "two worker labels rejected" "$OUT" "at most one"

echo
[[ $RC -eq 0 ]] && echo "all routing checks passed" || echo "FAILED"
exit $RC

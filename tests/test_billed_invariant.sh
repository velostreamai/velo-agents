#!/usr/bin/env bash
# A priced source must be backed by a figure that was actually REPORTED (#2107).
#
# #2107's second checkbox: "`openrouter-billed` with `usd: null` should be
# impossible to write, not merely unlikely." It was fixed only on the happy
# path. `COST=$(kv cost_usd "$TOTALS")` yields "" when the line carries no
# cost, and the python `f()` coerces "" to 0.0 — so a TOTALS claiming
# openrouter-billed with no figure wrote `usd: 0.0` under a billed label.
#
# That is the same lie as `usd: null` wearing one, in the shape that survives a
# null check: a run that cost money recorded as free, averaging into every
# cost-per-worker figure as a real zero.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$HERE/../bin/velo-record"
FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES+1)); }

echo "billed provenance invariant"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
WT="$TMP/wt"; mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
git -C "$WT" commit -q --allow-empty -m init 2>/dev/null

run_case() {  # $1=totals line -> prints the cost block
  printf '%s\n' "2026-01-01T00:00:00.000Z [prompt 1] sdk result status=success turns=3 text_len=10" \
                "2026-01-01T00:00:00.000Z $1" > "$TMP/run.log"
  rm -rf "$TMP/rec"; mkdir -p "$TMP/rec"
  VELO_RECORD_ROOT="$TMP/rec" "$REC" 4242 --worktree "$WT" --worker velo-deepseek \
    --model m --log "$TMP/run.log" --started 2026-01-01T00:00:00Z --rc 0 --max-turns 5 \
    >/dev/null 2>&1
  python3 -c "
import json,pathlib,sys
p=pathlib.Path('$TMP/rec/records/4242.result.jsonl')
if not p.exists(): print('{}'); sys.exit()
print(json.dumps(json.loads(p.read_text().strip().splitlines()[-1]).get('cost',{})))
"
}

# 1. A reported figure is kept, under billed provenance.
OUT=$(run_case "TOTALS prompts=1 leaked_tool_calls=0 input_tokens=10 output_tokens=5 cached_tokens=0 cost_usd=0.012345 usage_source=openrouter-billed read_only=false")
if grep -q '"usd": 0.012345' <<<"$OUT" && grep -q '"source": "openrouter-billed"' <<<"$OUT"; then
  pass "a reported cost is recorded under billed provenance"
else
  fail "a reported cost was lost or mislabelled: $OUT"
fi

# 2. THE INVARIANT. Billed claimed, no figure reported.
OUT=$(run_case "TOTALS prompts=1 leaked_tool_calls=0 input_tokens=10 output_tokens=5 cached_tokens=0 usage_source=openrouter-billed read_only=false")
if grep -q '"source": "openrouter-billed"[,}]' <<<"$OUT" && ! grep -q 'unreported' <<<"$OUT"; then
  fail "billed provenance asserted with no reported cost: $OUT"
else
  pass "billed with no reported cost is demoted, not asserted"
fi
# And it must not invent a zero — free is a claim, not a default.
if grep -q '"usd": 0.0\?[,}]' <<<"$OUT"; then
  fail "a missing cost was recorded as \$0.00, which reads as a free run: $OUT"
else
  pass "a missing cost stays null rather than becoming \$0.00"
fi

# 3. The backfill tool exists and is dry-run by default — a repair that runs
#    without being asked is how an audit trail gets rewritten silently.
BF="$HERE/../bin/velo-record-backfill"
if [[ -x "$BF" ]]; then
  pass "velo-record-backfill is present and executable"
else
  fail "velo-record-backfill missing"
fi
if grep -q 'APPLY = "--apply" in sys.argv' "$BF"; then
  pass "the backfill is a dry run unless --apply is passed"
else
  fail "the backfill writes without an explicit --apply"
fi
if grep -q 'bak-{stamp}' "$BF"; then
  pass "backups are timestamped, not a bare .bak"
else
  fail "the backfill does not take a timestamped backup"
fi
if grep -q '"backfilled"' "$BF"; then
  pass "an edited row is marked, not silently rewritten"
else
  fail "rows are rewritten with no marker"
fi

echo
if [[ $FAILURES -eq 0 ]]; then echo "all billed-invariant checks passed"; else echo "FAILED: $FAILURES check(s)"; fi
exit $((FAILURES > 0))

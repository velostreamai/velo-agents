#!/usr/bin/env bash
# velo-attention: list must show only UNACKED events, and ack must be
# idempotent and never resurrect an acked id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
ATTN="$BIN/velo-attention"
RC=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; RC=1; }

[[ -x "$ATTN" ]] || { fail "velo-attention not found at $ATTN"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export VELO_STATE="$T/state"; mkdir -p "$VELO_STATE/orch"

# shellcheck source=../bin/velo-orch-lib.sh
source "$BIN/velo-orch-lib.sh"

"$ATTN" list >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "list on an empty state dir does not error" || fail "list errored on empty state"

attention_append "gate-blocked:9:aaa" "gate-blocked" "9" "" "aaa" "finding X" >/dev/null
attention_append "worker-finished:12:2026-01-01T00:00:00Z" "worker-finished" "" "12" "2026-01-01T00:00:00Z" "outcome=failed" >/dev/null

OUT=$("$ATTN" list)
if grep -q "gate-blocked:9:aaa" <<<"$OUT" && grep -q "worker-finished:12:2026-01-01T00:00:00Z" <<<"$OUT"; then
  ok "list shows both unacked events"
else
  fail "list is missing an event: $OUT"
fi
if grep -q "2 unhandled" <<<"$OUT"; then
  ok "list reports the correct unhandled count"
else
  fail "wrong unhandled count: $(head -1 <<<"$OUT")"
fi

"$ATTN" ack "gate-blocked:9:aaa" >/dev/null
OUT=$("$ATTN" list)
if ! grep -q "gate-blocked:9:aaa" <<<"$OUT" && grep -q "worker-finished:12:2026-01-01T00:00:00Z" <<<"$OUT"; then
  ok "acking one event removes only that one from the unhandled list"
else
  fail "ack did not correctly narrow the list: $OUT"
fi

attention_append "gate-blocked:9:aaa" "gate-blocked" "9" "" "aaa" "duplicate append attempt" >/dev/null
N=$(grep -c '"id":"gate-blocked:9:aaa"' "$VELO_STATE/orch/attention.jsonl")
if [[ "$N" -eq 1 ]]; then
  ok "re-appending the same id is a no-op — never written twice"
else
  fail "the same id was written $N times"
fi

"$ATTN" ack --all >/dev/null
OUT=$("$ATTN" list)
if grep -q "no unhandled" <<<"$OUT"; then
  ok "ack --all clears every remaining unhandled event"
else
  fail "ack --all left something unhandled: $OUT"
fi

# An acked id must never come back just because the daemon recomputes the
# same fact again (idempotent escalation) — acking is a durable ledger, not a
# transient dismissal.
attention_append "worker-finished:12:2026-01-01T00:00:00Z" "worker-finished" "" "12" "2026-01-01T00:00:00Z" "recomputed, same id" >/dev/null
OUT=$("$ATTN" list)
if grep -q "no unhandled" <<<"$OUT"; then
  ok "an acked id stays acked even if the daemon recomputes the same fact"
else
  fail "an acked event resurfaced: $OUT"
fi

echo
[[ $RC -eq 0 ]] && echo "all velo-attention checks passed" || echo "FAILURES"
exit $RC

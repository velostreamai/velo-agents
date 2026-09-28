#!/bin/bash
# session-start-inflight.sh's new section (#2285 Round 2): list unhandled
# orchestrator attention events and, when any exist, recommend
# `velo-watch --attention` alongside the existing plain velo-watch line.
#
# Drives the REAL hook script directly (its own directory-relative sourcing
# of ../bin/velo-orch-lib.sh only resolves correctly run from its real path),
# against a sandboxed VELO_STATE and a stub `gh` that returns nothing for the
# gate:running PR scan — this test is scoped to the attention section, not
# the pre-existing process/PR scans, which have no test coverage of their own
# yet and are out of scope here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/hooks/session-start-inflight.sh"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -f "$HOOK" ]] || { fail "session-start-inflight.sh not found at $HOOK"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
[[ "$1" == "pr" && "$2" == "list" ]] && { echo "[]"; exit 0; }
echo ""; exit 0
EOF
chmod +x "$TMPD/bin/gh"
export PATH="$TMPD/bin:$PATH"

VELO_STATE="$TMPD/state"
export VELO_STATE
ORCH_DIR="$VELO_STATE/orch"
mkdir -p "$ORCH_DIR"

# ---- 1: no attention events -> no attention section, no --attention line -
: > "$ORCH_DIR/attention.jsonl"
OUT1=$(bash "$HOOK" 2>&1)
if ! grep -qi 'unhandled orchestrator attention' <<<"$OUT1"; then
  ok "no attention section when nothing is unacked"
else
  fail "printed an attention section with nothing unacked: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-200)"
fi
if ! grep -qF 'velo-watch --attention' <<<"$OUT1"; then
  ok "no --attention recommendation when nothing is unacked"
else
  fail "recommended --attention with nothing unacked"
fi

# ---- 2: one unacked event -> printed, plus the --attention recommendation
jq -cn '{id:"gate-blocked:801:abc1234", kind:"gate-blocked", pr:801, issue:null, sha:"abc1234", evidence:"code-review returned blocked, needs a fix brief"}' \
  > "$ORCH_DIR/attention.jsonl"
rm -f "$ORCH_DIR/acked-ids"
OUT2=$(bash "$HOOK" 2>&1)
if grep -qi 'unhandled orchestrator attention' <<<"$OUT2"; then
  ok "prints the attention section when an event is unacked"
else
  fail "no attention section despite an unacked event: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi
if grep -qF 'gate-blocked' <<<"$OUT2" && grep -qF '801' <<<"$OUT2"; then
  ok "the event's kind and PR number are both printed"
else
  fail "event details missing from output: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi
if grep -qF 'velo-watch --attention' <<<"$OUT2"; then
  ok "recommends velo-watch --attention when an event is unacked"
else
  fail "did not recommend --attention despite an unacked event: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi
if grep -qF 'velo-attention ack' <<<"$OUT2"; then
  ok "tells the operator how to ack it"
else
  fail "gave no ack instruction: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi

# ---- 3: the SAME event, now acked -> section and recommendation both gone
printf 'gate-blocked:801:abc1234\n' > "$ORCH_DIR/acked-ids"
OUT3=$(bash "$HOOK" 2>&1)
if ! grep -qi 'unhandled orchestrator attention' <<<"$OUT3"; then
  ok "an acked event no longer produces an attention section"
else
  fail "an ACKED event still printed as unhandled: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-300)"
fi
if ! grep -qF 'velo-watch --attention' <<<"$OUT3"; then
  ok "no --attention recommendation once the event is acked"
else
  fail "still recommended --attention after acking the only event"
fi

# ---- 4: MUTATION-PROOF — the attention_unhandled read is what surfaces this
rm -f "$ORCH_DIR/acked-ids"
BACKUP="$TMPD/hook.backup"
cp "$HOOK" "$BACKUP"
python3 - "$HOOK" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'ATTENTION_RAW=$(attention_unhandled 2>/dev/null || true)\n'
new = 'ATTENTION_RAW=""\n'
assert old in t, "the attention_unhandled read not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
OUT4=$(bash "$HOOK" 2>&1)
cp "$BACKUP" "$HOOK"
if diff -q "$BACKUP" "$HOOK" >/dev/null; then
  ok "session-start-inflight.sh restored byte-identical after the mutation"
else
  fail "session-start-inflight.sh did NOT restore cleanly — check $HOOK by hand"
fi
if ! grep -qF 'velo-watch --attention' <<<"$OUT4"; then
  ok "MUTATION-PROOF red: with the attention_unhandled read blanked out, a genuinely unacked event goes unmentioned"
else
  fail "mutation-proof did not go RED: still recommended --attention with the read disabled"
fi
OUT5=$(bash "$HOOK" 2>&1)
if grep -qF 'velo-watch --attention' <<<"$OUT5"; then
  ok "MUTATION-PROOF green: restored file surfaces the same unacked event again"
else
  fail "restored file still misses the unacked event — restore did not take"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all session-start attention checks passed" || echo "FAILURES"
exit $FAILED

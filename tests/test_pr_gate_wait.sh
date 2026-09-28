#!/bin/bash
# velo-pr-gate --wait's block, extracted verbatim (same convention as
# test_second_opinion.sh / test_gate_post_sha.sh use for other pieces of this
# script) and exercised against FAKE pids — short-lived `sleep` background
# jobs standing in for the real codex/claude/velo-local processes — plus
# fake CODE_LOG/CODEX_LOG files. Driving a real dispatch would need live
# codex/claude CLIs and a real PR; this proves the thing the brief asks for:
# it blocks until every one of ITS OWN pids has exited, then reports.
#
# Every case runs the block inside its OWN child `bash -c` process, not a
# direct `eval` in this script: the block ends with an explicit `exit 0`
# (added so a clean report's grep-finds-nothing can't leak a nonzero exit
# under pipefail — see velo-pr-gate's own comment there), and `exit` inside a
# plain `eval` terminates the CALLING shell, not a subshell — the first cut
# of this test called `eval "$BLOCK"` directly and silently killed itself at
# that `exit 0` before printing anything past the first assertion. Giving the
# block its own process means its `exit` only ends that process, and because
# THAT SAME process is the one that backgrounds the fake pids, its internal
# `wait "$gp"` calls are genuine waits on real children — no cross-shell
# "not a child of this shell" problem either (test_dispatch_wait.sh hit that
# one; documented there).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRGATE="$(cd "$HERE/.." && pwd)/bin/velo-pr-gate"
FAILED=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

FN=$(sed -n '/^gate_final_codex_message/,/^}/p' "$PRGATE")
BLOCK=$(sed -n '/^# >>> velo-pr-gate-wait/,/^# <<< velo-pr-gate-wait/p' "$PRGATE")
[[ -n "$FN" ]]    || { echo "  FAIL could not extract gate_final_codex_message — deleted or renamed."; exit 1; }
[[ -n "$BLOCK" ]] || { echo "  FAIL could not extract the --wait block from velo-pr-gate — deleted or renamed."; exit 1; }
echo "  ok   gate_final_codex_message and the --wait block are still present ($(wc -l <<<"$BLOCK" | tr -d ' ') lines)"

PR=2999
CODE_LOG="$TMPD/code.log"
cat > "$CODE_LOG" <<'EOF'
some preamble the model printed
**Verdict:** approve-with-findings
HIGH - foo.rs:10: something real
EOF

CODEX_LOG="$TMPD/review.log"
# Two "codex" markers: the extraction must isolate the SECOND (final) one and
# exclude the earlier turn, exactly like the real transcripts sampled from
# ~/.agents/state/gate/*/review.log during development.
cat > "$CODEX_LOG" <<'EOF'
codex
some earlier turn, not the report
codex
## Codex review - PR 2999 @ abc1234
**Verdict:** blocked
MEDIUM - bar.rs:20: something else
EOF

run_case() {  # $1 = outfile, $2 = setup script (sets WAIT / GATE_PIDS)
  local outfile="$1" setup="$2"
  bash -c "
    set -uo pipefail
    $FN
    warn() { echo \"WARN: \$1\"; }
    PR=$PR
    CODE_LOG='$CODE_LOG'
    CODEX_LOG='$CODEX_LOG'
    $setup
    $BLOCK
  " > "$outfile" 2>&1
  echo $?
}

# ---- case 1: --wait blocks until BOTH fake pids exit, then reports --------
# `date +%s` has 1s resolution on macOS (no %N, unlike GNU date) — too coarse
# to tell "waited ~0.6s" apart from "returned instantly", which is exactly
# the property this timing check exists to catch. python3's time.time() is
# used elsewhere in this repo's tooling and gives real sub-second precision.
now_s() { python3 -c 'import time; print(time.time())'; }

OUT1="$TMPD/out1.txt"
T0=$(now_s)
RC=$(run_case "$OUT1" 'WAIT=1; sleep 0.4 & GATE_PIDS=("$!"); sleep 0.6 & GATE_PIDS+=("$!")')
T1=$(now_s)
OUT=$(cat "$OUT1")

if [[ "$RC" == "0" ]]; then echo "  ok   --wait exits 0"
else echo "  FAIL --wait exited $RC, want 0"; FAILED=1; fi

# A real wait cannot finish faster than its slowest job (0.6s); returning
# immediately instead of waiting would read as ~0.0-0.05s here.
ELAPSED=$(python3 -c "print(f'{$T1 - $T0:.3f}')")
if python3 -c "exit(0 if ($T1 - $T0) >= 0.5 else 1)"; then
  echo "  ok   blocked for ${ELAPSED}s (>= the 0.6s slower fake pid)"
else
  echo "  FAIL only blocked for ${ELAPSED}s — returned before the slower fake pid exited"
  FAILED=1
fi

if grep -q 'approve-with-findings' <<<"$OUT" && grep -qF 'HIGH - foo.rs:10' <<<"$OUT"; then
  echo "  ok   check-code report's Verdict/HIGH lines are printed"
else
  echo "  FAIL check-code report missing from output:"; sed 's/^/        /' <<<"$OUT"; FAILED=1
fi

if grep -q 'blocked' <<<"$OUT" && grep -qF 'MEDIUM - bar.rs:20' <<<"$OUT"; then
  echo "  ok   codex final message's Verdict/MEDIUM lines are printed"
else
  echo "  FAIL codex final-message report missing from output:"; sed 's/^/        /' <<<"$OUT"; FAILED=1
fi

if grep -q 'some earlier turn, not the report' <<<"$OUT"; then
  echo "  FAIL leaked an EARLIER codex turn into the report — not isolating the FINAL message"
  FAILED=1
else
  echo "  ok   the earlier (non-final) codex turn was excluded"
fi

# ---- case 2: nothing dispatched -> reported, still exits 0, no crash ------
OUT2="$TMPD/out2.txt"
RC2=$(run_case "$OUT2" 'WAIT=1; GATE_PIDS=()')
if [[ "$RC2" == "0" ]]; then echo "  ok   empty GATE_PIDS still exits 0"
else echo "  FAIL empty GATE_PIDS exited $RC2, want 0"; FAILED=1; fi
if grep -q 'nothing was dispatched' "$OUT2"; then echo "  ok   empty GATE_PIDS is reported, not silent"
else echo "  FAIL empty GATE_PIDS produced no message:"; sed 's/^/        /' "$OUT2"; FAILED=1; fi

# ---- case 3: WAIT=0 is a complete no-op (existing, non---wait callers) ----
OUT3="$TMPD/out3.txt"
RC3=$(run_case "$OUT3" 'WAIT=0; GATE_PIDS=($$)')  # a real pid (the child itself) — a bug that ignores WAIT would hang waiting on it
if [[ ! -s "$OUT3" && "$RC3" == "0" ]]; then
  echo "  ok   WAIT=0 produces no output and exits 0 (no-op for callers who never pass --wait)"
else
  echo "  FAIL WAIT=0 was not a no-op: rc=$RC3"; sed 's/^/        /' "$OUT3"; FAILED=1
fi

echo
[[ $FAILED -eq 0 ]] && echo "all velo-pr-gate --wait checks passed" || echo "FAILURES"
exit $FAILED

#!/bin/bash
# velo-pr-gate's launch-time bookkeeping, extracted verbatim (same convention
# test_pr_gate_wait.sh / test_fail_to_pass.sh use): gate_track_pid (the single
# write-site for both GATE_PIDS and "<log>.pid", #2285 Round 2) and the
# gated.sha write (recorded before ANY gate is dispatched, so velo-gate-post
# and velo-orchestrd never fall back to the live PR head).
#
# Both blocks are exercised in a fresh child `bash -c`, not a direct `eval` in
# this script — same reason test_pr_gate_wait.sh gives: isolating each run so
# nothing here can leak state (a stray GATE_PIDS entry, a leftover die()
# trap) between cases.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRGATE="$(cd "$HERE/.." && pwd)/bin/velo-pr-gate"
FAILED=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

TRACK_BLOCK=$(sed -n '/^# >>> velo-gate-track-pid/,/^# <<< velo-gate-track-pid/p' "$PRGATE")
SHA_BLOCK=$(sed -n '/^# >>> velo-gated-sha/,/^# <<< velo-gated-sha/p' "$PRGATE")
[[ -n "$TRACK_BLOCK" ]] || { echo "  FAIL could not extract gate_track_pid — deleted or renamed."; exit 1; }
[[ -n "$SHA_BLOCK" ]]   || { echo "  FAIL could not extract the gated.sha block — deleted or renamed."; exit 1; }
echo "  ok   gate_track_pid and the gated.sha block are still present ($(wc -l <<<"$TRACK_BLOCK" | tr -d ' ')+$(wc -l <<<"$SHA_BLOCK" | tr -d ' ') lines)"

# ---- 1: gate_track_pid writes BOTH records from one call ------------------
LOG="$TMPD/some-gate.log"
OUT1="$TMPD/out1.txt"
bash -c "
  set -uo pipefail
  $TRACK_BLOCK
  gate_track_pid 4242 '$LOG'
  printf 'GATE_PIDS=%s\n' \"\${GATE_PIDS[*]}\"
" > "$OUT1" 2>&1
if grep -q 'GATE_PIDS=4242' "$OUT1"; then
  echo "  ok   gate_track_pid appends to GATE_PIDS"
else
  echo "  FAIL GATE_PIDS was not populated:"; sed 's/^/        /' "$OUT1"; FAILED=1
fi
if [[ -f "$LOG.pid" ]] && [[ "$(cat "$LOG.pid")" == "4242" ]]; then
  echo "  ok   gate_track_pid persists <log>.pid for a separate process to read"
else
  echo "  FAIL $LOG.pid missing or wrong content: $(cat "$LOG.pid" 2>/dev/null || echo '<absent>')"; FAILED=1
fi

# ---- 2: MUTATION-PROOF — gate_track_pid's persistence half ----------------
# Comment out the printf line in the REAL file, confirm the pid-file half
# goes missing (GATE_PIDS still populates — that half is untouched), restore,
# confirm both halves are back.
BACKUP="$TMPD/velo-pr-gate.backup.$(date -u +%Y%m%dT%H%M%SZ)"
cp "$PRGATE" "$BACKUP"
python3 - "$PRGATE" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = "  GATE_PIDS+=(\"$1\")\n  printf '%s\\n' \"$1\" > \"$2.pid\"\n"
new = "  GATE_PIDS+=(\"$1\")\n  : mutated-out-for-test \"$1\" \"$2.pid\"\n"
assert old in t, "gate_track_pid body not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
MUT_BLOCK=$(sed -n '/^# >>> velo-gate-track-pid/,/^# <<< velo-gate-track-pid/p' "$PRGATE")
LOG2="$TMPD/mutated-gate.log"
bash -c "
  set -uo pipefail
  $MUT_BLOCK
  gate_track_pid 5151 '$LOG2'
" > "$TMPD/out_mut.txt" 2>&1
if [[ -f "$LOG2.pid" ]]; then
  echo "  FAIL mutation-proof did not go RED: $LOG2.pid still got written with the printf line removed"; FAILED=1
else
  echo "  ok   MUTATION-PROOF red: with the printf line removed, no <log>.pid is written"
fi
cp "$BACKUP" "$PRGATE"
if diff -q "$BACKUP" "$PRGATE" >/dev/null; then
  echo "  ok   velo-pr-gate restored byte-identical after the mutation"
else
  echo "  FAIL velo-pr-gate did NOT restore cleanly — check $PRGATE by hand"; FAILED=1
fi
RESTORED_BLOCK=$(sed -n '/^# >>> velo-gate-track-pid/,/^# <<< velo-gate-track-pid/p' "$PRGATE")
LOG3="$TMPD/restored-gate.log"
bash -c "
  set -uo pipefail
  $RESTORED_BLOCK
  gate_track_pid 6161 '$LOG3'
" > "$TMPD/out_restored.txt" 2>&1
if [[ -f "$LOG3.pid" ]] && [[ "$(cat "$LOG3.pid")" == "6161" ]]; then
  echo "  ok   MUTATION-PROOF green: restored file writes <log>.pid again"
else
  echo "  FAIL restored file still does not write <log>.pid — restore did not take"; FAILED=1
fi

# ---- 3: gated.sha is written at launch, matching the worktree's real HEAD -
FAKE_REPO="$TMPD/fakerepo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
EXPECT_SHA=$(git -C "$FAKE_REPO" rev-parse --short HEAD)
GATE_DIR1="$TMPD/gatedir1"; mkdir -p "$GATE_DIR1"
bash -c "
  set -uo pipefail
  die() { echo \"DIE: \$1\" >&2; exit 1; }
  WTPATH='$FAKE_REPO'
  GATE_DIR='$GATE_DIR1'
  $SHA_BLOCK
" > "$TMPD/out_sha.txt" 2>&1
if [[ -f "$GATE_DIR1/gated.sha" ]] && [[ "$(cat "$GATE_DIR1/gated.sha")" == "$EXPECT_SHA" ]]; then
  echo "  ok   gated.sha records the worktree's real HEAD ($EXPECT_SHA)"
else
  echo "  FAIL gated.sha wrong or missing: $(cat "$GATE_DIR1/gated.sha" 2>/dev/null || echo '<absent>') want $EXPECT_SHA"
  sed 's/^/        /' "$TMPD/out_sha.txt"
  FAILED=1
fi

# ---- 4: MUTATION-PROOF — the gated.sha write itself -----------------------
python3 - "$PRGATE" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = "printf '%s\\n' \"$HEAD\" > \"$GATE_DIR/gated.sha\"\n"
new = ": mutated-out-for-test \"$HEAD\" \"$GATE_DIR/gated.sha\"\n"
assert old in t, "gated.sha printf not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
MUT_SHA_BLOCK=$(sed -n '/^# >>> velo-gated-sha/,/^# <<< velo-gated-sha/p' "$PRGATE")
GATE_DIR2="$TMPD/gatedir2"; mkdir -p "$GATE_DIR2"
bash -c "
  set -uo pipefail
  die() { echo \"DIE: \$1\" >&2; exit 1; }
  WTPATH='$FAKE_REPO'
  GATE_DIR='$GATE_DIR2'
  $MUT_SHA_BLOCK
" > "$TMPD/out_sha_mut.txt" 2>&1
if [[ -f "$GATE_DIR2/gated.sha" ]]; then
  echo "  FAIL mutation-proof did not go RED: gated.sha still got written with the printf line removed"; FAILED=1
else
  echo "  ok   MUTATION-PROOF red: with the printf line removed, no gated.sha is written"
fi
cp "$BACKUP" "$PRGATE"
if diff -q "$BACKUP" "$PRGATE" >/dev/null; then
  echo "  ok   velo-pr-gate restored byte-identical after the second mutation"
else
  echo "  FAIL velo-pr-gate did NOT restore cleanly — check $PRGATE by hand"; FAILED=1
fi
RESTORED_SHA_BLOCK=$(sed -n '/^# >>> velo-gated-sha/,/^# <<< velo-gated-sha/p' "$PRGATE")
GATE_DIR3="$TMPD/gatedir3"; mkdir -p "$GATE_DIR3"
bash -c "
  set -uo pipefail
  die() { echo \"DIE: \$1\" >&2; exit 1; }
  WTPATH='$FAKE_REPO'
  GATE_DIR='$GATE_DIR3'
  $RESTORED_SHA_BLOCK
" > "$TMPD/out_sha_restored.txt" 2>&1
if [[ -f "$GATE_DIR3/gated.sha" ]] && [[ "$(cat "$GATE_DIR3/gated.sha")" == "$EXPECT_SHA" ]]; then
  echo "  ok   MUTATION-PROOF green: restored file writes gated.sha again"
else
  echo "  FAIL restored file still does not write gated.sha — restore did not take"; FAILED=1
fi

# ---- 5: gated.sha is computed BEFORE the first dispatch, not just inside ---
# NEEDS_REVIEW. Pre-#2285-Round-2, HEAD was only resolved inside the
# NEEDS_REVIEW block, itself AFTER the NEEDS_SPEC dispatch — a check-spec-only
# run (git show 3436e0367:.agents/bin/velo-pr-gate, the PR1 shape) never got a
# gated.sha at all. Structural, not a runtime mutation: the property being
# pinned IS the line ordering.
SHA_LINE=$(grep -n '^# >>> velo-gated-sha' "$PRGATE" | head -1 | cut -d: -f1)
DISPATCH_LINE=$(grep -n 'NEEDS_SPEC -eq 1 \]\]; then' "$PRGATE" | head -1 | cut -d: -f1)
if [[ -n "$SHA_LINE" && -n "$DISPATCH_LINE" && "$SHA_LINE" -lt "$DISPATCH_LINE" ]]; then
  echo "  ok   gated.sha (line $SHA_LINE) is computed before the first dispatch (line $DISPATCH_LINE)"
else
  echo "  FAIL gated.sha block is not before the first dispatch: sha=$SHA_LINE dispatch=$DISPATCH_LINE"; FAILED=1
fi

# ---- the second opinion is detached: --wait does not wait for it (#2350) ----
# Tracked like a gate, it held velo-pr-gate's --wait — and the gate lock — until
# the local model finished, and the next round died on "a gate is already
# running". Runs the REAL launch block and the REAL --wait block in one process,
# with a stub runner that outlives the wait by several seconds.
SO_BLOCK=$(awk '/^  if \[\[ "\$\{VELO_SECOND_OPINION:-1\}" == "1" \]\]; then$/ {p=1} p {print} p && /^  fi$/ {exit}' "$PRGATE")
WAIT_BLOCK=$(sed -n '/^# >>> velo-pr-gate-wait/,/^# <<< velo-pr-gate-wait/p' "$PRGATE")
FN_BLOCK=$(sed -n '/^gate_final_codex_message/,/^}/p' "$PRGATE")
[[ -n "$SO_BLOCK" && -n "$WAIT_BLOCK" ]] || { echo "  FAIL could not extract the second-opinion launch or the --wait block"; exit 1; }
cat > "$TMPD/fake-runner" <<'EOF'
#!/bin/bash
sleep 8
EOF
chmod +x "$TMPD/fake-runner"
so_wait_secs() {   # <launch block> -> seconds --wait took; leaves the pid in $TMPD/so/second-opinion.log.pid
  rm -rf "$TMPD/so"; mkdir -p "$TMPD/so"; printf 'brief\n' > "$TMPD/so/brief.md"
  local t0=$SECONDS
  bash -c "
    set -uo pipefail
    ok() { :; }; warn() { :; }
    GATE_DIR='$TMPD/so'; WRAPPER='$TMPD/fake-runner'; LOCAL_MODEL=m; LMSTUDIO_URL=u
    POLICY=p; WTPATH='$TMPD'; OUT='$TMPD/so/brief.md'; WAIT=1; PR=1; CODE_LOG=''; CODEX_LOG=''
    $TRACK_BLOCK
    $FN_BLOCK
    $1
    $WAIT_BLOCK
  " > "$TMPD/so/out.txt" 2>&1
  echo $((SECONDS - t0))
}
T_REAL=$(so_wait_secs "$SO_BLOCK")
SO_PID=$(cat "$TMPD/so/second-opinion.log.pid" 2>/dev/null)
if [[ "$T_REAL" -lt 5 ]] && [[ -n "$SO_PID" ]] && kill -0 "$SO_PID" 2>/dev/null; then
  echo "  ok   --wait returned in ${T_REAL}s with the second opinion still running (pid $SO_PID, persisted for velo-gate-run to reap)"
else
  echo "  FAIL --wait took ${T_REAL}s / second opinion pid '$SO_PID' not running: $(tail -3 "$TMPD/so/out.txt")"; FAILED=1
fi
[[ -n "$SO_PID" ]] && kill "$SO_PID" 2>/dev/null
# MUTATION-PROOF: tracked as a gate again, --wait blocks for the runner's 8s.
MUT_SO=${SO_BLOCK/gate_track_detached/gate_track_pid}
if [[ "$MUT_SO" == "$SO_BLOCK" ]]; then
  echo "  FAIL MUTATION-PROOF: the second-opinion launch does not call gate_track_detached"; FAILED=1
else
  T_MUT=$(so_wait_secs "$MUT_SO")
  if [[ "$T_MUT" -ge 7 ]]; then
    echo "  ok   MUTATION-PROOF red: tracked with gate_track_pid, --wait blocked ${T_MUT}s on the second opinion"
  else
    echo "  FAIL MUTATION-PROOF stayed green: --wait took only ${T_MUT}s with the second opinion in GATE_PIDS"; FAILED=1
  fi
fi

echo
[[ $FAILED -eq 0 ]] && echo "all velo-pr-gate launch-bookkeeping checks passed" || echo "FAILURES"
exit $FAILED

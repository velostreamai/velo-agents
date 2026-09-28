#!/bin/bash
# velo-gate-post must post a (pr, gate-name, sha) result AT MOST ONCE, even
# when two callers race — a human relaying a --wait report by hand, and
# velo-orchestrd's own step_gates on its next tick both call this same
# script, and step_gates' own "does a header already exist" check reads the
# PR THEN posts, leaving a window a concurrent caller can land in.
#
# Also covers the other #2285 Round 2 change to this file: a bare (no --sha)
# call now prefers the recorded $VELO_STATE/gate/<pr>/gated.sha over the PR's
# live head, so a report posted after fixing findings and committing still
# stamps the sha the gate actually ran against.
#
# Drives the REAL script under a stubbed `gh` and a sandboxed VELO_STATE —
# same reason test_gate_post_sha.sh does it this way.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
POST="$BIN/velo-gate-post"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$POST" ]] || { fail "velo-gate-post not found at $POST"; exit 1; }

TMPD=$(mktemp -d)
LIVE_PID=""
kill_live() { [[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null; }
trap 'kill_live; rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

# Deliberately DIFFERENT from the recorded gated.sha below — if a bare call
# ever posts against this instead, the gated-sha preference has regressed.
LIVEHEAD="9999999999999999999999999999999999999999"
GATEDSHA="1234567890123456789012345678901234567890"
CALLS_LOG="$TMPD/calls.log"

cat > "$TMPD/bin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$CALLS_LOG"
for a in "\$@"; do [[ "\$a" == "headRefOid" ]] && { echo "$LIVEHEAD"; exit 0; }; done
if [[ "\$1" == "pr" && "\$2" == "comment" ]]; then
  echo "https://github.com/x/y/pull/1#issuecomment-stub"
  exit 0
fi
echo ""; exit 0
EOF
chmod +x "$TMPD/bin/gh"
export PATH="$TMPD/bin:$PATH"

VELO_STATE="$TMPD/state"
export VELO_STATE
PR=555
GATE_DIR="$VELO_STATE/gate/$PR"
mkdir -p "$GATE_DIR"
printf '%s' "$GATEDSHA" > "$GATE_DIR/gated.sha"

REPORT="$TMPD/report.md"
printf '## report\n**Verdict:** approve\n' > "$REPORT"

# See test_merge_once.sh's identical helper for why this is not
# `grep -c ... || echo 0`: grep -c exits 1 on a legitimate zero count, and a
# `||` fallback on that exit status prints a SECOND "0" on top of the first.
pr_comment_calls() { grep -c '^pr comment' "$CALLS_LOG"; }

# ---- 1: a bare call (no --sha) prefers gated.sha over the live head -------
OUT1=$("$POST" "$PR" code-review "$REPORT" 2>&1); RC1=$?
if [[ $RC1 -eq 0 ]]; then ok "first post exits 0"
else fail "first post exited $RC1: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-200)"; fi
# The stub logs the full `gh pr comment ... --body "$FULL"` argv, so the
# ACTUAL posted header is checkable directly — a stronger assertion than
# scanning stdout, which legitimately ALSO mentions the live head as part of
# the (correct, wanted) staleness-transparency warn when the two differ.
if grep -qF "gate: code-review @ ${GATEDSHA:0:9}" "$CALLS_LOG"; then
  ok "posted against the recorded gated.sha, not the live head"
else
  fail "posted body does not carry the gated.sha header: $(tr '\n' ' ' <<<"$(cat "$CALLS_LOG")" | cut -c1-300)"
fi
if [[ "$(pr_comment_calls)" == "1" ]]; then
  ok "exactly one 'gh pr comment' call for the first post"
else
  fail "expected exactly 1 pr-comment call, got $(pr_comment_calls)"
fi
DONE_MARKER="$GATE_DIR/.posted-code-review-${GATEDSHA:0:9}"
if [[ -f "$DONE_MARKER" ]]; then
  ok "done-marker written at $DONE_MARKER"
else
  fail "no done-marker at $DONE_MARKER"
fi

# ---- 2: a sequential repeat (e.g. a re-run) is a silent no-op -------------
OUT2=$("$POST" "$PR" code-review "$REPORT" 2>&1); RC2=$?
if [[ $RC2 -eq 0 ]]; then ok "repeat post also exits 0"
else fail "repeat post exited $RC2"; fi
if grep -qi 'already posted' <<<"$OUT2"; then
  ok "repeat post reports it is skipping, not silent"
else
  fail "repeat post gave no idempotency message: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-200)"
fi
if [[ "$(pr_comment_calls)" == "1" ]]; then
  ok "still exactly one 'gh pr comment' call after the repeat — no double-post"
else
  fail "repeat post added a SECOND pr-comment call: total now $(pr_comment_calls)"
fi

# ---- 3: a session --wait post racing a daemon tick's post -----------------
# Simulate contention directly rather than hoping two backgrounded processes
# happen to collide: hold the lock ourselves (as if process A — the daemon's
# step_gates — is mid-post), launch process B (the session, relaying a --wait
# report by hand) against the SAME (pr, name, sha), then release the lock by
# writing the done-marker ourselves after a short delay (as if A finished).
# B must detect that and exit 0 having made no `gh pr comment` call of its
# own — the exact shape #2285 Round 2 asks to prove.
PR2=556
GATE_DIR2="$VELO_STATE/gate/$PR2"
mkdir -p "$GATE_DIR2"
printf '%s' "$GATEDSHA" > "$GATE_DIR2/gated.sha"
LOCK2="$GATE_DIR2/.posting-code-review-${GATEDSHA:0:9}.lock"
DONE2="$GATE_DIR2/.posted-code-review-${GATEDSHA:0:9}"
mkdir "$LOCK2"   # process A holds the lock

CALLS_BEFORE_B=$(pr_comment_calls)
OUT3_FILE="$TMPD/out3.txt"
"$POST" "$PR2" code-review "$REPORT" > "$OUT3_FILE" 2>&1 &
LIVE_PID=$!

sleep 1.5
# Process A "finishes": writes the done-marker, releases its lock.
printf 'pid A-simulated at %s\n' "$(date -u +%FT%TZ)" > "$DONE2"
rmdir "$LOCK2" 2>/dev/null

wait "$LIVE_PID"; RC3=$?
LIVE_PID=""
OUT3=$(cat "$OUT3_FILE")
if [[ $RC3 -eq 0 ]]; then
  ok "the racing (session --wait) post exits 0 once it sees A's done-marker"
else
  fail "the racing post exited $RC3: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-200)"
fi
if grep -qi 'posted concurrently' <<<"$OUT3"; then
  ok "the racing post reports it detected a concurrent post, not silent"
else
  fail "the racing post gave no concurrency message: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-200)"
fi
CALLS_AFTER_B=$(pr_comment_calls)
if [[ "$CALLS_AFTER_B" == "$CALLS_BEFORE_B" ]]; then
  ok "the racing post made NO 'gh pr comment' call of its own — posted exactly once total"
else
  fail "the racing post ALSO called gh pr comment — double-post: before=$CALLS_BEFORE_B after=$CALLS_AFTER_B"
fi

# ---- 4: MUTATION-PROOF — the done-marker check is what prevents the double-post
# Fresh PR/gate-dir for this section: PR=555's own gate dir already carries a
# done-marker from checks 1-2 above, which would make even the CORRECT,
# restored code skip on its first call here and read as a false failure.
PR3=557
GATE_DIR3="$VELO_STATE/gate/$PR3"
mkdir -p "$GATE_DIR3"
printf '%s' "$GATEDSHA" > "$GATE_DIR3/gated.sha"

BACKUP="$TMPD/velo-gate-post.backup"
cp "$POST" "$BACKUP"
python3 - "$POST" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$POST_DONE" ]]; then\n  ok "\'$NAME\' @ ${SHA:0:9} already posted ($(cat "$POST_DONE" 2>/dev/null)) — skipping (idempotent)"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert old in t, "post-once done-marker check not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
: > "$CALLS_LOG"   # reset the call count for a clean before/after read
OUT_MUT1=$("$POST" "$PR3" code-review "$REPORT" 2>&1)
OUT_MUT2=$("$POST" "$PR3" code-review "$REPORT" 2>&1)
MUT_CALLS=$(pr_comment_calls)
cp "$BACKUP" "$POST"
if diff -q "$BACKUP" "$POST" >/dev/null; then
  ok "velo-gate-post restored byte-identical after the mutation"
else
  fail "velo-gate-post did NOT restore cleanly — check $POST by hand"
fi
if [[ "$MUT_CALLS" -ge 2 ]]; then
  ok "MUTATION-PROOF red: with the done-marker check disabled, the same (pr,name,sha) posts twice ($MUT_CALLS calls)"
else
  fail "mutation-proof did not go RED: expected >=2 pr-comment calls with the guard disabled, got $MUT_CALLS"
fi
# A fresh done-marker was written by OUT_MUT1/2 above under the mutated code,
# so verifying the RESTORE also needs a fresh (pr, name, sha) — PR3's gate
# dir now carries a marker too, for the same reason PR=555's does.
PR4=558
GATE_DIR4="$VELO_STATE/gate/$PR4"
mkdir -p "$GATE_DIR4"
printf '%s' "$GATEDSHA" > "$GATE_DIR4/gated.sha"
: > "$CALLS_LOG"
"$POST" "$PR4" code-review "$REPORT" >/dev/null 2>&1
"$POST" "$PR4" code-review "$REPORT" >/dev/null 2>&1
RESTORED_CALLS=$(pr_comment_calls)
if [[ "$RESTORED_CALLS" == "1" ]]; then
  ok "MUTATION-PROOF green: restored file posts exactly once again"
else
  fail "restored file still double-posts: $RESTORED_CALLS calls — restore did not take"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all gate-post once-only checks passed" || echo "FAILURES"
exit $FAILED

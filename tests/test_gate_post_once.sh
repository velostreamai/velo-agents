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

# The guard looks at the marker TWICE: before the lock (the fast path) and again once the
# lock is held (a caller that was delayed between the two). Either alone keeps a
# sequential repeat from posting twice — so this proof removes BOTH; each look on its own
# is pinned by section 5.
BACKUP="$TMPD/velo-gate-post.backup"
cp "$POST" "$BACKUP"
python3 - "$POST" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$POST_DONE" ]]; then\n  read_marker "$POST_DONE"\n  ok "\'$NAME\' @ ${SHA:0:9} already posted ($MARKER_TEXT) — skipping (idempotent)"\n  exit 0\nfi\n'
old2 = 'if [[ -f "$POST_DONE" ]]; then\n  read_marker "$POST_DONE"\n  ok "\'$NAME\' @ ${SHA:0:9} was posted concurrently ($MARKER_TEXT) — skipping"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert old in t, "post-once done-marker check not found verbatim — did it change shape?"
assert old2 in t, "post-once second look at the done-marker not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1).replace(old2, new, 1))
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
  ok "MUTATION-PROOF red: with both done-marker checks disabled, the same (pr,name,sha) posts twice ($MUT_CALLS calls)"
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

# ---- 5: the done-marker is checked AGAIN once the lock is held (#2380 r2) ----
# Section 3 is a caller that finds the lock HELD. This is the other order: a caller
# that checked the marker (absent), was delayed, and takes the lock only AFTER the first
# one finished — marker written, lock released. Nothing in the script lets a test stand
# between its marker check and its mkdir, so `mkdir` is a stub that models exactly that:
# asked for the LOCK, it first writes the marker (the other caller finishing), then makes
# the directory. A script that does not look again posts the same comment twice.
PR5=559
GATE_DIR5="$VELO_STATE/gate/$PR5"
mkdir -p "$GATE_DIR5" "$TMPD/mkstub"
printf '%s' "$GATEDSHA" > "$GATE_DIR5/gated.sha"
cat > "$TMPD/mkstub/mkdir" <<'EOF'
#!/bin/bash
last=""; for a in "$@"; do last="$a"; done
if [[ "$last" == *.posting-*.lock && -n "${RACE_MARKER:-}" ]]; then
  printf 'pid other-caller at race\n' > "$RACE_MARKER"
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$TMPD/mkstub/mkdir"
: > "$CALLS_LOG"
OUT5=$(PATH="$TMPD/mkstub:$PATH" RACE_MARKER="$GATE_DIR5/.posted-code-review-${GATEDSHA:0:9}" \
       "$POST" "$PR5" code-review "$REPORT" 2>&1); RC5=$?
if [[ $RC5 -eq 0 ]]; then ok "a caller that takes the lock after the first finished exits 0"
else fail "late-lock caller exited $RC5: $(tr '\n' ' ' <<<"$OUT5" | cut -c1-200)"; fi
if grep -qi 'posted concurrently' <<<"$OUT5"; then
  ok "and says it found the comment already posted, not silent"
else
  fail "late-lock caller gave no concurrency message: $(tr '\n' ' ' <<<"$OUT5" | cut -c1-200)"
fi
if [[ "$(pr_comment_calls)" == "0" ]]; then
  ok "and made NO 'gh pr comment' call: the comment is posted exactly once"
else
  fail "late-lock caller posted the comment AGAIN: $(pr_comment_calls) call(s)"
fi
if [[ ! -d "$GATE_DIR5/.posting-code-review-${GATEDSHA:0:9}.lock" ]]; then
  ok "and released the lock it took"
else
  fail "late-lock caller left its lock behind"
fi

# MUTATION-PROOF: the second look alone is what covers this order.
BACKUP5="$TMPD/velo-gate-post.backup5"
cp "$POST" "$BACKUP5"
python3 - "$POST" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$POST_DONE" ]]; then\n  read_marker "$POST_DONE"\n  ok "\'$NAME\' @ ${SHA:0:9} was posted concurrently ($MARKER_TEXT) — skipping"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert t.count(old) == 1, "post-once second look at the done-marker not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
PR6=560
GATE_DIR6="$VELO_STATE/gate/$PR6"
mkdir -p "$GATE_DIR6"
printf '%s' "$GATEDSHA" > "$GATE_DIR6/gated.sha"
: > "$CALLS_LOG"
PATH="$TMPD/mkstub:$PATH" RACE_MARKER="$GATE_DIR6/.posted-code-review-${GATEDSHA:0:9}" "$POST" "$PR6" code-review "$REPORT" >/dev/null 2>&1
MUT5_CALLS=$(pr_comment_calls)
cp "$BACKUP5" "$POST"
if diff -q "$BACKUP5" "$POST" >/dev/null; then
  ok "velo-gate-post restored byte-identical after the second mutation"
else
  fail "velo-gate-post did NOT restore cleanly — check $POST by hand"
fi
if [[ "$MUT5_CALLS" -ge 1 ]]; then
  ok "MUTATION-PROOF red: without the second look, a late-lock caller posts a comment that is already there ($MUT5_CALLS call)"
else
  fail "mutation-proof did not go RED: expected >=1 pr-comment call without the second look, got $MUT5_CALLS"
fi
PR7=561
GATE_DIR7="$VELO_STATE/gate/$PR7"
mkdir -p "$GATE_DIR7"
printf '%s' "$GATEDSHA" > "$GATE_DIR7/gated.sha"
: > "$CALLS_LOG"
PATH="$TMPD/mkstub:$PATH" RACE_MARKER="$GATE_DIR7/.posted-code-review-${GATEDSHA:0:9}" "$POST" "$PR7" code-review "$REPORT" >/dev/null 2>&1
if [[ "$(pr_comment_calls)" == "0" ]]; then
  ok "MUTATION-PROOF green: the restored file makes no comment call in that order"
else
  fail "the restored file still posts in the late-lock order: $(pr_comment_calls) call(s)"
fi

# ---- 8: a done-marker that EXISTS but cannot be read is an error, not a success (#2380 r3) --
#
# The guards act on the marker's existence; its content is the "who and when" in the skip
# line. The content used to be read with `$(cat "$POST_DONE" 2>/dev/null)`: a failed read
# printed "already posted ()" and exited 0 — a success line for a record never read. The
# three states are told apart now: absent (the guard does not fire), unreadable (refuse,
# naming the file and cat's own error), empty (still proof the comment was posted: skip,
# and say the marker was empty rather than print "()").
#
# `cat` is a stub for the unreadable case because root reads a chmod 000 file and this suite
# runs under any uid; it stands for EIO, a stale NFS handle, a state dir owned by another user.
echo
echo "8. a done-marker that exists but cannot be read is an error, not a success"
CATSTUB="$TMPD/catstub"; mkdir -p "$CATSTUB"
cat > "$CATSTUB/cat" <<'EOF'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == */.posted-* ]]; then
    echo "cat: $a: Input/output error" >&2
    exit 1
  fi
done
exec /bin/cat "$@"
EOF
chmod +x "$CATSTUB/cat"
# A `mkdir` that reports the lock as held by someone else, whose marker is already written:
# the order that sends a caller into the poll loop.
HOLDSTUB="$TMPD/holdstub"; mkdir -p "$HOLDSTUB"
cat > "$HOLDSTUB/mkdir" <<'EOF'
#!/bin/bash
last=""; for a in "$@"; do last="$a"; done
if [[ "$last" == *.posting-*.lock ]]; then
  [[ -n "${RACE_MARKER:-}" ]] && printf 'pid other-caller at race\n' > "$RACE_MARKER"
  echo "mkdir: $last: File exists" >&2
  exit 1
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$HOLDSTUB/mkdir"
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-320)"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then fail "$1: did NOT want '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-320)"; else ok "$1"; fi; }
marker_of() { printf '%s' "$VELO_STATE/gate/$1/.posted-code-review-${GATEDSHA:0:9}"; }   # <pr>
lock_of()   { printf '%s' "$VELO_STATE/gate/$1/.posting-code-review-${GATEDSHA:0:9}.lock"; }   # <pr>
prep_pr()   { mkdir -p "$VELO_STATE/gate/$1"; printf '%s' "$GATEDSHA" > "$VELO_STATE/gate/$1/gated.sha"; }   # <pr>
plant_marker() { prep_pr "$1"; printf '%s' "$2" > "$(marker_of "$1")"; }   # <pr> <exact content>
# Run velo-gate-post for <pr> under the given PATH prefix. Sets OUT and RC; clears the call log.
post_with() {   # <pr> <PATH prefix or ''>
  local pr="$1" pre="$2"
  : > "$CALLS_LOG"
  OUT=$(PATH="${pre:+$pre:}$PATH" "$POST" "$pr" code-review "$REPORT" 2>&1); RC=$?
}
refused_unreadable() {   # <label> <pr>: the shared expectations of an unreadable marker
  [[ $RC -ne 0 ]] && ok "$1: refuses (exit $RC)" || fail "$1: exit 0 — a success for a record never read"
  has   "$1: named as an unreadable done-marker"  "$OUT" "unreadable done-marker"
  has   "$1: names the marker file"               "$OUT" ".posted-code-review-${GATEDSHA:0:9}"
  has   "$1: shows cat's own error"               "$OUT" "Input/output error"
  lacks "$1: NOT reported as already posted"      "$OUT" "already posted"
  lacks "$1: NOT reported as posted concurrently" "$OUT" "posted concurrently"
  [[ "$(pr_comment_calls)" == "0" ]] && ok "$1: no 'gh pr comment' call" || fail "$1: gh pr comment ran: $(pr_comment_calls) call(s)"
  [[ ! -d "$(lock_of "$2")" ]] && ok "$1: no lock left behind" || fail "$1: left $(lock_of "$2") behind"
}

plant_marker 951 $'pid 4242 at 2026-10-05T00:00:00Z\n'
post_with 951 ""
[[ $RC -eq 0 ]] && ok "readable marker: exits 0" || fail "readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "readable marker: the skip line shows the marker's own content" "$OUT" "'code-review' @ ${GATEDSHA:0:9} already posted (pid 4242 at 2026-10-05T00:00:00Z)"
[[ "$(pr_comment_calls)" == "0" ]] && ok "readable marker: no 'gh pr comment' call" || fail "readable marker: gh pr comment ran"

plant_marker 952 ''
post_with 952 ""
[[ $RC -eq 0 ]] && ok "empty marker: exits 0 (the comment was posted: the marker is written after it)" || fail "empty marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has   "empty marker: says the marker was empty"  "$OUT" "'code-review' @ ${GATEDSHA:0:9} already posted (empty marker)"
lacks "empty marker: no blank '()' in the line"  "$OUT" "()"
[[ "$(pr_comment_calls)" == "0" ]] && ok "empty marker: no 'gh pr comment' call" || fail "empty marker: gh pr comment ran"

plant_marker 953 $'pid 4242 at 2026-10-05T00:00:00Z\n'
post_with 953 "$CATSTUB"
refused_unreadable "unreadable marker (fast path)" 953

# The same marker under a real permission failure, where the uid makes one possible.
plant_marker 954 $'pid 4242 at 2026-10-05T00:00:00Z\n'
chmod 000 "$(marker_of 954)"
if /bin/cat "$(marker_of 954)" >/dev/null 2>&1; then
  ok "(uid $(id -u) reads a chmod 000 file: the stubbed read failure above is the proof under this uid)"
else
  post_with 954 ""
  [[ $RC -ne 0 ]] && ok "chmod 000 marker: refuses (exit $RC)" || fail "chmod 000 marker: exit 0 — a success for a record never read"
  has   "chmod 000 marker: named as an unreadable done-marker" "$OUT" "unreadable done-marker"
  has   "chmod 000 marker: shows the OS's own error"           "$OUT" "Permission denied"
  lacks "chmod 000 marker: NOT reported as already posted"     "$OUT" "already posted"
  [[ "$(pr_comment_calls)" == "0" ]] && ok "chmod 000 marker: no 'gh pr comment' call" || fail "chmod 000 marker: gh pr comment ran"
fi
chmod 644 "$(marker_of 954)"

# The second look, once the lock is held (section 5's order).
prep_pr 955
RACE_MARKER="$(marker_of 955)" post_with 955 "$TMPD/mkstub"
[[ $RC -eq 0 ]] && ok "second look, readable marker: exits 0" || fail "second look, readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "second look, readable marker: the skip line shows the marker's content" "$OUT" "posted concurrently (pid other-caller at race)"
[[ "$(pr_comment_calls)" == "0" ]] && ok "second look, readable marker: no 'gh pr comment' call" || fail "second look, readable marker: gh pr comment ran"
prep_pr 956
RACE_MARKER="$(marker_of 956)" post_with 956 "$TMPD/mkstub:$CATSTUB"
refused_unreadable "unreadable marker (second look under the lock)" 956

# The poll loop: the lock is held by another caller, whose marker is there on the first look.
prep_pr 957
RACE_MARKER="$(marker_of 957)" post_with 957 "$HOLDSTUB"
[[ $RC -eq 0 ]] && ok "lock held, readable marker: exits 0" || fail "lock held, readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "lock held, readable marker: the skip line shows the marker's content" "$OUT" "posted concurrently (pid other-caller at race)"
[[ "$(pr_comment_calls)" == "0" ]] && ok "lock held, readable marker: no 'gh pr comment' call" || fail "lock held, readable marker: gh pr comment ran"
prep_pr 958
RACE_MARKER="$(marker_of 958)" post_with 958 "$HOLDSTUB:$CATSTUB"
refused_unreadable "unreadable marker (poll loop)" 958

echo
[[ $FAILED -eq 0 ]] && echo "all gate-post once-only and done-marker-read checks passed" || echo "FAILURES"
exit $FAILED

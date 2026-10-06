#!/bin/bash
# Two #2285 Round 2 changes to velo-merge, both exercised against the REAL
# script under a stubbed `gh` (same reason test_merge_gates.sh does it this
# way):
#
#   1. An .agents/-only PR (CODE>0 via the bin|rules|skills|tasks sum, so
#      gating still applies) with NO CI checks at all — the ci.yml
#      paths-ignore shape, not a broken build — now merges with a warn
#      instead of a die. Any OTHER code PR with no CI still dies.
#   2. The merge-once guard: two callers that can legitimately race (a
#      session's own --wait loop and velo-orchestrd's step_merge) must never
#      both call `gh pr merge` for the same (pr, head-sha).
#
# And (#2380) a FAILED `gh pr view` — network, rate limit, auth, anything gh
# does not recognise — is never reported as "PR #N not found", which --wait
# reads as definitive (section 5).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
MERGE="$BIN/velo-merge"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$MERGE" ]] || { fail "velo-merge not found at $MERGE"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
CALLS_LOG="$TMPD/calls.log"
HEADSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# `gh` stub: PR_JSON (env) is the full `pr view` payload; `pr merge` records
# a call and succeeds unless GH_MERGE_RC is set nonzero.
#
# GH_VIEW_FAIL_RC (env), when set, makes `pr view` exit with that status, printing
# GH_VIEW_FAIL_ERR (may be empty) on stderr — for the first GH_VIEW_FAIL_N calls
# (default: all of them), counted from this stub's own CALLS_LOG line, so a
# --wait loop that re-invokes velo-merge sees the failure clear after N attempts.
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$CALLS_LOG"
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ -n "${GH_VIEW_FAIL_RC:-}" ]]; then
    views=$(grep -c '^pr view' "$CALLS_LOG")
    if [[ "$views" -le "${GH_VIEW_FAIL_N:-999999}" ]]; then
      [[ -n "${GH_VIEW_FAIL_ERR:-}" ]] && printf '%s\n' "$GH_VIEW_FAIL_ERR" >&2
      exit "$GH_VIEW_FAIL_RC"
    fi
  fi
  echo "$PR_JSON"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  exit "${GH_MERGE_RC:-0}"
fi
echo ""; exit 0
EOF
chmod +x "$TMPD/bin/gh"
export PATH="$TMPD/bin:$PATH"
export CALLS_LOG

VELO_STATE="$TMPD/state"
export VELO_STATE

# `grep -c` exits 1 (not 0) when the count is legitimately zero — its count
# convention is "print N", its EXIT convention is "were there matches at
# all". A `|| echo 0` fallback on that exit status would then print a SECOND
# "0" on top of the first, corrupting the very count it exists to normalize
# for the empty case. Not chaining on the exit status is the fix: the file
# always exists by the time this runs (created by `: > "$CALLS_LOG"` before
# every case below), so there is nothing left for a fallback to catch.
pr_merge_calls() { grep -c '^pr merge' "$CALLS_LOG"; }

mk_pr_json() {   # files_json labels_json mergeable ci_json
  jq -cn --arg head "$HEADSHA" --argjson files "$1" --argjson labels "$2" \
     --arg mergeable "$3" --argjson ci "$4" '
    { headRefOid: $head, state: "OPEN", title: "t",
      mergeable: $mergeable, files: $files, labels: $labels,
      statusCheckRollup: $ci }'
}

# ---- 1: an .agents/-only PR with NO CI merges (warn, not die) -------------
# CODE>0 needs bin/ (or rules|skills|tasks) in the diff, not just any
# .agents/ path — a hooks-only or docs-only PR already hits the PRE-EXISTING
# "CODE -eq 0" branch and proves nothing new. --force sidesteps this test's
# ONE unrelated dependency: the gate-name cross-check further down shells out
# to the REAL ~/.agents/bin/velo-gate (a hardcoded path, not overridable),
# which this sandboxed run has no business invoking. The CI-none/AGENTS_ONLY
# branch under test runs BEFORE that section and does not itself consult
# FORCE, so --force does not weaken what is actually being asserted here.
FILES1='["path"]'  # placeholder, replaced below via --argjson
PR_JSON=$(mk_pr_json '[{"path":".agents/bin/velo-example"}]' '["gate:passed"]' MERGEABLE '[]')
export PR_JSON
: > "$CALLS_LOG"
OUT1=$("$MERGE" 601 --force 2>&1); RC1=$?
if [[ $RC1 -eq 0 ]]; then
  ok ".agents/-only PR with no CI merges under --force"
else
  fail ".agents/-only PR with no CI was refused: rc=$RC1 $(tr '\n' ' ' <<<"$OUT1" | cut -c1-300)"
fi
if grep -qi 'expected for an .agents/-only PR' <<<"$OUT1"; then
  ok "the acceptance is a stated warn, not a silent pass"
else
  fail "no .agents/-only warn message found: $(tr '\n' ' ' <<<"$OUT1" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "1" ]]; then
  ok "gh pr merge was actually called for the accepted .agents/-only PR"
else
  fail "expected 1 pr-merge call, got $(pr_merge_calls)"
fi

# ---- 2: a NON-.agents/ code PR with no CI still dies -----------------------
PR_JSON=$(mk_pr_json '[{"path":"src/foo.rs"}]' '["gate:passed"]' MERGEABLE '[]')
export PR_JSON
: > "$CALLS_LOG"
OUT2=$("$MERGE" 602 --force 2>&1); RC2=$?
if [[ $RC2 -ne 0 ]]; then
  ok "a src/ PR with no CI still refuses — the exception is scoped to .agents/-only"
else
  fail "a src/ PR with no CI was allowed through: $(tr '\n' ' ' <<<"$OUT2" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "0" ]]; then
  ok "no merge attempted for the refused src/ PR"
else
  fail "a merge was attempted despite the refusal"
fi

# ---- 3: the merge-once guard — a sequential repeat is a silent no-op ------
PR_JSON=$(mk_pr_json '[{"path":"docs/x.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
OUT3=$("$MERGE" 603 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "first merge of a docs PR exits 0" || fail "first merge exited $RC3: $(tr '\n' ' ' <<<"$OUT3" | cut -c1-300)"
OUT4=$("$MERGE" 603 2>&1); RC4=$?
[[ $RC4 -eq 0 ]] && ok "repeat merge call also exits 0" || fail "repeat merge exited $RC4: $(tr '\n' ' ' <<<"$OUT4" | cut -c1-300)"
if grep -qi 'already merged' <<<"$OUT4"; then
  ok "repeat merge reports it is skipping, not silent"
else
  fail "repeat merge gave no idempotency message: $(tr '\n' ' ' <<<"$OUT4" | cut -c1-300)"
fi
if [[ "$(pr_merge_calls)" == "1" ]]; then
  ok "exactly one 'gh pr merge' call across both invocations — no double-merge"
else
  fail "expected exactly 1 pr-merge call across both calls, got $(pr_merge_calls)"
fi

# ---- 4: MUTATION-PROOF — the merge-once done-marker checks -----------------
# The guard looks at the marker TWICE: before the lock (the fast path) and again once the
# lock is held (a caller that was delayed between the two). Either alone keeps a
# sequential repeat from merging twice — so this proof removes BOTH; each look on its own
# is pinned by section 7.
BACKUP="$TMPD/velo-merge.backup"
cp "$MERGE" "$BACKUP"
python3 - "$MERGE" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$MERGE_DONE" ]]; then\n  read_marker "$MERGE_DONE"\n  ok "already merged @ $SHORT ($MARKER_TEXT) — skipping (idempotent)"\n  exit 0\nfi\n'
old2 = 'if [[ -f "$MERGE_DONE" ]]; then\n  read_marker "$MERGE_DONE"\n  ok "merged concurrently @ $SHORT ($MARKER_TEXT) — skipping"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert old in t, "merge-once done-marker check not found verbatim — did it change shape?"
assert old2 in t, "merge-once second look at the done-marker not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1).replace(old2, new, 1))
PYEOF
PR_JSON=$(mk_pr_json '[{"path":"docs/y.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
"$MERGE" 604 >/dev/null 2>&1
"$MERGE" 604 >/dev/null 2>&1
MUT_CALLS=$(pr_merge_calls)
cp "$BACKUP" "$MERGE"
if diff -q "$BACKUP" "$MERGE" >/dev/null; then
  ok "velo-merge restored byte-identical after the mutation"
else
  fail "velo-merge did NOT restore cleanly — check $MERGE by hand"
fi
if [[ "$MUT_CALLS" -ge 2 ]]; then
  ok "MUTATION-PROOF red: with both done-marker checks disabled, the same head merges twice ($MUT_CALLS calls)"
else
  fail "mutation-proof did not go RED: expected >=2 pr-merge calls with the guard disabled, got $MUT_CALLS"
fi
PR_JSON=$(mk_pr_json '[{"path":"docs/z.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
export PR_JSON
: > "$CALLS_LOG"
"$MERGE" 605 >/dev/null 2>&1
"$MERGE" 605 >/dev/null 2>&1
RESTORED_CALLS=$(pr_merge_calls)
if [[ "$RESTORED_CALLS" == "1" ]]; then
  ok "MUTATION-PROOF green: restored file merges exactly once again"
else
  fail "restored file still double-merges: $RESTORED_CALLS calls — restore did not take"
fi

# ---- 5: a FAILED `gh pr view` is never reported as "PR #N not found" (#2380) --
#
# `gh pr view` exits non-zero for a PR that does not exist AND for a dead network,
# an exhausted rate limit, an expired token and a 5xx. velo-merge sent gh's stderr
# to /dev/null and called every one of them "PR #N not found"; --wait treats that
# as DEFINITIVE, so one blip ended a wait on an open PR whose CI was pending (#2281,
# attempt 17). The stderr texts below are what gh printed when probed on
# 2026-10-05 (not-found, bad token) or its documented wording (the rest).
NF_ERR='GraphQL: Could not resolve to a PullRequest with the number of 99999999. (repository.pullRequest)'
AUTH_ERR=$'HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login -h github.com'
RATE_ERR='GraphQL: API rate limit already exceeded for user ID 12345.'
NET_ERR='Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host'
ODD_ERR='something no gh release has ever said'
READ_JSON=$(mk_pr_json '[{"path":"docs/read.md"}]' '[]' MERGEABLE '[{"conclusion":"SUCCESS","name":"Build"}]')
pr_view_calls() { grep -c '^pr view' "$CALLS_LOG"; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-320)"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then fail "$1: did NOT want '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-320)"; else ok "$1"; fi; }
# Single-shot: gh fails EVERY call. Sets OUT and RC.
read_fails() {   # <pr> <gh stderr> <gh exit code>
  : > "$CALLS_LOG"
  OUT=$(PR_JSON="$READ_JSON" GH_VIEW_FAIL_ERR="$2" GH_VIEW_FAIL_RC="$3" "$MERGE" "$1" 2>&1); RC=$?
}
# --wait: gh fails the first <n> calls, then answers. Sets OUT and RC.
wait_read() {    # <pr> <gh stderr> <gh exit code> <n failing calls>
  : > "$CALLS_LOG"
  OUT=$(PR_JSON="$READ_JSON" GH_VIEW_FAIL_ERR="$2" GH_VIEW_FAIL_RC="$3" GH_VIEW_FAIL_N="$4" \
        VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=20 "$MERGE" "$1" --wait 2>&1); RC=$?
}

echo
echo "5. a failed PR read says what failed, and only a missing PR is 'not found'"
read_fails 811 "$NF_ERR" 1
[[ $RC -ne 0 ]] && ok "missing PR: refuses" || fail "missing PR: exit 0"
has   "missing PR: reported as not found"          "$OUT" "PR #811 not found"
has   "missing PR: gh's own stderr is printed"     "$OUT" "Could not resolve to a PullRequest"

read_fails 812 "$NET_ERR" 1
[[ $RC -ne 0 ]] && ok "network failure: refuses" || fail "network failure: exit 0"
lacks "network failure: NOT called not found"      "$OUT" "not found"
has   "network failure: names the kind"            "$OUT" "could not read PR #812 (network)"
has   "network failure: gh's own stderr is printed" "$OUT" "no such host"

read_fails 813 "$RATE_ERR" 1
[[ $RC -ne 0 ]] && ok "rate limit: refuses" || fail "rate limit: exit 0"
lacks "rate limit: NOT called not found"           "$OUT" "not found"
has   "rate limit: names the kind"                 "$OUT" "could not read PR #813 (rate-limit)"
has   "rate limit: gh's own stderr is printed"     "$OUT" "rate limit already exceeded"

read_fails 814 "$AUTH_ERR" 1
[[ $RC -ne 0 ]] && ok "auth failure: refuses" || fail "auth failure: exit 0"
lacks "auth failure: NOT called not found"         "$OUT" "not found"
has   "auth failure: names the kind"               "$OUT" "could not read PR #814 (auth)"
has   "auth failure: gh's own stderr is printed (every line)" "$OUT" "gh auth login"

read_fails 815 "$ODD_ERR" 4
[[ $RC -ne 0 ]] && ok "unrecognised failure: refuses" || fail "unrecognised failure: exit 0"
lacks "unrecognised failure: NOT called not found" "$OUT" "not found"
has   "unrecognised failure: names the kind"       "$OUT" "could not read PR #815 (other)"
has   "unrecognised failure: gh's own stderr is printed" "$OUT" "something no gh release has ever said"
has   "unrecognised failure: the exit status is printed" "$OUT" "exited 4"

read_fails 816 "" 1
[[ $RC -ne 0 ]] && ok "failure with NO stderr: refuses" || fail "failure with NO stderr: exit 0"
lacks "failure with NO stderr: NOT called not found" "$OUT" "not found"
has   "failure with NO stderr: says gh printed nothing" "$OUT" "gh printed nothing on stderr"

if [[ "$(pr_merge_calls)" == "0" ]]; then
  ok "no merge attempted after any failed read"
else
  fail "a merge was attempted after a failed read: $(pr_merge_calls)"
fi

echo
echo "   --wait retries only what clears on its own"
wait_read 821 "$NET_ERR" 1 2
[[ $RC -eq 0 ]] && ok "--wait: a network blip is retried, then the PR merges" \
                || fail "--wait: gave up on a transient network failure: rc=$RC $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
[[ "$(pr_view_calls)" == "3" ]] && ok "--wait: 2 failed reads + 1 good read (3 attempts)" \
                                || fail "--wait: expected 3 pr-view calls, got $(pr_view_calls)"
[[ "$(pr_merge_calls)" == "1" ]] && ok "--wait: merged exactly once after the retry" \
                                 || fail "--wait: expected 1 merge, got $(pr_merge_calls)"

wait_read 822 "$RATE_ERR" 1 1
[[ $RC -eq 0 ]] && ok "--wait: a rate limit is retried, then the PR merges" \
                || fail "--wait: gave up on a rate limit: rc=$RC $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"

wait_read 823 "$NF_ERR" 1 999999
[[ $RC -ne 0 ]] && ok "--wait: a missing PR stops the wait" || fail "--wait: exit 0 on a missing PR"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: a missing PR is read once, not retried" \
                                || fail "--wait: a missing PR was read $(pr_view_calls) times"
has "--wait: says the failure is definitive" "$OUT" "definitive failure"

wait_read 824 "$AUTH_ERR" 1 999999
[[ $RC -ne 0 ]] && ok "--wait: an auth failure stops the wait" || fail "--wait: exit 0 on an auth failure"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: an auth failure is read once, not retried for hours" \
                                || fail "--wait: an auth failure was read $(pr_view_calls) times"

wait_read 825 "$ODD_ERR" 4 999999
[[ $RC -ne 0 ]] && ok "--wait: an unrecognised failure stops the wait" || fail "--wait: exit 0 on an unrecognised failure"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: an unrecognised failure is shown at once, not retried silently" \
                                || fail "--wait: an unrecognised failure was read $(pr_view_calls) times"
has "--wait: the unrecognised failure's own text reaches the caller" "$OUT" "something no gh release has ever said"

# ---- 6: a read that exits 0 but is not a PR gets its own named error (#2380 r2) --
#
# gh did not FAIL, so none of section 5's kinds applies — and the jq reads that
# followed either failed in jq's own words or printed nothing and were taken as an
# empty value: an empty body gave "PR #N is " (a blank state), which --wait, seeing
# no definitive text, would have polled for six hours.
read_payload() {   # <pr> <payload>: gh exits 0 and prints exactly this. Sets OUT and RC.
  : > "$CALLS_LOG"
  OUT=$(PR_JSON="$2" "$MERGE" "$1" 2>&1); RC=$?
}
wait_payload() {   # <pr> <payload>, under --wait. Sets OUT and RC.
  : > "$CALLS_LOG"
  OUT=$(PR_JSON="$2" VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=5 "$MERGE" "$1" --wait 2>&1); RC=$?
}
payload_case() {   # <pr> <label> <payload> <fragment of the reason>
  read_payload "$1" "$3"
  [[ $RC -ne 0 ]] && ok "$2: refuses" || fail "$2: exit 0"
  has   "$2: named as a payload failure"   "$OUT" "could not read PR #$1 (payload)"
  has   "$2: says what is wrong"           "$OUT" "$4"
  has   "$2: says gh itself exited 0"      "$OUT" "gh pr view exited 0"
  lacks "$2: no blank-state message"       "$OUT" "PR #$1 is "
  lacks "$2: not called not found"         "$OUT" "not found"
  [[ "$(pr_merge_calls)" == "0" ]] && ok "$2: no merge attempted" || fail "$2: a merge was attempted"
}

echo
echo "6. a read that exits 0 but is not a PR gets its own named error"
payload_case 911 "empty body"          ''                                                     "printed nothing"
payload_case 912 "whitespace body"     $'  \n '                                               "printed nothing"
payload_case 913 "truncated JSON"      '{"headRefOid":"aaa","state":"OPEN","title":"t'         "could not be parsed"
has "truncated JSON: shows what gh printed" "$OUT" '"title":"t'
payload_case 914 "an HTML error page"  '<html><body>502 Bad Gateway</body></html>'            "could not be parsed"
payload_case 915 "JSON null"           'null'                                                 "a JSON null, not a PR object"
payload_case 916 "a JSON array"        '[]'                                                   "a JSON array, not a PR object"
payload_case 917 "two JSON values"     '{} {}'                                                "printed 2 JSON values"
payload_case 918 "an empty object"     '{}'                                                   "headRefOid is missing"
payload_case 919 "a mistyped field"    "$(jq -c '.state = 1' <<<"$READ_JSON")"                "state has type number"
payload_case 920 "a missing field"     "$(jq -c 'del(.statusCheckRollup)' <<<"$READ_JSON")"   "statusCheckRollup is missing"

# The check must not over-reject: gh returns a null rollup for a PR no workflow ran on.
read_payload 925 "$(jq -c '.statusCheckRollup = null' <<<"$READ_JSON")"
[[ $RC -eq 0 ]] && ok "a null statusCheckRollup is a usable payload" \
                || fail "a null statusCheckRollup was refused: rc=$RC $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
[[ "$(pr_merge_calls)" == "1" ]] && ok "and the PR merges" || fail "expected 1 merge, got $(pr_merge_calls)"

echo
echo "   --wait does not poll a payload that is not a PR"
wait_payload 931 ''
[[ $RC -ne 0 ]] && ok "--wait: an empty body stops the wait" || fail "--wait: exit 0 on an empty body"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: an empty body is read once, not polled for hours" \
                                || fail "--wait: an empty body was read $(pr_view_calls) times"
has "--wait: says the failure is definitive" "$OUT" "definitive failure"
wait_payload 932 '{"headRefOid":"aaa","state":"OPEN","title":"t'
[[ $RC -ne 0 ]] && ok "--wait: a truncated body stops the wait" || fail "--wait: exit 0 on a truncated body"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: a truncated body is read once" \
                                || fail "--wait: a truncated body was read $(pr_view_calls) times"

# ---- 7: the done-marker is checked AGAIN once the lock is held (#2380 r2) --------
# Section 3 is a repeat call after the first finished. This is the narrower order: a
# caller that checked the marker (absent), was delayed, and takes the lock only AFTER
# the first one finished — marker written, lock released. Nothing in the script lets a
# test stand between its marker check and its mkdir, so `mkdir` is a stub that models
# exactly that: asked for the LOCK, it first writes the marker (the other caller
# finishing), then makes the directory. A script that does not look again calls
# `gh pr merge` on a head that is already merged.
MKSTUB="$TMPD/mkstub"; mkdir -p "$MKSTUB"
cat > "$MKSTUB/mkdir" <<'EOF'
#!/bin/bash
last=""; for a in "$@"; do last="$a"; done
if [[ "$last" == *.merging-*.lock && -n "${RACE_MARKER:-}" ]]; then
  printf 'pid other-caller at race\n' > "$RACE_MARKER"
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$MKSTUB/mkdir"
echo
echo "7. the done-marker is looked at again once the lock is held"
: > "$CALLS_LOG"
OUT7=$(PATH="$MKSTUB:$PATH" RACE_MARKER="$VELO_STATE/gate/941/.merged-${HEADSHA:0:9}" PR_JSON="$READ_JSON" "$MERGE" 941 2>&1); RC7=$?
[[ $RC7 -eq 0 ]] && ok "a caller that takes the lock after the first finished exits 0" \
                 || fail "late-lock caller exited $RC7: $(tr '\n' ' ' <<<"$OUT7" | cut -c1-300)"
has "and says it found the head already merged" "$OUT7" "merged concurrently"
[[ "$(pr_merge_calls)" == "0" ]] && ok "and made NO 'gh pr merge' call: the head is merged exactly once" \
                                 || fail "late-lock caller ran gh pr merge AGAIN: $(pr_merge_calls) call(s)"
[[ ! -d "$VELO_STATE/gate/941/.merging-${HEADSHA:0:9}.lock" ]] && ok "and released the lock it took" \
                                                               || fail "late-lock caller left its lock behind"

# MUTATION-PROOF: the second look alone is what covers this order.
BACKUP7="$TMPD/velo-merge.backup7"
cp "$MERGE" "$BACKUP7"
python3 - "$MERGE" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [[ -f "$MERGE_DONE" ]]; then\n  read_marker "$MERGE_DONE"\n  ok "merged concurrently @ $SHORT ($MARKER_TEXT) — skipping"\n  exit 0\nfi\n'
new = 'if false; then\n  ok "mutated out for test"\n  exit 0\nfi\n'
assert t.count(old) == 1, "merge-once second look at the done-marker not found verbatim — did it change shape?"
open(p, "w").write(t.replace(old, new, 1))
PYEOF
: > "$CALLS_LOG"
PATH="$MKSTUB:$PATH" RACE_MARKER="$VELO_STATE/gate/942/.merged-${HEADSHA:0:9}" PR_JSON="$READ_JSON" "$MERGE" 942 >/dev/null 2>&1
MUT7_CALLS=$(pr_merge_calls)
cp "$BACKUP7" "$MERGE"
diff -q "$BACKUP7" "$MERGE" >/dev/null && ok "velo-merge restored byte-identical after the second mutation" \
                                       || fail "velo-merge did NOT restore cleanly — check $MERGE by hand"
[[ "$MUT7_CALLS" -ge 1 ]] && ok "MUTATION-PROOF red: without the second look, a late-lock caller merges an already-merged head ($MUT7_CALLS call)" \
                          || fail "mutation-proof did not go RED: expected >=1 pr-merge call without the second look, got $MUT7_CALLS"
: > "$CALLS_LOG"
PATH="$MKSTUB:$PATH" RACE_MARKER="$VELO_STATE/gate/943/.merged-${HEADSHA:0:9}" PR_JSON="$READ_JSON" "$MERGE" 943 >/dev/null 2>&1
[[ "$(pr_merge_calls)" == "0" ]] && ok "MUTATION-PROOF green: the restored file makes no merge call in that order" \
                                 || fail "the restored file still merges in the late-lock order: $(pr_merge_calls) call(s)"

# ---- 8: a done-marker that EXISTS but cannot be read is an error, not a success (#2380 r3) --
#
# The guards act on the marker's existence; its content is the "who and when" in the skip
# line. The content used to be read with `$(cat "$MERGE_DONE" 2>/dev/null)`: a failed read
# printed "already merged ()" and exited 0 — a success line for a record never read. The
# three states are told apart now: absent (the guard does not fire), unreadable (refuse,
# naming the file and cat's own error), empty (still proof the merge ran: skip, and say
# the marker was empty rather than print "()").
#
# `cat` is a stub for the unreadable case because root reads a chmod 000 file and this suite
# runs under any uid; it stands for EIO, a stale NFS handle, a state dir owned by another user.
CATSTUB="$TMPD/catstub"; mkdir -p "$CATSTUB"
cat > "$CATSTUB/cat" <<'EOF'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == */.merged-* ]]; then
    echo "cat: $a: Input/output error" >&2
    exit 1
  fi
done
exec /bin/cat "$@"
EOF
chmod +x "$CATSTUB/cat"
# A `mkdir` that reports the lock as held by someone else: the other caller has finished by
# the time this one looks (it writes the marker), and the lock was still taken when this one
# tried — the order that sends a caller into the poll loop.
HOLDSTUB="$TMPD/holdstub"; mkdir -p "$HOLDSTUB"
cat > "$HOLDSTUB/mkdir" <<'EOF'
#!/bin/bash
last=""; for a in "$@"; do last="$a"; done
if [[ "$last" == *.merging-*.lock ]]; then
  [[ -n "${RACE_MARKER:-}" ]] && printf 'pid other-caller at race\n' > "$RACE_MARKER"
  echo "mkdir: $last: File exists" >&2
  exit 1
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$HOLDSTUB/mkdir"
marker_of() { printf '%s' "$VELO_STATE/gate/$1/.merged-${HEADSHA:0:9}"; }   # <pr>
plant_marker() {   # <pr> <exact content>: a done-marker for (pr, HEADSHA)
  mkdir -p "$VELO_STATE/gate/$1"
  printf '%s' "$2" > "$(marker_of "$1")"
}
lock_of() { printf '%s' "$VELO_STATE/gate/$1/.merging-${HEADSHA:0:9}.lock"; }   # <pr>
# Run velo-merge for <pr> under the given PATH prefix. Sets OUT and RC; clears the call log.
merge_with() {   # <pr> <PATH prefix or ''> [extra args]
  local pr="$1" pre="$2"; shift 2
  : > "$CALLS_LOG"
  OUT=$(PATH="${pre:+$pre:}$PATH" PR_JSON="$READ_JSON" "$MERGE" "$pr" "$@" 2>&1); RC=$?
}
refused_unreadable() {   # <label> <pr>: the shared expectations of an unreadable marker
  [[ $RC -ne 0 ]] && ok "$1: refuses (exit $RC)" || fail "$1: exit 0 — a success for a record it never read"
  has   "$1: named as an unreadable done-marker" "$OUT" "unreadable done-marker"
  has   "$1: names the marker file"              "$OUT" ".merged-${HEADSHA:0:9}"
  has   "$1: shows cat's own error"              "$OUT" "Input/output error"
  lacks "$1: NOT reported as already merged"     "$OUT" "already merged"
  lacks "$1: NOT reported as merged concurrently" "$OUT" "merged concurrently"
  [[ "$(pr_merge_calls)" == "0" ]] && ok "$1: no 'gh pr merge' call" || fail "$1: gh pr merge ran: $(pr_merge_calls) call(s)"
  [[ ! -d "$(lock_of "$2")" ]] && ok "$1: no lock left behind" || fail "$1: left $(lock_of "$2") behind"
}

echo
echo "8. a done-marker that exists but cannot be read is an error, not a success"
plant_marker 951 $'pid 4242 at 2026-10-05T00:00:00Z\n'
merge_with 951 ""
[[ $RC -eq 0 ]] && ok "readable marker: exits 0" || fail "readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "readable marker: the skip line shows the marker's own content" "$OUT" "already merged @ ${HEADSHA:0:9} (pid 4242 at 2026-10-05T00:00:00Z)"
[[ "$(pr_merge_calls)" == "0" ]] && ok "readable marker: no 'gh pr merge' call" || fail "readable marker: gh pr merge ran"

plant_marker 952 ''
merge_with 952 ""
[[ $RC -eq 0 ]] && ok "empty marker: exits 0 (the merge ran: the marker is written after it)" || fail "empty marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has   "empty marker: says the marker was empty"      "$OUT" "already merged @ ${HEADSHA:0:9} (empty marker)"
lacks "empty marker: no blank '()' in the line"      "$OUT" "()"
[[ "$(pr_merge_calls)" == "0" ]] && ok "empty marker: no 'gh pr merge' call" || fail "empty marker: gh pr merge ran"

plant_marker 953 $'pid 4242 at 2026-10-05T00:00:00Z\n'
merge_with 953 "$CATSTUB"
refused_unreadable "unreadable marker (fast path)" 953

# The same marker under a real permission failure, where the uid makes one possible.
plant_marker 954 $'pid 4242 at 2026-10-05T00:00:00Z\n'
chmod 000 "$(marker_of 954)"
if /bin/cat "$(marker_of 954)" >/dev/null 2>&1; then
  ok "(uid $(id -u) reads a chmod 000 file: the stubbed read failure above is the proof under this uid)"
else
  merge_with 954 ""
  [[ $RC -ne 0 ]] && ok "chmod 000 marker: refuses (exit $RC)" || fail "chmod 000 marker: exit 0 — a success for a record never read"
  has   "chmod 000 marker: named as an unreadable done-marker" "$OUT" "unreadable done-marker"
  has   "chmod 000 marker: shows the OS's own error"           "$OUT" "Permission denied"
  lacks "chmod 000 marker: NOT reported as already merged"     "$OUT" "already merged"
  [[ "$(pr_merge_calls)" == "0" ]] && ok "chmod 000 marker: no 'gh pr merge' call" || fail "chmod 000 marker: gh pr merge ran"
fi
chmod 644 "$(marker_of 954)"

# The second look, once the lock is held (section 7's order), with a marker that cannot be read.
RACE_MARKER="$(marker_of 955)" merge_with 955 "$MKSTUB"
[[ $RC -eq 0 ]] && ok "second look, readable marker: exits 0" || fail "second look, readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "second look, readable marker: the skip line shows the marker's content" "$OUT" "merged concurrently @ ${HEADSHA:0:9} (pid other-caller at race)"
[[ "$(pr_merge_calls)" == "0" ]] && ok "second look, readable marker: no 'gh pr merge' call" || fail "second look, readable marker: gh pr merge ran"
RACE_MARKER="$(marker_of 956)" merge_with 956 "$MKSTUB:$CATSTUB"
refused_unreadable "unreadable marker (second look under the lock)" 956

# The poll loop: the lock is held by another caller, whose marker is there on the first look.
RACE_MARKER="$(marker_of 957)" merge_with 957 "$HOLDSTUB"
[[ $RC -eq 0 ]] && ok "lock held, readable marker: exits 0" || fail "lock held, readable marker: exit $RC: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
has "lock held, readable marker: the skip line shows the marker's content" "$OUT" "merged concurrently @ ${HEADSHA:0:9} (pid other-caller at race)"
[[ "$(pr_merge_calls)" == "0" ]] && ok "lock held, readable marker: no 'gh pr merge' call" || fail "lock held, readable marker: gh pr merge ran"
RACE_MARKER="$(marker_of 958)" merge_with 958 "$HOLDSTUB:$CATSTUB"
refused_unreadable "unreadable marker (poll loop)" 958

# --wait must not poll an error that waiting cannot fix: the marker stays unreadable until
# someone repairs the file, so the wait would run to its 6h limit.
plant_marker 959 $'pid 4242 at 2026-10-05T00:00:00Z\n'
: > "$CALLS_LOG"
OUT=$(PATH="$CATSTUB:$PATH" PR_JSON="$READ_JSON" VELO_MERGE_WAIT_INTERVAL=0 VELO_MERGE_WAIT_MAX=5 "$MERGE" 959 --wait 2>&1); RC=$?
[[ $RC -ne 0 ]] && ok "--wait: an unreadable marker stops the wait" || fail "--wait: exit 0 on an unreadable marker"
[[ "$(pr_view_calls)" == "1" ]] && ok "--wait: an unreadable marker is read once, not polled for hours" \
                                || fail "--wait: an unreadable marker was read $(pr_view_calls) times"
has "--wait: says the failure is definitive" "$OUT" "definitive failure"
has "--wait: the marker's own error reaches the caller" "$OUT" "Input/output error"

echo
[[ $FAILED -eq 0 ]] && echo "all merge once-only / .agents-only-CI / read-failure / payload / done-marker-read checks passed" || echo "FAILURES"
exit $FAILED

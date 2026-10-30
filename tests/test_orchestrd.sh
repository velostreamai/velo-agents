#!/usr/bin/env bash
# velo-orchestrd must detect, post, merge, dispatch and escalate exactly once
# per real-world fact — never zero times (a finding sits unprocessed for
# hours, #2285's whole root cause) and never twice (a duplicate PR comment, a
# double merge attempt).
#
# Drives the REAL script under a stubbed `gh` and a sandboxed VELO_STATE, not
# a reimplementation of its logic — same reason test_merge_gates.sh and
# test_gate_post_sha.sh do it this way.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
ORCHD="$BIN/velo-orchestrd"
RC=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; RC=1; }

[[ -x "$ORCHD" ]] || { fail "velo-orchestrd not found at $ORCHD"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FIX="$T/fixtures"; mkdir -p "$FIX"
CALLS_LOG="$T/calls.log"
STATE="$T/state"
LIVE_PIDS=""
# spawn_live_worker runs inside $(...), so its LIVE_PIDS+= never reaches this
# shell; reap by path instead. Every fake runner lives under $T, and its own
# `sleep` child does not name $T, so kill children first (4 x sleep 120 leaked
# per run).
kill_live() {
  local p
  for p in $LIVE_PIDS $(pgrep -f "$T/"); do pkill -P "$p"; kill "$p"; done 2>/dev/null
}
trap 'kill_live; rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUBEOF'
#!/bin/bash
echo "$*" >> "$CALLS_LOG"

get_flag() {   # --flagname  ->  its value, from the full original argv
  local want="$1"; shift
  local prev=""
  for a in "$@"; do
    [[ "$prev" == "$want" ]] && { printf '%s' "$a"; return; }
    prev="$a"
  done
}

if [[ "$1" == "auth" ]]; then
  exit "${GH_AUTH_RC:-0}"
fi

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  LABEL=$(get_flag --label "$@")
  SLUG=$(printf '%s' "$LABEL" | tr ':' '-')
  RAW="$FIX/list_${SLUG}.json"
  NUMS=$(jq -r '.[].number' "$RAW" 2>/dev/null)
  OUT="[]"
  for N in $NUMS; do
    [[ -f "$FIX/pr_${N}.merged" ]] && continue
    OUT=$(jq -c --argjson n "$N" '. + [{number:$n}]' <<<"$OUT")
  done
  echo "$OUT"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  NUM="$3"
  BASE=$(cat "$FIX/pr_${NUM}.json" 2>/dev/null || echo '{}')
  DIR="$FIX/pr_${NUM}.posted-comments"
  if [[ -d "$DIR" ]]; then
    for f in "$DIR"/*.txt; do
      [[ -f "$f" ]] || continue
      BODY_TXT=$(cat "$f")
      BASE=$(jq --arg b "$BODY_TXT" '.comments = ((.comments // []) + [{body:$b}])' <<<"$BASE")
    done
  fi
  FILT=$(get_flag --jq "$@")
  if [[ -n "$FILT" ]]; then jq -r "$FILT" <<<"$BASE"; else echo "$BASE"; fi
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  NUM="$3"
  BODY=$(get_flag --body "$@")
  DIR="$FIX/pr_${NUM}.posted-comments"
  mkdir -p "$DIR"
  IDX=$(( $(ls "$DIR" 2>/dev/null | wc -l | tr -d ' ') + 1 ))
  printf '%s' "$BODY" > "$DIR/$(printf '%04d' "$IDX").txt"
  echo "https://github.com/x/y/pull/${NUM}#issuecomment-stub-${IDX}"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  NUM="$3"
  RC_VAR="GH_MERGE_RC_${NUM}"
  RCV="${!RC_VAR:-0}"
  [[ "$RCV" -eq 0 ]] && touch "$FIX/pr_${NUM}.merged"
  exit "$RCV"
fi

if [[ "$1" == "issue" && "$2" == "view" ]]; then
  NUM="$3"
  # GH_ISSUE_FAIL_<n>=1 makes the read of issue <n> fail the way a dropped connection does.
  FAILVAR="GH_ISSUE_FAIL_${NUM}"
  if [[ -n "${!FAILVAR:-}" ]]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
  BASE=$(cat "$FIX/issue_${NUM}.json" 2>/dev/null || echo '{}')
  FILT=$(get_flag --jq "$@")
  if [[ -n "$FILT" ]]; then jq -r "$FILT" <<<"$BASE"; else echo "$BASE"; fi
  exit 0
fi

echo '{}'; exit 0
STUBEOF
chmod +x "$T/bin/gh"

# velo-dispatch itself (preflight against a real issue, real worktree cut, real
# discovery index) is out of scope for this suite — it has its own tests. Only
# the WIP-cap / queue-popping DECISION to call it is under test here.
cat > "$T/bin/velo-dispatch" <<'DISPATCHEOF'
#!/bin/bash
echo "FAKE-DISPATCH $*"
exit 0
DISPATCHEOF
chmod +x "$T/bin/velo-dispatch"
export VELO_DISPATCH_BIN="$T/bin/velo-dispatch"

# step_dispatch asks `df -Pk` how much is free where $HOME is, and pauses under VELO_ORCH_MIN_DISK_GB (25). What it does with a dispatch
# is under test here, not the disk of the host that runs the suite (a hosted runner has about 10 GB free), so df is a stub: 900 GiB
# free unless a scenario sets DF_FREE_GIB (section 18 does, both ways).
cat > "$T/bin/df" <<'STUBEOF'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1048576000 0 %s 0%% /\n' "$(( ${DF_FREE_GIB:-900} * 1048576 ))"
STUBEOF
chmod +x "$T/bin/df"

export FIX CALLS_LOG
export PATH="$T/bin:$BIN:$PATH"

# ---- fixture builders ---------------------------------------------------------

HEADSHA="1111111111111111111111111111111111111111"
OLDSHA="2222222222222222222222222222222222222222"

mkpr() {   # number head files_json labels_json comments_json [mergeable] [status_json]
  # Defaults are assigned in plain statements, not `${N:-<json-with-braces>}` —
  # bash's parameter-expansion scanner matches the FIRST unescaped `}` as the
  # expansion's own terminator, so a brace-nested JSON default silently
  # truncates and reorders (caught by running this once: it produced
  # `[{"conclusion":"SUCCESS","name":"Build"]}]`, not the intended object).
  local n="$1" head="$2" files="$3" labels="$4" comments="$5"
  local mergeable="${6:-}"; [[ -n "$mergeable" ]] || mergeable="MERGEABLE"
  local status="${7:-}"; [[ -n "$status" ]] || status='[{"conclusion":"SUCCESS","name":"Build"}]'
  # Callers pass plain string arrays (readable); real `gh --json files,labels`
  # returns arrays of OBJECTS ({"path":...}, {"name":...}) — velo-gate/velo-merge
  # read `.files[].path` / `.labels[].name`, so a plain-string fixture silently
  # jq-errors those lines to empty, which used to misclassify every PR as
  # "docs only" regardless of its real files.
  files=$(jq -c '[.[] | {path: .}]' <<<"$files")
  labels=$(jq -c '[.[] | {name: .}]' <<<"$labels")
  jq -cn --arg head "$head" --argjson files "$files" --argjson labels "$labels" \
     --argjson comments "$comments" --arg mergeable "$mergeable" --argjson status "$status" '
    { headRefOid: $head, files: $files, labels: $labels, state: "OPEN",
      title: "test pr", body: "no linked issue here",
      comments: $comments, mergeable: $mergeable, statusCheckRollup: $status }' \
    > "$FIX/pr_${n}.json"
}

list_prs() {   # label numbers...
  local label="$1"; shift
  local slug; slug=$(printf '%s' "$label" | tr ':' '-')
  local arr="[]"
  for n in "$@"; do arr=$(jq -c --argjson n "$n" '. + [{number:$n}]' <<<"$arr"); done
  printf '%s' "$arr" > "$FIX/list_${slug}.json"
}

dead_pid() {   # -> a pid that has definitely already exited
  ( exit 0 ) & local p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

spawn_live_worker() {   # <worktree-dir> -> pid, appended to LIVE_PIDS, matched by orch_running_pid_for
  local wt="$1"
  mkdir -p "$wt"
  local fake="$T/velo-openai-agents-runner.py"
  [[ -f "$fake" ]] || { printf '#!/bin/bash\nsleep 120\n' > "$fake"; chmod +x "$fake"; }
  nohup "$fake" --cwd "$wt" --foo bar >/dev/null 2>&1 &
  local p=$!
  disown "$p" 2>/dev/null   # else bash prints a "Terminated" job-control line when kill_live reaps it
  LIVE_PIDS="$LIVE_PIDS $p"
  printf '%s' "$p"
}

reset_state() {
  rm -rf "$STATE" "$FIX"
  mkdir -p "$STATE" "$FIX"
}

gate_dir() { mkdir -p "$STATE/gate/$1"; printf '%s' "$STATE/gate/$1"; }

run_tick() {   # ORCHD_UNDER_TEST: a mutant copy of the daemon, for the in-suite mutation proofs
  VELO_STATE="$STATE" VELO_ORCH_WORKTREE_GLOB="${VELO_ORCH_WORKTREE_GLOB:-$T/worktrees/velostream-*}" \
    "${ORCHD_UNDER_TEST:-$ORCHD}" tick
}

calls_of() { grep -c "$1" "$CALLS_LOG" 2>/dev/null || true; }   # substring -> count

echo "== 1. detect a finished gate (approve), an appended worker record, CI done =="
reset_state
GD=$(gate_dir 101)
printf '## Codex review — PR 101 @ %s\n**Verdict:** approve\n\nno findings\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 101 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 101
list_prs gate:passed
mkdir -p "$STATE/records"
printf '{"issue":501,"worker":"deepseek","outcome":"landed","dispatched_at":"2026-09-28T00:00:00Z"}\n' > "$STATE/records/501.result.jsonl"
: > "$CALLS_LOG"
OUT=$(run_tick 2>&1)
if grep -q "gate: code-review @ ${HEADSHA:0:9}" "$FIX/pr_101.posted-comments/0001.txt" 2>/dev/null; then
  ok "posted the finished gate's report with the recorded sha header"
else
  fail "did not post, or posted the wrong header: $(cat "$FIX/pr_101.posted-comments/0001.txt" 2>/dev/null | head -1)"
fi
if grep -q "pr edit 101.*gate:passed" "$CALLS_LOG"; then
  ok "single-gate PR with verdict=approve -> gate:passed"
else
  fail "did not set gate:passed: $(grep 'pr edit 101' "$CALLS_LOG")"
fi
if grep -q '"kind":"worker-finished"' "$STATE/orch/attention.jsonl" 2>/dev/null; then
  ok "appended worker record escalated as worker-finished"
else
  fail "worker-finished record did not escalate"
fi

echo
echo "== 2. escalation lines are well-formed and never duplicated =="
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
N=$(grep -c '"kind":"worker-finished"' "$STATE/orch/attention.jsonl" 2>/dev/null || echo 0)
if [[ "$N" -eq 1 ]]; then
  ok "the same worker record is not escalated twice across ticks"
else
  fail "worker-finished escalated $N times, expected 1"
fi
if jq -e . "$STATE/orch/attention.jsonl" >/dev/null 2>&1 || [[ ! -s "$STATE/orch/attention.jsonl" ]]; then
  BAD=0
  while IFS= read -r l; do [[ -n "$l" ]] && { jq -e . <<<"$l" >/dev/null 2>&1 || BAD=1; }; done < "$STATE/orch/attention.jsonl"
  [[ "$BAD" -eq 0 ]] && ok "every attention line is valid JSON" || fail "an attention line is not valid JSON"
fi

echo
echo "== 3. a merge refused when the sha moved does not escalate or merge =="
reset_state
mkpr 202 "$HEADSHA" '["src/bar.rs"]' '["gate:passed"]' \
  "$(jq -cn --arg h1 "gate: code-review @ $OLDSHA" --arg h2 "gate: check-code @ $OLDSHA" \
     '[{body:$h1},{body:$h2}]')"
list_prs gate:passed 202
list_prs gate:running
: > "$CALLS_LOG"
OUT=$(run_tick 2>&1)
if ! grep -q "pr merge 202" "$CALLS_LOG"; then
  ok "stale-gate PR is not merged"
else
  fail "merge was attempted on a stale-gate PR"
fi
if [[ -z "$(grep '"pr":202' "$STATE/orch/attention.jsonl" 2>/dev/null)" ]]; then
  ok "a routine stale-gate refusal does not escalate"
else
  fail "stale-gate refusal escalated, but it is routine/self-healing"
fi

echo
echo "== 4. WIP-cap dispatch =="
reset_state
mkdir -p "$T/worktrees"
BRIEF="$T/brief-301.md"; printf 'do the thing\n' > "$BRIEF"
SHA256=$(shasum -a 256 "$BRIEF" | awk '{print $1}')
mkdir -p "$STATE/orch"
jq -cn --arg issue 301 --arg brief "$BRIEF" --arg worker deepseek --arg s "$SHA256" \
  '{issue:($issue|tonumber), brief:$brief, worker:$worker, brief_sha256:$s}' > "$STATE/orch/queue.jsonl"
jq -cn '{labels:[{name:"worker:deepseek"}]}' > "$FIX/issue_301.json"
list_prs gate:running; list_prs gate:passed
export VELO_ORCH_WORKTREE_GLOB="$T/worktrees/velostream-*"
spawn_live_worker "$T/worktrees/velostream-1" >/dev/null
spawn_live_worker "$T/worktrees/velostream-2" >/dev/null
spawn_live_worker "$T/worktrees/velostream-3" >/dev/null
spawn_live_worker "$T/worktrees/velostream-4" >/dev/null
sleep 1
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if [[ -s "$STATE/orch/queue.jsonl" ]]; then
  ok "at the WIP cap (4/4), the queued item is left queued"
else
  fail "dispatched past the WIP cap"
fi
kill_live
LIVE_PIDS=""
sleep 1
run_tick >/dev/null 2>&1
if [[ ! -s "$STATE/orch/queue.jsonl" ]] || ! grep -q 301 "$STATE/orch/queue.jsonl" 2>/dev/null; then
  ok "under the cap, the queued item is popped and dispatched"
else
  fail "queued item was not popped once under the WIP cap"
fi

echo
echo "== 5. two ticks back to back post and merge nothing twice =="
reset_state
GD=$(gate_dir 303)
printf '## Codex review — PR 303 @ %s\n**Verdict:** approve\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 303 "$HEADSHA" '["src/baz.rs"]' '["gate:running"]' '[]'
list_prs gate:running 303
list_prs gate:passed

GD404=$(gate_dir 404)
# Files outside src/, tests/ AND .agents/ so velo-merge treats this as
# CODE=0 (docs-only): it skips the gate cross-check and the CI requirement
# entirely, needing only mergeable=true — the simplest fixture that reaches a
# REAL, successful `gh pr merge` call for the idempotency assertion below.
mkpr 404 "$HEADSHA" '["README.md"]' '["gate:passed"]' \
  "$(jq -cn --arg h "gate: code-review @ $HEADSHA" '[{body:$h}]')"
list_prs gate:passed 404
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
run_tick >/dev/null 2>&1
C1=$(calls_of "pr comment 303")
C2=$(calls_of "pr merge 404")
if [[ "$C1" -eq 1 ]]; then ok "the gate report for #303 was posted exactly once across two ticks"
else fail "#303 was posted $C1 times across two ticks, expected 1"; fi
if [[ "$C2" -eq 1 ]]; then ok "#404 was merged exactly once across two ticks"
else fail "#404 was merged $C2 times across two ticks, expected 1"; fi

echo
echo "== 6. a tick racing a simulated session post of the same (pr, gate, sha) posts nothing =="
reset_state
GD=$(gate_dir 505)
printf '## Codex review — PR 505 @ %s\n**Verdict:** approve\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
# The PR ALREADY carries the exact header a session's own --wait path would
# have posted moments earlier — this tick must not post a second copy.
mkpr 505 "$HEADSHA" '[".agents/bin/race"]' '["gate:running"]' \
  "$(jq -cn --arg h "gate: code-review @ ${HEADSHA:0:9}
someone already posted this" '[{body:$h}]')"
list_prs gate:running 505
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if [[ "$(calls_of 'pr comment 505')" -eq 0 ]]; then
  ok "no duplicate post when the PR already carries the gate header"
else
  fail "posted again even though the header already existed"
fi
if grep -q "pr edit 505.*gate:passed" "$CALLS_LOG"; then
  ok "the verdict is still read from the log file and the PR still passes"
else
  fail "did not pass #505 even though its only gate approved"
fi

echo
echo "== 7. the paused file stops a tick cold =="
reset_state
mkdir -p "$STATE/orch"; touch "$STATE/orch/paused"
: > "$CALLS_LOG"
OUT=$(run_tick 2>&1)
if grep -q "paused" <<<"$OUT" && [[ ! -s "$CALLS_LOG" ]]; then
  ok "a paused tick makes no gh calls at all"
else
  fail "paused tick still did something: $OUT / calls=$(cat "$CALLS_LOG" 2>/dev/null)"
fi
rm -f "$STATE/orch/paused"

echo
echo "== 8. approve-with-findings and a malformed verdict both escalate, neither passes =="
reset_state
GD=$(gate_dir 606)
printf '## Codex review — PR 606 @ %s\n**Verdict:** approve-with-findings\n\nsome nit\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 606 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'

GD707=$(gate_dir 707)
printf '## Codex review — PR 707 @ %s\n**Verdict:** request-changes\n' "$HEADSHA" > "$GD707/review.log"
printf '%s' "$(dead_pid)" > "$GD707/review.log.pid"
printf '%s' "$HEADSHA" > "$GD707/gated.sha"
mkpr 707 "$HEADSHA" '[".agents/bin/bar"]' '["gate:running"]' '[]'

list_prs gate:running 606 707
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if grep -q '"kind":"gate-findings"' "$STATE/orch/attention.jsonl"; then ok "approve-with-findings escalates"
else fail "approve-with-findings did not escalate"; fi
if grep -q '"kind":"gate-malformed"' "$STATE/orch/attention.jsonl"; then ok "an unrecognised verdict word (request-changes) escalates as malformed"
else fail "malformed verdict did not escalate"; fi
if ! grep -q "pr edit 606.*gate:passed" "$CALLS_LOG" && ! grep -q "pr edit 707.*gate:passed" "$CALLS_LOG"; then
  ok "neither findings nor malformed sets gate:passed"
else
  fail "a gate that is not a clean approve was still passed"
fi
# Gates, unlike workers, have no offset-file layer in front of them — they
# re-derive their verdict from disk every tick — so attention_append's own
# id-dedup is the ONLY thing standing between this and a duplicate escalation
# on every single tick forever.
run_tick >/dev/null 2>&1
NF=$(grep -c '"kind":"gate-findings"' "$STATE/orch/attention.jsonl")
NM=$(grep -c '"kind":"gate-malformed"' "$STATE/orch/attention.jsonl")
if [[ "$NF" -eq 1 && "$NM" -eq 1 ]]; then
  ok "a second tick re-deriving the same verdict does not re-escalate (findings=$NF malformed=$NM)"
else
  fail "gate escalation duplicated across ticks (findings=$NF malformed=$NM, expected 1 each)"
fi

echo
echo "== 9. an .agents-only PR is never auto-merged, even gate:passed with green CI =="
reset_state
mkpr 808 "$HEADSHA" '[".agents/bin/foo", ".agents/tests/test_x.sh"]' '["gate:passed"]' \
  "$(jq -cn --arg h "gate: code-review @ $HEADSHA" '[{body:$h}]')"
list_prs gate:passed 808
list_prs gate:running
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if [[ "$(calls_of 'pr merge 808')" -eq 0 ]]; then
  ok ".agents-only PR is never handed to velo-merge"
else
  fail "an .agents-only PR was merged"
fi
if grep -q '"kind":"agents-only-merge"' "$STATE/orch/attention.jsonl"; then
  ok ".agents-only PR escalates for a human to merge by hand"
else
  fail ".agents-only PR did not escalate"
fi

echo
echo "== 10. dispatch re-checks the pinned worker label and brief sha256 =="
reset_state
mkdir -p "$STATE/orch" "$T/worktrees"
BRIEF2="$T/brief-909.md"; printf 'do another thing\n' > "$BRIEF2"
SHA2=$(shasum -a 256 "$BRIEF2" | awk '{print $1}')
jq -cn --arg issue 909 --arg brief "$BRIEF2" --arg worker deepseek --arg s "$SHA2" \
  '{issue:($issue|tonumber), brief:$brief, worker:$worker, brief_sha256:$s}' > "$STATE/orch/queue.jsonl"
# The issue's label has since moved to glm — the pinned worker no longer matches.
jq -cn '{labels:[{name:"worker:glm"}]}' > "$FIX/issue_909.json"
list_prs gate:running; list_prs gate:passed
export VELO_ORCH_WORKTREE_GLOB="$T/worktrees/velostream-*"
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if ! grep -q "FAKE-DISPATCH 909" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "a worker-label mismatch at dispatch time blocks the dispatch"
else
  fail "dispatched #909 despite the worker label having changed since queueing"
fi
if [[ ! -s "$STATE/orch/queue.jsonl" ]]; then
  ok "the mismatched entry is dropped from the queue rather than retried forever"
else
  fail "the mismatched entry is still sitting in the queue"
fi
if grep -q '"kind":"dispatch-mismatch"' "$STATE/orch/attention.jsonl"; then
  ok "the mismatch escalates for a human to re-queue"
else
  fail "the mismatch did not escalate"
fi

echo
echo "== 11. a finished gate with no recorded gated.sha escalates rather than posting =="
reset_state
GD=$(gate_dir 1010)
printf '## Codex review — PR 1010 @ %s\n**Verdict:** approve\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
# Deliberately no gated.sha — this is real production state today: velo-pr-gate
# does not write it yet (Integration after PR1). The daemon must never fall
# back to the PR's current head, which could stamp coverage the gate never had.
mkpr 1010 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 1010
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if [[ "$(calls_of 'pr comment 1010')" -eq 0 ]]; then
  ok "no gated.sha -> never posts against the current head"
else
  fail "posted without a recorded gated-start sha"
fi
if grep -q '"kind":"gate-nosha"' "$STATE/orch/attention.jsonl"; then
  ok "the missing sha escalates so a human can post with the right --sha"
else
  fail "a missing gated.sha did not escalate"
fi

echo
echo "== 12. a blocked verdict sets gate:blocked and escalates for a fix brief =="
reset_state
GD=$(gate_dir 1111)
# The REAL shape a local-model report has come back in on this repo: a
# trailing period and prose immediately after the word, on the same line.
printf '## Check-code review: PR 1111 @ %s\n**Verdict:** blocked. One wrong-topic defect.\n\n### Findings\n...\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 1111 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 1111
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if grep -q "pr edit 1111.*gate:blocked" "$CALLS_LOG"; then
  ok "'blocked.' with trailing prose still parses as blocked, not malformed"
else
  fail "did not set gate:blocked for a real-shaped blocked verdict"
fi
if grep -q '"kind":"gate-blocked"' "$STATE/orch/attention.jsonl"; then
  ok "a blocked gate escalates so a human writes the fix brief"
else
  fail "a blocked gate did not escalate"
fi
if ! grep -q "pr edit 1111.*--add-label gate:passed" "$CALLS_LOG"; then
  ok "a blocked gate never also gets marked passed"
else
  fail "a blocked gate was also marked passed"
fi

echo
echo "== 13. a report that states two different verdicts is neither passed nor blocked =="
reset_state
GD=$(gate_dir 1212)
# An early `approve` (a restated header) followed by a later `blocked`: the first line used to
# decide, so the daemon labelled this PR gate:passed over a reviewer who also said blocked.
printf '## Codex review — PR 1212 @ %s\n**Verdict:** approve\n\n### Re-check\n**Verdict:** blocked\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 1212 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 1212
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if ! grep -q "pr edit 1212.*gate:passed" "$CALLS_LOG"; then
  ok "an approve that a later line contradicts does not pass the PR"
else
  fail "a report that also said blocked was passed on its first line"
fi
if ! grep -q "pr edit 1212.*gate:blocked" "$CALLS_LOG"; then
  ok "nor is it blocked on its later line — a contradictory report asks a human"
else
  fail "a contradictory report was blocked automatically"
fi
if grep -q '"kind":"gate-malformed"' "$STATE/orch/attention.jsonl"; then
  ok "the contradictory report escalates as malformed, for a human to read"
else
  fail "a contradictory report did not escalate"
fi

echo
echo "== 14. dispatch: several worker labels, and an unreadable issue, are neither the first label nor 'no label' =="
reset_state
mkdir -p "$STATE/orch" "$T/worktrees"
BRIEF3="$T/brief-1313.md"; printf 'do a third thing\n' > "$BRIEF3"
SHA3=$(shasum -a 256 "$BRIEF3" | awk '{print $1}')
export VELO_ORCH_WORKTREE_GLOB="$T/worktrees/velostream-*"
list_prs gate:running; list_prs gate:passed
queue_one() {   # <issue> <worker pinned at queue time>
  jq -cn --arg issue "$1" --arg brief "$BRIEF3" --arg worker "$2" --arg s "$SHA3" \
    '{issue:($issue|tonumber), brief:$brief, worker:$worker, brief_sha256:$s}' > "$STATE/orch/queue.jsonl"
}
# The pinned worker is one of the issue's two worker labels, and it is the FIRST: the first-label
# read called that a match and handed the issue to velo-dispatch, which refuses an issue with more
# than one worker label — the daemon log was the only place anyone would have seen it.
queue_one 1313 deepseek
jq -cn '{labels:[{name:"worker:deepseek"},{name:"worker:glm"}]}' > "$FIX/issue_1313.json"
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if ! grep -q "FAKE-DISPATCH 1313" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "an issue with two worker labels is not dispatched on the strength of the first"
else
  fail "dispatched #1313 although it carries two worker labels"
fi
if grep -q '"kind":"dispatch-mismatch"' "$STATE/orch/attention.jsonl" 2>/dev/null \
   && grep -q 'worker:deepseek' "$STATE/orch/attention.jsonl" && grep -q 'worker:glm' "$STATE/orch/attention.jsonl"; then
  ok "the escalation names both labels"
else
  fail "no escalation naming both worker labels: $(cat "$STATE/orch/attention.jsonl" 2>/dev/null)"
fi
# An issue that could not be READ is not an issue with no worker label.
reset_state
mkdir -p "$STATE/orch" "$T/worktrees"
list_prs gate:running; list_prs gate:passed
queue_one 1414 deepseek
jq -cn '{labels:[{name:"worker:deepseek"}]}' > "$FIX/issue_1414.json"
: > "$CALLS_LOG"
GH_ISSUE_FAIL_1414=1 run_tick >/dev/null 2>&1
if ! grep -q "FAKE-DISPATCH 1414" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "an unreadable issue is not dispatched"
else
  fail "dispatched #1414 although its labels could not be read"
fi
if grep -q '"kind":"dispatch-unreadable"' "$STATE/orch/attention.jsonl" 2>/dev/null \
   && grep -q 'HTTP 502' "$STATE/orch/attention.jsonl"; then
  ok "the escalation says the read failed, with gh's own words"
else
  fail "no dispatch-unreadable escalation carrying gh's message: $(cat "$STATE/orch/attention.jsonl" 2>/dev/null)"
fi
if ! grep -q 'worker:<none>' "$STATE/orch/attention.jsonl" 2>/dev/null; then
  ok "and does not claim the issue has no worker label"
else
  fail "an unreadable issue was reported as having no worker label"
fi

echo
echo "== 15. a verdict that velo-gate refuses to record is not logged as recorded =="
# A velo-gate that cannot record a verdict: --pass / --block refuse the way the real one does (a
# stale gate, comments it cannot read, a label it cannot set); the plan is the real thing. The
# daemon sent velo-gate's output and status to /dev/null and logged "gate:passed" anyway, on
# every tick, with nothing escalated — a PR stuck at gate:running behind a log that said it passed.
cat > "$T/bin/velo-gate-refusing" <<STUBEOF
#!/bin/bash
case "\$2" in
  --pass|--block)
    printf '\n\033[31mERROR:\033[0m refusing to mark passed: head is %s, but:\n    check-code ran at 2222222\n  Re-run the gate against the current head.\n\n' "\$1" >&2
    exit 1 ;;
esac
exec "$BIN/velo-gate" "\$@"
STUBEOF
chmod +x "$T/bin/velo-gate-refusing"
reset_state
GD=$(gate_dir 1515)
printf '## Codex review — PR 1515 @ %s\n**Verdict:** approve\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 1515 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
GD1616=$(gate_dir 1616)
printf '## Codex review — PR 1616 @ %s\n**Verdict:** blocked\n' "$HEADSHA" > "$GD1616/review.log"
printf '%s' "$(dead_pid)" > "$GD1616/review.log.pid"
printf '%s' "$HEADSHA" > "$GD1616/gated.sha"
mkpr 1616 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 1515 1616
list_prs gate:passed
: > "$CALLS_LOG"
VELO_GATE_BIN="$T/bin/velo-gate-refusing" run_tick >/dev/null 2>&1
if ! grep -q "gate:passed #1515" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "a --pass that velo-gate refused is not logged as gate:passed"
else
  fail "the daemon logged gate:passed #1515 although velo-gate refused to record it"
fi
if ! grep -q "gate:blocked #1616" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "a --block that velo-gate refused is not logged as gate:blocked"
else
  fail "the daemon logged gate:blocked #1616 although velo-gate refused to record it"
fi
if [[ "$(grep -c '"kind":"gate-label-failed"' "$STATE/orch/attention.jsonl" 2>/dev/null)" == "2" ]] \
   && grep -q 'refusing to mark passed' "$STATE/orch/attention.jsonl"; then
  ok "each refusal escalates, carrying velo-gate's own reason"
else
  fail "expected two gate-label-failed escalations carrying the reason: $(cat "$STATE/orch/attention.jsonl" 2>/dev/null)"
fi
VELO_GATE_BIN="$T/bin/velo-gate-refusing" run_tick >/dev/null 2>&1
if [[ "$(grep -c '"kind":"gate-label-failed"' "$STATE/orch/attention.jsonl" 2>/dev/null)" == "2" ]]; then
  ok "a second tick over the same refusals does not re-escalate"
else
  fail "the refusals were escalated again on the next tick"
fi
# The control: when velo-gate does record it, the log says so (sections 1, 5, 6 and 12 pin the
# label calls themselves).
reset_state
GD=$(gate_dir 1717)
printf '## Codex review — PR 1717 @ %s\n**Verdict:** approve\n' "$HEADSHA" > "$GD/review.log"
printf '%s' "$(dead_pid)" > "$GD/review.log.pid"
printf '%s' "$HEADSHA" > "$GD/gated.sha"
mkpr 1717 "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
list_prs gate:running 1717
list_prs gate:passed
: > "$CALLS_LOG"
run_tick >/dev/null 2>&1
if grep -q "gate:passed #1717" "$STATE/orch/orchestrd.log" 2>/dev/null; then
  ok "a verdict velo-gate records is logged as recorded"
else
  fail "the daemon did not log a recorded gate:passed #1717"
fi

echo
echo "== 16. a gate whose pid file cannot say whether its reviewer is still running is not finished =="
# The reviewer's pid was read as `cat pid 2>/dev/null` and "no live pid" was the whole test for
# "finished", so a pid file that was empty, held no pid or could not be read was a finished reviewer:
# its log — possibly still being written — was judged and POSTED under the gate header, and the
# post-once guard then kept the real report off the PR. Only a pid KNOWN to be gone is a finished
# gate; any other state is left for the next tick, as an absent pid file already was.
UNREADABLE_OK=1
echo ok > "$T/readable.probe"; chmod 000 "$T/readable.probe"
if cat "$T/readable.probe" >/dev/null 2>&1; then UNREADABLE_OK=0; fi   # root reads everything
chmod 600 "$T/readable.probe"

gate_with_pid() {   # <pr>: a gate that looks finished — an approve report and a recorded sha — for PR <pr>
  local pr="$1" gd; gd=$(gate_dir "$pr")
  printf '## Codex review — PR %s @ %s\n**Verdict:** approve\n' "$pr" "$HEADSHA" > "$gd/review.log"
  printf '%s' "$HEADSHA" > "$gd/gated.sha"
  mkpr "$pr" "$HEADSHA" '[".agents/bin/foo"]' '["gate:running"]' '[]'
}
GP_UNKNOWN="1801 1802 1803"      # a pid file that names no reviewer: empty, blank, not a pid
[[ $UNREADABLE_OK -eq 0 ]] || GP_UNKNOWN="$GP_UNKNOWN 1806"   # ... and one that cannot be read
GP_FAILS=""
run_gate_pid_tick() {   # one tick of the daemon named by ORCHD_UNDER_TEST (default: the real one)
  reset_state
  gate_with_pid 1801; : > "$STATE/gate/1801/review.log.pid"
  gate_with_pid 1802; printf '  \n' > "$STATE/gate/1802/review.log.pid"
  gate_with_pid 1803; printf 'not-a-pid\n' > "$STATE/gate/1803/review.log.pid"
  gate_with_pid 1804; printf '%s\n' "$$" > "$STATE/gate/1804/review.log.pid"                 # a reviewer still running
  gate_with_pid 1805; printf '%s' "$(dead_pid)" > "$STATE/gate/1805/review.log.pid"          # a reviewer that is gone
  local running="1801 1802 1803 1804 1805"
  if [[ $UNREADABLE_OK -eq 1 ]]; then
    gate_with_pid 1806; printf '%s\n' "$$" > "$STATE/gate/1806/review.log.pid"
    chmod 000 "$STATE/gate/1806/review.log.pid"
    running="$running 1806"
  fi
  list_prs gate:running $running
  list_prs gate:passed
  : > "$CALLS_LOG"
  VELO_GATE_BIN="$BIN/velo-gate" VELO_GATE_POST_BIN="$BIN/velo-gate-post" VELO_MERGE_BIN="$BIN/velo-merge" run_tick >/dev/null 2>&1
}
check_gate_pid_tick() {   # -> GP_FAILS: the checks that did not hold
  local pr
  GP_FAILS=""
  for pr in $GP_UNKNOWN; do
    [[ "$(calls_of "pr comment $pr")" -eq 0 ]]                          || GP_FAILS="$GP_FAILS not-posted[$pr]"
    ! grep -q "pr edit $pr.*gate:passed" "$CALLS_LOG"                    || GP_FAILS="$GP_FAILS not-passed[$pr]"
    grep -q "for #$pr: .*review.log.pid holds no readable pid" "$STATE/orch/orchestrd.log" 2>/dev/null \
                                                                         || GP_FAILS="$GP_FAILS says-why[$pr]"
  done
  [[ "$(calls_of 'pr comment 1804')" -eq 0 ]]                            || GP_FAILS="$GP_FAILS running-not-posted"
  ! grep -q "pr edit 1804.*gate:passed" "$CALLS_LOG"                     || GP_FAILS="$GP_FAILS running-not-passed"
  ! grep -q "for #1804: " "$STATE/orch/orchestrd.log" 2>/dev/null        || GP_FAILS="$GP_FAILS running-is-not-an-anomaly"
  [[ "$(calls_of 'pr comment 1805')" -eq 1 ]]                            || GP_FAILS="$GP_FAILS finished-posted"
  grep -q "pr edit 1805.*gate:passed" "$CALLS_LOG"                       || GP_FAILS="$GP_FAILS finished-passed"
}
run_gate_pid_tick
check_gate_pid_tick
if [[ -z "$GP_FAILS" ]]; then
  ok "a pid file that is empty, blank, not a pid or unreadable is not a finished gate: nothing posted or passed, and the log says why"
  ok "a reviewer still running is left alone, silently; one that is gone is posted and passed"
else
  fail "gate pid file handling:$GP_FAILS"
fi

# MUTATION-PROOF, on a COPY of the daemon: with the guard turned off (the old behaviour — an unreadable
# pid is the same as no live pid) the four unknown-pid gates are posted and passed.
mutant_orchd() {   # <anchor> <replacement> -> $T/mut/velo-orchestrd, with its libraries beside it
  mkdir -p "$T/mut"
  python3 - "$ORCHD" "$T/mut/velo-orchestrd" "$1" "$2" <<'PY' || return 1
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
  cp "$BIN/velo-orch-lib.sh" "$BIN/velo-worktree-lib.sh" "$T/mut/" && chmod +x "$T/mut/velo-orchestrd"
}
if mutant_orchd '        if ! [[ "$pid" =~ ^[0-9]+$ ]]; then' '        if false; then'; then
  ORCHD_UNDER_TEST="$T/mut/velo-orchestrd" run_gate_pid_tick
  check_gate_pid_tick
  MISSING=""
  for pr in $GP_UNKNOWN; do
    [[ "$GP_FAILS" == *"not-posted[$pr]"* && "$GP_FAILS" == *"not-passed[$pr]"* && "$GP_FAILS" == *"says-why[$pr]"* ]] \
      || MISSING="$MISSING $pr"
  done
  if [[ -z "$MISSING" ]]; then
    ok "MUTATION-PROOF an unreadable pid is not a finished gate: red with the guard off ($GP_FAILS )"
  else
    fail "MUTATION-PROOF an unreadable pid is not a finished gate: the mutant stayed green for$MISSING (red: $GP_FAILS )"
  fi
else
  fail "MUTATION-PROOF an unreadable pid is not a finished gate: could not build the mutant (anchor missing — did step_gates change shape?)"
fi

echo
echo "== 17. a dispatch that does not happen is escalated, once per ATTEMPT, not left in the log =="
# step_dispatch pops the queue entry BEFORE it checks or runs anything, so an entry that does not
# become a dispatch is gone, and what the operator is told is all they will ever know of it. Each of
# these used to reach only the daemon log, or nobody:
#   - velo-dispatch refuses (stale anchors, a brief that fails its lint, no disk): its status was
#     never looked at
#   - the entry cannot be dispatched at all: no numeric issue, no brief, a brief that is not there
#   - the issue's labels cannot be read, it has several worker labels, or the pinned worker moved:
#     escalated, but under an id of (issue, brief) that dedupes FOREVER — queue the same entry again
#     and the second drop was silent.
cat > "$T/bin/velo-dispatch-refusing" <<'STUBEOF'
#!/bin/bash
echo "preflight: anchors"
printf '\n\033[31mNOT READY:\033[0m %s\n\n' "${REFUSAL_REASON:-stale anchor in the brief: src/foo.rs:12 no longer matches}" >&2
exit 1
STUBEOF
chmod +x "$T/bin/velo-dispatch-refusing"
BRIEF_MISSING="$T/no-such-brief.md"
DR_FAILS=""
count_events() { grep -c "\"kind\":\"$1\"" "$STATE/orch/attention.jsonl" 2>/dev/null || true; }
events_of() {   # <kind> <issue> -> how many escalations of that kind name that issue
  jq -c --arg k "$1" --argjson i "$2" 'select(.kind == $k and .issue == $i)' "$STATE/orch/attention.jsonl" 2>/dev/null | grep -c . || true
}
dispatch_scenario() {   # the whole story, one tick per step; the daemon is ORCHD_UNDER_TEST (default: the real one)
  reset_state
  mkdir -p "$STATE/orch" "$T/worktrees"
  export VELO_ORCH_WORKTREE_GLOB="$T/worktrees/velostream-*"
  list_prs gate:running; list_prs gate:passed
  export VELO_GATE_BIN="$BIN/velo-gate" VELO_GATE_POST_BIN="$BIN/velo-gate-post" VELO_MERGE_BIN="$BIN/velo-merge"
  local n
  for n in 1818 1919 1414; do jq -cn '{labels:[{name:"worker:deepseek"}]}' > "$FIX/issue_$n.json"; done
  jq -cn '{labels:[{name:"worker:deepseek"},{name:"worker:glm"}]}' > "$FIX/issue_1313.json"
  jq -cn '{labels:[{name:"worker:glm"}]}' > "$FIX/issue_2020.json"
  # velo-dispatch refuses #1818, twice, for different reasons ...
  queue_one 1818 deepseek
  VELO_DISPATCH_BIN="$T/bin/velo-dispatch-refusing" run_tick >/dev/null 2>&1
  queue_one 1818 deepseek
  REFUSAL_REASON="no room: 3GB free" VELO_DISPATCH_BIN="$T/bin/velo-dispatch-refusing" run_tick >/dev/null 2>&1
  # ... and accepts #1919
  queue_one 1919 deepseek
  run_tick >/dev/null 2>&1
  # the SAME entry queued twice and dropped twice: labels unreadable / two worker labels / pinned worker moved
  for n in 1 2; do queue_one 1414 deepseek; GH_ISSUE_FAIL_1414=1 run_tick >/dev/null 2>&1; done
  for n in 1 2; do queue_one 1313 deepseek; run_tick >/dev/null 2>&1; done
  for n in 1 2; do queue_one 2020 deepseek; run_tick >/dev/null 2>&1; done
  # an entry that cannot be dispatched at all: a brief that is not there (twice), a line that is not
  # JSON, an issue that is not a number
  for n in 1 2; do
    jq -cn --arg b "$BRIEF_MISSING" '{issue:2121, brief:$b, worker:"deepseek", brief_sha256:"abc"}' > "$STATE/orch/queue.jsonl"
    run_tick >/dev/null 2>&1
  done
  printf 'this is not json\n' > "$STATE/orch/queue.jsonl"; run_tick >/dev/null 2>&1
  jq -cn --arg b "$BRIEF3" '{issue:"abc", brief:$b, worker:"deepseek", brief_sha256:"abc"}' > "$STATE/orch/queue.jsonl"
  run_tick >/dev/null 2>&1
  unset VELO_GATE_BIN VELO_GATE_POST_BIN VELO_MERGE_BIN
}
check_dispatch_scenario() {   # -> DR_FAILS: the checks that did not hold
  DR_FAILS=""
  local att="$STATE/orch/attention.jsonl" dlog="$STATE/orch/orchestrd.log" ev
  # velo-dispatch refuses
  [[ "$(events_of dispatch-failed 1818)" == "2" ]]            || DR_FAILS="$DR_FAILS refusal-escalated-per-attempt"
  ev=$(jq -r 'select(.kind == "dispatch-failed") | .evidence' "$att" 2>/dev/null)
  grep -q 'stale anchor in the brief' <<<"$ev"                || DR_FAILS="$DR_FAILS refusal-carries-its-reason"
  grep -q 'no room: 3GB free' <<<"$ev"                        || DR_FAILS="$DR_FAILS second-refusal-carries-its-reason"
  grep -q 'exit 1' <<<"$ev"                                   || DR_FAILS="$DR_FAILS refusal-carries-the-status"
  grep -q 'stale anchor in the brief' "$dlog" 2>/dev/null     || DR_FAILS="$DR_FAILS refusal-still-in-the-log"
  # velo-dispatch accepts
  grep -q "FAKE-DISPATCH 1919" "$dlog" 2>/dev/null            || DR_FAILS="$DR_FAILS accepted-dispatch-logged"
  [[ "$(events_of dispatch-failed 1919)" == "0" ]]            || DR_FAILS="$DR_FAILS accepted-dispatch-not-escalated"
  # the same entry queued twice, dropped twice: two escalations, not one
  [[ "$(events_of dispatch-unreadable 1414)" == "2" ]]        || DR_FAILS="$DR_FAILS unreadable-per-attempt"
  [[ "$(events_of dispatch-mismatch 1313)" == "2" ]]          || DR_FAILS="$DR_FAILS several-labels-per-attempt"
  [[ "$(events_of dispatch-mismatch 2020)" == "2" ]]          || DR_FAILS="$DR_FAILS moved-pin-per-attempt"
  # an entry that cannot be dispatched at all
  [[ "$(events_of dispatch-malformed 2121)" == "2" ]]         || DR_FAILS="$DR_FAILS missing-brief-per-attempt"
  [[ "$(count_events dispatch-malformed)" == "4" ]]           || DR_FAILS="$DR_FAILS four-bad-entries-four-events"
  ev=$(jq -r 'select(.kind == "dispatch-malformed") | .evidence' "$att" 2>/dev/null)
  grep -q "no brief file at $BRIEF_MISSING" <<<"$ev"          || DR_FAILS="$DR_FAILS missing-brief-says-which"
  grep -q 'this is not json' <<<"$ev"                         || DR_FAILS="$DR_FAILS not-json-shows-the-line"
  grep -q 'no numeric issue' <<<"$ev"                         || DR_FAILS="$DR_FAILS non-numeric-issue-says-why"
}
dispatch_scenario
check_dispatch_scenario
if [[ -z "$DR_FAILS" ]]; then
  ok "a dispatch velo-dispatch refuses escalates as dispatch-failed with its status and last output; the output is still in the log"
  ok "a refusal for a second, different reason of the same entry is a second escalation"
  ok "a dispatch that succeeds is logged and not escalated"
  ok "the same entry dropped twice (labels unreadable / several worker labels / pin moved) escalates twice"
  ok "an entry with no brief file, no JSON or no numeric issue escalates as dispatch-malformed, saying which"
else
  fail "dispatch escalation:$DR_FAILS"
fi

# MUTATION-PROOF, each on a COPY of the daemon with one fix reverted; the checks named must go red.
dispatch_proof() {   # <what is pinned> <anchor> <replacement> <the checks that must go red...>
  local what="$1" anchor="$2" repl="$3" missing="" c
  shift 3
  if mutant_orchd "$anchor" "$repl"; then
    ORCHD_UNDER_TEST="$T/mut/velo-orchestrd" dispatch_scenario
    check_dispatch_scenario
    for c in "$@"; do [[ " $DR_FAILS " == *" $c "* ]] || missing="$missing $c"; done
    if [[ -z "$missing" ]]; then
      ok "MUTATION-PROOF $what: red with it reverted ($DR_FAILS )"
    else
      fail "MUTATION-PROOF $what: the mutant stayed green for$missing (red: $DR_FAILS )"
    fi
  else
    fail "MUTATION-PROOF $what: could not build the mutant (anchor missing — did step_dispatch change shape?)"
  fi
}
dispatch_proof "velo-dispatch's status is looked at" \
  '  if [[ $d_rc -ne 0 ]]; then' '  if false; then' \
  refusal-escalated-per-attempt refusal-carries-its-reason second-refusal-carries-its-reason refusal-carries-the-status
dispatch_proof "an escalation id is per attempt" \
  "  printf '%s:%s:%s-%s' \"\$1\" \"\$2\" \"\$(date -u +%FT%TZ)\" \"\$\$\"" "  printf '%s:%s' \"\$1\" \"\$2\"" \
  refusal-escalated-per-attempt unreadable-per-attempt several-labels-per-attempt moved-pin-per-attempt missing-brief-per-attempt four-bad-entries-four-events
dispatch_proof "an entry that cannot be dispatched is escalated" \
  '    if attention_append "$(dispatch_attempt_id dispatch-malformed' '    if false && attention_append "$(dispatch_attempt_id dispatch-malformed' \
  missing-brief-per-attempt four-bad-entries-four-events missing-brief-says-which not-json-shows-the-line non-numeric-issue-says-why
dispatch_proof "an issue that is not a number is a bad entry, not a read to try" \
  '  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then bad="no numeric issue"' '  if [[ -z "$issue" ]]; then bad="no numeric issue"' \
  four-bad-entries-four-events

echo
echo "== 18. a host short of disk pauses dispatch and says so once a day; one with room dispatches =="
# Every section above runs against the stub df at 900 GiB, so none of it depends on the host's disk. Here the stub says 10, and 900 again as the control:
# a daemon that read the real disk instead of asking df would fail one of the two on any host (a roomy one fails the 10, a tight one the 900).
LD_FAILS=""
lowdisk_scenario() {   # <GiB the stub df reports free>: one entry queued, two ticks of the daemon under test (ORCHD_UNDER_TEST, default the real one)
  reset_state
  mkdir -p "$STATE/orch" "$T/worktrees"
  export VELO_ORCH_WORKTREE_GLOB="$T/worktrees/velostream-*"
  list_prs gate:running; list_prs gate:passed
  jq -cn '{labels:[{name:"worker:deepseek"}]}' > "$FIX/issue_1818.json"
  queue_one 1818 deepseek
  DF_FREE_GIB="$1" run_tick >/dev/null 2>&1
  DF_FREE_GIB="$1" run_tick >/dev/null 2>&1
}
check_lowdisk() {   # <short|roomy> -> LD_FAILS: the checks that did not hold
  LD_FAILS=""
  local dlog="$STATE/orch/orchestrd.log" n ev
  n=$(count_events low-disk)
  if [[ "$1" == short ]]; then
    grep -q 1818 "$STATE/orch/queue.jsonl" 2>/dev/null     || LD_FAILS="$LD_FAILS entry-stays-queued"
    ! grep -q "FAKE-DISPATCH 1818" "$dlog" 2>/dev/null     || LD_FAILS="$LD_FAILS nothing-dispatched"
    [[ "${n:-0}" == 1 ]]                                   || LD_FAILS="$LD_FAILS escalated-once-across-two-ticks"
    ev=$(jq -r 'select(.kind == "low-disk") | .evidence' "$STATE/orch/attention.jsonl" 2>/dev/null)
    grep -q 'only 10GB free (< 25GB)' <<<"$ev"             || LD_FAILS="$LD_FAILS says-how-much-is-free"
  else
    grep -q "FAKE-DISPATCH 1818" "$dlog" 2>/dev/null       || LD_FAILS="$LD_FAILS dispatched-with-room"
    ! grep -q 1818 "$STATE/orch/queue.jsonl" 2>/dev/null   || LD_FAILS="$LD_FAILS entry-leaves-the-queue"
    [[ "${n:-0}" == 0 ]]                                   || LD_FAILS="$LD_FAILS no-escalation-with-room"
  fi
}
lowdisk_scenario 10;  check_lowdisk short; SHORT_FAILS="$LD_FAILS"
lowdisk_scenario 900; check_lowdisk roomy
if [[ -z "$SHORT_FAILS$LD_FAILS" ]]; then
  ok "10 GB free (< 25): the entry stays queued, nothing is dispatched, and two ticks escalate low-disk once, saying how much is free"
  ok "900 GB free: the entry is dispatched and nothing is escalated"
else
  fail "low disk:$SHORT_FAILS$LD_FAILS"
fi
lowdisk_proof() {   # <what is pinned> <anchor> <replacement> <short|roomy> <GiB the stub reports> <the checks that must go red...>
  local what="$1" anchor="$2" repl="$3" kind="$4" gib="$5" missing="" c
  shift 5
  if mutant_orchd "$anchor" "$repl"; then
    ORCHD_UNDER_TEST="$T/mut/velo-orchestrd" lowdisk_scenario "$gib"
    check_lowdisk "$kind"
    for c in "$@"; do [[ " $LD_FAILS " == *" $c "* ]] || missing="$missing $c"; done
    if [[ -z "$missing" ]]; then
      ok "MUTATION-PROOF $what: red with it reverted ($LD_FAILS )"
    else
      fail "MUTATION-PROOF $what: the mutant stayed green for$missing (red: $LD_FAILS )"
    fi
  else
    fail "MUTATION-PROOF $what: could not build the mutant (anchor missing — did step_dispatch change shape?)"
  fi
}
lowdisk_proof "a short disk pauses dispatch" \
  '  if [[ -z "$disk" || "$disk" -lt "$MIN_DISK_GB" ]]; then' '  if [[ -z "$disk" ]]; then' short 10 \
  entry-stays-queued nothing-dispatched escalated-once-across-two-ticks says-how-much-is-free
lowdisk_proof "a disk with room is not paused" \
  '  if [[ -z "$disk" || "$disk" -lt "$MIN_DISK_GB" ]]; then' '  if true; then' roomy 900 \
  dispatched-with-room entry-leaves-the-queue no-escalation-with-room
lowdisk_proof "a short disk is escalated once a day, not once a tick" \
  'attention_append "low-disk:orch:$day" "low-disk"' 'attention_append "low-disk:orch:$day-$$" "low-disk"' short 10 \
  escalated-once-across-two-ticks

echo
[[ $RC -eq 0 ]] && echo "all velo-orchestrd checks passed" || echo "FAILURES"
exit $RC

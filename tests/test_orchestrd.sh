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

run_tick() {
  VELO_STATE="$STATE" VELO_ORCH_WORKTREE_GLOB="${VELO_ORCH_WORKTREE_GLOB:-$T/worktrees/velostream-*}" \
    "$ORCHD" tick
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
[[ $RC -eq 0 ]] && echo "all velo-orchestrd checks passed" || echo "FAILURES"
exit $RC

#!/bin/bash
# Record-writing and STOP-detection invariants (#1992).
#
# Every case here is a defect that already shipped once. Two of them recorded a
# confident WRONG value rather than failing — the class this tooling exists to
# prevent — so they are pinned with the same reproductions the review used.
#
# Run:  .agents/tests/run.sh   (or execute this file directly)

# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "$BIN/velo-worktree-lib.sh"

FAILURES=0
check() {  # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then
    printf '  PASS  %s: %s\n' "$1" "$2"
  else
    printf '  FAIL  %s: got %s, want %s\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

# A throwaway git worktree so the record's git derivations have something real
# to read. `commits` is what several outcome branches turn on.
make_repo() {  # <dir> <commits>
  mkdir -p "$1" && git -C "$1" init -q
  git -C "$1" config user.email t@t && git -C "$1" config user.name t
  echo base > "$1/f"; git -C "$1" add -A; git -C "$1" commit -qm base
  git -C "$1" branch -f master HEAD 2>/dev/null
  git -C "$1" remote add origin "$1" 2>/dev/null
  git -C "$1" update-ref refs/remotes/origin/master HEAD
  for ((i = 0; i < $2; i++)); do
    echo "$i" >> "$1/f"; git -C "$1" add -A; git -C "$1" commit -qm "c$i"
  done
}

totals() {  # <read_only> -> a TOTALS line
  echo "TOTALS prompts=1 leaked_tool_calls=0 input_tokens=10 output_tokens=2 cached_tokens=0 cost_usd=0.0 usage_source=sdk-unpriced read_only=$1"
}

outcome_of() {  # reads the last record line
  python3 -c "import json,sys;print(json.loads(open(sys.argv[1]).read().strip().split(chr(10))[-1])['outcome'])" "$1"
}

echo "STOP detection"
# `velo-impl.md` tells every worker to end its report with "Any STOP triggers
# hit", so these benign forms are the DOCUMENTED format, not exotic input. A
# false positive outranks `landed` and is defined as not-a-failure, so it erased
# the run from both columns.
mkdir -p "$TMP/benign"
{
  echo "2026-09-05T10:00:00Z PHASE 3 - no STOP triggers hit; gate green"
  echo "2026-09-05T10:01:00Z STOP-trigger list reviewed, none fired"
  echo "2026-09-05T10:02:00Z Final report: STOP triggers: none"
  echo "2026-09-05T10:03:00Z STOP: none"
} > "$TMP/benign/agent.log"
wt_stop_fired "$TMP/benign" && R=fired || R=quiet
check "benign STOP mentions do not fire" "$R" "quiet"

for real in "STOP — run-commit.sh --fast failed" "STOP: brief requires deleting a test" "STOP the work needs an error swallowed"; do
  mkdir -p "$TMP/real"; echo "2026-09-05T10:04:00Z $real" > "$TMP/real/agent.log"
  wt_stop_fired "$TMP/real" && R=fired || R=quiet
  check "real activation fires (${real:0:24}…)" "$R" "fired"
done

echo "outcome ladder"
make_repo "$TMP/clean" 1
make_repo "$TMP/empty" 0
mkdir -p "$TMP/root/.agents/tasks"
printf 'READ-ONLY review. Do not modify any file.\n' > "$TMP/ro-brief.md"
printf 'Implement the thing.\n' > "$TMP/impl-brief.md"

run_record() {  # <issue> <worktree> <log> <brief> <rc> [start-head]
  VELO_RECORD_ROOT="$TMP/root" "$BIN/velo-record" "$1" --worktree "$2" \
    --worker w --model m --log "$3" --brief "$4" \
    --started 2020-01-01T00:00:00Z --rc "$5" --max-turns 10 \
    ${6:+--start-head "$6"} >/dev/null 2>&1
  outcome_of "$TMP/root/records/$1.result.jsonl"
}

totals true  > "$TMP/ro.log"
totals false > "$TMP/impl.log"
: > "$TMP/no-totals.log"   # codex emits none

check "read-only + no commits -> reported"        "$(run_record 1 "$TMP/empty" "$TMP/ro.log"        "$TMP/ro-brief.md" 0)"   "reported"
check "read-only + commits -> violation"          "$(run_record 2 "$TMP/clean" "$TMP/ro.log"        "$TMP/ro-brief.md" 0)"   "read-only-violation"
check "impl + commits -> landed"                  "$(run_record 3 "$TMP/clean" "$TMP/impl.log"      "$TMP/impl-brief.md" 0)" "landed"
check "impl + no commits -> abandoned"            "$(run_record 4 "$TMP/empty" "$TMP/impl.log"      "$TMP/impl-brief.md" 0)" "abandoned"
check "non-zero rc -> failed"                     "$(run_record 5 "$TMP/clean" "$TMP/impl.log"      "$TMP/impl-brief.md" 3)" "failed"
# codex writes no TOTALS, so read_only can only come from the brief. Without the
# fallback every codex review — the gate velo-pr-gate routes to — scored failed.
check "codex (no TOTALS) + read-only brief"       "$(run_record 6 "$TMP/empty" "$TMP/no-totals.log" "$TMP/ro-brief.md" 0)"   "reported"

echo "resumed branch: score the run's own commits (#2291)"
# A resume starts on a branch that already carries earlier runs' commits. Counting
# from origin/master scored two velo-local runs that committed nothing as landed.
make_repo "$TMP/resumed" 3
RESUME_HEAD=$(git -C "$TMP/resumed" rev-parse HEAD)
check "resume + no new commits -> abandoned" \
      "$(run_record 20 "$TMP/resumed" "$TMP/impl.log" "$TMP/impl-brief.md" 0 "$RESUME_HEAD")" "abandoned"
check "read-only resume on a committed branch -> reported" \
      "$(run_record 21 "$TMP/resumed" "$TMP/ro.log" "$TMP/ro-brief.md" 0 "$RESUME_HEAD")" "reported"
echo more >> "$TMP/resumed/f"; git -C "$TMP/resumed" commit -qam "run commit"
check "resume + one new commit -> landed" \
      "$(run_record 22 "$TMP/resumed" "$TMP/impl.log" "$TMP/impl-brief.md" 0 "$RESUME_HEAD")" "landed"
check "run_commits counts only this run" \
      "$(python3 -c "import json,sys;w=json.loads(open(sys.argv[1]).read().strip().split(chr(10))[-1])['work'];print(w['run_commits'],w['commits'])" "$TMP/root/records/22.result.jsonl")" "1 4"
check "unresolvable start head -> branch count, not a guess of 0" \
      "$(run_record 23 "$TMP/resumed" "$TMP/impl.log" "$TMP/impl-brief.md" 0 deadbeefdeadbeef)" "landed"

echo "push state (#2012 R1)"
# `git log origin/<b>..HEAD` on a branch with NO remote errors to empty, so
# wc -l returned 0 — "nothing left to push" for a branch never pushed at all.
# The error direction is the dangerous one: unpushed work is what gets lost.
check "no remote branch -> all commits unpushed" "$(wt_unpushed "$TMP/clean" fix/never-pushed)" \
      "$(wt_commits "$TMP/clean")"
check "and that is not zero"                     "$([[ "$(wt_unpushed "$TMP/clean" fix/never-pushed)" != "0" ]] && echo yes || echo no)" "yes"

echo "read-only classification (#2012 R2)"
# A brief that is read-only TO SRC but mandates committing an analysis is not a
# read-only run. Collapsing it to one accused a compliant worker of a violation.
printf 'READ-ONLY analysis of the join path. Do not modify src/.\n\n## Incremental commits — MANDATORY\nCommit after each section you complete. Do NOT push.\n' > "$TMP/ro-but-commits.md"
check "read-only brief that mandates commits -> landed" \
      "$(run_record 7 "$TMP/clean" "$TMP/no-totals.log" "$TMP/ro-but-commits.md" 0)" "landed"
# ...while a genuinely read-only brief that commits is still a violation.
check "genuinely read-only brief that commits -> violation" \
      "$(run_record 8 "$TMP/clean" "$TMP/ro.log" "$TMP/ro-brief.md" 0)" "read-only-violation"

echo "discovery index state (audit)"
# The ONLY evidence that an index existed was a warn line in a terminal — and it
# turned out never to have been built at all (#2056). Recording it makes "how
# many dispatches actually had one?" a jq query instead of an archaeology
# exercise.
for st in built refused failed skipped; do
  D=$(mktemp -d); git init -q "$D"
  git -C "$D" config user.email t@t; git -C "$D" config user.name t
  printf 'x\n' > "$D/f"; git -C "$D" add -A; git -C "$D" commit -qm init
  printf 'WORKTREE: %s\nSTOP and report\nYou may commit.\n' "$D" > "$D/b.md"
  VELO_RECORD_ROOT="$D" "$BIN/velo-record" 4242 --index "$st" --worktree "$D" \
    --worker w --model m --brief "$D/b.md" --started "$(date -u +%FT%TZ)" \
    --rc 0 --max-turns 10 --base abc >/dev/null 2>&1
  GOT=$(python3 -c "
import json
print(json.loads(open('$D/records/4242.result.jsonl').readline()).get('discovery_index'))
" 2>/dev/null)
  check "index state '$st' recorded" "$GOT" "$st"
  rm -rf "$D"
done

# An omitted flag must not silently become a plausible value.
D=$(mktemp -d); git init -q "$D"
git -C "$D" config user.email t@t; git -C "$D" config user.name t
printf 'x\n' > "$D/f"; git -C "$D" add -A; git -C "$D" commit -qm init
printf 'WORKTREE: %s\nSTOP and report\nYou may commit.\n' "$D" > "$D/b.md"
VELO_RECORD_ROOT="$D" "$BIN/velo-record" 4243 --worktree "$D" --worker w --model m \
  --brief "$D/b.md" --started "$(date -u +%FT%TZ)" --rc 0 --max-turns 10 --base abc >/dev/null 2>&1
GOT=$(python3 -c "
import json
print(json.loads(open('$D/records/4243.result.jsonl').readline()).get('discovery_index'))
" 2>/dev/null)
check "omitted --index is 'unknown', not a guess" "$GOT" "unknown"
rm -rf "$D"

echo "record file"
# The JSON-array append was an unlocked read-modify-write: six concurrent
# recorders left 1 of 6 rows, silently, in the file whose stated purpose is that
# re-dispatches ACCUMULATE.
for i in 1 2 3 4 5 6; do
  VELO_RECORD_ROOT="$TMP/root" "$BIN/velo-record" 99 --worktree "$TMP/clean" \
    --worker "w$i" --model m --log "$TMP/impl.log" --brief "$TMP/impl-brief.md" \
    --started 2020-01-01T00:00:00Z --rc 0 --max-turns 10 >/dev/null 2>&1 &
done
wait
check "6 concurrent recorders keep 6 rows" "$(wc -l < "$TMP/root/records/99.result.jsonl" | tr -d ' ')" "6"

# Observational means observational: a dispatch that already finished must never
# be failed by the act of recording it.
VELO_RECORD_ROOT="$TMP/root" "$BIN/velo-record" 100 --worktree /nonexistent-worktree \
  --worker w --model m --log /nonexistent.log --started bogus --rc 0 >/dev/null 2>&1
check "velo-record exits 0 on bad input" "$?" "0"


# ── records live in $VELO_STATE, not the repo (#2107 follow-up) ────────────
# They were in the repo AND gitignored, so a working-tree cleanup on 2026-09-19
# destroyed every row; 17 survived only because install.sh had copied them to
# ~/.agents/tasks, where nothing reads them. This is the history the re-dispatch
# guard reads — losing it silently re-enables #2000's blind re-dispatch.
echo
echo "record location"
if grep -q "VELO_STATE:-\$HOME/.agents/state}/records" "$HERE/../bin/velo-record"; then
  echo "  PASS  velo-record writes under \$VELO_STATE"
else
  echo "  FAIL  velo-record still writes into the repo"; FAILURES=$((FAILURES+1))
fi
if grep -q 'records/\${ISSUE}.result.jsonl' "$HERE/../bin/velo-dispatch"; then
  echo "  PASS  the guard reads the new location"
else
  echo "  FAIL  the guard does not read \$VELO_STATE/records"; FAILURES=$((FAILURES+1))
fi
# Legacy reads must survive, or the move blinds the guard for every existing row.
if grep -q 'reading LEGACY record location' "$HERE/../bin/velo-dispatch"; then
  echo "  PASS  legacy locations are still read, loudly"
else
  echo "  FAIL  no legacy fallback — the move would orphan existing history"; FAILURES=$((FAILURES+1))
fi

# ── provenance: no field may assert what nobody established (#2107) ────────
echo
echo "cost / model / leak provenance"
REC="$HERE/../bin/velo-record"; DISP="$HERE/../bin/velo-dispatch"
RUN="$HERE/../bin/velo-openai-agents-runner.py"

# 1. openrouter-billed had NO branch, so the gateway's real billed figure was
#    dropped and every row recorded usd:null under billed provenance — 35 of 35.
if grep -q 'if source == "openrouter-billed"' "$REC"; then
  echo "  PASS  the billed figure is promoted to usd"
else
  echo "  FAIL  openrouter-billed still falls through to usd:null"; FAILURES=$((FAILURES+1))
fi

# 2. the leak counter was a hardcoded 0 — the SAFE value — on a runtime that
#    never counted. Three consumers read it as measured. It then became an
#    honest `unmeasured`, and now it is a REAL count: the incumbent's detector
#    is ported (see test_leaked_tool_calls.py). What must never come back is a
#    constant, in either spelling.
if grep -q 'leaked_tool_calls={hooks.leaked}' "$RUN" \
   && ! grep -qE 'leaked_tool_calls=(0|unmeasured) ' "$RUN"; then
  echo "  PASS  the runner reports a measured leak count, not a constant"
else
  echo "  FAIL  leaked_tool_calls is a constant again (0 or unmeasured)"; FAILURES=$((FAILURES+1))
fi
if grep -q 'None if g("VR_LEAKED") == "unmeasured"' "$REC"; then
  echo "  PASS  unmeasured is recorded as null, not 0"
else
  echo "  FAIL  unmeasured would be coerced to 0 in the record"; FAILURES=$((FAILURES+1))
fi
# ...and must not be mistaken for an actual leak, which would fail every run.
if grep -q '!= "unmeasured"' "$REC"; then
  echo "  PASS  unmeasured does not promote the outcome to failed"
else
  echo "  FAIL  an unmeasured count would be treated as a leak"; FAILURES=$((FAILURES+1))
fi

# 3. the codex route recorded its ROUTE LABEL as its model, so 15 rows cannot be
#    attributed — on the most expensive tier.
if grep -q "MODEL_ID='codex'" "$DISP"; then
  echo "  FAIL  codex still records the route label as its model"; FAILURES=$((FAILURES+1))
else
  echo "  PASS  codex no longer records 'codex' as a model"
fi
if grep -q 'model_reasoning_effort' "$DISP"; then
  echo "  PASS  reasoning effort is recorded with the model"
else
  echo "  FAIL  effort is not recorded — high vs low is load-bearing"; FAILURES=$((FAILURES+1))
fi

# Summary LAST. It used to sit mid-file, so every block appended after it ran
# only when nothing earlier failed — and printed AFTER "all record checks
# passed", which was therefore a claim about part of the file. Two blocks were
# appended below it before anyone noticed (#2164's location checks and #2107's
# provenance checks); on any earlier failure both were skipped silently.
echo
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s)"
  exit 1
fi
echo "all record checks passed"

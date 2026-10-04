#!/usr/bin/env bash
# velo-gate-sweep — the one compact view of every gating PR (#2354).
#
# The sweep is the orchestrator's only cheap look at "what is blocking what", so
# its failure modes are about READING THE GATE STATE WRONG rather than crashing:
# showing a stale verdict as if it were current, printing an older Codex turn
# instead of the final one, mixing an older check-code round's verdict into the
# current one, or letting one unreadable PR cost the rest of the sweep. Each case
# below is one of those, and each was MUTATION-PROVED: the script line it covers
# was broken, the case went red with the message quoted in its comment, and the
# line was restored.
#
# Fixtures live in a throwaway VELO_STATE (the same override every sibling gate
# script honours — velo-gate-run:58, velo-pr-gate:156) and `gh` is a stub on PATH
# that APPLIES the script's real -q expression with real jq, exactly as
# test_merge_gates.sh does for velo-merge: the jq expression is half the script,
# and a stub that returned canned strings would not test it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$HERE/../bin/velo-gate-sweep"
RC=0
TMPD=$(mktemp -d)
# #2354 r4 (CLASS rule): every background process this test suite starts (fake
# gates, sleepers, subshells, `&` jobs, `nohup`) is killed AND reaped by an
# EXIT-trap-backed teardown registered at the top of this file — the happy
# path's `kill` is never the only teardown. Concrete defect: `kill "$FAKE"`
# signals the fake-gate shell only. Its background `sleep` survives — reparented
# to init, still in this suite's process group — so run.sh's leak detector
# (#2368/#2370, pgrep -g) marked test_gate_sweep.sh FAILED even when every
# check passed. Two-layer fix: (a) the trap kills the whole child tree of every
# tracked job on any exit path; (b) the fake gate itself forwards TERM to its
# sleep child, so even the direct `kill "$FAKE"` path leaves nothing behind.
BG_PIDS=""
bg_start() { BG_PIDS="$BG_PIDS $! "; }         # track the job just backgrounded (space-padded both ends so bg_done's pattern has boundaries)
bg_done()  { BG_PIDS="${BG_PIDS// $1 / }"; }   # explicit kill+wait done: stop tracking (a dead pid left in BG_PIDS risks killing a recycled pid's process at exit)
kill_tree() {  # <pid>: TERM the pid and its whole child tree, then KILL any holdout
  # Children are snapshotted BEFORE killing the parent: once the parent dies
  # they are reparented to init and `pgrep -P <pid>` finds nothing — the TERM
  # would then reach only the shell and leave the sleep behind, which is the
  # exact leak this function exists to close.
  local p=$1 kids
  kids=$(pgrep -P "$p" 2>/dev/null)
  kill "$p" 2>/dev/null || true
  if [[ -n $kids ]]; then kill $kids 2>/dev/null || true; fi
  sleep 0.1
  kids=$(pgrep -P "$p" 2>/dev/null)
  if [[ -n $kids ]]; then kill -9 $kids 2>/dev/null || true; fi
  kill -9 "$p" 2>/dev/null || true
}
kill_reap() {  # one-shot (re-entrant with the EXIT trap): kill+reap every tracked job
  local p
  [[ -n $BG_PIDS ]] || return 0
  for p in $BG_PIDS; do kill_tree "$p"; wait "$p" 2>/dev/null || true; done
  BG_PIDS=""
}
# No ERR trap: without `set -e`, ERR fires on EVERY unguarded failing command
# (the liveness poll loops' `grep -q && break` returns 1 routinely) and would
# kill the still-live fake gate mid-suite. EXIT covers every exit path: normal
# completion, a crash, or a signal all reach it.
trap 'kill_reap; rm -rf "$TMPD"' EXIT
# Registered before the first background job starts (below). Nothing survives
# this script past its own EXIT.
mkdir -p "$TMPD/bin" "$TMPD/state/gate"
STATE="$TMPD/state"

# PR numbers used here are 3000+, so no fixture can collide with a real PR.
HEAD9="a1b2c3d4e"; HEAD40="${HEAD9}00000000000000000000000000000ffff"
OLD9="0ld5ha9be"; OLD40="${OLD9}00000000000000000000000000000000000"

check() {  # label, haystack, needle
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-200)"; RC=1; fi
}
check_not() {
  if [[ "$2" != *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: did NOT want '$3': $(tr '\n' ' ' <<<"$2" | cut -c1-170)"; RC=1; fi
}

# ---- the gh stub ----------------------------------------------------------
# GH_VIEW_<pr>    the JSON blob `gh pr view --json` would return
# GH_CHECKS_<pr>  the TSV `gh pr checks` would return (\t escapes)
# GH_MISSING      space-separated PRs gh cannot see at all
# GH_CHECKS_FAIL  space-separated PRs whose `pr checks` read FAILS (network/API
#                 error): stderr + exit 1, so a failed read can never be confused
#                 with a successful read that returned no checks (#2358 P1)
cat > "$TMPD/bin/gh" <<'EOF'
#!/usr/bin/env bash
pair="$1 $2"; prn="$3"
if [[ " ${GH_MISSING:-} " == *" $prn "* ]]; then
  echo "could not fetch pull request: HTTP 404: Not Found" >&2; exit 1
fi
case "$pair" in
  "pr view")
    if [[ " ${GH_VIEW_EMPTY:-} " == *" $prn "* ]]; then
      exit 0   # gh succeeded and returned nothing — genuinely no view, rc 0
    fi
    var="GH_VIEW_$prn"; blob="${!var:-}"
    [[ -n "$blob" ]] || { echo "stub: no view fixture for $prn" >&2; exit 1; }
    JQF=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -q|--jq) JQF="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s' "$blob" | jq -r "$JQF"
    ;;
  "pr checks")
    if [[ " ${GH_CHECKS_FAIL:-} " == *" $prn "* ]]; then
      echo "HTTP 502: bad gateway (Issue) getting pull request checks" >&2
      echo "second stderr line that must never be printed" >&2
      exit 1
    fi
    var="GH_CHECKS_$prn"; printf '%b\n' "${!var:-}"
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMPD/bin/gh"

view_json() {  # head_sha state mergeable
  printf '{"headRefOid":"%s","state":"%s","mergeable":"%s"}' "$1" "$2" "$3"
}

# ---- fixtures -------------------------------------------------------------
CC_CHECKS='Build & Test\tpass\t3m12s\tBuild & Test\t\nIntegration Tests\tskipping\t0s\tIntegration Tests\t'

# (1) passed gate: verdict file present, head == gated. The report is DOUBLED as
# real codex-verdict.md files are (velo-gate-run appends the final message to a
# transcript that already holds it) — the sweep must de-duplicate, so the printed
# output carries the Verdict line exactly ONCE.
mk_passed() {
  local d="$STATE/gate/3001"; mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/codex-verdict.md" <<EOF
## Codex review — PR 3001 @ $HEAD9
**Verdict:** approve

### Findings
None.

### Refutation attempts that FAILED
- \`cargo fmt --all -- --check\` passed. The diff adds no swallowed error.
## Codex review — PR 3001 @ $HEAD9
**Verdict:** approve

### Findings
None.

### Refutation attempts that FAILED
- \`cargo fmt --all -- --check\` passed. The diff adds no swallowed error.
EOF
  cat > "$d/code.log" <<EOF
2026-10-04T00:00:00Z [prompt 1] tool start names=bash
## check-code — PR 3001 @ $HEAD9
**Verdict:** approve-with-findings

### Findings
**HIGH — src/z.rs:5 — the retry wrapper swallows its own Err.** Nothing upstream can see the failure.

MEDIUM src/a.rs:10 — the retry loop has no bound, a permanently failing call spins.

LOW src/a.rs:44 — the doc comment names a function that no longer exists. padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding TAIL-PAST-200-CHARACTERS-SENTINEL-ZZZ tail beyond the 200-char cut must never be printed.

### Refutation attempts that FAILED
- No test removed.
EOF
}

# (2) blocked gate: P* finding titles must survive the reduction
mk_blocked() {
  local d="$STATE/gate/3002"; mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/codex-verdict.md" <<'EOF'
## Codex review — PR 3002 @ a1b2c3d4e
**Verdict:** blocked

### Findings
- [P1] Preserve side-qualified window bounds in joins — src/velostream/sql/plan/builder.rs:1680-1683
- **P2 — src/x.rs:12.** The new absent-side test accepts Ok(vec![]), so a swallowed error passes.
- [P3] Over-long finding title whose tail must never reach the printed view: pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad CODX-TAIL-SENTINEL-ZZZ tail past the 260-char cut must never print.

### Refutation attempts that FAILED
- Tried to find a production caller that swallows the Err. Failed.
EOF
}

# (3) no gate at all: the dir does not exist
# (4) STALE: gated.sha != head
mk_stale() {
  local d="$STATE/gate/3004"; mkdir -p "$d"
  printf '%s\n' "$OLD9" > "$d/gated.sha"
  cat > "$d/codex-verdict.md" <<'EOF'
## Codex review — PR 3004 @ 0ld5ha9be
**Verdict:** approve

### Findings
None.
EOF
}

# (5) no codex-verdict.md → review.log tail after the LAST ^codex$ line. Two
# codex turns: an earlier one that BLOCKED, then the final approve. The verdict
# file was written by velo-gate-run from the final turn only.
mk_reviewlog() {
  local d="$STATE/gate/3005"; mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/review.log" <<EOF
codex
## Codex review — PR 3005 @ $HEAD9
**Verdict:** blocked

### Findings
- [P1] Obsolete first-round finding — src/gone.rs:1
codex
## Codex review — PR 3005 @ $HEAD9
**Verdict:** approve

### Findings
No actionable findings.
EOF
}

# (6) code.log with TWO rounds: only the LAST `## ` section may appear
mk_code_two_rounds() {
  local d="$STATE/gate/3006"; mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/codex-verdict.md" <<'EOF'
**Verdict:** approve
EOF
  cat > "$d/code.log" <<EOF
## check-code — PR 3006 @ oldsha1
**Verdict:** blocked

### Findings
HIGH src/old.rs:1 — the round-one HIGH that the fix addressed.

### Refutation attempts that FAILED
- none
2026-10-04T01:00:00Z sdk result status=success
## check-code — PR 3006 @ a1b2c3d4e
**Verdict:** approve-with-findings

### Findings
LOW src/new.rs:2 — a round-two LOW about the fix itself.
EOF
}

# (7) #2358 P2: an UNFINISHED or OFF-FORMAT Codex review must never print as a
# verdict. codex-verdict.md is velo-gate-run's cut of Codex's final message, so
# a verdict is printed ONLY when the file states one of the three canonical
# words. 3007: prose with no Verdict line — the outcome is still surfaced by the
# keyword reduction, but it is labelled INCOMPLETE. 3010/3011: a Verdict line
# whose word is none of the three ("needs-changes") — the verdict line is
# WITHHELD (an off-format word must not be printed as if it decided anything)
# while the finding titles still are. 3011 is the same without the bold template.
mk_incomplete_verdict() {
  local d="$STATE/gate/3007"; mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/codex-verdict.md" <<'EOF'
Codex: blocked — 2 findings, both in the watermark path. Details in the brief reply.
EOF
  export GH_CHECKS_3007="$CC_CHECKS"
  local d2="$STATE/gate/3010"; mkdir -p "$d2"
  printf '%s\n' "$HEAD9" > "$d2/gated.sha"
  cat > "$d2/codex-verdict.md" <<'EOF'
## Codex review — PR 3010 @ a1b2c3d4e
**Verdict:** needs-changes

### Findings
- [P1] Reject absent window-bound join keys — src/k.rs:252
EOF
  # 3011: the verdict spelled WITHOUT the bold template (`Verdict:` at no star
  # prefix) — carried by the grep's generic `Verdict` alternative alone.
  local d3="$STATE/gate/3011"; mkdir -p "$d3"
  printf '%s\n' "$HEAD9" > "$d3/gated.sha"
  cat > "$d3/codex-verdict.md" <<'EOF'
Verdict: needs-changes for 3011 — see the finding list.
EOF
  # 3012: review.log with NO ^codex$ marker at all (a check-code-only round
  # wrote the transcript but Codex never ran) — the sweep must say "(no gate
  # yet)" rather than print the whole transcript.
  local d4="$STATE/gate/3012"; mkdir -p "$d4"
  printf '%s\n' "$HEAD9" > "$d4/gated.sha"
  cat > "$d4/review.log" <<'EOF'
[local gate] velo-local plan leg finished
check-spec leg finished, rc=0
EOF
  # 3013: code.log with NO '## ' section (a run that died mid-stream)
  local d5="$STATE/gate/3013"; mkdir -p "$d5"
  printf '%s\n' "$HEAD9" > "$d5/gated.sha"
  cat > "$d5/codex-verdict.md" <<'EOF'
**Verdict:** approve
EOF
  printf 'sdk result status=error: stream closed before any report\n' > "$d5/code.log"
  # 3014: reports with MORE findings than the view may print — the per-leg caps
  # (6 codex lines, 8 check-code lines) are what keeps the sweep inside 30/PR.
  local d6="$STATE/gate/3014"; mkdir -p "$d6"
  printf '%s\n' "$HEAD9" > "$d6/gated.sha"
  { echo '**Verdict:** blocked'
    for i in $(seq 1 30); do echo "- [P1] finding number $i — src/f$i.rs:1"; done; } > "$d6/codex-verdict.md"
  { echo '## check-code — PR 3014 @ a1b2c3d4e'
    echo '**Verdict:** blocked'
    for i in $(seq 1 30); do echo "HIGH src/g$i.rs:1 — advisory finding $i"; done; } > "$d6/code.log"
  export GH_CHECKS_3010="$CC_CHECKS"
  export GH_CHECKS_3011="$CC_CHECKS"
  export GH_CHECKS_3014="$CC_CHECKS"
}

# (8)+(9) review.log final turns with no template line: the same keyword
# fallbacks on the transcript-tail path.
mk_keyword_reviewlog() {
  local d="$STATE/gate/3008"
  mkdir -p "$d"
  printf '%s\n' "$HEAD9" > "$d/gated.sha"
  cat > "$d/review.log" <<EOF
codex
## first pass, superseded
codex
Codex says: blocked. One finding stands.
- [P1] Do not advance HWM for all-NULL event times — src/s.rs:735
EOF
  local d2="$STATE/gate/3009"; mkdir -p "$d2"
  printf '%s\n' "$HEAD9" > "$d2/gated.sha"
  cat > "$d2/review.log" <<EOF
codex
No newly actionable findings; the round-one blocker is resolved by 5c1f2a3.
EOF
  export GH_CHECKS_3008="$CC_CHECKS"
  export GH_CHECKS_3009="$CC_CHECKS"
}

mk_passed; mk_blocked; mk_stale; mk_reviewlog; mk_code_two_rounds
mk_incomplete_verdict; mk_keyword_reviewlog
mkdir -p "$STATE/gate/3003"   # dir exists, empty: still "(no gate yet)"

export GH_VIEW_3001="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3002="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3003="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3004="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3005="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3006="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3007="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3008="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3009="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3010="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3011="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3012="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3013="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_VIEW_3014="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_CHECKS_3012="$CC_CHECKS"
export GH_CHECKS_3013="$CC_CHECKS"
export GH_VIEW_3098="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_CHECKS_3001="$CC_CHECKS"
export GH_CHECKS_3002="$CC_CHECKS"
export GH_CHECKS_3003="$CC_CHECKS"
export GH_CHECKS_3004="$CC_CHECKS"
export GH_CHECKS_3005="$CC_CHECKS"
export GH_CHECKS_3006='Build & Test\tfail\t2m4s\tBuild & Test\tjob exited 101'
export GH_MISSING="3999"

sweep() {  # run the real script against the fixture state
  VELO_STATE="$STATE" PATH="$TMPD/bin:$PATH" bash "$SWEEP" "$@" 2>&1
}

echo
echo "passed gate: head, gated sha, CI leg and the verdict lines"
OUT=$(sweep 3001)
check     "header carries the 9-char head sha"      "$OUT" "head=$HEAD9 OPEN MERGEABLE"
check     "the gated sha is shown"                  "$OUT" "gated=$HEAD9"
check_not "a matching sha is not flagged STALE"     "$OUT" "STALE"
check     "Build & Test is read from the TSV"       "$OUT" "ci=pass"
check     "the Codex Verdict line is printed"       "$OUT" "**Verdict:** approve"
check     "the check-code Verdict is printed"       "$OUT" "**Verdict:** approve-with-findings"
check     "the bold **HIGH —** headline is printed" "$OUT" "**HIGH — src/z.rs:5"
check     "the MEDIUM headline is printed"          "$OUT" "MEDIUM src/a.rs:10"
check     "the LOW headline is printed"             "$OUT" "LOW src/a.rs:44"
check_not "the check-code headline is cut at 200"   "$OUT" "TAIL-PAST-200-CHARACTERS-SENTINEL-ZZZ"
check_not "refutation prose is not swept"           "$OUT" "Refutation attempts"
check_not "the tool-log preamble is not swept"      "$OUT" "tool start names=bash"
# The report was written twice on disk; the sweep must de-duplicate it.
NV=$(printf '%s\n' "$OUT" | grep -c '^\*\*Verdict:\*\* approve$')
if [[ "$NV" == "1" ]]; then echo "  PASS  the repeated verdict file is de-duplicated"
else echo "  FAIL  verdict printed $NV times — dedup lost"; RC=1; fi

echo
echo "blocked gate: the Verdict and EACH finding title survive the reduction"
OUT=$(sweep 3002)
check     "blocked is shown"                        "$OUT" "**Verdict:** blocked"
check     "the [P1] finding title is shown"         "$OUT" "[P1] Preserve side-qualified window bounds in joins"
check     "the bold **P2 — file** finding is shown" "$OUT" "**P2 — src/x.rs:12.**"
check_not "the codex finding title is cut at 260"   "$OUT" "CODX-TAIL-SENTINEL-ZZZ"

echo
echo "no gate yet: an empty/absent gate dir is not an error"
OUT=$(sweep 3003)
check     "empty dir: codex leg says no gate yet"   "$OUT" "-- codex: (no gate yet)"
check     "empty dir: check-code says no gate yet"  "$OUT" "-- check-code (advisory): (no gate yet)"
check     "empty dir: gated=none"                   "$OUT" "gated=none"
check_not "an ungated PR is never flagged STALE"    "$OUT" "STALE"
OUT=$(sweep 3098)   # dir does not exist at all
check     "absent dir: still no gate yet"           "$OUT" "(no gate yet)"
check_not "absent dir: no shell error leaks"        "$OUT" "No such file or directory"
check_not "absent dir: nothing crashed"             "$OUT" "unbound variable"

echo
echo "STALE: a verdict for a sha that is no longer head must be flagged"
OUT=$(sweep 3004)
check     "head is the real head"                   "$OUT" "head=$HEAD9"
check     "the gated sha is the old one"            "$OUT" "gated=$OLD9"
check     "STALE is flagged"                        "$OUT" "STALE"

echo
echo "review.log fallback: only the LAST ^codex$ block, de-duplicated"
OUT=$(sweep 3005)
check     "the tail is labelled as review.log"      "$OUT" "-- codex (review.log tail):"
check     "the final Verdict is shown"              "$OUT" "**Verdict:** approve"
check_not "the earlier blocked turn is excluded"    "$OUT" "**Verdict:** blocked"
check_not "the earlier P1 finding is excluded"      "$OUT" "Obsolete first-round finding"

echo
echo "check-code: only the LAST '## ' section of code.log"
OUT=$(sweep 3006)
check     "the round-two verdict is shown"          "$OUT" "**Verdict:** approve-with-findings"
check     "the round-two LOW is shown"              "$OUT" "LOW src/new.rs:2"
check_not "the round-one HIGH is excluded"          "$OUT" "the round-one HIGH"
check_not "round one's blocked verdict excluded"    "$OUT" "**Verdict:** blocked"
check     "Build & Test failure is reported"        "$OUT" "ci=fail"

echo
echo "#2358 P2: an unfinished / off-format Codex verdict is INCOMPLETE, never a verdict"
OUT=$(sweep 3007)
check     "no Verdict line -> INCOMPLETE reason"    "$OUT" "codex: INCOMPLETE (no verdict line)"
check     "'blocked' in prose is still surfaced"    "$OUT" "Codex: blocked — 2 findings"
OUT=$(sweep 3010)
check     "off-format word -> INCOMPLETE names it"  "$OUT" "INCOMPLETE (verdict word 'needs-changes'"
check_not "the off-format Verdict line is withheld" "$OUT" "**Verdict:** needs-changes"
check     "its P1 title is shown"                   "$OUT" "[P1] Reject absent window-bound join keys"
OUT=$(sweep 3011)
check     "bare unbolded Verdict also classified"   "$OUT" "INCOMPLETE (verdict word 'needs-changes'"
check_not "no bare off-format verdict printed"      "$OUT" "Verdict: needs-changes for 3011"
echo
echo "keyword fallback on the review.log tail: blocked / No newly actionable"
OUT=$(sweep 3008)
check     "review.log 'blocked.' is surfaced"       "$OUT" "Codex says: blocked."
check     "its P1 title is surfaced"                "$OUT" "[P1] Do not advance HWM for all-NULL event times"
OUT=$(sweep 3009)
check     "'No newly actionable' is surfaced"       "$OUT" "No newly actionable findings"

echo
echo "malformed reports: a transcript with no ^codex$ marker, a code.log with no section"
OUT=$(sweep 3012)
check     "review.log with no marker: (no gate yet)" "$OUT" "-- codex: (no gate yet)"
check_not "the raw transcript body is not swept"    "$OUT" "check-spec leg finished"
OUT=$(sweep 3013)
check     "code.log with no '## ' section: (no gate yet)" "$OUT" "-- check-code (advisory): (no gate yet)"
check_not "the dead-run code.log body is not swept" "$OUT" "stream closed"

echo
echo "per-leg caps: a report with 30 findings still fits the 30-line budget"
OUT=$(sweep 3014)
NCX=$(printf '%s\n' "$OUT" | sed -n '/^-- codex:/,/^-- check-code/p' | grep -c 'finding number')
NCC=$(printf '%s\n' "$OUT" | sed -n '/^-- check-code/,$p' | grep -c 'advisory finding')
NL=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [[ "$NCX" == "5" && "$NCC" == "7" && "$NL" -le 30 ]]; then
  echo "  PASS  5 codex finding lines + 7 check-code lines, $NL lines total"
else echo "  FAIL  caps wrong: codex findings=$NCX (want 5), check-code=$NCC (want 7), lines=$NL"; RC=1; fi

# 3015: gh sees the PR, but CI has not reported any check yet (a fresh push) —
# the header must print ci=none rather than an empty field.
mkdir -p "$STATE/gate/3015"
export GH_VIEW_3015="$(view_json "$HEAD40" OPEN MERGEABLE)"
OUT_CI=$(sweep 3015)
echo
echo "a PR whose CI leg has not reported yet prints ci=none, not an empty field"
check     "ci=none on a PR with no checks"          "$OUT_CI" "ci=none"

echo
echo "gh cannot see the PR: an error line, and the sweep CONTINUES"
OUT=$(sweep 3999 3001)
check     "the dead PR prints an error line"        "$OUT" "#3999 ERROR"
check     "the next PR is still swept"              "$OUT" "=== #3001"
if [[ "$OUT" == *"#3999 ERROR"* && "$OUT" == *"=== #3001"* ]]; then
  echo "  PASS  sweep does not abort on a dead PR"
else echo "  FAIL  sweep aborted at the dead PR"; RC=1; fi
OUT=$(sweep 3999)
check_not "an unreadable PR prints no fake header"  "$OUT" "head="
# #2354 class: a FAILED view read and an empty successful one are different facts.
# 3999 fails (rc 1); 3020 succeeds with no output (rc 0).
export GH_VIEW_EMPTY="3020"
OUT=$(sweep 3999 3020)
check     "failed view read -> unreadable + gh msg" "$OUT" "#3999 ERROR: unreadable (gh failed to read PR #3999: could not fetch pull request: HTTP 404"
check     "empty view read -> not found"            "$OUT" "#3020 ERROR: not found"
check_not "empty view read never says unreadable"   "$OUT" "#3020 ERROR: unreadable"

echo
echo "#2358 P1: a FAILED gh pr checks read prints ci=ERROR, never ci=none"
export GH_VIEW_3016="$(view_json "$HEAD40" OPEN MERGEABLE)"
export GH_CHECKS_FAIL="3016"
OUT=$(sweep 3016)
check     "failed read prints ci=ERROR"            "$OUT" "ci=ERROR(HTTP 502: bad gateway (Issue) getting pull request checks)"
check_not "failed read never prints as ci=none"     "$OUT" "ci=none"
check_not "only the FIRST stderr line is printed"   "$OUT" "second stderr line"

echo
echo "#2358 P2: template placeholder / empty / unreadable verdict files"
# 3016 is reused above for ci; these use 3017-3019.
d="$STATE/gate/3017"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
cat > "$d/codex-verdict.md" <<EOF
## Codex review — PR 3017 @ $HEAD9
**Verdict:** approve | approve-with-findings | blocked

### Findings
- [P1] A real finding above an UNFILLED template — src/m.rs:1
EOF
export GH_VIEW_3017="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3017="$CC_CHECKS"
OUT=$(sweep 3017)
check     "unfilled template -> INCOMPLETE reason"  "$OUT" "INCOMPLETE (template placeholder"
check_not "the placeholder line is never printed"   "$OUT" "approve | approve-with-findings | blocked"
check     "the finding title still shown"           "$OUT" "[P1] A real finding above an UNFILLED template"
d="$STATE/gate/3018"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
: > "$d/codex-verdict.md"
export GH_VIEW_3018="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3018="$CC_CHECKS"
OUT=$(sweep 3018)
check     "empty verdict file -> INCOMPLETE empty"  "$OUT" "INCOMPLETE (empty)"
d="$STATE/gate/3019"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
printf '**Verdict:** approve\n' > "$d/codex-verdict.md"
chmod 000 "$d/codex-verdict.md"
export GH_VIEW_3019="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3019="$CC_CHECKS"
OUT=$(sweep 3019)
# NOTE: running as root (or on a filesystem ignoring mode bits) can still read a
# 000 file; then this fixture degrades to 'approve' and the check would be
# testing the OS, not the script — so only assert when the read really fails.
if ! cat "$d/codex-verdict.md" >/dev/null 2>&1; then
  check     "unreadable verdict -> INCOMPLETE unreadable" "$OUT" "INCOMPLETE (unreadable"
  check_not "an unread file never prints its verdict"     "$OUT" "**Verdict:** approve"
else
  echo "  SKIP  unreadable-file case: this user can read a 000 file (root); nothing to assert"
fi
chmod 644 "$d/codex-verdict.md"

echo
echo "#2354 r3: a COMPLETED report quoting the template words in a finding is not INCOMPLETE"
# P2: the placeholder scan ran over the WHOLE report, so a finished canonical
# review that quoted `approve | approve-with-findings | blocked` inside a
# finding (a refutation of the template itself) was classified as an unfilled
# template — its real approve suppressed, a completed review shown as unfinished.
# The scan inspects only the parsed Verdict line now.
d="$STATE/gate/3023"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
cat > "$d/codex-verdict.md" <<EOF
## Codex review — PR 3023 @ $HEAD9
**Verdict:** approve

### Findings
- [P2] Placeholder detection scanned the whole report, so this very line — quoting approve | approve-with-findings | blocked — was falsely INCOMPLETE — src/t.rs:83

### Refutation attempts that FAILED
- Reverted the scan; the quoted line made a completed verdict disappear. Confirmed.
EOF
export GH_VIEW_3023="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3023="$CC_CHECKS"
OUT=$(sweep 3023)
check     "quoted template still a canonical verdict" "$OUT" "**Verdict:** approve"
check_not "a quoted template is not INCOMPLETE"      "$OUT" "INCOMPLETE (template placeholder"
# MUTATION-PROOF: reverting cx_classify to whole-report placeholder grep turns
# the first check red ("wanted '**Verdict:** approve'") — verified by hand.
chmod 644 "$d/codex-verdict.md"

echo
echo "#2354 class: UNREADABLE review.log / code.log / gated.sha, never '(no gate yet)'"
# Each file EXISTS but cannot be read. Before the class sweep each failed read
# printed the ABSENT state's message — "(no gate yet)" / gated=none / no STALE
# flag — because awk's/grep's failure was discarded and n/gated stayed empty.
# chmod 000 degrades to readable when running as root; then these skip, as the
# 3019 case does — the check would test the OS, not the script.
unreadable_can_test=0
probe="$STATE/gate/probe-000"; printf 'x\n' > "$probe"; chmod 000 "$probe"
if ! cat "$probe" >/dev/null 2>&1; then unreadable_can_test=1; fi
chmod 644 "$probe"; rm -f "$probe"
if [[ $unreadable_can_test == 1 ]]; then
  d="$STATE/gate/3024"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
  printf 'x\ncodex\n**Verdict:** approve\n' > "$d/review.log"; chmod 000 "$d/review.log"
  export GH_VIEW_3024="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3024="$CC_CHECKS"
  OUT=$(sweep 3024)
  check     "unreadable review.log -> ERROR leg"      "$OUT" "-- codex: ERROR(unreadable review.log:"
  check_not "unreadable review.log never '(no gate yet)'" "$OUT" "-- codex: (no gate yet)"
  chmod 644 "$d/review.log"
  d="$STATE/gate/3025"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"
  printf '## sec\n**Verdict:** approve\n' > "$d/code.log"; chmod 000 "$d/code.log"
  export GH_VIEW_3025="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3025="$CC_CHECKS"
  OUT=$(sweep 3025)
  check     "unreadable code.log -> ERROR advisory"   "$OUT" "-- check-code (advisory): ERROR(unreadable code.log:"
  check_not "unreadable code.log never '(no gate yet)'" "$OUT" "-- check-code (advisory): (no gate yet)"
  chmod 644 "$d/code.log"
  d="$STATE/gate/3026"; mkdir -p "$d"; printf '%s\n' "$HEAD9" > "$d/gated.sha"; chmod 000 "$d/gated.sha"
  printf '**Verdict:** approve\n' > "$d/codex-verdict.md"
  export GH_VIEW_3026="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3026="$CC_CHECKS"
  OUT=$(sweep 3026)
  check     "unreadable gated.sha -> gated=ERROR"     "$OUT" "gated=ERROR(unreadable"
  check     "unreadable gated.sha -> STALE? not verified" "$OUT" "STALE?"
  chmod 644 "$d/gated.sha"
else
  echo "  SKIP  unreadable read cases: this user can read a 000 file (root)"
fi
# EMPTY gated.sha: readable, zero bytes — a gate that wrote nothing is NOT
# "never gated" (gated=none): the comparison is impossible and must not read as
# current. Readable, so it needs no root guard.
d="$STATE/gate/3027"; mkdir -p "$d"; : > "$d/gated.sha"
printf '**Verdict:** approve\n' > "$d/codex-verdict.md"
export GH_VIEW_3027="$(view_json "$HEAD40" OPEN MERGEABLE)"; export GH_CHECKS_3027="$CC_CHECKS"
OUT=$(sweep 3027)
check     "empty gated.sha -> gated=ERROR(empty)"    "$OUT" "gated=ERROR(empty"
check     "empty gated.sha -> STALE? not verified"   "$OUT" "STALE?"
check_not "empty gated.sha never reads as ungated"   "$OUT" "gated=none"

echo
echo "gate-running: the per-PR lock, validated by pid liveness AND command identity (#2358 P2)"
# A fake gate dispatch: named like the real command so `ps -ww -o command=`
# matches it, exactly as a real `velo-gate-run <pr>` process line would.
# #2358 P1: the script must NOT end on a bare `sleep`. Bash 3.2 exec-optimises
# the final simple command, so the pid becomes the sleep and `ps -ww -o
# command=` shows `sleep 10`, not `velo-gate-run` — the command-identity path
# this test exists to prove would never run. `sleep … & wait $!` ends on a
# builtin: the pid stays the named shell (what a real velo-gate-run looks like
# to ps), and kill still leaves no orphan that outlives the 10s sleep.
cat > "$TMPD/bin/velo-gate-run" <<'EOF'
#!/usr/bin/env bash
# #2354 r4: kill signals THIS shell; without the trap its background `sleep`
# survives the shell's death (reparented, same pgid). Forward TERM to the child
# so every kill of the fake — the in-test one and the suite's EXIT trap — takes
# the whole tree. Still ends on the `wait` builtin, so the pid keeps the
# `velo-gate-run` command identity the sweep's ps read depends on (#2358 P1).
sleep "${FAKE_GATE_SECONDS:-10}" &
CHILD=$!
trap 'kill "$CHILD" 2>/dev/null' TERM INT
wait $!
EOF
chmod +x "$TMPD/bin/velo-gate-run"
# live: the gate's OWN lock, written the way velo-pr-gate writes it — .lock dir
# with the holder's pid inside.
"$TMPD/bin/velo-gate-run" 3007 scope.md >/dev/null 2>&1 &
FAKE=$!
bg_start
# Bounded wait until the process is visible with its own name on the command
# line — what the sweep's `ps -ww -o command=` read will see.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ps -ww -o command= -p "$FAKE" 2>/dev/null | grep -q "velo-gate-run" && break
  sleep 0.2
done
mkdir -p "$STATE/gate/3007/.lock"
echo "$FAKE" > "$STATE/gate/3007/.lock/pid"
OUT=$(sweep 3007)
check     "live lock holder is counted"             "$OUT" "gate-running=1"
check_not "a live lock is not flagged stale"        "$OUT" "STALE-LOCK"
# Teardown is kill_tree (the pid AND its child tree) + wait, not a bare kill:
# the fake gate forwards TERM to its sleep child since #2354 r4, but the suite
# must not depend on the fixture's cooperation — kill_tree is the CLASS rule,
# and the EXIT trap re-runs it harmlessly if anything below exits early.
kill_tree "$FAKE"
wait "$FAKE" 2>/dev/null || true
bg_done "$FAKE"
# stale: the lock survives, its holder does not (gate killed -9).
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$FAKE" 2>/dev/null || break; sleep 0.2; done
OUT=$(sweep 3007)
check     "dead holder: gate-running=0"             "$OUT" "gate-running=0"
check     "dead holder: STALE-LOCK flagged"         "$OUT" "STALE-LOCK(no live holder pid)"
# pid recycled by an UNRELATED process: alive, but not a gate.
sleep 30 &
BOGUS=$!
bg_start
echo "$BOGUS" > "$STATE/gate/3007/.lock/pid"
OUT=$(sweep 3007)
check     "recycled pid: gate-running=0"            "$OUT" "gate-running=0"
check     "recycled pid: flagged not a gate"        "$OUT" "STALE-LOCK(pid $BOGUS: not a gate process)"
kill_tree "$BOGUS"
wait "$BOGUS" 2>/dev/null || true
bg_done "$BOGUS"
# no lock at all: the healthy idle state — 0, and NO stale flag.
rm -rf "$STATE/gate/3007/.lock"
OUT=$(sweep 3007)
check     "no lock reads 0"                         "$OUT" "gate-running=0"
check_not "no lock is not flagged stale"            "$OUT" "STALE-LOCK"
# #2354 class: the lock EXISTS but its pid read FAILS — that is not "no live
# holder pid" (a claim about the holder the sweep cannot make) and not the
# absent state either. chmod-guarded like the other unreadable cases.
if [[ $unreadable_can_test == 1 ]]; then
  mkdir -p "$STATE/gate/3007/.lock"; printf '4242\n' > "$STATE/gate/3007/.lock/pid"
  chmod 000 "$STATE/gate/3007/.lock/pid"
  OUT=$(sweep 3007)
  check     "unreadable lock pid -> gate-running=ERROR" "$OUT" "gate-running=ERROR(lock pid file unreadable:"
  chmod 644 "$STATE/gate/3007/.lock/pid"
fi
# empty / malformed pid files: readable, so no root guard.
: > "$STATE/gate/3007/.lock/pid"
OUT=$(sweep 3007)
check     "empty pid file -> STALE-LOCK empty"      "$OUT" "STALE-LOCK(pid file empty"
check_not "empty pid file never claims no-live-holder" "$OUT" "STALE-LOCK(no live holder pid)"
printf 'not-a-pid\n' > "$STATE/gate/3007/.lock/pid"
OUT=$(sweep 3007)
check     "malformed pid file -> STALE-LOCK malformed" "$OUT" "STALE-LOCK(pid file malformed: 'not-a-pid')"
rm -rf "$STATE/gate/3007/.lock"

echo
echo "compact: at most 30 lines per PR"
OUT=$(sweep 3001 3002 3004 3005 3006)
N5=$(printf '%s\n' "$OUT" | grep -c '^=== ')
L5=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [[ "$N5" == "5" ]] && (( L5 <= 5 * 30 )); then
  echo "  PASS  $L5 lines across $N5 PRs (<= 30 each)"
else echo "  FAIL  $L5 lines across $N5 PRs"; RC=1; fi

echo
echo "never writes: the gate state is byte-identical after a sweep"
BEFORE=$(cd "$STATE" && find . -type f | sort | xargs shasum | shasum)
sweep 3001 3002 3003 3004 3005 3006 3999 >/dev/null
AFTER=$(cd "$STATE" && find . -type f | sort | xargs shasum | shasum)
if [[ "$BEFORE" == "$AFTER" ]]; then echo "  PASS  gate state unchanged"; else echo "  FAIL  sweep wrote to the gate state"; RC=1; fi

echo
echo "usage: no arguments is a usage error, not a silent success"
OUT=$(VELO_STATE="$STATE" PATH="$TMPD/bin:$PATH" bash "$SWEEP" 2>&1); rc=$?
check     "usage is printed"                        "$OUT" "usage: velo-gate-sweep"
if [[ "$rc" == "2" ]]; then echo "  PASS  exits 2"; else echo "  FAIL  exit $rc, want 2"; RC=1; fi

echo
[[ $RC -eq 0 ]] && echo "all velo-gate-sweep checks passed" || echo "FAILURES"
exit $RC

#!/bin/bash
# END-TO-END gate-health + brief-reuse checks, driving the REAL velo-pr-gate.
#
# Two defects live here, both found by review rounds on #2027:
#
# ROUND 7 — #2005's `codex_health_check` was wired to `code-review` and not to
# `check-code`, which is dispatched FIRST and whose PID went straight into its
# `ok` message and was discarded. A check-code dying on quota still ended with
# `ok gate:running` — the exact state #2005 exists to prevent, in the gate it
# happened not to watch.
#
# ROUND 8 — brief reuse meant only "does not contain the FILL THIS IN
# placeholder", and $OUT is a long-lived path in shared /tmp. Observed live: the
# reused file's entire contents were `filled attack section`, a placeholder
# written to get past the stub check. The script announced `ok reusing filled
# brief`, silently discarded the scope file passed on the command line, and
# dispatched a review briefed on nothing.
#
# The test uses its OWN PR number so it can never read or clobber the real
# /tmp/gate-<pr>-review-brief.md. An earlier cut of this file did not, and two
# cases passed only because they were reusing a brief left behind by a live run —
# green for a reason that had nothing to do with the code under test.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/bin/velo-pr-gate"
FAILURES=0
# A PR number unique to THIS process, not a fixed 999999.
#
# Artefacts now live under a per-run VELO_STATE (below), so this no longer
# guards against a cross-worktree collision in /tmp — it keeps the PR namespace
# distinct WITHIN a run, and keeps stray files obviously test-owned.
#
# Kept because the history is instructive: with a fixed 999999 in /tmp, two
# `run.sh` runs from different worktrees deleted each other's files and the loser
# failed on an unrelated gate assertion. That is #2040 exactly — fixed in
# tests/velo_sql_test.rs (#2041) while this file shipped the same defect the same
# day, in the suite whose purpose is catching it.
#
# Must stay numeric: velo-pr-gate requires ^[0-9]+$. Kept far above any real PR
# number so a stray file is obviously a test artifact.
TPR=$(( 900000 + ($$ % 90000) ))
# Same reasoning for the stub marker: `pkill -f velo-test-gate-sleep` matched
# EVERY concurrent run's stubs, so two suites killed each other's reviewers and
# one reported `Terminated: 15`. Caught by actually running two at once.
MARKER="velo-test-gate-sleep-$$"
TMPD=$(mktemp -d)
# A PRIVATE state root, exported so velo-pr-gate uses it. A test run must never
# read, overwrite or PRUNE real gate artefacts — and this file's prune case
# deliberately ages a directory past the 7-day threshold, which against the real
# root would delete someone's in-flight gate.
export VELO_STATE="$TMPD/state"
# This file pins the DISPATCHED check-code leg: its health check, the quota-death
# refusal and the claude stub below. That is the opus route, which is opt-in now
# that the default hands check-code to a read-only Sonnet agent the orchestrator
# launches (nothing for a health check to watch). Select the route explicitly so
# every assertion here keeps testing the code it names; the default route has its
# own end-to-end coverage in test_gate_check_code_mode.sh.
export VELO_CHECK_CODE=opus
BRIEF="$VELO_STATE/gate/${TPR}/review-brief.md"
FLAG="$TMPD/running.flag"
cleanup() {
  pkill -f "$MARKER" 2>/dev/null
  rm -rf "$TMPD"
  # EVERY file velo-pr-gate derives from the PR number, not the three I happened
  # to think of. The earlier list omitted -code-brief.md, and with a per-process
  # TPR that turned one reused file into a NEW leaked file on every run: /tmp
  # already held gate-959197, gate-960256..8, gate-999999 and gate-888888 code
  # briefs from a single afternoon. Fixing a race by leaking is not fixing it.
  # Nothing to hand-enumerate now: the whole state root is inside $TMPD.
}
trap cleanup EXIT
rm -f "$BRIEF" "$BRIEF".superseded.*

mkdir -p "$TMPD/bin" "$TMPD/home/.agents/bin"
WTPATH="$(cd "$HERE/../.." && pwd)"
BRANCH="$(git -C "$WTPATH" branch --show-current 2>/dev/null)"
[[ -n "$BRANCH" ]] || { echo "  SKIP  not on a branch"; exit 0; }

# velo-pr-gate REFUSES an empty diff range ("reviewing an empty diff yields a
# vacuous approve"), so from a checkout with nothing ahead of origin/master it
# never reaches the dispatch code and every assertion below fails for a reason
# that has nothing to do with the code under test. That is what happened the
# moment #2027 merged and the suite was first run from the main checkout: seven
# FAILs, all environmental. Skip loudly instead — a suite that goes red for the
# wrong reason trains people to ignore it.
if [[ "$(git -C "$WTPATH" rev-list --count origin/master..HEAD 2>/dev/null || echo 0)" == "0" ]]; then
  echo "  SKIP  $WTPATH has nothing ahead of origin/master — velo-pr-gate refuses"
  echo "        an empty diff range, so the gate-health cases cannot run here."
  echo "        Run this from a feature worktree with at least one commit."
  exit 0
fi

cat > "$TMPD/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *headRefName*) echo "$BRANCH";;
  *baseRefName*) echo "master";;
  *)             echo "";;
esac
EOF
cat > "$TMPD/home/.agents/bin/velo-gate" <<EOF
#!/bin/bash
case "\$*" in
  *--plan*)    echo "needs: check-code code-review"; exit 0;;
  *--running*) echo set > "$FLAG"; exit 0;;
esac
exit 0
EOF
chmod +x "$TMPD/bin/gh" "$TMPD/home/.agents/bin/velo-gate"

make_codex() {
  if [[ "$1" == "kill-check-code" ]]; then
    sed "s/MARKERTOKEN/$MARKER/" > "$TMPD/bin/codex" <<'EOF'
#!/bin/bash
IN=$(cat)
if grep -q "CHECK-CODE gate" <<<"$IN"; then echo "quota exceeded"; exit 1; fi
exec -a MARKERTOKEN sleep 400
EOF
  else
    sed "s/MARKERTOKEN/$MARKER/" > "$TMPD/bin/codex" <<'EOF'
#!/bin/bash
cat >/dev/null; exec -a MARKERTOKEN sleep 400
EOF
  fi
  chmod +x "$TMPD/bin/codex"

  # check-code runs on `claude`, not `codex`, since #2134 routed it to
  # opus --effort high. This suite stubbed only codex, so `command -v claude`
  # failed inside the sandboxed PATH, check-code never dispatched, and the
  # all-healthy case could not set its flag — reported as "healthy gates were
  # refused — the check is now over-broad", which named the wrong cause.
  #
  # It went unnoticed because this suite SKIPs from the master checkout (it
  # needs a commit ahead of origin/master for velo-pr-gate's diff range), so
  # #2134 shipped green without this file ever executing. A SKIP is not a pass.
  if [[ "$1" == "kill-check-code" ]]; then
    sed "s/MARKERTOKEN/$MARKER/" > "$TMPD/bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null; echo "quota exceeded"; exit 1
EOF
  else
    sed "s/MARKERTOKEN/$MARKER/" > "$TMPD/bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null; exec -a MARKERTOKEN sleep 400
EOF
  fi
  chmod +x "$TMPD/bin/claude"
}

SCOPE="$TMPD/scope.md"
printf '# Scope\n\nReal scope text for the gate-health test.\n' > "$SCOPE"

invoke() {
  rm -f "$FLAG"
  HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" \
    bash "$GATE" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
  pkill -f "$MARKER" 2>/dev/null
  sleep 1
}

fill_attack() {
  python3 - "$BRIEF" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = re.sub(r'^<<<.*?>>>\s*$\n?', '', t, flags=re.M | re.S)
p.write_text(t.replace("## ATTACK\n\n", "## ATTACK\n\nreal attack content\n\n", 1))
PY
}

# Prime: first invocation regenerates the template and refuses; fill ATTACK, so
# the run under test actually dispatches. This mirrors real two-step usage and
# makes the test independent of whatever is lying in /tmp.
prime_and_run() {
  invoke
  [[ -f "$BRIEF" ]] && grep -q "FILL THIS IN" "$BRIEF" && fill_attack
  invoke
}

echo "gate health (end-to-end, real velo-pr-gate)"

make_codex kill-check-code
prime_and_run
if [[ -f "$FLAG" ]]; then
  echo "  FAIL  check-code died on quota but gate:running was still set"; FAILURES=$((FAILURES+1))
else
  echo "  PASS  check-code death refuses gate:running"
fi
if grep -q "check-code did NOT run" "$TMPD/out.txt"; then
  echo "  PASS  the dead gate is named in the failure message"
else
  echo "  FAIL  failure message does not name check-code"; FAILURES=$((FAILURES+1))
fi

make_codex all-healthy
invoke
if [[ -f "$FLAG" ]]; then
  echo "  PASS  two healthy gates still set gate:running"
else
  echo "  FAIL  healthy gates were refused — the check is now over-broad"; FAILURES=$((FAILURES+1))
fi

echo "brief reuse"
rm -f "$BRIEF" "$BRIEF".superseded.*
printf 'filled attack section\n' > "$BRIEF"
invoke
if grep -q "reusing filled brief" "$TMPD/out.txt"; then
  echo "  FAIL  a one-line stub was accepted as a filled brief"; FAILURES=$((FAILURES+1))
elif grep -q "discarding a brief that is not for this review" "$TMPD/out.txt"; then
  echo "  PASS  stub brief discarded, not reused"
else
  echo "  FAIL  stub neither reused nor discarded — unexpected path"; FAILURES=$((FAILURES+1))
fi
if grep -q "unfilled ## ATTACK" "$TMPD/out.txt"; then
  echo "  PASS  regenerated brief refuses to dispatch until ATTACK is filled"
else
  echo "  FAIL  did not refuse an unfilled regenerated brief"; FAILURES=$((FAILURES+1))
fi

fill_attack
invoke
if grep -q "reusing filled brief" "$TMPD/out.txt"; then
  echo "  PASS  filled brief with a matching trailer IS reused"
else
  echo "  FAIL  guard broke the hand-filled-brief workflow it exists to protect"; FAILURES=$((FAILURES+1))
fi

# A brief valid for THIS scope must stop being valid when the scope changes —
# otherwise round 8's actual bug (a new scope file silently discarded) survives.
printf '# Scope\n\nDIFFERENT scope: round N+1 targets something else entirely.\n' > "$SCOPE"
invoke
if grep -q "discarding a brief that is not for this review" "$TMPD/out.txt"; then
  echo "  PASS  changing the scope file invalidates the brief"
else
  echo "  FAIL  a new scope file was silently discarded — round 8's bug is back"
  FAILURES=$((FAILURES+1))
fi

# codex absent entirely: NOTHING is dispatched, so the gate must not claim to be
# running (#2005 acceptance criterion 1). CODEX_FAILED only distinguishes
# "dispatched and died" from "dispatched and lived"; it says nothing about "never
# dispatched", and that branch set gate:running with no reviewer at all.
rm -f "$BRIEF" "$BRIEF".superseded.*
invoke                       # regenerate template
[[ -f "$BRIEF" ]] && grep -q "FILL THIS IN" "$BRIEF" && fill_attack
# Remove ONLY codex — keep the stub gh and velo-gate on PATH. Dropping to a bare
# PATH takes `gh` with it, the script dies at the head-branch lookup long before
# any dispatch, and the "gate:running was not set" assertion then passes for a
# reason that has nothing to do with the code under test. That false green is the
# same defect this whole file exists to catch.
# PATH must contain the stubs and the system utilities and NOTHING ELSE. With
# "$TMPD/bin:$PATH" the REAL codex is still reachable, so this case dispatched a
# real review — nondeterministic, quota-burning, and testing the opposite branch.
# BOTH reviewer CLIs must go, not just codex. Since #2134 the two gates run on
# different binaries — code-review on `codex`, check-code on `claude` — so
# removing codex alone no longer means "nothing is dispatched": check-code still
# runs, GATE_DISPATCHED is set, and gate:running is claimed correctly. The
# assertion below is about the NOTHING-dispatched branch, so the fixture has to
# actually produce nothing.
rm -f "$FLAG" "$TMPD/bin/codex" "$TMPD/bin/claude"
HOME="$TMPD/home" PATH="$TMPD/bin:/usr/bin:/bin" \
  bash "$GATE" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
if command -v codex >/dev/null 2>&1 && PATH="$TMPD/bin:/usr/bin:/bin" command -v codex >/dev/null 2>&1; then
  echo "  FAIL  codex still reachable — the absent-codex case did not run"
  FAILURES=$((FAILURES+1))
fi
if grep -qE "could not read head branch|no local worktree" "$TMPD/out.txt"; then
  echo "  FAIL  script died before the dispatch section — case never exercised"
  FAILURES=$((FAILURES+1))
fi
if [[ -f "$FLAG" ]]; then
  echo "  FAIL  gate:running set with codex absent and nothing dispatched"
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  nothing dispatched -> gate:running refused"
fi
if grep -q "NOTHING was dispatched" "$TMPD/out.txt"; then
  echo "  PASS  says plainly that nothing was dispatched"
else
  echo "  FAIL  did not explain why the gate was refused"; FAILURES=$((FAILURES+1))
fi

# ---- one gate per PR at a time (#2040 class, same-PR case) ------------------
#
# Different PRs cannot collide: every /tmp path is keyed by PR number. Two gates
# on the SAME PR share the brief and both logs, so the second overwrites files
# the first is still writing and codex is still reading. The lock refuses rather
# than letting two interleave into a report neither wrote.
LOCK="$VELO_STATE/gate/${TPR}/.lock"
rm -rf "$LOCK"
mkdir -p "$(dirname "$LOCK")" "$LOCK"; echo $$ > "$LOCK/pid"          # a LIVE holder: this shell
HOME="$TMPD/home" PATH="$TMPD/bin:/usr/bin:/bin" \
  bash "$GATE" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
if grep -q "a gate is already running for #$TPR" "$TMPD/out.txt"; then
  echo "  PASS  second gate on the same PR is refused"
else
  echo "  FAIL  concurrent gate on the same PR was NOT refused"; FAILURES=$((FAILURES+1))
fi

# A holder that is gone must not block the PR forever — a gate killed mid-run
# would otherwise need someone to notice a stray directory.
rm -rf "$LOCK"; mkdir -p "$(dirname "$LOCK")" "$LOCK"; echo 999999999 > "$LOCK/pid"   # dead pid
make_codex all-healthy
invoke
if grep -q "removing a stale gate lock" "$TMPD/out.txt"; then
  echo "  PASS  stale lock (dead holder) is taken over"
else
  echo "  FAIL  stale lock was not reclaimed — the PR is wedged"; FAILURES=$((FAILURES+1))
fi
if [[ -d "$LOCK" ]]; then
  echo "  FAIL  lock not released on exit — next gate would be refused forever"
  FAILURES=$((FAILURES+1))
  rm -rf "$LOCK"
else
  echo "  PASS  lock released on exit"
fi

# ---- /tmp pruning actually fires -------------------------------------------
#
# The first cut used `find /tmp -maxdepth 1 ...`, which is a SILENT NO-OP on
# macOS: /tmp is a symlink to private/tmp and find will not traverse a symlink
# start point unless told to. It deleted nothing and reported success — a
# housekeeping step that looked done for as long as nobody measured it.
#
# This drives the real gate and asserts on the filesystem, because the failure
# mode is precisely "the command ran and did nothing".
OLDF="$VELO_STATE/gate/OLDPROBE/x.log"
mkdir -p "$(dirname "$OLDF")"; : > "$OLDF"
touch -t 202601010000 "$(dirname "$OLDF")"   # the DIRECTORY is the prune unit
NEWF="$VELO_STATE/gate/${TPR}/freshprobe.log"
mkdir -p "$(dirname "$NEWF")"; : > "$NEWF"
make_codex all-healthy
invoke
if [[ -f "$OLDF" ]]; then
  echo "  FAIL  stale /tmp gate file was not pruned (find is a no-op again?)"
  FAILURES=$((FAILURES+1)); rm -f "$OLDF"
else
  echo "  PASS  stale /tmp gate file pruned"
fi
if [[ -f "$NEWF" ]]; then
  echo "  PASS  recent gate file kept — prune is age-bounded, not a wipe"
  rm -f "$NEWF"
else
  echo "  FAIL  prune deleted a FRESH file — it would eat a live gate's log"
  FAILURES=$((FAILURES+1))
fi

# The stub reviewers must not outlive the test. `pkill -f velo-test-gate-sleep`
# silently matched NOTHING until the marker moved into argv[0] via `exec -a`:
# the string was only ever written to stdout, so every run leaked its stubs for
# 400s (#2027 round 8, P2). Assert the cleanup rather than trusting it.
sleep 1
LEAKED=$(pgrep -f "$MARKER" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LEAKED" == "0" ]]; then
  echo "  PASS  no stub reviewers leaked"
else
  echo "  FAIL  $LEAKED stub reviewer(s) still running — pkill is not matching them"
  FAILURES=$((FAILURES+1))
fi

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all gate-health checks passed"

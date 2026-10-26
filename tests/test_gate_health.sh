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
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

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
# that the default hands check-code to the free OpenRouter leg the script dispatches
# (its own health path), and the sonnet route to an agent the orchestrator launches. Select the route explicitly so
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

# The branch's fork point: an ancestor of HEAD, and not HEAD itself (the check above needs commits
# ahead of origin/master). Not origin/master, which is only an ancestor while master has not moved on.
GATE_BASE_SHA=$(git -C "$WTPATH" merge-base origin/master HEAD)
cat > "$TMPD/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *headRefName*) echo "$BRANCH";;
  *baseRefName*) echo "\${VELO_TEST_BASE:-master}";;
  *comments*)
    # VELO_TEST_COMMENTS is what the read of the PR's gate comments gives: a failed read, "null" (no
    # review recorded), a sha that does not exist any more (a rebase orphaned it), or the fork point
    # (a review that is an ancestor of the head). Unset: an empty answer.
    case "\${VELO_TEST_COMMENTS:-}" in
      fail)   echo "gh: HTTP 502" >&2; exit 1;;
      none)   echo "null";;
      orphan) echo "1111111111111111111111111111111111111111";;
      ok)     echo "$GATE_BASE_SHA";;
      *)      echo "";;
    esac;;
  *)             echo "";;
esac
EOF
cat > "$TMPD/home/.agents/bin/velo-gate" <<EOF
#!/bin/bash
case "\$*" in
  *--plan*)    : > "$TMPD/plan.called"; echo "needs: check-code code-review"; exit 0;;
  *--running*)
    # VELO_TEST_RUNNING_FAIL: velo-gate cannot set the label (an edit refused, gh down).
    if [[ -n "\${VELO_TEST_RUNNING_FAIL:-}" ]]; then
      printf '\n\033[31mERROR:\033[0m could not set gate:running: label edit failed\n\n' >&2; exit 1
    fi
    echo set > "$FLAG"; exit 0;;
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

stubs_gone() {   # until the killed stubs are gone; up to 1s, not a fixed 1s
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$MARKER" >/dev/null || return 0; sleep 0.1; done
}

invoke() {
  rm -f "$FLAG"
  HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" \
    bash "$GATE" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
  INVOKE_RC=$?
  pkill -f "$MARKER" 2>/dev/null
  stubs_gone
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

# A gate:running that velo-gate could not record used to vanish: the call's output and status went
# to /dev/null and the only trace was the ABSENCE of an "ok gate:running" line. The reviewers are
# running, but velo-orchestrd follows only gate:running PRs, so nobody would pick the results up.
make_codex all-healthy
export VELO_TEST_RUNNING_FAIL=1
invoke
unset VELO_TEST_RUNNING_FAIL
if grep -q "could not record gate:running for #$TPR" "$TMPD/out.txt"; then
  echo "  PASS  a gate:running that could not be set is said, not silently dropped"
else
  echo "  FAIL  velo-gate refused gate:running and the script said nothing"; FAILURES=$((FAILURES+1))
fi
if grep -q "label edit failed" "$TMPD/out.txt"; then
  echo "  PASS  and carries velo-gate's own reason"
else
  echo "  FAIL  the warning does not carry velo-gate's reason"; FAILURES=$((FAILURES+1))
fi
if ! grep -q "ok gate:running" "$TMPD/out.txt"; then
  echo "  PASS  and does not claim gate:running"
else
  echo "  FAIL  claimed gate:running although it was not recorded"; FAILURES=$((FAILURES+1))
fi
if grep -q "code-review -> codex (pid" "$TMPD/out.txt" && grep -q "still running after" "$TMPD/out.txt"; then
  echo "  PASS  the reviewers are dispatched and alive (the warning does not abort the round)"
else
  echo "  FAIL  the round did not carry on past the failed label: $(tail -5 "$TMPD/out.txt")"; FAILURES=$((FAILURES+1))
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

# ---- a lock whose holder cannot be told is not a stale lock ------------------------
#
# The holder was read as `cat pid 2>/dev/null || echo ""`, and "no live holder pid" was the whole
# stale-lock test — so EVERY state in which a pid could not be learned counted as a dead holder, and
# its lock was removed: no pid file yet (the owner has made the directory and not yet written its
# pid — a gate that has only just started), an empty one (mid-write), one that names no pid, one
# that cannot be read. A second gate then started over the first, which is the interleaving the lock
# exists to prevent. velo-gate-sweep (#2358) already tells these states apart; here a lock is taken
# over only from a holder KNOWN to be gone, a pid that has not been written yet is waited for, and
# any other holder is refused with the reason.
set_lock_absent()     { :; }
set_lock_empty()      { : > "$LOCK/pid"; }
set_lock_garbage()    { echo "not-a-pid" > "$LOCK/pid"; }
set_lock_unreadable() { echo $$ > "$LOCK/pid"; chmod 000 "$LOCK/pid"; }
# The owner writes its pid a moment late: 0.3s after the gate has asked for its plan, which happens
# a few milliseconds before the gate reaches the lock. Timed from the gate's own progress, not from
# the clock, so a loaded host that starts the gate slowly still has it read the lock BEFORE the pid
# exists — which is the state this case is about. Bounded: a gate that never asks leaves no writer.
LATE_JOB=""
set_lock_late_pid() {
  rm -f "$TMPD/plan.called"
  ( for _w in $(seq 1 500); do [[ -e "$TMPD/plan.called" ]] && break; sleep 0.02; done
    sleep 0.3; echo "$LATE_PID" > "$LOCK/pid" ) &
  LATE_JOB=$!
}
LATE_PID=$$   # a live pid: this shell ($$ does not change in the writer's subshell)

unknown_holder_case() {   # <velo-pr-gate> <setup fn> <expected text> <expect: refused|already-running>
  local gate="$1" setup="$2" want="$3" kind="$4"
  UNKNOWN_FAILS=""
  rm -rf "$LOCK"; mkdir -p "$(dirname "$LOCK")" "$LOCK"
  "$setup"
  rm -f "$FLAG"
  HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" bash "$gate" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
  local rc=$?
  [[ -z "$LATE_JOB" ]] || { wait "$LATE_JOB" 2>/dev/null; LATE_JOB=""; }
  pkill -f "$MARKER" 2>/dev/null
  stubs_gone
  [[ $rc -ne 0 ]]                                                || UNKNOWN_FAILS="$UNKNOWN_FAILS refuses"
  grep -qF -- "$want" "$TMPD/out.txt"                            || UNKNOWN_FAILS="$UNKNOWN_FAILS says-$kind"
  ! grep -q "removing a stale gate lock" "$TMPD/out.txt"         || UNKNOWN_FAILS="$UNKNOWN_FAILS does-not-call-it-stale"
  [[ -d "$LOCK" ]]                                               || UNKNOWN_FAILS="$UNKNOWN_FAILS the-lock-is-left-in-place"
  [[ ! -f "$FLAG" ]]                                             || UNKNOWN_FAILS="$UNKNOWN_FAILS nothing-was-started"
  chmod 600 "$LOCK/pid" 2>/dev/null
  rm -rf "$LOCK"
}
make_codex all-healthy
UNREADABLE_OK=1
echo ok > "$TMPD/readable.probe"; chmod 000 "$TMPD/readable.probe"
if cat "$TMPD/readable.probe" >/dev/null 2>&1; then UNREADABLE_OK=0; fi   # root reads everything
chmod 600 "$TMPD/readable.probe"
for spec in "empty:set_lock_empty:has an empty pid file" \
            "garbage:set_lock_garbage:which is not a pid" \
            "absent:set_lock_absent:has no pid file" \
            "late-pid:set_lock_late_pid:a gate is already running for #$TPR (pid $LATE_PID)" \
            "unreadable:set_lock_unreadable:has a pid file that cannot be read"; do
  name="${spec%%:*}"; rest="${spec#*:}"; setup="${rest%%:*}"; want="${rest#*:}"
  if [[ "$name" == unreadable && $UNREADABLE_OK -eq 0 ]]; then
    echo "  SKIP  lock with an unreadable pid file — this user can read a mode-000 file (root?)"; continue
  fi
  kind=refused; [[ "$name" == late-pid ]] && kind=already-running
  unknown_holder_case "$GATE" "$setup" "$want" "$kind"
  if [[ -z "$UNKNOWN_FAILS" ]]; then
    case "$name" in
      late-pid) echo "  PASS  a pid written a moment late is waited for: the lock is held, not taken over" ;;
      *)        echo "  PASS  a lock whose pid file is $name is refused, left in place, and not called stale" ;;
    esac
  else
    echo "  FAIL  lock with a $name pid file:$UNKNOWN_FAILS"; FAILURES=$((FAILURES+1))
  fi
done

# A pid that cannot be written leaves a lock nobody can name: the gate releases it and refuses,
# rather than run behind a lock that every later gate would have to guess about. A directory made
# under umask 222 is mode 0555, so the pid file cannot be created inside it — the same refusal a full
# disk or a read-only mount produces. (As root, 0555 stops nothing: skipped with the unreadable case.)
pid_unwritable_case() {   # <velo-pr-gate>
  local gate="$1"
  UNKNOWN_FAILS=""
  rm -rf "$LOCK"; mkdir -p "$(dirname "$LOCK")"
  rm -f "$FLAG"
  ( umask 222; HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" bash "$gate" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1 )
  local rc=$?
  pkill -f "$MARKER" 2>/dev/null
  stubs_gone
  [[ $rc -ne 0 ]]                                                   || UNKNOWN_FAILS="$UNKNOWN_FAILS refuses"
  grep -qF -- "could not write this gate's pid" "$TMPD/out.txt"     || UNKNOWN_FAILS="$UNKNOWN_FAILS says-why"
  [[ ! -d "$LOCK" ]]                                                || UNKNOWN_FAILS="$UNKNOWN_FAILS the-nameless-lock-is-released"
  [[ ! -f "$FLAG" ]]                                                || UNKNOWN_FAILS="$UNKNOWN_FAILS nothing-was-started"
  chmod -R u+w "$LOCK" 2>/dev/null
  rm -rf "$LOCK"
}
if [[ $UNREADABLE_OK -eq 1 ]]; then
  pid_unwritable_case "$GATE"
  if [[ -z "$UNKNOWN_FAILS" ]]; then
    echo "  PASS  a pid that cannot be written releases the lock and refuses the gate"
  else
    echo "  FAIL  a pid that cannot be written:$UNKNOWN_FAILS"; FAILURES=$((FAILURES+1))
  fi
else
  echo "  SKIP  a pid that cannot be written — this user writes into a mode-0555 directory (root?)"
fi

# MUTATION-PROOF, on COPIES of velo-pr-gate: with the unknown-holder refusal removed (the old
# behaviour: no holder pid alive = stale) the empty / garbage / absent / late-pid / unreadable cases
# go red; with the grace removed only the late-pid case does.
mutant_gate() {   # <anchor> <replacement> -> $TMPD/mut/velo-pr-gate
  mkdir -p "$TMPD/mut"
  python3 - "$GATE" "$TMPD/mut/velo-pr-gate" "$1" "$2" <<'PY' || return 1
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
  cp "$(dirname "$GATE")/velo-local.conf" "$TMPD/mut/velo-local.conf"
}
prove_lock() {   # <label> <must-be-red names, space separated> <anchor> <replacement>
  local label="$1" want="$2" red="" spec name rest setup wanted kind
  if ! mutant_gate "$3" "$4"; then
    echo "  FAIL  MUTATION-PROOF $label: could not build the mutant (anchor missing — did the lock code change shape?)"
    FAILURES=$((FAILURES+1)); return
  fi
  local specs=("empty:set_lock_empty:has an empty pid file" \
               "garbage:set_lock_garbage:which is not a pid" \
               "absent:set_lock_absent:has no pid file" \
               "late-pid:set_lock_late_pid:a gate is already running for #$TPR (pid $LATE_PID)")
  [[ $UNREADABLE_OK -eq 0 ]] || specs+=("unreadable:set_lock_unreadable:has a pid file that cannot be read")
  for spec in "${specs[@]}"; do
    name="${spec%%:*}"; rest="${spec#*:}"; setup="${rest%%:*}"; wanted="${rest#*:}"
    kind=refused; [[ "$name" == late-pid ]] && kind=already-running
    unknown_holder_case "$TMPD/mut/velo-pr-gate" "$setup" "$wanted" "$kind"
    [[ -z "$UNKNOWN_FAILS" ]] || red="$red $name"
  done
  local n missing=""
  for n in $want; do [[ " $red " == *" $n "* ]] || missing="$missing $n"; done
  if [[ -z "$missing" ]]; then
    echo "  PASS  MUTATION-PROOF $label: red for$red"
  else
    echo "  FAIL  MUTATION-PROOF $label: stayed GREEN for$missing (red for:$red)"; FAILURES=$((FAILURES+1))
  fi
}
UNK_RED="empty garbage absent late-pid"; [[ $UNREADABLE_OK -eq 0 ]] || UNK_RED="$UNK_RED unreadable"
prove_lock "an unknown holder is refused, not taken over" "$UNK_RED" \
  '  if ! read_lock_holder "$GATE_LOCK"; then' '  if false; then'
prove_lock "a pid not yet written is waited for" "late-pid" \
  '  for i in 1 2 3 4 5 6 7 8 9 10; do' '  for i in 1; do'
# The pid-write guard, with its die swallowed: the gate goes on behind a lock it cannot name.
if [[ $UNREADABLE_OK -eq 1 ]]; then
  if ! mutant_gate '|| { rm -rf "$GATE_LOCK"; die "could not write' '|| { true; true "could not write'; then
    echo "  FAIL  MUTATION-PROOF a pid that cannot be written refuses the gate: could not build the mutant (anchor missing — did the lock code change shape?)"
    FAILURES=$((FAILURES+1))
  else
    pid_unwritable_case "$TMPD/mut/velo-pr-gate"
    if [[ "$UNKNOWN_FAILS" == *refuses* && "$UNKNOWN_FAILS" == *says-why* && "$UNKNOWN_FAILS" == *nothing-was-started* ]]; then
      echo "  PASS  MUTATION-PROOF a pid that cannot be written refuses the gate: red for$UNKNOWN_FAILS"
    else
      echo "  FAIL  MUTATION-PROOF a pid that cannot be written refuses the gate: expected red for refuses says-why nothing-was-started, got:$UNKNOWN_FAILS"
      FAILURES=$((FAILURES+1))
    fi
  fi
fi

# ---- the brief says why its range is what it is -----------------------------------------------
#
# The review range is "since the last review" when one can be found and the whole branch otherwise.
# The brief's SCOPE line used to key on the SHAPE of the range, so every whole-branch range was "the
# first review of this PR" — including one whose last review's commit a rebase had removed, and one
# whose gate comments could not be READ at all. That read also threw away gh's status and stderr, so a
# failure was the same empty value as "no review yet" and said nothing. A git that could not diff the
# range read as an EMPTY one ("nothing has landed since the last review") and ended the round with
# exit 0. Each of those is now its own state, with the words to match.
make_codex all-healthy
scope_case() {   # <VELO_TEST_COMMENTS> [VELO_TEST_BASE] -> SCOPE_LINE; the run's output is $TMPD/out.txt
  rm -f "$BRIEF" "$BRIEF".superseded.*
  VELO_TEST_COMMENTS="$1" VELO_TEST_BASE="${2:-master}" invoke
  SCOPE_LINE=$(grep -m1 '^SCOPE: ' "$BRIEF" 2>/dev/null)
}
scope_says() { grep -qF -- "$1" <<<"$SCOPE_LINE"; }
out_says()   { grep -qF -- "$1" "$TMPD/out.txt"; }
case_scope_first() {   # no review recorded yet
  scope_case none; SCOPE_FAILS=""
  scope_says "This is the first review of this PR." || SCOPE_FAILS="$SCOPE_FAILS says-first-review"
  ! out_says "could not read the gate comments"      || SCOPE_FAILS="$SCOPE_FAILS no-read-warning"
}
case_scope_delta() {   # the last review is an ancestor of the head: only the delta
  scope_case ok; SCOPE_FAILS=""
  scope_says "Everything below $GATE_BASE_SHA you have already reviewed and cleared" || SCOPE_FAILS="$SCOPE_FAILS says-the-delta"
  ! scope_says "first review"                                                       || SCOPE_FAILS="$SCOPE_FAILS not-called-first-review"
}
case_scope_orphaned() {   # the last review's commit is gone: whole branch, and not a first review
  scope_case orphan; SCOPE_FAILS=""
  out_says "is NOT an ancestor of"                  || SCOPE_FAILS="$SCOPE_FAILS warns-it-is-orphaned"
  scope_says "which a rebase orphaned"              || SCOPE_FAILS="$SCOPE_FAILS brief-says-orphaned"
  ! scope_says "first review"                       || SCOPE_FAILS="$SCOPE_FAILS not-called-first-review"
}
case_scope_unreadable() {   # the gate comments could not be read: whole branch, said, and not a first review
  scope_case fail; SCOPE_FAILS=""
  out_says "could not read the gate comments of #$TPR" || SCOPE_FAILS="$SCOPE_FAILS says-the-read-failed"
  out_says "gh: HTTP 502"                               || SCOPE_FAILS="$SCOPE_FAILS shows-ghs-own-words"
  scope_says "could not be read"                        || SCOPE_FAILS="$SCOPE_FAILS brief-says-unknown"
  ! scope_says "first review"                           || SCOPE_FAILS="$SCOPE_FAILS not-called-first-review"
}
case_range_undiffable() {   # git has no such base ref: not an empty range
  scope_case none gone; SCOPE_FAILS=""
  [[ $INVOKE_RC -ne 0 ]]       || SCOPE_FAILS="$SCOPE_FAILS refuses"
  out_says "gone"              || SCOPE_FAILS="$SCOPE_FAILS names-the-ref"
  ! out_says "is EMPTY"        || SCOPE_FAILS="$SCOPE_FAILS not-called-empty"
}
for spec in "no review recorded: the brief says it is the first review:case_scope_first" \
            "a review that is an ancestor of the head: the brief says only the delta:case_scope_delta" \
            "a review orphaned by a rebase: the brief says so, not 'first review':case_scope_orphaned" \
            "gate comments that cannot be read: said, and not 'first review':case_scope_unreadable" \
            "a range git cannot diff is not an empty range:case_range_undiffable"; do
  "${spec##*:}"
  if [[ -z "$SCOPE_FAILS" ]]; then echo "  PASS  ${spec%:*}"; else echo "  FAIL  ${spec%:*}:$SCOPE_FAILS"; FAILURES=$((FAILURES+1)); fi
done

# MUTATION-PROOF, on COPIES of velo-pr-gate: each piece taken out in turn, and the case that pins it
# must go red, naming the check.
scope_prove() {   # <label> <case fn> <names that must be red> <anchor> <replacement>
  local label="$1" fn="$2" want="$3" n missing="" real="$GATE"
  if ! mutant_gate "$4" "$5"; then
    echo "  FAIL  MUTATION-PROOF $label: could not build the mutant (anchor missing — did the range code change shape?)"
    FAILURES=$((FAILURES+1)); return
  fi
  GATE="$TMPD/mut/velo-pr-gate"; "$fn"; GATE="$real"
  for n in $want; do [[ " $SCOPE_FAILS " == *" $n "* ]] || missing="$missing $n"; done
  if [[ -z "$missing" ]]; then
    echo "  PASS  MUTATION-PROOF $label: red for$SCOPE_FAILS"
  else
    echo "  FAIL  MUTATION-PROOF $label: stayed GREEN for$missing (red for:$SCOPE_FAILS)"; FAILURES=$((FAILURES+1))
  fi
}
scope_prove "the first-review sentence is the default" case_scope_first "says-first-review" \
  'SCOPE_NOTE="This is the first review of this PR."' 'SCOPE_NOTE=""'
scope_prove "a review that is an ancestor of the head gets the delta sentence" case_scope_delta \
  "says-the-delta not-called-first-review" \
  'SCOPE_NOTE="Everything below $GSHA' ': "Everything below $GSHA'
scope_prove "an orphaned review is said in the brief" case_scope_orphaned \
  "brief-says-orphaned not-called-first-review" \
  'SCOPE_NOTE="The last review was recorded at' ': "The last review was recorded at'
scope_prove "an unreadable gate-comment read is said (the branch removed)" case_scope_unreadable \
  "says-the-read-failed brief-says-unknown not-called-first-review" \
  '  if [[ $GSHA_RC -ne 0 ]]; then' '  if false; then'
scope_prove "an unreadable gate-comment read shows gh's own words (stderr hidden again)" case_scope_unreadable \
  "shows-ghs-own-words" \
  $'| last | .s\')' $'| last | .s\' 2>/dev/null)'
scope_prove "a range git cannot diff is not an empty range (the failure ignored)" case_range_undiffable \
  "refuses not-called-empty" \
  '|| die "git could not diff' '|| : "git could not diff'

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

# ---- ...and it must not take the gate ROOT with it --------------------------------
#
# `find "$VELO_STATE/gate" -maxdepth 1 -type d -mtime +7` lists its START directory as well as
# its children (depth 0 is within -maxdepth 1), and the start directory is a directory too.
# The root's mtime moves only when an entry is created or removed DIRECTLY in it, so after a
# week in which every gate was a re-run of a PR that already had a directory the root is "older
# than 7 days" — and the prune ran `rm -rf` on all of `gate/`: every PR's briefs, logs, verdicts
# and locks, including the gate this very run had just locked. `-mindepth 1` is the whole fix.
#
# The case ages the root LAST (creating the children refreshes it), keeps a young sibling PR's
# directory and this PR's own file, and asserts on the filesystem — the failure mode is "the
# command ran and deleted too much".
GATE_ROOT="$VELO_STATE/gate"
prune_root_case() {   # <velo-pr-gate to run>  ->  PRUNE_FAILS (names of the failed checks)
  local gate="$1" sib="$GATE_ROOT/SIBLING_LIVE" old="$GATE_ROOT/OLDPROBE2" live="$GATE_ROOT/${TPR}"
  PRUNE_FAILS=""
  rm -rf "$sib" "$old"
  mkdir -p "$sib" "$old" "$live"
  : > "$sib/review.log"; : > "$old/x.log"; : > "$live/live.log"
  touch -t 202601010000 "$old"
  touch -t 202601010000 "$GATE_ROOT"            # LAST: the mkdirs above refreshed it
  rm -f "$FLAG"
  HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" bash "$gate" "$TPR" "$SCOPE" >"$TMPD/out.txt" 2>&1
  pkill -f "$MARKER" 2>/dev/null
  stubs_gone
  [[ -d "$GATE_ROOT" ]]       || PRUNE_FAILS="$PRUNE_FAILS the-gate-root-survives"
  [[ -f "$sib/review.log" ]]  || PRUNE_FAILS="$PRUNE_FAILS another-prs-young-gate-survives"
  [[ -f "$live/live.log" ]]   || PRUNE_FAILS="$PRUNE_FAILS this-prs-own-files-survive"
  [[ ! -d "$old" ]]           || PRUNE_FAILS="$PRUNE_FAILS an-aged-pr-dir-is-still-pruned"
  rm -rf "$sib" "$old" "$live/live.log"
  mkdir -p "$GATE_ROOT"
}
make_codex all-healthy
prune_root_case "$GATE"
if [[ -z "$PRUNE_FAILS" ]]; then
  echo "  PASS  an aged gate root is not pruned, and nothing in it is lost: only the aged child goes"
else
  echo "  FAIL  the prune with an aged gate root:$PRUNE_FAILS"
  FAILURES=$((FAILURES+1))
fi

# MUTATION-PROOF, on a COPY (the repo's script is never edited): with `-mindepth 1` removed the
# same case must go red, and name the root. The copy needs velo-local.conf beside it.
mkdir -p "$TMPD/mut"
if python3 - "$GATE" "$TMPD/mut/velo-pr-gate" <<'PY'
import sys
src, dst = sys.argv[1:3]
t = open(src).read()
old = 'find "$VELO_STATE/gate" -maxdepth 1 -mindepth 1 -type d'
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, 'find "$VELO_STATE/gate" -maxdepth 1 -type d', 1))
PY
then
  cp "$(dirname "$GATE")/velo-local.conf" "$TMPD/mut/velo-local.conf"
  prune_root_case "$TMPD/mut/velo-pr-gate"
  if [[ "$PRUNE_FAILS" == *the-gate-root-survives* && "$PRUNE_FAILS" == *another-prs-young-gate-survives* ]]; then
    echo "  PASS  MUTATION-PROOF: without -mindepth 1 the case is red:$PRUNE_FAILS"
  else
    echo "  FAIL  MUTATION-PROOF: without -mindepth 1 the case did not go red for the root wipe (got:$PRUNE_FAILS)"
    FAILURES=$((FAILURES+1))
  fi
else
  echo "  FAIL  MUTATION-PROOF: could not build the mutant (anchor missing — did the prune line change shape?)"
  FAILURES=$((FAILURES+1))
fi

# The stub reviewers must not outlive the test. `pkill -f velo-test-gate-sleep`
# silently matched NOTHING until the marker moved into argv[0] via `exec -a`:
# the string was only ever written to stdout, so every run leaked its stubs for
# 400s (#2027 round 8, P2). Assert the cleanup rather than trusting it.
stubs_gone
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

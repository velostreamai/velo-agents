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
# velo-pr-gate derives its brief and log paths from the PR number and puts them
# in /tmp, which is per MACHINE while worktrees are not. With a fixed number, two
# `run.sh` runs from different worktrees — the normal state of this repo — write
# and delete the same /tmp/gate-999999-* files, and the loser fails on a gate
# assertion that has nothing to do with its change. That is #2040 exactly, which
# was fixed in tests/velo_sql_test.rs (#2041) while this file shipped the same
# defect on the same day — in the suite whose purpose is catching it.
#
# Must stay numeric: velo-pr-gate requires ^[0-9]+$. Kept far above any real PR
# number so a stray file is obviously a test artifact.
TPR=$(( 900000 + ($$ % 90000) ))
# Same reasoning for the stub marker: `pkill -f velo-test-gate-sleep` matched
# EVERY concurrent run's stubs, so two suites killed each other's reviewers and
# one reported `Terminated: 15`. Caught by actually running two at once.
MARKER="velo-test-gate-sleep-$$"
BRIEF="/tmp/gate-${TPR}-review-brief.md"
TMPD=$(mktemp -d)
FLAG="$TMPD/running.flag"
cleanup() {
  pkill -f "$MARKER" 2>/dev/null
  rm -rf "$TMPD"; rm -f "$BRIEF" "$BRIEF".superseded.* "/tmp/gate-${TPR}-code.log" "/tmp/gate-${TPR}-review.log"
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
rm -f "$FLAG" "$TMPD/bin/codex"
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

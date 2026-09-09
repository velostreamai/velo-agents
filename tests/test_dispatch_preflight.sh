#!/bin/bash
# END-TO-END preflight checks, driving the REAL velo-dispatch (#2027 round 6).
#
# test_brief_fields.sh exercises the extractor HELPERS in isolation, and that is
# why it did not notice when a rewrite deleted the WORKTREE comparison entirely:
# every helper still returned the right value, and the script that consumes them
# no longer compared anything. `WORKTREE: /tmp/completely-wrong` printed
# "ok brief BRANCH/WORKTREE match what will be cut".
#
# Unit-testing the parts you are thinking about does not test the behaviour. This
# file runs `velo-dispatch --dry-run` and asserts on what it actually says.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# A spec-less, worker-labelled issue is needed to reach section 4. Without one,
# these are skipped rather than silently passing.
ISSUE="${VELO_TEST_ISSUE:-}"
if [[ -z "$ISSUE" ]]; then
  echo "  SKIP  set VELO_TEST_ISSUE to an OPEN issue with a worker:* label and no"
  echo "        .agents/tasks/<n>.json to run the end-to-end preflight checks"
  exit 0
fi

brief() {  # $1 = worktree line, $2 = branch line
  local f="$TMPD/b.md"
  { [[ -n "$1" ]] && echo "$1"; [[ -n "$2" ]] && echo "$2"
    echo "Do NOT cd into it."; echo "STOP and report if blocked."
    echo "commit after each section"; echo "cargo check --no-default-features"
    echo "You may commit. Do NOT push."; } > "$f"
  echo "$f"
}
run() { bash "$DISPATCH" "$ISSUE" "$1" --dry-run 2>&1; }

# The brief checks live in section 4. Everything before them — issue OPEN,
# labels, worker routing, dependencies, anchors, disk — can refuse first, and
# then every assertion below fails for a reason that has nothing to do with the
# comparison under test. That is what happened the moment #2005 was closed:
# three FAILs reading "output did not contain brief WORKTREE does not match",
# when the real output was "issue #2005 is CLOSED — nothing to dispatch".
#
# Skip loudly instead. A suite that goes red for the wrong reason trains people
# to ignore the red — the same lesson test_gate_health.sh learned separately.
PROBE=$(run "$(brief "WORKTREE: $HOME/RustroverProjects/velostream-$ISSUE" "BRANCH: fix/$ISSUE-auto")")
if ! grep -q "brief BRANCH/WORKTREE" <<<"$PROBE"; then
  echo "  SKIP  #$ISSUE never reaches the brief checks — dispatch refused earlier:"
  grep -E "NOT READY|ERROR" <<<"$PROBE" | head -2 | sed 's/^/        /'
  echo "        Set VELO_TEST_ISSUE to an OPEN issue with a worker:* label and"
  echo "        no .agents/tasks/<n>.json."
  exit 0
fi
expect() {  # $1 label, $2 output, $3 substring
  if grep -qF -- "$3" <<<"$2"; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: output did not contain %q\n' "$1" "$3"; FAILURES=$((FAILURES+1)); fi
}

WTP="$HOME/RustroverProjects/velostream-$ISSUE"
echo "end-to-end preflight (issue #$ISSUE)"
expect "wrong WORKTREE refuses" \
  "$(run "$(brief "WORKTREE: /tmp/completely-wrong" "BRANCH: fix/$ISSUE-auto")")" \
  "brief WORKTREE does not match"
expect "wrong BRANCH refuses" \
  "$(run "$(brief "WORKTREE: $WTP" "BRANCH: fix/$ISSUE-WRONG")")" \
  "brief BRANCH does not match"
expect "both correct passes" \
  "$(run "$(brief "WORKTREE: $WTP" "BRANCH: fix/$ISSUE-auto")")" \
  "brief BRANCH/WORKTREE match"
expect "declared-but-empty WORKTREE refuses" \
  "$(run "$(brief "## Worktree" "## Branch")")" \
  "NOT READY"

# ---- --resume (#1914) -------------------------------------------------------
#
# The refusal for a worktree with work used to say "dispatch with --worktree" — a
# flag the parser rejects with `unknown flag`. The documented way to KEEP work did
# not exist; the only flag that worked was --force, which deletes the branch and
# its commits.
#
# These cases build a REAL worktree with a REAL commit, because that is the state
# where the difference between --resume and --force is whether work survives.
RESUME_WT="$HOME/RustroverProjects/velostream-$ISSUE"
if [[ -e "$RESUME_WT" ]]; then
  echo "  SKIP  $RESUME_WT already exists — not touching a real worktree to test"
else
  ROOT_REPO="$HOME/RustroverProjects/velostream"
  RB="fix/$ISSUE-auto"
  git -C "$ROOT_REPO" worktree add -q "$RESUME_WT" -b "$RB" origin/master 2>/dev/null
  if [[ ! -d "$RESUME_WT" ]]; then
    echo "  SKIP  could not create a scratch worktree at $RESUME_WT"
  else
    echo "probe" >> "$RESUME_WT/.agents/RESUME_TEST"
    git -C "$RESUME_WT" add -A
    git -C "$RESUME_WT" -c user.email=t@t -c user.name=t commit -qm "resume probe" >/dev/null 2>&1
    HEAD_BEFORE=$(git -C "$RESUME_WT" rev-parse HEAD)
    GOODBRIEF=$(brief "WORKTREE: $RESUME_WT" "BRANCH: $RB")

    expect "refusal names --resume, a flag that EXISTS" \
      "$(bash "$DISPATCH" "$ISSUE" "$GOODBRIEF" 2>&1)" "re-run with --resume"
    expect "--resume with --force is refused" \
      "$(bash "$DISPATCH" "$ISSUE" "$GOODBRIEF" --resume --force 2>&1)" "opposites"
    expect "--resume --dry-run says the tree is kept" \
      "$(bash "$DISPATCH" "$ISSUE" "$GOODBRIEF" --resume --dry-run 2>&1)" "RESUMED — kept as-is"
    expect "plain --dry-run warns it would refuse, and how to keep the work" \
      "$(bash "$DISPATCH" "$ISSUE" "$GOODBRIEF" --dry-run 2>&1)" "--resume to keep them"

    HEAD_AFTER=$(git -C "$RESUME_WT" rev-parse HEAD 2>/dev/null)
    if [[ "$HEAD_BEFORE" == "$HEAD_AFTER" ]]; then
      echo "  PASS  the commit survived every one of those"
    else
      echo "  FAIL  HEAD moved: $HEAD_BEFORE -> $HEAD_AFTER"; FAILURES=$((FAILURES+1))
    fi

    git -C "$ROOT_REPO" worktree remove --force "$RESUME_WT" >/dev/null 2>&1
    git -C "$ROOT_REPO" branch -D "$RB" >/dev/null 2>&1
  fi
fi


# ---- usage lists every flag the parser accepts -------------------------------
#
# --resume shipped accepted-but-unlisted: the parser took it, the usage line did
# not mention it. That is the phantom-flag bug in reverse — the tool and its own
# guidance disagreeing about which flags exist — and #1914 was caused by exactly
# that disagreement pointing at a destructive flag.
#
# Derive both sets from the script so this cannot go stale.
USAGE=$(bash "$DISPATCH" 2>&1 | grep -m1 'usage: velo-dispatch')
PARSED=$(sed -n '/^while \[\[ \$# -gt 0 \]\]/,/^done/p' "$DISPATCH" \
         | grep -oE '^\s+--[a-z-]+\)' | tr -d ' )' | sort -u)
MISSING=""
for f in $PARSED; do grep -qF -- "$f" <<<"$USAGE" || MISSING="$MISSING $f"; done
if [[ -z "$MISSING" ]]; then
  echo "  PASS  usage lists every accepted flag ($(wc -w <<<"$PARSED" | tr -d ' ') of them)"
else
  echo "  FAIL  accepted but absent from usage:$MISSING"
  FAILURES=$((FAILURES+1))
fi

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all end-to-end preflight checks passed"

#!/bin/bash
# velo-worktree-lib.sh — worktree facts, derived once, in one place.
#
# Sourced by velo-status (live view) and velo-record (durable history).
#
# These derivations were originally inline in velo-status, which printed them
# and threw them away. velo-record needs the same numbers, and a COPY would be
# worse than useless: if the live view and the recorded history ever disagreed
# about what a worktree contained, neither could be trusted, which is precisely
# the failure the record exists to remove. One definition, two readers.
#
# Every function takes a worktree path and is safe against a missing or broken
# worktree — it prints a zero or an empty string rather than failing, because a
# caller iterating over worktrees must not abort on one bad entry.

wt_branch() {   # <worktree> -> branch name, or "?"
  git -C "$1" branch --show-current 2>/dev/null || echo "?"
}

wt_commits() {  # <worktree> -> commits ahead of origin/master
  git -C "$1" log --oneline origin/master..HEAD 2>/dev/null | wc -l | tr -d ' '
}

wt_dirty() {    # <worktree> -> count of dirty paths
  git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '
}

wt_unpushed() { # <worktree> <branch> -> commits not on the remote branch
  # An unset upstream makes this the same as wt_commits, which is the correct
  # answer: nothing has been pushed, because there is nowhere to have pushed to.
  git -C "$1" log --oneline "origin/$2..HEAD" 2>/dev/null | wc -l | tr -d ' '
}

wt_diffstat() { # <worktree> -> "files insertions deletions" vs origin/master
  git -C "$1" diff --shortstat origin/master...HEAD 2>/dev/null | awk '
    { f=0; i=0; d=0
      for (n=1; n<=NF; n++) {
        if ($n ~ /^file/)      f=$(n-1)
        if ($n ~ /^insertion/) i=$(n-1)
        if ($n ~ /^deletion/)  d=$(n-1)
      }
      print f+0, i+0, d+0; found=1 }
    END { if (!found) print 0, 0, 0 }'
}

# Last real UTC stamp in agent.log — NOT the file mtime. An agent can touch its
# log without progressing, and mtime would call that fresh.
wt_agentlog_last() {  # <worktree> -> ISO stamp, or empty
  grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
    "$1/agent.log" 2>/dev/null | tail -1
}

wt_agentlog_age_min() {  # <worktree> -> minutes since last entry, or empty
  local last; last=$(wt_agentlog_last "$1")
  [[ -n "$last" ]] || return 0
  local secs
  secs=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$last" +%s 2>/dev/null \
         || date -u -d "$last" +%s 2>/dev/null)
  [[ -n "$secs" ]] || return 0
  echo $(( ( $(date -u +%s) - secs ) / 60 ))
}

# A STOP-trigger activation, defined ONCE — velo-status flags on it, velo-record
# scores an outcome from it, and the two must not disagree.
#
# The naive `grep STOP` matches the exact lines that say a STOP did NOT happen.
# `velo-impl.md` tells every worker to end its report with "Any STOP triggers
# hit", so "no STOP triggers hit" is the DOCUMENTED reporting format, not an
# exotic input — and scoring that as `stopped` hides a run that actually landed,
# because `stopped` ranks above `landed` and is deliberately not a failure.
#
# A real activation is logged as its own entry, so STOP must be the first token
# of the message (after the timestamp), not a word somewhere in a sentence.
#
# Anchoring alone is not enough: `STOP-trigger list reviewed, none fired` also
# begins with STOP. So the delimiter set deliberately EXCLUDES `-`, which makes
# the convention explicit — an activation is `STOP <reason>`, `STOP: <reason>`
# or `STOP — <reason>`, while `STOP-trigger`/`STOP-TRIGGER` reads as prose about
# the mechanism. A negation guard catches the rest ("STOP: none").
#
# Erring towards MISSING a stop is deliberate. A missed stop reads as `landed`
# and the commits are right there in the record to contradict it; a false stop
# ranks above `landed`, is defined as not-a-failure, and erases the run from
# both columns with nothing to contradict it.
wt_stop_fired() {  # <worktree> -> 0 if agent.log records a STOP-trigger activation
  grep -E '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?[[:space:]]+)?STOP([[:space:]]|:|—|$)' \
       "$1/agent.log" 2>/dev/null \
    | grep -qvE '(none|not fired|no STOP|nothing|clear|n/a)'
}

# The stall predicate, defined ONCE. velo-status colours on it; velo-watch will
# act on it (issue #1992 Phase 2). Two implementations of "stalled" would drift,
# and the one that acts must mean the same thing as the one a human reads.
WT_STALL_MINUTES=10

wt_is_stalled() {  # <worktree> -> 0 if agent.log has not moved for WT_STALL_MINUTES
  local age; age=$(wt_agentlog_age_min "$1")
  [[ -n "$age" && "$age" -ge "$WT_STALL_MINUTES" ]]
}

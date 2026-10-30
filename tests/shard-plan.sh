#!/bin/bash
# shard-plan.sh <I/N> [<run.sh> [<weights>]] - the suites of slice I of N, one name per line, in run.sh order.
# shard-plan.sh --all [<run.sh> [<weights>]] - every suite the plan knows, the same way (for run.sh to tell "another slice's"
#                                              from "a call the plan cannot see").
#
# `run.sh --shard I/N` runs only these, so a CI matrix can spread the suites over N runners (N jobs that each start from a
# clean checkout and share nothing) instead of running 73 suites one after another on one. The suites are not touched and
# each one still runs whole, in its own process group, with its own leak check; only WHICH suites a run starts changes.
#
# The slices are made by longest-processing-time-first: the suites go in order of weight, heaviest first (run.sh order breaks
# a tie), each to the slice that is lightest so far (the lowest slice breaks a tie). Whatever the weights are, no slice ends
# up more than one suite's weight heavier than the lightest, and the answer is the same on every machine.
#
# A plan that could silently drop or repeat a suite is refused, not guessed at: every suite run.sh starts needs a weight in
# tests/suite-weights.txt, every weight needs a suite, a name may appear only once, and a slice with nothing in it is an
# error (a runner that ran no tests would report success). The weights are seconds on the slowest CI runner; they only
# balance the slices and never decide whether a suite runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:-}"
RUNSH="${2:-$HERE/run.sh}"
WEIGHTS="${3:-$HERE/suite-weights.txt}"

SPEC_RE='^([1-9][0-9]*)/([1-9][0-9]*)$'
if [[ $SPEC == --all ]]; then
  WANT=0
  SHARDS=1
elif ! [[ $SPEC =~ $SPEC_RE ]]; then
  echo "shard-plan: '$SPEC' is not I/N (two positive integers, e.g. 2/4)" >&2
  exit 2
else
  WANT=${BASH_REMATCH[1]}
  SHARDS=${BASH_REMATCH[2]}
  if [[ $WANT -gt $SHARDS ]]; then
    echo "shard-plan: slice $WANT of $SHARDS does not exist (I runs from 1 to N)" >&2
    exit 2
  fi
fi
for f in "$RUNSH" "$WEIGHTS"; do
  [[ -r $f ]] || { echo "shard-plan: cannot read $f" >&2; exit 2; }
done

awk -v want="$WANT" -v shards="$SHARDS" -v wf="$WEIGHTS" '
  function err(m) { print "shard-plan: " m > "/dev/stderr"; bad = 1 }
  FILENAME == wf {
    if ($0 ~ /^[ \t]*(#|$)/) next
    if (NF != 2 || $1 !~ /^[0-9]+$/ || $1 + 0 < 1) { err("weights line " FNR " is not \"<seconds> <suite>\": " $0); next }
    if ($2 in w) { err("weights: " $2 " is listed twice"); next }
    w[$2] = $1 + 0
    next
  }
  /^suite[ \t]/ {
    if ($2 in seen) { err("run.sh calls suite " $2 " twice"); next }
    seen[$2] = 1; n++; names[n] = $2
  }
  END {
    for (i = 1; i <= n; i++) if (!(names[i] in w)) err("suite " names[i] " has no weight (add \"<seconds> " names[i] "\" to the weights file)")
    for (s in w) if (!(s in seen)) err("the weights file lists " s ", which run.sh does not run")
    if (n == 0) err("run.sh calls no suite")
    if (n > 0 && shards > n) err(shards " slices for " n " suites: some slice would run nothing")
    if (bad) exit 1
    for (i = 1; i <= n; i++) idx[i] = i
    for (i = 2; i <= n; i++) {                         # insertion sort, heaviest first; equal weights keep run.sh order
      v = idx[i]; j = i - 1
      while (j >= 1 && w[names[idx[j]]] < w[names[v]]) { idx[j + 1] = idx[j]; j-- }
      idx[j + 1] = v
    }
    for (s = 1; s <= shards; s++) load[s] = 0
    for (k = 1; k <= n; k++) {
      i = idx[k]; best = 1
      for (s = 2; s <= shards; s++) if (load[s] < load[best]) best = s
      slot[i] = best; load[best] += w[names[i]]
    }
    for (i = 1; i <= n; i++) if (want == 0 || slot[i] == want) { print names[i]; got++ }
    if (got == 0) { err("slice " want " of " shards " has no suite"); exit 1 }
  }' "$WEIGHTS" "$RUNSH"

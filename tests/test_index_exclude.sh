#!/bin/bash
# The discovery index must never be committable — on ANY branch (#2032).
#
# #2033 adds `.zvec-grep/` to the tracked .gitignore, which protects only the
# branches that CONTAIN that line. Every worktree cut before it merges is on a
# branch without it, and there the 325MB index is merely untracked:
#
#   ?? .zvec-grep/
#   $ git add -A --dry-run   ->   add '.zvec-grep/db/index.bin'
#
# `velo_runner_lib.salvage_on_failure()` runs exactly `git add -A` and commits.
# So the path added to PRESERVE a dying run's work would commit the index into
# the branch. The fix writes the pattern to the git common dir's info/exclude,
# which is branch-independent and covers worktrees already on disk.
#
# This test EXTRACTS THE REAL BLOCK from velo-dispatch and executes it against a
# throwaway repo. It deliberately does not re-implement the logic: a copy would
# keep passing after the real block was deleted, which is precisely how round 6
# of #2027 shipped a script that had lost the check it was written to add.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

echo "discovery-index git exclusion"

# Extracted between explicit markers, not by line range: the block's SHAPE
# changed when fail-closed verification was added, and a positional range would
# have silently captured only the first half — the write, without the check that
# the write worked, which is precisely the P1 this test now covers.
BLOCK=$(sed -n '/^# >>> velo-index-exclude/,/^# <<< velo-index-exclude/p' "$DISPATCH")
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL  could not extract the exclude block from velo-dispatch —"
  echo "        it has been deleted, renamed, or restructured. The index is"
  echo "        committable again on any branch lacking the .gitignore line."
  exit 1
fi
echo "  PASS  exclude block still present in velo-dispatch ($(wc -l <<<"$BLOCK" | tr -d ' ') lines)"

# A repo whose .gitignore does NOT mention the index — i.e. any pre-merge branch.
git init -q "$TMPD/repo"
git -C "$TMPD/repo" config user.email t@t; git -C "$TMPD/repo" config user.name t
printf 'target/\n' > "$TMPD/repo/.gitignore"
git -C "$TMPD/repo" add -A && git -C "$TMPD/repo" commit -qm init
git -C "$TMPD/repo" worktree add -q "$TMPD/wt" -b feature 2>/dev/null

mkdir -p "$TMPD/repo/.zvec-grep/db"; echo x > "$TMPD/repo/.zvec-grep/db/index.bin"
mkdir -p "$TMPD/wt/.zvec-grep/db";   echo x > "$TMPD/wt/.zvec-grep/db/index.bin"

# Baseline: BOTH must be committable before the block runs, or the test proves
# nothing about what the block did.
BASE_OK=1
for WTDIR in "$TMPD/repo" "$TMPD/wt"; do
  git -C "$WTDIR" status --porcelain | grep -q '\.zvec-grep' || BASE_OK=0
done
if [[ "$BASE_OK" != "1" ]]; then
  echo "  FAIL  baseline wrong — index already ignored somewhere; test proves nothing"
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  baseline: index is committable in BOTH trees before the fix"
fi

# Run the block ONCE, against the linked worktree only. The claim under test is
# that info/exclude lives in the git COMMON dir, so a single dispatch protects
# every worktree on disk — including ones cut long before, which is the whole
# point (1928, 1958, 1965 … are all on pre-merge branches).
WT="$TMPD/wt"
ok()   { :; }
warn() { echo "  warn(from block): $*"; }
eval "$BLOCK"

for WTDIR in "$TMPD/wt" "$TMPD/repo"; do
  LABEL=$([[ "$WTDIR" == "$TMPD/wt" ]] && echo "the worktree it ran in" || echo "a DIFFERENT worktree")
  if git -C "$WTDIR" status --porcelain | grep -q '\.zvec-grep'; then
    echo "  FAIL  [$LABEL] index still visible to git status"
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS  [$LABEL] index hidden from git status"
  fi
  if git -C "$WTDIR" add -A --dry-run 2>/dev/null | grep -q '\.zvec-grep'; then
    echo "  FAIL  [$LABEL] 'git add -A' (the salvage path) still stages the index"
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS  [$LABEL] 'git add -A' does not stage the index"
  fi
done

# Idempotence: dispatch runs on every job; the file must not grow without bound.
WT="$TMPD/repo"; ok() { :; }; warn() { :; }
eval "$BLOCK"; eval "$BLOCK"
N=$(grep -cxF '.zvec-grep/' "$TMPD/repo/.git/info/exclude" 2>/dev/null || echo 0)
if [[ "$N" == "1" ]]; then echo "  PASS  idempotent across repeated dispatches (1 entry)"
else echo "  FAIL  entry written $N times — not idempotent"; FAILURES=$((FAILURES+1)); fi

# ---- fail-closed (#2033 P1) -------------------------------------------------
#
# The first cut printed success whenever the redirect did not crash the script.
# With info/exclude symlinked to /dev/null, or read-only, the append silently
# fails, `git status` still shows `?? .zvec-grep/`, and the dispatcher announced
# the index was safe before building 325MB that salvage could commit. Writing the
# guard is not the guard holding.
#
# Each case gets a FRESH repo: a leftover exclude entry from an earlier case
# would make check-ignore pass and the assertion vacuous.
fail_closed_case() {   # $1 = label, $2 = setup fn
  local label="$1" setup="$2" dir="$TMPD/fc-$3"
  git init -q "$dir"
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  printf 'target/\n' > "$dir/.gitignore"
  git -C "$dir" add -A && git -C "$dir" commit -qm init
  mkdir -p "$dir/.git/info"
  "$setup" "$dir"

  WT="$dir"; INDEX_SAFE=1
  ok() { :; }; warn() { :; }
  eval "$BLOCK"

  if [[ "${INDEX_SAFE:-1}" == "0" ]]; then
    echo "  PASS  [$label] refuses to build — INDEX_SAFE=0"
  else
    echo "  FAIL  [$label] claimed the index was safe; git says otherwise"
    FAILURES=$((FAILURES+1))
  fi
  if git -C "$dir" check-ignore -q .zvec-grep 2>/dev/null; then
    echo "  FAIL  [$label] baseline wrong — exclusion unexpectedly worked"
    FAILURES=$((FAILURES+1))
  fi
}

setup_symlink()  { ln -sf /dev/null "$1/.git/info/exclude"; }
setup_readonly() { : > "$1/.git/info/exclude"; chmod 444 "$1/.git/info/exclude"; }

fail_closed_case "info/exclude -> /dev/null" setup_symlink  sym
fail_closed_case "info/exclude read-only"    setup_readonly ro
chmod 644 "$TMPD"/fc-ro/.git/info/exclude 2>/dev/null || true

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all discovery-index exclusion checks passed"

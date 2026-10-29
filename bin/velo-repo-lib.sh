#!/bin/bash
# velo-repo-lib.sh — WHICH GitHub repo the tools work on. Sourced, never run.
#
# One source of truth. VELO_REPO (owner/name) names the repo; VELO_GATE_REPO is the older name for the same thing and
# VELO_REPO overrides it; with neither set the repo is VELO_DEFAULT_REPO, below — the only place in bin/ and hooks/
# that spells a repo out (tests/test_repo_env.sh counts). Source it, then call repo_init: it resolves the repo and fails,
# with the reason on stderr, when the value is not <owner>/<name>. It exports nothing: a child resolves the repo from
# the same two variables its parent did.
#
# repo_init sets:
#   REPO              the repo, for every `gh --repo`
#   REPO_IS_DEFAULT   1 for Velostream, the default
#   REPO_NAME         the name without the owner. The canonical checkout is ~/RustroverProjects/$REPO_NAME and a
#                     worker's worktree is ~/RustroverProjects/$REPO_NAME-<issue> (`velostream`, today's spelling,
#                     for the default)
#   REPO_SUB          "" for the default, "/<owner>__<name>" otherwise. Appended to a state dir (gate/, records/,
#                     dispatch/, orch/) so numbers from two repos never share a directory or a file
#   GATE_SUBDIR       the gate state dir under $VELO_STATE: gate$REPO_SUB
#   GATE_PATH_RE      how a reviewer's command line names a gate dir (velo-watch, the SessionStart hook)
#   GATE_CMD_ENV      "VELO_REPO=<repo> " in front of a printed follow-up command for another repo, so pasting it
#                     into a shell without the variable cannot act on the same number in Velostream
#   GATE_ORCH_RE      the changed files that are orchestration — the tooling itself, which governs every other run:
#                     .agents/ in Velostream, the repo root in the repo that holds the tooling (velo-agents)
#   GATE_ORCH_WHERE   the same, in words
#   REPO_NOTE         "" for the default; for any other repo the paragraph a review brief or a worker's task opens with:
#                     the Velostream-only prerequisites do not apply here, said in the words velo-impl.md honours
#                     (OVERRIDE-DIRECTIVES:). A variable, not a function: it is spliced into a heredoc, and a
#                     command substitution would eat the newlines that end it
#
# repo_base_branch sets BASE_BRANCH and WT_BASE_REF; repo_checkout, repo_worktree and repo_scoped are described at
# their definitions. Callers that count a worktree's commits read ${WT_BASE_REF:-origin/master}, so a script run on
# its own, with nothing set, is the Velostream one.

VELO_DEFAULT_REPO="velostreamai/velostream"

repo_init() {
  local re='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' lc
  REPO="${VELO_REPO:-${VELO_GATE_REPO:-$VELO_DEFAULT_REPO}}"
  if [[ ! "$REPO" =~ $re ]]; then
    printf 'ERROR: VELO_REPO must be <owner>/<name>, got %q\n' "$REPO" >&2
    return 1
  fi
  lc=$(tr '[:upper:]' '[:lower:]' <<<"$REPO")   # GitHub names are case-blind: one repo, one state dir
  if [[ "$lc" == "$VELO_DEFAULT_REPO" ]]; then
    REPO="$VELO_DEFAULT_REPO"; REPO_IS_DEFAULT=1; REPO_SUB=""; GATE_CMD_ENV=""; REPO_NOTE=""
    GATE_ORCH_RE='^\.agents/(bin|rules|skills|tasks)/|^\.agents/(install|update)\.sh$'
    GATE_ORCH_WHERE="under .agents/"
  else
    REPO_IS_DEFAULT=0; REPO_SUB="/${lc/\//__}"; GATE_CMD_ENV="VELO_REPO=$REPO "
    GATE_ORCH_RE='^(bin|rules|skills|tasks|hooks|launchd)/|^(install|update)\.sh$'
    GATE_ORCH_WHERE="in the tooling tree"
    printf -v REPO_NOTE '%s\n\n' "REPO: $REPO is NOT Velostream. The Velostream-only prerequisites are SKIPPED here and their absence is no finding.
OVERRIDE-DIRECTIVES: the 'Read first' CLAUDE.md requirement and its STOP trigger (this repo has none to read), the ./run-commit.sh --fast gate, the STREAMING-COMPLIANCE-CHECK log lines, and cargo/nextest. Judge the diff by this repo's own conventions and its own tests."
  fi
  REPO_NAME="${REPO#*/}"
  GATE_SUBDIR="gate$REPO_SUB"
  GATE_PATH_RE="state/$GATE_SUBDIR/[0-9]+/"
}

# repo_checkout <dir> — 0 when <dir> is a git checkout of REPO: it has a .git and its origin names REPO. REPO_ERR says
# what is there when it is not, so a refusal can name the path it tried.
repo_checkout() {
  local have
  [[ -e "$1/.git" ]] || { REPO_ERR="$1 is not a git checkout"; return 1; }
  have=$(git -C "$1" remote get-url origin 2>/dev/null \
    | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##' | tr '[:upper:]' '[:lower:]')
  [[ "$have" == "$(tr '[:upper:]' '[:lower:]' <<<"$REPO")" ]] \
    || { REPO_ERR="$1 is a checkout of ${have:-nothing (it has no origin)}, not $REPO"; return 1; }
}

# repo_worktree <branch> — the worktree of REPO checked out on <branch>, in REPO_WT. For every repo but the default,
# whose lookup (the caller's own `git worktree list`) is unchanged. Only ~/RustroverProjects/$REPO_NAME and
# $REPO_NAME-* are looked at, and one counts only when repo_checkout accepts it, so another repo's tree can never
# answer. Returns 1 with REPO_ERR naming every path it tried.
repo_worktree() {
  local d cur tried="" base="$HOME/RustroverProjects"
  for d in "$base/$REPO_NAME" "$base/$REPO_NAME"-*; do
    [[ -e "$d" ]] || continue
    if repo_checkout "$d"; then
      cur=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null)
      if [[ "$cur" == "$1" ]]; then REPO_WT="$d"; return 0; fi
      tried="$tried
    $d (on ${cur:-no branch})"
    else
      tried="$tried
    $REPO_ERR"
    fi
  done
  REPO_ERR="no local worktree of $REPO is checked out on '$1' — a gate must read the tree it reviews, and will not read another repo's.
  Looked in $base/$REPO_NAME and $base/$REPO_NAME-*:${tried:- nothing there}"
  return 1
}

# repo_base_branch — BASE_BRANCH, the branch a worker's tree is cut from, and WT_BASE_REF (origin/<it>), the ref a
# worktree's commits are counted against (velo-worktree-lib.sh): `master` for the default repo (read from nowhere: its
# callers have always spelled it out), the repo's own default branch as GitHub names it otherwise. Returns 1, with
# REPO_ERR, when GitHub does not say.
repo_base_branch() {
  if [[ $REPO_IS_DEFAULT -eq 1 ]]; then BASE_BRANCH=master; WT_BASE_REF=origin/master; return 0; fi
  BASE_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)
  if [[ -z "$BASE_BRANCH" || "$BASE_BRANCH" == null ]]; then
    REPO_ERR="GitHub does not name a default branch for $REPO (gh repo view $REPO failed, or the repo has no commits)"
    return 1
  fi
  WT_BASE_REF="origin/$BASE_BRANCH"
}

# repo_scoped <path> — <path> with REPO_SUB put before its last component: records/7.result.jsonl becomes
# records/<owner>__<name>/7.result.jsonl. <path> itself for the default repo.
repo_scoped() { printf '%s' "${1%/*}$REPO_SUB/${1##*/}"; }

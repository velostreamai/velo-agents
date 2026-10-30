#!/bin/bash
# repo-env-lib.sh - the harness test_repo_env.sh and test_repo_env_workers.sh share. Sourced by them; not a suite.
#
# VELO_REPO (alias VELO_GATE_REPO) names the GitHub repo every tool works on; unset it is the Velostream default. A check
# of that is only worth anything when it runs the real scripts, so this builds a world for them and DRIVES them:
#
#   stubs      gh (answers from fixture files, logs one line per call), git (logs where it ran), df, launchctl
#   sandbox    a fake HOME with a private state dir and, for each repo, a clone in ~/RustroverProjects/<name> on branch
#              feat/gate plus a worker worktree <name>-77 (velostream: master, branch fix/77-def; velo-agents: main,
#              branch fix/77-alt), each one commit ahead of its origin
#   drive      def | alt: one run of 20 scenarios (every tool that names a repo) in one sandbox, with the repo env set
#              (alt) or not (def). Cached per code under test, so a check reads what the tools did instead of running
#              them again, and a mutated copy (R) gets its own drive
#
# Everything a check reads comes from files the scenarios left in the sandbox: $SB/trace (the gh calls per scenario),
# $SB/{gh,git,out,rc}.<scenario>, and the state dir $S. A scenario that does not exist in the code under test is a
# failed check, never a skip.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # the code under test; a mutation proof points it at a mutated copy
. "$HERE/test-timeouts.sh"
# The code under test finds velo-repo-lib.sh beside itself: a mutant must run ITS lib, not the real one test-timeouts.sh names.
unset VELO_REPO_LIB VELO_REPO VELO_GATE_REPO WT_BASE_REF VELO_RECORD_ROOT VELO_ORCH_WORKTREE_GLOB ORCH_DIR GATE_ROOT \
  RECORDS_DIR RECORD_DIR VELO_GATE_BIN VELO_GATE_POST_BIN VELO_MERGE_BIN VELO_DISPATCH_BIN VELO_SKIP_INDEX
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(/usr/bin/mktemp -d "$TMP_ROOT/repo-env.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }
T=$(cd "$T" && pwd -P)
DECOY_PIDS=""
kill_decoys() { local p; for p in $DECOY_PIDS; do kill "$p" 2>/dev/null; done; DECOY_PIDS=""; }
trap 'kill_decoys; chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
MUT_PATHS="bin hooks rules"
. "$HERE/mutation-lib.sh"

DEF=velostreamai/velostream; ALT=velostreamai/velo-agents; ALT_SUB=velostreamai__velo-agents
CLASH=acme/velostream; CLASH_SUB=acme__velostream   # the same repo NAME as DEF, another owner: ~/RustroverProjects/velostream is DEF's
PR=12; WIP=77; ISS=78; ISS_REAL=79; CLASH_WIP=99
HEADSHA=1111111111111111111111111111111111111111; H9=111111111
GITID='-c user.email=t@t -c user.name=t -c commit.gpgsign=false'
GOLDEN="$HERE/fixtures/repo-env/default.golden"

# ---- stubs --------------------------------------------------------------------------------------------------------
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
# Stub gh: one log line per call (its argv), answers from the fixture files in $FX, refuses a call it was not taught.
a="$*"; printf '%s\n' "${a//$'\n'/\\n}" >> "$GH_LOG"   # one line per call: a newline inside an argument is written \n
EXPR=""; prev=""
for a in "$@"; do
  if [[ "$prev" == --jq || "$prev" == -q ]]; then EXPR="$a"; fi
  prev="$a"
done
answer() {   # <fixture>: the fixture, through the call's own --jq when it has one
  [[ -f "$FX/$1" ]] || { echo "stub gh: no fixture $1 for: $*" >&2; exit 1; }
  if [[ -n "$EXPR" ]]; then jq -r "$EXPR" "$FX/$1"; else cat "$FX/$1"; fi
}
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json headRefOid,labels,files,state,title,body"*) answer pr-meta.json ;;
      *statusCheckRollup*) answer pr-merge.json ;;
      *comments*)
        J=$(jq -nc --slurpfile c "$FX/comments.json" --arg h "$(jq -r .headRefOid "$FX/pr-view.json")" '{headRefOid:$h, comments:$c[0]}')
        if [[ -n "$EXPR" ]]; then jq -r "$EXPR" <<<"$J"; else printf '%s\n' "$J"; fi ;;
      *) answer pr-view.json ;;
    esac; exit $? ;;
  "pr checks") [[ -f "$FX/pr-checks.txt" ]] && cat "$FX/pr-checks.txt"; exit "$(cat "$FX/pr-checks.rc" 2>/dev/null || echo 0)" ;;
  "pr list")
    case "$*" in
      *"--label gate:running"*) answer pr-list-running.json ;;
      *"--label gate:passed"*) echo '[]' ;;
      *) answer pr-list.json ;;
    esac; exit $? ;;
  "pr edit"|"issue edit") exit 0 ;;
  "pr comment") echo "https://github.com/stub/repo/pull/1#issuecomment-1"; exit 0 ;;
  "issue view")
    if [[ -f "$FX/issue-$3.json" ]]; then answer "issue-$3.json"; exit $?; fi
    echo "GraphQL: Could not resolve to an issue or pull request with the number of $3. (repository.issue)" >&2; exit 1 ;;
  "issue list") answer issue-list.json; exit $? ;;
  "repo view") answer repo-view.json; exit $? ;;
  "auth status") exit 0 ;;
esac
echo "stub gh: unexpected call: $*" >&2; exit 1
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
printf '%s: %s\n' "$PWD" "$*" >> "$GIT_LOG"
exec /usr/bin/git "$@"
STUB
cat > "$T/stub/df" <<'STUB'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1048576000 104857600 943718400 10%% /\n'
STUB
cat > "$T/stub/launchctl" <<'STUB'
#!/bin/bash
# The user's launchd domain is not a test fixture: every call is logged and nothing is done.
printf '%s\n' "$*" >> "${LAUNCH_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$T/stub/gh" "$T/stub/git" "$T/stub/df" "$T/stub/launchctl"

# ---- a sandbox: HOME, state, trees of both repos, fixtures ----------------------------------------------------------
sb_use() {   # <dir>: the variables of an existing sandbox; nothing set for the repo (XE), the cwd is the sandbox (CWD)
  SB="$1"; H="$SB/home"; S="$H/.agents/state"; FX="$SB/fx"; GL="$SB/gh.log"; GITL="$SB/git.log"; XE=""; CWD="$SB"
  ENVV=(HOME="$H" VELO_STATE="$S" TMPDIR="$SB/tmp" PATH="$T/stub:$PATH" GH_LOG="$GL" GIT_LOG="$GITL" FX="$FX"
        LAUNCH_LOG="$SB/launchctl.log" WORKER_DIR="$SB/worker" ZG_LOG="$SB/zg.log" VELO_CHECK_CODE_SKILL="$FX/skill.md")
}
sb_new() {
  local d f
  d=$(/usr/bin/mktemp -d "$T/sb.XXXXXX") && d=$(cd "$d" && pwd -P) || return 1
  sb_use "$d"
  mkdir -p "$H/.agents/bin" "$H/RustroverProjects" "$S" "$FX" "$SB/tmp" "$SB/worker" "$SB/remote/velostreamai"
  for f in "$R"/bin/*; do ln -s "$f" "$H/.agents/bin/${f##*/}"; done
  ln -s "$R/rules" "$H/.agents/rules"
  : > "$GL"; : > "$GITL"
  printf '# fixture skill\n' > "$FX/skill.md"
  # What a dispatch launches: a worker that keeps its task and cwd and does nothing, an indexer that logs that it ran.
  cat > "$H/.agents/bin/velo-openrouter-agent.stub" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    --task) printf '%s' "$2" > "$WORKER_DIR/task"; shift 2 ;;
    --cwd)  printf '%s' "$2" > "$WORKER_DIR/cwd"; shift 2 ;;
    *) shift ;;
  esac
done
echo "stub worker ran"
STUB
  cat > "$H/.agents/bin/zg.stub" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ZG_LOG"
exit 0
STUB
  chmod +x "$H/.agents/bin/velo-openrouter-agent.stub" "$H/.agents/bin/zg.stub"
}
stub_worker() {   # replace the symlinked worker and indexer by the stubs (dispatch launches ~/.agents/bin/<name>)
  rm -f "$H/.agents/bin/velo-openrouter-agent" "$H/.agents/bin/zg"
  mv "$H/.agents/bin/velo-openrouter-agent.stub" "$H/.agents/bin/velo-openrouter-agent"
  mv "$H/.agents/bin/zg.stub" "$H/.agents/bin/zg"
}
mk_tree() {   # <name> <default branch>: a remote of that name, cloned to ~/RustroverProjects/<name>, on feat/gate one commit ahead
  local rem="$SB/remote/velostreamai/$1" tree="$H/RustroverProjects/$1"
  git init -q -b "$2" "$rem" && echo "seed $1" > "$rem/seed.txt" && git -C "$rem" add seed.txt && git -C "$rem" $GITID commit -q -m "seed $1" \
    && git clone -q "$rem" "$tree" && git -C "$tree" checkout -q -b feat/gate \
    && echo change > "$tree/change.txt" && git -C "$tree" add change.txt && git -C "$tree" $GITID commit -q -m change
}
mk_worker() {   # <name> <default branch> <branch>: the worktree ~/RustroverProjects/<name>-77, one commit ahead of origin/<default branch>
  local tree="$H/RustroverProjects/$1" wt="$H/RustroverProjects/$1-$WIP"
  git -C "$tree" worktree add -q -b "$3" "$wt" "origin/$2" \
    && echo w > "$wt/w.txt" && git -C "$wt" add w.txt && git -C "$wt" $GITID commit -q -m worker
}
mk_world() {   # both repos' trees, each with a worker worktree
  mk_tree velostream master && mk_tree velo-agents main \
    && mk_worker velostream master fix/$WIP-def && mk_worker velo-agents main fix/$WIP-alt
}
mk_clash() {   # $CLASH has Velostream's directory name. ~/RustroverProjects/velostream is Velostream's tree, with its worker
               # velostream-77; $CLASH's own clone is in ~/other, its worker is the worktree velostream-99 (both on main)
  local rem="$SB/remote/acme/velostream" own="$H/other/velostream" wt="$H/RustroverProjects/velostream-$CLASH_WIP"
  mk_tree velostream main && mk_worker velostream main fix/$WIP-def \
    && git init -q -b main "$rem" && echo "seed acme" > "$rem/seed.txt" && git -C "$rem" add seed.txt && git -C "$rem" $GITID commit -q -m "seed acme" \
    && git clone -q "$rem" "$own" && git -C "$own" worktree add -q -b fix/$CLASH_WIP-acme "$wt" origin/main \
    && echo w > "$wt/w.txt" && git -C "$wt" add w.txt && git -C "$wt" $GITID commit -q -m worker
}
x() {   # <cmd...>: one command in the sandbox under $XE, from $CWD -> OUT RC
  OUT=$(cd "$CWD" && env "${ENVV[@]}" $XE "$@" 2>&1); RC=$?
}
xbg() {   # <out file> <cmd...>: x in the background, its output in the file -> BGPID (killed with the stand-in processes)
  local f="$1"; shift
  ( cd "$CWD" && exec env "${ENVV[@]}" $XE "$@" > "$f" 2>&1 ) &
  BGPID=$!; DECOY_PIDS="$DECOY_PIDS $BGPID"
}
decoy() {   # <command line>: a sleeping process whose command line reads that, as `ps` shows a reviewer's -> DPID.
  # A check that starts one sets `trap kill_decoys EXIT` first: a trap of the parent shell does not run in its subshells.
  local i=0
  bash -c 'exec -a "$1" sleep 60' decoy "$1" &
  DPID=$!; DECOY_PIDS="$DECOY_PIDS $DPID"
  until ps -o command= -p "$DPID" 2>/dev/null | grep -qF -- "$1"; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { echo "FAILED: the stand-in process never showed in ps" >&2; return 1; }
    sleep 0.05
  done
}
sc() {   # <label> <cmd...>: x, then the label, rc and gh argv go to the trace and the rest to per-scenario files
  local label="$1"; shift
  : > "$GL"; : > "$GITL"
  x "$@"
  { printf '== %s rc=%s\n' "$label" "$RC"; sed 's/^/gh: /' "$GL"; } >> "$SB/trace"
  cp "$GL" "$SB/gh.$label"; cp "$GITL" "$SB/git.$label"; printf '%s\n' "$OUT" > "$SB/out.$label"; printf '%s\n' "$RC" > "$SB/rc.$label"
}

# ---- fixtures -----------------------------------------------------------------------------------------------------
fx_pr() {   # <title> <body> <head branch> <base branch> <file>...: the PR the stub gh describes, as every kind of read sees it
  local title="$1" body="$2" head="$3" base="$4" files; shift 4
  files=$(printf '%s\n' "$@" | jq -R '{path:.}' | jq -sc .)
  jq -nc --arg h "$HEADSHA" --arg t "$title" --arg b "$body" --argjson f "$files" \
    '{headRefOid:$h, labels:[], files:$f, state:"OPEN", title:$t, body:$b}' > "$FX/pr-meta.json"
  jq -nc --arg h "$HEADSHA" --arg t "$title" --arg hb "$head" --arg bb "$base" \
    '{headRefOid:$h, headRefName:$hb, baseRefName:$bb, title:$t, state:"OPEN", mergeable:"MERGEABLE"}' > "$FX/pr-view.json"
  jq -nc --arg h "$HEADSHA" --arg t "$title" --argjson f "$files" \
    '{headRefOid:$h, labels:[], files:$f, state:"OPEN", title:$t, mergeable:"MERGEABLE",
      statusCheckRollup:[{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"}]}' > "$FX/pr-merge.json"
}
fx_comments() {   # <comment body>...: the PR's comments, all by the repo owner
  local json='[]' b
  for b in "$@"; do json=$(jq -c --arg b "$b" '. + [{body:$b, authorAssociation:"OWNER"}]' <<<"$json"); done
  printf '%s\n' "$json" > "$FX/comments.json"
}
fx_issue() {   # <n> <body>: issue n, open, one worker label
  jq -nc --arg b "$2" '{state:"OPEN", title:"fixture", body:$b, labels:[{name:"worker:local"}], assignees:[], updatedAt:"2026-10-11T06:00:00Z"}' > "$FX/issue-$1.json"
}
fx_base() {   # <branch>: what GitHub says the repo's default branch is
  jq -nc --arg b "$1" '{defaultBranchRef:{name:$b}}' > "$FX/repo-view.json"
}
gate_comment() { printf 'gate: %s @ %s\n\n## report\n**Verdict:** approve\n' "$1" "$H9"; }

# ---- assertions: they collect (bad), the check ends with `[ "$BAD" -eq 0 ]` -------------------------------------------
has()    { grep -qF -- "$2" <<<"$1"; }                 # has <text> <needle>
want()   { has "$1" "$2" || bad "$3"; }                # want <text> <needle> <what is wrong when it is missing>
unwant() { if has "$1" "$2"; then bad "$3"; fi; }      # unwant <text> <needle> <what is wrong when it is there>
eq()     { [ "$1" = "$2" ] || bad "$3: got '$1', want '$2'"; }
nonl()   { tr '\n' ' ' <<<"$1" | cut -c1-"${2:-300}"; }
gh_names() {   # <gh log file> <repo>: bad for every gh call in the file that does not name the repo
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in "auth status") continue ;; esac
    case "$l" in
      *" --repo $2 "*|*" --repo $2"|"repo view $2 "*) ;;
      *) bad "${1##*/}: a gh call that does not name $2: $l" ;;
    esac
  done < "$1"
}
mk_brief() {   # <file> <worktree> [<branch>]
  printf '%s\n' "BRANCH: ${3:-fix/$ISS-auto}" "WORKTREE: $2" 'Do NOT cd into it.' 'STOP and report if blocked.' \
    'Commit after each step.' 'cargo check --no-default-features' './tests/run.sh' 'You may commit. Do NOT push.' > "$1"
}

# ---- the drive: every scenario, in one sandbox, under $XE -----------------------------------------------------------
drive_all() {   # <def|alt>: the scenarios -> $SB/trace, $SB/{gh,git,out,rc}.<label>
  local tag="$1" name base
  case "$tag" in
    def) name=velostream;  base=master; XE="" ;;
    alt) name=velo-agents; base=main;   XE="VELO_REPO=$ALT" ;;
  esac
  : > "$SB/trace"
  fx_base "$base"
  fx_pr '[#2231] #1: a child PR' 'Fixes #5' feat/gate "$base" bin/velo-gate src/a.rs tests/t.sh
  fx_issue 5 $'## Acceptance\n- one\n- two\n- three\n- four\n'
  fx_issue $ISS ''
  fx_issue 9 ''
  printf '[]\n' > "$FX/issue-list.json"; printf '[]\n' > "$FX/pr-list-running.json"
  jq -nc '[{number:12, title:"[#9] x", headRefName:"feat/gate", mergeable:"MERGEABLE", statusCheckRollup:[]}]' > "$FX/pr-list.json"
  printf '## report\n**Verdict:** approve\n' > "$FX/report.md"
  printf 'what this PR does\n' > "$FX/scope.md"
  mk_brief "$FX/brief.md" "$H/RustroverProjects/$name-$ISS"

  fx_comments
  sc gate-plan bash "$R/bin/velo-gate" $PR --plan
  fx_comments "$(gate_comment code-review)"
  sc gate-show bash "$R/bin/velo-gate" $PR
  fx_comments "$(gate_comment code-review)" "$(gate_comment check-code)" "$(gate_comment check-spec)"
  sc gate-pass bash "$R/bin/velo-gate" $PR --pass
  sc gate-finish bash "$R/bin/velo-gate-finish" $PR $H9 --pass --code-review "$FX/report.md"
  sc gate-block bash "$R/bin/velo-gate" $PR --block
  sc gate-running bash "$R/bin/velo-gate" $PR --running
  sc gate-post bash "$R/bin/velo-gate-post" $PR code-review "$FX/report.md" --sha $H9
  printf 'Build & Test\tpass\t1m\thttps://x\n' > "$FX/pr-checks.txt"
  sc sweep bash "$R/bin/velo-gate-sweep" $PR
  fx_comments
  sc pr-gate-plan bash "$R/bin/velo-pr-gate" $PR --plan
  CWD="$H/RustroverProjects/velostream" sc pr-gate-brief bash "$R/bin/velo-pr-gate" $PR "$FX/scope.md" --brief-only
  sc dispatch-dry bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
  sc spec-review bash "$R/bin/velo-spec-review" $ISS "$FX/brief.md"
  sc record bash "$R/bin/velo-record" $WIP --worktree "$H/RustroverProjects/$name-$WIP" --worker local --model m \
    --started 2026-10-29T00:00:00Z --rc 0 --max-turns 10
  sc status bash "$R/bin/velo-status"
  sc merge bash "$R/bin/velo-merge" $PR
  sc native bash "$R/bin/velo-native" start 5 fix/5-x /w --model haiku
  sc native-rows bash "$R/bin/velo-native" rows
  sc orchestrd bash "$R/bin/velo-orchestrd" tick
  printf 'Build\tpending\t1m\thttps://x\n' > "$FX/pr-checks.txt"; printf '8\n' > "$FX/pr-checks.rc"
  sc watch bash "$R/bin/velo-watch" --pr $PR --interval 1 --max 1
  jq -nc '[{number:12, title:"[#9] x", headRefName:"feat/gate"}]' > "$FX/pr-list-running.json"
  sc hook bash "$R/hooks/session-start-inflight.sh"
}
drive() {   # <def|alt>: the drive of this repo for the code under test (R), run once; leaves the sandbox variables set
  local tag="$1" key
  key="$T/drive.$(printf '%s' "$R" | cksum | cut -d' ' -f1).$tag"
  if [ -s "$key" ]; then
    sb_use "$(cat "$key")"
  else
    sb_new && mk_world && drive_all "$tag" || { echo "FAILED: the $tag drive could not run" >&2; return 1; }
    printf '%s\n' "$SB" > "$key"
  fi
  case "$tag" in def) XE="" ;; alt) XE="VELO_REPO=$ALT" ;; esac
}
state_tree() {   # the files under the state dir, timestamps and pids masked
  (cd "$S" && find . -mindepth 1 | sed 's#^\./##' | sed -E 's/[0-9]{8}T[0-9]{6}Z/<ts>/g; s/-[0-9]+\.md$/-<pid>.md/' | sort)
}
norm() {   # stdin with everything that differs between runs and trees made equal
  sed -E "s#$SB#<SB>#g; s#$R#<R>#g; s/[0-9]{8}T[0-9]{6}Z/<ts>/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/<iso>/g; s/[0-9a-f]{7,40}/<sha>/g; s/-[0-9]+\.(md|log)/-<pid>.\1/g; s/wall=[0-9]+s/wall=<n>s/g"
}
default_trace() {   # the default repo's whole drive -> stdout: the gh calls, the state tree, the review brief, every output
  local f
  cat "$SB/trace"
  echo "== state"; state_tree
  echo "== brief"; norm < "$S/gate/$PR/review-brief.md"
  for f in "$SB"/out.*; do echo "== out ${f##*/out.}"; norm < "$f"; done
}

if [ -n "${REPO_ENV_GOLDEN_FROM:-}" ]; then   # regenerate the golden from a tree: see tests/fixtures/repo-env/README
  R="$REPO_ENV_GOLDEN_FROM"; sb_new && mk_world && drive_all def && default_trace
  exit $?
fi

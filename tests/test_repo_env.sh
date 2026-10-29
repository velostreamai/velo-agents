#!/bin/bash
# VELO_REPO (alias VELO_GATE_REPO): the gate tools work on ANY GitHub repo, and Velostream, the default, is untouched
# (velo-agents#17, velostream#2769).
#
# The repo used to be spelled velostreamai/velostream in 13 places (12 files), and `gh` without --repo answers from the caller's cwd.
# Every bar below is therefore proved by RUNNING the real scripts against a stub gh that logs its argv, in a sandbox that holds
# a clone of each repo - and then by breaking the code and watching the check go red (tests/mutation-lib.sh):
#
#   1 the default is unchanged     the recorded behaviour of the scripts before the variable (fixtures/repo-env/default.golden):
#                                  every gh argv, every state path, the review brief, every output
#   2 the variable reaches every gh call, and the default is spelled once (bin/ and hooks/): scanned in the source AND observed
#   3 state paths are scoped       PR 12 of two repos never share a gate dir (post-once markers, gated.sha, prune)
#   4 no cwd fallback              a tree that is missing, belongs to another repo, or is on another branch is refused, by
#                                  path; the Velostream tree is never read for another repo, even as the cwd on the same branch
#   5 a plan for that repo's diff  tier and legs, with check-spec triggered by a closing OR a referencing issue
#
# The worker-side tools (dispatch, record, status, native, orchestrd, watch, the SessionStart hook) are in
# test_repo_env_workers.sh; both share tests/repo-env-lib.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-env-lib.sh"

LIB=bin/velo-repo-lib.sh

# ---- scans of the source ---------------------------------------------------------------------------------------------
# Every `gh <noun>` COMMAND (not a message that mentions one) in a logical line (backslash continuations joined). With -v all=1
# every gh command is listed; without, only those that do not name the repo.
cat > "$T/gh-scan.awk" <<'AWK'
function flush(   l, t) {
  if (cur == "") return
  l = cur; cur = ""
  t = l; sub(/^[ \t]+/, "", t)
  if (t ~ /^#/) return
  if (l ~ /(^[ \t]*\(?|\$\(|[;&|`{]|(^|[ \t])(then|else|do|if|while|until|!)[ \t])[ \t]*(timeout[ \t]+[0-9a-zA-Z_.${}]+[ \t]+)?(command[ \t]+)?gh[ \t]+(pr|issue|repo|api|run|label|release|search)[ \t]/ \
      && (all || l !~ /--repo|[ \t]-R[ \t]|gh[ \t]+repo[ \t]+view[ \t]+"\$REPO"/))
    printf "%s:%d: %s\n", FILENAME, start, substr(t, 1, 110)
}
{
  if (cur == "") start = FNR
  line = $0
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cur = cur line " "; next }
  cur = cur line
  flush()
}
AWK
# Every code line that builds a path under the state dir for one of the per-number dirs. Without -v all=1 only those that do
# not carry the repo's suffix (REPO_SUB / GATE_SUBDIR / repo_scoped).
cat > "$T/state-scan.awk" <<'AWK'
function flush(   l, t) {
  if (cur == "") return
  l = cur; cur = ""; t = l; sub(/^[ \t]+/, "", t)
  if (t ~ /^#/ || l ~ /~\//) return
  if (l ~ /(VELO_STATE|STATE|\.agents\/state)[}"]*\/(gate|dispatch|records|spec|native|orch)([\/"}$ ]|$)/ \
      && (all || (l !~ /GATE_SUBDIR|REPO_SUB|repo_scoped/ && l !~ /\*__\*/)))
    printf "%s:%d: %s\n", FILENAME, start, substr(t, 1, 150)
}
{
  if (cur == "") start = FNR
  line = $0
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cur = cur line " "; next }
  cur = cur line
  flush()
}
AWK

t_literal_once() {
  local hits n
  hits=$(cd "$R" && grep -rn "velostreamai/velostream" bin hooks 2>/dev/null)
  [ -n "$hits" ] || { bad "the default repo is spelled nowhere: it is defined once, in $LIB"; return 1; }
  n=$(grep -c . <<<"$hits")
  [ "$n" -eq 1 ] || bad "the default repo is spelled $n times in bin/ and hooks/, want exactly its one definition: $(nonl "$hits")"
  case "$hits" in
    "$LIB":*'VELO_DEFAULT_REPO="velostreamai/velostream"') ;;
    *) bad "the one spelling is not the VELO_DEFAULT_REPO definition in $LIB: $(nonl "$hits")" ;;
  esac
  [ "$BAD" -eq 0 ]
}
t_gh_calls_static() {
  local out n
  out=$(cd "$R" && awk -f "$T/gh-scan.awk" bin/velo-* hooks/*.sh)
  [ -z "$out" ] || bad "gh command(s) that do not name the repo, so gh would answer from the caller's cwd: $(nonl "$out" 400)"
  n=$(cd "$R" && awk -v all=1 -f "$T/gh-scan.awk" bin/velo-* hooks/*.sh | grep -c .)
  [ "$n" -ge 40 ] || bad "the scan found $n gh commands in bin/ and hooks/ (there are about 47): it no longer reads them"
  [ "$BAD" -eq 0 ]
}
t_state_paths_static() {
  local out n
  out=$(cd "$R" && awk -f "$T/state-scan.awk" $(ls bin/velo-* hooks/*.sh | grep -v 'velo-record-backfill'))
  [ -z "$out" ] || bad "path(s) under the state dir shared by two repos' numbers: $(nonl "$out" 400)"
  n=$(cd "$R" && awk -v all=1 -f "$T/state-scan.awk" $(ls bin/velo-* hooks/*.sh | grep -v 'velo-record-backfill') | grep -c .)
  [ "$n" -ge 15 ] || bad "the scan found $n state paths in bin/ and hooks/ (there are about 22): it no longer reads them"
  [ "$BAD" -eq 0 ]
}

# ---- the library: what repo_init decides -----------------------------------------------------------------------------
libv() {   # <VAR=value>...: repo_init's results under exactly those variables, one NAME=value per line (the note's newlines as ~)
  env -i PATH="$PATH" R="$R" "$@" bash -c '
    . "$R/bin/velo-repo-lib.sh" || exit 8
    repo_init || exit 9
    for v in REPO REPO_IS_DEFAULT REPO_NAME REPO_SUB GATE_SUBDIR GATE_PATH_RE GATE_CMD_ENV GATE_ORCH_RE GATE_ORCH_WHERE; do
      printf "%s=%s\n" "$v" "${!v}"
    done
    printf "REPO_NOTE=%s\n" "$(printf "%s" "$REPO_NOTE" | tr "\n" "~")"' 2>&1
}
val() { sed -n "s/^$1=//p" <<<"$2" | head -1; }   # val <NAME> <libv output>
orch_class() {   # <regex> <yes|no> <path>...: which of these paths the regex calls orchestration
  local re="$1" w="$2" p; shift 2
  for p in "$@"; do
    if grep -qE "$re" <<<"$p"; then [ "$w" = yes ] || bad "$p counts as orchestration and must not (pattern $re)"
    else [ "$w" = no ] || bad "$p does not count as orchestration and must (pattern $re)"; fi
  done
}
t_lib_default() {
  local o; o=$(libv)
  eq "$(val REPO "$o")" "$DEF" "the repo when nothing is set"
  eq "$(val REPO_IS_DEFAULT "$o")" 1 "REPO_IS_DEFAULT"
  eq "$(val REPO_NAME "$o")" velostream "REPO_NAME (the checkout is ~/RustroverProjects/velostream)"
  eq "$(val REPO_SUB "$o")" "" "REPO_SUB: the default's state paths carry no repo suffix"
  eq "$(val GATE_SUBDIR "$o")" gate "GATE_SUBDIR"
  eq "$(val GATE_PATH_RE "$o")" 'state/gate/[0-9]+/' "GATE_PATH_RE"
  eq "$(val GATE_CMD_ENV "$o")" "" "GATE_CMD_ENV: a printed command for the default needs no variable"
  eq "$(val GATE_ORCH_WHERE "$o")" "under .agents/" "GATE_ORCH_WHERE"
  eq "$(val REPO_NOTE "$o")" "" "REPO_NOTE: the default's briefs carry no note"
  orch_class "$(val GATE_ORCH_RE "$o")" yes .agents/bin/velo-gate .agents/rules/x.md .agents/skills/s/SKILL.md .agents/tasks/1.json \
    .agents/install.sh .agents/update.sh
  orch_class "$(val GATE_ORCH_RE "$o")" no bin/velo-gate src/a.rs tests/t.sh .agents/tests/t.sh hooks/h.sh README.md
  [ "$BAD" -eq 0 ]
}
t_lib_alt() {
  local o; o=$(libv VELO_REPO=$ALT)
  eq "$(val REPO "$o")" "$ALT" "the repo"
  eq "$(val REPO_IS_DEFAULT "$o")" 0 "REPO_IS_DEFAULT"
  eq "$(val REPO_NAME "$o")" velo-agents "REPO_NAME (the checkout is ~/RustroverProjects/velo-agents)"
  eq "$(val REPO_SUB "$o")" "/$ALT_SUB" "REPO_SUB: the suffix that keeps this repo's numbers apart"
  eq "$(val GATE_SUBDIR "$o")" "gate/$ALT_SUB" "GATE_SUBDIR"
  eq "$(val GATE_PATH_RE "$o")" "state/gate/$ALT_SUB/[0-9]+/" "GATE_PATH_RE: how a reviewer's command line names this repo's gate dir"
  eq "$(val GATE_CMD_ENV "$o")" "VELO_REPO=$ALT " "GATE_CMD_ENV: the variable a pasted follow-up command needs"
  eq "$(val GATE_ORCH_WHERE "$o")" "in the tooling tree" "GATE_ORCH_WHERE"
  has "$(val REPO_NOTE "$o")" "REPO: $ALT is NOT Velostream." || bad "REPO_NOTE does not say the repo is not Velostream: $(val REPO_NOTE "$o")"
  has "$(val REPO_NOTE "$o")" "OVERRIDE-DIRECTIVES:" || bad "REPO_NOTE does not carry the OVERRIDE-DIRECTIVES: token velo-impl.md honours"
  case "$(val REPO_NOTE "$o")" in *'~~') ;; *) bad "REPO_NOTE does not end with a blank line, so the text it opens would run into it" ;; esac
  orch_class "$(val GATE_ORCH_RE "$o")" yes bin/velo-gate rules/x.md skills/s/SKILL.md tasks/1.json hooks/h.sh launchd/p.plist install.sh update.sh
  orch_class "$(val GATE_ORCH_RE "$o")" no src/a.rs tests/t.sh README.md docs/x.md
  [ "$BAD" -eq 0 ]
}
t_lib_precedence() {
  eq "$(val REPO "$(libv VELO_REPO=$ALT)")" "$ALT" "VELO_REPO alone"
  eq "$(val REPO "$(libv VELO_GATE_REPO=$ALT)")" "$ALT" "the older name VELO_GATE_REPO alone"
  eq "$(val REPO "$(libv VELO_REPO=$ALT VELO_GATE_REPO=other/thing)")" "$ALT" "VELO_REPO overrides VELO_GATE_REPO"
  eq "$(val REPO "$(libv VELO_REPO= VELO_GATE_REPO=$ALT)")" "$ALT" "an empty VELO_REPO falls through to VELO_GATE_REPO"
  eq "$(val REPO "$(libv VELO_REPO= VELO_GATE_REPO=)")" "$DEF" "both empty is the default"
  [ "$BAD" -eq 0 ]
}
t_lib_validation() {
  local v o rc
  for v in nonsense a/b/c /x x/ -a/b a/-b 'a b/c' 'a/b c' 'a/b;rm' '$(id)/x' a//b a/.. o/.hidden /; do
    o=$(libv "VELO_REPO=$v"); rc=$?
    [ "$rc" -ne 0 ] || bad "VELO_REPO='$v' was accepted, and it is not <owner>/<name>"
    has "$o" "VELO_REPO must be <owner>/<name>, got" || bad "VELO_REPO='$v' was refused without saying why: $(nonl "$o")"
  done
  for v in a/b Owner123/Name.with-dots_x velostreamai/velo-agents x-y/z; do
    o=$(libv "VELO_REPO=$v"); rc=$?
    [ "$rc" -eq 0 ] || bad "VELO_REPO='$v' is a repo and was refused: $(nonl "$o")"
  done
  [ "$BAD" -eq 0 ]
}
t_lib_case() {
  local o
  o=$(libv VELO_REPO=VELOSTREAMAI/Velostream)
  eq "$(val REPO "$o")" "$DEF" "the default, spelled in capitals, is the default"
  eq "$(val REPO_IS_DEFAULT "$o")" 1 "...and is treated as it"
  eq "$(val REPO_SUB "$o")" "" "...with the default's own state paths"
  o=$(libv VELO_REPO=VeloStreamAI/Velo-Agents)
  eq "$(val REPO "$o")" "VeloStreamAI/Velo-Agents" "a repo is handed to gh as it was given"
  eq "$(val REPO_SUB "$o")" "/$ALT_SUB" "...but one repo is one state dir, whatever its case"
  eq "$(val GATE_SUBDIR "$o")" "gate/$ALT_SUB" "GATE_SUBDIR is case-blind too"
  [ "$BAD" -eq 0 ]
}

# ---- the scripts under the variable ----------------------------------------------------------------------------------
t_env_alias() {   # both names reach a real script, and VELO_REPO wins
  local l e
  sb_new || return 1
  fx_base main; fx_pr 'plain title' '' feat/gate main src/a.rs
  for e in "VELO_GATE_REPO=$ALT" "VELO_REPO=$ALT VELO_GATE_REPO=$DEF"; do
    XE="$e"; : > "$GL"; x bash "$R/bin/velo-gate" $PR --plan
    [ -s "$GL" ] || bad "$e: velo-gate made no gh call"
    while IFS= read -r l; do
      case "$l" in *" --repo $ALT "*) ;; *) bad "$e: a gh call that does not name $ALT: $l" ;; esac
    done < "$GL"
  done
  [ "$BAD" -eq 0 ]
}
t_invalid_everywhere() {   # a value that is not <owner>/<name> stops every tool before any gh call
  local c name args
  sb_new || return 1
  fx_base main; fx_pr 'plain title' '' feat/gate main src/a.rs
  printf 'r\n' > "$FX/report.md"; printf 's\n' > "$FX/scope.md"; mk_brief "$FX/brief.md" "$H/RustroverProjects/velo-agents-78"
  XE="VELO_REPO=not-a-repo"
  for c in "velo-gate $PR --plan" "velo-gate-post $PR code-review $FX/report.md --sha $H9" \
           "velo-gate-finish $PR $H9 --pass --code-review $FX/report.md" "velo-gate-run $PR $FX/scope.md" "velo-gate-sweep $PR" \
           "velo-pr-gate $PR --plan" "velo-merge $PR" "velo-dispatch $ISS $FX/brief.md --dry-run" "velo-status" \
           "velo-watch --pr $PR --max 1" "velo-native rows" "velo-orchestrd tick" "velo-attention list" \
           "velo-spec-review $ISS $FX/brief.md" "velo-record $WIP --worker local --rc 0"; do
    name=${c%% *}; args=${c#"$name"}
    : > "$GL"
    x bash "$R/bin/$name" $args
    has "$OUT" "VELO_REPO must be <owner>/<name>, got not-a-repo" || bad "$name: did not refuse VELO_REPO=not-a-repo: $(nonl "$OUT" 160)"
    [ ! -s "$GL" ] || bad "$name: called gh before refusing VELO_REPO=not-a-repo: $(nonl "$(cat "$GL")" 160)"
    case "$name" in
      velo-record) [ "$RC" -eq 0 ] || bad "$name is observational and exits 0, got $RC" ;;
      *) [ "$RC" -ne 0 ] || bad "$name exited 0 on VELO_REPO=not-a-repo" ;;
    esac
  done
  : > "$GL"; x bash "$R/hooks/session-start-inflight.sh"
  has "$OUT" "VELO_REPO must be <owner>/<name>, got not-a-repo" || bad "the SessionStart hook did not refuse VELO_REPO=not-a-repo: $(nonl "$OUT" 160)"
  [ ! -s "$GL" ] || bad "the SessionStart hook called gh before refusing VELO_REPO=not-a-repo"
  [ "$BAD" -eq 0 ]
}

# bar 1
t_default_unchanged() {
  drive def || return 1
  [ -s "$GOLDEN" ] || { bad "the golden $GOLDEN is missing or empty"; return 1; }
  default_trace > "$SB/actual.golden"
  if ! diff "$GOLDEN" "$SB/actual.golden" > "$SB/golden.diff"; then
    bad "with VELO_REPO unset the tools differ from tests/fixtures/repo-env/default.golden in $(grep -c '^[<>]' "$SB/golden.diff") line(s), first: $(grep -m1 '^[<>]' "$SB/golden.diff" | cut -c1-200)"
    sed -n '1,24p' "$SB/golden.diff" | sed 's/^/        /'
  fi
  [ "$BAD" -eq 0 ]
}
# bar 2
t_nondefault_calls() {
  local l f c
  drive alt || return 1
  for f in "$SB"/gh.*; do
    gh_names "$f" "$ALT"
    while IFS= read -r l; do
      case "$l" in *"$DEF"*) bad "${f##*/}: a gh call that names $DEF: $l" ;; esac
    done < "$f"
  done
  # a check that reads no calls proves nothing: each scenario made the calls it is known to make
  for c in gate-plan:2 gate-show:3 gate-pass:5 gate-finish:5 gate-block:2 gate-running:2 gate-post:2 sweep:2 pr-gate-plan:2 \
           pr-gate-brief:5 dispatch-dry:2 record:1 status:7 merge:1 orchestrd:3 watch:2 hook:1; do
    f=$(wc -l < "$SB/gh.${c%%:*}" | tr -d ' ')
    [ "$f" -ge "${c##*:}" ] || bad "scenario ${c%%:*} made $f gh call(s), want at least ${c##*:}: the drive no longer exercises it"
  done
  [ "$BAD" -eq 0 ]
}
# bar 3
t_alt_state_layout() {
  local t f
  drive alt || return 1
  t=$(state_tree)
  while IFS= read -r f; do
    case "$f" in
      dispatch|gate|native|orch|records) ;;
      dispatch/$ALT_SUB|gate/$ALT_SUB|native/$ALT_SUB|orch/$ALT_SUB|records/$ALT_SUB) ;;
      dispatch/$ALT_SUB/*|gate/$ALT_SUB/*|native/$ALT_SUB/*|orch/$ALT_SUB/*|records/$ALT_SUB/*) ;;
      *) bad "the drive for $ALT wrote $f outside its own $ALT_SUB directory, where PR and issue numbers of two repos would share it" ;;
    esac
  done <<<"$t"
  for f in "records/$ALT_SUB/77.result.jsonl" "orch/$ALT_SUB/attention.jsonl" "orch/$ALT_SUB/offsets/77.count" "native/$ALT_SUB/5.json" \
           "gate/$ALT_SUB/$PR/gated.sha" "gate/$ALT_SUB/$PR/review-brief.md" "gate/$ALT_SUB/$PR/.posted-code-review-$H9" \
           "gate/$ALT_SUB/$PR/gate-finish.verdict.out" "dispatch/$ALT_SUB/$ISS/brief-<ts>-<pid>.md" "dispatch/$ALT_SUB/$ISS/dispatch-<ts>.log"; do
    has "$t" "$f" || bad "the drive for $ALT did not leave $f in the state dir"
  done
  [ "$BAD" -eq 0 ]
}
t_two_repos_one_state_dir() {   # PR 12 of Velostream and PR 12 of velo-agents, one state dir
  local alt_out
  sb_new || return 1
  fx_base main; fx_pr 'plain title' '' feat/gate main src/a.rs
  printf '## report\n**Verdict:** approve\n' > "$FX/report.md"
  XE="VELO_REPO=$ALT"; : > "$GL"; x bash "$R/bin/velo-gate-post" $PR code-review "$FX/report.md" --sha $H9
  [ "$RC" -eq 0 ] && has "$(cat "$GL")" "pr comment $PR --repo $ALT " || bad "the post to $ALT's PR $PR did not happen: rc=$RC $(nonl "$OUT" 160)"
  XE=""; : > "$GL"; x bash "$R/bin/velo-gate-post" $PR code-review "$FX/report.md" --sha $H9
  [ "$RC" -eq 0 ] && has "$(cat "$GL")" "pr comment $PR --repo $DEF " \
    || bad "Velostream's PR $PR code-review @ $H9 was not posted after $ALT's: the post-once marker is shared. rc=$RC $(nonl "$OUT" 200)"
  [ -e "$S/gate/$PR/.posted-code-review-$H9" ] || bad "no post-once marker in Velostream's gate/$PR"
  [ -e "$S/gate/$ALT_SUB/$PR/.posted-code-review-$H9" ] || bad "no post-once marker in $ALT's gate/$ALT_SUB/$PR"
  # each repo's sweep reads its own gated.sha
  printf '%s\n' "$HEADSHA" > "$S/gate/$ALT_SUB/$PR/gated.sha"
  printf '2222222222222222222222222222222222222222\n' > "$S/gate/$PR/gated.sha"
  printf 'Build\tpass\t1m\thttps://x\n' > "$FX/pr-checks.txt"
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-gate-sweep" $PR; alt_out="$OUT"
  XE=""; x bash "$R/bin/velo-gate-sweep" $PR
  want "$alt_out" "gated=111111111" "the sweep of $ALT's PR $PR does not read its own gated.sha: $(nonl "$alt_out" 160)"
  unwant "$alt_out" "STALE" "the sweep of $ALT's PR $PR (gated at its head) says STALE: it read another repo's gated.sha"
  want "$OUT" "gated=222222222" "the sweep of Velostream's PR $PR does not read its own gated.sha: $(nonl "$OUT" 160)"
  want "$OUT" "STALE" "the sweep of Velostream's PR $PR (gated at another sha) does not say STALE: it read $ALT's gated.sha"
  [ "$BAD" -eq 0 ]
}
t_prune_scoped() {   # the 7-day sweep of gate dirs: a repo's dir is never swept as if it were a PR's, and sweeps its own PRs
  sb_new && mk_world || return 1
  printf 'scope\n' > "$FX/scope.md"
  mkdir -p "$S/gate/7" "$S/gate/$ALT_SUB/7" "$S/gate/$ALT_SUB/8"
  touch -t 202001010000 "$S/gate/7" "$S/gate/$ALT_SUB/7" "$S/gate/$ALT_SUB"   # the slug dir last: creating a child moves its mtime
  fx_base master; fx_pr 'plain title' '' feat/gate master src/a.rs
  XE=""; CWD="$H/RustroverProjects/velostream"; x bash "$R/bin/velo-pr-gate" $PR "$FX/scope.md" --brief-only
  [ "$RC" -eq 0 ] || bad "Velostream's brief-only run failed: $(nonl "$OUT" 200)"
  [ ! -e "$S/gate/7" ] || bad "Velostream's run did not prune its own old PR dir gate/7"
  [ -d "$S/gate/$ALT_SUB" ] || bad "Velostream's run swept $ALT's whole gate dir, which only looks idle because its PR dirs are older children"
  [ -d "$S/gate/$ALT_SUB/8" ] || bad "Velostream's run removed $ALT's live PR dir"
  fx_base main; fx_pr 'plain title' '' feat/gate main src/a.rs
  XE="VELO_REPO=$ALT"; CWD="$H/RustroverProjects/velostream"; x bash "$R/bin/velo-pr-gate" $PR "$FX/scope.md" --brief-only
  [ "$RC" -eq 0 ] || bad "$ALT's brief-only run failed: $(nonl "$OUT" 200)"
  [ ! -e "$S/gate/$ALT_SUB/7" ] || bad "$ALT's run did not prune its own old PR dir"
  [ -d "$S/gate/$ALT_SUB/8" ] || bad "$ALT's run removed its own live PR dir"
  [ -d "$S/gate/$ALT_SUB" ] || bad "$ALT's run removed its own gate dir"
  [ "$BAD" -eq 0 ]
}

# bar 4
alt_gate() {   # <head branch>: velo-pr-gate --brief-only for PR 12 on $ALT from the Velostream tree, which is on feat/gate
  fx_base main; fx_pr 'plain title' '' "$1" main bin/velo-x; printf 'scope\n' > "$FX/scope.md"
  XE="VELO_REPO=$ALT"; CWD="$H/RustroverProjects/velostream"; [ -d "$CWD" ] || CWD="$SB"
  x bash "$R/bin/velo-pr-gate" $PR "$FX/scope.md" --brief-only
}
only_alt_git() {   # every git command the run made ran in a tree of $ALT
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in *": -C $H/RustroverProjects/velo-agents"*) ;; *) bad "a git command outside $ALT's trees: $l" ;; esac
  done < "$GITL"
}
t_worktree_missing() {
  sb_new && mk_tree velostream master || return 1
  alt_gate feat/gate
  [ "$RC" -ne 0 ] || bad "a PR of $ALT was gated with no tree of $ALT on the machine (it fell back to another tree): $(nonl "$OUT" 200)"
  want "$OUT" "$H/RustroverProjects/velo-agents" "the refusal does not name the path it looked in, $H/RustroverProjects/velo-agents: $(nonl "$OUT" 300)"
  unwant "$OUT" "worktree: $H" "the run reports a worktree it should not have found"
  [ ! -e "$S/gate/$ALT_SUB/$PR" ] || bad "a refused run left state for $ALT's PR $PR"
  only_alt_git
  [ "$BAD" -eq 0 ]
}
t_worktree_wrong_repo() {   # the tree at the repo's name is a clone of ANOTHER repo
  sb_new && mk_tree velostream master || return 1
  git clone -q "$SB/remote/velostreamai/velostream" "$H/RustroverProjects/velo-agents" && git -C "$H/RustroverProjects/velo-agents" checkout -q -b feat/gate || return 1
  alt_gate feat/gate
  [ "$RC" -ne 0 ] || bad "a clone of Velostream at ~/RustroverProjects/velo-agents was read as $ALT's tree: $(nonl "$OUT" 200)"
  want "$OUT" "is a checkout of $DEF, not $ALT" "the refusal does not say whose checkout it found: $(nonl "$OUT" 300)"
  only_alt_git
  [ "$BAD" -eq 0 ]
}
t_worktree_not_a_checkout() {   # a plain directory inside some OTHER repo that happens to have the right origin
  sb_new || return 1
  git init -q -b main "$H/RustroverProjects" && git -C "$H/RustroverProjects" remote add origin "$SB/remote/velostreamai/velo-agents" \
    && git -C "$H/RustroverProjects" $GITID commit -q --allow-empty -m e && git -C "$H/RustroverProjects" checkout -q -b feat/gate \
    && mkdir -p "$H/RustroverProjects/velo-agents" || return 1
  alt_gate feat/gate
  [ "$RC" -ne 0 ] || bad "a plain directory was read as a checkout of $ALT through the repo that encloses it: $(nonl "$OUT" 200)"
  want "$OUT" "$H/RustroverProjects/velo-agents is not a git checkout" "the refusal does not say the directory is no checkout: $(nonl "$OUT" 300)"
  [ "$BAD" -eq 0 ]
}
t_worktree_wrong_branch() {   # the right tree, on another branch than the PR's head
  sb_new && mk_world || return 1
  git -C "$H/RustroverProjects/velo-agents" checkout -q main || return 1
  alt_gate feat/gate
  [ "$RC" -ne 0 ] || bad "a tree of $ALT on main was read as the tree of a PR whose head is feat/gate: $(nonl "$OUT" 200)"
  want "$OUT" "is checked out on 'feat/gate'" "the refusal does not name the branch it wanted: $(nonl "$OUT" 300)"
  want "$OUT" "$H/RustroverProjects/velo-agents (on main)" "the refusal does not say what each tree it looked at is on: $(nonl "$OUT" 300)"
  [ "$BAD" -eq 0 ]
}
t_worktree_found() {
  local b
  drive alt || return 1
  b=$(cat "$S/gate/$ALT_SUB/$PR/review-brief.md")
  want "$b" "WORKTREE: $H/RustroverProjects/velo-agents (head" "the brief reviews no tree of $ALT, though the Velostream tree on the same branch was the caller's cwd: $(nonl "$b" 200)"
  unwant "$b" "RustroverProjects/velostream" "the brief of a $ALT PR names the Velostream tree"
  want "$b" "git -C $H/RustroverProjects/velo-agents diff origin/main...HEAD" "the diff is not read from $ALT's tree against its own base branch"
  # a worker's worktree is found by its branch among ~/RustroverProjects/velo-agents-*, and Velostream's is not
  sb_new && mk_world || return 1
  alt_gate fix/$WIP-alt
  [ "$RC" -eq 0 ] || bad "a PR whose head is a worker's branch was refused: $(nonl "$OUT" 300)"
  want "$OUT" "worktree: $H/RustroverProjects/velo-agents-$WIP" "the worker's worktree velo-agents-$WIP was not found by its branch: $(nonl "$OUT" 300)"
  alt_gate fix/$WIP-def
  [ "$RC" -ne 0 ] || bad "$ALT's PR was gated in the Velostream worktree that has the same worker slot: $(nonl "$OUT" 300)"
  only_alt_git
  [ "$BAD" -eq 0 ]
}

# bar 5
t_plan_alt() {
  local p g
  drive alt || return 1
  p=$(cat "$SB/out.pr-gate-plan"); g=$(cat "$SB/out.gate-plan")
  eq "$(cat "$SB/rc.pr-gate-plan")" 0 "velo-pr-gate --plan exit status"
  for f in "$p" "$g"; do
    want "$f" "#12  [#2231] #1: a child PR  [$ALT]" "the plan does not say whose PR it is: $(nonl "$f" 160)"
    want "$f" "files: 3 (src=1 tests=1)" "the plan does not count the diff's files"
    want "$f" "gates needed:" "the plan has no tier line"
    want "$f" "code-review  (orchestration: 1 file(s) in the tooling tree — governs every other run)" "bin/ of $ALT is not orchestration of that repo"
    want "$f" "check-code   (src/ touched: 1 files)" "src/ of the diff does not plan check-code"
    want "$f" "check-spec   (#5 has 4 acceptance bars)" "the closed issue's acceptance bars do not plan check-spec"
  done
  want "$p" "would dispatch:" "velo-pr-gate --plan lists no legs"
  want "$p" "check-code   -> " "no check-code leg"
  want "$p" "check-spec   -> velo-local" "no check-spec leg"
  want "$p" "code-review  -> codex review" "no code-review leg"
  [ "$BAD" -eq 0 ]
}
plan_row() {   # <title> <body> <files...>, under $XE and $BASE -> PLAN PRC ICALLS (the issue numbers read, space separated)
  local title="$1" body="$2"; shift 2
  fx_pr "$title" "$body" feat/gate "$BASE" "$@"
  : > "$GL"; x bash "$R/bin/velo-gate" $PR --plan
  PLAN="$OUT"; PRC=$RC
  ICALLS=$(sed -n 's/^issue view \([0-9]*\) .*/\1/p' "$GL" | tr '\n' ' ' | sed 's/ $//')
}
plan_world() {   # <default branch>: a sandbox whose issue 5 has 4 bars, issue 6 one, and no issue 99
  sb_new || return 1
  BASE="$1"; fx_base "$BASE"
  fx_issue 5 $'## Acceptance\n- one\n- two\n- three\n- four\n'
  fx_issue 6 $'## Acceptance\n- one\n'
}
t_plan_by_diff() {   # the tier follows the repo's own diff
  plan_world main || return 1
  XE="VELO_REPO=$ALT"
  plan_row 'plain title' 'Fixes #5' README.md docs/x.md
  want "$PLAN" "none — docs only, no buildable code and no orchestration" "a docs-only diff of $ALT plans a gate: $(nonl "$PLAN" 200)"
  plan_row 'plain title' '' src/a.rs
  want "$PLAN" "code-review  (independent reviewer)" "a src/ diff plans no code-review"
  want "$PLAN" "check-code   (src/ touched: 1 files)" "a src/ diff plans no check-code"
  unwant "$PLAN" "check-spec" "a src/ diff with no issue plans check-spec"
  plan_row 'plain title' '' tests/t.sh
  want "$PLAN" "code-review  (independent reviewer)" "a tests/ diff plans no code-review"
  unwant "$PLAN" "check-code" "a tests/ diff plans check-code"
  plan_row 'plain title' '' bin/velo-x
  want "$PLAN" "code-review  (orchestration: 1 file(s) in the tooling tree" "a bin/ diff of $ALT is not orchestration"
  plan_row 'plain title' '' .agents/bin/velo-x
  unwant "$PLAN" "code-review  (orchestration" "Velostream's .agents/ layout counts as orchestration of $ALT"
  [ "$BAD" -eq 0 ]
}
t_check_spec_triggers() {
  plan_world main || return 1
  XE="VELO_REPO=$ALT"
  plan_row 'plain title' 'Part of #5' bin/velo-x
  want "$PLAN" "check-spec   (#5 has 4 acceptance bars)" "a tooling PR that references an issue with bars plans no check-spec: $(nonl "$PLAN" 200)"
  plan_row 'plain title' 'Part of #5' src/a.rs
  want "$PLAN" "check-spec   (#5 has 4 acceptance bars)" "a src/ PR that references an issue with bars plans no check-spec: $(nonl "$PLAN" 200)"
  plan_row 'plain title' 'Fixes #5' bin/velo-x
  want "$PLAN" "check-spec   (#5 has 4 acceptance bars)" "a tooling PR that closes an issue with bars plans no check-spec: $(nonl "$PLAN" 200)"
  plan_row 'plain title' 'Part of #6' bin/velo-x
  unwant "$PLAN" "check-spec" "an issue with one bar plans check-spec"
  eq "$ICALLS" "6" "the issues read for a reference to #6"
  plan_row 'plain title' 'Part of velostreamai/velostream#2769 and #5' bin/velo-x
  want "$PLAN" "check-spec   (#5 has 4 acceptance bars)" "a reference next to another repo's issue plans no check-spec"
  eq "$ICALLS" "5" "the issues read when the body also names another repo's issue (it is not this repo's #2769)"
  plan_row 'plain title' 'Part of #99' bin/velo-x
  eq "$PRC" 0 "a reference to an issue that does not exist is not an error (plan exit status)"
  unwant "$PLAN" "check-spec" "an unresolvable reference plans check-spec"
  eq "$ICALLS" "99" "the issues read for a reference to #99"
  plan_row 'plain title' 'Fixes #99' bin/velo-x
  [ "$PRC" -ne 0 ] || bad "a closing keyword for an issue that cannot be read printed a plan, which may be missing check-spec"
  want "$PLAN" "could not read issue #99, which #12 closes" "the refusal does not say which issue it could not read: $(nonl "$PLAN" 200)"
  plan_row '[#9] fix' '' src/a.rs
  unwant "$PLAN" "check-spec" "a [#N] title plans Velostream's parent-tracked check-spec for $ALT: $(nonl "$PLAN" 200)"
  # Velostream: unchanged
  plan_world master || return 1
  XE=""
  plan_row 'plain title' 'Part of #5' .agents/bin/velo-x
  unwant "$PLAN" "check-spec" "Velostream: a tooling PR that references an issue plans check-spec"
  eq "$ICALLS" "" "Velostream: the issues read for 'Part of #5' on a tooling PR"
  plan_row 'plain title' 'Fixes #5' .agents/bin/velo-x
  unwant "$PLAN" "check-spec" "Velostream: a tooling PR that closes an issue with bars plans check-spec"
  plan_row 'plain title' 'Part of #5' src/a.rs
  unwant "$PLAN" "check-spec" "Velostream: a reference ('Part of #5') plans check-spec; only a closing keyword does"
  eq "$ICALLS" "" "Velostream: the issues read for 'Part of #5' on a src/ PR"
  plan_row 'plain title' 'Fixes #5' src/a.rs
  want "$PLAN" "check-spec   (#5 has 4 acceptance bars)" "Velostream: a closing keyword no longer plans check-spec"
  plan_row '[#9] fix' '' src/a.rs
  want "$PLAN" "check-spec   (parent-tracked PR" "Velostream: a [#N] src/ PR no longer plans the parent-tracked check-spec"
  [ "$BAD" -eq 0 ]
}
t_merge_alt() {   # the merge gate classifies code by the repo's own tooling paths, and prints commands that act on the repo
  sb_new || return 1
  fx_base main; fx_pr 'plain title' '' feat/gate main bin/velo-x README.md
  XE="VELO_REPO=$ALT"; : > "$GL"; x bash "$R/bin/velo-merge" $PR
  [ "$RC" -ne 0 ] || bad "a PR that changes $ALT's bin/ was merged with no gate"
  want "$OUT" "touches 1 code file(s) and is 'gate:none', not gate:passed" "the refusal does not count bin/ of $ALT as code: $(nonl "$OUT" 300)"
  want "$OUT" "VELO_REPO=$ALT velo-gate $PR --pass" "the command it prints would act on Velostream's #$PR: $(nonl "$OUT" 300)"
  unwant "$(cat "$GL")" "pr merge" "a refused merge called gh pr merge"
  fx_base master; fx_pr 'plain title' '' feat/gate master .agents/bin/velo-x README.md
  XE=""; : > "$GL"; x bash "$R/bin/velo-merge" $PR
  [ "$RC" -ne 0 ] || bad "Velostream: a PR that changes .agents/bin was merged with no gate"
  want "$OUT" "touches 1 code file(s) and is 'gate:none', not gate:passed" "Velostream: .agents/bin no longer counts as code: $(nonl "$OUT" 300)"
  unwant "$OUT" "VELO_REPO=" "Velostream: a printed command carries a repo variable"
  [ "$BAD" -eq 0 ]
}
t_hints() {   # a command printed for another repo names it; one printed for Velostream is what it always was
  local o f
  drive alt || return 1
  want "$(cat "$SB/out.gate-show")" "VELO_REPO=$ALT velo-gate $PR --pass | --block" "gate --show prints a command that would set Velostream's label"
  want "$(cat "$SB/out.merge")" "VELO_REPO=$ALT velo-gate $PR --pass" "velo-merge prints a command that would gate Velostream's PR"
  want "$(cat "$SB/out.hook")" "VELO_REPO=$ALT ~/.agents/bin/velo-watch --pr $PR" "the SessionStart hook prints a watch for Velostream's PR"
  want "$(cat "$SB/out.hook")" "VELO_REPO=$ALT velo-attention ack" "the SessionStart hook prints an ack for Velostream's events"
  drive def || return 1
  for f in "$SB"/out.*; do
    o=$(cat "$f")
    unwant "$o" "VELO_REPO=" "Velostream: ${f##*/} prints a repo variable in a command"
  done
  [ "$BAD" -eq 0 ]
}
t_brief_note() {   # the Velostream-only prerequisites are skipped for another repo, and the brief says so
  local b d n
  drive alt || return 1
  b=$(cat "$S/gate/$ALT_SUB/$PR/review-brief.md")
  want "$b" "REPO: $ALT is NOT Velostream. The Velostream-only prerequisites are SKIPPED here" "the review brief does not say the prerequisites are skipped: $(nonl "$b" 200)"
  want "$b" "OVERRIDE-DIRECTIVES: the 'Read first' CLAUDE.md requirement" "the review brief carries no OVERRIDE-DIRECTIVES: paragraph"
  n=$(grep -n 'OVERRIDE-DIRECTIVES:' <<<"$b" | head -1 | cut -d: -f1); d=$(grep -n '^WORKTREE:' <<<"$b" | head -1 | cut -d: -f1)
  { [ -n "$n" ] && [ -n "$d" ] && [ "$n" -lt "$d" ]; } || bad "the note is not ahead of the brief's WORKTREE line (note at ${n:-none}, WORKTREE at ${d:-none})"
  # the other two places pr-gate hands a reviewer text
  n=$(grep -c 'REPO_NOTE' "$R/bin/velo-pr-gate")
  [ "$n" -ge 3 ] || bad "velo-pr-gate puts the note in $n place(s), want the brief, the spec leg's task and the check-code prompt (3)"
  drive def || return 1
  d=$(cat "$S/gate/$PR/review-brief.md")
  unwant "$d" "NOT Velostream" "Velostream's review brief says it is not Velostream"
  unwant "$d" "OVERRIDE-DIRECTIVES" "Velostream's review brief carries an override"
  [ "$BAD" -eq 0 ]
}
t_ftp_skipped() {   # fail_to_pass reads Velostream's sidecars: for another repo it says it is skipped
  drive alt || return 1
  want "$(cat "$SB/out.pr-gate-brief")" "fail_to_pass: skipped — it reads Velostream's .agents/tasks sidecars, and $ALT has none" "the brief run does not say fail_to_pass was skipped: $(nonl "$(cat "$SB/out.pr-gate-brief")" 300)"
  unwant "$(cat "$SB/gh.pr-gate-brief")" "--json title" "fail_to_pass looked up the title of $ALT's PR to find a Velostream sidecar"
  [ "$BAD" -eq 0 ]
}

# ---- the checks ------------------------------------------------------------------------------------------------------
echo "== which repo: the source"
check "the default repo is spelled once, in bin/velo-repo-lib.sh" t_literal_once
check "every gh command names the repo" t_gh_calls_static
check "every state path under the per-number dirs carries the repo's suffix" t_state_paths_static
echo "== which repo: what repo_init decides"
check "default: Velostream, no suffix, no note" t_lib_default
check "another repo: its name, suffix, tooling paths, note" t_lib_alt
check "VELO_REPO beats VELO_GATE_REPO, an empty one falls through" t_lib_precedence
check "only <owner>/<name> is a repo" t_lib_validation
check "repo names are case-blind for state, exact for gh" t_lib_case
echo "== which repo: the scripts"
check "VELO_GATE_REPO and VELO_REPO reach a real script" t_env_alias
check "an invalid value stops every tool before any gh call" t_invalid_everywhere
echo "== bar 1: the default is unchanged"
check "VELO_REPO unset: gh argv, state, brief and output equal the recorded ones" t_default_unchanged
echo "== bar 2: every gh call carries the repo"
check "VELO_REPO=$ALT: every gh call names it and none names $DEF" t_nondefault_calls
echo "== bar 3: state paths are scoped"
check "everything $ALT writes lives under its own directory" t_alt_state_layout
check "PR 12 of two repos: separate post-once markers and gated.sha" t_two_repos_one_state_dir
check "the 7-day prune keeps each repo's dirs apart" t_prune_scoped
echo "== bar 4: the worktree is the repo's own"
check "no tree of the repo: refused, by path, without touching another tree" t_worktree_missing
check "a clone of another repo at the repo's name: refused" t_worktree_wrong_repo
check "a plain directory inside an enclosing repo: refused" t_worktree_not_a_checkout
check "the repo's tree on another branch: refused, naming each tree" t_worktree_wrong_branch
check "the repo's tree, or its worker worktree, is found by branch" t_worktree_found
echo "== bar 5: a plan for the repo's diff"
check "velo-pr-gate --plan and velo-gate --plan print tier and legs" t_plan_alt
check "the tier follows the diff" t_plan_by_diff
check "check-spec follows a closing or a referencing issue" t_check_spec_triggers
echo "== the rest of the gate"
check "merge counts the repo's tooling as code and prints commands that name it" t_merge_alt
check "printed commands name the repo for another repo, and only then" t_hints
check "the brief says the Velostream-only prerequisites are skipped" t_brief_note
check "fail_to_pass is skipped, and says so" t_ftp_skipped

# ---- the mutants: each breaks one thing, and the check named for it must go red --------------------------------------
echo "== mutation proofs"
# the library
prove "the default repo is velo-agents" t_default_unchanged $LIB 'VELO_DEFAULT_REPO="velostreamai/velostream"' 'VELO_DEFAULT_REPO="velostreamai/velo-agents"'
prove "the default repo is velo-agents" t_lib_default $LIB 'VELO_DEFAULT_REPO="velostreamai/velostream"' 'VELO_DEFAULT_REPO="velostreamai/velo-agents"'
prove "the default repo's state is suffixed" t_default_unchanged $LIB 'REPO_IS_DEFAULT=1; REPO_SUB=""' 'REPO_IS_DEFAULT=1; REPO_SUB="/default"'
prove "the default repo's state is suffixed" t_lib_default $LIB 'REPO_IS_DEFAULT=1; REPO_SUB=""' 'REPO_IS_DEFAULT=1; REPO_SUB="/default"'
prove "the default repo carries a note" t_default_unchanged $LIB 'GATE_CMD_ENV=""; REPO_NOTE=""' 'GATE_CMD_ENV=""; REPO_NOTE="note"'
prove "the default repo carries a note" t_lib_default $LIB 'GATE_CMD_ENV=""; REPO_NOTE=""' 'GATE_CMD_ENV=""; REPO_NOTE="note"'
prove "the default repo's printed commands carry the variable" t_hints $LIB 'GATE_CMD_ENV=""; REPO_NOTE=""' 'GATE_CMD_ENV="VELO_REPO=$REPO "; REPO_NOTE=""'
prove "the default repo's printed commands carry the variable" t_lib_default $LIB 'GATE_CMD_ENV=""; REPO_NOTE=""' 'GATE_CMD_ENV="VELO_REPO=$REPO "; REPO_NOTE=""'
prove "the default repo's brief carries the note" t_brief_note $LIB 'GATE_CMD_ENV=""; REPO_NOTE=""' 'GATE_CMD_ENV=""; REPO_NOTE="REPO: x is NOT Velostream. OVERRIDE-DIRECTIVES: x
"'
prove "the default repo asks GitHub for its branch" t_default_unchanged $LIB 'if [[ $REPO_IS_DEFAULT -eq 1 ]]; then BASE_BRANCH=master' 'if false; then BASE_BRANCH=master'
prove "another repo has no suffix" t_lib_alt $LIB 'REPO_SUB="/${lc/\//__}"' 'REPO_SUB=""'
prove "another repo has no suffix" t_alt_state_layout $LIB 'REPO_SUB="/${lc/\//__}"' 'REPO_SUB=""'
prove "the gate dir of another repo is the default's" t_lib_alt $LIB 'GATE_SUBDIR="gate$REPO_SUB"' 'GATE_SUBDIR="gate"'
prove "the gate dir of another repo is the default's" t_alt_state_layout $LIB 'GATE_SUBDIR="gate$REPO_SUB"' 'GATE_SUBDIR="gate"'
prove "the gate dir of another repo is the default's" t_two_repos_one_state_dir $LIB 'GATE_SUBDIR="gate$REPO_SUB"' 'GATE_SUBDIR="gate"'
prove "another repo's tooling is judged by Velostream's layout" t_lib_alt $LIB 'GATE_ORCH_RE='"'"'^(bin|rules|skills|tasks|hooks|launchd)/|^(install|update)\.sh$'"'" \
  'GATE_ORCH_RE='"'"'^\.agents/(bin|rules|skills|tasks)/|^\.agents/(install|update)\.sh$'"'"
prove "another repo's tooling is judged by Velostream's layout" t_plan_alt $LIB 'GATE_ORCH_RE='"'"'^(bin|rules|skills|tasks|hooks|launchd)/|^(install|update)\.sh$'"'" \
  'GATE_ORCH_RE='"'"'^\.agents/(bin|rules|skills|tasks)/|^\.agents/(install|update)\.sh$'"'"
prove "another repo's tooling is judged by Velostream's layout" t_merge_alt $LIB 'GATE_ORCH_RE='"'"'^(bin|rules|skills|tasks|hooks|launchd)/|^(install|update)\.sh$'"'" \
  'GATE_ORCH_RE='"'"'^\.agents/(bin|rules|skills|tasks)/|^\.agents/(install|update)\.sh$'"'"
prove "another repo's tooling is judged by Velostream's layout" t_plan_by_diff $LIB 'GATE_ORCH_RE='"'"'^(bin|rules|skills|tasks|hooks|launchd)/|^(install|update)\.sh$'"'" \
  'GATE_ORCH_RE='"'"'^\.agents/(bin|rules|skills|tasks)/|^\.agents/(install|update)\.sh$'"'"
prove "a printed command for another repo has no variable" t_lib_alt $LIB 'GATE_CMD_ENV="VELO_REPO=$REPO "' 'GATE_CMD_ENV=""'
prove "a printed command for another repo has no variable" t_hints $LIB 'GATE_CMD_ENV="VELO_REPO=$REPO "' 'GATE_CMD_ENV=""'
prove "a printed command for another repo has no variable" t_merge_alt $LIB 'GATE_CMD_ENV="VELO_REPO=$REPO "' 'GATE_CMD_ENV=""'
prove "another repo has no note" t_lib_alt $LIB "printf -v REPO_NOTE '%s\n\n' \"REPO:" 'REPO_NOTE=""; : "REPO:'
prove "another repo has no note" t_brief_note $LIB "printf -v REPO_NOTE '%s\n\n' \"REPO:" 'REPO_NOTE=""; : "REPO:'
prove "the note lacks the token velo-impl.md honours" t_lib_alt $LIB 'OVERRIDE-DIRECTIVES: the' 'OVERRIDES: the'
prove "the note lacks the token velo-impl.md honours" t_brief_note $LIB 'OVERRIDE-DIRECTIVES: the' 'OVERRIDES: the'
prove "another repo's name is velostream" t_lib_alt $LIB 'REPO_NAME="${REPO#*/}"' 'REPO_NAME=velostream'
prove "gate dirs of reviewers are found under the default's name" t_lib_alt $LIB 'GATE_PATH_RE="state/$GATE_SUBDIR/[0-9]+/"' 'GATE_PATH_RE="state/gate/[0-9]+/"'
prove "the older variable wins" t_lib_precedence $LIB 'REPO="${VELO_REPO:-${VELO_GATE_REPO:-$VELO_DEFAULT_REPO}}"' 'REPO="${VELO_GATE_REPO:-${VELO_REPO:-$VELO_DEFAULT_REPO}}"'
prove "the older variable wins" t_env_alias $LIB 'REPO="${VELO_REPO:-${VELO_GATE_REPO:-$VELO_DEFAULT_REPO}}"' 'REPO="${VELO_GATE_REPO:-${VELO_REPO:-$VELO_DEFAULT_REPO}}"'
prove "the older variable is ignored" t_lib_precedence $LIB 'REPO="${VELO_REPO:-${VELO_GATE_REPO:-$VELO_DEFAULT_REPO}}"' 'REPO="${VELO_REPO:-$VELO_DEFAULT_REPO}"'
prove "the older variable is ignored" t_env_alias $LIB 'REPO="${VELO_REPO:-${VELO_GATE_REPO:-$VELO_DEFAULT_REPO}}"' 'REPO="${VELO_REPO:-$VELO_DEFAULT_REPO}"'
prove "any value is a repo" t_lib_validation $LIB 'if [[ ! "$REPO" =~ $re ]]; then' 'if false; then'
prove "any value is a repo" t_invalid_everywhere $LIB 'if [[ ! "$REPO" =~ $re ]]; then' 'if false; then'
prove "repo names are case-sensitive" t_lib_case $LIB "lc=\$(tr '[:upper:]' '[:lower:]' <<<\"\$REPO\")" 'lc="$REPO"'
prove "a tool carries on after an invalid value" t_invalid_everywhere bin/velo-merge 'repo_init || exit 1' 'repo_init'
prove "velo-attention carries on after an invalid value" t_invalid_everywhere bin/velo-attention 'source "$HERE/velo-orch-lib.sh" || exit 1' 'source "$HERE/velo-orch-lib.sh"'
# the library: finding the tree
prove "the origin of a tree is not checked" t_worktree_wrong_repo $LIB '[[ "$have" == "$(tr '"'[:upper:]' '[:lower:]'"' <<<"$REPO")" ]] \' 'true \'
prove "a directory need not be a checkout" t_worktree_not_a_checkout $LIB '[[ -e "$1/.git" ]] || { REPO_ERR="$1 is not a git checkout"; return 1; }' ':'
prove "the Velostream tree answers when none is found" t_worktree_missing $LIB '  REPO_ERR="no local worktree of $REPO is checked out on' '  REPO_WT="$HOME/RustroverProjects/velostream"; return 0
  REPO_ERR="no local worktree of $REPO is checked out on'
prove "the Velostream tree answers when none is found" t_worktree_found $LIB '  REPO_ERR="no local worktree of $REPO is checked out on' '  REPO_WT="$HOME/RustroverProjects/velostream"; return 0
  REPO_ERR="no local worktree of $REPO is checked out on'
prove "a worker's worktree is not looked for" t_worktree_found $LIB 'for d in "$base/$REPO_NAME" "$base/$REPO_NAME"-*; do' 'for d in "$base/$REPO_NAME"; do'
prove "the branch of a tree is not compared" t_worktree_wrong_branch $LIB 'if [[ "$cur" == "$1" ]]; then REPO_WT="$d"; return 0; fi' 'if true; then REPO_WT="$d"; return 0; fi'
prove "the branch of a tree is not compared" t_worktree_found $LIB 'if [[ "$cur" == "$1" ]]; then REPO_WT="$d"; return 0; fi' 'if true; then REPO_WT="$d"; return 0; fi'
prove "the refusal names no path" t_worktree_missing $LIB 'Looked in $base/$REPO_NAME and $base/$REPO_NAME-*:' 'Looked nowhere:'
# the scripts: Velostream's way of finding the tree is used for another repo
prove "the caller's worktree list answers for another repo" t_worktree_missing bin/velo-pr-gate 'if [[ $REPO_IS_DEFAULT -eq 1 ]]; then
  WTPATH=$(git worktree list' 'if true; then
  WTPATH=$(git worktree list'
prove "the caller's worktree list answers for another repo" t_worktree_found bin/velo-pr-gate 'if [[ $REPO_IS_DEFAULT -eq 1 ]]; then
  WTPATH=$(git worktree list' 'if true; then
  WTPATH=$(git worktree list'
# the source scans
prove "one hard-coded repo left in velo-gate-sweep" t_literal_once bin/velo-gate-sweep 'ci=$(gh pr checks "$p" --repo "$REPO" 2>"$ci_errf")' 'ci=$(gh pr checks "$p" --repo velostreamai/velostream 2>"$ci_errf")'
prove "one hard-coded repo left in the SessionStart hook" t_literal_once hooks/session-start-inflight.sh 'RUNNING_PRS=$(timeout 10 gh pr list --repo "$REPO" --label gate:running' 'RUNNING_PRS=$(timeout 10 gh pr list --repo velostreamai/velostream --label gate:running'
prove "velo-merge merges in the cwd's repo" t_gh_calls_static bin/velo-merge 'gh pr merge "$PR" --repo "$REPO" --squash --delete-branch' 'gh pr merge "$PR" --squash --delete-branch'
prove "velo-gate-finish comments in the cwd's repo" t_gh_calls_static bin/velo-gate-finish 'gh pr comment "$PR" --repo "$REPO" --body "$body"' 'gh pr comment "$PR" --body "$body"'
prove "velo-dispatch assigns in the cwd's repo" t_gh_calls_static bin/velo-dispatch 'gh issue edit "$ISSUE" --repo "$REPO" --add-assignee "$ASSIGNEE"' 'gh issue edit "$ISSUE" --add-assignee "$ASSIGNEE"'
prove "velo-spec-review reads the cwd's repo" t_gh_calls_static bin/velo-spec-review 'META=$(gh issue view "$ISSUE" --repo "$REPO" --json updatedAt,labels' 'META=$(gh issue view "$ISSUE" --json updatedAt,labels'
prove "velo-spec-review shares its rounds between repos" t_state_paths_static bin/velo-spec-review 'mkdir -p "$STATE/spec${REPO_SUB}/$ISSUE"' 'mkdir -p "$STATE/spec/$ISSUE"'
prove "velo-gate-run shares its gate dir between repos" t_state_paths_static bin/velo-gate-run 'GATE_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'GATE_DIR="$VELO_STATE/gate/$PR"'
prove "velo-merge shares its merge marker between repos" t_state_paths_static bin/velo-merge 'MERGE_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'MERGE_DIR="$VELO_STATE/gate/$PR"'
prove "velo-dispatch resumes from the default repo's record" t_state_paths_static bin/velo-dispatch 'RESULT_FILE=$(repo_scoped "${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl")' 'RESULT_FILE="${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl"'
# bar 2: a gh call that does not name the repo, one script at a time
prove "a repo lookup that names no repo" t_nondefault_calls $LIB 'gh repo view "$REPO" --json defaultBranchRef' 'gh repo view --json defaultBranchRef'
prove "velo-gate-sweep keeps one hard-coded repo" t_nondefault_calls bin/velo-gate-sweep 'ci=$(gh pr checks "$p" --repo "$REPO" 2>"$ci_errf")' 'ci=$(gh pr checks "$p" --repo velostreamai/velostream 2>"$ci_errf")'
prove "velo-gate reads the cwd's PR" t_nondefault_calls bin/velo-gate 'META=$(gh pr view "$PR" --repo "$REPO" --json headRefOid,labels,files,state,title,body' 'META=$(gh pr view "$PR" --json headRefOid,labels,files,state,title,body'
prove "velo-gate-post reads the cwd's PR" t_nondefault_calls bin/velo-gate-post 'HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid' 'HEAD=$(gh pr view "$PR" --json headRefOid --jq .headRefOid'
prove "velo-gate-finish reads the cwd's PR" t_nondefault_calls bin/velo-gate-finish 'n=$(gh pr view "$PR" --repo "$REPO" --json comments' 'n=$(gh pr view "$PR" --json comments'
prove "velo-pr-gate reads the cwd's PR" t_nondefault_calls bin/velo-pr-gate 'WT=$(gh pr view "$PR" --repo "$REPO" --json headRefName' 'WT=$(gh pr view "$PR" --json headRefName'
prove "velo-merge reads the cwd's PR" t_nondefault_calls bin/velo-merge 'gh pr view "$PR" --repo "$REPO" --json "$PR_FIELDS"' 'gh pr view "$PR" --json "$PR_FIELDS"'
prove "velo-status lists the cwd's PRs" t_nondefault_calls bin/velo-status 'PRS_JSON=$(gh pr list --repo "$REPO" --state open --limit 10' 'PRS_JSON=$(gh pr list --state open --limit 10'
prove "velo-status titles the cwd's issues" t_nondefault_calls bin/velo-status '( gh issue view "$N" --repo "$REPO" --json title --jq .title' '( gh issue view "$N" --json title --jq .title'
prove "velo-orchestrd lists the cwd's PRs" t_nondefault_calls bin/velo-orchestrd 'prs=$(gh pr list --repo "$REPO" --label gate:running --state open --json number' 'prs=$(gh pr list --label gate:running --state open --json number'
prove "velo-watch checks the cwd's PRs" t_nondefault_calls bin/velo-watch 'if gh pr checks "$p" --repo "$REPO" 2>/dev/null | grep -qE' 'if gh pr checks "$p" 2>/dev/null | grep -qE'
prove "the SessionStart hook lists the cwd's PRs" t_nondefault_calls hooks/session-start-inflight.sh 'RUNNING_PRS=$(timeout 10 gh pr list --repo "$REPO" --label gate:running' 'RUNNING_PRS=$(timeout 10 gh pr list --label gate:running'
prove "velo-dispatch reads the cwd's issue" t_nondefault_calls bin/velo-dispatch 'META=$(gh issue view "$ISSUE" --repo "$REPO" --json state,title,labels,assignees' 'META=$(gh issue view "$ISSUE" --json state,title,labels,assignees'
# bar 3: state shared between repos, one script at a time
prove "velo-pr-gate shares its gate dir" t_alt_state_layout bin/velo-pr-gate 'GATE_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'GATE_DIR="$VELO_STATE/gate/$PR"'
prove "velo-gate-finish shares its gate dir" t_alt_state_layout bin/velo-gate-finish 'GATE_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'GATE_DIR="$VELO_STATE/gate/$PR"'
prove "velo-gate-post shares its post-once marker" t_alt_state_layout bin/velo-gate-post 'POST_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'POST_DIR="$VELO_STATE/gate/$PR"'
prove "velo-gate-post shares its post-once marker" t_two_repos_one_state_dir bin/velo-gate-post 'POST_DIR="$VELO_STATE/${GATE_SUBDIR}/$PR"' 'POST_DIR="$VELO_STATE/gate/$PR"'
prove "velo-gate-sweep reads the default repo's gated.sha" t_two_repos_one_state_dir bin/velo-gate-sweep 'd="$VELO_STATE/${GATE_SUBDIR}/$p"' 'd="$VELO_STATE/gate/$p"'
prove "velo-native shares its records" t_alt_state_layout bin/velo-native 'NATIVE_DIR="$VELO_STATE/native$REPO_SUB"' 'NATIVE_DIR="$VELO_STATE/native"'
prove "velo-record shares its records" t_alt_state_layout bin/velo-record '/records}$REPO_SUB"' '/records}"'
prove "the orchestrator shares its attention log" t_alt_state_layout bin/velo-orch-lib.sh 'ORCH_DIR="${ORCH_DIR:-$VELO_STATE/orch$REPO_SUB}"' 'ORCH_DIR="${ORCH_DIR:-$VELO_STATE/orch}"'
prove "the orchestrator reads the default repo's records" t_alt_state_layout bin/velo-orch-lib.sh 'RECORDS_DIR="${RECORDS_DIR:-$VELO_STATE/records$REPO_SUB}"' 'RECORDS_DIR="${RECORDS_DIR:-$VELO_STATE/records}"'
prove "velo-dispatch shares its logs" t_alt_state_layout bin/velo-dispatch 'DLOG="$VELO_STATE/dispatch${REPO_SUB}/${ISSUE}/dispatch-' 'DLOG="$VELO_STATE/dispatch/${ISSUE}/dispatch-'
prove "the prune sweeps another repo's whole gate dir" t_prune_scoped bin/velo-pr-gate "-type d ! -name '*__*' -mtime +7" '-type d -mtime +7'
prove "the prune leaves the repo's own old PRs" t_prune_scoped bin/velo-pr-gate '[[ $REPO_IS_DEFAULT -eq 1 ]] || find "$VELO_STATE/$GATE_SUBDIR" -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true' ':'
# bar 5 and the gate's other behaviour
prove "another repo's plan does not say whose it is" t_plan_alt bin/velo-gate '[[ $REPO_IS_DEFAULT -eq 1 ]] || TITLE="$TITLE  [$REPO]"' ':'
prove "check-spec is never planned from an issue for tooling" t_check_spec_triggers bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 0 && "$TOUCHES_ORCH" -gt 0 && -n "$ISSUES" ]]; then' 'if false; then'
prove "check-spec is never planned from an issue for tooling" t_plan_alt bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 0 && "$TOUCHES_ORCH" -gt 0 && -n "$ISSUES" ]]; then' 'if false; then'
prove "a referenced issue is never read" t_check_spec_triggers bin/velo-gate "ISSUES=\$(printf '%s\n%s\n' \"\$ISSUES\" \"\$REFS\" | grep . | sort -un)" "ISSUES=\$(printf '%s\n' \"\$ISSUES\" | grep . | sort -un)"
prove "an unresolvable reference is an error" t_check_spec_triggers bin/velo-gate 'elif [[ "$GH_ERR" == *"Could not resolve"* && " $CLOSING" != *" $n "* ]]; then' 'elif false; then'
prove "an unresolvable closing keyword is ignored" t_check_spec_triggers bin/velo-gate '*"Could not resolve"* && " $CLOSING" != *" $n "* ]]' '*"Could not resolve"* ]]'
prove "references are read for Velostream too" t_check_spec_triggers bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 0 ]]; then
  REFS=$(jq' 'if true; then
  REFS=$(jq'
prove "issue bars plan check-spec for Velostream tooling too" t_check_spec_triggers bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 0 && "$TOUCHES_ORCH" -gt 0 && -n "$ISSUES" ]]; then' 'if [[ "$TOUCHES_ORCH" -gt 0 && -n "$ISSUES" ]]; then'
prove "Velostream's parent-tracked check-spec reaches another repo" t_check_spec_triggers bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 1 && "$TOUCHES_SRC" -gt 0 && "$TITLE" =~ ^\[#[0-9]+\]' 'if [[ "$TOUCHES_SRC" -gt 0 && "$TITLE" =~ ^\[#[0-9]+\]'
prove "Velostream's parent-tracked check-spec is gone" t_check_spec_triggers bin/velo-gate 'if [[ $REPO_IS_DEFAULT -eq 1 && "$TOUCHES_SRC" -gt 0 && "$TITLE" =~ ^\[#[0-9]+\]' 'if false; then # '
prove "the note is missing from the brief" t_brief_note bin/velo-pr-gate '${REPO_NOTE}WORKTREE: $WTPATH (head $HEAD)' 'WORKTREE: $WTPATH (head $HEAD)'
prove "the note is missing from the spec leg's task" t_brief_note bin/velo-pr-gate '--task "${REPO_NOTE}$(cat "$SCOPE")"' '--task "$(cat "$SCOPE")"'
prove "the note is missing from the check-code prompt" t_brief_note bin/velo-pr-gate "printf '%s%s\n\n' \"\$REPO_NOTE\" \"\$body\"" "printf '%s\n\n' \"\$body\""
prove "fail_to_pass reads Velostream's sidecars for another repo" t_ftp_skipped bin/velo-pr-gate 'if [[ $REPO_IS_DEFAULT -eq 1 ]]; then
# >>> velo-fail-to-pass-merge' 'if true; then
# >>> velo-fail-to-pass-merge'

proofs_finish
echo
[[ $FAILED -eq 0 ]] && echo "all repo-env checks passed" || echo "FAILURES"
exit $FAILED

#!/bin/bash
# VELO_REPO (alias VELO_GATE_REPO) for the tools around a WORKER: dispatch, record, status, native, the orchestrator, watch,
# the SessionStart hook, spec-review (velo-agents#17, velostream#2769). The gate tools are in test_repo_env.sh; both share
# tests/repo-env-lib.sh and the same method: run the real scripts in a sandbox that holds a clone of each repo, against a stub
# gh that logs its argv, then break the code and watch the check go red (tests/mutation-lib.sh).
#
# What a dispatch for another repo must do, each proved here:
#   - cut the worker's worktree from THAT repo's default branch (not master), at ~/RustroverProjects/<repo-name>-<issue>
#   - refuse, naming the path it tried, when that tree is missing, is another repo's clone, or GitHub names no default branch
#     - and never touch the Velostream tree
#   - say that the Velostream-only prerequisites are skipped (the discovery index is not built; the worker's task opens with
#     OVERRIDE-DIRECTIVES:), instead of failing on them
#   - keep its state (logs, records, orchestrator events, native workers) apart from Velostream's, issue number for issue number
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-env-lib.sh"

LIB=bin/velo-repo-lib.sh
REC="2026-10-29T00:00:00Z"

rec() {   # <issue> <worktree> [<started>]: velo-record for a finished run -> OUT RC
  x bash "$R/bin/velo-record" "$1" --worktree "$2" --worker local --model m --started "${3:-$REC}" --rc 0 --max-turns 10
}

# ---- dispatch --------------------------------------------------------------------------------------------------------
t_dispatch_dry_alt() {
  local o sha
  drive alt || return 1
  o=$(cat "$SB/out.dispatch-dry")
  eq "$(cat "$SB/rc.dispatch-dry")" 0 "velo-dispatch --dry-run exit status"
  sha=$(git -C "$H/RustroverProjects/velo-agents" rev-parse origin/main | cut -c1-9)
  want "$o" "repo $ALT: tree $H/RustroverProjects/velo-agents, worktree $H/RustroverProjects/velo-agents-$ISS cut from origin/main" "the validation does not say which tree, worktree and base the dispatch uses: $(nonl "$o" 300)"
  want "$o" "repo     : $ALT  (tree $H/RustroverProjects/velo-agents, base origin/main)" "the dry run does not say which repo, tree and base it would use"
  want "$o" "worktree : $H/RustroverProjects/velo-agents-$ISS  (branch fix/$ISS-auto off origin/main $sha)" "the dry run would cut the worktree from something other than $ALT's origin/main ($sha)"
  want "$o" "validating against origin/main ($sha) — pinned for this run" "the brief is validated against something other than $ALT's origin/main ($sha)"
  want "$o" "$ALT is not Velostream: the discovery index is not built" "the dry run does not say the Velostream-only prerequisites are skipped"
  unwant "$o" "origin/master" "a dispatch for $ALT mentions origin/master"
  unwant "$o" "RustroverProjects/velostream" "a dispatch for $ALT names the Velostream tree"
  eq "$(grep -c '^repo view' "$SB/gh.dispatch-dry")" 1 "the default-branch lookups of one dispatch"
  [ "$BAD" -eq 0 ]
}
t_dispatch_real_alt() {   # a whole dispatch, with a worker that does nothing and an indexer that says when it ran
  local wt tree o vt
  sb_new && mk_world && stub_worker || return 1
  fx_base main; fx_issue $ISS_REAL ''
  mk_brief "$FX/brief.md" "$H/RustroverProjects/velo-agents-$ISS_REAL" fix/$ISS_REAL-auto
  wt="$H/RustroverProjects/velo-agents-$ISS_REAL"; tree="$H/RustroverProjects/velo-agents"; vt="$H/RustroverProjects/velostream"
  XE="VELO_REPO=$ALT VELO_WAIT_INTERVAL=0.2"
  x perl -e 'alarm 20; exec @ARGV' bash "$R/bin/velo-dispatch" $ISS_REAL "$FX/brief.md" --wait
  want "$OUT" "#$ISS_REAL exited — outcome: abandoned" "--wait did not see the worker's exit recorded (rc=$RC): $(nonl "$OUT" 400)"
  [ -d "$wt" ] || bad "no worktree at $wt"
  eq "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>&1)" "fix/$ISS_REAL-auto" "the worktree's branch"
  eq "$(git -C "$wt" rev-parse HEAD 2>&1)" "$(git -C "$tree" rev-parse origin/main)" "the worktree is not cut from $ALT's origin/main"
  # Velostream's tree is as it was
  eq "$(git -C "$vt" worktree list | wc -l | tr -d ' ')" 2 "the worktrees of the Velostream tree (itself and velostream-$WIP)"
  [ ! -e "$H/RustroverProjects/velostream-$ISS_REAL" ] || bad "a worktree velostream-$ISS_REAL was made for $ALT's issue"
  eq "$(git -C "$vt" branch --list "fix/$ISS_REAL-auto" | wc -l | tr -d ' ')" 0 "branches named for $ALT's issue in the Velostream tree"
  eq "$(git -C "$vt" status --porcelain | wc -l | tr -d ' ')" 0 "uncommitted changes in the Velostream tree"
  # the worker: started in the worktree, told what does not apply
  eq "$(cat "$SB/worker/cwd" 2>/dev/null)" "$wt" "the worker's --cwd"
  o=$(cat "$SB/worker/task" 2>/dev/null)
  case "$o" in "REPO: $ALT is NOT Velostream."*) ;; *) bad "the worker's task does not open with the repo note: $(nonl "$o" 160)" ;; esac
  want "$o" "OVERRIDE-DIRECTIVES:" "the worker's task carries no OVERRIDE-DIRECTIVES: paragraph"
  want "$o" "SPEC CONTRACT — none: $ALT has no task sidecar for #$ISS_REAL" "the worker's task does not say there is no task sidecar"
  [ ! -e "$SB/zg.log" ] || bad "the discovery index was built for $ALT: $(cat "$SB/zg.log")"
  # gh and state
  gh_names "$GL" "$ALT"
  eq "$(grep -c '^repo view' "$GL")" 1 "the default-branch lookups of one dispatch and the run it supervises"
  [ -s "$S/records/$ALT_SUB/$ISS_REAL.result.jsonl" ] || bad "the supervisor recorded no exit under records/$ALT_SUB"
  [ ! -e "$S/records/$ISS_REAL.result.jsonl" ] || bad "the exit of $ALT's #$ISS_REAL was recorded in Velostream's records"
  eq "$(jq -r .base_sha "$S/records/$ALT_SUB/$ISS_REAL.result.jsonl" 2>&1)" "$(git -C "$tree" rev-parse origin/main | cut -c1-9)" "the recorded base"
  [ "$BAD" -eq 0 ]
}
t_dispatch_refuses() {   # no tree, another repo's tree, no default branch: refused, naming why, before anything is cut
  local alt_tree
  sb_new && mk_tree velostream master || return 1
  alt_tree="$H/RustroverProjects/velo-agents"
  fx_base main; fx_issue $ISS ''; mk_brief "$FX/brief.md" "$alt_tree-$ISS"
  XE="VELO_REPO=$ALT"
  x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
  [ "$RC" -ne 0 ] || bad "a dispatch for $ALT went ahead with no tree of $ALT: $(nonl "$OUT" 200)"
  want "$OUT" "$alt_tree is not a git checkout" "with no tree the refusal does not name the path: $(nonl "$OUT" 300)"
  [ ! -s "$GL" ] || bad "a dispatch with no tree called gh: $(nonl "$(cat "$GL")" 200)"
  git clone -q "$SB/remote/velostreamai/velostream" "$alt_tree" || return 1
  x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
  [ "$RC" -ne 0 ] || bad "a clone of Velostream at $alt_tree was cut from for $ALT: $(nonl "$OUT" 200)"
  want "$OUT" "is a checkout of $DEF, not $ALT" "the refusal does not say whose clone it found: $(nonl "$OUT" 300)"
  rm -rf "$alt_tree"; mk_tree velo-agents main || return 1
  rm -f "$FX/repo-view.json"
  x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
  [ "$RC" -ne 0 ] || bad "a dispatch for $ALT went ahead though GitHub names no default branch for it: $(nonl "$OUT" 200)"
  want "$OUT" "GitHub does not name a default branch for $ALT" "the refusal does not say GitHub named no default branch: $(nonl "$OUT" 300)"
  [ ! -e "$H/RustroverProjects/velostream-$ISS" ] || bad "a refused dispatch left a worktree in the Velostream tree"
  [ "$BAD" -eq 0 ]
}
sidecar() {   # <tree> <verified_against> <anchors json>: .agents/tasks/<ISS>.json in that tree, reviewed against the brief as it is
  local sha; sha=$(shasum -a 256 "$FX/brief.md" | cut -d' ' -f1)
  mkdir -p "$1/.agents/tasks"
  jq -nc --arg s "$sha" --arg v "$2" --argjson a "$3" \
    '{design:"pinned", evidence:"code", verified_against:$v, anchors:$a, reviewed:{by:"t", at:"2099-01-01T00:00:00Z", brief_sha256:$s}}' > "$1/.agents/tasks/$ISS.json"
}
t_dispatch_names_its_branch() {   # what a dispatch says about the base branch is the repo's own: main for velo-agents, master for Velostream
  local tag name b env seed tree
  nomaster() { if [ "$tag" = alt ]; then unwant "$OUT" "master" "$tag: a dispatch for $ALT says master ($1): $(nonl "$OUT" 300)"; fi; }
  for tag in alt def; do
    case $tag in
      alt) name=velo-agents; b=main;   env="VELO_REPO=$ALT" ;;
      def) name=velostream;  b=master; env="" ;;
    esac
    sb_new && mk_tree $name $b || return 1
    XE="$env"   # after sb_new: a new sandbox starts with nothing set for the repo
    tree="$H/RustroverProjects/$name"
    seed=$(git -C "$SB/remote/velostreamai/$name" rev-parse HEAD)
    fx_base $b; fx_issue $ISS ''; mk_brief "$FX/brief.md" "$H/RustroverProjects/$name-$ISS"
    # a stale sidecar: all three ways an anchor goes stale
    sidecar "$tree" "$seed" '[{"file":"nope.txt","symbol":"x","expect":1},{"file":"seed.txt","symbol":"no such symbol","expect":1},{"file":"seed.txt","symbol":"seed","expect":2}]'
    x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
    want "$OUT" "nope.txt: FILE MISSING at origin/$b" "$tag: the stale-anchor report does not name origin/$b for a missing file: $(nonl "$OUT" 300)"
    want "$OUT" "seed.txt: symbol 'no such symbol' NOT FOUND at origin/$b" "$tag: ...for a symbol that is not there"
    want "$OUT" "seed.txt: 'seed' found 1x at origin/$b, spec says 2x" "$tag: ...for a count that differs"
    want "$OUT" "Re-verify against $b, update" "$tag: the advice to re-verify does not name $b"
    nomaster "stale anchors"
    # a sidecar that holds, as of the seed commit, and a second commit on the base since
    sidecar "$tree" "$seed" "[{\"file\":\"seed.txt\",\"symbol\":\"seed $name\",\"expect\":1}]"
    git -C "$SB/remote/velostreamai/$name" $GITID commit -q --allow-empty -m second || return 1
    x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
    want "$OUT" "anchors verified against origin/$b" "$tag: the verified line does not name origin/$b: $(nonl "$OUT" 300)"
    want "$OUT" "spec verified 1 commits behind $b (anchors still check out)" "$tag: the behind warning does not name $b"
    nomaster "a spec one commit behind"
    sidecar "$tree" "$(git -C "$SB/remote/velostreamai/$name" rev-parse HEAD)" "[{\"file\":\"seed.txt\",\"symbol\":\"seed $name\",\"expect\":1}]"
    x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
    want "$OUT" "spec verified at current $b" "$tag: the current-spec line does not name $b: $(nonl "$OUT" 300)"
    nomaster "a current spec"
    rm -rf "$tree/.agents"
    # a triage-needed issue is refused, naming the branch its claims were checked against
    jq -c '.labels += [{name:"triage-needed"}]' "$FX/issue-$ISS.json" > "$FX/issue-$ISS.tmp" && mv "$FX/issue-$ISS.tmp" "$FX/issue-$ISS.json"
    x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md" --dry-run
    want "$OUT" "its claims may not match $b." "$tag: the triage-needed refusal does not name $b: $(nonl "$OUT" 300)"
    want "$OUT" "against current $b, then remove the label" "$tag: ...nor its advice"
    nomaster "triage-needed"
    fx_issue $ISS ''
    # a branch that already holds commits the base does not
    git -C "$tree" branch fix/$ISS-auto feat/gate || return 1
    x bash "$R/bin/velo-dispatch" $ISS "$FX/brief.md"
    want "$OUT" "already exists with 1 commit(s) not on $b." "$tag: the existing-branch refusal does not name $b: $(nonl "$OUT" 300)"
    nomaster "an existing branch"
  done
  [ "$BAD" -eq 0 ]
}

t_dispatch_history_scoped() {   # a failed run of #78 in Velostream's records, current or legacy, is not a failed run of velo-agents' #78
  local row='{"worker":"velo-local","outcome":"failed","work":{"commits":0},"runner":{"turns":0}}' refused="last ran on velo-local and ended 'failed'"
  sb_new && mk_world || return 1
  fx_base main; fx_issue $ISS ''
  mk_brief "$FX/brief-alt.md" "$H/RustroverProjects/velo-agents-$ISS"; mk_brief "$FX/brief-def.md" "$H/RustroverProjects/velostream-$ISS"
  alt() { XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-dispatch" $ISS "$FX/brief-alt.md" --dry-run; }
  def() { XE=""; x bash "$R/bin/velo-dispatch" $ISS "$FX/brief-def.md" --dry-run; }
  # Velostream's record: refuses Velostream's dispatch (the guard is live), says nothing to velo-agents'
  mkdir -p "$S/records"; printf '%s\n' "$row" > "$S/records/$ISS.result.jsonl"
  def; [ "$RC" -ne 0 ] || bad "Velostream's own failed run did not refuse its re-dispatch: $(nonl "$OUT" 300)"
  want "$OUT" "$refused" "Velostream's re-dispatch is refused for another reason: $(nonl "$OUT" 300)"
  alt; eq "$RC" 0 "a dry run for $ALT after Velostream's failed run of the same number"
  unwant "$OUT" "prior attempts" "$ALT's dispatch read Velostream's records: $(nonl "$OUT" 300)"
  # the legacy locations are Velostream's too
  rm -f "$S/records/$ISS.result.jsonl"; mkdir -p "$H/.agents/tasks"; printf '%s\n' "$row" > "$H/.agents/tasks/$ISS.result.jsonl"
  def; want "$OUT" "reading LEGACY record location" "Velostream's dispatch no longer reads a legacy record: $(nonl "$OUT" 300)"
  alt; eq "$RC" 0 "a dry run for $ALT with a legacy Velostream record of the same number"
  unwant "$OUT" "LEGACY" "$ALT's dispatch read a legacy Velostream record: $(nonl "$OUT" 300)"
  unwant "$OUT" "prior attempts" "$ALT's dispatch took a legacy Velostream record for its own history: $(nonl "$OUT" 300)"
  # velo-agents' own record: refuses velo-agents' dispatch (naming it in the advice), says nothing to Velostream's
  rm -f "$H/.agents/tasks/$ISS.result.jsonl"; mkdir -p "$S/records/$ALT_SUB"; printf '%s\n' "$row" > "$S/records/$ALT_SUB/$ISS.result.jsonl"
  alt; [ "$RC" -ne 0 ] || bad "$ALT's own failed run did not refuse its re-dispatch: $(nonl "$OUT" 300)"
  want "$OUT" "$refused" "$ALT's re-dispatch is refused for another reason: $(nonl "$OUT" 300)"
  want "$OUT" "gh issue edit $ISS --repo $ALT --remove-label" "the advice does not name $ALT: $(nonl "$OUT" 300)"
  def; eq "$RC" 0 "a dry run for Velostream after $ALT's failed run of the same number"
  unwant "$OUT" "prior attempts" "Velostream's dispatch read $ALT's records: $(nonl "$OUT" 300)"
  [ "$BAD" -eq 0 ]
}

# ---- record, status, native ------------------------------------------------------------------------------------------
t_record_alt() {
  local f
  drive alt || return 1
  f="$S/records/$ALT_SUB/$WIP.result.jsonl"
  want "$(cat "$SB/out.record")" "commits=1/1" "the run's commit is not counted against $ALT's origin/main: $(nonl "$(cat "$SB/out.record")" 200)"
  [ -s "$f" ] || { bad "no record at $f"; return 1; }
  eq "$(jq -r .base_sha "$f")" "$(git -C "$H/RustroverProjects/velo-agents" rev-parse --short origin/main)" "the recorded base sha is not $ALT's origin/main"
  eq "$(jq -r .branch "$f")" "fix/$WIP-alt" "the recorded branch"
  eq "$(jq -r .work.commits "$f")" 1 "the recorded commits"
  # GitHub names no default branch: said, loudly, and nothing recorded (a record against the wrong base is a wrong number)
  sb_new && mk_world || return 1
  XE="VELO_REPO=$ALT"; rec $WIP "$H/RustroverProjects/velo-agents-$WIP"
  eq "$RC" 0 "velo-record is observational and exits 0"
  want "$OUT" "velo-record: GitHub does not name a default branch for $ALT" "velo-record did not say why it recorded nothing: $(nonl "$OUT" 200)"
  want "$OUT" "nothing recorded" "velo-record did not say it recorded nothing"
  [ ! -e "$S/records" ] || bad "velo-record wrote a record against a base it could not determine: $(ls -R "$S/records" | tr '\n' ' ')"
  [ "$BAD" -eq 0 ]
}
t_status_alt() {
  local a d
  drive alt || return 1; a=$(cat "$SB/out.status")
  drive def || return 1; d=$(cat "$SB/out.status")
  want "$a" "fix/$WIP-alt" "the status of $ALT lists no worker of $ALT: $(nonl "$a" 200)"
  want "$a" "1!" "the status of $ALT does not count the worker's commit against its origin/main"
  unwant "$a" "fix/$WIP-def" "the status of $ALT lists Velostream's worker"
  want "$d" "fix/$WIP-def" "the status of Velostream lists no worker of Velostream: $(nonl "$d" 200)"
  unwant "$d" "fix/$WIP-alt" "the status of Velostream lists $ALT's worker"
  # GitHub names no default branch: refused, loudly
  sb_new && mk_world || return 1
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-status"
  [ "$RC" -ne 0 ] || bad "velo-status carried on with no default branch for $ALT"
  want "$OUT" "velo-status: GitHub does not name a default branch for $ALT" "velo-status did not say why it stopped: $(nonl "$OUT" 200)"
  [ "$BAD" -eq 0 ]
}
t_workers_two_repos_one_state_dir() {   # worker 77 and native worker 5 exist in both repos, in one state dir
  local n
  sb_new && mk_world || return 1
  XE=""; rec $WIP "$H/RustroverProjects/velostream-$WIP" 2026-10-29T00:00:00Z
  fx_base main; XE="VELO_REPO=$ALT"; rec $WIP "$H/RustroverProjects/velo-agents-$WIP" 2026-10-29T01:00:00Z
  for n in "$S/records/$WIP.result.jsonl" "$S/records/$ALT_SUB/$WIP.result.jsonl"; do
    eq "$(wc -l < "$n" 2>/dev/null | tr -d ' ')" 1 "records in ${n#"$S"/}"
  done
  eq "$(jq -r .branch "$S/records/$WIP.result.jsonl" 2>&1)" "fix/$WIP-def" "Velostream's recorded branch"
  eq "$(jq -r .branch "$S/records/$ALT_SUB/$WIP.result.jsonl" 2>&1)" "fix/$WIP-alt" "$ALT's recorded branch"
  XE=""; x bash "$R/bin/velo-native" start 5 fix/5-def /d --model haiku
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-native" start 5 fix/5-alt /a --model haiku
  eq "$RC" 0 "starting $ALT's native worker 5 after Velostream's (exit status): $OUT"
  XE=""; x bash "$R/bin/velo-native" rows
  want "$OUT" "fix/5-def" "Velostream's native worker 5 is gone: $(nonl "$OUT" 200)"
  unwant "$OUT" "fix/5-alt" "Velostream's native workers list $ALT's"
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-native" rows
  want "$OUT" "fix/5-alt" "$ALT's native worker 5 is gone: $(nonl "$OUT" 200)"
  unwant "$OUT" "fix/5-def" "$ALT's native workers list Velostream's"
  [ "$BAD" -eq 0 ]
}
t_spec_review_tree() {
  drive alt || return 1
  eq "$(cat "$SB/rc.spec-review")" 1 "velo-spec-review with no sidecar (exit status)"
  want "$(cat "$SB/out.spec-review")" "no task spec: $H/RustroverProjects/velo-agents/.agents/tasks/$ISS.json" "the spec is looked for somewhere other than $ALT's tree: $(nonl "$(cat "$SB/out.spec-review")" 200)"
  [ "$BAD" -eq 0 ]
}

# ---- the orchestrator ------------------------------------------------------------------------------------------------
t_orchestrd_isolation() {   # worker 77 in each repo, a STOP in each worktree's agent.log: each tick and attention list sees only its own
  local def_stop=2026-10-29T03:00:00 alt_stop=2026-10-29T04:00:00 def_run=2026-10-29T00:00:00Z alt_run=2026-10-29T01:00:00Z
  sb_new && mk_world || return 1
  fx_base master; printf '[]\n' > "$FX/pr-list-running.json"
  printf '%sZ STOP: def tree\n' "$def_stop" > "$H/RustroverProjects/velostream-$WIP/agent.log"
  printf '%sZ STOP: alt tree\n' "$alt_stop" > "$H/RustroverProjects/velo-agents-$WIP/agent.log"
  XE=""; rec $WIP "$H/RustroverProjects/velostream-$WIP" $def_run
  # velo-agents ticks first: its own worktree's STOP, and nothing of Velostream's (its finished worker, its STOP)
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-orchestrd" tick; x bash "$R/bin/velo-attention" list
  want "$OUT" "1 unhandled attention event(s)" "$ALT's first tick: $(nonl "$OUT" 300)"
  want "$OUT" "stop:$WIP:$alt_stop" "$ALT's tick missed the STOP in its own worktree: $(nonl "$OUT" 300)"
  want "$OUT" "velo-agents-$WIP recorded a STOP" "$ALT's STOP does not name its own worktree: $(nonl "$OUT" 300)"
  unwant "$OUT" "worker-finished" "$ALT's tick saw Velostream's finished worker $WIP: $(nonl "$OUT" 300)"
  unwant "$OUT" "velostream-$WIP" "$ALT's tick looked in a Velostream worktree: $(nonl "$OUT" 300)"
  # Velostream's tick: its finished worker and its STOP, none of velo-agents'
  XE=""; x bash "$R/bin/velo-orchestrd" tick; x bash "$R/bin/velo-attention" list
  want "$OUT" "2 unhandled attention event(s)" "Velostream's tick: $(nonl "$OUT" 300)"
  want "$OUT" "worker-finished:$WIP:$def_run" "Velostream's tick missed its finished worker $WIP: $(nonl "$OUT" 300)"
  want "$OUT" "stop:$WIP:$def_stop" "Velostream's tick missed the STOP in its own worktree: $(nonl "$OUT" 300)"
  unwant "$OUT" "$alt_stop" "Velostream's attention list holds $ALT's STOP: $(nonl "$OUT" 300)"
  unwant "$OUT" "velo-agents-$WIP" "Velostream's tick looked in a $ALT worktree: $(nonl "$OUT" 300)"
  # velo-agents' worker 77 finishes after Velostream's did: its record is its own, not already read as Velostream's
  fx_base main; XE="VELO_REPO=$ALT"; rec $WIP "$H/RustroverProjects/velo-agents-$WIP" $alt_run
  x bash "$R/bin/velo-orchestrd" tick; x bash "$R/bin/velo-attention" list
  want "$OUT" "2 unhandled attention event(s)" "$ALT's second tick: $(nonl "$OUT" 300)"
  want "$OUT" "worker-finished:$WIP:$alt_run" "$ALT's tick missed its finished worker $WIP (read as already seen?): $(nonl "$OUT" 300)"
  want "$OUT" "stop:$WIP:$alt_stop" "$ALT lost its STOP"
  unwant "$OUT" "$def_run" "$ALT's attention list holds Velostream's finished worker: $(nonl "$OUT" 300)"
  unwant "$OUT" "$def_stop" "$ALT's attention list holds Velostream's STOP: $(nonl "$OUT" 300)"
  XE=""; x bash "$R/bin/velo-attention" list
  want "$OUT" "2 unhandled attention event(s)" "Velostream's attention list changed when $ALT's worker finished: $(nonl "$OUT" 300)"
  unwant "$OUT" "$alt_run" "Velostream's attention list holds $ALT's finished worker: $(nonl "$OUT" 300)"
  [ "$BAD" -eq 0 ]
}
t_orchestrd_launchd_default_only() {   # the launchd agent is Velostream's: another repo's install/uninstall/status are refused
  local c
  sb_new || return 1
  fx_base main; printf '[]\n' > "$FX/pr-list-running.json"
  XE="VELO_REPO=$ALT"
  for c in install uninstall status; do
    x bash "$R/bin/velo-orchestrd" $c
    [ "$RC" -ne 0 ] || bad "velo-orchestrd $c ran for $ALT"
    want "$OUT" "$c manages Velostream's launchd agent, not $ALT's" "velo-orchestrd $c for $ALT does not say whose agent it is: $(nonl "$OUT" 200)"
  done
  [ ! -e "$SB/launchctl.log" ] || bad "launchctl was called for $ALT: $(cat "$SB/launchctl.log")"
  [ ! -e "$H/Library/LaunchAgents" ] || bad "a launchd plist was written for $ALT"
  # the guard is for other repos only
  XE=""; x bash "$R/bin/velo-orchestrd" status
  [ -s "$SB/launchctl.log" ] || bad "velo-orchestrd status for Velostream no longer asks launchd (exit $RC): $(nonl "$OUT" 200)"
  [ "$BAD" -eq 0 ]
}

# ---- watch and the SessionStart hook ---------------------------------------------------------------------------------
t_gates_scoped() {   # reviewers are found by the gate dir their command line names: 31 is Velostream's, 41 is velo-agents'
  trap kill_decoys EXIT
  sb_new && mk_world || return 1
  fx_base main; printf '[]\n' > "$FX/pr-list-running.json"
  printf 'Build\tpending\t1m\thttps://x\n' > "$FX/pr-checks.txt"; printf '8\n' > "$FX/pr-checks.rc"
  decoy "codex review - $S/gate/31/review.log" || return 1
  decoy "codex review - $S/gate/$ALT_SUB/41/review.log" || return 1
  XE=""; x bash "$R/hooks/session-start-inflight.sh"
  want "$OUT" "PR #31 - review still running" "Velostream's hook does not list its reviewer of PR 31: $(nonl "$OUT" 200)"
  unwant "$OUT" "PR #41" "Velostream's hook lists $ALT's reviewer"
  XE="VELO_REPO=$ALT"; x bash "$R/hooks/session-start-inflight.sh"
  want "$OUT" "PR #41 - review still running" "$ALT's hook does not list its reviewer of PR 41: $(nonl "$OUT" 200)"
  unwant "$OUT" "PR #31" "$ALT's hook lists Velostream's reviewer"
  want "$OUT" "VELO_REPO=$ALT ~/.agents/bin/velo-watch --pr 41" "the hook's watch command would watch Velostream's PR 41"
  XE=""; x bash "$R/bin/velo-watch" --pr 31 --interval 1 --max 1
  want "$OUT" "31:review" "Velostream's watch does not see its reviewer of PR 31: $(nonl "$OUT" 200)"
  unwant "$OUT" "41:review" "Velostream's watch sees $ALT's reviewer"
  XE="VELO_REPO=$ALT"; x bash "$R/bin/velo-watch" --pr 41 --interval 1 --max 1
  want "$OUT" "41:review" "$ALT's watch does not see its reviewer of PR 41: $(nonl "$OUT" 200)"
  unwant "$OUT" "31:review" "$ALT's watch sees Velostream's reviewer"
  kill_decoys
  [ "$BAD" -eq 0 ]
}
t_watch_workers_scoped() {   # a worker of Velostream finishing does not wake a watch on velo-agents, and its own finishing does
  local i
  trap kill_decoys EXIT
  sb_new || return 1
  fx_base main; printf '[]\n' > "$FX/pr-list-running.json"
  decoy "codex review - $S/gate/$ALT_SUB/41/review.log" || return 1   # a running gate keeps the watch armed
  XE="VELO_REPO=$ALT"; xbg "$SB/watch.out" bash "$R/bin/velo-watch" --pr 41 --interval 1 --max 12
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q armed "$SB/watch.out" 2>/dev/null && break; sleep 0.25; done
  grep -q armed "$SB/watch.out" 2>/dev/null || { bad "the watch never armed: $(cat "$SB/watch.out" 2>&1)"; return 1; }
  mkdir -p "$S/records"; echo '{"issue":78}' > "$S/records/78.result.jsonl"   # Velostream's worker 78 finishes
  sleep 2.5
  kill -0 "$BGPID" 2>/dev/null || bad "the watch on $ALT ended when Velostream's worker 78 finished: $(nonl "$(cat "$SB/watch.out")" 300)"
  unwant "$(cat "$SB/watch.out")" "worker finished" "the watch on $ALT reported Velostream's worker"
  mkdir -p "$S/records/$ALT_SUB"; echo '{"issue":79}' > "$S/records/$ALT_SUB/79.result.jsonl"   # its own worker 79 finishes
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "$BGPID" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$BGPID" 2>/dev/null && bad "the watch on $ALT did not end when its own worker 79 finished"
  want "$(cat "$SB/watch.out")" "worker finished: 79" "the watch on $ALT did not report its own worker: $(nonl "$(cat "$SB/watch.out")" 300)"
  kill_decoys
  [ "$BAD" -eq 0 ]
}

# ---- the checks ------------------------------------------------------------------------------------------------------
echo "== dispatch"
check "a dry run for another repo: its tree, its default branch, its notes" t_dispatch_dry_alt
check "a whole dispatch for another repo: worktree, worker, task, state" t_dispatch_real_alt
check "no tree, another repo's tree, no default branch: refused, by path" t_dispatch_refuses
check "every message that names the base branch names the repo's own" t_dispatch_names_its_branch
check "the re-dispatch guard reads the repo's own history, never Velostream's" t_dispatch_history_scoped
echo "== record, status, native, spec-review"
check "record counts against the repo's default branch, or says why not" t_record_alt
check "status lists the repo's own workers" t_status_alt
check "worker 77 and native worker 5 of two repos share no file" t_workers_two_repos_one_state_dir
check "spec-review reads the repo's own tree" t_spec_review_tree
echo "== the orchestrator"
check "each repo's tick and attention list see only its own workers" t_orchestrd_isolation
check "the launchd agent is Velostream's alone" t_orchestrd_launchd_default_only
echo "== watch and the SessionStart hook"
check "reviewers are found by the repo's gate dir" t_gates_scoped
check "a watch wakes for its own repo's workers only" t_watch_workers_scoped

# ---- the mutants -----------------------------------------------------------------------------------------------------
echo "== mutation proofs"
prove "dispatch cuts from the Velostream tree" t_dispatch_dry_alt bin/velo-dispatch 'ROOT="$HOME/RustroverProjects/${REPO_NAME}"' 'ROOT="$HOME/RustroverProjects/velostream"'
prove "dispatch cuts from the Velostream tree" t_dispatch_real_alt bin/velo-dispatch 'ROOT="$HOME/RustroverProjects/${REPO_NAME}"' 'ROOT="$HOME/RustroverProjects/velostream"'
prove "the worktree to cut is named velostream-<n>" t_dispatch_dry_alt bin/velo-dispatch 'WT="$WORKTREE_BASE/${REPO_NAME}-$ISSUE"

# (fetch already done' 'WT="$WORKTREE_BASE/velostream-$ISSUE"

# (fetch already done'
prove "the worktree to cut is named velostream-<n>" t_dispatch_real_alt bin/velo-dispatch 'WT="$WORKTREE_BASE/${REPO_NAME}-$ISSUE"

# (fetch already done' 'WT="$WORKTREE_BASE/velostream-$ISSUE"

# (fetch already done'
prove "the worktree the brief is checked against is named velostream-<n>" t_dispatch_dry_alt bin/velo-dispatch 'WT="$WORKTREE_BASE/${REPO_NAME}-$ISSUE"

# brief_prose' 'WT="$WORKTREE_BASE/velostream-$ISSUE"

# brief_prose'
prove "the repo and tree are not announced" t_dispatch_dry_alt bin/velo-dispatch 'if [[ $REPO_IS_DEFAULT -eq 0 ]]; then
  ok "repo $REPO: tree $ROOT' 'if false; then
  ok "repo $REPO: tree $ROOT'
prove "the base is origin/master" t_dispatch_dry_alt $LIB 'WT_BASE_REF="origin/$BASE_BRANCH"' 'WT_BASE_REF="origin/master"'
prove "the base is origin/master" t_dispatch_real_alt $LIB 'WT_BASE_REF="origin/$BASE_BRANCH"' 'WT_BASE_REF="origin/master"'
prove "the base is origin/master" t_record_alt $LIB 'WT_BASE_REF="origin/$BASE_BRANCH"' 'WT_BASE_REF="origin/master"'
prove "the base is origin/master" t_status_alt $LIB 'WT_BASE_REF="origin/$BASE_BRANCH"' 'WT_BASE_REF="origin/master"'
prove "the supervisor asks GitHub for the base again" t_dispatch_real_alt bin/velo-dispatch '[[ $REPO_IS_DEFAULT -eq 1 ]] || export WT_BASE_REF' ':'
prove "the worker's task has no repo note" t_dispatch_real_alt bin/velo-dispatch 'TASK="${REPO_NOTE}${TASK}"' 'TASK="${TASK}"'
prove "the discovery index is built for another repo" t_dispatch_real_alt bin/velo-dispatch 'if [[ "$INDEX_SAFE" == "1" ]] && [[ $REPO_IS_DEFAULT -eq 1 ]] \' 'if [[ "$INDEX_SAFE" == "1" ]] \'
prove "--wait waits on the default repo's record" t_dispatch_real_alt bin/velo-dispatch 'WAIT_RECORD_FILE=$(repo_scoped "${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl")' 'WAIT_RECORD_FILE="${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl"'
prove "records are not scoped to the repo" t_dispatch_real_alt $LIB "repo_scoped() { printf '%s' \"\${1%/*}\$REPO_SUB/\${1##*/}\"; }" "repo_scoped() { printf '%s' \"\$1\"; }"
prove "a tree that is no checkout of the repo is cut from anyway" t_dispatch_refuses bin/velo-dispatch 'repo_checkout "$ROOT" || die "$REPO_ERR' 'repo_checkout "$ROOT" || : "$REPO_ERR'
prove "the origin of the tree is not checked" t_dispatch_refuses $LIB '[[ "$have" == "$(tr '"'[:upper:]' '[:lower:]'"' <<<"$REPO")" ]] \' 'true \'
prove "a missing default branch is carried on from" t_dispatch_refuses bin/velo-dispatch 'repo_base_branch || die "$REPO_ERR"' 'repo_base_branch || :'
prove "a missing default branch is accepted" t_dispatch_refuses $LIB 'if [[ -z "$BASE_BRANCH" || "$BASE_BRANCH" == null ]]; then' 'if false; then'
prove "a missing default branch is accepted" t_record_alt $LIB 'if [[ -z "$BASE_BRANCH" || "$BASE_BRANCH" == null ]]; then' 'if false; then'
prove "the guard reads Velostream's record for another repo" t_dispatch_history_scoped bin/velo-dispatch 'RESULT_FILE=$(repo_scoped "${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl")' 'RESULT_FILE="${VELO_STATE:-$HOME/.agents/state}/records/${ISSUE}.result.jsonl"'
prove "the guard reads Velostream's legacy record for another repo" t_dispatch_history_scoped bin/velo-dispatch 'if [[ ! -f "$RESULT_FILE" && $REPO_IS_DEFAULT -eq 1 ]]; then' 'if [[ ! -f "$RESULT_FILE" ]]; then'
prove "a missing file is reported against origin/master" t_dispatch_names_its_branch bin/velo-dispatch 'bad.append(f"{f}: FILE MISSING at {ref}"); continue' 'bad.append(f"{f}: FILE MISSING at origin/master"); continue'
prove "a missing symbol is reported against origin/master" t_dispatch_names_its_branch bin/velo-dispatch "bad.append(f\"{f}: symbol '{sym}' NOT FOUND at {ref}\")" "bad.append(f\"{f}: symbol '{sym}' NOT FOUND at origin/master\")"
prove "a wrong count is reported against origin/master" t_dispatch_names_its_branch bin/velo-dispatch "bad.append(f\"{f}: '{sym}' found {n}x at {ref}, spec says {exp}x\")" "bad.append(f\"{f}: '{sym}' found {n}x at origin/master, spec says {exp}x\")"
prove "the anchor check is told origin/master" t_dispatch_names_its_branch bin/velo-dispatch '"$BASE_SHA" "${WT_BASE_REF:-origin/master}" <<'"'"'PYA'"'"'' '"$BASE_SHA" "origin/master" <<'"'"'PYA'"'"''
prove "the verified line says origin/master" t_dispatch_names_its_branch bin/velo-dispatch 'ok "anchors verified against ${WT_BASE_REF:-origin/master}"' 'ok "anchors verified against origin/master"'
prove "the advice to re-verify says master" t_dispatch_names_its_branch bin/velo-dispatch 'Re-verify against $BASE_BRANCH, update' 'Re-verify against master, update'
prove "a current spec is verified at master" t_dispatch_names_its_branch bin/velo-dispatch 'ok "spec verified at current $BASE_BRANCH"' 'ok "spec verified at current master"'
prove "a spec behind is behind master" t_dispatch_names_its_branch bin/velo-dispatch 'commits behind $BASE_BRANCH (anchors still check out)' 'commits behind master (anchors still check out)'
prove "triage-needed claims may not match master" t_dispatch_names_its_branch bin/velo-dispatch 'its claims may not match $BASE_BRANCH.' 'its claims may not match master.'
prove "triage-needed advice says master" t_dispatch_names_its_branch bin/velo-dispatch 'against current $BASE_BRANCH, then remove the label.' 'against current master, then remove the label.'
prove "an existing branch is not on master" t_dispatch_names_its_branch bin/velo-dispatch 'commit(s) not on $BASE_BRANCH.' 'commit(s) not on master.'
prove "velo-record counts against the Velostream tree" t_record_alt bin/velo-record 'ROOT="${VELO_RECORD_ROOT:-$HOME/RustroverProjects/${REPO_NAME}}"' 'ROOT="${VELO_RECORD_ROOT:-$HOME/RustroverProjects/velostream}"'
prove "velo-record records against a base it could not find" t_record_alt bin/velo-record 'repo_base_branch || { echo "velo-record: $REPO_ERR — nothing recorded" >&2; exit 0; }' 'repo_base_branch || :'
prove "velo-record shares its records" t_workers_two_repos_one_state_dir bin/velo-record '/records}$REPO_SUB"' '/records}"'
prove "velo-native shares its records" t_workers_two_repos_one_state_dir bin/velo-native 'NATIVE_DIR="$VELO_STATE/native$REPO_SUB"' 'NATIVE_DIR="$VELO_STATE/native"'
prove "velo-status lists Velostream's worktrees in its table" t_status_alt bin/velo-status '/${REPO_NAME}-*; do
  [[ -d "$WT/.git" || -f "$WT/.git" ]] || continue
  ISSUE=' '/velostream-*; do
  [[ -d "$WT/.git" || -f "$WT/.git" ]] || continue
  ISSUE='
prove "velo-status carries on with no default branch" t_status_alt bin/velo-status 'repo_base_branch || { echo "velo-status: $REPO_ERR" >&2; exit 1; }' 'repo_base_branch || :'
prove "velo-spec-review reads the Velostream tree" t_spec_review_tree bin/velo-spec-review 'ROOT="$HOME/RustroverProjects/${REPO_NAME}"' 'ROOT="$HOME/RustroverProjects/velostream"'
prove "the orchestrator watches Velostream's worktrees" t_orchestrd_isolation bin/velo-orchestrd 'WORKTREE_GLOB="${VELO_ORCH_WORKTREE_GLOB:-$HOME/RustroverProjects/$REPO_NAME-*}"' 'WORKTREE_GLOB="${VELO_ORCH_WORKTREE_GLOB:-$HOME/RustroverProjects/velostream-*}"'
prove "the orchestrator shares its attention log" t_orchestrd_isolation bin/velo-orch-lib.sh 'ORCH_DIR="${ORCH_DIR:-$VELO_STATE/orch$REPO_SUB}"' 'ORCH_DIR="${ORCH_DIR:-$VELO_STATE/orch}"'
prove "the orchestrator reads Velostream's records" t_orchestrd_isolation bin/velo-orch-lib.sh 'RECORDS_DIR="${RECORDS_DIR:-$VELO_STATE/records$REPO_SUB}"' 'RECORDS_DIR="${RECORDS_DIR:-$VELO_STATE/records}"'
prove "launchd is managed for another repo" t_orchestrd_launchd_default_only bin/velo-orchestrd 'case "$cmd" in install|uninstall|status)' 'case "$cmd" in __never__)'
prove "reviewers are looked for under the default's gate dir" t_gates_scoped $LIB 'GATE_PATH_RE="state/$GATE_SUBDIR/[0-9]+/"' 'GATE_PATH_RE="state/gate/[0-9]+/"'
prove "the hook reads the PR number from the default's gate dir" t_gates_scoped hooks/session-start-inflight.sh 'state/$GATE_SUBDIR/([0-9]+)/([a-z-]+)[.-].*%  PR #\2 - \3 still running (pid \1)%' 'state/gate/([0-9]+)/([a-z-]+)[.-].*%  PR #\2 - \3 still running (pid \1)%'
prove "the watch reads the PR number from the default's gate dir" t_gates_scoped bin/velo-watch 'state/$GATE_SUBDIR/([0-9]+)/([a-z-]+)[.-].*#\2:\3#' 'state/gate/([0-9]+)/([a-z-]+)[.-].*#\2:\3#'
prove "the watch counts Velostream's finished workers" t_watch_workers_scoped bin/velo-watch '"$HOME"/.agents/state/records$REPO_SUB/*.result.jsonl' '"$HOME"/.agents/state/records/*.result.jsonl'

proofs_finish
echo
[[ $FAILED -eq 0 ]] && echo "all repo-env worker checks passed" || echo "FAILURES"
exit $FAILED

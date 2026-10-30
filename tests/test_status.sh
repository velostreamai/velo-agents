#!/bin/bash
# velo-status — the operator's primary view, and until now untested.
#
# It had no coverage at all, which is how a rename shipped straight through it:
# the state migration moved worker logs from /tmp/<worker>-<issue>.log to
# $VELO_STATE/dispatch/<issue>/<worker>-<UTC>.log, and the worker-name rule
# still stripped from "-<issue>" onward. Nothing matched, so the WHOLE filename
# became the worker name and the table showed `codex-20260` for a codex run.
#
# The failure was cosmetic-looking and load-bearing: velo-status is how you tell
# which model ran, and a garbled name is indistinguishable from a worker you do
# not recognise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# Exercise the derivation the way the script does, against the REAL filename
# shapes it now sees. Kept in lockstep with velo-status by the wiring assertion
# at the end — a copy that drifts is worse than no test.
derive() {  # $1 = log basename
  local BN; BN=$(basename "$1" .log)
  sed -E 's/-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$//' <<<"$BN"
}

check() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: got '$2', want '$3'"; FAILURES=$((FAILURES+1)); fi
}

echo "velo-status worker naming"

check "codex run"           "$(derive codex-20260908T035158Z.log)"       "codex"
check "deepseek run"        "$(derive deepseek-20260908T035158Z.log)"    "deepseek"
check "glm run"             "$(derive glm-20260908T035158Z.log)"         "glm"
check "haiku run"           "$(derive haiku-20260908T035158Z.log)"       "haiku"
# The one a naive "cut at the first hyphen" gets wrong.
check "velo-local keeps its hyphen" "$(derive velo-local-20260908T035158Z.log)" "velo-local"

# The pid disambiguator velo-dispatch appends so two same-second dispatches of one
# issue do not share a log identity. `${BN%-*}` rendered these as
# `codex-20260913T065540Z`, which is the exact regression the anchored pattern
# exists to prevent — and no fixture here had a pid suffix, so the old helper
# passed while being wrong about every real log written since.
check "codex run with pid suffix"   "$(derive codex-20260913T065540Z-84398.log)"      "codex"
check "velo-local with pid suffix"  "$(derive velo-local-20260913T065540Z-84398.log)" "velo-local"
# Fails VISIBLY rather than truncating at the wrong place: a name that does not
# end in -<UTC>[-<pid>] is left whole, so the table shows something obviously odd
# instead of something plausibly wrong.
check "unrecognised shape is left whole" "$(derive weird-name.log)"                   "weird-name"

# Wiring: the rule under test must still be the rule in the script. Without this
# the helper above can stay correct while velo-status drifts back.
#
# Matched on the sed PROGRAM, not on a whole source line: the previous version
# grepped for a one-liner (`BN=...; WORKER="${BN%-*}"`) and broke the moment that
# statement was split across two lines, reporting "testing a copy" while the copy
# was in fact in lockstep. A wiring check that fails on formatting trains people
# to ignore it, which costs more than the drift it guards against.
if grep -qF 's/-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$//' "$BIN/velo-status"; then
  echo "  PASS  velo-status still uses this derivation"
else
  echo "  FAIL  velo-status's derivation changed — this test is now testing a copy"
  FAILURES=$((FAILURES+1))
fi

# ── the worker name shown for a LIVE process ───────────────────────────────
# Separate from the log-filename derivation above: when a worker is running,
# velo-status names it from the process argv instead. Those arms had no coverage
# and were wrong in two ways — they emitted bare names ("glm") while
# result.jsonl stored prefixed ones ("velo-glm"), so the table and the history
# disagreed about who ran; and there was no arm for deepseek41 at all, so a live
# V4.1 run displayed as "running?".
#
# EXECUTED, not copied: worker_from_cmd is eval'd out of velo-status, so an edit
# to the arms fails here rather than drifting. The first draft of this block
# re-implemented the case statement and guarded it with a grep for one literal
# arm — which proves a string exists, not that the logic matches. A reviewer
# caught that same shape twice in this repo; writing it a third time and calling
# it "extracted" in the comment was worse than the bug.
eval "$(sed -n '/^worker_from_cmd() {/,/^}/p' "$BIN/velo-status")"
if declare -F worker_from_cmd >/dev/null; then
  echo "  PASS  extracted worker_from_cmd from velo-status"
else
  echo "  FAIL  worker_from_cmd NOT extracted — the checks below would test nothing"
  FAILURES=$((FAILURES+1)); exit 1
fi
cmd_worker() { worker_from_cmd "$1"; }
# The function reads the local endpoint velo-status sources from velo-local.conf.
# shellcheck source=/dev/null
. "$BIN/velo-local.conf"
check "an empty local endpoint does not claim every run" \
  "$(VELO_LMSTUDIO_BASE_URL='' VELO_LLAMA_SERVER_URL='' worker_from_cmd 'codex exec --cd /x')" "velo-codex"
check "live glm names velo-glm"        "$(cmd_worker '--model z-ai/glm-5.3-flash')"          "velo-glm"
# #2423: the haiku route is matched on the anthropic/ model id, not a z-ai/ one.
check "live haiku names velo-haiku"    "$(cmd_worker '--model anthropic/claude-haiku-5.5')"  "velo-haiku"
check_not_haiku() { [[ "$(cmd_worker "$1")" != "velo-haiku" ]]; }
if check_not_haiku '--model z-ai/glm-5.3-flash'; then
  echo "  PASS  a glm run is not mis-named velo-haiku"
else
  echo "  FAIL  the haiku arm swallowed a glm model"; FAILURES=$((FAILURES+1))
fi
check "live codex names velo-codex"    "$(cmd_worker 'codex exec --cd /x')"                  "velo-codex"
check "live local names velo-local"    "$(cmd_worker '--model qwen3.8-flash-next-ud --base-url http://127.0.0.1:8091/v1')" "velo-local"
# The route is the LM Studio endpoint, not a model name: any local model matches.
check "a re-pinned local model still names velo-local" \
  "$(cmd_worker '--model some-future-model --base-url http://127.0.0.1:1234/v1')" "velo-local"
check "live deepseek names velo-deepseek" "$(cmd_worker '--model deepseek/deepseek-v4-flash-0731')" "velo-deepseek"
# Any deepseek model maps to the one unversioned route — a re-pin must not need
# a velo-status edit.
check "a re-pinned deepseek model still names velo-deepseek" \
      "$(cmd_worker '--model deepseek/deepseek-v4.1-flash')"                                 "velo-deepseek"

# And the whole command must still run. Assert only that it succeeds and prints its header.
# gh stubbed to fail at once: the real one made this check 8s of live GitHub
# calls, and velo-status already degrades to "(gh unavailable)" without it.
#
# velo-status walks the worktrees under $HOME/RustroverProjects and, when it finds none, says so and stops BEFORE the open-PR
# section — so on a host with no Velostream worktrees (a CI runner, a fresh account) every check below saw an empty PR list.
# The checks read a sandbox HOME instead: one worktree, with one runner log in the shape velo-dispatch writes, so the worker
# column has a row whose name the check on raw filenames below can actually catch. The result no longer depends on what
# worktrees the host happens to have.
SBH="$TMPD/home"; SBS="$TMPD/state"
mkdir -p "$SBH/RustroverProjects/velostream-101" "$SBS/dispatch/101"
git -C "$SBH/RustroverProjects/velostream-101" init -q \
  && git -C "$SBH/RustroverProjects/velostream-101" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
: > "$SBS/dispatch/101/codex-20260908T035158Z.log"
mkdir -p "$TMPD/stub"; printf '#!/bin/bash\nexit 1\n' > "$TMPD/stub/gh"; chmod +x "$TMPD/stub/gh"
OUT=$(HOME="$SBH" VELO_STATE="$SBS" PATH="$TMPD/stub:$PATH" "$BIN/velo-status" 2>&1)
if grep -q 'ISSUE.*WORKER.*STATE' <<<"$OUT"; then
  echo "  PASS  velo-status runs and prints its table"
else
  echo "  FAIL  velo-status did not produce a table"; FAILURES=$((FAILURES+1))
fi
# The column is TRUNCATED for display, so the full timestamp is not visible —
# 'codex-20260908T035158Z' renders as 'codex-20260'. Matching on the 'T' found
# nothing and the assertion was decorative. Match the year prefix instead, which
# survives truncation.
if grep -qE '^[0-9]+ +[a-z-]+-20[0-9][0-9]' <<<"$OUT"; then
  echo "  FAIL  a worker column still shows a raw timestamped filename"
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  no worker column shows a raw log filename"
fi
# gh failing at once must still be NAMED, not shown as an empty list of PRs.
if grep -qF '(gh unavailable)' <<<"$OUT"; then
  echo "  PASS  a gh that fails is reported as unavailable"
else
  echo "  FAIL  a gh that fails was not reported as unavailable"; FAILURES=$((FAILURES+1))
fi

# ── open PRs: the CI column is ONE state from EVERY check row ───────────────
# It printed `statusCheckRollup[0].conclusion` — whichever row sorts first. An optional lane that
# was skipped sorts first and says nothing, so a PR with a failing build showed SKIPPED, and one
# with a check still running showed the first finished row's SUCCESS. The state now comes from
# velo-ci-rollup.jq, the definition velo-merge refuses on, so the display and the gate cannot
# disagree about one PR.
echo
echo "velo-status open PRs: one CI state from every row"
CK='{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"}'
SK='{"__typename":"CheckRun","name":"Optional","status":"COMPLETED","conclusion":"SKIPPED"}'
OPEN_PRS='[
 {"number":101,"title":"skipped lane first, build failed","mergeable":"MERGEABLE","statusCheckRollup":[
    '"$SK"',{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number":102,"title":"green first, build still running","mergeable":"MERGEABLE","statusCheckRollup":[
    '"$CK"',{"__typename":"CheckRun","name":"Slow","status":"IN_PROGRESS","conclusion":""}]},
 {"number":103,"title":"skipped lane first, build green","mergeable":"MERGEABLE","statusCheckRollup":['"$SK"','"$CK"']},
 {"number":104,"title":"no checks at all","mergeable":"CONFLICTING","statusCheckRollup":[]},
 {"number":105,"title":"failed commit status first","mergeable":"MERGEABLE","statusCheckRollup":[
    {"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"},'"$CK"']}
]'
mkdir -p "$TMPD/stubpr"
cat > "$TMPD/stubpr/gh" <<'EOF'
#!/bin/bash
# The open-PR list is served from $STUB_OPEN_PRS (the caller's own --jq applied if it passes one);
# every other call finds nothing.
case "$*" in
  *"pr list"*"statusCheckRollup"*)
    [[ -n "${STUB_GH_FAIL:-}" ]] && exit 1
    jqx=""; prev=""
    for a in "$@"; do [[ "$prev" == "--jq" ]] && jqx="$a"; prev="$a"; done
    if [[ -n "$jqx" ]]; then jq -r "$jqx" <<<"$STUB_OPEN_PRS"; else printf '%s\n' "$STUB_OPEN_PRS"; fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/stubpr/gh"
run_status() {   # <directory holding velo-status> -> $OPEN_OUT
  OPEN_OUT=$(HOME="$SBH" VELO_STATE="$SBS" STUB_OPEN_PRS="$OPEN_PRS" PATH="$TMPD/stubpr:$PATH" "$1/velo-status" 2>&1)
}
pr_line() { grep -E "^  #$1 " <<<"$OPEN_OUT" | head -n 1; }   # <pr number>
run_status "$BIN"
check "a failed build behind a skipped first lane is FAILING" "$(pr_line 101)" "  #101 MERGEABLE FAILING  skipped lane first, build failed"
check "a check still running behind a green first row is pending" "$(pr_line 102)" "  #102 MERGEABLE pending  green first, build still running"
check "a skipped first lane does not hide a green build"  "$(pr_line 103)" "  #103 MERGEABLE SUCCESS  skipped lane first, build green"
check "a PR with no checks is none, not pending"          "$(pr_line 104)" "  #104 CONFLICTING none  no checks at all"
check "a failed commit status first is FAILING"           "$(pr_line 105)" "  #105 MERGEABLE FAILING  failed commit status first"

# Every behaviour above is pinned both ways: the same scenario on a copy of the tooling with that
# one behaviour mutated out must go red, and for the pinned reason. The copy is of the whole bin/
# directory — velo-status reads its libraries and the rollup definition from beside itself.
mutant_bin() {   # <file> <anchor> <replacement> -> a private copy of bin/ in which <file> has <anchor> replaced, once
  local d; d=$(mktemp -d "$TMPD/bincopy.XXXXXX") && cp -R "$BIN/." "$d/" || return 1
  python3 - "$d/$1" "$2" "$3" <<'PY' || return 1
import sys
path, old, new = sys.argv[1:]
t = open(path).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(path, "w").write(t.replace(old, new, 1))
PY
  printf '%s' "$d"
}
prove_red() {   # <label> <pr line to look at> <the line the real script prints> <mutant bin dir>
  local label="$1" pr="$2" want="$3" mdir="$4" got
  [[ -n "$mdir" ]] || { echo "  FAIL MUTATION-PROOF $label: the mutant could not be built (anchor not found?)"; FAILURES=$((FAILURES+1)); return; }
  run_status "$mdir"; got="$(pr_line "$pr")"
  if [[ "$got" == "$want" ]]; then
    echo "  FAIL MUTATION-PROOF $label: stayed GREEN with the behaviour removed"; FAILURES=$((FAILURES+1))
  else
    echo "  PASS  MUTATION-PROOF $label: red with the behaviour removed (got '$got')"
  fi
}
prove_red "the state is read from every row, not the first" 101 "  #101 MERGEABLE FAILING  skipped lane first, build failed" \
  "$(mutant_bin velo-status '(.statusCheckRollup | ci_rollup) as $ci' '({state: ((.statusCheckRollup[0].conclusion) // "pending")}) as $ci')"
prove_red "the state is read through the shared definition" 105 "  #105 MERGEABLE FAILING  failed commit status first" \
  "$(mutant_bin velo-ci-rollup.jq '"SUCCESS": "pass", "FAILURE": "fail", "ERROR": "fail", "PENDING"' '"SUCCESS": "pass", "PENDING"')"

# A definition that cannot be read, or cannot run, is NAMED on the PR list — never an empty list.
echo "  -- a rollup definition that is missing or broken"
NOJQ=$(mktemp -d "$TMPD/bincopy.XXXXXX") && cp -R "$BIN/." "$NOJQ/" && rm -f "$NOJQ/velo-ci-rollup.jq"
run_status "$NOJQ"
if grep -qF '(cannot read the CI rollup definition' <<<"$OPEN_OUT" && ! grep -qE '^  #10[0-9] ' <<<"$OPEN_OUT"; then
  echo "  PASS  a missing definition is named, and no PR is shown with a guessed state"
else
  echo "  FAIL  a missing definition was not named, or PRs were shown without it: $(grep -A1 'open PRs:' <<<"$OPEN_OUT" | tr '\n' ' ' | cut -c1-200)"; FAILURES=$((FAILURES+1))
fi
BROKEN=$(mktemp -d "$TMPD/bincopy.XXXXXX") && cp -R "$BIN/." "$BROKEN/" && printf 'def ci_rollup: this is not jq ;\n' > "$BROKEN/velo-ci-rollup.jq"
run_status "$BROKEN"
if grep -qF "(could not classify the open PRs' checks" <<<"$OPEN_OUT" && ! grep -qE '^  #10[0-9] ' <<<"$OPEN_OUT"; then
  echo "  PASS  a definition that cannot run is named, and no PR is shown with a guessed state"
else
  echo "  FAIL  a broken definition was not named, or PRs were shown without it: $(grep -A1 'open PRs:' <<<"$OPEN_OUT" | tr '\n' ' ' | cut -c1-200)"; FAILURES=$((FAILURES+1))
fi
# Each message removed in turn: the check that looks for it goes red.
named_in() {   # <bin dir> <needle> ; runs with the stub gh, which fails the PR list when STUB_GH_FAIL is set
  run_status "$1"; grep -qF -- "$2" <<<"$OPEN_OUT"
}
M1=$(mutant_bin velo-status '  echo "  (cannot read the CI rollup definition' '  : "  (cannot read the CI rollup definition') && rm -f "$M1/velo-ci-rollup.jq"
if [[ -n "$M1" ]] && ! named_in "$M1" '(cannot read the CI rollup definition'; then
  echo "  PASS  MUTATION-PROOF the unreadable-definition message: gone from the output with the line removed"
else
  echo "  FAIL  MUTATION-PROOF the unreadable-definition message: still printed (or the mutant could not be built)"; FAILURES=$((FAILURES+1))
fi
M2=$(mutant_bin velo-status "  echo \"  (could not classify the open PRs' checks" "  : \"  (could not classify the open PRs' checks") && printf 'def ci_rollup: this is not jq ;\n' > "$M2/velo-ci-rollup.jq"
if [[ -n "$M2" ]] && ! named_in "$M2" "(could not classify the open PRs' checks"; then
  echo "  PASS  MUTATION-PROOF the cannot-run message: gone from the output with the line removed"
else
  echo "  FAIL  MUTATION-PROOF the cannot-run message: still printed (or the mutant could not be built)"; FAILURES=$((FAILURES+1))
fi
# And a gh that fails is told apart from an empty list: with the line removed the section is blank.
M3=$(mutant_bin velo-status '  echo "  (gh unavailable)"' '  : "  (gh unavailable)"')
export STUB_GH_FAIL=1
if [[ -n "$M3" ]] && named_in "$BIN" '(gh unavailable)' && ! named_in "$M3" '(gh unavailable)'; then
  echo "  PASS  MUTATION-PROOF the gh-unavailable message: printed by the real script, gone with the line removed"
else
  echo "  FAIL  MUTATION-PROOF the gh-unavailable message: not printed by the real script, or still printed by the mutant"; FAILURES=$((FAILURES+1))
fi
unset STUB_GH_FAIL

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all velo-status checks passed"

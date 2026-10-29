#!/bin/bash
# The pre-gate sweep is supplied by the tooling, not by whoever writes the brief (#2231, spec §14).
#
# Past gate rounds on one stream found the same few defect shapes one per round: a second parser that
# diverges from the route's own, batch-constant work in a row loop, a route nobody listed. A worker
# sweeps for them before its first push only if its brief says so, and briefs went out without the
# text whenever the author forgot to paste rules/worker-pre-gate-sweep.md. Now:
#   - the brief lint (velo-brief-lint.sh) REFUSES a brief with no `## PRE-GATE SWEEP` heading, and
#     tells the caller to paste the file;
#   - velo-dispatch APPENDS the file to a COPY of such a brief, under its own state dir, and hands
#     the worker the copy — the caller's file is never touched, and it is still the caller's file that
#     the spec attestation pins and that velo-record reads.
#
# What is driven is the shipped code, never a re-statement of it:
#   - velo_brief_lint, velo_brief_has_sweep and velo_brief_ste_warn, sourced from velo-brief-lint.sh;
#   - velo-dispatch --dry-run, for real, against a stub gh, a stub df (so the result does not depend on
#     the disk the suite runs on) and a scratch clone for origin/master. The worktree it would cut is
#     named by the brief and never created.
#
# Every behaviour is pinned twice: green on the real file, and RED on a copy with that one behaviour
# mutated out (the MUTATION-PROOF cases at the end). The mutants are copies in a temp dir; the repo's
# scripts are never edited, so an interrupted run cannot leave one mutated.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin"
LIB_REAL="$BIN/velo-brief-lint.sh"
DISPATCH_REAL="$BIN/velo-dispatch"
SWEEP_REAL="$ROOT/rules/worker-pre-gate-sweep.md"
PREAMBLE_REAL="$ROOT/rules/gate-attack-preamble.md"
LIB_UNDER_TEST="$LIB_REAL"
DISPATCH_UNDER_TEST="$DISPATCH_REAL"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

for f in "$LIB_REAL" "$DISPATCH_REAL" "$SWEEP_REAL" "$PREAMBLE_REAL"; do
  [[ -s "$f" ]] || { fail "missing or empty: $f"; exit 1; }
done

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/mut"

SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has_text() { [[ "$1" == *"$2"* ]]; }                          # <haystack> <fixed needle>

run_scenarios() {   # "<function>::<what it pins>" ...
  local entry fn what
  for entry in "$@"; do
    fn="${entry%%::*}"; what="${entry#*::}"
    "$fn"
    if [[ -z "$SC_FAILS" ]]; then ok "$what"; else fail "$what:$SC_FAILS"; fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# the shipped rule files
# ═════════════════════════════════════════════════════════════════════════════
sc_rule_files() {
  SC_FAILS=""
  [[ "$(head -n 1 "$SWEEP_REAL")" == "## PRE-GATE SWEEP"* ]];   sc_check the-sweep-file-opens-with-its-heading $?
  [[ "$(head -n 1 "$PREAMBLE_REAL")" == "## ATTACK 0 — ONE-ROUND EXHAUSTIVE REVIEW"* ]]; sc_check the-preamble-opens-with-its-heading $?
  bash -c '. "$1"; velo_brief_has_sweep "$2"' _ "$LIB_UNDER_TEST" "$SWEEP_REAL"; sc_check the-lints-own-test-recognises-the-sweep-file $?
}

# ═════════════════════════════════════════════════════════════════════════════
# the lint
# ═════════════════════════════════════════════════════════════════════════════
# A brief that satisfies every lint rule except the sweep: worktree, no-cd, STOP, incremental
# commits, validation commands, commit authorization.
BODY=$'WORKTREE: /w\nDo NOT cd into it.\nSTOP and report if blocked.\nCommit after each step.\ncargo check --no-default-features\nYou may commit. Do NOT push.\n'
lint() {   # <brief text> -> LOUT, LRC
  printf '%s' "$1" > "$TMPD/lint.md"
  LOUT=$(bash -c '. "$1"; velo_brief_lint "$2"' _ "$LIB_UNDER_TEST" "$TMPD/lint.md" 2>&1); LRC=$?
}
bullets() { grep -c '^  - ' <<<"$LOUT"; }   # how many rules the lint just named

sc_lint_needs_sweep() {
  SC_FAILS=""
  lint "$BODY"
  [[ $LRC -eq 1 ]];                                             sc_check refused $?
  has_text "$LOUT" "BRIEF INCOMPLETE:";                         sc_check under-the-lint-heading $?
  has_text "$LOUT" "no '## PRE-GATE SWEEP' section (spec §14)"; sc_check names-the-rule $?
  has_text "$LOUT" "worker-pre-gate-sweep.md";                  sc_check and-the-file-to-paste $?
  has_text "$LOUT" "velo-dispatch appends it for you";          sc_check and-that-dispatch-would-have-appended-it $?
  [[ "$(bullets)" == "1" ]];                                    sc_check and-it-is-the-only-rule-named $?
}

sc_lint_accepts_sweep() {
  SC_FAILS=""
  local n=0 h
  for h in '## PRE-GATE SWEEP' '# PRE-GATE SWEEP' '### PRE-GATE SWEEP (mandatory; paste into every worker brief)' '##   PRE-GATE SWEEP'; do
    n=$((n + 1))
    lint "${BODY}${h}"$'\n'
    [[ $LRC -eq 0 && -z "$LOUT" ]];                             sc_check "accepted[heading-$n]" $?
  done
  lint "${BODY}$(cat "$SWEEP_REAL")"$'\n'
  [[ $LRC -eq 0 && -z "$LOUT" ]];                               sc_check accepted-the-shipped-file-as-dispatch-appends-it $?
  lint "${BODY//$'\n'/$'\r\n'}## PRE-GATE SWEEP"$'\r\n'
  [[ $LRC -eq 0 && -z "$LOUT" ]];                               sc_check accepted-with-CRLF-line-endings $?
}

# Each of these brings the words up without a sweep HEADING outside a fence.
sc_lint_sweep_must_be_a_heading() {
  SC_FAILS=""
  local n=0 t
  for t in \
    $'```\n## PRE-GATE SWEEP\n```\n' \
    $'~~~\n## PRE-GATE SWEEP\n' \
    $'Run the PRE-GATE SWEEP before the first push.\n' \
    $'- ## PRE-GATE SWEEP\n' \
    $'## pre-gate sweep\n' \
    $'## The PRE-GATE SWEEP\n' \
    $'## PRE-GATE-SWEEP\n' \
    $'    ## PRE-GATE SWEEP\n'; do
    n=$((n + 1))
    lint "${BODY}${t}"
    [[ $LRC -eq 1 ]] && has_text "$LOUT" "no '## PRE-GATE SWEEP' section"; sc_check "refused[mention-$n]" $?
  done
}

# The sweep heading satisfies ITS rule only.
sc_lint_sweep_does_not_mask_the_rest() {
  SC_FAILS=""
  lint $'## PRE-GATE SWEEP\n'
  [[ $LRC -eq 1 ]];                                             sc_check refused $?
  ! has_text "$LOUT" "PRE-GATE SWEEP' section";                 sc_check the-sweep-rule-is-not-named $?
  has_text "$LOUT" "no WORKTREE path";                          sc_check but-the-worktree-rule-is $?
  has_text "$LOUT" "no STOP conditions";                        sc_check and-the-stop-rule-is $?
  has_text "$LOUT" "no explicit commit/push authorization";     sc_check and-the-authorization-rule-is $?
}

# ═════════════════════════════════════════════════════════════════════════════
# the style advisory leaves the tooling-owned section alone
# ═════════════════════════════════════════════════════════════════════════════
LONG='Run the very long step that keeps going on and on with many more words than the twenty that the style limit allows for one step.'
sc_ste_skips_the_sweep_section() {
  SC_FAILS=""
  local STEOUT L
  ste_of() { printf '%s' "$1" > "$TMPD/ste.md"; STEOUT=$(bash -c '. "$1"; velo_brief_ste_warn "$2"' _ "$LIB_UNDER_TEST" "$TMPD/ste.md" 2>&1); }
  ste_of "${BODY}"$'\n'"$(cat "$SWEEP_REAL")"$'\n'
  [[ -z "$STEOUT" ]];                                           sc_check the-shipped-sweep-text-draws-no-warning $?
  ste_of "${BODY}1. ${LONG}"$'\n\n## PRE-GATE SWEEP\n\n1. '"${LONG}"$'\n\n## Notes\n\n1. '"${LONG}"$'\n'
  L=($(grep -n -- "$LONG" "$TMPD/ste.md" | cut -d: -f1))
  [[ ${#L[@]} -eq 3 ]];                                         sc_check fixture-has-three-long-steps $?
  has_text "$STEOUT" "line ${L[0]}:";                           sc_check a-long-step-before-the-section-is-flagged $?
  ! has_text "$STEOUT" "line ${L[1]}:";                         sc_check the-one-inside-it-is-not $?
  has_text "$STEOUT" "line ${L[2]}:";                           sc_check and-the-one-under-the-next-heading-is-flagged-again $?
}

# ═════════════════════════════════════════════════════════════════════════════
# velo-dispatch --dry-run, for real
# ═════════════════════════════════════════════════════════════════════════════
DH="$TMPD/dhome"; DROOT="$DH/RustroverProjects/velostream"; DSTATE="$TMPD/dstate"
ISS=9100100
WTP="$DH/RustroverProjects/velostream-$ISS"
mkdir -p "$DH/RustroverProjects" "$DSTATE" "$TMPD/stub"
git init -q -b master "$TMPD/seed"
git -C "$TMPD/seed" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m seed
git clone -q "$TMPD/seed" "$DROOT" || { fail "the scratch clone of the seed repo failed"; exit 1; }
# gh answers `issue view` from $GH_STATE_JSON (honouring --jq) and logs every call.
cat > "$TMPD/stub/gh" <<'STUB'
#!/bin/bash
ARGS="$*"
echo "$ARGS" >> "$GH_LOG"
case "$ARGS" in
  "issue view "*)
    if [[ "$ARGS" == *" --jq "* ]]; then jq -r "${ARGS##* --jq }" <<<"$GH_STATE_JSON"
    else printf '%s\n' "$GH_STATE_JSON"; fi ;;
  "issue edit "*) exit 0 ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
# velo-dispatch refuses under 40GB free (`df -g $HOME`, column 4 of line 2) and a dry run ends
# right after that check: say there is plenty, so the printout is reached on any host.
cat > "$TMPD/stub/df" <<'STUB'
#!/bin/bash
printf 'Filesystem 1G-blocks Used Available Capacity Mounted on\n/dev/stub 1000 100 900 10%% /\n'
STUB
chmod +x "$TMPD/stub/gh" "$TMPD/stub/df"
SKILL="$TMPD/check-code.md"; echo "# fixture skill" > "$SKILL"
DISPATCH_STATE="{\"state\":\"OPEN\",\"title\":\"[#$ISS] fixture\",\"labels\":[{\"name\":\"worker:local\"}],\"assignees\":[],\"updatedAt\":\"2026-10-11T06:00:00Z\"}"
SPEC="$DROOT/.agents/tasks/$ISS.json"

# A layout is <dir>/bin — velo-dispatch with the files it sources from its own directory — beside
# <dir>/rules, where it looks for the sweep file. The copies are of the scripts under test, so a
# mutant is what runs.
layout() {   # <dir> [<sweep file to install as rules/worker-pre-gate-sweep.md> | none]
  local dir="$1" rules="${2-$SWEEP_REAL}"
  rm -rf "$dir"; mkdir -p "$dir/bin"
  cp "$DISPATCH_UNDER_TEST" "$dir/bin/velo-dispatch"
  cp "$LIB_UNDER_TEST" "$dir/bin/velo-brief-lint.sh"
  cp "$BIN/velo-local.conf" "$dir/bin/velo-local.conf"
  if [[ "$rules" != none ]]; then mkdir -p "$dir/rules"; cp "$rules" "$dir/rules/worker-pre-gate-sweep.md"; fi
}
# A brief that satisfies every rule of the lint but the sweep, and names the worktree and branch
# the dispatch will cut.
mk_brief() {   # <file>
  printf '%s\n' "BRANCH: fix/$ISS-auto" "WORKTREE: $WTP" 'Do NOT cd into it.' 'STOP and report if blocked.' \
    'Commit after each step.' 'cargo check --no-default-features' 'You may commit. Do NOT push.' > "$1"
}
dispatch_dry() {   # <layout> <brief> -> DOUT, DRC; the issue's dispatch state dir starts empty
  rm -rf "$DSTATE/dispatch/$ISS"
  : > "$TMPD/dgh.log"
  DOUT=$(HOME="$DH" VELO_STATE="$DSTATE" VELO_CHECK_CODE_SKILL="$SKILL" PATH="$TMPD/stub:$PATH" \
         GH_LOG="$TMPD/dgh.log" GH_STATE_JSON="$DISPATCH_STATE" bash "$1/bin/velo-dispatch" "$ISS" "$2" --dry-run 2>&1); DRC=$?
}
copies() { ls "$DSTATE/dispatch/$ISS"/brief-*.md 2>/dev/null; }   # the briefs dispatch derived, one path per line
fresh_home() { rm -rf "$DH/.agents" "$DROOT/.agents/tasks"; }

sc_dispatch_appends() {
  SC_FAILS=""
  local B="$TMPD/brief.nosweep.md" L="$TMPD/lay-appends" C
  fresh_home; mk_brief "$B"; cp "$B" "$TMPD/brief.pristine"; layout "$L"
  dispatch_dry "$L" "$B"
  [[ $DRC -eq 0 ]];                                             sc_check dry-run-completes $?
  has_text "$DOUT" "brief had no PRE-GATE SWEEP: appended $L/bin/../rules/worker-pre-gate-sweep.md"; sc_check says-so-and-names-the-file $?
  C=$(copies)
  [[ -n "$C" && "$(wc -l <<<"$C" | tr -d ' ')" == "1" ]];       sc_check exactly-one-copy-under-the-dispatch-state-dir $?
  has_text "$DOUT" "the worker gets $C ($B is untouched)";      sc_check and-the-line-names-it $?
  { cat "$TMPD/brief.pristine"; printf '\n\n%s\n' "$(cat "$SWEEP_REAL")"; } > "$TMPD/copy.expected"
  cmp -s "$C" "$TMPD/copy.expected";                            sc_check the-copy-is-the-brief-then-a-blank-line-then-the-sweep-file $?
  cmp -s "$B" "$TMPD/brief.pristine";                           sc_check the-callers-file-is-byte-identical $?
  has_text "$DOUT" "brief satisfies the spec checklist";        sc_check the-lint-passes-on-the-copy $?
  has_text "$DOUT" "brief    : $B";                             sc_check the-dry-run-prints-the-callers-file $?
  has_text "$DOUT" "+ PRE-GATE SWEEP appended: the worker gets $C"; sc_check and-the-copy-the-worker-gets $?
}

sc_dispatch_leaves_a_complete_brief_alone() {
  SC_FAILS=""
  local B="$TMPD/brief.sweep.md" L="$TMPD/lay-complete"
  fresh_home; mk_brief "$B"; printf '\n%s\n' "$(cat "$SWEEP_REAL")" >> "$B"; cp "$B" "$TMPD/brief.pristine"; layout "$L"
  dispatch_dry "$L" "$B"
  [[ $DRC -eq 0 ]];                                             sc_check dry-run-completes $?
  ! has_text "$DOUT" "appended";                                sc_check says-nothing-was-appended $?
  [[ -z "$(copies)" ]];                                         sc_check and-writes-no-copy $?
  has_text "$DOUT" "brief satisfies the spec checklist";        sc_check and-the-lint-passes $?
  has_text "$DOUT" "brief    : $B";                             sc_check and-the-worker-gets-the-callers-file $?
  ! has_text "$DOUT" "+ PRE-GATE SWEEP appended";               sc_check with-no-second-line-about-a-copy $?
  cmp -s "$B" "$TMPD/brief.pristine";                           sc_check and-the-file-is-byte-identical $?
}

# The spec attestation pins the sha256 of the brief AS THE CALLER WROTE IT. The check runs before the
# append and reads the caller's file, so a pinned brief with no sweep is still accepted — twice running,
# because nothing ever rewrites the file — while a pin of anything else is still refused.
sc_dispatch_pins_the_callers_file() {
  SC_FAILS=""
  local B="$TMPD/brief.pinned.md" L="$TMPD/lay-pinned" sha
  fresh_home; mk_brief "$B"; layout "$L"
  mkdir -p "$DROOT/.agents/tasks"
  sha=$(shasum -a 256 "$B" | cut -d' ' -f1)
  printf '{ "issue": %s, "worker": "local", "design": "pinned",\n  "reviewed": { "by": "t", "at": "2026-10-12T00:00:00Z", "brief_sha256": "%s" } }\n' "$ISS" "$sha" > "$SPEC"
  dispatch_dry "$L" "$B"
  [[ $DRC -eq 0 ]];                                             sc_check dry-run-completes $?
  has_text "$DOUT" "brief hash matches reviewed.brief_sha256";  sc_check the-pin-is-checked-against-the-callers-file $?
  has_text "$DOUT" "brief had no PRE-GATE SWEEP: appended";     sc_check and-the-sweep-is-still-appended $?
  dispatch_dry "$L" "$B"
  [[ $DRC -eq 0 ]];                                             sc_check a-second-dispatch-of-the-same-file-completes $?
  has_text "$DOUT" "brief hash matches reviewed.brief_sha256";  sc_check and-the-pin-still-holds $?
  printf '{ "issue": %s, "worker": "local", "design": "pinned",\n  "reviewed": { "by": "t", "at": "2026-10-12T00:00:00Z", "brief_sha256": "%064d" } }\n' "$ISS" 0 > "$SPEC"
  dispatch_dry "$L" "$B"
  [[ $DRC -ne 0 ]];                                             sc_check a-pin-of-anything-else-is-refused $?
  has_text "$DOUT" "THE BRIEF CHANGED SINCE REVIEW";            sc_check and-says-why $?
  [[ -z "$(copies)" ]];                                         sc_check and-no-copy-was-written-before-the-refusal $?
  rm -f "$SPEC"
}

# The sweep file is looked for beside the script first, then in the installed copy. One that is
# missing, empty or not recognised stops the dispatch before it writes anything: appending nothing
# would just be the lint refusing a brief this script was meant to complete.
sc_dispatch_sweep_file() {
  SC_FAILS=""
  local B="$TMPD/brief.nosweep.md" L="$TMPD/lay-file" C v
  fresh_home; mk_brief "$B"
  layout "$L" none
  dispatch_dry "$L" "$B"
  [[ $DRC -ne 0 ]];                                             sc_check "refused[absent]" $?
  has_text "$DOUT" "worker-pre-gate-sweep.md was not found to append. Looked in:"; sc_check "says-why[absent]" $?
  has_text "$DOUT" "$L/bin/../rules/worker-pre-gate-sweep.md";  sc_check "names-the-path-beside-the-script[absent]" $?
  has_text "$DOUT" "$DH/.agents/rules/worker-pre-gate-sweep.md"; sc_check "names-the-installed-path[absent]" $?
  [[ -z "$(copies)" ]];                                         sc_check "writes-nothing[absent]" $?
  for v in empty blank no-heading; do
    case "$v" in
      empty)      : > "$TMPD/sweep.variant" ;;
      blank)      printf ' \n\n\t\n' > "$TMPD/sweep.variant" ;;
      no-heading) printf '1. Sweep for the shapes.\n' > "$TMPD/sweep.variant" ;;
    esac
    layout "$L" "$TMPD/sweep.variant"
    dispatch_dry "$L" "$B"
    [[ $DRC -ne 0 ]];                                           sc_check "refused[$v]" $?
    case "$v" in
      empty|blank) has_text "$DOUT" "worker-pre-gate-sweep.md is EMPTY"; sc_check "says-why[$v]" $? ;;
      no-heading)  has_text "$DOUT" "has no '## PRE-GATE SWEEP' heading, so appending it would not satisfy the lint"; sc_check "says-why[$v]" $? ;;
    esac
    [[ -z "$(copies)" ]];                                       sc_check "writes-nothing[$v]" $?
  done
  # only the installed copy
  fresh_home; layout "$L" none
  mkdir -p "$DH/.agents/rules"
  printf '## PRE-GATE SWEEP\nINSTALLED-TOKEN\n' > "$DH/.agents/rules/worker-pre-gate-sweep.md"
  dispatch_dry "$L" "$B"
  C=$(copies)
  [[ $DRC -eq 0 ]];                                             sc_check "completes[installed]" $?
  has_text "$DOUT" "appended $DH/.agents/rules/worker-pre-gate-sweep.md"; sc_check "names-the-installed-copy[installed]" $?
  [[ -n "$C" ]] && grep -qF INSTALLED-TOKEN "$C";               sc_check "the-worker-gets-it[installed]" $?
  # both: the one beside the script wins
  printf '## PRE-GATE SWEEP\nSIBLING-TOKEN\n' > "$TMPD/sweep.sibling"
  layout "$L" "$TMPD/sweep.sibling"
  dispatch_dry "$L" "$B"
  C=$(copies)
  [[ $DRC -eq 0 ]];                                             sc_check "completes[both]" $?
  [[ -n "$C" ]] && grep -qF SIBLING-TOKEN "$C";                 sc_check "the-copy-beside-the-script-wins" $?
  [[ -n "$C" ]] && ! grep -qF INSTALLED-TOKEN "$C";             sc_check "and-the-installed-one-is-not-added" $?
  fresh_home
}

# The two launch-time uses of the brief cannot be driven without cutting a worktree and starting a
# worker, so the lines that pick the file are pinned where they are made: the worker's task is read
# from the brief dispatch settled on (the copy, when one was made); the supervisor — and so
# velo-record, which classifies a brief as read-only by grepping its prose, and reads the sweep's
# "mandatory" as a brief that mandates commits — is handed the caller's file.
sc_dispatch_launch_wiring() {
  SC_FAILS=""
  [[ "$(grep -cF 'TASK="$(cat "$BRIEF")' "$DISPATCH_UNDER_TEST")" == "1" ]]; sc_check the-workers-task-is-read-from-the-brief-dispatch-settled-on $?
  [[ "$(grep -cF '"$MODEL_ID" "$BRIEF_AS_WRITTEN" "$STARTED"' "$DISPATCH_UNDER_TEST")" == "1" ]]; sc_check the-supervisor-is-handed-the-callers-file $?
}

# velo-spec-review attests the brief AS WRITTEN — it pins the file's sha256 — so unlike velo-dispatch it
# does not complete a brief for you: a file with no sweep section is refused, and a refusal records
# nothing. (Attesting the file with the section pins the file that carries it.)
sc_spec_review_attests_the_file_as_written() {
  SC_FAILS=""
  local AISS=9100101 FH="$TMPD/attest-home" L="$TMPD/lay-attest" B="$TMPD/brief.attest.md" W="$TMPD/brief.attest.sweep.md" S AOUT ARC
  S="$FH/RustroverProjects/velostream/.agents/tasks/$AISS.json"
  rm -rf "$FH" "$L"; mkdir -p "$FH/RustroverProjects/velostream/.agents/tasks" "$L/bin"
  printf '{\n  "issue": %s,\n  "worker": "local"\n}\n' "$AISS" > "$S"; cp "$S" "$TMPD/attest.spec.pristine"
  cp "$BIN/velo-spec-review" "$L/bin/velo-spec-review"; cp "$LIB_UNDER_TEST" "$L/bin/velo-brief-lint.sh"
  mk_brief "$B"; { cat "$B"; printf '\n%s\n' "$(cat "$SWEEP_REAL")"; } > "$W"
  : > "$TMPD/agh.log"
  attest_of() {   # <brief> -> AOUT, ARC
    AOUT=$(HOME="$FH" VELO_STATE="$TMPD/astate" PATH="$TMPD/stub:$PATH" GH_LOG="$TMPD/agh.log" \
           GH_STATE_JSON='{"updatedAt":"2026-10-11T06:00:00Z","labels":[{"name":"worker:local"}]}' \
           bash "$L/bin/velo-spec-review" "$AISS" "$1" --by tester 2>&1); ARC=$?
  }
  attest_of "$B"
  [[ $ARC -eq 1 ]];                                             sc_check refuses-a-brief-with-no-sweep-section $?
  has_text "$AOUT" "no '## PRE-GATE SWEEP' section (spec §14)"; sc_check and-names-the-rule $?
  cmp -s "$S" "$TMPD/attest.spec.pristine";                     sc_check and-records-nothing-in-the-spec $?
  [[ "$(grep -c 'issue edit' "$TMPD/agh.log")" == "0" ]];       sc_check and-writes-nothing-to-the-issue $?
  attest_of "$W"
  [[ $ARC -eq 0 ]];                                             sc_check attests-the-file-that-carries-it $?
  [[ "$(jq -r .reviewed.brief_sha256 "$S")" == "$(shasum -a 256 "$W" | cut -d' ' -f1)" ]]; sc_check and-pins-that-file-as-written $?
}

echo "the shipped rule files"
run_scenarios \
  "sc_rule_files::both rules files ship, each opening with the heading the tooling recognises it by"

echo
echo "the brief lint: the sweep (spec §14)"
run_scenarios \
  "sc_lint_needs_sweep::a brief with no PRE-GATE SWEEP heading is refused, naming the file to paste and that dispatch appends it" \
  "sc_lint_accepts_sweep::any depth of heading, CRLF, and the shipped file itself satisfy it" \
  "sc_lint_sweep_must_be_a_heading::a fenced heading, a mention, a bullet, other case or spelling, or indented code do not" \
  "sc_lint_sweep_does_not_mask_the_rest::the heading satisfies its own rule only"

echo
echo "the style advisory (spec §13)"
run_scenarios \
  "sc_ste_skips_the_sweep_section::the tooling-owned section draws no warning; steps around it still do"

echo
echo "velo-dispatch --dry-run (real script, stub gh and df)"
run_scenarios \
  "sc_dispatch_appends::a brief with no sweep gets it on a COPY: caller's file untouched, lint passes on the copy, the dry run names both" \
  "sc_dispatch_leaves_a_complete_brief_alone::a brief that has the section is handed over as it is, no copy" \
  "sc_dispatch_pins_the_callers_file::the spec pin is checked against the caller's file, twice running; any other pin is still refused" \
  "sc_dispatch_sweep_file::the sweep file is found beside the script, then installed; missing, empty or unrecognised stops the dispatch before it writes" \
  "sc_dispatch_launch_wiring::the worker reads the settled brief; the supervisor and velo-record get the caller's"

echo
echo "velo-spec-review attest (the file as written)"
run_scenarios \
  "sc_spec_review_attests_the_file_as_written::attest refuses a brief with no sweep section, records nothing, and pins the file that has it as written"

# ═════════════════════════════════════════════════════════════════════════════
# MUTATION-PROOF — each behaviour goes red when it is removed
# ═════════════════════════════════════════════════════════════════════════════
echo
echo "mutation proofs"
mutate() {   # <src> <dst> <anchor> <replacement> [<anchor> <replacement>]...
  python3 - "$@" <<'PY'
import sys
src, dst, *pairs = sys.argv[1:]
assert len(pairs) % 2 == 0, "mutation anchors come as (anchor, replacement) pairs"
t = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
    t = t.replace(old, new, 1)
open(dst, "w").write(t)
PY
}
report_proof() {   # <label> <scenario> <SC_FAILS of the mutant run> <SC_FAILS of the restored run>
  if [[ -z "$3" ]]; then fail "MUTATION-PROOF $1: stayed GREEN with the behaviour removed — $2 does not pin it"
  elif [[ -n "$4" ]]; then fail "MUTATION-PROOF $1: the real script is red too:$4"
  else ok "MUTATION-PROOF $1: red with the behaviour removed ($3 ), green restored"; fi
}
prove_lib() {   # <label> <scenario> <anchor> <replacement> [<anchor> <replacement>]...
  local label="$1" fn="$2" red; shift 2
  if ! mutate "$LIB_REAL" "$TMPD/mut/velo-brief-lint.sh" "$@"; then fail "MUTATION-PROOF $label: anchor not found — did velo-brief-lint.sh change shape?"; return; fi
  LIB_UNDER_TEST="$TMPD/mut/velo-brief-lint.sh"; "$fn"; red="$SC_FAILS"
  LIB_UNDER_TEST="$LIB_REAL"; "$fn"
  report_proof "$label" "$fn" "$red" "$SC_FAILS"
}
prove_dispatch() {   # <label> <scenario> <anchor> <replacement> [<anchor> <replacement>]...
  local label="$1" fn="$2" red; shift 2
  if ! mutate "$DISPATCH_REAL" "$TMPD/mut/velo-dispatch" "$@"; then fail "MUTATION-PROOF $label: anchor not found — did velo-dispatch change shape?"; return; fi
  DISPATCH_UNDER_TEST="$TMPD/mut/velo-dispatch"; "$fn"; red="$SC_FAILS"
  DISPATCH_UNDER_TEST="$DISPATCH_REAL"; "$fn"
  report_proof "$label" "$fn" "$red" "$SC_FAILS"
}

HAS_SWEEP_GREP="grep -qE '^#+[[:space:]]+PRE-GATE SWEEP' <<<\"\$prose\""
prove_lib "the lint refuses a brief with no sweep heading" sc_lint_needs_sweep \
  'velo_brief_has_sweep "$BRIEF" \' 'true \'
prove_lib "...and velo-spec-review attest, which runs the same lint, refuses it too" sc_spec_review_attests_the_file_as_written \
  'velo_brief_has_sweep "$BRIEF" \' 'true \'
prove_lib "...and a fenced quote of the heading is not the heading" sc_lint_sweep_must_be_a_heading \
  'prose=$(brief_prose)' 'prose=$(cat "$BRIEF")'
prove_lib "...nor a mention of its words" sc_lint_sweep_must_be_a_heading \
  "$HAS_SWEEP_GREP" "grep -qE 'PRE-GATE SWEEP' <<<\"\$prose\""
prove_lib "...nor the same words in another case" sc_lint_sweep_must_be_a_heading \
  "$HAS_SWEEP_GREP" "grep -qiE '^#+[[:space:]]+PRE-GATE SWEEP' <<<\"\$prose\""
prove_lib "the heading is accepted at any depth" sc_lint_accepts_sweep \
  "$HAS_SWEEP_GREP" "grep -qE '^##[[:space:]]+PRE-GATE SWEEP' <<<\"\$prose\""
prove_lib "...and it need not end the line (CRLF, trailing words)" sc_lint_accepts_sweep \
  "$HAS_SWEEP_GREP" "grep -qE '^#+[[:space:]]+PRE-GATE SWEEP\$' <<<\"\$prose\""
prove_lib "the style advisory skips the tooling-owned section" sc_ste_skips_the_sweep_section \
  '    sweep { next }' ''
prove_lib "...up to the next heading, and no further" sc_ste_skips_the_sweep_section \
  '    sweep && /^#/ { sweep = 0 }' ''

APPEND='{ cat "$BRIEF_AS_WRITTEN"; printf '"'"'\n\n%s\n'"'"' "$SWEEP_TEXT"; } > "$BRIEF" \'
prove_dispatch "dispatch appends the sweep file to the brief" sc_dispatch_appends \
  "$APPEND" 'cp "$BRIEF_AS_WRITTEN" "$BRIEF" \'
prove_dispatch "...to a COPY: the caller's file is never written to" sc_dispatch_appends \
  'BRIEF="$VELO_STATE/dispatch${REPO_SUB}/${ISSUE}/brief-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"' 'BRIEF="$BRIEF_AS_WRITTEN"'
prove_dispatch "...and the spec pin still holds for a second dispatch of the same file" sc_dispatch_pins_the_callers_file \
  'BRIEF="$VELO_STATE/dispatch${REPO_SUB}/${ISSUE}/brief-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"' 'BRIEF="$BRIEF_AS_WRITTEN"'
prove_dispatch "the dry run names the caller's file" sc_dispatch_appends \
  'echo "  brief    : $BRIEF_AS_WRITTEN"' 'echo "  brief    : $BRIEF"'
prove_dispatch "...and the copy the worker gets" sc_dispatch_appends \
  'echo "             + PRE-GATE SWEEP appended: the worker gets $BRIEF"' ':'
prove_dispatch "a brief that has the section is left alone" sc_dispatch_leaves_a_complete_brief_alone \
  'if ! velo_brief_has_sweep "$BRIEF"; then' 'if true; then'
prove_dispatch "a sweep file that cannot be found stops the dispatch" sc_dispatch_sweep_file \
  '[[ -n "$SWEEP_FILE" ]] || die "the brief has no' '[[ -n "$SWEEP_FILE" ]] || : "the brief has no'
prove_dispatch "...an empty one too" sc_dispatch_sweep_file \
  '|| die "$SWEEP_FILE is EMPTY' '|| : "$SWEEP_FILE is EMPTY'
prove_dispatch "...and one with no heading, which would not satisfy the lint" sc_dispatch_sweep_file \
  '|| die "$SWEEP_FILE has no ' '|| : "$SWEEP_FILE has no '
prove_dispatch "the installed copy is the fallback" sc_dispatch_sweep_file \
  'for cand in "$(dirname "${BASH_SOURCE[0]}")/../rules/$SWEEP_NAME" "$HOME/.agents/rules/$SWEEP_NAME"; do' \
  'for cand in "$(dirname "${BASH_SOURCE[0]}")/../rules/$SWEEP_NAME"; do'
prove_dispatch "...and the copy beside the script wins" sc_dispatch_sweep_file \
  'for cand in "$(dirname "${BASH_SOURCE[0]}")/../rules/$SWEEP_NAME" "$HOME/.agents/rules/$SWEEP_NAME"; do' \
  'for cand in "$HOME/.agents/rules/$SWEEP_NAME" "$(dirname "${BASH_SOURCE[0]}")/../rules/$SWEEP_NAME"; do'
prove_dispatch "the supervisor is handed the caller's file" sc_dispatch_launch_wiring \
  '"$MODEL_ID" "$BRIEF_AS_WRITTEN" "$STARTED"' '"$MODEL_ID" "$BRIEF" "$STARTED"'
prove_dispatch "the worker's task is read from the brief dispatch settled on" sc_dispatch_launch_wiring \
  'TASK="$(cat "$BRIEF")' 'TASK="$(cat "$BRIEF_AS_WRITTEN")'

echo
[[ $FAILED -eq 0 ]] && echo "all brief-sweep checks passed" || echo "FAILURES"
exit $FAILED

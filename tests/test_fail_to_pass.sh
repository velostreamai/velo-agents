#!/bin/bash
# The acceptance gate must name tests that EXIST.
#
# `tests.fail_to_pass` is what decides whether a run worked. Every other gate in
# velo-dispatch validated the WORK — anchors, blast radius, dependencies, brief
# shape — and nothing validated the GATE.
#
# #1958 declared `enforced_files_covers_every_executable_sql_doc` and
# `ungated_block_register_matches_reality`. Neither is defined anywhere in the
# tree. That dispatch LANDED with 6 commits: a run reporting success while its
# acceptance gate named nothing. A paid Codex spec review found it; this is a
# grep, and it now runs before a worktree is even cut.
#
# The block is EXTRACTED from velo-dispatch between markers and evaluated here,
# not re-implemented — a copy keeps passing after the real check is deleted,
# which is how #2027 round 6 shipped a script that had lost the check it added.
#
# #2096 SPLIT THE CHECK IN TWO, and this file now guards both halves.
#
# Dispatch-time verification could only ever be satisfied by tests already on
# master. A spec pinning NEW behaviour therefore had to redden master or point
# fail_to_pass at something that already passes — and the second satisfies the
# grep while gating exactly as little as #1958's names-nothing case. So the
# dispatch check WARNS, and velo-pr-gate BLOCKS at merge, where it can also see
# the already-passing case the grep never could.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
PRGATE="$(cd "$HERE/.." && pwd)/bin/velo-pr-gate"
ROOT="$HOME/RustroverProjects/velostream"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

echo "fail_to_pass validation"

BLOCK=$(sed -n '/^  # >>> velo-fail-to-pass/,/^  # <<< velo-fail-to-pass/p' "$DISPATCH")
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL  could not extract the check from velo-dispatch — deleted or renamed."
  echo "        A spec naming nonexistent tests would dispatch again."
  exit 1
fi
echo "  PASS  check still present in velo-dispatch ($(wc -l <<<"$BLOCK" | tr -d ' ') lines)"

# The merge-time half is where the guarantee actually lives now. If it is gone,
# nothing enforces the acceptance gate at all — dispatch only warns.
MBLOCK=$(sed -n '/^# >>> velo-fail-to-pass-merge/,/^# <<< velo-fail-to-pass-merge/p' "$PRGATE")
if [[ -z "$MBLOCK" ]]; then
  echo "  FAIL  merge-time check missing from velo-pr-gate — deleted or renamed."
  echo "        Dispatch only WARNS since #2096, so this is the only enforcement left:"
  echo "        without it a PR can merge naming tests that never existed (#1958)."
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  merge-time check present in velo-pr-gate ($(wc -l <<<"$MBLOCK" | tr -d ' ') lines)"
  for needle in 'BLOCK: fail_to_pass names test(s) that do not exist' 'exit 1' 'FTP_PREDATES'; do
    if grep -qF -- "$needle" <<<"$MBLOCK"; then
      echo "  PASS  merge check retains '$needle'"
    else
      echo "  FAIL  merge check lost '$needle' — it can no longer refuse."
      FAILURES=$((FAILURES+1))
    fi
  done
fi

# ---- the merge-time half, RUN -----------------------------------------------------------------
#
# The needles above only prove the block is still there. It is also run here, extracted verbatim,
# against a real two-commit repo with gh / warn / ok / die standing in for the script's own. Every
# read the block makes can fail — the PR's title, its base branch, the spec file, git itself — and
# each of those used to leave the check with nothing to verify and nothing to say: a failed read is
# not "no names", and the gate that enforces the acceptance tests must not go quiet because it
# could not look.
if [[ -n "$MBLOCK" ]]; then
  MREPO="$TMPD/mrepo"
  git init -q "$MREPO"
  mg() { git -C "$MREPO" -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false "$@"; }
  mkdir -p "$MREPO/tests" "$MREPO/.agents/tasks" "$TMPD/notrepo/.agents/tasks"
  printf 'fn old_test() {}\n' > "$MREPO/tests/a.rs"
  mg add tests/a.rs; mg commit -q -m base
  mg update-ref refs/remotes/origin/master HEAD       # the base: old_test exists, new_test does not
  printf 'fn new_test() {}\n' >> "$MREPO/tests/a.rs"
  mg add tests/a.rs; mg commit -q -m head              # the PR's head: both exist

  # <block text>; reads $MSPEC (the spec file's content) and the MR_* knobs from the environment.
  mrun() {
    local wt="${MR_WTPATH:-$MREPO}"
    printf '%s\n' "$MSPEC" > "$wt/.agents/tasks/9999.json"
    (
      PR=1; REPO=x/y; WTPATH="$wt"; WT="${MR_WT:-fix/9999-thing}"
      warn() { echo "WARN: $1"; }
      ok()   { echo "OK: $1"; }
      die()  { echo "DIED: $1"; exit 1; }
      gh() {   # the two reads the block makes: the base branch and the title's issue number
        case "$*" in
          *baseRefName*) [[ -z "${MR_BASE_FAIL:-}" ]] || { echo "gh: HTTP 502" >&2; return 1; }
                         printf '%s\n' "${MR_BASE:-master}" ;;
          *title*)       [[ -z "${MR_TITLE_FAIL:-}" ]] || { echo "gh: HTTP 502" >&2; return 1; }
                         printf '%s\n' "${MR_TITLE_N:-}" ;;
          *)             echo "unexpected gh call: $*" >&2; return 1 ;;
        esac
      }
      eval "$1"
    ) 2>&1
    echo "RC=$?"
  }
  msay() { grep -qF -- "$2" <<<"$1"; }     # <output> <needle>
  mfail() { MFAILS="$MFAILS $1"; }
  mreport() {   # <label>: the case just run, judged by MFAILS
    if [[ -z "$MFAILS" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1:$MFAILS"; FAILURES=$((FAILURES+1)); fi
  }

  # What the block does today, pinned: these must not change.
  case_new_name() {   # a name defined at the head only: accepted, nothing said about the base
    MSPEC='{"tests":{"fail_to_pass":["new_test"]}}'
    local o; o=$(mrun "$1"); MFAILS=""
    msay "$o" "OK: fail_to_pass: 1 name(s), all defined at PR head [spec from worktree]" || mfail accepted
    msay "$o" "RC=0"                                                                     || mfail exits-0
    ! msay "$o" "already existed"                                                        || mfail not-called-predating
  }
  case_absent_name() {   # a name defined nowhere: the gate refuses
    MSPEC='{"tests":{"fail_to_pass":["nope_test"]}}'
    local o; o=$(mrun "$1"); MFAILS=""
    msay "$o" "BLOCK: fail_to_pass names test(s) that do not exist" || mfail blocks
    msay "$o" "nope_test"                                           || mfail names-it
    msay "$o" "RC=1"                                                || mfail exits-1
  }
  case_predating_name() {   # a name that already existed at the base: said, not refused
    MSPEC='{"tests":{"fail_to_pass":["old_test"]}}'
    local o; o=$(mrun "$1"); MFAILS=""
    msay "$o" "already existed at origin/master" || mfail says-it-predates
    msay "$o" "RC=0"                             || mfail exits-0
  }
  case_no_names() {   # a spec that parses and names nothing: nothing to verify, nothing to say
    MSPEC='{"tests":{}}'
    local o; o=$(mrun "$1"); MFAILS=""
    ! msay "$o" "WARN:" || mfail no-warning
    ! msay "$o" "OK:"   || mfail no-verdict
    msay "$o" "RC=0"    || mfail exits-0
  }
  case_title_names_the_issue() {   # no issue in the branch name: the PR title's number finds the spec
    MSPEC='{"tests":{"fail_to_pass":["new_test"]}}'
    local o; o=$(MR_WT=feature-branch MR_TITLE_N=9999 mrun "$1"); MFAILS=""
    msay "$o" "OK: fail_to_pass: 1 name(s), all defined at PR head" || mfail spec-found-through-the-title
  }
  case_title_names_nothing() {   # no issue in the branch name or the title: no spec, legitimately
    MSPEC='{"tests":{"fail_to_pass":["nope_test"]}}'
    local o; o=$(MR_WT=feature-branch MR_TITLE_N= mrun "$1"); MFAILS=""
    ! msay "$o" "WARN:"  || mfail no-warning
    ! msay "$o" "BLOCK:" || mfail nothing-to-block
    msay "$o" "RC=0"     || mfail exits-0
  }
  # Reads that can fail: said, never read as "nothing to verify".
  case_title_unreadable() {
    MSPEC='{"tests":{"fail_to_pass":["nope_test"]}}'
    local o; o=$(MR_WT=feature-branch MR_TITLE_FAIL=1 mrun "$1"); MFAILS=""
    msay "$o" "WARN: could not read the title of #1"         || mfail says-the-title-read-failed
    msay "$o" "fail_to_pass is NOT being verified"           || mfail says-nothing-was-verified
    msay "$o" "gh: HTTP 502"                                 || mfail shows-ghs-own-words
    ! msay "$o" "BLOCK:"                                     || mfail not-a-verdict
  }
  case_spec_unparseable() {
    MSPEC='{"tests": {"fail_to_pass": ['
    local o; o=$(mrun "$1"); MFAILS=""
    msay "$o" "WARN: could not read the names from"          || mfail says-the-spec-is-unreadable
    msay "$o" "9999.json"                                    || mfail names-the-file
    msay "$o" "fail_to_pass is NOT being verified"           || mfail says-nothing-was-verified
    ! msay "$o" "OK: fail_to_pass"                           || mfail not-called-verified
  }
  case_base_unreadable() {
    MSPEC='{"tests":{"fail_to_pass":["old_test"]}}'
    local o; o=$(MR_BASE_FAIL=1 mrun "$1"); MFAILS=""
    msay "$o" "DIED: could not read base branch for #1"      || mfail refuses-in-the-retryable-shape
    msay "$o" "RC=1"                                         || mfail exits-1
    ! msay "$o" "OK: fail_to_pass"                           || mfail not-called-verified
  }
  case_base_unsearchable() {   # the base branch reads fine but git has no such ref
    MSPEC='{"tests":{"fail_to_pass":["new_test"]}}'
    local o; o=$(MR_BASE=gone mrun "$1"); MFAILS=""
    msay "$o" "DIED: git could not search origin/gone"       || mfail says-git-could-not-search
    msay "$o" "new_test"                                     || mfail names-the-test
    msay "$o" "RC=1"                                         || mfail exits-1
    ! msay "$o" "OK: fail_to_pass"                           || mfail not-called-verified
  }
  case_head_unsearchable() {   # git cannot search the head (not a repo): not "the tests do not exist"
    MSPEC='{"tests":{"fail_to_pass":["new_test"]}}'
    local o; o=$(GIT_CEILING_DIRECTORIES="$TMPD" MR_WTPATH="$TMPD/notrepo" mrun "$1"); MFAILS=""
    msay "$o" "DIED: git could not search HEAD"              || mfail says-git-could-not-search
    msay "$o" "RC=1"                                         || mfail exits-1
    ! msay "$o" "do not exist"                               || mfail not-called-nonexistent
  }

  for spec in "a name defined at the head is accepted:case_new_name" \
              "a name defined nowhere is refused:case_absent_name" \
              "a name that predates the PR is said, not refused:case_predating_name" \
              "a spec that names nothing is skipped without a word:case_no_names" \
              "the PR title finds the spec when the branch name carries no issue:case_title_names_the_issue" \
              "no issue anywhere means no spec, with no warning:case_title_names_nothing" \
              "a title that cannot be read says the check was not made:case_title_unreadable" \
              "a spec that cannot be read says the check was not made:case_spec_unparseable" \
              "a base branch that cannot be read refuses the round (retryable):case_base_unreadable" \
              "a base ref git cannot search refuses, naming the test:case_base_unsearchable" \
              "a head git cannot search refuses, and does not call the tests missing:case_head_unsearchable"; do
    "${spec##*:}" "$MBLOCK"
    mreport "merge-time check: ${spec%:*}"
  done

  # MUTATION-PROOF, on COPIES of the extracted block: each fix is taken out in turn and the case that
  # pins it must go red, naming the check it pins.
  mutant_block() {   # <anchor> <replacement> -> MUT_BLOCK (the anchor must occur exactly once)
    MUT_BLOCK=$(python3 -c '
import sys
t, old, new = sys.stdin.read(), sys.argv[1], sys.argv[2]
assert t.count(old) == 1, "anchor must occur exactly once, found %d: %r" % (t.count(old), old)
sys.stdout.write(t.replace(old, new, 1))
' "$1" "$2" <<<"$MBLOCK") || return 1
  }
  mprove() {   # <label> <case fn> <names that must be red> <anchor> <replacement>
    local label="$1" fn="$2" want="$3" n missing=""
    if ! mutant_block "$4" "$5"; then
      echo "  FAIL  MUTATION-PROOF $label: could not build the mutant (anchor missing or repeated — did the block change shape?)"
      FAILURES=$((FAILURES+1)); return
    fi
    "$fn" "$MUT_BLOCK"
    for n in $want; do [[ " $MFAILS " == *" $n "* ]] || missing="$missing $n"; done
    if [[ -z "$missing" ]]; then
      echo "  PASS  MUTATION-PROOF $label: red for$MFAILS"
    else
      echo "  FAIL  MUTATION-PROOF $label: stayed GREEN for$missing (red for:$MFAILS)"; FAILURES=$((FAILURES+1))
    fi
  }
  mprove "a title that cannot be read is said (the warning removed)" case_title_unreadable \
    "says-the-title-read-failed says-nothing-was-verified" \
    'warn "could not read the title of #$PR' ': "could not read the title of #$PR'
  mprove "a title that cannot be read shows gh's own words (stderr hidden again)" case_title_unreadable \
    "shows-ghs-own-words" \
    $'| .n\'); then' $'| .n\' 2>/dev/null); then'
  mprove "a spec that cannot be read is said (the failing status dropped)" case_spec_unparseable \
    "says-the-spec-is-unreadable names-the-file says-nothing-was-verified" \
    'sys.exit(1)' 'sys.exit(0)'
  # Only the message is this guard's own: with it removed the empty base becomes `origin/`, which git
  # cannot search, so the guard below it still refuses (exits-1, not-called-verified stay green) — but
  # with git's error, not the `could not read base branch` words velo-gate-run knows to retry.
  mprove "a base branch that cannot be read refuses in the retryable shape (the guard removed)" case_base_unreadable \
    "refuses-in-the-retryable-shape" \
    '[[ -n "$FTP_BASE" ]] || die "could not read base branch for #$PR"' ':'
  mprove "a base ref git cannot search refuses (git's exit status ignored)" case_base_unsearchable \
    "says-git-could-not-search names-the-test exits-1 not-called-verified" \
    '[[ $rc -le 1 ]] || die' 'true || die'
  mprove "a head git cannot search is not 'the tests do not exist' (git's exit status ignored)" case_head_unsearchable \
    "says-git-could-not-search not-called-nonexistent" \
    '[[ $rc -le 1 ]] || die' 'true || die'
fi

BASE_SHA=$(git -C "$ROOT" rev-parse origin/master 2>/dev/null)
if [[ -z "$BASE_SHA" ]]; then echo "  SKIP  no origin/master to resolve names against"; exit 0; fi

# Stand in for velo-dispatch's environment: `y` reads the spec, die/ok report.
run_case() {   # $1 = json for tests.fail_to_pass
  local spec="$TMPD/spec.json"
  printf '{"tests":{"fail_to_pass":%s}}\n' "$1" > "$spec"
  ISSUE=9999
  y() { python3 -c "
import json,sys
d=json.load(open('$spec'))
for p in '$1'.split('.'):
    d = d.get(p) if isinstance(d,dict) else None
print('' if d is None else (json.dumps(d) if isinstance(d,(list,dict)) else d))
" 2>/dev/null; }
  die()  { echo "DIED: $1"; return 1; }
  ok()   { echo "OK: $1"; }
  warn() { echo "WARN: $1"; }
  ( eval "$BLOCK" ) 2>&1
}

check() {  # label, output, must-contain
  if grep -qF -- "$3" <<<"$2"; then echo "  PASS  $1"
  else echo "  FAIL  $1: output lacked '$3'"; echo "$2" | sed 's/^/          /'; FAILURES=$((FAILURES+1)); fi
}

# The exact spec that landed 6 commits while gating nothing. Since #2096 this
# WARNS rather than refusing — the refusal moved to velo-pr-gate — but it must
# still SAY SO, and still name which ones. A silent pass here would mean the
# author never learns the names are undefined.
OUT=$(run_case '["enforced_files_covers_every_executable_sql_doc","ungated_block_register_matches_reality"]')
check "#1958's real names are reported" "$OUT" "not yet defined"
check "the report lists which ones" "$OUT" "enforced_files_covers_every_executable_sql_doc"
check "and points at the merge-time gate" "$OUT" "velo-pr-gate"
if grep -q 'DIED' <<<"$OUT"; then
  echo "  FAIL  dispatch still REFUSES an undefined name — #2096 moved this to merge time,"
  echo "        and refusing here forces red master or an already-passing test."
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  dispatch warns rather than refusing (#2096)"
fi

# A name that does exist must pass, and must be counted as already defined.
OUT=$(run_case '["test_enforced_docs_sql_gate"]')
check "a real test name passes" "$OUT" "OK: fail_to_pass: 1 name(s) declared, 1 already defined"

# Mixed: one real, one fake — the fake must still be named.
OUT=$(run_case '["test_enforced_docs_sql_gate","totally_invented_test_name"]')
check "one bad name among good ones is reported" "$OUT" "totally_invented_test_name"

# An empty list declares no gate: nothing to validate, and NOT an error. Four
# open specs are in exactly this state today.
OUT=$(run_case '[]')
if grep -q 'DIED' <<<"$OUT"; then
  echo "  FAIL  an empty fail_to_pass was treated as an error"; FAILURES=$((FAILURES+1))
else
  echo "  PASS  empty fail_to_pass is skipped, not refused"
fi

# A name that appears only as a MENTION (a comment, another spec) is not a test.
# The check greps for 'fn <name>(' precisely so a stray string cannot satisfy it.
OUT=$(run_case '["velo_dispatch"]')
check "a mere mention does not count as a definition" "$OUT" "not yet defined"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all fail_to_pass checks passed"

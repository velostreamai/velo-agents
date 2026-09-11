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
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$(cd "$HERE/.." && pwd)/bin/velo-dispatch"
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
  die() { echo "DIED: $1"; return 1; }
  ok()  { echo "OK: $1"; }
  ( eval "$BLOCK" ) 2>&1
}

check() {  # label, output, must-contain
  if grep -qF -- "$3" <<<"$2"; then echo "  PASS  $1"
  else echo "  FAIL  $1: output lacked '$3'"; echo "$2" | sed 's/^/          /'; FAILURES=$((FAILURES+1)); fi
}

# The exact spec that landed 6 commits while gating nothing.
OUT=$(run_case '["enforced_files_covers_every_executable_sql_doc","ungated_block_register_matches_reality"]')
check "#1958's real names are refused" "$OUT" "DO NOT EXIST"
check "the refusal lists which ones" "$OUT" "enforced_files_covers_every_executable_sql_doc"

# A name that does exist must pass.
OUT=$(run_case '["test_enforced_docs_sql_gate"]')
check "a real test name passes" "$OUT" "OK: fail_to_pass: 1 test(s) exist"

# Mixed: one real, one fake — the fake must still be caught.
OUT=$(run_case '["test_enforced_docs_sql_gate","totally_invented_test_name"]')
check "one bad name among good ones is caught" "$OUT" "totally_invented_test_name"

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
check "a mere mention does not count as a definition" "$OUT" "DO NOT EXIST"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all fail_to_pass checks passed"

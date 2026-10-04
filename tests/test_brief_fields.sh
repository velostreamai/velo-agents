#!/bin/bash
# Brief BRANCH/WORKTREE extraction (#2004, hardened twice by review).
#
# Both regressions this pins were found by the reviewer, not by me, and both
# were in the SAME check on consecutive rounds:
#   round 1 — only `BRANCH:` was matched, so the five `## Branch` briefs were
#             silently skipped: a check that reported success for something it
#             never examined.
#   round 2 — the heading form puts BOTH declarations on one prose line, and the
#             helper returned the whole sentence, so with the new hard-fail all
#             five became undispatchable — a false refusal, which sends an
#             operator to hand-roll a nohup and bypass every gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s: %s\n' "$1" "$2"
          else printf '  FAIL  %s: got %s, want %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); fi; }

# Per run, not a fixed /tmp path: several agents run this suite at once on one host.
BH=$(mktemp); trap 'rm -f "$BH"' EXIT
python3 - "$ROOT/bin/velo-dispatch" > "$BH" <<'PYX' || exit 1
import pathlib, sys
# Extraction is by name and that is brittle: a helper the extracted functions
# CALL but which is not listed here stays undefined, so they return empty — a
# silent wrong answer, not an error. That happened with path_token (#2027
# round-3). Fail loudly instead of testing a crippled copy.
src = pathlib.Path(sys.argv[1]).read_text()
wanted = ["brief_field", "brief_heading_line", "path_token",
          "path_token_count", "brief_heading_branch", "brief_heading_worktree"]
missing = [f for f in wanted if f + "() {" not in src]
if missing:
    sys.exit("test_brief_fields: velo-dispatch no longer defines %s — update "
             "the extraction list; do not run without them" % missing)
for fn in wanted:
    i = src.index(fn + "() {"); j = src.index("\n}\n", i) + 3
    print(src[i:j])
PYX

source "$BH"

echo "heading form — all five tracked briefs must parse to a TOKEN, not a sentence"
for n in 1934 1937 1946 1948 1949; do
  b="$ROOT/tasks/$n-brief.md"
  [[ -f "$b" ]] || { echo "  SKIP  #$n brief absent"; continue; }
  BRIEF="$b" ; export BRIEF
  check "#$n worktree" "$(brief_heading_worktree)" "$HOME/RustroverProjects/velostream-$n"
  # branch must be one token with no spaces
  bb=$(brief_heading_branch)
  check "#$n branch is a token" "$(grep -cE '^[^[:space:]]+$' <<<"$bb")" "1"
done

echo "P2 regressions (#2027 round 4)"
TMP2=$(mktemp)
printf '## Branch\nfix/x — cut from `~/a/old-tree`, work in `~/a/velostream-2027`\n' > "$TMP2"
BRIEF="$TMP2"; export BRIEF
# Prose naming several paths cannot be disambiguated. Guessing produced a false
# refusal; empty means "skip the comparison", which the caller warns about.
check "ambiguous prose -> skip not guess" "$(brief_heading_worktree)" ""
printf '## Worktree\n/tmp/trees,archive/wt\n' > "$TMP2"
check "comma is POSIX-legal in a path" "$(brief_heading_worktree)" "/tmp/trees,archive/wt"
printf '## Worktree\n/tmp/build(1)/wt\n' > "$TMP2"
check "paren is POSIX-legal in a path"  "$(brief_heading_worktree)" "/tmp/build(1)/wt"
printf '## Worktree\n`~/a/wt`.\n' > "$TMP2"
check "trailing punctuation stripped"   "$(brief_heading_worktree)" "$HOME/a/wt"
rm -f "$TMP2"

echo "declared-but-empty must refuse, not skip (#2027 round 5)"
TMP3=$(mktemp)
printf '## Worktree\nthe usual place, see below\n\n## Branch\nfix/x — from ~/a/one into ~/b/two\n' > "$TMP3"
BRIEF="$TMP3"; export BRIEF
# A DECLARED worktree yielding no path is malformed, not ambiguous. It must never
# reach the ambiguity skip — that would be a check passing without examining
# anything, which is the failure this whole PR exists to prevent.
check "declared Worktree with no path -> empty" "$(brief_heading_worktree)" ""
check "and the declaration IS present"          "$([[ -n "$(brief_heading_line Worktree)" ]] && echo yes || echo no)" "yes"
check "Branch prose is ambiguous (2 paths)"     "$(path_token_count "$(brief_heading_line Branch)")" "2"
rm -f "$TMP3"

echo "colon form"
TMP=$(mktemp); printf 'BRANCH: fix/9-auto\nWORKTREE: /tmp/wt-9\n' > "$TMP"
BRIEF="$TMP"; export BRIEF
check "colon branch"   "$(brief_field BRANCH)"   "fix/9-auto"
check "colon worktree" "$(brief_field WORKTREE)" "/tmp/wt-9"
printf '## Branches\nnot-a-branch\n' > "$TMP"
check "plural heading does NOT match" "$(brief_heading_branch)" ""
rm -f "$TMP"

# The label is matched case-insensitively, so it must be STRIPPED that way too.
# It was not: grep -i accepted `Branch:` while the sed stripped only literal
# `BRANCH:`, so the value came back as "Branch: fix/x" and never equalled the
# branch being cut — every ordinary-markdown brief undispatchable, with a
# refusal that printed the two sides looking identical.
#
# This suite did not catch it because every case above writes the label in the
# one casing the sed happened to expect. Found in the field, on #1918.
echo "label casing (#1918)"
TMP=$(mktemp)
printf 'Branch: `fix/1918-expr-output-names`\nWorktree: `/tmp/velostream-1918`\n' > "$TMP"
BRIEF="$TMP"; export BRIEF
check "Mixed-case Branch: strips its label"   "$(brief_field BRANCH)"   "fix/1918-expr-output-names"
check "Mixed-case Worktree: strips its label" "$(brief_field WORKTREE)" "/tmp/velostream-1918"
printf 'branch: fix/all-lower\nworktree: /tmp/wt-lower\n' > "$TMP"
check "all-lower branch: strips its label"    "$(brief_field BRANCH)"   "fix/all-lower"
check "all-lower worktree: strips its label"  "$(brief_field WORKTREE)" "/tmp/wt-lower"
# A value may legitimately contain a colon; splitting on the FIRST one only.
printf 'WORKTREE: C:/src/velostream-9\n' > "$TMP"
check "a colon inside the value survives"     "$(brief_field WORKTREE)" "C:/src/velostream-9"
rm -f "$TMP"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all brief-field checks passed"

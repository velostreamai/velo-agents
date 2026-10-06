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
BH=$(mktemp); LD=$(mktemp -d); trap 'rm -f "$BH"; rm -rf "$LD"' EXIT
python3 - "$ROOT/bin/velo-dispatch" > "$BH" <<'PYX' || exit 1
import pathlib, sys
# Extraction is by name and that is brittle: a helper the extracted functions
# CALL but which is not listed here stays undefined, so they return empty — a
# silent wrong answer, not an error. That happened with path_token (#2027
# round-3). Fail loudly instead of testing a crippled copy.
src = pathlib.Path(sys.argv[1]).read_text()
wanted = ["brief_prose", "brief_field", "brief_heading_line", "path_token",
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

# ---- the lint's validation rule (#2380) ---------------------------------------
#
# The lint demanded `cargo (check|nextest)` in EVERY brief, so a no-code analysis
# stage, or an .agents/-only tooling brief, had to mention cargo only to say it
# did not need it. These drive the block EXTRACTED from the shipped velo-dispatch
# between its markers — not a copy of the rule, which would keep passing after the
# real one changed.
echo "brief lint: validation (spec §7)"
LINT_BLOCK=$(sed -n '/^# >>> velo-brief-lint/,/^# <<< velo-brief-lint/p' "$ROOT/bin/velo-dispatch")
if [[ -z "$LINT_BLOCK" ]]; then
  echo "  FAIL  could not extract the brief lint from velo-dispatch — deleted, renamed or restructured."
  echo "        The spec checklist would stop running and nothing here would notice."
  exit 1
fi
# The lint block READS the fence-masked brief but does not define the masker: brief_prose
# lives above it because brief_heading_line needs it before the lint runs. Take the
# shipped function (sourced from the extraction above), never a copy of it.
PROSE_FN=$(declare -f brief_prose)
if [[ -z "$PROSE_FN" ]]; then
  echo "  FAIL  brief_prose is not defined — the lint block cannot run without it."
  exit 1
fi
printf '#!/bin/bash\nok() { echo "OK: $1"; }\n%s\n%s\n' "$PROSE_FN" "$LINT_BLOCK" > "$LD/lint.sh"

# "<exit status>|<output on one line>": a function called inside $(...) cannot set
# a variable in this shell, so the status travels with the output.
lint() {   # <brief text>
  printf '%s' "$1" > "$LD/brief.md"
  local out rc
  out=$(BRIEF="$LD/brief.md" HOME=/h bash "$LD/lint.sh" 2>&1); rc=$?
  printf '%s|%s' "$rc" "$(tr '\n' ' ' <<<"$out")"
}
verdict() {   # <label> <want rc> <want substring> <brief text>
  local got rc out
  got=$(lint "$4"); rc=${got%%|*}; out=${got#*|}
  if [[ "$rc" == "$2" && "$out" == *"$3"* ]]; then
    printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s: rc=%s (want %s), wanted %q in: %s\n' "$1" "$rc" "$2" "$3" "${out:0:320}"
    FAILURES=$((FAILURES+1))
  fi
}
# Every brief below starts from this body, which satisfies every OTHER rule of the
# lint (worktree, no-cd, STOP, incremental commits, commit authorization); only the
# validation shape varies.
BODY=$'WORKTREE: /w\nDo NOT cd into it.\nSTOP and report if blocked.\nCommit after each step.\nYou may commit. Do NOT push.\n'
PASS_MSG="satisfies the spec checklist"
NEED_CMDS="no validation commands (spec §7)"
NEED_SECTION="no '## Validation' section with content (spec §7)"

echo "  a brief that changes code still names its commands"
verdict "cargo check passes"                            0 "$PASS_MSG"  "${BODY}cargo check --no-default-features"$'\n'
verdict "cargo nextest passes"                          0 "$PASS_MSG"  "${BODY}cargo nextest run foo"$'\n'
verdict ".agents/tests/run.sh passes (tooling brief)"   0 "$PASS_MSG"  "${BODY}bash .agents/tests/run.sh"$'\n'
verdict "no validation commands is refused"             1 "$NEED_CMDS" "$BODY"
verdict "a Validation heading alone does not satisfy a code brief" \
                                                        1 "$NEED_CMDS" "${BODY}"$'\n## Validation\nrun the tests\n'
verdict "'no code' in PROSE does not relax the lint" \
                                                        1 "$NEED_CMDS" "${BODY}There must be no code path that skips the check. If no code change is needed, STOP."$'\n'
verdict "'analysis only' in PROSE does not relax the lint" \
                                                        1 "$NEED_CMDS" "${BODY}This is analysis only for the first half."$'\n'

echo "  a stage that changes NO code needs the section, not cargo"
verdict "'ANALYSIS ONLY' title + Validation section passes without cargo" \
                                                        0 "$PASS_MSG"  $'# #9 — Stage-1 ANALYSIS ONLY: x\n'"${BODY}"$'\n## Validation\n\nProve you changed nothing.\n'
verdict "'THIS TASK WRITES NO CODE' heading + Validation section passes" \
                                                        0 "$PASS_MSG"  $'## THIS TASK WRITES NO CODE\n'"${BODY}"$'\n## Validation\nGround each claim with grep.\n'
verdict "'READ-ONLY analysis' title + Validation section passes" \
                                                        0 "$PASS_MSG"  $'# #9 — Stage 1 READ-ONLY analysis: x\n'"${BODY}"$'\n## Validation commands\ngrep -n x y\n'
verdict "a numbered '## 7. Validation commands' section counts" \
                                                        0 "$PASS_MSG"  $'# #9 — ANALYSIS ONLY\n'"${BODY}"$'\n## 7. Validation commands\ngrep -n x y\n'
verdict "no Validation section is refused" \
                                                        1 "$NEED_SECTION" $'# #9 — Stage-1 ANALYSIS ONLY: x\n'"${BODY}"
verdict "an EMPTY Validation section is refused" \
                                                        1 "$NEED_SECTION" $'## THIS TASK WRITES NO CODE\n'"${BODY}"$'\n## Validation\n\n## Logging\nagent.log\n'
verdict "'Invalidation' is not a Validation section" \
                                                        1 "$NEED_SECTION" $'# #9 — ANALYSIS ONLY\n'"${BODY}"$'\n## Invalidation rules\nsome text\n'
verdict "every other rule still applies to a no-code stage (STOP)" \
                                                        1 "no STOP conditions (spec §5)" \
  $'# #9 — ANALYSIS ONLY\nWORKTREE: /w\nDo NOT cd into it.\nCommit after each step.\nYou may commit. Do NOT push.\n\n## Validation\nx\n'

# A heading QUOTED inside a fenced code block is not a heading (#2380 round 2). The lint
# read the raw file, so a code brief that showed what an analysis brief says dropped its
# cargo requirement, and an analysis brief whose only "## Validation" sat in a fence
# passed with no section at all. ONE masking step (brief_prose) feeds every heading scan.
FB='```'; FT='~~~'
ANA=$'# #9 — ANALYSIS ONLY\n'"$BODY"
echo "  a heading quoted inside a fence is not a heading"
verdict "'## ANALYSIS ONLY' quoted in a backtick fence does not relax a code brief" \
                                                        1 "$NEED_CMDS" \
  "${BODY}"$'\nAn analysis brief declares itself like this:\n'"$FB"$'\n## ANALYSIS ONLY\n'"$FB"$'\n\n## Validation\nrun the tests\n'
verdict "'## ANALYSIS ONLY' quoted in a tilde fence does not relax a code brief" \
                                                        1 "$NEED_CMDS" \
  "${BODY}"$'\nAn analysis brief declares itself like this:\n'"$FT"$'\n## ANALYSIS ONLY\n'"$FT"$'\n\n## Validation\nrun the tests\n'
verdict "a '## Validation' that exists only inside a backtick fence is not a section" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\nThe section looks like this:\n'"$FB"$'\n## Validation\nprove it\n'"$FB"$'\n'
verdict "a '## Validation' that exists only inside a tilde fence is not a section" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\nThe section looks like this:\n'"$FT"$'\n## Validation\nprove it\n'"$FT"$'\n'

echo "  the fence rules are CommonMark's, not 'anything with backticks'"
verdict "a heading AFTER a closed fence is a heading again" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n'"$FB"$'\nsome text\n'"$FB"$'\n\n## Validation\ngrep -n x y\n'
verdict "a tilde line does not close a backtick fence" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n'"$FT"$'\n## Validation\nprove it\n'"$FB"$'\n'
verdict "a shorter fence line does not close a longer fence" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n````\n'"$FB"$'\n## Validation\nprove it\n````\n'
verdict "an opener with an info string opens, a closer with one does not close" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'bash\n'"$FB"$' bash\n## Validation\nprove it\n'"$FB"$'\n'
verdict "four spaces of indent is an indented code block, not a fence" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n    '"$FB"$'\n\n## Validation\ngrep -n x y\n'
verdict "a line that starts with an inline triple-backtick span is not an opener" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n'"$FB"$'grep -n x y'"$FB"$' is the check.\n\n## Validation\ngrep -n x y\n'
# A TAB in the leading whitespace reaches column 4 at once (CommonMark), so such a line is
# indented code, like four spaces — never an opener or a closer. extract_attack in
# velo-gate-run reads the same rule (test_gate_run.sh, sc_attack_shapes).
verdict "a tab-indented line is indented code, not a fence opener" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n\t'"$FB"$'\n\n## Validation\ngrep -n x y\n'
verdict "a tab-indented line does not close a fence" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n\t'"$FB"$'\n## Validation\nprove it\n'"$FB"$'\n'
verdict "spaces then a tab do not close a fence either" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n \t'"$FB"$'\n## Validation\nprove it\n'"$FB"$'\n'
verdict "three spaces then a tab do not close a fence either" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n   \t'"$FB"$'\n## Validation\nprove it\n'"$FB"$'\n'
# A closer may be followed only by spaces and tabs (and the CR of a CRLF line).
verdict "a closer followed by a non-breaking space does not close" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n'"$FB"$'\302\240\n## Validation\nprove it\n'"$FB"$'\n'
verdict "a closer followed by a form feed does not close" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n'"$FB"$'\f\n## Validation\nprove it\n'"$FB"$'\n'
verdict "a closer followed by a vertical tab does not close" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\n'"$FB"$'\v\n## Validation\nprove it\n'"$FB"$'\n'
verdict "a closer followed by spaces and tabs does close" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n'"$FB"$'\nx\n'"$FB"$'  \t \n\n## Validation\ngrep -n x y\n'
verdict "an unclosed fence runs to the end of the brief" \
                                                        1 "$NEED_SECTION" \
  "${ANA}"$'\n'"$FB"$'\nnever closed\n\n## Validation\ngrep -n x y\n'
verdict "a CRLF closing fence closes" \
                                                        0 "$PASS_MSG" \
  $'# #9 — ANALYSIS ONLY\r\n'"${BODY//$'\n'/$'\r\n'}"$'\r\n'"$FB"$'\r\n## Validation\r\nprove it\r\n'"$FB"$'\r\n\r\n## Validation\r\ngrep -n x y\r\n'

echo "  masking keeps fenced text as CONTENT (it is hidden from headings, not deleted)"
verdict "a fenced block of commands under a real Validation heading is its content" \
                                                        0 "$PASS_MSG" \
  "${ANA}"$'\n## Validation\n'"$FB"$'\ngrep -n x y\n'"$FB"$'\n'
verdict "a code brief whose only command sits in a fence still names its commands" \
                                                        0 "$PASS_MSG" \
  "${BODY}"$'\n'"$FB"$'\ncargo check --no-default-features\n'"$FB"$'\n'

echo "  brief_heading_line reads the same masked text (a fenced decoy is not the declaration)"
FZ=$(mktemp)
printf '%s\n' '```' '## Worktree' '/tmp/decoy' '```' '' '## Worktree' '/tmp/real' > "$FZ"
BRIEF="$FZ"; export BRIEF
check "a fenced '## Worktree' decoy loses to the real section"  "$(brief_heading_worktree)" "/tmp/real"
printf '%s\n' '~~~' '## Branch' 'fix/decoy' '~~~' '' '## Branch' 'fix/real' > "$FZ"
check "a fenced '## Branch' decoy loses to the real section"    "$(brief_heading_branch)"   "fix/real"
printf '%s\n' '```' '## Worktree' '/tmp/decoy' '```' > "$FZ"
check "a heading that exists only inside a fence declares nothing" "$(brief_heading_line Worktree)" ""
check "brief_prose keeps every line (masks, never deletes)" \
  "$(brief_prose | wc -l | tr -d ' ')" "$(wc -l < "$FZ" | tr -d ' ')"
rm -f "$FZ"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all brief-field checks passed"

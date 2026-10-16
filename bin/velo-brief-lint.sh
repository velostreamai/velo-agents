#!/bin/bash
# velo-brief-lint.sh — the brief-completeness lint, ONE definition for every tool that judges a
# brief. velo-dispatch refuses a brief on it; velo-spec-review runs it BEFORE it attests one, so a
# brief that dispatch would refuse is never certified (2026-10-11: "ok reviewed" was printed for
# briefs that dispatch then refused three times in one session).
#
# SOURCED, never executed. Sourcing sets no variable and runs nothing:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/velo-brief-lint.sh"
#   velo_brief_lint <brief-file> || exit 1
#
# velo_brief_lint prints the BRIEF INCOMPLETE block to stderr and returns 1 when a rule fails. It
# returns 0 and prints nothing otherwise: what a pass says is the caller's to say. It needs no
# helper from its callers (no ok, no die), so it sources cleanly into velo-spec-review as well.
#
# brief_prose lives here, not beside the BRANCH/WORKTREE readers in velo-dispatch, because the lint
# and those readers must mask fenced blocks with the same grammar, and this file is reachable from
# both callers.

# A heading inside a fenced code block is not a heading. A brief that QUOTES one — a
# template, an example of what an analysis brief says — must not be read as declaring
# it: "## ANALYSIS ONLY" quoted in a fence dropped the cargo requirement from a code
# brief, and a "## Validation" that existed only inside a fence satisfied the section
# check (#2380). Every heading / section scan below reads THIS, not the raw file.
#
# Fenced lines are MASKED (four spaces in front), not deleted: a Validation section
# whose content IS a fenced block of commands still has content, and the line count
# and order are unchanged. CommonMark rules: an opener is up to three SPACES of indent
# then 3+ backticks or tildes (a backtick opener cannot carry a backtick in its info
# string, so an inline ```x``` is not one); only a line of the SAME character, at least
# as long, with nothing after it but spaces, tabs (and a CR) closes it; an unclosed fence
# runs to the end of the brief. A TAB in the leading whitespace reaches column 4 at once,
# so such a line is indented code — never an opener or a closer — like four spaces
# (velo-gate-run's extract_attack reads the same grammar). `LABEL:` declarations
# (brief_field) and the command greps keep reading the raw file on purpose —
# declarations and commands are written in fences.
brief_prose() {
  awk '
    {
      ind = 0
      while (substr($0, ind + 1, 1) == " ") ind++
      rest = substr($0, ind + 1)
      ch = substr(rest, 1, 1)
      run = 0
      if (ind <= 3 && (ch == "`" || ch == "~"))
        while (substr(rest, run + 1, 1) == ch) run++
      if (fch == "") {
        if (run >= 3 && (ch == "~" || index(substr(rest, run + 1), "`") == 0)) {
          fch = ch; flen = run
          print "    " $0
        } else print $0
        next
      }
      if (ch == fch && run >= flen && substr(rest, run + 1) ~ /^[ \t\r]*$/) fch = ""
      print "    " $0
    }' "$BRIEF"
}

# >>> velo-brief-lint (extracted verbatim by tests/test_brief_fields.sh)
# spec §7, validation. WHAT it must contain depends on whether the stage changes code:
#   - a brief that changes code names the commands that prove it: `cargo check|nextest`,
#     or `.agents/tests/run.sh` for an .agents/-only tooling change (which has no
#     Rust to build, so had to mention cargo only to say it was not needed);
#   - a stage that changes NO code (analysis) runs no build, but the section must
#     still EXIST and say something: how its findings are checked is what an
#     analysis validates (see 2006-brief.md: "prove you changed nothing", "ground
#     each claim").
# "No code" is read from a HEADING — the title or a section — the way the real
# analysis briefs declare it ("Stage-1 ANALYSIS ONLY", "THIS TASK WRITES NO CODE",
# "READ-ONLY analysis"). In prose it would relax the lint for an implementation
# brief that merely says "no code path" or "if no code change is needed, STOP".
# The heading must be a validation heading — `## Validation`, `## 7. Validation
# commands` — not any heading that contains the letters ("## Invalidation").
#
# Both heading scans read BRIEF_PROSE — the brief with its fenced blocks masked
# (brief_prose, above) — so a heading QUOTED inside a fence is neither a no-code
# declaration nor a Validation section. The command greps below stay on the raw
# file: the commands are written inside fences.
brief_has_validation_section() {   # a Validation heading with something under it
  awk '
    tolower($0) ~ /^#+[ \t]+([0-9]+[.)]?[ \t]+)?validation/ { g = 1; next }
    /^#/ { g = 0; next }
    g && NF { found = 1; exit }
    END { exit !found }' <<<"$BRIEF_PROSE"
}
velo_brief_lint() {   # $1 = the brief. 0 when complete; 1 with the BRIEF INCOMPLETE block on stderr
  local BRIEF="$1" BRIEF_PROSE MISSING=()
  BRIEF_PROSE=$(brief_prose)
grep -qi "worktree" "$BRIEF"                  || MISSING+=("no WORKTREE path (spec §1)")
grep -qiE "do not.*cd|don't.*cd" "$BRIEF"     || MISSING+=("no 'do NOT cd' instruction (spec §1)")
grep -qiE "STOP and report|STOP —|STOP if"    "$BRIEF" || MISSING+=("no STOP conditions (spec §5)")
grep -qiE "commit incrementally|commit after each" "$BRIEF" || MISSING+=("no incremental-commit rule (spec §12) — a timeout will lose all work")
if grep -qiE '^#+[[:space:]].*(analysis[ -]only|no[ -]code([^[:alpha:]]|$)|read-only[ -]analysis)' <<<"$BRIEF_PROSE"; then
  brief_has_validation_section \
    || MISSING+=("no '## Validation' section with content (spec §7) — a no-code stage runs no build, but still says how its findings are checked")
else
  grep -qiE "cargo (check|nextest)|\.agents/tests/run\.sh" "$BRIEF" \
    || MISSING+=("no validation commands (spec §7) — a brief that changes code names 'cargo check|nextest' (or .agents/tests/run.sh for an .agents/-only change); a stage that changes NO code says so in a heading ('## THIS TASK WRITES NO CODE', 'ANALYSIS ONLY') and then needs a '## Validation' section instead")
fi
grep -qiE "do not commit|may commit|commit and push|do not push|do not open a pr|authorized to (commit|push)" "$BRIEF" \
  || MISSING+=("no explicit commit/push authorization (spec §8) — the brief is the only thing telling a worker what it may do")
if grep -qiE "\.sql|SELECT .* FROM" "$BRIEF"; then
  grep -q "SQL_GRAMMAR_RULES\|PARSER_GRAMMAR" "$BRIEF" \
    || MISSING+=("brief writes SQL but cites no grammar reference (spec §6)")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  printf '\n\033[31mBRIEF INCOMPLETE:\033[0m %s\n' "$BRIEF" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  printf '\nSee %s\n\n' "$HOME/.agents/rules/velo-brief-spec.md" >&2
  return 1
fi
return 0
}
# <<< velo-brief-lint

# >>> velo-brief-ste (extracted verbatim by tests/test_brief_ste.sh)
# spec §13, instruction style (ASD-STE100). ADVISORY: it prints warnings and always returns 0.
# It does not refuse a brief until its false-positive rate on real briefs is known.
#
# A STEP is a numbered list item in prose: `1. Do X` or `1) Do X`, at most three spaces of
# indent. Fenced lines are skipped (brief_prose masks them). A line under a step that is
# indented and is not a new item or a heading continues that step. Bullets are not checked:
# briefs use them for facts and lists, and STE limits only the procedural sentence.
#
# Each step is checked for:
#   - more than 20 words. An inline code span counts as ONE word (it is a name);
#   - more than one sentence (". " then a capital letter or a backtick);
#   - a chained action: ", then", "; then", " and then".
velo_brief_ste_warn() {   # $1 = the brief. Prints warnings to stderr. Always returns 0.
  local BRIEF="$1" out
  out=$(brief_prose | awk '
    function flush(   t, n, why) {
      if (step == "") return
      t = step
      gsub(/`[^`]*`/, "CODE", t)          # a code span is one word
      n = split(t, w, /[ \t]+/)
      why = ""
      if (n > 20) why = why sprintf("%d words (max 20); ", n)
      if (t ~ /[.!?][ \t]+[A-Z]/) why = why "more than one sentence; "
      if (tolower(t) ~ /(, then |; then | and then )/) why = why "chained action (\"then\"); "
      if (why != "") {
        sub(/; $/, "", why)
        printf "  - line %d: %s\n      %s\n", sline, why, substr(step, 1, 100)
      }
      step = ""
    }
    /^    / { flush(); next }                               # fenced: not prose
    /^ {0,3}[0-9]+[.)][ \t]+/ {
      flush(); sline = NR
      s = $0; sub(/^ *[0-9]+[.)][ \t]+/, "", s); step = s; next
    }
    step != "" && /^[ \t]+[^ \t]/ && !/^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ {
      s = $0; sub(/^[ \t]+/, "", s); step = step " " s; next
    }
    { flush() }
    END { flush() }')
  [[ -z "$out" ]] && return 0
  printf '\n\033[33mBRIEF STYLE (advisory, STE100 — spec §13):\033[0m %s\n' "$BRIEF" >&2
  printf '%s\n' "$out" >&2
  printf '  One action per step, imperative, max 20 words. Split the step; move the reason to a "Why" line.\n\n' >&2
  return 0
}
# <<< velo-brief-ste

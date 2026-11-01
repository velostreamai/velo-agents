#!/bin/bash
# guard-lib.sh - the command scanner the deny-* PreToolUse hooks share (docs/velo-task-spec.md R10, R15(i)).
# Sourced by deny-vanth-cleanup.sh, deny-pgrep-wait-loop.sh and deny-raw-launch.sh; never registered, never run. The hooks
# fail open when it is missing, so the guard is silently off until install.sh has put it beside them.
#
# A guard that greps the raw command text blocks `git commit -m "never run vanth prune"` and `gh pr create --body ...`.
# So the command is first reduced to its command-position text: one segment per line, where
#   - quoted text is dropped (a quoted span that is one plain word is kept, so "$HOME/bin/vanth" still names vanth),
#   - a backslash outside quotes is dropped and the character after it is plain word text (\vanth is vanth, \\vanth is
#     not, vanth\ prune is one word); a backslash-newline joins the lines,
#   - heredoc bodies and comments are dropped (a comment may hold an apostrophe that would otherwise swallow the rest),
#   - $( ), backticks, ( ), ; | & and newlines start a new segment, and the body of a $( ) inside double quotes is
#     scanned like any other command, because it runs.
# Anything the scanner cannot see (a string handed to bash -c or eval, a variable holding the program name, a script
# file) stays invisible: these hooks are guardrails against the orchestrating LLM's own mistakes, not isolation.
# Two limits of the scanner itself. A heredoc whose delimiter starts with anything but a letter, underscore, quote or
# backslash (<<2) is not recognised, so its body is scanned as commands (a false deny, never a miss). A segment keeps its
# first 1024 characters, which bounds the work on a 300 KB one-liner (quadratic without it: 66 s), so a command that follows
# more than 1 KB of VAR=value text in the same segment is not seen.

export LC_ALL=C
set -f   # command text is only ever word-split below, never glob-expanded

IFS= read -r -d '' GUARD_AWK <<'AWK'
function word() { return (qs && length(qb) > 0) ? qb : "\002" }
function put(t) { if (length(cur) < 1024) cur = cur t; prev = substr(t, length(t), 1) }
function brk() { if (cur != "") print cur; cur = ""; prev = "\n" }
function push(kind) { sp++; sk[sp] = kind; sd[sp] = 1; st = "N"; qb = ""; qs = 1 }
function pop() { sp--; st = "D"; qs = 0 }
function qadd(c, bad) { if (qs && length(qb) < 256 && c !~ bad) qb = qb c; else qs = 0 }
BEGIN { st = "N"; prev = "\n" }
{
  if (hdk > 0) {
    t = $0; if (hdt[hdk]) sub(/^\t+/, "", t)
    if (t == hdd[hdk]) { hdk++; if (hdk > hdn) { hdk = 0; hdn = 0 } }
    next
  }
  n = split($0 "\n", ch, "")
  for (i = 1; i <= n; ) {
    c = ch[i]; c1 = ch[i + 1]
    if (st == "S" || st == "A") {
      if (st == "A" && c == "\\") { qs = 0; i += 2; continue }
      if (c == "'") { put(word()); st = "N"; i++; continue }
      qadd(c, "[ \t\n&;|()<>`]"); i++; continue
    }
    if (st == "D") {
      if (c == "\\") { qs = 0; i += 2; continue }
      if (c == "\"") { put(word()); st = "N"; i++; continue }
      if (c == "$" && c1 == "(") { push("("); brk(); i += 2; continue }
      if (c == "`") { push("`"); brk(); i++; continue }
      qadd(c, "[ \t\n&;|()<>]"); i++; continue
    }
    if (ar > 0) { if (c == "(") ar++; else if (c == ")") ar--; put(c); i++; continue }
    if (c == "\\") { if (c1 != "\n") { put(c1 ~ /[ \t]/ ? "\002" : c1); prev = c } i += 2; continue }   # backslash-newline is deleted, as the shell does; any other escaped character is plain word text (\vanth is vanth) and never opens a comment or an ANSI-C quote
    if (c == "'") { st = (prev == "$") ? "A" : "S"; qb = ""; qs = 1; i++; continue }
    if (c == "\"") { st = "D"; qb = ""; qs = 1; i++; continue }
    if (c == "#" && prev ~ /[ \t\n&;|()]/) { i = n; continue }
    if (c == "(" && c1 == "(") { put("(("); ar = 2; i += 2; continue }   # (( and $(( alike: a << inside is a shift, not a heredoc
    if (c == "<" && c1 == "<" && ch[i + 2] == "<") { put("<<<"); i += 3; continue }
    if (c == "<" && c1 == "<") {
      j = i + 2; tab = 0
      if (ch[j] == "-") { tab = 1; j++ }
      while (ch[j] == " " || ch[j] == "\t") j++
      q = ch[j]; d = ""
      if (q ~ /[A-Za-z_'"\\]/) {
        if (q == "'" || q == "\"") { j++; while (j <= n && ch[j] != q && ch[j] != "\n") { d = d ch[j]; j++ } j++ }
        else { if (q == "\\") j++; while (j <= n && ch[j] !~ /[ \t\n&;|()<>]/) { d = d ch[j]; j++ } }
        hdn++; hdd[hdn] = d; hdt[hdn] = tab; i = j; continue
      }
    }
    if (c == "\n") { brk(); if (hdn > 0) hdk = 1; i++; continue }
    if (c == ";" || c == "|" || c == "&") { brk(); i++; continue }
    if (c == "`") { if (sp > 0 && sk[sp] == "`") pop(); brk(); i++; continue }
    if (c == "(") { if (sp > 0 && sk[sp] == "(") sd[sp]++; brk(); i++; continue }
    if (c == ")") { if (sp > 0 && sk[sp] == "(" && --sd[sp] == 0) pop(); brk(); i++; continue }
    put(c); i++
  }
}
END { brk() }
AWK

# guard_scan_payload: stdin is the PreToolUse JSON. Sets SEGS to the command-position segments of its Bash command, one
# per line. Fails, so that the caller allows, when jq is missing. Malformed JSON, no command and a payload for another
# tool all leave SEGS empty, which the caller also allows. The callers walk SEGS in this shell, never through a
# command substitution per segment: a 300 KB generated script has tens of thousands of segments, and a fork each took 10 s.
guard_scan_payload() {
  command -v jq >/dev/null 2>&1 || return 1
  SEGS=$(jq -r '.tool_input.command // empty' 2>/dev/null | /usr/bin/awk "$GUARD_AWK") || return 1
}

# guard_cmd_words SEGMENT: sets GW_KW (the control words stripped from the front, space separated) and GW (the command
# and its arguments). Skipped in front of the command: VAR=value, control words, and the wrappers below; after a wrapper
# the options and counts it takes (nice -n 10, timeout 30) go too. `for`, `select` and `done` end the segment: no
# command follows them. A wrapper option that takes a word (sudo -u neil) is not skipped: that form is not seen.
guard_cmd_words() {
  local w wrapped=0
  GW_KW=""; GW=()
  set -- $1
  while [ $# -gt 0 ]; do
    w=$1
    case $w in
      [A-Za-z_]*=*) ;;
      '!'|'{'|if|then|else|elif|do|while|until) GW_KW="$GW_KW $w" ;;
      for|select|done) GW_KW="$GW_KW $w"; return 0 ;;
      -*|[0-9]*) [ "$wrapped" = 1 ] || break ;;
      *) case ${w##*/} in
           command|builtin|exec|nohup|sudo|doas|env|nice|timeout|stdbuf|time|xargs|uv|uvx|pipx|run|tool) wrapped=1 ;;
           *) break ;;
         esac ;;
    esac
    shift
  done
  GW=("$@")
}

# guard_deny MESSAGE SEGMENT: the PreToolUse block. stderr goes back to the model, so it says what to do instead.
guard_deny() {
  printf '%s\nMatched: %s\n' "$1" "$(printf '%s' "$2" | tr -d '\002' | tr -s ' \t' ' ' | cut -c1-200)" >&2
  exit 2
}

#!/bin/bash
# velo-task M3c, bars B13 and B29 (hook half) (docs/velo-task-spec.md R10, R15(i)): the three PreToolUse deny hooks.
#
#   hooks/deny-vanth-cleanup.sh     denies `vanth prune` and `vanth restore`, in every command form it claims
#   hooks/deny-pgrep-wait-loop.sh   denies a hand-written `until/while pgrep` wait loop; `velo-task wait` passes
#   hooks/deny-raw-launch.sh        denies a raw `velo-openrouter-agent` or `codex exec` launch; `velo-dispatch` passes
#   hooks/guard-lib.sh              the command-position scanner the three share
#
# All three are guardrails against the orchestrating model's own mistakes, not isolation (R15(i)), and heuristics over command
# TEXT. An evasion the scanner cannot see (a bash -c string, a variable holding the program, a script file) is a known false
# negative: each is listed below and asserted ALLOWED, so closing a gap turns that line red and says to move it to the denied
# list. An accepted false positive is asserted DENIED the same way.
#
# Checks: t_vanth_denied/_wrappers/_control/_allowed/_false_negatives, t_pgrep_denied/_nesting/_allowed/_false_negatives,
# t_raw_denied/_allowed/_false_negatives, t_scanner (quoting, backslashes, heredocs, comments, substitutions), t_noglob, t_utf8, t_messages, t_failopen,
# t_scan_speed (CPU time, see t_scan_clock), t_readme_registration (the registration line in README.md, run as Claude Code
# would run it), t_hook_files, t_hook_docs (each pinned false negative is in the header and the README), t_install_hooks,
# t_install_exec_scope, t_install_pycache.
# Hooks run as Claude Code runs them: the PreToolUse JSON on stdin, exit 2 = block, exit 0 = allow.
#
# Every check is also proved RED on a mutated COPY of the code under test (tests/mutation-lib.sh): the repo's files are never
# edited, and a mutation whose anchor is not found exactly once is a failed proof, never a skip. B13's named mutant, "allow
# all", is the first proof of each hook.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
unset B14_BASH HOOK_CWD
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(/usr/bin/mktemp -d "$TMP_ROOT/velo-task-hooks.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
MUT_PATHS="hooks install.sh README.md"
. "$HERE/mutation-lib.sh"
. "$HERE/bash32-sweep.sh"   # the sweep that t_hook_files applies to the code under test
V=deny-vanth-cleanup.sh; P=deny-pgrep-wait-loop.sh; W=deny-raw-launch.sh

show() { printf '%s' "$1" | tr '\n' '~' | cut -c1-120; }
run_hook() {  # <hook> <command> [VAR=value...]: the hook as Claude Code runs it, the PreToolUse JSON on stdin; sets RC and ERR
  local hook=$1 cmd=$2
  shift 2
  ERR=$(cd "${HOOK_CWD:-$PWD}" && jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | env "$@" "$R/hooks/$hook" 2>&1 >/dev/null); RC=$?
}
deny()  { run_hook "$@"; [ "$RC" = 2 ] || bad "${1%.sh} should DENY (exit 2) but exited $RC: $(show "$2")"; }
allow() { run_hook "$@"; [ "$RC" = 0 ] || bad "${1%.sh} should ALLOW (exit 0) but exited $RC: $(show "$2")"; }
miss()  {  # <hook> <command> <why>: a known false negative, an evasion the scanner cannot see
  run_hook "$1" "$2"
  if [ "$RC" = 0 ]; then echo "note: known false negative ($3): $(show "$2")"
  else bad "${1%.sh} now denies a known false negative ($3): move it to the denied list: $(show "$2")"; fi
}
fpos()  {  # <hook> <command> <why>: an accepted false positive
  run_hook "$1" "$2"
  if [ "$RC" = 2 ]; then echo "note: accepted false positive ($3): $(show "$2")"
  else bad "${1%.sh} no longer denies an accepted false positive ($3): move it to the allowed list: $(show "$2")"; fi
}
cpu_run() {  # <timefile> <command...>: runs the command (stdin as given, output discarded); sets RC to its exit code and CPU to the user + system seconds it and its children used
  local tf=$1 u s fmt='%3U %3S'
  shift
  [ "${SCAN_CLOCK:-cpu}" != wall ] || fmt='%3R 0.000'   # the mutant the clock proof runs: wall time, which a loaded host stretches
  { TIMEFORMAT=$fmt; time "$@" >/dev/null 2>&1; } 2> "$tf"; RC=$?
  read -r u s < "$tf"
  [[ $u =~ ^[0-9]+\.[0-9]+$ && $s =~ ^[0-9]+\.[0-9]+$ ]] || { echo "FAILED: no CPU time was reported for $*: [$(cat "$tf")]"; exit 1; }
  CPU=$(/usr/bin/awk -v u="$u" -v s="$s" 'BEGIN { printf "%.3f", u + s }')
}
below() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }   # <a> < <b>, as numbers
install_tree() {  # a throwaway checkout (the real install.sh, the real hooks, one script) and its destination: sets src and dest from the caller's d, defines inst
  src="$d/src"; dest="$d/dest"
  mkdir -p "$src/bin" "$src/hooks" "$d/home" "$d/skills"
  cp "$R/install.sh" "$src/install.sh"
  cp "$R"/hooks/*.sh "$src/hooks/"
  printf '#!/bin/bash\n' > "$src/bin/stub"
  inst() { env -i HOME="$d/home" PATH=/usr/bin:/bin VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$d/skills" /bin/bash "$src/install.sh" "$@"; }
}

# ---- deny-vanth-cleanup.sh (B29, hook half) ----
t_vanth_denied() {  # vanth prune and vanth restore, in every form the hook claims
  local c
  for c in \
    'vanth prune' 'vanth restore' 'vanth prune --older-than 0 --yes' 'vanth --json prune' 'vanth prune --json' \
    'vanth --json restore --yes backup.tgz' 'vanth restore --yes backup.tgz' \
    '/Users/x/.agents/state/velo-task/venv/bin/vanth prune --yes' './venv/bin/vanth restore' \
    '~/.agents/state/velo-task/venv/bin/vanth restore' '"$HOME/.agents/state/velo-task/venv/bin/vanth" prune' \
    '"vanth" prune' "'vanth' prune" $'v\'a\'nth prune' \
    'python3 -m vanth prune' 'python -m vanth restore' '/opt/venv/bin/python3.12 -I -m vanth.cli restore --yes' \
    'python3 -mvanth prune' 'python3 -X utf8 -m vanth prune' 'python -W ignore -m vanth.__main__ prune' 'pypy3 -m vanth prune' \
    'python3 -Im vanth prune' 'python3 -IBm vanth.cli restore' \
    'VANTH_HOME=/tmp/x vanth prune' 'A=1 B="x" vanth prune' \
    'vanth restore --yes -- --help' 'vanth prune >/dev/null 2>&1' 'vanth prune &>/dev/null' 'vanth prune &' \
    'cd /tmp && vanth prune --yes' 'echo y | vanth prune --yes' 'true || vanth prune' 'vanth status; vanth prune' \
    $'echo hi\nvanth prune' 'out=$(vanth prune --yes)' 'echo "$(vanth prune)"' 'echo `vanth prune`' 'echo "`vanth prune`"' \
    '( vanth prune )' 'cat <(vanth prune)' 'case x in x) vanth prune ;; esac' \
    $'vanth \\\nprune --yes' $'van\\\nth prune' \
    '\vanth prune' 'v\anth prune' '\vanth --json restore' '\/usr/bin/vanth prune' '\python3 -m vanth prune' 'python3 -m \vanth prune' 'sudo \vanth prune'
  do deny $V "$c"; done
  [ "$BAD" = 0 ]
}
t_vanth_wrappers() {  # every wrapper the hook looks through, and the options and counts those wrappers take
  local c
  for c in \
    'command vanth prune' 'builtin command vanth prune' 'exec vanth prune' 'nohup vanth prune' 'sudo vanth prune' 'doas vanth prune' \
    'env vanth prune' 'env FOO=1 vanth prune' 'env -i vanth prune' '/usr/bin/env vanth prune' 'nice vanth prune' 'nice -n 10 vanth prune' \
    'timeout 30 vanth prune' 'timeout --signal=KILL 30 vanth prune' 'stdbuf -oL vanth prune' 'time vanth prune' \
    'xargs vanth prune' 'xargs -n 1 vanth prune' 'uv run vanth prune' 'uvx vanth prune' 'pipx run vanth prune' 'uv tool run vanth prune' \
    'uv run python3 -m vanth prune' 'sudo env FOO=1 nohup vanth restore' 'command -p vanth prune'
  do deny $V "$c"; done
  allow $V 'echo x >&2 vanth prune'   # the 2 of >&2 starts a segment of its own: a number is not a command to look through
  [ "$BAD" = 0 ]
}
t_vanth_control() {  # every control word the hook looks through
  local c
  for c in '! vanth prune' '{ vanth prune; }' 'if vanth prune; then :; fi' 'if true; then vanth prune; fi' \
           'if false; then :; else vanth prune; fi' 'if false; then :; elif vanth prune; then :; fi' \
           'for i in 1; do vanth prune; done' 'while vanth prune; do :; done' 'until vanth prune; do :; done'
  do deny $V "$c"; done
  [ "$BAD" = 0 ]
}
t_vanth_allowed() {  # look-alikes that must pass: other subcommands, help, the words in text, other programs
  local c
  for c in \
    'vanth status' 'vanth --json status job1' 'vanth prune --help' 'vanth prune -h' 'vanth restore --help' 'vanth --json prune --help' \
    'vanth' 'vanth --json' 'vanth help prune' 'vanth status prune' \
    'echo vanth prune' 'printf "%s\n" vanth prune' '# vanth prune' 'echo ok # vanth prune' \
    'git commit -m "deny vanth prune"' 'git commit -m "fix; vanth prune is gone"' \
    $'git commit -m "$(cat <<\'EOF\'\nnever run vanth prune\nEOF\n)"' \
    'grep -rn "vanth prune" docs/' 'gh pr create --title t --body "never run vanth prune or vanth restore"' \
    "echo 'vanth restore'" 'vanthd prune' 'my-vanth prune' 'vanth_prune' 'ls vanth-prune.txt' 'cat docs/vanth-restore.md' \
    'pip install vanth' 'uv pip install vanth==1.14.0' 'python3 -m vanth status' 'python3 -m vanth.server prune' \
    'python3 script.py vanth prune' 'python3 script.py -m vanth prune' 'python3 -c "print(1)" vanth prune' 'python3 -Im json.tool prune' \
    'until pgrep -f foo; do sleep 5; done' 'velo-task wait gate-1' 'velo-task status' 'echo ok' \
    '\\vanth prune' 'vanth\ prune' $'vanth\\\tprune' '"\vanth" prune' '\vanth status'
  do allow $V "$c"; done
  [ "$BAD" = 0 ]
}
t_vanth_false_negatives() {  # the evasions the hook cannot see, pinned
  local long
  long=$(printf 'x%.0s' $(seq 1 1100))
  miss $V "FOO=$long vanth prune" 'more than 1 KB of text in front of the command in one segment: the scanner keeps a segment'"'"'s first 1024 characters'
  miss $V 'bash -c "vanth prune"' 'a string handed to bash -c'
  miss $V "sh -c 'vanth restore'" 'a string handed to sh -c'
  miss $V 'eval "vanth prune"' 'a string handed to eval'
  miss $V 'V=vanth; $V prune' 'a variable holds the program'
  miss $V 'v=vanth; "$v" prune' 'a quoted variable holds the program'
  miss $V '"$(echo "vanth")" prune' 'the output of a command substitution names the program'
  miss $V 'alias vp="vanth prune"; vp' 'an alias'
  miss $V 'bash cleanup.sh' 'a script file that runs it'
  miss $V './cleanup.sh' 'a script file that runs it'
  miss $V 'find . -name x -exec vanth prune \;' 'find -exec'
  miss $V 'sudo -u neil vanth prune' 'a wrapper option that takes a word'
  miss $V 'env -u HOME vanth prune' 'a wrapper option that takes a word'
  miss $V 'timeout -s KILL 30 vanth prune' 'a wrapper option that takes a word'
  miss $V 'Vanth prune' 'a differently cased name on a case-insensitive volume'
  miss $V '>out vanth prune' 'a redirection in front of the command name'
  miss $V '2>&1 vanth prune' 'a redirection in front of the command name'
  miss $V '"/Users/me/My Venv/bin/vanth" prune' 'a quoted command path that contains a space'
  miss $V 'curl -X POST http://127.0.0.1:48217/cleanup' 'the HTTP route POST /cleanup, the other way to prune'
  miss $V 'python3 -c "from vanth.cli import main; main()" prune' 'python -c'
  miss $V 'VANTH_RETENTION_SECONDS=1 vanth status' 'automatic retention, which prunes with no subcommand'
  miss $V 'echo vanth | xargs -I{} {} prune' 'xargs substitution'
  [ "$BAD" = 0 ]
}

# ---- deny-pgrep-wait-loop.sh (B13) ----
t_pgrep_denied() {  # a literal pgrep loop is denied, in every shape the hook claims
  local c
  for c in \
    'until pgrep -f foo; do sleep 5; done' 'while pgrep -f foo >/dev/null 2>&1; do sleep 5; done' 'while ! pgrep -f foo; do sleep 2; done' \
    'until ! pgrep -x vanthd >/dev/null; do sleep 1; done' 'while [ -n "$(pgrep -f foo)" ]; do sleep 5; done' \
    'while true; do pgrep -f foo || break; sleep 5; done' $'while pgrep -f foo\ndo\n  sleep 5\ndone' $'until pgrep -f x\ndo sleep 1; done' \
    'cd /x && until /usr/bin/pgrep -f y; do sleep 1; done; echo done' \
    'until sudo pgrep -f x; do sleep 1; done' 'until env X=1 pgrep -f x; do sleep 1; done' 'time until pgrep -f x; do sleep 1; done' \
    'until pgrep -f "build step"; do sleep 1; done' 'until pgrep -fl x; do sleep 1; done' \
    'for i in 1 2; do until pgrep -f x; do sleep 1; done; done' 'r=$(until pgrep -f x; do sleep 1; done)' \
    '( while pgrep -f x; do sleep 1; done )' 'waitfor() { until pgrep -f "$1"; do sleep 1; done; }' \
    'while :; do if pgrep -f x; then sleep 1; else break; fi; done' 'while pgrep -f x | grep -q .; do sleep 1; done' \
    'while sleep 1; do pgrep -f x && continue; break; done' \
    'until \pgrep -f x; do sleep 1; done' 'until p\grep -f x; do sleep 1; done' 'while \pgrep -f x >/dev/null; do sleep 1; done' \
    'until sudo \pgrep -f x; do sleep 1; done' 'while true; do \pgrep -f x || break; sleep 5; done'
  do deny $P "$c"; done
  [ "$BAD" = 0 ]
}
t_pgrep_nesting() {  # which loops are open decides: while/until (W) and for/select (F) are tracked, and done closes the innermost
  deny  $P 'while true; do for i in 1 2; do sleep 1; done; pgrep -f x || break; done'
  deny  $P 'while true; do select x in a; do break; done; pgrep -f x || break; done'
  allow $P 'while true; do sleep 1; done; pgrep -f x'
  allow $P 'for i in 1; do pgrep -f x; done'
  allow $P 'for i in 1; do while true; do sleep 1; done; pgrep -f x; done'
  allow $P 'select x in a; do pgrep -f x; break; done'
  allow $P 'until velo-task wait a; do sleep 1; done; pgrep -f foo'
  allow $P 'while read l; do echo $l; done < f; pgrep -f foo'
  [ "$BAD" = 0 ]
}
t_pgrep_allowed() {  # velo-task wait, and everything that merely looks like a wait loop
  local c
  for c in \
    'velo-task wait gate-1' 'velo-task wait gate-1 gate-2' 'until velo-task wait gate-1; do sleep 5; done' \
    'pgrep -f foo' 'pgrep -f foo || echo none' 'if pgrep -f x; then echo up; fi' 'for p in $(pgrep -f foo); do kill $p; done' \
    'pgrep -f x | xargs kill' 'while read l; do echo $l; done < <(pgrep -f foo)' \
    'git commit -m "deny until pgrep loops"' 'echo "while pgrep -f x; do sleep 1; done"' $'cat <<EOF\nwhile pgrep -f x; do sleep 1; done\nEOF' \
    '# until pgrep -f x; do sleep 1; done' 'while true; do sleep 1; done' 'until pgrepx -f x; do sleep 1; done' 'until mypgrep -f x; do sleep 1; done' \
    'sleep 5' 'echo pgrep' 'vanth prune' 'vanth status' \
    'until pgrep\ -f x; do sleep 1; done' 'until \\pgrep -f x; do sleep 1; done' '\pgrep -f x'
  do allow $P "$c"; done
  [ "$BAD" = 0 ]
}
t_pgrep_false_negatives() {  # the evasions the hook cannot see, and its accepted false positive, pinned
  local long
  long=$(printf 'x%.0s' $(seq 1 1100))
  miss $P "until FOO=$long pgrep -f x; do sleep 1; done" 'more than 1 KB of text in front of the command in one segment'
  miss $P 'bash -c "until pgrep -f x; do sleep 1; done"' 'a loop in a string handed to bash -c'
  miss $P "sh -c 'while pgrep -f x; do sleep 1; done'" 'a loop in a string handed to sh -c'
  miss $P 'eval "until pgrep -f x; do sleep 1; done"' 'a loop in a string handed to eval'
  miss $P 'for i in $(seq 1 100); do pgrep -f x || break; sleep 1; done' 'a for loop polls'
  miss $P 'watch -n 5 pgrep -f x' 'watch polls'
  miss $P 'until ps aux | grep -q "[x]yz"; do sleep 1; done' 'ps piped to grep'
  miss $P 'while pidof x; do sleep 1; done' 'pidof'
  miss $P 'while kill -0 $PID 2>/dev/null; do sleep 1; done' 'kill -0'
  miss $P 'until [ -f /tmp/x.done ]; do sleep 1; done' 'a marker file'
  miss $P 'PGREP=pgrep; until $PGREP -f x; do sleep 1; done' 'a variable holds the program'
  miss $P 'bash wait.sh' 'a script file'
  miss $P 'until sudo -u neil pgrep -f x; do sleep 1; done' 'a wrapper option that takes a word'
  miss $P 'until >/dev/null pgrep -f x; do sleep 1; done' 'a redirection in front of the command name'
  fpos $P 'while read n; do for p in $(pgrep -f "$n"); do kill $p; done; done' 'a pgrep that only lists, inside a while body'
  [ "$BAD" = 0 ]
}

# ---- deny-raw-launch.sh (#31 part C): a raw worker or Codex launch outside velo-dispatch ----
t_raw_denied() {  # the worker runner and `codex exec` are denied in every command form the hook claims
  local c
  for c in \
    'nohup velo-openrouter-agent --model x --brief b &' 'env X=1 /abs/path/velo-openrouter-agent --model x' \
    '"$HOME/.agents/bin/velo-openrouter-agent" --model x' './bin/velo-openrouter-agent --model x' \
    'timeout 900 velo-openrouter-agent --model x' 'sudo velo-openrouter-agent --model x' 'nice -n 10 velo-openrouter-agent --model x' \
    'R=1 velo-openrouter-agent --model x' 'cd /tmp && velo-openrouter-agent --model x' \
    'velo-openrouter-agent --model x >/dev/null 2>&1' 'velo-openrouter-agent --model x &' \
    'echo x | velo-openrouter-agent --model x' 'true || velo-openrouter-agent --model x' 'velo-openrouter-agent --model x; echo done' \
    'if true; then velo-openrouter-agent --model x; fi' 'x=$(velo-openrouter-agent --model x)' $'echo hi\nvelo-openrouter-agent --model x' \
    'velo-openrouter-agent' 'velo-openrouter-agent --model x' \
    'codex exec "do the thing"' 'codex exec --dangerously-bypass-approvals-and-sandbox "brief"' \
    'codex -c a=b exec "do the thing"' 'codex -ca=b exec "do the thing"' 'codex --config a=b exec "do the thing"' \
    'codex --config=a=b exec "do the thing"' '/opt/homebrew/bin/codex exec "do the thing"' \
    'codex -m gpt-5 exec "do the thing"' 'codex -mgpt-5 exec "do the thing"' 'codex --model gpt-5 exec "do the thing"' \
    'codex --model=gpt-5 exec "do the thing"' 'codex -s danger-full-access exec "do the thing"' \
    'codex --sandbox=read-only exec "do the thing"' 'codex -a never exec "do the thing"' 'codex -C /tmp exec "do the thing"' \
    'codex -p work exec "do the thing"' 'codex --profile work exec "do the thing"' 'codex -i shot.png exec "do the thing"' \
    'codex -o out.txt exec "do the thing"' 'codex --enable web_search exec "do the thing"' 'codex --disable foo exec "do the thing"' \
    'codex --full-auto exec "do the thing"' 'codex --oss exec "do the thing"' \
    'codex exec -- "brief"' 'codex exec -- --help' \
    'nohup codex exec "the brief" &' 'sudo env FOO=1 nohup codex exec "the brief"' \
    'codex exec "$(cat brief.txt)"' 'git log; codex exec "the brief"'
  do deny $W "$c"; done
  [ "$BAD" = 0 ]
}
t_raw_allowed() {  # the entry points, the look-alikes, and the words in text
  local c
  for c in \
    'velo-dispatch 12 brief --wait' 'velo-dispatch 12 brief --wait &' 'velo-gate-run 42 full' 'velo-pr-gate 42 full' \
    'velo-openrouter-agent --help' 'velo-openrouter-agent -h' 'velo-openrouter-agent --version' \
    '/abs/path/velo-openrouter-agent --help' 'nohup velo-openrouter-agent --help &' \
    'codex login' 'codex --version' 'codex --help' 'codex mcp' 'codex' 'codex -c a=b --help' 'codex exec --help' \
    'velo-openrouter-agent-status' 'my-velo-openrouter-agent --model x' 'ls velo-openrouter-agent.txt' \
    'echo codex exec' 'printf "%s\n" nohup velo-openrouter-agent' 'grep -rn "codex exec" docs/' \
    '# nohup velo-openrouter-agent --model x' 'codex-exec' \
    'git commit -m "nohup velo-openrouter-agent --model x --brief b"' \
    'gh pr create --title t --body "codex exec ..."' \
    $'cat <<EOF\ncodex exec "the brief"\nEOF' $'cat <<\'EOF\'\nvelo-openrouter-agent --model x\nEOF' \
    'until pgrep -f codex; do sleep 1; done' 'velo-task status'
  do allow $W "$c"; done
  [ "$BAD" = 0 ]
}
t_raw_false_negatives() {  # the evasions this hook cannot see, pinned
  local long
  long=$(printf 'x%.0s' $(seq 1 1100))
  miss $W "FOO=$long velo-openrouter-agent --model x" 'more than 1 KB of text in front of the command in one segment'
  miss $W "FOO=$long codex exec \"the brief\"" 'more than 1 KB of text in front of the command in one segment'
  miss $W 'bash -c "nohup velo-openrouter-agent --model x"' 'a string handed to bash -c'
  miss $W "sh -c 'codex exec \"the brief\"'" 'a string handed to sh -c'
  miss $W 'eval "nohup velo-openrouter-agent --model x"' 'a string handed to eval'
  miss $W 'AGENT=velo-openrouter-agent; $AGENT --model x' 'a variable holds the program'
  miss $W 'alias ca="codex exec"; ca "the brief"' 'an alias'
  miss $W '"$(echo codex)" exec "the brief"' 'the output of a command substitution names the program'
  miss $W 'echo codex | xargs -I{} {} exec "the brief"' 'xargs substitution'
  miss $W 'bash launch-worker.sh' 'a script file that launches it'
  miss $W './bin/launch-worker.sh --model x' 'a script file that launches it'
  miss $W 'find . -name x -exec velo-openrouter-agent --model x \;' 'find -exec'
  miss $W 'sudo -u neil velo-openrouter-agent --model x' 'a wrapper option that takes a word'
  miss $W 'codex --some-new-flag v exec "the brief"' 'a codex option this hook does not know takes a word'
  miss $W 'cp bin/velo-openrouter-agent /tmp/agent && /tmp/agent --model x' 'the runner copied under another name'
  miss $W 'Velo-Openrouter-Agent --model x' 'a differently cased name on a case-insensitive volume'
  miss $W 'Codex exec "the brief"' 'a differently cased name on a case-insensitive volume'
  miss $W '>out velo-openrouter-agent --model x' 'a redirection in front of the command name'
  miss $W '2>&1 codex exec "the brief"' 'a redirection in front of the command name'
  miss $W 'python bin/velo-openrouter-agent-sdk.py --model x' 'the other raw entry points'
  miss $W 'python3 bin/velo-openai-agents-runner.py --model x' 'the other raw entry points'
  miss $W 'node /opt/codex/bin/codex.js exec "the brief"' 'the other raw entry points'
  [ "$BAD" = 0 ]
}

# ---- the scanner the three share: what is text and what is a command ----
t_scanner() {
  # heredoc bodies are text; what follows them is a command
  allow $V $'cat <<EOF\nvanth prune\nEOF'
  allow $V $'cat <<\'EOF\'\nvanth prune\nEOF'
  allow $V $'cat <<"EOF"\nvanth prune\nEOF'
  allow $V $'cat <<\\EOF\nvanth prune\nEOF'
  allow $V $'cat <<-EOF\n\tvanth prune\n\tEOF'
  allow $V $'cat << EOF\nvanth prune\nEOF'
  allow $V $'cat <<A <<B\nvanth prune\nA\nvanth prune\nB'
  allow $V $'cat <<EOF\nEOF2\nvanth prune\nEOF'
  allow $V $'cat <<EOF\nvanth prune'
  allow $V $'git commit -m "$(cat <<\'EOF\'\nnever run vanth prune\nEOF\n)"'
  deny  $V $'cat <<EOF\nbody\nEOF\nvanth prune'
  deny  $V $'cat <<\'EOF\'\nbody\nEOF\nvanth prune'
  deny  $V $'cat <<"EOF"\nbody\nEOF\nvanth prune'
  deny  $V $'cat <<\\EOF\nbody\nEOF\nvanth prune'
  deny  $V $'cat << EOF\nbody\nEOF\nvanth prune'
  deny  $V $'cat <<-EOF\n\tbody\n\tEOF\nvanth prune'
  deny  $V $'cat <<A <<B\nx\nA\ny\nB\nvanth prune'
  # shift and here-string are not heredocs, and arithmetic parentheses are counted
  deny  $V $'cat <<< foo\nvanth prune'
  deny  $V $'echo $((1<<n))\nvanth prune'
  deny  $V $'(( x = 1<<n ))\nvanth prune'
  deny  $V $'echo $(( (1) + (2) + (3<<n) ))\nvanth prune'
  deny  $V 'echo $(( 1 + 2 )) && vanth prune'
  deny  $V 'echo $(( (1+2)*3 )); vanth prune'
  # comments are text, and a comment may hold an apostrophe; # inside a word is not a comment
  allow $V 'echo ok # vanth prune'
  deny  $V $'# don\'t\nvanth prune'
  deny  $V $'echo ok;# don\'t\nvanth prune'
  deny  $V $'echo hi # a comment\nvanth prune'
  deny  $V 'echo a#b; vanth prune'
  deny  $V 'echo $#; vanth prune'
  deny  $V 'x=abc; echo ${#x}; vanth prune'
  deny  $V 'echo \;# x; vanth prune'
  deny  $V 'echo \ # x; vanth prune'
  # quotes: single quotes are literal, double quotes run $( ) and backticks, ANSI-C quotes take backslash escapes
  allow $V "echo '\$(vanth prune)'"
  allow $V 'echo "\$(vanth prune)"'
  allow $V 'echo "a \" b; vanth prune"'
  allow $V $'echo $\'vanth prune\\\'s\''
  allow $V 'echo "unterminated vanth prune'
  allow $V '"vanth x" prune'
  allow $V 'vanth "" prune'
  allow $V 'echo "`date` vanth prune"'
  allow $V 'echo "$(date) vanth prune"'
  deny  $V $'echo $\'it\\\'s\'; vanth prune'
  deny  $V 'echo \"; vanth prune'
  deny  $V $'echo \\$\'a\\\'; vanth prune'
  deny  $V 'echo "a $(echo "b $(vanth prune)")"'
  deny  $V 'echo "$( (cd /x); vanth prune )"'
  deny  $V "echo \"\$(echo 'a)b'; vanth prune)\""
  deny  $V 'echo "${x:-$(vanth prune)}"'
  deny  $V 'vanth prune "unterminated'
  deny  $V "vanth prune 'unterminated"
  deny  $V 'diff <(vanth prune) <(echo)'
  deny  $V $'true &&\nvanth prune'
  [ "$BAD" = 0 ]
}
t_noglob() {  # command text is only ever word-split, never glob-expanded
  local d
  d=$(/usr/bin/mktemp -d "$T/g.XXXXXX") || exit 1
  : > "$d/prune"; : > "$d/pgrep"
  HOOK_CWD=$d
  allow $V 'vanth p*'
  allow $P 'until pg*; do sleep 1; done'
  HOOK_CWD=
  [ "$BAD" = 0 ]
}
t_utf8() {  # a multibyte character inside quotes must not blind the scanner, whatever locale the caller has
  deny  $V 'echo "é"; vanth prune' LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  deny  $V "echo 'ü ö'; vanth prune" LC_ALL=en_US.UTF-8
  allow $V 'echo "日本語 — vanth prune"' LC_ALL=en_US.UTF-8
  # Those three cases go red only on an awk that aborts on a lone byte of a multibyte character in a UTF-8 locale: the awk macOS ships
  # does (towc: multibyte conversion failure); mawk, gawk and the bwk awk of 2023 do not, so a scanner that dropped its LC_ALL=C would
  # still pass them there. What they stand for is checked directly, on every awk: the scanner's awk starts in the C locale whatever
  # locale the caller has. A copy of the hooks runs the scanner through an awk that records the locale it was started in.
  local d out; d=$(/usr/bin/mktemp -d "$T/utf8.XXXXXX") || return 1
  cp -R "$R/hooks" "$d/hooks"
  printf '#!/bin/bash\nprintf "%%s\\n" "${LC_ALL-unset}" >> "%s/awk-locale"\nexec /usr/bin/awk "$@"\n' "$d" > "$d/awk-spy"; chmod +x "$d/awk-spy"
  sed "s#/usr/bin/awk#$d/awk-spy#g" "$R/hooks/guard-lib.sh" > "$d/hooks/guard-lib.sh"
  [ "$(grep -c "$d/awk-spy" "$d/hooks/guard-lib.sh")" -ge 1 ] || bad "precondition: the copied scanner runs its awk through the spy"
  out=$(jq -cn --arg c 'echo "é"; vanth prune' '{tool_name:"Bash",tool_input:{command:$c}}' | env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$d/hooks/$V" 2>&1 >/dev/null); RC=$?
  [ "$RC" = 2 ] || bad "the spied hook should still DENY (exit 2) but exited $RC: $out"
  [ -s "$d/awk-locale" ] || bad "the spy awk never ran, so the locale the scanner's awk starts in was not observed"
  [ "$(sort -u "$d/awk-locale" 2>/dev/null)" = C ] || bad "the scanner's awk started in the caller's locale, not in C: $(sort -u "$d/awk-locale" 2>/dev/null | tr '\n' ' ')"
  [ "$BAD" = 0 ]
}

# ---- what the model is told, and what happens when the machine is not as expected ----
t_messages() {
  local out long matched
  run_hook $V 'vanth prune --yes'
  [ "$RC" = 2 ] || bad "vanth prune exited $RC, want 2"
  case $ERR in *'BLOCKED: `vanth prune`'*) ;; *) bad "the vanth message does not name the command: $ERR" ;; esac
  case $ERR in *'Matched: vanth prune --yes'*) ;; *) bad "the vanth message does not show the matched segment: $ERR" ;; esac
  case $ERR in *'R15(i)'*) ;; *) bad "the vanth message does not cite the spec: $ERR" ;; esac
  run_hook $V 'vanth restore x'
  case $ERR in *'BLOCKED: `vanth restore`'*) ;; *) bad "the message for restore names the wrong subcommand: $ERR" ;; esac
  run_hook $V $'vanth   prune \t --yes "a b"'
  case $ERR in *'Matched: vanth prune --yes'*) ;; *) bad "the matched segment is not squeezed to single spaces: $ERR" ;; esac
  case $ERR in *$'\002'*) bad "the matched segment leaks the scanner's placeholder byte" ;; esac
  long=$(printf 'x%.0s' $(seq 1 400))
  run_hook $V "vanth prune $long"
  matched=${ERR##*Matched: }
  [ "${#matched}" -le 200 ] || bad "the matched segment is ${#matched} characters, it must be cut at 200"
  run_hook $P 'until pgrep -f foo; do sleep 5; done'
  [ "$RC" = 2 ] || bad "the pgrep loop exited $RC, want 2"
  case $ERR in *'velo-task wait'*) ;; *) bad "the pgrep message does not name velo-task wait: $ERR" ;; esac
  case $ERR in *'run_in_background: true'*) ;; *) bad "the pgrep message does not say how to run it: $ERR" ;; esac
  case $ERR in *'Matched: until pgrep -f foo'*) ;; *) bad "the pgrep message does not show the matched segment: $ERR" ;; esac
  out=$(jq -cn --arg c 'vanth prune' '{tool_input:{command:$c}}' | "$R/hooks/$V" 2>/dev/null)
  [ -z "$out" ] || bad "a deny writes to stdout: $out"
  run_hook $V 'vanth status'
  [ "$RC" = 0 ] && [ -z "$ERR" ] || bad "an allow is not silent (exit $RC): $ERR"
  run_hook $W 'nohup velo-openrouter-agent --model x --brief b'
  [ "$RC" = 2 ] || bad "a raw worker launch exited $RC, want 2"
  case $ERR in *'velo-dispatch <issue> <brief> --wait'*) ;; *) bad "the raw-launch message does not name velo-dispatch: $ERR" ;; esac
  case $ERR in *'velo-gate-run <pr> <scope>'*) ;; *) bad "the raw-launch message does not name velo-gate-run: $ERR" ;; esac
  case $ERR in *'velo-task status'*) ;; *) bad "the raw-launch message does not say what a raw launch dodges: $ERR" ;; esac
  case $ERR in *'Matched: nohup velo-openrouter-agent --model x --brief b'*) ;; *) bad "the raw-launch message does not show the matched segment: $ERR" ;; esac
  run_hook $W 'codex exec "the brief"'
  [ "$RC" = 2 ] || bad "codex exec exited $RC, want 2"
  case $ERR in *'Matched: codex exec'*) ;; *) bad "the codex-exec message does not show the matched segment: $ERR" ;; esac
  [ "$BAD" = 0 ]
}
t_failopen() {  # no jq, no lib, a lib that does not load, a payload with nothing to scan: exit 0, so a broken install never wedges Bash
  local hook body d out rc variant payload bin t
  d=$(/usr/bin/mktemp -d "$T/fo.XXXXXX") || exit 1
  for hook in $V $P $W; do
    case $hook in
      $V) payload=$(jq -cn '{tool_input:{command:"vanth prune"}}') ;;
      $W) payload=$(jq -cn '{tool_input:{command:"nohup velo-openrouter-agent --model x"}}') ;;
      *)  payload=$(jq -cn '{tool_input:{command:"until pgrep -f x; do sleep 1; done"}}') ;;
    esac
    for body in '' '{}' 'not json' '{"tool_input":' '{"tool_input":{"command":null}}' '{"tool_input":{"command":""}}' \
                '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' '{"tool_input":{"command":5}}' '{"tool_input":{"command":["vanth","prune"]}}'; do
      out=$(printf '%s' "$body" | "$R/hooks/$hook" 2>&1); rc=$?
      [ "$rc" = 0 ] || bad "$hook exits $rc on the payload [$body]: it must fail open"
      [ -z "$out" ] || bad "$hook prints on the payload [$body]: $out"
    done
    # no jq on PATH
    mkdir -p "$d/nojq" "$d/withjq"
    for t in dirname tr cut; do ln -sf "$(command -v $t)" "$d/nojq/$t"; ln -sf "$(command -v $t)" "$d/withjq/$t"; done
    ln -sf "$(command -v jq)" "$d/withjq/jq"
    out=$(printf '%s' "$payload" | env PATH="$d/nojq" "$R/hooks/$hook" 2>&1); rc=$?
    [ "$rc" = 0 ] && [ -z "$out" ] || bad "$hook without jq on PATH: exit $rc, output [$out]; it must fail open silently"
    out=$(printf '%s' "$payload" | env PATH="$d/withjq" "$R/hooks/$hook" 2>&1); rc=$?
    [ "$rc" = 2 ] || bad "control: $hook with jq on that PATH must deny (exit 2), exited $rc: $out"
    # the lib beside it is missing, unreadable, does not load, or defines nothing
    for variant in intact missing unreadable corrupt empty; do
      rm -rf "$d/h"; mkdir "$d/h"; cp "$R"/hooks/*.sh "$d/h/"; chmod +x "$d/h/"*.sh
      case $variant in
        missing)    rm -f "$d/h/guard-lib.sh" ;;
        unreadable) chmod 000 "$d/h/guard-lib.sh" ;;
        corrupt)    printf 'if then fi\n' > "$d/h/guard-lib.sh" ;;
        empty)      : > "$d/h/guard-lib.sh" ;;
      esac
      out=$(printf '%s' "$payload" | "$d/h/$hook" 2>&1); rc=$?
      if [ "$variant" = intact ]; then [ "$rc" = 2 ] || bad "control: a copy of $hook with its lib must deny, exited $rc: $out"
      else [ "$rc" = 0 ] || bad "$hook with the lib $variant exits $rc, it must fail open: $out"; fi
      case $variant in missing|unreadable) [ -z "$out" ] || bad "$hook with the lib $variant prints: $out" ;; esac
    done
  done
  [ "$BAD" = 0 ]
}
t_scan_speed() {  # a hook runs before every Bash call: about 300 KB of command in any shape must not take seconds of CPU (not of wall time: a loaded host stretches that)
  local d name hook
  d=$(/usr/bin/mktemp -d "$T/sp.XXXXXX") || exit 1
  /usr/bin/awk 'BEGIN { for (i = 0; i < 27000; i++) printf "echo \"a\" ; "; print "vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/many-segments.json"
  /usr/bin/awk 'BEGIN { for (i = 0; i < 10000; i++) printf "echo \"line %d some text here\"\n", i; print "vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/many-lines.json"
  /usr/bin/awk 'BEGIN { printf "echo \""; for (i = 0; i < 60000; i++) printf "word "; print "\"; vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/one-string.json"
  /usr/bin/awk 'BEGIN { print "cat > f <<\047EOF\047"; for (i = 0; i < 10000; i++) printf "some body line %d with text\n", i; print "EOF"; print "vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/heredoc.json"
  /usr/bin/awk 'BEGIN { for (i = 0; i < 20000; i++) printf "vanth status ; "; print "vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/vanth-segments.json"
  /usr/bin/awk 'BEGIN { for (i = 0; i < 10000; i++) printf "for i in 1; do :; done; "; print "until pgrep -f x; do sleep 1; done" }' | jq -Rs '{tool_input:{command:.}}' > "$d/loops.json"
  # one word, unquoted (150 KB) and quoted (600 KB): quadratic without the caps in the scanner (66 s for 300 KB unquoted), linear with them
  /usr/bin/awk 'BEGIN { for (i = 0; i < 150000; i++) printf "a"; print "; vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/one-word.json"
  /usr/bin/awk 'BEGIN { printf "echo \""; for (i = 0; i < 600000; i++) printf "a"; print "\"; vanth prune" }' | jq -Rs '{tool_input:{command:.}}' > "$d/one-quoted-word.json"
  # the raw-launch hook has its own loop over the words of a segment (the codex options): the same two shapes, ending in a
  # denied raw launch, so it is measured and not only the scanner it shares
  /usr/bin/awk 'BEGIN { for (i = 0; i < 27000; i++) printf "echo \"a\" ; "; print "nohup velo-openrouter-agent --model x" }' | jq -Rs '{tool_input:{command:.}}' > "$d/many-segments-raw.json"
  /usr/bin/awk 'BEGIN { printf "echo \""; for (i = 0; i < 600000; i++) printf "a"; print "\"; nohup velo-openrouter-agent --model x" }' | jq -Rs '{tool_input:{command:.}}' > "$d/one-quoted-word-raw.json"
  # CPU seconds, not elapsed ones: the slow mutants below burn 8 to 16 s of CPU where the real scanner needs 1.5 s, and a host
  # busy with other suites or with four parallel proof jobs stretches elapsed time past a fixed bound without the scanner changing.
  for name in many-segments many-lines one-string heredoc vanth-segments loops one-word one-quoted-word many-segments-raw one-quoted-word-raw; do
    case $name in loops) hook=$P ;; *-raw) hook=$W ;; *) hook=$V ;; esac
    cpu_run "$d/clock" "$R/hooks/$hook" < "$d/$name.json"
    [ "$RC" = 2 ] || bad "$name: the hook exited $RC, want 2 (the command ends in the denied form)"
    below "$CPU" 5 || bad "$name: the hook used ${CPU}s of CPU on a $(wc -c < "$d/$name.json" | tr -d ' ') byte command (bound 5 s)"
    echo "note: $name, $(wc -c < "$d/$name.json" | tr -d ' ') bytes: ${CPU}s of CPU"
  done
  [ "$BAD" = 0 ]
}
t_scan_clock() {  # the clock t_scan_speed reads is CPU time: a second of sleeping costs almost none, a busy loop costs some
  local tf
  tf=$(/usr/bin/mktemp "$T/clk.XXXXXX") || exit 1
  cpu_run "$tf" /bin/sleep 1
  [ "$RC" = 0 ] || { echo "FAILED: sleep exited $RC"; return 1; }
  below "$CPU" 0.5 || bad "a second of sleeping cost ${CPU}s: the clock counts elapsed time, which a loaded host stretches"
  cpu_run "$tf" /usr/bin/awk 'BEGIN { for (i = 0; i < 3000000; i++) x += i }'
  [ "$RC" = 0 ] || { echo "FAILED: awk exited $RC"; return 1; }
  below 0.05 "$CPU" || bad "a busy loop cost ${CPU}s: the clock does not see CPU time"
  [ "$BAD" = 0 ]
}

# ---- registration, files, install ----
t_readme_registration() {  # the registration line in README.md, run the way Claude Code runs a hook command, with the hook there, absent and not executable
  local d stanza cmd hook sh home out rc payload
  d=$(/usr/bin/mktemp -d "$T/rd.XXXXXX") || exit 1
  stanza=$(/usr/bin/awk '/^```json$/ { inb = 1; buf = ""; next } /^```$/ { if (inb && index(buf, "deny-vanth-cleanup.sh")) { printf "%s", buf; exit } inb = 0; next } inb { buf = buf $0 "\n" }' "$R/README.md")
  [ -n "$stanza" ] || { bad "no json block in README.md registers deny-vanth-cleanup.sh"; return 1; }
  printf '%s' "$stanza" | jq -e . >/dev/null 2>&1 || { bad "the README registration stanza is not valid JSON"; return 1; }
  for hook in deny-vanth-cleanup.sh deny-pgrep-wait-loop.sh deny-raw-launch.sh; do
    cmd=$(printf '%s' "$stanza" | jq -r --arg h "$hook" '.hooks.PreToolUse[].hooks[].command | select(contains($h))')
    [ -n "$cmd" ] || { bad "the README stanza has no command for $hook"; continue; }
    case $hook in
      deny-vanth-cleanup.sh) payload=$(jq -cn '{tool_input:{command:"vanth prune"}}') ;;
      deny-raw-launch.sh)    payload=$(jq -cn '{tool_input:{command:"codex exec \"the brief\""}}') ;;
      *)                     payload=$(jq -cn '{tool_input:{command:"until pgrep -f x; do sleep 1; done"}}') ;;
    esac
    for sh in /bin/sh /bin/bash; do
      home="$d/home-${hook%.sh}-${sh##*/}"; rm -rf "$home"; mkdir -p "$home"
      out=$(printf '%s' "$payload" | env HOME="$home" "$sh" -c "$cmd" 2>&1); rc=$?
      [ "$rc" = 0 ] && [ -z "$out" ] || bad "$sh: with $hook not installed the registered command exited $rc [$out]: it must be skipped silently (exit 0)"
      mkdir -p "$home/.agents/hooks"; cp "$R"/hooks/*.sh "$home/.agents/hooks/"; chmod +x "$home/.agents/hooks/"*.sh
      out=$(printf '%s' "$payload" | env HOME="$home" "$sh" -c "$cmd" 2>&1); rc=$?
      [ "$rc" = 2 ] || bad "$sh: with $hook installed the registered command exited $rc, want 2: $out"
      chmod -x "$home/.agents/hooks/$hook"
      out=$(printf '%s' "$payload" | env HOME="$home" "$sh" -c "$cmd" 2>&1); rc=$?
      [ "$rc" = 0 ] && [ -z "$out" ] || bad "$sh: with $hook installed but not executable the registered command exited $rc [$out]: it must be skipped (exit 0)"
    done
  done
  [ "$BAD" = 0 ]
}
t_hook_files() {  # the deny hooks and their lib are bash scripts that must parse and run on the bash 3.2 of a stock macOS
  local f name first
  for name in deny-vanth-cleanup.sh deny-pgrep-wait-loop.sh deny-raw-launch.sh guard-lib.sh; do
    f="$R/hooks/$name"
    [ -f "$f" ] || { bad "hooks/$name is missing"; continue; }
    first=$(/usr/bin/head -n 1 "$f")
    [ "$first" = '#!/bin/bash' ] || bad "hooks/$name starts with [$first], not #!/bin/bash"
    /bin/bash -n "$f" 2>/dev/null || bad "hooks/$name does not parse under /bin/bash"
    bash4_hits "$f" >/dev/null; [ $? = 1 ] || bad "hooks/$name uses a bash-4 construct (a parse error exits 2, which blocks every Bash call): $(bash4_hits "$f" | /usr/bin/head -2 | tr '\n' ' ')"
    case $name in guard-lib.sh) ;; *) [ -x "$f" ] || bad "hooks/$name is not executable: a registered hook that is not executable is skipped without a word" ;; esac
  done
  [ "$BAD" = 0 ]
}
t_install_hooks() {  # install.sh puts the hooks where the registration looks, executable, and --check notices when one is not
  local d src dest out rc f
  d=$(/usr/bin/mktemp -d "$T/in.XXXXXX") || exit 1
  src="$d/src"; dest="$d/dest"
  mkdir -p "$src/bin" "$src/hooks" "$d/home" "$d/skills"
  cp "$R/install.sh" "$src/install.sh"
  cp "$R"/hooks/*.sh "$src/hooks/"
  printf '#!/bin/bash\n' > "$src/bin/stub"
  chmod -x "$src/hooks/deny-vanth-cleanup.sh"   # a checkout that lost the exec bit
  inst() { env -i HOME="$d/home" PATH=/usr/bin:/bin VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$d/skills" /bin/bash "$src/install.sh" "$@"; }
  out=$(inst 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "FAILED: install.sh exited $rc: $out"; return 1; }
  for f in deny-vanth-cleanup.sh deny-pgrep-wait-loop.sh deny-raw-launch.sh guard-lib.sh; do
    [ -x "$dest/hooks/$f" ] || bad "install.sh left hooks/$f missing or not executable at the destination"
  done
  out=$(inst --check 2>&1); rc=$?
  [ "$rc" = 0 ] || bad "--check is not clean right after an install (exit $rc): $out"
  chmod -x "$dest/hooks/deny-vanth-cleanup.sh"
  out=$(inst --check 2>&1); rc=$?
  [ "$rc" != 0 ] || bad "--check passes although an installed hook is not executable"
  case $out in *'hooks/deny-vanth-cleanup.sh'*) ;; *) bad "--check does not name the hook that is not executable: $out" ;; esac
  chmod +x "$dest/hooks/deny-vanth-cleanup.sh"
  rm -f "$dest/hooks/guard-lib.sh"
  out=$(inst --check 2>&1); rc=$?
  [ "$rc" != 0 ] || bad "--check passes although hooks/guard-lib.sh is not installed"
  case $out in *'not installed: hooks/guard-lib.sh'*) ;; *) bad "--check does not name the hook that is not installed: $out" ;; esac
  [ "$BAD" = 0 ]
}
t_install_exec_scope() {  # install.sh makes exactly the hooks and scripts it ships executable: a file only the live copy has keeps its mode
  local d src dest out rc n
  d=$(/usr/bin/mktemp -d "$T/ix.XXXXXX") || exit 1
  install_tree
  chmod -x "$src/bin/stub" "$src/hooks/deny-vanth-cleanup.sh"   # a checkout that lost the exec bit
  mkdir -p "$dest/hooks" "$dest/bin"
  : > "$dest/hooks/local-hook.sh"; : > "$dest/hooks/notes.txt"; : > "$dest/bin/notes.txt"
  chmod 644 "$dest/hooks/local-hook.sh" "$dest/hooks/notes.txt" "$dest/bin/notes.txt"   # a hook someone switched off, and two files that are no hook
  out=$(inst 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "FAILED: install.sh exited $rc: $out"; return 1; }
  [ -x "$dest/hooks/deny-vanth-cleanup.sh" ] || bad "a shipped hook whose checkout lost the exec bit is not executable after the install"
  [ -x "$dest/bin/stub" ] || bad "a shipped script whose checkout lost the exec bit is not executable after the install"
  [ ! -x "$dest/hooks/local-hook.sh" ] || bad "install.sh switched on hooks/local-hook.sh, a hook it does not ship"
  [ ! -x "$dest/hooks/notes.txt" ] || bad "install.sh made hooks/notes.txt, a file it does not ship, executable"
  [ ! -x "$dest/bin/notes.txt" ] || bad "install.sh made bin/notes.txt, a file it does not ship, executable"
  n=$(ls "$src/hooks" | wc -l | tr -d ' ')
  case $out in *"chmod +x on $n hook scripts"*) ;; *) bad "install.sh does not report the $n hooks it shipped: $out" ;; esac
  [ "$BAD" = 0 ]
}
t_install_pycache() {  # a __pycache__ under hooks/ is not tooling: it is not shipped, and an installed .pyc is not read as a hook that lost its exec bit (#2091)
  local d src dest out rc
  d=$(/usr/bin/mktemp -d "$T/ip.XXXXXX") || exit 1
  install_tree
  mkdir -p "$src/hooks/__pycache__"; printf 'bytecode\n' > "$src/hooks/__pycache__/guard.cpython-314.pyc"
  out=$(inst 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "FAILED: install.sh exited $rc: $out"; return 1; }
  [ ! -e "$dest/hooks/__pycache__" ] || bad "install.sh shipped hooks/__pycache__"
  mkdir -p "$dest/hooks/__pycache__"; printf 'bytecode written by a run in the live copy\n' > "$dest/hooks/__pycache__/guard.cpython-314.pyc"
  out=$(inst --check 2>&1); rc=$?
  [ "$rc" = 0 ] || bad "--check reports drift for a .pyc python wrote under hooks/ (exit $rc): $out"
  case $out in *pyc*) bad "--check mentions a python artifact: $out" ;; esac
  [ "$BAD" = 0 ]
}
t_hook_docs() {  # every known false negative the tests pin is listed in the hook's header and in its README row, not only in the tests
  local hook phrase head row
  local -a common vanth raw phrases
  common=('a redirection in front of the command name' 'more than 1 KB of text in front of the command')
  vanth=('the output of a command substitution naming the program' 'xargs substitution' 'a quoted command path that contains a space')
  raw=('a string handed to bash -c' 'a variable or alias holding the program' 'a wrapper option that takes a word' 'a codex option this hook does not know takes a word' 'the other raw entry points')
  for hook in $V $P $W; do
    head=$(/usr/bin/awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); printf "%s ", $0; next } NR > 1 { exit }' "$R/hooks/$hook")
    row=$(grep -F "| \`$hook\` |" "$R/README.md")
    [ -n "$row" ] || { bad "README.md has no table row for $hook"; continue; }
    phrases=("${common[@]}")
    [ "$hook" != "$V" ] || phrases=("${phrases[@]}" "${vanth[@]}")
    [ "$hook" != "$W" ] || phrases=("${phrases[@]}" "${raw[@]}")
    for phrase in "${phrases[@]}"; do
      case $head in *"$phrase"*) ;; *) bad "the header of $hook does not list the known false negative: $phrase" ;; esac
      case $row in *"$phrase"*) ;; *) bad "the README row of $hook does not list the known false negative: $phrase" ;; esac
    done
  done
  [ "$BAD" = 0 ]
}

echo "velo-task M3c: guard hooks"
echo " deny-vanth-cleanup.sh (B29, hook half)"
check "vanth prune and vanth restore are denied in every command form" t_vanth_denied
check "...behind every wrapper (sudo, env, timeout, uv run, ...) and its options" t_vanth_wrappers
check "...behind every control word (!, {, if, then, else, elif, do, while, until)" t_vanth_control
check "look-alikes pass: other subcommands, --help, the words in text, other programs" t_vanth_allowed
check "known false negatives are pinned" t_vanth_false_negatives
echo " deny-pgrep-wait-loop.sh (B13)"
check "a pgrep inside a while/until loop is denied in every shape" t_pgrep_denied
check "the loop stack: for/select/done decide whether a pgrep is inside a while" t_pgrep_nesting
check "velo-task wait and everything that only looks like a wait loop pass" t_pgrep_allowed
check "known false negatives and the accepted false positive are pinned" t_pgrep_false_negatives
echo " deny-raw-launch.sh (#31 part C)"
check "a raw velo-openrouter-agent or codex exec launch is denied in every shape" t_raw_denied
check "velo-dispatch, velo-gate-run, --help/--version, other codex subcommands and the words in text pass" t_raw_allowed
check "known false negatives are pinned" t_raw_false_negatives
echo " the scanner the three share"
check "heredocs, comments, quotes, substitutions: what is text and what is a command" t_scanner
check "command text is never glob-expanded" t_noglob
check "a multibyte character in quotes does not blind the scanner (UTF-8 locale)" t_utf8
echo " behaviour"
check "the messages say what was matched and what to do; an allow is silent" t_messages
check "fail open: no jq, no lib, a lib that does not load, nothing to scan" t_failopen
check "about 300 KB of command in eight shapes is scanned in seconds" t_scan_speed
check "...measured in CPU time: a second of sleeping costs none, a busy loop costs some" t_scan_clock
check "the registration line in README.md: absent hook skipped, present hook denies, not executable skipped" t_readme_registration
check "the hooks parse under /bin/bash, carry no bash-4 construct and are executable" t_hook_files
check "install.sh installs the hooks executable and --check notices a hook that is not" t_install_hooks
check "install.sh makes exactly the hooks and scripts it ships executable, not a file only the live copy has" t_install_exec_scope
check "a __pycache__ under hooks/ is not shipped and not read as a hook without its exec bit" t_install_pycache
check "each known false negative the tests pin is listed in the hook's header and its README row" t_hook_docs

echo "mutation proofs"
LIB=hooks/guard-lib.sh; HV=hooks/deny-vanth-cleanup.sh; HP=hooks/deny-pgrep-wait-loop.sh; HW=hooks/deny-raw-launch.sh
# B13 "allow all", and its mirror
prove "allow all: the pgrep hook exits 0 before it scans (B13 mutant)" t_pgrep_denied $HP 'guard_scan_payload || exit 0' 'exit 0'
prove "allow all: the vanth hook exits 0 before it scans" t_vanth_denied $HV 'guard_scan_payload || exit 0' 'exit 0'
prove "allow all: a deny exits 0 (pgrep hook)" t_pgrep_denied $LIB $'  exit 2\n}' $'  exit 0\n}'
prove "allow all: a deny exits 0 (vanth hook)" t_vanth_denied $LIB $'  exit 2\n}' $'  exit 0\n}'
prove "deny all: the pgrep hook exits 2 before it scans" t_pgrep_allowed $HP 'guard_scan_payload || exit 0' 'exit 2'
prove "deny all: the vanth hook exits 2 before it scans" t_vanth_allowed $HV 'guard_scan_payload || exit 0' 'exit 2'
# the vanth hook
prove "the vanth hook ignores a program called vanth" t_vanth_denied $HV '    vanth) ;;' '    vanthx) ;;'
prove "the vanth hook ignores python3 -m" t_vanth_denied $HV 'python*|pypy*)' 'NOpython*|pypy*)'
prove "the vanth hook ignores pypy" t_vanth_denied $HV 'python*|pypy*)' 'python*|NOpypy*)'
prove "-m followed by a module is not read" t_vanth_denied $HV '-m|-[A-Za-z]*m) mod=' 'NO-m|-[A-Za-z]*m) mod='
prove "an option cluster ending in m (-Im) is not read" t_vanth_denied $HV '-m|-[A-Za-z]*m) mod=' '-m|NO-[A-Za-z]*m) mod='
prove "an attached module (-mvanth) is not read" t_vanth_denied $HV '-m?*)  mod=' '-m?*NEVER)  mod='
prove "python options that take a word (-X, -W) are not skipped" t_vanth_denied $HV '-X|-W) i=$((i + 2)) ;;' 'NO-X|NO-W) i=$((i + 2)) ;;'
prove "python options without a value are not skipped" t_vanth_denied $HV '-*)    i=$((i + 1)) ;;' 'NO-*)    i=$((i + 1)) ;;'
prove "a python script name does not end the python options" t_vanth_allowed $HV '*)     return 1 ;;' '*)     i=$((i + 1)) ;;'
prove "python -m vanth.cli is not recognised" t_vanth_denied $HV 'vanth|vanth.cli|vanth.__main__' 'vanth|vanth.__main__'
prove "python -m vanth.__main__ is not recognised" t_vanth_denied $HV 'vanth|vanth.cli|vanth.__main__' 'vanth|vanth.cli'
prove "python -m vanth is not recognised" t_vanth_denied $HV 'vanth|vanth.cli|vanth.__main__' 'NOvanth|vanth.cli|vanth.__main__'
prove "the global --json flag is not skipped" t_vanth_denied $HV 'while [ "${GW[i]:-}" = "--json" ]; do i=$((i + 1)); done' ':'
prove "restore is no longer denied" t_vanth_denied $HV 'case $w in prune|restore) ;; *) return 1 ;; esac' 'case $w in prune) ;; *) return 1 ;; esac'
prove "prune is no longer denied" t_vanth_denied $HV 'case $w in prune|restore) ;; *) return 1 ;; esac' 'case $w in restore) ;; *) return 1 ;; esac'
prove "--help no longer exempts" t_vanth_allowed $HV '-h|--help) return 1 ;;' 'NO-h|NO--help) return 1 ;;'
prove "-h no longer exempts" t_vanth_allowed $HV '-h|--help) return 1 ;;' 'NO-h|--help) return 1 ;;'
prove "--help after -- exempts although it is an argument there" t_vanth_denied $HV '--) break ;; -h|--help) return 1 ;;' '-h|--help) return 1 ;;'
# the words the hooks look through
WRAPPERS="command builtin exec nohup sudo doas env nice timeout stdbuf time xargs uv uvx pipx run tool"
LIST=""; for w in $WRAPPERS; do LIST="$LIST${LIST:+|}$w"; done
for w in $WRAPPERS; do
  MUT=""; for x in $WRAPPERS; do if [ "$x" = "$w" ]; then y="NO_$x"; else y=$x; fi; MUT="$MUT${MUT:+|}$y"; done
  prove "$w is no longer looked through" t_vanth_wrappers $LIB "$LIST) wrapped=1 ;;" "$MUT) wrapped=1 ;;"
done
prove "the options a wrapper takes are not skipped" t_vanth_wrappers $LIB '-*|[0-9]*) [ "$wrapped" = 1 ] || break ;;' '-*|[0-9]*) break ;;'
prove "the counts a wrapper takes are not skipped" t_vanth_wrappers $LIB '-*|[0-9]*) [ "$wrapped" = 1 ] || break ;;' '-*) [ "$wrapped" = 1 ] || break ;;'
prove "a number or an option is looked through even without a wrapper" t_vanth_wrappers $LIB '-*|[0-9]*) [ "$wrapped" = 1 ] || break ;;' '-*|[0-9]*) : ;;'
prove "VAR=value is not looked through" t_vanth_denied $LIB '[A-Za-z_]*=*) ;;' 'NO_[A-Za-z_]*=*) ;;'
CONTROL="'!' '{' if then else elif do while until"
CLIST=""; for w in $CONTROL; do CLIST="$CLIST${CLIST:+|}$w"; done
for w in $CONTROL; do
  MUT=""; for x in $CONTROL; do if [ "$x" = "$w" ]; then y="NO_$x"; else y=$x; fi; MUT="$MUT${MUT:+|}$y"; done
  prove "the control word $w is no longer looked through" t_vanth_control $LIB "$CLIST) GW_KW=\"\$GW_KW \$w\" ;;" "$MUT) GW_KW=\"\$GW_KW \$w\" ;;"
done
prove "a wrapper option that takes a word is skipped with its word (closes the sudo -u gap)" t_vanth_false_negatives $LIB '-*|[0-9]*) [ "$wrapped" = 1 ] || break ;;' '-*|[0-9]*) [ "$wrapped" = 1 ] || break; shift ;;'
prove "a wrapper option that takes a word is skipped with its word (pgrep hook)" t_pgrep_false_negatives $LIB '-*|[0-9]*) [ "$wrapped" = 1 ] || break ;;' '-*|[0-9]*) [ "$wrapped" = 1 ] || break; shift ;;'
# the pgrep hook
prove "while is not tracked as a loop" t_pgrep_denied $HP 'while|until) loops="W$loops" ;;' 'NOwhile|until) loops="W$loops" ;;'
prove "until is not tracked as a loop" t_pgrep_denied $HP 'while|until) loops="W$loops" ;;' 'while|NOuntil) loops="W$loops" ;;'
prove "for is not tracked as a loop" t_pgrep_nesting $LIB 'for|select|done) GW_KW="$GW_KW $w"; return 0 ;;' 'NOfor|select|done) GW_KW="$GW_KW $w"; return 0 ;;'
prove "select is not tracked as a loop" t_pgrep_nesting $LIB 'for|select|done) GW_KW="$GW_KW $w"; return 0 ;;' 'for|NOselect|done) GW_KW="$GW_KW $w"; return 0 ;;'
prove "done is not seen as closing a loop (lib)" t_pgrep_nesting $LIB 'for|select|done) GW_KW="$GW_KW $w"; return 0 ;;' 'for|select|NOdone) GW_KW="$GW_KW $w"; return 0 ;;'
prove "done does not pop the loop stack" t_pgrep_nesting $HP 'done)        loops="${loops#?}" ;;' 'done)        ;;'
prove "a for loop is tracked as a while loop" t_pgrep_allowed $HP 'for|select)  loops="F$loops" ;;' 'for|select)  loops="W$loops" ;;'
prove "a while loop is tracked as a for loop" t_pgrep_denied $HP 'while|until) loops="W$loops" ;;' 'while|until) loops="F$loops" ;;'
prove "a pgrep outside any loop is denied" t_pgrep_allowed $HP '*W*) if' '*) if'
prove "a pgrep by absolute path is not recognised" t_pgrep_denied $HP '${GW[0]##*/}' '${GW[0]}'
prove "no wrapper is looked through in front of pgrep" t_pgrep_denied $LIB "$LIST) wrapped=1 ;;" "NOWRAPPER) wrapped=1 ;;"
# the scanner
prove "heredoc bodies are scanned as commands" t_scanner $LIB 'if (hdk > 0) {' 'if (0) {'
prove "<<- does not strip the tabs of its terminator" t_scanner $LIB 'if (hdt[hdk]) sub(/^\t+/, "", t)' ''
prove "a quoted heredoc delimiter keeps its quotes" t_scanner $LIB 'if (q == "'"'"'" || q == "\"") {' 'if (0) {'
prove "a second heredoc on the line ends the heredocs" t_scanner $LIB 'hdk++; if (hdk > hdn) { hdk = 0; hdn = 0 }' 'hdk = 0; hdn = 0'
prove "every newline opens a heredoc body" t_vanth_denied $LIB 'if (hdn > 0) hdk = 1;' 'hdk = 1;'
prove "comments are scanned as commands" t_scanner $LIB 'if (c == "#" && prev ~ /[ \t\n&;|()]/) { i = n; continue }' ''
prove "a # inside a word starts a comment" t_scanner $LIB 'c == "#" && prev ~ /[ \t\n&;|()]/' 'c == "#"'
prove "<<< is read as a heredoc" t_scanner $LIB 'if (c == "<" && c1 == "<" && ch[i + 2] == "<") { put("<<<"); i += 3; continue }' ''
prove '(( and $(( are not arithmetic: a shift is read as a heredoc' t_scanner $LIB 'if (c == "(" && c1 == "(") { put("(("); ar = 2; i += 2; continue }' ''
prove 'arithmetic parentheses are not counted' t_scanner $LIB 'if (ar > 0) { if (c == "(") ar++; else if (c == ")") ar--; put(c); i++; continue }' 'if (ar > 0) { if (c == ")") ar--; put(c); i++; continue }'
prove 'arithmetic never ends' t_scanner $LIB 'else if (c == ")") ar--;' 'else if (c == ")") ar = ar;'
prove "a heredoc with a space before its delimiter is not recognised" t_scanner $LIB 'while (ch[j] == " " || ch[j] == "\t") j++' 'j = j'
prove "<<- is not recognised" t_scanner $LIB 'if (ch[j] == "-") { tab = 1; j++ }' 'j = j'
prove "a double-quoted heredoc delimiter keeps its quotes" t_scanner $LIB 'if (q == "'"'"'" || q == "\"") {' 'if (q == "'"'"'") {'
prove "a backslash heredoc delimiter keeps its backslash" t_scanner $LIB 'if (q == "\\") j++;' 'j = j;'
prove "an unterminated quote hides the command in front of it" t_scanner $LIB 'END { brk() }' ''
prove "an ANSI-C quote is read as a plain single quote" t_scanner $LIB 'st = (prev == "$") ? "A" : "S"' 'st = "S"'
prove "an escape inside double quotes is not skipped" t_scanner $LIB 'if (c == "\\") { qs = 0; i += 2; continue }' ''
prove 'a $( ) inside double quotes is text' t_vanth_denied $LIB 'if (c == "$" && c1 == "(") { push("("); brk(); i += 2; continue }' ''
prove "a backtick inside double quotes is text" t_vanth_denied $LIB 'if (c == "`") { push("`"); brk(); i++; continue }' ''
prove "a closing backtick does not return to the double quote" t_scanner $LIB 'if (sp > 0 && sk[sp] == "`") pop();' ''
prove 'the end of a $( ) does not return to the double quote' t_scanner $LIB 'function pop() { sp--; st = "D"; qs = 0 }' 'function pop() { sp--; st = "N"; qs = 0 }'
prove 'a string with a $( ) in it stays a plain word' t_vanth_false_negatives $LIB 'function pop() { sp--; st = "D"; qs = 0 }' 'function pop() { sp--; st = "D" }'
prove 'parentheses inside a $( ) are not counted' t_scanner $LIB '--sd[sp] == 0' '1'
prove "; does not end a command" t_vanth_denied $LIB 'if (c == ";" || c == "|" || c == "&") {' 'if (c == "|" || c == "&") {'
prove "| does not end a command" t_vanth_denied $LIB 'if (c == ";" || c == "|" || c == "&") {' 'if (c == ";" || c == "&") {'
prove "& does not end a command" t_vanth_denied $LIB 'if (c == ";" || c == "|" || c == "&") {' 'if (c == ";" || c == "|") {'
prove "( does not start a command" t_vanth_denied $LIB 'sd[sp]++; brk();' 'sd[sp]++;'
prove ") does not end a command" t_vanth_denied $LIB '--sd[sp] == 0) pop(); brk();' '--sd[sp] == 0) pop();'
prove "a backtick does not end a command" t_vanth_denied $LIB 'sk[sp] == "`") pop(); brk();' 'sk[sp] == "`") pop();'
prove "a backslash outside quotes is not an escape" t_scanner $LIB 'if (c == "\\") { if (c1 != "\n") { put(c1 ~ /[ \t]/ ? "\002" : c1); prev = c } i += 2; continue }' ''
prove "an empty quoted word is a command name" t_scanner $LIB '(qs && length(qb) > 0) ? qb : "\002"' 'qs ? qb : "\002"'
prove "a comment after a separator is scanned" t_scanner $LIB 'cur = ""; prev = "\n" }' 'cur = ""; prev = "" }'
prove "a comment at the start is scanned" t_scanner $LIB 'BEGIN { st = "N"; prev = "\n" }' 'BEGIN { st = "N" }'
prove "a quoted word is never a command name" t_vanth_denied $LIB 'function word() { return (qs && length(qb) > 0) ? qb : "\002" }' 'function word() { return "\002" }'
prove "a quoted string with a space is a command name" t_scanner $LIB 'function word() { return (qs && length(qb) > 0) ? qb : "\002" }' 'function word() { return qb }'
prove "a backslash-newline is kept" t_vanth_denied $LIB 'if (c1 != "\n") {' '{'
prove "the backslash is kept in the word: \vanth is not vanth (item 1 mutant)" t_vanth_denied $LIB 'put(c1 ~ /[ \t]/ ? "\002" : c1)' 'put(c c1)'
prove "the backslash is kept in the word: \pgrep is not pgrep (item 1 mutant)" t_pgrep_denied $LIB 'put(c1 ~ /[ \t]/ ? "\002" : c1)' 'put(c c1)'
prove "an escaped space or tab splits the word: vanth\ prune is read as vanth prune" t_vanth_allowed $LIB 'c1 ~ /[ \t]/ ? "\002" : c1' 'c1'
prove "an escaped space or tab splits the word: pgrep\ -f is read as pgrep -f" t_pgrep_allowed $LIB 'c1 ~ /[ \t]/ ? "\002" : c1' 'c1'
prove "a character after an escape can open a comment: \;# is read as a comment" t_scanner $LIB '"\002" : c1); prev = c }' '"\002" : c1); prev = ";" }'
prove "a quote after an escaped dollar opens an ANSI-C quote: \$'a\' swallows the rest" t_scanner $LIB '"\002" : c1); prev = c }' '"\002" : c1); prev = "$" }'
prove "command text is glob-expanded" t_noglob $LIB 'set -f   # command text is only ever word-split below, never glob-expanded' ':'
prove "the scanner runs in the caller's locale" t_utf8 $LIB 'export LC_ALL=C' ':'
# messages, fail-open, speed
prove "a deny prints nothing" t_messages $LIB "printf '%s\nMatched: %s\n' \"\$1\" \"\$(printf '%s' \"\$2\" | tr -d '\002' | tr -s ' \t' ' ' | cut -c1-200)\" >&2" ':'
prove "the matched segment is not cut" t_messages $LIB "| cut -c1-200)" ")"
prove "the placeholder byte is shown" t_messages $LIB "tr -d '\002' | " ''
prove "the matched segment is not squeezed" t_messages $LIB "tr -s ' \t' ' ' | " ''
prove "the vanth hook fails closed when jq is missing" t_failopen $HV 'guard_scan_payload || exit 0' 'guard_scan_payload || exit 2'
prove "the pgrep hook fails closed when jq is missing" t_failopen $HP 'guard_scan_payload || exit 0' 'guard_scan_payload || exit 2'
prove "the vanth hook fails closed when its lib is missing" t_failopen $HV '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0' '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 2'
prove "the pgrep hook fails closed when its lib is missing" t_failopen $HP '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0' '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 2'
prove "the vanth hook fails closed when its lib does not load" t_failopen $HV '. "$HOOK_DIR/guard-lib.sh" || exit 0' '. "$HOOK_DIR/guard-lib.sh" || exit 2'
prove "the pgrep hook fails closed when its lib does not load" t_failopen $HP '. "$HOOK_DIR/guard-lib.sh" || exit 0' '. "$HOOK_DIR/guard-lib.sh" || exit 2'
prove "a fork per segment (the old command substitution)" t_scan_speed $HV $'  guard_cmd_words "$seg"\n  if vanth_cleanup_sub; then' $'  guard_cmd_words "$seg"; : "$(:)"\n  if vanth_cleanup_sub; then'
prove "a segment is not capped: one 150 KB word takes quadratic time" t_scan_speed $LIB 'if (length(cur) < 1024) cur = cur t;' 'cur = cur t;'
prove "a quoted word is not capped: one 600 KB string takes quadratic time" t_scan_speed $LIB 'length(qb) < 256 && ' ''
prove "the segment cap is raised past 1 KB: the known false negative closes" t_vanth_false_negatives $LIB 'length(cur) < 1024' 'length(cur) < 4096'
prove "the segment cap is raised past 1 KB: the known false negative closes (pgrep hook)" t_pgrep_false_negatives $LIB 'length(cur) < 1024' 'length(cur) < 4096'
# registration, files, install
prove "the README registration line has no guard" t_readme_registration README.md '[ -x \"$HOME/.agents/hooks/deny-vanth-cleanup.sh\" ] || exit 0; ' ''
prove "the README registration guard fails closed" t_readme_registration README.md 'deny-pgrep-wait-loop.sh\" ] || exit 0;' 'deny-pgrep-wait-loop.sh\" ] || exit 2;'
prove "the README registration execs another file" t_readme_registration README.md 'exec \"$HOME/.agents/hooks/deny-vanth-cleanup.sh\"' 'exec \"$HOME/.agents/hooks/deny-vanth-cleanup2.sh\"'
prove "the README registration is not JSON" t_readme_registration README.md '"matcher": "Bash",' '"matcher": "Bash"'
prove "the README registration of the pgrep hook has no guard" t_readme_registration README.md '[ -x \"$HOME/.agents/hooks/deny-pgrep-wait-loop.sh\" ] || exit 0; ' ''
prove "the README registers no pgrep hook" t_readme_registration README.md $',\n          { "type": "command", "command": "[ -x \\"$HOME/.agents/hooks/deny-pgrep-wait-loop.sh\\" ] || exit 0; exec \\"$HOME/.agents/hooks/deny-pgrep-wait-loop.sh\\"" }' ''
prove "the README registers no vanth hook" t_readme_registration README.md $'          { "type": "command", "command": "[ -x \\"$HOME/.agents/hooks/deny-vanth-cleanup.sh\\" ] || exit 0; exec \\"$HOME/.agents/hooks/deny-vanth-cleanup.sh\\"" },\n' ''
# the raw-launch hook (#31 part C): H1 deny, H2 allow, H3 fail open, H4 documented
prove "allow all: the raw-launch hook exits 0 before it scans (B13 mutant)" t_raw_denied $HW 'guard_scan_payload || exit 0' 'exit 0'
prove "deny all: the raw-launch hook exits 2 before it scans" t_raw_allowed $HW 'guard_scan_payload || exit 0' 'exit 2'
prove "allow codex: the codex branch is dropped (H1 mutant)" t_raw_denied $HW '    codex)' '    NOcodex)'
prove "allow codex exec: the subcommand is not read (H1 mutant)" t_raw_denied $HW '[ "${GW[i]:-}" = exec ] || return 1' '[ "${GW[i]:-}" = NOexec ] || return 1'
prove "allow the worker runner by name (H1 mutant)" t_raw_denied $HW '    velo-openrouter-agent) ;;' '    NOvelo-openrouter-agent) ;;'
prove "allow the worker runner by path: the basename is not taken" t_raw_denied $HW 'base=${GW[0]##*/}' 'base=${GW[0]}'
prove "-c is skipped without its word: codex -c a=b exec is not read" t_raw_denied $HW '-c|--config)       i=$((i + 2)) ;;' '-c|--config)       i=$((i + 1)) ;;'
prove "-m and the other codex options are skipped without their word (H1 mutant)" t_raw_denied $HW '-m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|-i|--image|-o|--enable|--disable|--output-last-message)' 'no-such-option)'
prove "an option does not end the codex options: exec is never reached (H1 mutant)" t_raw_denied $HW '-*)                i=$((i + 1)) ;;' '-*)                break ;;'
prove "no wrapper is looked through in front of the runner" t_raw_denied $LIB "$LIST) wrapped=1 ;;" "NOWRAPPER) wrapped=1 ;;"
prove "a help flag no longer exempts (H2 mutant)" t_raw_allowed $HW '-h|--help|--version) return 1 ;;' '-h|NO--help|--version) return 1 ;;'
prove "a version flag no longer exempts" t_raw_allowed $HW '-h|--help|--version) return 1 ;;' '-h|--help|NO--version) return 1 ;;'
prove "a mention of the words in a heredoc is denied (the deny-on-mention mutant, H2)" t_raw_allowed $LIB 'if (hdk > 0) {' 'if (0) {'
prove "--help after -- exempts although it is a prompt argument there" t_raw_denied $HW '--)                  return 0 ;;' ''
prove "the raw-launch message does not name the entry point" t_messages $HW '  velo-dispatch <issue> <brief> --wait' '  the entry point'
prove "the raw-launch hook fails closed when jq is missing (H3 mutant)" t_failopen $HW 'guard_scan_payload || exit 0' 'guard_scan_payload || exit 2'
prove "the raw-launch hook fails closed when its lib is missing (H3 mutant)" t_failopen $HW '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 0' '[ -r "$HOOK_DIR/guard-lib.sh" ] || exit 2'
prove "the raw-launch hook fails closed when its lib does not load (H3 mutant)" t_failopen $HW '. "$HOOK_DIR/guard-lib.sh" || exit 0' '. "$HOOK_DIR/guard-lib.sh" || exit 2'
prove "the raw-launch header omits the other raw entry points (H4 mutant)" t_hook_docs $HW 'the other raw entry points' 'the other entry points'
prove "the raw-launch README row omits the redirection miss (H4 mutant)" t_hook_docs README.md 'a redirection in front of the command name (`>out velo-openrouter-agent --model x`)' 'a redirection (`>out velo-openrouter-agent --model x`)'
prove "the README registers no raw-launch hook" t_readme_registration README.md $',\n          { "type": "command", "command": "[ -x \\"$HOME/.agents/hooks/deny-raw-launch.sh\\" ] || exit 0; exec \\"$HOME/.agents/hooks/deny-raw-launch.sh\\"" }' ''
prove "the raw-launch hook is not executable" t_hook_files %hooks/deny-raw-launch.sh 644 ''
prove "the raw-launch hook starts with another interpreter" t_hook_files $HW $'#!/bin/bash\n# Claude Code PreToolUse hook for Bash: denies a raw launch' $'#!/usr/bin/env bash\n# Claude Code PreToolUse hook for Bash: denies a raw launch'
prove "a hook is not executable" t_hook_files %hooks/deny-vanth-cleanup.sh 644 ''
prove "a hook starts with another interpreter" t_hook_files $HP $'#!/bin/bash\n# Claude Code PreToolUse hook for Bash, beside' $'#!/usr/bin/env bash\n# Claude Code PreToolUse hook for Bash, beside'
prove "the lib gains a bash-4 construct" t_hook_files $LIB 'export LC_ALL=C' $'export LC_ALL=C\ndeclare -A seeded'
prove "the lib no longer parses" t_hook_files $LIB 'export LC_ALL=C' $'export LC_ALL=C\nif then fi'
prove "install.sh leaves the installed hooks as they were" t_install_hooks install.sh '  chmod_shipped hooks "hook scripts"' '  :'
prove "install.sh makes every file in the installed hooks directory executable (item 4 mutant)" t_install_exec_scope install.sh '  chmod_shipped hooks "hook scripts"' '  find "$DEST/hooks" -type f -exec chmod +x {} +'
prove "install.sh makes every file in the installed bin directory executable" t_install_exec_scope install.sh 'chmod_shipped bin scripts' 'chmod +x "$DEST"/bin/*'
prove "the hook exec check walks hooks/__pycache__ too (item 3 mutant)" t_install_pycache install.sh 'done < <(tooling_files "$SRC/hooks")' 'done < <(find "$SRC/hooks" -type f -print0)'
prove "the walks of the source tree forget the python exclusion" t_install_pycache install.sh "-type d -name __pycache__ -prune -o -type f ! -name '*.pyc' -print0; }" '-type f -print0; }'
prove_env "the scan-speed clock is elapsed time, not CPU time (item 5 mutant)" t_scan_clock SCAN_CLOCK=wall
prove "the vanth header omits the redirection misses (item 2 mutant)" t_hook_docs $HV 'a redirection in front of the command name (>out vanth prune,' 'a redirection (>out vanth prune,'
prove "the pgrep header omits the redirection miss" t_hook_docs $HP 'a redirection in front of the command name (until >/dev/null pgrep' 'a redirection (until >/dev/null pgrep'
prove "the vanth README row omits the redirection misses" t_hook_docs README.md 'a redirection in front of the command name (`>out vanth prune`)' 'a redirection (`>out vanth prune`)'
prove "the pgrep README row omits the redirection miss" t_hook_docs README.md 'a redirection in front of the command name (`until >/dev/null pgrep ...`)' 'a redirection (`until >/dev/null pgrep ...`)'
prove "the vanth header omits xargs substitution" t_hook_docs $HV 'xargs substitution (echo vanth |' 'xargs (echo vanth |'
prove "the vanth README row omits the quoted path with a space" t_hook_docs README.md 'a quoted command path that contains a space, xargs' 'a quoted command path, xargs'
prove "the vanth header omits the 1 KB cap" t_hook_docs $HV 'more than 1 KB' 'a long segment'
prove "install.sh --check ignores a hook that is not executable" t_install_hooks install.sh 'if [[ -e "$DEST/$rel" && ! -x "$DEST/$rel" ]]; then' 'if false; then'
prove "install.sh does not copy hooks" t_install_hooks install.sh $'for d in bin rules skills hooks launchd requirements; do\n  [[ -d "$SRC/$d" ]] || continue\n  mkdir -p "$DEST/$d"' $'for d in bin rules skills launchd requirements; do\n  [[ -d "$SRC/$d" ]] || continue\n  mkdir -p "$DEST/$d"'
prove "install.sh --check does not compare hooks" t_install_hooks install.sh $'for d in bin rules skills hooks launchd requirements; do\n  [[ -d "$SRC/$d" ]] || continue\n  # __pycache__' $'for d in bin rules skills launchd requirements; do\n  [[ -d "$SRC/$d" ]] || continue\n  # __pycache__'
proofs_finish

echo
[ $FAILED -eq 0 ] && echo "all velo-task M3c guard-hook checks passed" || echo "FAILURES"
exit $FAILED

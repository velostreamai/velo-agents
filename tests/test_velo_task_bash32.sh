#!/bin/bash
# velo-task M3c, bar B14 (docs/velo-task-spec.md): every script matching the fixed glob bin/velo-task* runs under /bin/bash
# 3.2.x and is swept for bash-4 constructs, and a seeded `declare -A` fixture fails BOTH halves.
#
# A script whose first line is not exactly #!/bin/bash must not be skipped, or a later bin/velo-task-x written as
# #!/usr/bin/env bash would never be swept. This is the standing check: such a script FAILS here, because B14 cannot vouch for a script it does not know how to run. The sweep and the runner
# are tests/bash32-sweep.sh; tests/test_velo_task_hooks.sh sweeps the hooks with the same code.
#
#   t_premise             the shell is bash 3.2.x                    red when B14_BASH names a bash 5
#   t_sweep_real          the real scripts pass both halves           red for a bash-4 construct in the front end, in a library
#                                                                      function nothing runs, an empty array under set -u (run half
#                                                                      only), a new script under the glob (any interpreter line)
#   t_fixture_fails_both  the seeded fixture fails both halves        red when the fixture is skipped (deleted), neutered, or only
#                                                                      fails one half
#   t_constructs          one seed per construct family; valid-3.2    red when any pattern goes blind, or over-greedy, or the
#                         code is not flagged; each seed is run       comment / unreadable-file rules of bash4_hits are dropped
#
# Every check is also proved RED on a mutated COPY of the code under test (tests/mutation-lib.sh): the repo's files are never
# edited, and a mutation whose anchor is not found exactly once is a failed proof, never a skip.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
unset B14_BASH VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_HOME VELO_TASK_PORT VELO_TASK_UV
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(/usr/bin/mktemp -d "$TMP_ROOT/velo-task-bash32.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
MUT_PATHS="bin tests/bash32-sweep.sh tests/fixtures/velo-task/bash4-seeded.sh tests/fixtures/velo-task/fake-bash5.sh"
. "$HERE/mutation-lib.sh"
. "$HERE/bash32-sweep.sh"   # in this shell only for BASH4_PIECES, to give every piece its blind-mutant proof; the checks source $R's own

t_premise() {  # B14's premise: scripts run under bash 3.2.x. On anything newer the rest of this suite proves nothing
  . "$R/tests/bash32-sweep.sh"
  local v
  v=$(bash32_version) || { echo "FAILED: ${B14_BASH:-$BASH32_DEFAULT} would not report a version"; return 1; }
  case $v in
    3.2.*) echo "note: ${B14_BASH:-$BASH32_DEFAULT} is bash $v" ;;
    *) echo "FAILED: ${B14_BASH:-$BASH32_DEFAULT} is bash '$v', not 3.2.x, so a script that passes here may still fail on the 3.2 the spec pins (on a host whose /bin/bash is newer, point VELO_TEST_BASH32 at a bash 3.2: .github/ci/build-bash32.sh builds one)"; return 1 ;;
  esac
}

t_sweep_real() {  # B14 on the real scripts: the fixed glob, nothing excluded by name
  . "$R/tests/bash32-sweep.sh"
  local f name hits out rc swept=""
  for f in "$R"/bin/velo-task*; do
    [ -e "$f" ] || { bad "the glob bin/velo-task* matched nothing"; break; }
    name=${f##*/}
    [ -r "$f" ] || { bad "$name is not readable, so it cannot be swept"; continue; }
    case $(b14_kind "$f") in
      python) echo "note: $name is python: B14 sweeps bash"; continue ;;
      bash) ;;
      *) bad "$name: the first line is '$(/usr/bin/head -n 1 "$f")', neither #!/bin/bash nor a python shebang. B14 cannot vouch for a script it does not know how to run: make it #!/bin/bash, or teach b14_kind and say why"; continue ;;
    esac
    swept="$swept $name"
    out=$("${B14_BASH:-$BASH32_DEFAULT}" -n "$f" 2>&1) || bad "$name does not parse under bash 3.2: $out"
    hits=$(bash4_hits "$f"); rc=$?
    case $rc in
      0) bad "$name uses a bash-4 construct: $(printf '%s' "$hits" | /usr/bin/head -3 | tr '\n' ' ')" ;;
      1) ;;
      *) bad "$name could not be swept" ;;
    esac
    out=$(bash32_run "$f" --help 2>&1) || bad "$name --help does not exit 0 under bash 3.2: $(printf '%s' "$out" | /usr/bin/head -2 | tr '\n' ' ')"
  done
  case "$swept " in *" velo-task "*) ;; *) bad "bin/velo-task was not among the swept scripts ($swept )" ;; esac
  case "$swept " in *" velo-task-lib.sh "*) ;; *) bad "bin/velo-task-lib.sh was not among the swept scripts ($swept )" ;; esac
  echo "note: swept and run under bash 3.2:$swept"
  [ "$BAD" = 0 ]
}

t_fixture_fails_both() {  # B14: the seeded declare -A fixture fails the sweep AND the run
  . "$R/tests/bash32-sweep.sh"
  local fx="$R/tests/fixtures/velo-task/bash4-seeded.sh" hits out rc
  need "the seeded fixture exists" [ -f "$fx" ]
  need "it is a bash script by the same first-line rule as the real ones" [ "$(b14_kind "$fx")" = bash ]
  hits=$(bash4_hits "$fx"); rc=$?
  need "the sweep flags the seeded fixture" [ "$rc" = 0 ]
  case $hits in *"declare -A"*) ;; *) echo "FAILED: the sweep flagged the fixture, but not for its declare -A: $hits"; return 1 ;; esac
  out=$(bash32_run "$fx" 2>&1); rc=$?
  need "the fixture fails under /bin/bash 3.2 (it exited $rc)" [ "$rc" != 0 ]
  case $out in *"declare: -A: invalid option"*) ;; *) echo "FAILED: the fixture failed under bash 3.2, but not on its declare -A: $out"; return 1 ;; esac
}

# The seeds. A bash-4 seed is "<piece> <outcome> <snippet>": the outcome is what bash 3.2 does with it, E = it reports an error
# (a non-zero exit or text on stderr), S=<text> = it runs silently and prints <text> where bash 4+ prints something else. Every
# snippet is run, so a seed cannot claim a construct is bash 4 when 3.2 accepts it.
b4_seeds() {  # <emit>
  "$1" SW_DECL     E 'declare -A m'
  "$1" SW_DECL     E 'f() { local -A m; }; f'
  "$1" SW_DECL     E 'declare -n r=x'
  "$1" SW_DECL     E 'declare -g g=1'
  "$1" SW_DECL     E 'declare -u x=a; echo "$x"'
  "$1" SW_DECL     E 'echo "#"; declare -A m'
  "$1" SW_DECL     E 'declare -A m  # trailing comment: the code before it is still swept'
  "$1" SW_MAPFILE  E 'mapfile -t a </dev/null'
  "$1" SW_MAPFILE  E 'readarray -t a </dev/null'
  "$1" SW_MAPFILE  E 'coproc cat'
  "$1" SW_CASEMOD  E 'x=Ab; echo "${x,,}"'
  "$1" SW_CASEMOD  E 'x=Ab; echo "${x^^}"'
  "$1" SW_CASEMOD  S=Ab 'a=(Ab); echo "${a[0],,}"'
  "$1" SW_XFORM    E 'x=a; echo "${x@Q}"'
  "$1" SW_REDIR    E 'echo a |& cat'
  "$1" SW_REDIR    E 'echo a &>> /dev/null'
  "$1" SW_REDIR    E 'case a in a) echo 1 ;;& *) echo 2 ;; esac'
  "$1" SW_REDIR    E 'case a in a) echo 1 ;& *) echo 2 ;; esac'
  "$1" SW_TESTV    E '[[ -v x ]]'
  "$1" SW_TESTV    E 'test -v x'
  "$1" SW_TESTV    E '[ ! -v x ]'
  "$1" SW_TESTV    E 'x=1; [[ -R x ]]'
  "$1" SW_SHOPT    E 'shopt -s globstar'
  "$1" SW_SHOPT    E 'shopt -s lastpipe'
  "$1" SW_SHOPT    E 'shopt -s extglob inherit_errexit'
  "$1" SW_SHOPT    E 'shopt -s compat32'
  "$1" SW_WAIT     E 'wait -n'
  "$1" SW_VARS     'S=[]' 'echo "[$BASHPID]"'
  "$1" SW_VARS     'S=[]' 'echo "[$EPOCHSECONDS]"'
  "$1" SW_VARS     'S=[]' 'echo "[$EPOCHREALTIME]"'
  "$1" SW_VARS     'S=[]' 'echo "[$SRANDOM]"'
  "$1" SW_VARS     'S=[]' 'echo "[$BASH_ARGV0]"'
  "$1" SW_NEGIDX   E 'a=(1 2); echo "${a[-1]}"'
  "$1" SW_READ     E 'read -t 0.5 x </dev/null'
  "$1" SW_READ     E 'read -N 3 x </dev/null'
  "$1" SW_READ     E 'read -rN 3 x </dev/null'
  "$1" SW_BRACE    'S={1..10..2}' 'echo {1..10..2}'
  "$1" SW_BRACE    'S=1 2 3' 'echo {01..03}'
  "$1" SW_BRACE    'S={a..e..2}' 'echo {a..e..2}'
  "$1" SW_PRINTFT  E 'printf "%(%s)T\n" -1'
  "$1" SW_NAMEDFD  E 'exec {fd}>/dev/null'
  "$1" SW_UNSETN   E 'x=1; unset -n x'
}
# Valid bash 3.2 that sits close to those patterns: the sweep must not flag it, and it runs clean.
ok_seeds() {  # <emit>
  "$1" 'declare -a a=(1 2); echo "${a[1]}"'
  "$1" 'declare -i n=3; echo $n'
  "$1" 'declare -r r=1; echo $r'
  "$1" 'declare -x e=1; echo $e'
  "$1" 'declare -f >/dev/null; echo ok'
  "$1" 'f() { local -a a=(1); local -r r=2; local -i i=3; echo "${a[0]}$r$i"; }; f'
  "$1" 'readonly r=1; echo $r'
  "$1" 'typeset -i n=2; echo $n'
  "$1" 'mapfileish=1; echo ok'
  "$1" 'x=abc; echo "${x:-d} ${x#a} ${x%%c} ${x//b/B} ${#x} ${x:1:1} ${x: -1}"'
  "$1" 'a=(1 2 3); echo "${a[@]} ${#a[@]} ${!a[@]} ${a[@]:1}"'
  "$1" 'n=x; x=5; echo "${!n}"'
  "$1" 'echo a &>/dev/null; echo ok'
  "$1" 'true && echo ok || echo no'
  "$1" '[[ -n x ]] && echo ok'
  "$1" '[ -n x ] && echo ok'
  "$1" 'test -r /etc/passwd && echo ok'
  "$1" '[[ -f /etc/passwd ]] && echo ok'
  "$1" 'shopt -s extglob nullglob; echo ok'
  "$1" 'shopt -s compat31; echo ok'
  "$1" 'wait; echo ok'
  "$1" 'sleep 0 & wait $!; echo ok'
  "$1" 'read -t 1 x </dev/null; echo ok'
  "$1" 'read -r -d "" x </dev/null; echo ok'
  "$1" 'echo {1..3} {a,b}'
  "$1" 'printf "%s (%d)T\n" a 1'
  "$1" 'printf -v v "%s" 1; echo $v'
  "$1" 'exec 3>/dev/null; exec 3>&-; echo ok'
  "$1" 'x=1; unset x; unset -f nothing; unset -v y; echo ok'
  "$1" '[[ abc =~ ^a ]] && echo ok'
  "$1" 'echo $((1<<2)) $(( 3 >> 1 )) $(( 5 % 3 ))'
}

SEEN=""
emit_b4() {  # <piece> <outcome> <snippet>
  local piece=$1 want=$2 code=$3 f="$SEEDS/seed.sh" out err rc
  SEEN="$SEEN $piece"
  printf '%s\n' "$code" > "$f"
  bash4_hits "$f" >/dev/null || bad "the sweep misses $piece: $code"
  printf '%s\n' "$code" | LC_ALL=C /usr/bin/grep -qE -- "${!piece}" || bad "the $piece pattern itself misses: $code"
  out=$(bash32_run "$f" 2>"$SEEDS/err"); rc=$?; err=$(cat "$SEEDS/err")
  case $want in
    E)   [ "$rc" != 0 ] || [ -n "$err" ] || bad "bash 3.2 runs this without complaint, so it is not a bash-4 construct: $code" ;;
    S=*) [ "$out" = "${want#S=}" ] || bad "bash 3.2 printed [$out], not the silent wrong answer [${want#S=}]: $code" ;;
  esac
}
emit_ok() {  # <snippet>
  local code=$1 f="$SEEDS/seed.sh" out err rc
  printf '%s\n' "$code" > "$f"
  if bash4_hits "$f" >/dev/null; then bad "the sweep flags valid bash 3.2: $code"; fi
  out=$(bash32_run "$f" 2>"$SEEDS/err"); rc=$?; err=$(cat "$SEEDS/err")
  [ "$rc" = 0 ] && [ -z "$err" ] || bad "this negative is not clean bash 3.2 (exit $rc, stderr [$err]): $code"
}

t_constructs() {  # each family of bash-4 constructs is flagged; valid 3.2 is not; the file-level rules of bash4_hits
  . "$R/tests/bash32-sweep.sh"
  local p rc
  SEEDS=$(/usr/bin/mktemp -d "$T/k.XXXXXX") || exit 1
  SEEN=""
  b4_seeds emit_b4
  ok_seeds emit_ok
  for p in $BASH4_PIECES; do
    case "$SEEN " in *" $p "*) ;; *) bad "$p is a sweep piece without a seed here: add one" ;; esac
  done
  printf '# declare -A in a comment\n    # mapfile in an indented comment\n' > "$SEEDS/comments.sh"
  bash4_hits "$SEEDS/comments.sh" >/dev/null; rc=$?
  [ "$rc" = 1 ] || bad "a full-line comment was swept as code (bash4_hits exited $rc)"
  bash4_hits "$SEEDS/does-not-exist.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || bad "a file that cannot be read must be an error, not clean (bash4_hits exited $rc)"
  rm -rf "$SEEDS"
  [ "$BAD" = 0 ]
}

echo "velo-task M3c: B14, bash 3.2"
check "the shell scripts run under is bash 3.2.x" t_premise
check "every script matching bin/velo-task* parses, sweeps clean and runs under bash 3.2" t_sweep_real
check "the seeded declare -A fixture fails the sweep and fails under bash 3.2" t_fixture_fails_both
check "each construct family is flagged and each is bash-4; valid 3.2 is not flagged" t_constructs

echo "mutation proofs"
V=bin/velo-task; L=bin/velo-task-lib.sh; S=tests/bash32-sweep.sh; F=tests/fixtures/velo-task/bash4-seeded.sh
prove_env "the shell is a bash 5" t_premise B14_BASH="$REPO/tests/fixtures/velo-task/fake-bash5.sh"
prove "a bash-4 construct is added to the front end" t_sweep_real $V 'set -euo pipefail' $'set -euo pipefail\ndeclare -A seeded'
prove "a bash-4 construct hides in a library function nothing runs" t_sweep_real $L 'cmd_cancel() {' $'cmd_cancel() {\n  mapfile -t unreached </dev/null'
prove "an empty array under set -u (parses, passes the sweep, dies at 3.2)" t_sweep_real $V 'set -euo pipefail' $'set -euo pipefail\nunreached=(); : "${unreached[@]}"'
prove "a new bash script with a bash-4 construct appears under the glob" t_sweep_real +bin/velo-task-hook $'#!/bin/bash\ndeclare -A x\n' ''
prove "a new script is written as #!/usr/bin/env bash" t_sweep_real +bin/velo-task-future $'#!/usr/bin/env bash\ndeclare -A x\n' ''
prove "a new script has no first-line interpreter" t_sweep_real +bin/velo-task-bare $'declare -A x\n' ''
prove "a new bash script whose --help fails" t_sweep_real +bin/velo-task-broken $'#!/bin/bash\nexit 3\n' ''
prove "a new script nobody can read" t_sweep_real +bin/velo-task-secret $'#!/bin/bash\n' '' %bin/velo-task-secret 000 ''
prove "skip the fixture: it is deleted" t_fixture_fails_both -$F '' ''
prove "the fixture is neutered (declare -a)" t_fixture_fails_both $F 'declare -A seeded' 'declare -a seeded'
prove "the fixture only mentions declare -A (the sweep flags it, bash 3.2 runs it)" t_fixture_fails_both $F 'declare -A seeded' 'echo "declare -A seeded"'
prove "the fixture fails, but not on declare -A" t_fixture_fails_both $F 'set -e' $'set -e\nexit 3'
for p in $BASH4_PIECES; do
  prove "the $p pattern goes blind" t_constructs $S "$p='" "$p='NEVER-MATCHES-"
done
prove "SW_DECL also flags -a" t_constructs $S "[Agclnu]'" "[Agclnua]'"
prove "SW_MAPFILE needs no word end" t_constructs $S '(mapfile|readarray|coproc)([^A-Za-z_]|$)' '(mapfile|readarray|coproc)'
prove "SW_REDIR flags every ;" t_constructs $S '|;;&|;&)' '|;;&|;)'
prove "SW_TESTV also flags -n" t_constructs $S '-[vR][[:space:]]' '-[vRn][[:space:]]'
prove "SW_SHOPT also flags extglob" t_constructs $S '(globstar|autocd|' '(globstar|extglob|autocd|'
prove "SW_WAIT flags a plain wait" t_constructs $S 'wait[[:space:]]+-[a-zA-Z]' 'wait'
prove "SW_NEGIDX also flags ordinary subscripts" t_constructs $S '\[-[0-9]+\]' '\[-?[0-9]+\]'
prove "SW_READ flags every read -t" t_constructs $S '(-t[[:space:]]*[0-9]*\.[0-9]|' '(-t|'
prove "SW_BRACE flags every range" t_constructs $S '\{([0-9]+\.\.[0-9]+\.\.[0-9]+|' '\{([0-9]+\.\.[0-9]+\.\.[0-9]+|[0-9]+\.\.[0-9]+|'
prove "SW_UNSETN flags every unset option" t_constructs $S '*-[a-z]*n'"'" '*-[a-z]*'"'"
prove "bash4_hits sweeps comments" t_constructs $S "| LC_ALL=C /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#'" '| cat'
prove "bash4_hits reads an unreadable file as clean" t_constructs $S '[ -r "$1" ] || { echo "bash4_hits: cannot read $1" >&2; return 2; }' ':'
proofs_finish

echo
[ $FAILED -eq 0 ] && echo "all velo-task M3c bash 3.2 checks passed" || echo "FAILURES"
exit $FAILED

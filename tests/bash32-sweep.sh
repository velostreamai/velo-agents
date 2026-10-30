#!/bin/bash
# bash32-sweep.sh - what bar B14 (docs/velo-task-spec.md) means by "bash 3.2": a text sweep for bash-4 constructs and a
# runner that executes a script under /bin/bash. Sourced by tests/test_velo_task_bash32.sh (the standing B14 check on
# bin/velo-task*) and tests/test_velo_task_hooks.sh (a hook that dies at parse time exits 2, and exit 2 blocks every
# Bash call); not a suite itself.
#
# The two halves see what the other cannot. The sweep reads TEXT, so it finds a construct on a path no test runs (a
# library function, an error branch). Running the script finds what no list of patterns can (a construct nobody
# listed, an empty array under set -u). B14 needs both.
#
# Each SW_ piece is one family of constructs that /bin/bash 3.2 rejects or silently gets wrong, with the version that
# added it. tests/test_velo_task_bash32.sh keeps one seed per piece and proves the piece with a blind mutant, so a new
# piece must be listed in BASH4_PIECES and given a seed there. Full-line comments are not code and are not swept; a
# construct inside a string or a heredoc is flagged, which is the safe side.

SW_DECL='(declare|typeset|local|readonly)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[Agclnu]'              # -A -l -u 4.0, -g 4.2, -n 4.3, -c
SW_MAPFILE='(^|[^A-Za-z_./-])(mapfile|readarray|coproc)([^A-Za-z_]|$)'                                      # 4.0
SW_CASEMOD='\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?(,,?|\^\^?)'                                                      # ${x,,} ${x^^} ${x,} ${x^}: 4.0
SW_XFORM='\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?@[A-Za-z]'                                                          # ${x@Q} ${x@P} ${x@a}: 4.4
SW_REDIR='([|]&|&>>|;;&|;&)'                                                                               # |& &>> ;;& ;&: 4.0
SW_TESTV='(\[\[?|test|!|&&|[|][|]|\()[[:space:]]+-[vR][[:space:]]'                                           # [[ -v x ]] test -v x: 4.2, -R 4.3
SW_SHOPT='shopt[[:space:]]+(-[a-z]+[[:space:]]+)*([a-z_0-9]+[[:space:]]+)*(globstar|autocd|dirspell|checkjobs|direxpand|lastpipe|inherit_errexit|compat3[2-9]|compat[4-9][0-9]|localvar_inherit|localvar_unset|assoc_expand_once|array_expand_once|patsub_replacement|progcomp_alias|globasciiranges|complete_fullquote)([^a-z_0-9]|$)'
SW_WAIT='(^|[^A-Za-z_./-])wait[[:space:]]+-[a-zA-Z]'                                                          # wait -n 4.3, -f 5.0, -p 5.1
SW_VARS='(^|[^A-Za-z_])(BASHPID|EPOCHREALTIME|EPOCHSECONDS|SRANDOM|BASH_ARGV0)([^A-Za-z_0-9]|$)'              # empty at 3.2: 4.0, 5.0, 5.0, 5.1, 5.0
SW_NEGIDX='\[-[0-9]+\]'                                                                                      # ${a[-1]}: 4.3
SW_READ='(^|[^A-Za-z_./-])read[[:space:]]+([^|;&]*[[:space:]])?(-t[[:space:]]*[0-9]*\.[0-9]|-[a-zA-Z]*N)'    # read -t 0.5: 4.0, read -N: 4.1
SW_BRACE='\{([0-9]+\.\.[0-9]+\.\.[0-9]+|0[0-9]+\.\.[0-9]+|[A-Za-z]\.\.[A-Za-z]\.\.[0-9]+)\}'                 # {1..10..2} {01..10}: 4.0
SW_PRINTFT='%\([^)]*\)T'                                                                                     # printf '%(%s)T': 4.2
SW_NAMEDFD='(^|[[:space:]])\{[A-Za-z_][A-Za-z_0-9]*\}[<>]'                                                   # exec {fd}>file: 4.1
SW_UNSETN='unset[[:space:]]+(-[a-z]+[[:space:]]+)*-[a-z]*n'                                                  # unset -n: 4.3
BASH4_PIECES="SW_DECL SW_MAPFILE SW_CASEMOD SW_XFORM SW_REDIR SW_TESTV SW_SHOPT SW_WAIT SW_VARS SW_NEGIDX SW_READ SW_BRACE SW_PRINTFT SW_NAMEDFD SW_UNSETN"
BASH4_RE=""
for _p in $BASH4_PIECES; do BASH4_RE="${BASH4_RE:+$BASH4_RE|}${!_p}"; done
unset _p

bash4_hits() {  # <file>: print the lines that use a bash-4 construct as N:text. 0 = some, 1 = none, 2 = the file could not be read
  [ -r "$1" ] || { echo "bash4_hits: cannot read $1" >&2; return 2; }
  LC_ALL=C /usr/bin/grep -nE "$BASH4_RE" "$1" | LC_ALL=C /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#'
}

b14_kind() {  # <file>: what its first line says it is: bash (exactly #!/bin/bash, the shell the spec pins), python, or other
  case $(/usr/bin/head -n 1 "$1") in
    '#!/bin/bash') echo bash ;;
    '#!'*python*)  echo python ;;
    *)             echo other ;;
  esac
}

# The shell B14 runs scripts under. /bin/bash is bash 3.2.57 on macOS, and the spec pins 3.2; a host whose /bin/bash is newer (every
# Linux) builds a 3.2 of its own and names it in VELO_TEST_BASH32 (.github/ci/build-bash32.sh does that for CI). B14_BASH is the
# suites' own override, for the proof that a bash 5 turns the premise red. With neither set the premise check says what to do.
BASH32_DEFAULT="${VELO_TEST_BASH32:-/bin/bash}"

bash32_version() {  # the version of the shell B14 runs scripts under
  "${B14_BASH:-$BASH32_DEFAULT}" -c 'echo "$BASH_VERSION"'
}

bash32_run() {  # <script> [args...]: the script under that shell, with nothing inherited from the caller's environment
  local home rc
  home=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/b32run.XXXXXX") || return 1
  /usr/bin/env -i HOME="$home" VELO_TASK_HOME="$home/vt" PATH=/usr/bin:/bin:/usr/sbin:/sbin "${B14_BASH:-$BASH32_DEFAULT}" "$@"
  rc=$?
  rm -rf "$home"
  return "$rc"
}

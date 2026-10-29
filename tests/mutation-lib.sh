#!/bin/bash
# mutation-lib.sh - "a test never seen red does not count" for the velo-task guard suites. Sourced by
# test_velo_task_hooks.sh and test_velo_task_bash32.sh; not a suite itself.
#
# Every check is run twice: on the real tree, where it must pass, and on a deliberately broken COPY of the code under
# test, where it must go RED. The repo's files are never edited, and a mutation whose anchor is not found exactly once
# is a failed proof, never a skip.
#
# The suite sets REPO (the tree under test), MUT_PATHS (what a proof copies: paths under REPO, space separated) and
# T (a private temp directory), then reads the code under test through $R (R=$REPO; a proof points it at its copy):
#   check  <label> <fn>                      <fn> runs in a subshell and must pass on the real tree
#   prove  <label> <fn> <spec> <anchor> <replacement> [<spec> <anchor> <replacement>]...
#                                            <fn> must go RED on a copy with the mutation applied. <spec> is a file under
#                                            $R: its <anchor> (exactly one occurrence) becomes <replacement>. +file creates
#                                            it (content = <anchor>, mode 755), -file deletes it, %file sets its mode to <anchor>
#   prove_env <label> <fn> VAR=value...      <fn> must go RED on an unmodified copy run with these variables set
#   proofs_finish                            run the queued proofs VELO_TASK_PROOF_JOBS (default 4) at a time and report them
# A check prints `FAILED: <what>` for everything wrong (bad/need) and returns non-zero; `note: <text>` lines are shown
# when it passes. Mutations anchor on text, so a proof says what it breaks in the code, not where.

FAILED=0
BAD=0
PROOF_JOBS="${VELO_TASK_PROOF_JOBS:-4}"
PROOF_N=0; PROOF_LABEL=(); PROOF_FN=(); PROOF_ROOT=(); PROOF_ENV=()

pass()  { printf '  ok   %s\n' "$1"; }
flunk() { printf '  FAIL %s\n' "$1"; FAILED=1; }
bad()   { echo "FAILED: $*"; BAD=$((BAD + 1)); }                                  # collect: keep going, report every case
need()  { local d="$1"; shift; "$@" || { echo "FAILED: $d"; exit 1; }; }          # fail fast

check() {  # <label> <fn>
  local out line
  if out=$( ( "$2" ) 2>&1 ); then
    pass "$1"
    while IFS= read -r line; do case "$line" in note:*) printf '        %s\n' "$line" ;; esac; done <<<"$out"
  else
    flunk "$1"; printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

mutate_file() {  # <file> <anchor> <replacement>: the anchor must occur exactly once. Literal, no regex; the file's mode is kept
  local f="$1" tmp="$1.mut.$$"
  MUT_A="$2" MUT_R="$3" MUT_F="$1" /usr/bin/awk 'BEGIN { RS = "\001"; a = ENVIRON["MUT_A"]; r = ENVIRON["MUT_R"] }
    { all = all $0 }
    END { s = all; o = ""; n = 0
      while (a != "" && (i = index(s, a)) > 0) { n++; o = o substr(s, 1, i - 1) r; s = substr(s, i + length(a)) }
      if (n != 1) { printf "mutation anchor found %d times (want 1) in %s\n", n, ENVIRON["MUT_F"] > "/dev/stderr"; exit 1 }
      printf "%s%s", o, s }' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f" && rm -f "$tmp"
}

proof_copy() {  # <dest>: the code under test, copied
  local p
  mkdir -p "$1" || return 1
  for p in $MUT_PATHS; do
    mkdir -p "$1/$(dirname "$p")" && cp -Rp "$REPO/$p" "$1/$p" || return 1
  done
}

prove() {  # <label> <fn> <spec> <anchor> <replacement> [...]
  local label="$1" fn="$2" n op anchor repl f m
  shift 2
  PROOF_N=$((PROOF_N + 1)); n=$PROOF_N
  m="$T/pj$n/code"
  proof_copy "$m" || { flunk "MUTATION-PROOF $label: could not copy the code under test"; return; }
  while [ "$#" -ge 3 ]; do
    op="$1"; anchor="$2"; repl="$3"; shift 3
    case "$op" in
      +*) f="$m/${op#+}"; mkdir -p "$(dirname "$f")"; printf '%s' "$anchor" > "$f"; chmod 755 "$f" ;;
      -*) rm -f "$m/${op#-}" ;;
      %*) chmod "$anchor" "$m/${op#%}" ;;
      *)  mutate_file "$m/$op" "$anchor" "$repl" || { flunk "MUTATION-PROOF $label: anchor problem in $op (see above)"; return; } ;;
    esac
  done
  PROOF_LABEL[n]="$label"; PROOF_FN[n]="$fn"; PROOF_ROOT[n]="$m"; PROOF_ENV[n]=""
}

prove_env() {  # <label> <fn> VAR=value...
  local label="$1" fn="$2" n m
  shift 2
  PROOF_N=$((PROOF_N + 1)); n=$PROOF_N
  m="$T/pj$n/code"
  proof_copy "$m" || { flunk "MUTATION-PROOF $label: could not copy the code under test"; return; }
  PROOF_LABEL[n]="$label"; PROOF_FN[n]="$fn"; PROOF_ROOT[n]="$m"; PROOF_ENV[n]="$*"
}

red_text() {  # what a red check printed: its first FAILED line, cut to one line
  local line
  line=$(printf '%s\n' "$1" | grep -m 1 '^FAILED:') || line="${1%%$'\n'*}"
  printf '%s' "$line" | cut -c1-170
}

proof_job() {  # <n>: runs in the background; the verdict goes to a file for the parent
  local n="$1" out rc
  out=$( ( for kv in ${PROOF_ENV[n]}; do export "$kv"; done; R="${PROOF_ROOT[n]}"; "${PROOF_FN[n]}" ) 2>&1 ); rc=$?
  if [ "$rc" = 0 ]; then
    printf 'FAIL\nMUTATION-PROOF %s: %s stayed GREEN with the mutation\n' "${PROOF_LABEL[n]}" "${PROOF_FN[n]}"
  else
    printf 'ok\nMUTATION-PROOF | test=%s | mutation=%s | red="%s"\n' "${PROOF_FN[n]}" "${PROOF_LABEL[n]}" "$(red_text "$out")"
  fi > "$T/pj$n/result"
}

proofs_finish() {
  local n=1 first k pids res
  while [ "$n" -le "$PROOF_N" ]; do
    first=$n; pids=""
    while [ "$n" -le "$PROOF_N" ] && [ $((n - first)) -lt "$PROOF_JOBS" ]; do
      if [ -n "${PROOF_FN[n]:-}" ]; then proof_job "$n" & pids="$pids $!"; fi
      n=$((n + 1))
    done
    [ -z "$pids" ] || wait $pids
    for ((k = first; k < n; k++)); do
      [ -n "${PROOF_FN[k]:-}" ] || continue
      res="$T/pj$k/result"
      if [ ! -s "$res" ]; then flunk "MUTATION-PROOF #$k (${PROOF_LABEL[k]}): the proof produced no verdict"
      elif [ "$(head -n 1 "$res")" = ok ]; then pass "$(tail -n +2 "$res")"
      else flunk "$(tail -n +2 "$res")"; fi
      chmod -R u+rwx "$T/pj$k" 2>/dev/null; rm -rf "$T/pj$k"
    done
  done
}

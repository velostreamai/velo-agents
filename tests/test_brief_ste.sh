#!/bin/bash
# Brief instruction style, ASD-STE100 (spec §13). The check is ADVISORY: it must warn on a
# long or chained step and must never refuse a brief. These drive the block EXTRACTED from
# the shipped velo-brief-lint.sh, not a copy of it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/velo-brief-lint.sh"
FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES+1)); }

BLOCK=$(sed -n '/^# >>> velo-brief-ste/,/^# <<< velo-brief-ste/p' "$LIB")
[[ -n "$BLOCK" ]] || { echo "  FAIL  no velo-brief-ste block in velo-brief-lint.sh"; exit 1; }
. "$LIB"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

ste() {   # <brief text> -> "<rc>|<stderr on one line>"
  printf '%s' "$1" > "$TMP"
  local out rc
  out=$(velo_brief_ste_warn "$TMP" 2>&1); rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}
expect() {   # <label> <want substring, or "" for silence> <brief text>
  local got rc out; got=$(ste "$3"); rc=${got%%|*}; out=${got#*|}
  if [[ "$rc" != 0 ]]; then fail "$1: rc=$rc — the style check must never refuse"; return; fi
  if [[ -z "$2" ]]; then
    [[ -z "$out" ]] && pass "$1" || fail "$1: wanted silence, got: ${out:0:200}"
  else
    [[ "$out" == *"$2"* ]] && pass "$1" || fail "$1: wanted '$2' in: ${out:0:200}"
  fi
}

echo "brief style: STE100 steps (spec §13)"
expect "short single-action step is silent" "" $'1. Run `cargo check --no-default-features`.\n2. Commit the change.\n'
expect "over 20 words warns" "23 words" \
  $'1. Edit the file so that the function returns the value that the caller expects to see when the window closes late at night.\n'
expect "a code span counts as one word" "" \
  $'1. Run `cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E "test(a) or test(b) or test(c) or test(d) or test(e)"`.\n'
expect "two sentences warn" "more than one sentence" $'1. Edit the file. Run the tests.\n'
expect "', then' warns" "chained action" $'1. Edit the file, then run the tests.\n'
expect "' and then' warns" "chained action" $'1) Edit the file and then commit.\n'
expect "continuation line joins the step" "23 words" \
  $'1. Edit the file so that the function returns the value that the caller\n   expects to see when the window closes late at night.\n'
expect "a step inside a fence is not checked" "" \
  $'```\n1. Edit the file. Run the tests, then commit and then push and then go home now.\n```\n'
expect "bullets are not steps" "" $'- Edit the file. Run the tests, then commit.\n'
expect "the warning names the line" "line 3" $'# Steps\n\n1. Edit it. Commit it.\n'

# Wiring: both tools that judge a brief must run the style check AFTER the refusing lint.
for tool in velo-dispatch velo-spec-review; do
  if grep -q '^velo_brief_ste_warn "\$BRIEF"' "$ROOT/bin/$tool"; then pass "$tool runs the style check"
  else fail "$tool does not run velo_brief_ste_warn"; fi
done

[[ $FAILURES -eq 0 ]] && echo "test_brief_ste: all passed" || { echo "test_brief_ste: $FAILURES failed"; exit 1; }

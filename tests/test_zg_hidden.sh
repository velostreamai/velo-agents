#!/bin/bash
# zg must be able to see dot-directories (#2128).
#
# Both of zg's routes skipped `.agents/`, `.github/` and `.config/`, and neither
# said so:
#
#   --rg   ripgrep skips hidden paths by default and zvec-grep's managed
#          invocation did not pass --hidden, so the DOCUMENTED no-index fallback
#          returned "No matches" on files that plainly contain the term.
#
#   index  `zg index` without --hidden skipped them too — and the index did not
#          merely miss them, it answered anyway. `PROD-WIRING-BEFORE` exists in
#          exactly one file in the repo (.agents/rules/velo-impl.md) and zero
#          files under docs/; the query returned FOUR ranked docs/ hits, none
#          containing the string.
#
# Four plausible answers for a term it cannot see is worse than none, and a
# worker cannot tell it from a real result.
#
# NOT offered as the explanation for #2075 (zg going unused): the #2091 runner
# log records zero zg invocations by any route, so that worker never reached
# either of these defects. A mechanism, not a demonstrated cause.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "zg hidden-path coverage"

# ── the shim injects --hidden on the --rg route ────────────────────────────
# Asserted against the SHIM's own behaviour, not a copy of its logic: the
# injection is what ships, and a re-implementation here would prove only that
# this file agrees with itself.
if [[ -x "$BIN/zg" ]]; then
  ok "zg shim present at $BIN/zg"
else
  fail "no zg shim — nothing below is meaningful"
  exit 1
fi

# A fixture whose ONLY match lives under a dot-directory. Built here rather than
# pointed at the repo so the test does not depend on repo contents that move.
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/.dotdir" "$TMPD/plain"
printf 'needle_in_a_dotdir\n' > "$TMPD/.dotdir/f.txt"
printf 'unrelated\n'          > "$TMPD/plain/g.txt"

OUT=$("$BIN/zg" query --rg -F "needle_in_a_dotdir" "$TMPD" 2>&1)
if grep -q 'needle_in_a_dotdir' <<<"$OUT"; then
  ok "--rg finds a match inside a dot-directory"
else
  fail "--rg missed a dot-directory match (this is the #2128 B regression): $(head -1 <<<"$OUT")"
fi

# The flag reaches ripgrep, and the .git / .zvec-grep excludes still apply —
# --hidden must not turn the object store into search results.
DBG=$("$BIN/zg" query --rg --debug -F "needle_in_a_dotdir" "$TMPD" 2>&1 | grep -o 'rg_command=.*' | head -1)
if grep -q -- '--hidden' <<<"$DBG"; then
  ok "the shim passes --hidden to the managed ripgrep"
else
  fail "no --hidden in the rg command: $DBG"
fi
for EXC in '.git' '.zvec-grep'; do
  if grep -qF "$EXC" <<<"$DBG"; then
    ok "$EXC is still excluded despite --hidden"
  else
    fail "$EXC exclusion lost — the index or object store would be searchable"
  fi
done

# Injected exactly once when the caller already asked.
DBG2=$("$BIN/zg" query --rg --hidden --debug -F "needle_in_a_dotdir" "$TMPD" 2>&1 | grep -o 'rg_command=.*' | head -1)
if [[ "$(grep -o -- '--hidden' <<<"$DBG2" | wc -l | tr -d ' ')" == "1" ]]; then
  ok "--hidden is not duplicated when the caller supplies it"
else
  fail "--hidden duplicated: $DBG2"
fi

# ── the indexed route must NOT receive the flag ────────────────────────────
# It is an rg-option. Injecting it into the indexed route would be an unknown
# flag, turning a working query into an error.
IDX=$("$BIN/zg" query --limit 1 --fts "anything" 2>&1)
if grep -qiE 'unknown|unrecognized|unexpected' <<<"$IDX"; then
  fail "indexed route rejected its arguments — --hidden leaked into it: $(head -1 <<<"$IDX")"
else
  ok "indexed route unaffected by the injection"
fi

# ── the rewrite itself, executed — not a grep over the source ──────────────
# The previous version of this block counted literal `"$@"` occurrences, which a
# reviewer correctly called out: absence of that string does not prove any exec
# path passes the array correctly, and only whichever install route exists on the
# test machine is ever exercised behaviourally. So a broken path could ship and
# fail on someone else's install while this suite stayed green (#2129 review P2).
#
# Two changes answer it. The shim now resolves the binary and exec's ONCE, so
# there is no per-path argv handling left to diverge; and the rewrite is a
# function, eval'd and run here against the real implementation.
eval "$(sed -n '/^zg_rewrite_args() {/,/^}/p' "$BIN/zg")"
if declare -F zg_rewrite_args >/dev/null; then
  ok "extracted zg_rewrite_args from the shim"
else
  fail "zg_rewrite_args NOT extracted — the cases below would test nothing"
  exit 1
fi

# `${ARGS[*]}` on an EMPTY array is an unbound-variable error under `set -u` in
# bash 3.2, which is what macOS ships and what the shim's `#!/bin/bash` selects.
# The shim had the same bug — `zg` with no arguments died with
# `ARGS[@]: unbound variable` — and this assertion is what surfaced it.
rw() { ARGS=(); zg_rewrite_args "$@"; printf '%s' "${ARGS[*]+${ARGS[*]}}"; }
case_is() {  # <desc> <expected> <args...>
  local desc="$1" want="$2"; shift 2
  local got; got=$(rw "$@")
  if [[ "$got" == "$want" ]]; then ok "$desc"
  else fail "$desc: got '$got', want '$want'"; fi
}

# The documented shape, which is the only one that gets rewritten.
case_is "--rg gets --hidden"                     "query --rg --hidden -F n /tmp" query --rg -F n /tmp
case_is "caller's own --hidden is not doubled"   "query --rg --hidden -F x"      query --rg --hidden -F x
case_is "post-'--' literal is left alone"        "query --rg --hidden -F -- --rg" query --rg -F -- --rg

# Everything else is left EXACTLY as given. These are the cases two earlier
# attempts got wrong, and they all share one shape: `--rg` appearing as an option
# VALUE rather than as the route selector. Injecting there put `--hidden` on the
# INDEXED route, which rejects it — turning a working query into an error.
#
# Round 1 scanned every argument, so --fts/--limit values misfired.
case_is "an --fts VALUE of '--rg' is untouched"  "query --fts --rg"              query --fts --rg
case_is "a --limit VALUE of '--rg' is untouched" "query --limit --rg foo"        query --limit --rg foo
# Round 2 parsed, but against a hardcoded list that omitted the file-filter
# options. This is the case the second review reproduced.
case_is "a -g VALUE of '--rg' is untouched"      "query -g --rg"                 query -g --rg
case_is "a -t VALUE of '--rg' is untouched"      "query -t --rg"                 query -t --rg
case_is "a --glob VALUE of '--rg' is untouched"  "query --glob --rg"             query --glob --rg
case_is "indexed route untouched"                "query plain english"           query "plain english"
case_is "a non-query subcommand is untouched"    "index --hidden"                index --hidden
case_is "empty argv survives set -u"             ""

# A --hidden that is a GLOB VALUE must not suppress the real injection. The
# result carries --hidden twice; ripgrep accepts that, verified end to end below.
case_is "a --hidden glob value does not suppress" \
        "query --rg --hidden -g --hidden needle" query --rg -g --hidden needle

# Empty argv must not kill the shim. Bash 3.2 (what macOS ships, and what
# `#!/bin/bash` selects here) errors on an empty array expansion under `set -u`,
# where the special `"$@"` it replaced did not. Behavioural, because the source
# looks correct either way.
OUT=$("$BIN/zg" 2>&1); RC=$?
if [[ $RC -ne 0 ]] || grep -qi 'unbound variable' <<<"$OUT"; then
  fail "bare 'zg' failed: $(head -1 <<<"$OUT")"
else
  ok "bare 'zg' (empty argv) survives set -u on bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
fi

# One exec site for the installed binary, so the flag cannot depend on which of
# three install locations happens to exist on a given machine.
SITES=$(grep -c 'exec "\$REAL"' "$BIN/zg")
if [[ "$SITES" -eq 1 ]]; then
  ok "the installed-binary route has exactly one exec site"
else
  fail "expected 1 'exec \$REAL' site, found $SITES — per-path argv handling can diverge"
fi

# No EXEC line may pass the unrewritten "$@". Scoped to exec/npx lines: the
# earlier version counted every "$@" in the file and so flagged the legitimate
# `zg_rewrite_args "$@"` call and the comments describing the bug.
BARE=$(grep -nE '^[^#]*(exec |timeout [0-9]+ npx).*"\$@"' "$BIN/zg" | wc -l | tr -d ' ')
if [[ "$BARE" -eq 0 ]]; then
  ok "no exec path passes the unrewritten \"\$@\""
else
  fail "$BARE exec line(s) still pass \"\$@\" — the flag would depend on install location"
fi

# ── velo-dispatch indexes hidden paths ─────────────────────────────────────
# Without this the index skips .agents/ and then answers from docs/ anyway.
if grep -qE 'zg" index --hidden|zg index --hidden' "$BIN/velo-dispatch"; then
  ok "velo-dispatch builds the index with --hidden"
else
  fail "velo-dispatch's index build omits --hidden — .agents/ will be invisible"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all zg hidden-path checks passed" || echo "FAILURES"
exit $FAILED

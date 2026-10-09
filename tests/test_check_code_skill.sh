#!/usr/bin/env bash
# Every SDK-runner route inlines /check-code; the codex route does not (#2301).
#
# The policy's Pre-push HARD GATE item 2 requires `/check-code` before any push.
# `/check-code` is a Claude Code slash command and the SDK runners have no Skill
# tool, so on those routes the requirement could not be met at all — #2291's
# worker honestly reported "skill unavailable on this runtime". The runners
# already accepted `--skill`; velo-dispatch was the only missing link.
#
# Like test_routing.sh and test_dispatch_wait.sh, this drives the blocks
# extracted FROM THE SHIPPED SCRIPT rather than a copy of the logic, so a
# rewrite that deletes the flag or the preflight goes red here.
#
# Two things are asserted about the launch block, and they are different claims:
#   * each SDK arm passes the skill, and
#   * all four pass the SAME variable, resolved once — a path written per route
#     is a path that drifts per route, which is the defect the brief named.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/../bin/velo-dispatch"
RC=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

check()     { if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-200)"; RC=1; fi; }
check_not() { if [[ "$2" != *"$3"* ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: did NOT want '$3': $(tr '\n' ' ' <<<"$2" | cut -c1-200)"; RC=1; fi; }

# ── 1. the launch block, extracted from the shipped script ───────────────────
python3 - "$DISPATCH" "$TMPD/arms.sh" <<'PYEOF' || exit 1
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index('case "$NAME" in')
end = src.index("\nesac", start) + len("\nesac\n")
pathlib.Path(sys.argv[2]).write_text(
    '#!/usr/bin/env bash\n'
    'die()  { echo "DIE: $*"; exit 1; }\n'
    'ok()   { echo "OK: $*"; }\n'
    'warn() { echo "WARN: $*"; }\n'
    + src[start:end] +
    'printf \'%s\\n\' "${CMD[@]}"\n')
print("  extracted the real launch block from velo-dispatch")
PYEOF

# Drive the extracted arms. HOME is redirected so the runner path the arms build
# stays a real-looking path without touching the operator's ~/.agents. These
# must be exported: a bare `A=1 B=2 …` list with no command makes shell-locals,
# and the arms run in a child `bash`. Unexported, every one of them arrives
# empty — which reads as "the route passes no skill" instead of the test's own
# mistake.
export HOME="$TMPD"
export NAME="" MODEL_ID="" LMSTUDIO_URL="http://127.0.0.1:1234/v1" POLICY="$TMPD/policy.md" \
  WT="$TMPD/wt" TASK="the brief" PROMPT_TIMEOUT=2400 MAX_TURNS=250 MAX_BUDGET_USD=5 \
  RECORD_MAX_TURNS="" CHECK_CODE_SKILL="$TMPD/check-code.md"

launch() { NAME="$1" bash "$TMPD/arms.sh" 2>&1; }

echo
echo "the SDK-runner routes carry the skill"
for route in velo-local velo-deepseek velo-haiku velo-glm; do
  OUT=$(launch "$route")
  check "$route names the --skill flag"  "$OUT" "--skill"
  check "$route passes the shared path"  "$OUT" "$TMPD/check-code.md"
done

echo
echo "all four resolve the SAME variable — one path, not four literals"
# Extracted per arm so the check survives a reformat. Three arms each holding
# their own literal is exactly the drift the brief asked against.
SAME=$(python3 - "$DISPATCH" <<'PYEOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
arms = dict(re.findall(r'(velo-(?:local|deepseek|haiku|glm))\)(.*?);;\n', src, re.DOTALL))
vals = {k: sorted(set(re.findall(r'--skill\s+"([^"]+)"', v))) for k, v in arms.items()}
print("MISSING-ARM" if len(vals) != 4 else
      (list(vals.values())[0][0] if len({tuple(v) for v in vals.values()}) == 1
       and all(len(v) == 1 for v in vals.values()) else "DRIFTED: %s" % vals))
PYEOF
)
check "one --skill value across all four SDK arms" "$SAME" '$CHECK_CODE_SKILL'
# Asserted against the VARIABLE, not an expanded path: three arms each carrying
# the same literal string would satisfy "one value" while still being three
# literals that drift the first time one is edited.
check_not "and that value is not a hardcoded literal" "$SAME" ".md"

echo
echo "codex is untouched — it takes no --skill flag"
# The arm dies on a missing codex CLI before building CMD on most machines, and
# that is the shipped guard; asserting on the arm's text is the honest claim here.
CODEX_ARM=$(python3 - "$DISPATCH" <<'PYEOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'velo-codex\)(.*?);;\n', src, re.DOTALL)
print(m.group(1) if m else "ARM-NOT-FOUND")
PYEOF
)
check_not "the codex arm passes no skill" "$CODEX_ARM" "--skill"
check_not "the codex arm has no runner wrapper" "$CODEX_ARM" "velo-openrouter-agent"

echo
echo "── preflight: a missing skill file fails loud ─────────"
# >>> the block is marked in velo-dispatch so this test extracts the real one.
BLOCK=$(sed -n '/^# >>> velo-check-code-skill/,/^# <<< velo-check-code-skill/p' "$DISPATCH")
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL could not extract the check-code preflight from velo-dispatch."
  echo "        Deleted or renamed, the gate stops running and nothing notices —"
  echo "        which is the failure this file exists to prevent."
  exit 1
fi
printf '#!/usr/bin/env bash\ndie() { echo "DIE: $*"; exit 1; }\nok() { echo "OK: $*"; }\nwarn() { echo "WARN: $*"; }\n%s\n' "$BLOCK" > "$TMPD/preflight.sh"

PF_RC_FILE="$TMPD/pf.rc"
run_pf() {  # $1 = NAME, $2 = skill file (may not exist)
  # rc goes to a sidecar: command substitution runs this in a subshell, so a
  # variable set here would not survive the `OUT=$(...)` that captures output.
  NAME="$1" CHECK_CODE_SKILL="$2" bash "$TMPD/preflight.sh" >"$TMPD/pf.out" 2>&1
  echo $? > "$PF_RC_FILE"
  cat "$TMPD/pf.out"
}
refuses() {  # name, output — PASS only when it exited nonzero AND said why
  local rc; rc=$(cat "$PF_RC_FILE")
  if [[ "$rc" -ne 0 && "$2" == *"DIE:"* && "$2" == *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: rc=$rc, wanted 'DIE:' + '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-160)"; RC=1; fi
}
accepts() {  # name, output
  local rc; rc=$(cat "$PF_RC_FILE")
  if [[ "$rc" -eq 0 && "$2" != *"DIE:"* && "$2" == *"$3"* ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: rc=$rc, wanted '$3' and no refusal in: $(tr '\n' ' ' <<<"$2" | cut -c1-160)"; RC=1; fi
}

GOOD="$TMPD/check-code.md"; printf 'check the test coverage\n' > "$GOOD"
: > "$TMPD/empty.md"

accepts "a present skill passes" "$(run_pf velo-deepseek "$GOOD")" "check-code skill"

OUT=$(run_pf velo-deepseek "$TMPD/absent.md")
refuses "a missing skill fails loud" "$OUT" "the /check-code skill is missing"
check   "naming the path it wanted"  "$OUT" "absent.md"
check   "refusing rather than dropping" "$OUT" "silently skips the gate"

# Empty is the other silent shape: the flag is satisfied, the gate is not.
refuses "an empty skill fails loud" "$(run_pf velo-glm "$TMPD/empty.md")" "EMPTY"

for route in velo-local velo-deepseek velo-haiku velo-glm; do
  run_pf "$route" "$TMPD/absent.md" > /dev/null
  refuses "$route refuses a missing skill" "$(cat "$TMPD/pf.out")" "is missing"
done

# codex has no --skill flag at all, so requiring the file there would block a
# dispatch that cannot use it — the route is exempt, and says so.
OUT=$(run_pf velo-codex "$TMPD/absent.md")
check_not "codex is not blocked by the skill gate" "$OUT" "DIE:"
check     "codex says why" "$OUT" "not applicable to the codex route"

echo
echo "the preflight and the arms are tied to the same variable"
# A preflight that validates one path while the arms pass another checks nothing.
ARM_VAR=$(python3 - "$DISPATCH" <<'PYEOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
arms = re.findall(r'--skill\s+"([^"]+)"', src)
print(arms[0] if arms and len(set(arms)) == 1 else "DRIFTED:%s" % arms)
PYEOF
)
check "arms pass \$CHECK_CODE_SKILL" "$ARM_VAR" '$CHECK_CODE_SKILL'
grep -qF '[[ "$NAME" == "velo-codex" ]]' <<<"$BLOCK" \
  && echo "  PASS  the preflight keys off the routed NAME" \
  || { echo "  FAIL  the preflight does not branch on NAME"; RC=1; }
grep -qF '"$CHECK_CODE_SKILL"' <<<"$BLOCK" \
  && echo "  PASS  the preflight validates that same variable" \
  || { echo "  FAIL  the preflight validates something else"; RC=1; }

echo
[[ $RC -eq 0 ]] && echo "  ✅ check-code skill inlining OK" || echo "  ❌ check-code skill inlining FAILED"
exit $RC

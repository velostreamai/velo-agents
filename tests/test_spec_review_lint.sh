#!/bin/bash
# velo-spec-review runs the brief lint velo-dispatch runs, BEFORE it attests (2026-10-11).
#
# The failure this pins: `velo-spec-review <n> <brief> --by <who>` printed "ok ... reviewed",
# then velo-dispatch refused the same brief ("no explicit commit/push authorization") or the
# issue ("no 'worker:*' label"). Each refusal cost a review round, and applying the label moved
# the issue's updatedAt, so the review had to be redone. The attestation certified a brief that
# dispatch would never accept.
#
# What is driven here is the shipped code, never a copy of it:
#   - velo_brief_lint, sourced from bin/velo-brief-lint.sh (the one definition both tools run)
#   - velo-spec-review in attest mode, against a stub gh and a fake HOME, so the spec it attests
#     is a file in a sandbox and never the live checkout
#   - velo-dispatch --dry-run, against the same stub and a scratch origin, so the refusal the lint
#     gives dispatch is observed, not read off the source
#   - the model line velo-dispatch prints for its launch, and the supervisor that writes the log
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES+1)); }
check() {  # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi
}
has() {    # <label> <haystack> <needle> — fixed-string substring
  if [[ "$2" == *"$3"* ]]; then pass "$1"
  else fail "$1: wanted '$3' in: $(tr '\n' ' ' <<<"$2" | cut -c1-240)"; fi
}

# The bullet velo_brief_lint prints for a brief with no commit/push authorization (spec §8).
AUTH_BULLET="  - no explicit commit/push authorization (spec §8) — the brief is the only thing telling a worker what it may do"

LIB="$BIN/velo-brief-lint.sh"
echo "one definition: the lint is a sourceable file, and both tools source it"
if [[ -f "$LIB" ]]; then pass "bin/velo-brief-lint.sh exists"; else fail "bin/velo-brief-lint.sh exists ($LIB)"; fi
check "the lint block is opened once, in the lib" "$(grep -c '^# >>> velo-brief-lint' "$LIB" 2>/dev/null)" 1
check "the lint block is closed once, in the lib" "$(grep -c '^# <<< velo-brief-lint' "$LIB" 2>/dev/null)" 1
check "velo-dispatch keeps no inline copy of the checks" \
  "$(grep -cE 'MISSING\+=\("(no |brief writes)' "$BIN/velo-dispatch")" 0
if grep -qE '^\. "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/velo-brief-lint\.sh"' "$BIN/velo-dispatch"; then
  pass "velo-dispatch sources the lib from its own directory"
else fail "velo-dispatch does not source velo-brief-lint.sh"; fi
if grep -qE '^velo_brief_lint "\$BRIEF" \|\| exit 1$' "$BIN/velo-dispatch"; then
  pass "velo-dispatch refuses a brief through velo_brief_lint"
else fail "velo-dispatch does not call velo_brief_lint \"\$BRIEF\" || exit 1"; fi
if grep -qE '^\. "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/velo-brief-lint\.sh"' "$BIN/velo-spec-review"; then
  pass "velo-spec-review sources the lib from its own directory"
else fail "velo-spec-review does not source velo-brief-lint.sh"; fi
LINT_LINE=$(grep -nE '^velo_brief_lint "\$BRIEF"' "$BIN/velo-spec-review" | head -1 | cut -d: -f1)
WRITE_LINE=$(grep -nE '^python3 - "\$SPEC" "\$BY"' "$BIN/velo-spec-review" | head -1 | cut -d: -f1)
if [[ -n "$LINT_LINE" && -n "$WRITE_LINE" && "$LINT_LINE" -lt "$WRITE_LINE" ]]; then
  pass "velo-spec-review runs the lint before it writes the attestation (line $LINT_LINE < $WRITE_LINE)"
else
  fail "velo-spec-review does not run the lint before the attestation write (lint='$LINT_LINE' write='$WRITE_LINE')"
fi

echo "the lint, driven as velo-dispatch drives it (the shipped function, sourced)"
NOAUTH="$TMPD/noauth.md"
printf '%s\n' 'WORKTREE: /w' 'Do NOT cd into it.' 'STOP and report if blocked.' \
  'Commit after each step.' 'cargo check --no-default-features' '## PRE-GATE SWEEP' > "$NOAUTH"
COMPLETE="$TMPD/complete.md"
printf '%s\n' 'WORKTREE: /w' 'Do NOT cd into it.' 'STOP and report if blocked.' \
  'Commit after each step.' 'You may commit. Do NOT push.' 'cargo check --no-default-features' '## PRE-GATE SWEEP' > "$COMPLETE"
if [[ -f "$LIB" ]]; then
  . "$LIB"
  OUT=$(velo_brief_lint "$NOAUTH" 2>&1); RC=$?
  check "a brief with no commit/push authorization is refused" "$RC" 1
  has "...under the BRIEF INCOMPLETE heading" "$OUT" "BRIEF INCOMPLETE:"
  has "...naming the missing rule, with the exact bullet" "$OUT" "$AUTH_BULLET"
  OUT=$(velo_brief_lint "$COMPLETE" 2>&1); RC=$?
  check "a complete brief passes" "$RC" 0
  check "...and prints nothing (the caller says ok)" "$OUT" ""
else
  fail "the lint refuses a brief with no authorization (lib missing; not driven)"
  fail "a complete brief passes (lib missing; not driven)"
fi

echo "velo-spec-review attest: the lint runs first, and a refusal writes nothing"
FH="$TMPD/fakehome"; ROOTF="$FH/RustroverProjects/velostream"
mkdir -p "$ROOTF/.agents/tasks" "$TMPD/stub" "$TMPD/state"
ISS=9100001
SPEC="$ROOTF/.agents/tasks/$ISS.json"
printf '{\n  "issue": %s,\n  "worker": "local"\n}\n' "$ISS" > "$SPEC"
SPEC_PRISTINE="$TMPD/spec.pristine"; cp "$SPEC" "$SPEC_PRISTINE"

# A stub gh: answers `gh issue view` from $GH_STATE_JSON (honouring --jq), and logs every call
# to $GH_LOG, so a test can prove the attest path never wrote to the issue.
cat > "$TMPD/stub/gh" <<'STUB'
#!/bin/bash
ARGS="$*"
echo "$ARGS" >> "$GH_LOG"
case "$ARGS" in
  "issue view "*)
    if [[ "$ARGS" == *" --jq "* ]]; then jq -r "${ARGS##* --jq }" <<<"$GH_STATE_JSON"
    else printf '%s\n' "$GH_STATE_JSON"; fi ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMPD/stub/gh"

attest() {  # <brief> <issue-state-json> -> OUT, RC; the spec is reset to its pristine copy first
  cp "$SPEC_PRISTINE" "$SPEC"
  GH_LOG="$TMPD/gh.log"; : > "$GH_LOG"
  OUT=$(HOME="$FH" VELO_STATE="$TMPD/state" PATH="$TMPD/stub:$PATH" GH_LOG="$GH_LOG" \
        GH_STATE_JSON="$2" "$BIN/velo-spec-review" "$ISS" "$1" --by tester 2>&1); RC=$?
}
spec_unchanged() { cmp -s "$SPEC" "$SPEC_PRISTINE" && echo same || echo changed; }

LABELED='{"updatedAt":"2026-10-11T06:00:00Z","labels":[{"name":"worker:local"}]}'
attest "$NOAUTH" "$LABELED"
check "attest refuses a brief the lint refuses" "$RC" 1
has "...and prints the lint's bullet" "$OUT" "$AUTH_BULLET"
check "...and writes no attestation (the spec is byte-identical)" "$(spec_unchanged)" same
check "...and writes nothing to the issue" "$(grep -c 'issue edit' "$TMPD/gh.log")" 0

attest "$COMPLETE" "$LABELED"
check "attest accepts a complete brief on a labelled issue" "$RC" 0
check "...pins the issue's own updatedAt" "$(jq -r .reviewed.at "$SPEC")" "2026-10-11T06:00:00Z"
check "...pins the brief's sha256" "$(jq -r .reviewed.brief_sha256 "$SPEC")" "$(shasum -a 256 "$COMPLETE" | cut -d' ' -f1)"
check "...records who attested" "$(jq -r .reviewed.by "$SPEC")" tester

echo "velo-spec-review attest: an issue without exactly one worker:* label is refused"
# The fixture spec names worker "local": that must NOT stand in for the label, because velo-dispatch
# routes by the label alone and only warns when the spec disagrees.
NOLABEL='{"updatedAt":"2026-10-11T06:00:00Z","labels":[{"name":"bug"}]}'
attest "$COMPLETE" "$NOLABEL"
check "attest refuses an issue with no worker:* label, though the spec names a worker" "$RC" 1
has "...naming the label dispatch needs" "$OUT" "no 'worker:*' label"
has "...telling the operator to add it FIRST, because an edit moves updatedAt" "$OUT" "Add the label FIRST"
has "...offering the choices dispatch offers" "$OUT" "worker:local"
check "...and writes no attestation (the spec is byte-identical)" "$(spec_unchanged)" same
check "...and never edits the issue" "$(grep -c 'issue edit' "$TMPD/gh.log")" 0

TWO='{"updatedAt":"2026-10-11T06:00:00Z","labels":[{"name":"worker:local"},{"name":"worker:glm"}]}'
attest "$COMPLETE" "$TWO"
check "attest refuses an issue with two worker:* labels" "$RC" 1
has "...naming both" "$OUT" "2 worker labels"
check "...and writes no attestation (the spec is byte-identical)" "$(spec_unchanged)" same

echo "the choices velo-spec-review offers are the ones velo-dispatch offers"
offered() { grep -E '^ *worker:[a-z]+ ' "$1" | sed -E 's/^ +//; s/ +/ /g'; }
check "the five worker choices match, line for line" \
  "$(offered "$BIN/velo-spec-review" | diff - <(offered "$BIN/velo-dispatch") >/dev/null && echo same || echo differ)" same
check "...and there are five of them" "$(offered "$BIN/velo-spec-review" | wc -l | tr -d ' ')" 5

echo "velo-dispatch --dry-run: the same lint, reached through the real script (no launch)"
# A scratch clone of a seed repo supplies origin/master, which dispatch fetches and pins. The
# worktree dispatch would cut is named by the brief and never created: a dry run builds nothing.
DH="$TMPD/dhome"; DROOT="$DH/RustroverProjects/velostream"
mkdir -p "$DH/RustroverProjects" "$TMPD/dstate"
git init -q -b master "$TMPD/seed"
git -C "$TMPD/seed" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m seed
if ! git clone -q "$TMPD/seed" "$DROOT"; then fail "the scratch clone of the seed repo failed"; fi
DISP_ISS=9100002
WTP="$DH/RustroverProjects/velostream-$DISP_ISS"
NOAUTH_D="$TMPD/dispatch-noauth.md"
printf '%s\n' "BRANCH: fix/$DISP_ISS-auto" "WORKTREE: $WTP" 'Do NOT cd into it.' \
  'STOP and report if blocked.' 'Commit after each step.' 'cargo check --no-default-features' > "$NOAUTH_D"
COMPLETE_D="$TMPD/dispatch-complete.md"
{ cat "$NOAUTH_D"; echo 'You may commit. Do NOT push.'; } > "$COMPLETE_D"
SKILL="$TMPD/check-code.md"; echo "# fixture skill" > "$SKILL"
DISP_STATE='{"state":"OPEN","title":"[#9100002] fixture","labels":[{"name":"worker:local"}],"assignees":[],"updatedAt":"2026-10-11T06:00:00Z"}'
dispatch() {  # <brief> -> OUT, RC
  GH_LOG="$TMPD/dgh.log"; : > "$GH_LOG"
  OUT=$(HOME="$DH" VELO_STATE="$TMPD/dstate" VELO_CHECK_CODE_SKILL="$SKILL" PATH="$TMPD/stub:$PATH" \
        GH_LOG="$GH_LOG" GH_STATE_JSON="$DISP_STATE" bash "$BIN/velo-dispatch" "$DISP_ISS" "$1" --dry-run 2>&1); RC=$?
}
dispatch "$NOAUTH_D"
check "velo-dispatch refuses the authorization-less brief" "$RC" 1
has "...with the same BRIEF INCOMPLETE bullet" "$OUT" "$AUTH_BULLET"
check "...and the dry run writes nothing to the issue" "$(grep -c 'issue edit' "$TMPD/dgh.log")" 0
dispatch "$COMPLETE_D"
has "velo-dispatch passes the complete brief through the lint" "$OUT" "brief satisfies the spec checklist"
if [[ "$OUT" == *"BRIEF INCOMPLETE"* ]]; then fail "a complete brief is refused by the lint"
else pass "a complete brief is not refused by the lint"; fi

echo "velo-dispatch names the model it launched: the dispatched block, and the first line of the log"
MBLOCK="$TMPD/model-block.sh"
sed -n '/^# >>> velo-dispatch-model-line/,/^# <<< velo-dispatch-model-line/p' "$BIN/velo-dispatch" > "$MBLOCK"
check "the model-line block is marked once, in velo-dispatch" \
  "$(grep -c '^# >>> velo-dispatch-model-line' "$BIN/velo-dispatch")" 1
model_line() {  # <NAME> <MODEL_ID, or - for unset> <LMSTUDIO_URL> -> MODEL_LINE on stdout
  bash -c 'NAME="$1"; MODEL_ID="$2"; LMSTUDIO_URL="$3"
    [[ "$2" == "-" ]] && unset MODEL_ID
    . "$4"; printf "%s" "$MODEL_LINE"' _ "$1" "$2" "$3" "$MBLOCK"
}
check "velo-local names its model and the endpoint it is served from" \
  "$(model_line velo-local qwen3.8-flash-next-ud http://127.0.0.1:1234/v1)" \
  "model  : qwen3.8-flash-next-ud   base-url: http://127.0.0.1:1234/v1"
check "a cloud route names its model and no endpoint" \
  "$(model_line velo-deepseek deepseek/deepseek-v4.1-flash http://127.0.0.1:1234/v1)" \
  "model  : deepseek/deepseek-v4.1-flash"
check "codex names the model it was configured with" \
  "$(model_line velo-codex 'gpt-5.5 (effort=high, from config)' http://unused)" \
  "model  : gpt-5.5 (effort=high, from config)"
check "a route with no model prints nothing (blank-safe)" "$(model_line velo-glm - http://unused)" ""

DISP_BLOCK=$(sed -n '/^echo "── dispatched/,/^echo "  branch :/p' "$BIN/velo-dispatch")
W=$(grep -n 'echo "  worker : ' <<<"$DISP_BLOCK" | head -1 | cut -d: -f1)
M=$(grep -n 'MODEL_LINE' <<<"$DISP_BLOCK" | head -1 | cut -d: -f1)
B=$(grep -n 'echo "  branch : ' <<<"$DISP_BLOCK" | head -1 | cut -d: -f1)
if [[ -n "$W" && -n "$M" && -n "$B" && "$W" -lt "$M" && "$M" -lt "$B" ]]; then
  pass "the dispatched block prints the model line between the worker and branch lines"
else fail "the dispatched block does not print the model line between worker and branch (w=$W m=$M b=$B)"; fi
check "the launch hands the model line to the supervisor, after the start head" \
  "$(grep -cF '"$START_HEAD" "$MODEL_LINE" "${CMD[@]}"' "$BIN/velo-dispatch")" 1

# The supervisor is the nohup script inside velo-dispatch. It is extracted and run for real, with
# the argument order the launch passes, so the log it writes is the one a launch leaves behind.
NOHUP="$TMPD/nohup-script.sh"
if ! python3 - "$BIN/velo-dispatch" "$NOHUP" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index("nohup bash -c '") + len("nohup bash -c '")
end = src.index("' _ \"$LOG\"", start)
pathlib.Path(sys.argv[2]).write_text(src[start:end])
PY
then fail "could not extract the supervisor script from velo-dispatch (renamed or restructured?)"; fi
mkdir -p "$TMPD/rhome/.agents/bin"
printf '#!/bin/bash\nexit 0\n' > "$TMPD/rhome/.agents/bin/velo-record"; chmod +x "$TMPD/rhome/.agents/bin/velo-record"
run_supervisor() {  # <model line> -> runs the supervisor on a log that already holds stale text
  LOGF="$TMPD/worker.log"; printf 'stale line from an earlier run\n' > "$LOGF"
  HOME="$TMPD/rhome" bash -c "$(cat "$NOHUP")" _ "$LOGF" 9100003 "$TMPD" velo-local qwen \
    "$TMPD/brief.md" 2026-10-11T06:00:00Z 250 main unknown abc123 "$1" printf 'runner output\n' >/dev/null 2>&1
}
run_supervisor "model  : qwen3.8-flash-next-ud   base-url: http://127.0.0.1:1234/v1"
check "the worker log's first line is the model line" "$(head -n 1 "$TMPD/worker.log")" \
  "model  : qwen3.8-flash-next-ud   base-url: http://127.0.0.1:1234/v1"
check "the runner's own output follows it" "$(sed -n 2p "$TMPD/worker.log")" "runner output"
check "the stale text from an earlier run is gone" "$(grep -c 'stale line' "$TMPD/worker.log")" 0
run_supervisor ""
check "with no model line the log opens on the runner's output" "$(head -n 1 "$TMPD/worker.log")" "runner output"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all spec-review lint checks passed"

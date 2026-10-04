#!/bin/bash
# velo-pr-gate's check-code route: sonnet by default, opus on request.
#
# The opus leg — and the velo-local shim that later stood in for it — never
# produced a report: it timed out. So every round ended the same way, with the
# orchestrator running a read-only Sonnet agent by hand and writing the
# substitution note by hand. The default route now PREPARES that agent's prompt
# instead of launching a leg that cannot finish, and records the route so the
# substitution is declared rather than remembered. `--check-code-by opus` keeps
# the original dispatched leg.
#
# Drives the REAL velo-pr-gate end to end against a git repo this file builds
# (its own origin/master plus a commit ahead of it), so — unlike
# test_gate_health.sh — it cannot SKIP for want of a feature branch. gh, codex and
# claude are stubs; the state root is private to the run.
#
# Every behaviour is pinned twice: green on the real script, and RED on a copy
# with that one behaviour mutated out (the MUTATION-PROOF cases at the end). The
# mutants are COPIES in a temp dir — the repo's script is never edited, so an
# interrupted run cannot leave it mutated.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
GATE="$BIN/velo-pr-gate"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -f "$GATE" ]] || { fail "velo-pr-gate not found at $GATE"; exit 1; }

# Unique per process, far above any real PR number (velo-pr-gate wants digits).
TPR=$(( 900000 + ($$ % 90000) ))
# Stub reviewers carry this in argv[0] (via `exec -a`) so cleanup can find them
# without matching another run's stubs.
MARKER="velo-test-ccmode-sleep-$$"
TMPD=$(mktemp -d)
export VELO_STATE="$TMPD/state"
# A test must never start the real local-model worker.
export VELO_SECOND_OPINION=0
unset VELO_CHECK_CODE
GATE_DIR="$VELO_STATE/gate/$TPR"
BRIEF="$GATE_DIR/review-brief.md"
cleanup() { pkill -f "$MARKER" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

# ── a repo with an origin/master and a commit ahead of it ────────────────────
REPO="$TMPD/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m base
git -C "$REPO" update-ref refs/remotes/origin/master HEAD
git -C "$REPO" checkout -q -b tooling/gatemode
echo change >> "$REPO/f.txt"
git -C "$REPO" commit -q -am change
# velo-pr-gate learns the worktree path from `git worktree list`, which reports the
# PHYSICAL path: on macOS $TMPDIR sits behind the /var -> /private/var symlink.
REPO_REAL=$(git -C "$REPO" rev-parse --show-toplevel)

# ── stubs ────────────────────────────────────────────────────────────────────
mkdir -p "$TMPD/bin" "$TMPD/nocodex" "$TMPD/home/.agents/bin"
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *headRefName*) echo "tooling/gatemode";;
  *baseRefName*) echo "master";;
  *)             echo "";;
esac
EOF
cp "$TMPD/bin/gh" "$TMPD/nocodex/gh"
cat > "$TMPD/home/.agents/bin/velo-gate" <<EOF
#!/bin/bash
case "\$*" in
  *--plan*)    cat "$TMPD/plan.txt"; exit 0;;
  *--running*) echo set > "$TMPD/running.flag"; exit 0;;
esac
exit 0
EOF
cat > "$TMPD/bin/claude" <<EOF
#!/bin/bash
echo invoked >> "$TMPD/claude.called"
cat >/dev/null
exec -a $MARKER sleep 400
EOF
cat > "$TMPD/bin/codex" <<EOF
#!/bin/bash
cat >/dev/null
exec -a $MARKER sleep 400
EOF
# The OpenRouter runner velo-pr-gate launches for --check-code-by deepseek|glm
# (it resolves it under $HOME, which run_gate points here). Records its argv.
cat > "$TMPD/home/.agents/bin/velo-openrouter-agent" <<EOF
#!/bin/bash
# Written aside then renamed: the reader never sees a half-written argv. The
# brief makes this several KB, and under load (other agents' runs on the host)
# the test read it mid-write.
printf '%s\n' "\$@" > "$TMPD/oragent.args.part" && mv "$TMPD/oragent.args.part" "$TMPD/oragent.args"
exec -a $MARKER sleep 400
EOF
chmod +x "$TMPD/bin/gh" "$TMPD/nocodex/gh" "$TMPD/home/.agents/bin/velo-gate" "$TMPD/bin/claude" "$TMPD/bin/codex" \
  "$TMPD/home/.agents/bin/velo-openrouter-agent"

# velo-gate --plan is what tells velo-pr-gate which gates to run; it only greps it.
plan_with_code()    { printf '#1 t\n  gates needed:\n    - code-review  (independent reviewer)\n    - check-code   (src/ touched: 1 files)\n' > "$TMPD/plan.txt"; }
plan_without_code() { printf '#1 t\n  gates needed:\n    - code-review  (independent reviewer)\n' > "$TMPD/plan.txt"; }

SCOPE="$TMPD/scope.md"
printf '# Scope\n\nReal scope text for the check-code route test.\n' > "$SCOPE"

# A PATH with reviewers (the stubs, ahead of the real ones) and one with NEITHER
# reviewer CLI. With no codex nothing is dispatched, so the run reaches the end
# immediately instead of waiting out the 10s liveness check — every artefact this
# file asserts on is written before that point.
HEALTHY_PATH="$TMPD/bin:$PATH"
FAST_PATH="$TMPD/nocodex:/usr/bin:/bin"

# GATE_UNDER_TEST lets the mutation cases point the same scenarios at a mutant.
GATE_UNDER_TEST="$GATE"
run_gate() {   # <PATH value> [args after <pr> <scope>...]  ->  $TMPD/out.txt, $RC
  local p="$1"; shift
  rm -f "$TMPD/running.flag"
  (cd "$REPO" && HOME="$TMPD/home" PATH="$p" bash "$GATE_UNDER_TEST" "$TPR" "$SCOPE" "$@" > "$TMPD/out.txt" 2>&1)
  RC=$?
  pkill -f "$MARKER" 2>/dev/null
  return 0
}

fill_attack() {
  python3 - "$BRIEF" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(re.sub(r'(<<< [^\n]*>>>\n?)+',
                    lambda m: "ATTACK-PROBE-TEXT: does the sonnet prompt carry this?\n", t))
PY
}

# The first run regenerates the brief template and refuses it (an unfilled
# ## ATTACK); fill it so the run under test actually dispatches. A fresh gate dir
# each time, so no scenario inherits another's artefacts.
prime_and_fill() {
  rm -rf "$GATE_DIR"
  GATE_UNDER_TEST_SAVE="$GATE_UNDER_TEST"
  run_gate "$FAST_PATH"
  [[ -f "$BRIEF" ]] && grep -q "FILL THIS IN" "$BRIEF" && fill_attack
}

# Scenario results are collected, not printed, so the same scenario can run
# against the real script (expect none failed) and against a mutant (expect some).
SC_FAILS=""
sc_check() {   # <name> <exit status of the check>
  [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"
}
has() { grep -qF -- "$2" "$1" 2>/dev/null; }   # <file> <fixed string>

# ── scenario: the default route prepares a prompt and launches nothing ───────
sc_default_sonnet() {
  SC_FAILS=""
  plan_with_code; prime_and_fill; rm -f "$TMPD/claude.called"
  run_gate "$FAST_PATH"
  local P="$GATE_DIR/check-code-agent-prompt.md"
  has "$TMPD/out.txt" "NOTHING was dispatched"; sc_check reached-the-dispatch-section $?
  [[ -s "$P" ]];                                sc_check prompt-written $?
  [[ "$(cat "$GATE_DIR/check-code.by" 2>/dev/null)" == "sonnet" ]]; sc_check route-recorded $?
  [[ "$(grep -c 'LAUNCH a read-only Sonnet agent' "$TMPD/out.txt")" == "1" ]]; sc_check one-launch-line $?
  has "$TMPD/out.txt" "$P";                     sc_check launch-line-names-the-prompt $?
  [[ ! -f "$TMPD/claude.called" ]];             sc_check claude-not-launched $?
  [[ ! -e "$GATE_DIR/code.log" ]];              sc_check no-code-log $?
  [[ -s "$GATE_DIR/code-brief.md" ]];           sc_check code-brief-still-written $?
}

# ── scenario: the prompt is complete and self-contained ──────────────────────
sc_prompt_content() {
  SC_FAILS=""
  plan_with_code; prime_and_fill
  run_gate "$FAST_PATH"
  local P="$GATE_DIR/check-code-agent-prompt.md"
  has "$P" "READ-ONLY";                          sc_check read-only $?
  has "$P" "at most 40 tool calls";              sc_check tool-cap-40 $?
  has "$P" "You are running the CHECK-CODE gate, not the code review."; sc_check shared-instructions $?
  has "$P" "ATTACK-PROBE-TEXT";                  sc_check carries-the-filled-attack $?
  has "$P" "WORKTREE: $REPO_REAL";               sc_check carries-the-worktree $?
  has "$P" "git -C $REPO_REAL diff origin/master..."; sc_check carries-the-diff-range $?
  has "$P" "Real scope text for the check-code route test."; sc_check carries-the-scope $?
  has "$P" "## check-code — PR $TPR @";          sc_check output-heading $?
  has "$P" '**Verdict:** <verdict>';             sc_check output-verdict-line $?
  # Codex's framing must not leak into a Sonnet agent's prompt: its OUTPUT
  # template is the literal alternation velo-gate-post refuses as a template.
  ! has "$P" "approve | approve-with-findings | blocked"; sc_check no-verdict-alternation $?
  ! has "$P" "FILL THIS IN";                     sc_check no-placeholder $?
  ! has "$P" "## Codex review";                  sc_check no-codex-output-template $?
  ! has "$P" "velo-gate-brief";                  sc_check no-brief-trailer $?
}

# ── scenario: --check-code-by beats VELO_CHECK_CODE ──────────────────────────
sc_flag_beats_env() {
  SC_FAILS=""
  plan_with_code; prime_and_fill
  VELO_CHECK_CODE=opus run_gate "$FAST_PATH" --check-code-by sonnet
  [[ -s "$GATE_DIR/check-code-agent-prompt.md" ]]; sc_check flag-sonnet-over-env-opus $?
  [[ "$(cat "$GATE_DIR/check-code.by" 2>/dev/null)" == "sonnet" ]]; sc_check route-recorded $?
}

# ── scenario: a stale opus report is gone before the daemon can read it ──────
# velo-orchestrd treats "code.log present + pid dead" as a FINISHED gate and posts
# it under THIS run's gated.sha: a stale report stamped with a commit it never saw.
sc_stale_removed() {
  SC_FAILS=""
  plan_with_code; prime_and_fill
  printf 'an old opus report\n**Verdict:** approve\n' > "$GATE_DIR/code.log"
  printf '999999999\n' > "$GATE_DIR/code.log.pid"
  run_gate "$FAST_PATH"
  [[ ! -e "$GATE_DIR/code.log" ]];     sc_check stale-code-log-removed $?
  [[ ! -e "$GATE_DIR/code.log.pid" ]]; sc_check stale-pid-removed $?
}

# ── scenario: no check-code gate planned -> no prompt, no route, nothing stale ─
sc_no_check_code_needed() {
  SC_FAILS=""
  plan_without_code; prime_and_fill
  # Leftovers from an earlier run that DID have check-code.
  printf 'sonnet\n' > "$GATE_DIR/check-code.by"
  printf 'old prompt\n' > "$GATE_DIR/check-code-agent-prompt.md"
  run_gate "$FAST_PATH"
  has "$TMPD/out.txt" "NOTHING was dispatched"; sc_check reached-the-dispatch-section $?
  [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" ]]; sc_check no-prompt $?
  [[ ! -e "$GATE_DIR/check-code.by" ]];              sc_check no-stale-route $?
}

# ── scenario: the refusal run (unfilled ATTACK) writes neither ───────────────
sc_refused_run_writes_nothing() {
  SC_FAILS=""
  plan_with_code; rm -rf "$GATE_DIR"
  printf 'sonnet\n' > /dev/null
  mkdir -p "$GATE_DIR"
  printf 'sonnet\n' > "$GATE_DIR/check-code.by"
  printf 'old prompt\n' > "$GATE_DIR/check-code-agent-prompt.md"
  run_gate "$FAST_PATH"
  has "$TMPD/out.txt" "unfilled ## ATTACK";          sc_check refused-on-unfilled-attack $?
  [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" ]]; sc_check no-stale-prompt-after-a-refusal $?
  [[ ! -e "$GATE_DIR/check-code.by" ]];              sc_check no-stale-route-after-a-refusal $?
}

# ── scenario: --check-code-by deepseek|glm runs the prompt on OpenRouter (#2350) ──
# The route is dispatched by velo-pr-gate itself, read-only, with the sonnet
# route's prompt and output shape, and recorded so it is declared ADVISORY.
# Runs on FAST_PATH (no codex), so the leg under test is the only dispatch.
sc_openrouter_route() {   # <route> <model id>
  SC_FAILS=""
  local by="$1" model="$2" A="$TMPD/oragent.args"
  plan_with_code; prime_and_fill; rm -f "$TMPD/claude.called" "$A"
  printf 'old prompt\n' > "$GATE_DIR/check-code-agent-prompt.md"
  run_gate "$FAST_PATH" --check-code-by "$by"
  # The runner is detached: velo-pr-gate returning does not mean it has started.
  local i; for i in $(seq 50); do [[ -s "$A" ]] && break; sleep 0.1; done
  [[ -s "$A" ]];                                         sc_check runner-launched $?
  [[ "$(cat "$GATE_DIR/check-code.by" 2>/dev/null)" == "$by" ]]; sc_check route-recorded $?
  [[ "$(grep -A1 -x -- '--model' "$A" 2>/dev/null | tail -1)" == "$model" ]]; sc_check pinned-model $?
  ! grep -qx -- '--base-url' "$A" 2>/dev/null;           sc_check openrouter-not-local $?
  has "$A" "=== THIS IS A READ-ONLY REVIEW TASK ===";    sc_check read-only-marker $?
  has "$A" "You are running the CHECK-CODE gate, not the code review."; sc_check shared-instructions $?
  has "$A" "ATTACK-PROBE-TEXT";                          sc_check carries-the-filled-attack $?
  has "$A" '**Verdict:** <verdict>';                     sc_check same-output-shape $?
  has "$A" "READ-ONLY $by ($model) agent";               sc_check names-the-reviewer $?
  [[ -f "$GATE_DIR/code.log" && -f "$GATE_DIR/code.log.pid" ]]; sc_check code-log-and-pid $?
  [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" ]];     sc_check no-sonnet-prompt $?
  [[ ! -f "$TMPD/claude.called" ]];                      sc_check claude-not-launched $?
  has "$TMPD/out.txt" "check-code -> $by ($model, ADVISORY)"; sc_check says-advisory $?
  [[ -f "$TMPD/running.flag" ]];                         sc_check gate-running-set $?
}

echo "check-code route (end to end, real velo-pr-gate)"

# ── 1. the default is sonnet ─────────────────────────────────────────────────
sc_default_sonnet
[[ -z "$SC_FAILS" ]] && ok "default route: prompt written, route recorded, ONE launch line, nothing launched" \
                     || fail "default route is not sonnet:$SC_FAILS"
sc_prompt_content
[[ -z "$SC_FAILS" ]] && ok "the prompt is complete: read-only, tool cap 40, the filled brief, one output shape, no Codex framing" \
                     || fail "prompt incomplete:$SC_FAILS"
sc_flag_beats_env
[[ -z "$SC_FAILS" ]] && ok "--check-code-by sonnet beats VELO_CHECK_CODE=opus" \
                     || fail "flag does not beat the environment:$SC_FAILS"
sc_stale_removed
[[ -z "$SC_FAILS" ]] && ok "a stale code.log and its pid file are removed in sonnet mode" \
                     || fail "stale opus report survives for the daemon to post:$SC_FAILS"
sc_no_check_code_needed
[[ -z "$SC_FAILS" ]] && ok "no check-code gate planned: no prompt, no route, leftovers cleared" \
                     || fail "check-code artefacts without a check-code gate:$SC_FAILS"
sc_refused_run_writes_nothing
[[ -z "$SC_FAILS" ]] && ok "the refused (unfilled ATTACK) run clears stale artefacts and writes none" \
                     || fail "refused run left check-code state behind:$SC_FAILS"

# ── 1b. the OpenRouter routes (each costs the 10s liveness window) ──────────
sc_openrouter_route deepseek deepseek/deepseek-v4.1-flash
[[ -z "$SC_FAILS" ]] && ok "--check-code-by deepseek: read-only OpenRouter leg, pinned model, same prompt, route recorded" \
                     || fail "deepseek route:$SC_FAILS"
sc_openrouter_route glm z-ai/glm-5.3-flash
[[ -z "$SC_FAILS" ]] && ok "--check-code-by glm: read-only OpenRouter leg, pinned model, same prompt, route recorded" \
                     || fail "glm route:$SC_FAILS"
# The pins must be velo-dispatch's: a report from a model the worker records do
# not describe is a reviewer nobody has measured.
for r in deepseek glm; do
  want=$(awk -v arm="  velo-$r)" '$0 == arm {f=1} f && /MODEL_ID=/ {gsub(/.*MODEL_ID=.|.$/, ""); print; exit}' "$BIN/velo-dispatch")
  got=$(awk -v arm="  $r)" 'index($0, arm) == 1 && /CODE_MODEL_ID=/ {gsub(/.*CODE_MODEL_ID=.|. ;;$/, ""); print; exit}' "$GATE")
  if [[ -n "$want" && "$want" == "$got" ]]; then
    ok "$r: velo-pr-gate pins the same model as velo-dispatch ($want)"
  else
    fail "$r: velo-pr-gate pins '$got', velo-dispatch '$want'"
  fi
done

# ── 2. a healthy default run: codex dispatched, claude not, gate:running set ──
# This is the one that proves the whole point: no opus leg, and still a gate that
# is running. Costs the 10s liveness window, so it runs once per route.
plan_with_code; prime_and_fill; rm -f "$TMPD/claude.called"
run_gate "$HEALTHY_PATH"
if [[ -f "$TMPD/running.flag" ]]; then
  ok "healthy sonnet run: codex dispatched and gate:running set with no opus leg"
else
  fail "healthy sonnet run did not set gate:running:"; sed 's/^/        /' "$TMPD/out.txt" | tail -8
fi
if [[ ! -f "$TMPD/claude.called" ]]; then
  ok "the claude CLI was never launched on the default route"
else
  fail "the default route launched the opus leg"
fi
if grep -q "code-review -> codex" "$TMPD/out.txt"; then
  ok "the Codex leg is unchanged by the route"
else
  fail "the Codex leg was not dispatched"
fi

# ── 3. --check-code-by opus restores the original dispatched leg ─────────────
plan_with_code; prime_and_fill
printf 'sonnet\n' > "$GATE_DIR/check-code.by"          # leftover from a sonnet run
printf 'old prompt\n' > "$GATE_DIR/check-code-agent-prompt.md"
rm -f "$TMPD/claude.called"
run_gate "$HEALTHY_PATH" --check-code-by opus
if [[ -f "$TMPD/claude.called" ]]; then
  ok "--check-code-by opus launches the claude CLI leg"
else
  fail "--check-code-by opus did not launch the claude leg"; sed 's/^/        /' "$TMPD/out.txt" | tail -8
fi
if [[ -f "$GATE_DIR/code.log" && -f "$GATE_DIR/code.log.pid" ]]; then
  ok "opus route writes code.log and its pid file, as before"
else
  fail "opus route did not produce code.log / code.log.pid"
fi
if [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" && ! -e "$GATE_DIR/check-code.by" ]]; then
  ok "opus route clears a leftover sonnet prompt and route: no substitution is declared for an opus report"
else
  fail "opus route left sonnet state behind — velo-gate-post would declare a substitution that did not happen"
fi
if head -1 "$GATE_DIR/code-brief.md" | grep -q "^You are running the CHECK-CODE gate, not the code review.$"; then
  ok "code-brief.md is unchanged for the opus leg"
else
  fail "code-brief.md no longer opens with the check-code instructions"
fi
if [[ -f "$TMPD/running.flag" ]]; then
  ok "opus route still sets gate:running"
else
  fail "opus route did not set gate:running"
fi

# ── 4. VELO_CHECK_CODE=opus is the same route as the flag ────────────────────
plan_with_code; prime_and_fill; rm -f "$TMPD/claude.called"
VELO_CHECK_CODE=opus run_gate "$HEALTHY_PATH"
if [[ -f "$TMPD/claude.called" ]]; then
  ok "VELO_CHECK_CODE=opus launches the claude CLI leg"
else
  fail "VELO_CHECK_CODE=opus did not select the opus route"
fi

# ── 5. --plan states the route and writes nothing ────────────────────────────
plan_with_code; rm -rf "$GATE_DIR"
plan_out() { (cd "$REPO" && HOME="$TMPD/home" PATH="$FAST_PATH" "$@" 2>&1); }
D=$(plan_out bash "$GATE" "$TPR" --plan)
O=$(plan_out bash "$GATE" "$TPR" --plan --check-code-by opus)
E=$(plan_out env VELO_CHECK_CODE=opus bash "$GATE" "$TPR" --plan)
F=$(plan_out env VELO_CHECK_CODE=opus bash "$GATE" "$TPR" --plan --check-code-by sonnet)
if grep -q 'check-code   -> sonnet' <<<"$D" && ! grep -q 'opus:high via claude CLI' <<<"$D"; then
  ok "--plan advertises sonnet by default"
else
  fail "--plan does not state the default route: $(grep 'check-code' <<<"$D")"
fi
if grep -q 'check-code   -> opus:high via claude CLI' <<<"$O" && ! grep -q 'check-code   -> sonnet' <<<"$O"; then
  ok "--plan --check-code-by opus advertises the opus leg"
else
  fail "--plan ignores --check-code-by: $(grep 'check-code' <<<"$O")"
fi
if grep -q 'check-code   -> opus:high via claude CLI' <<<"$E"; then
  ok "--plan honours VELO_CHECK_CODE=opus"
else
  fail "--plan ignores VELO_CHECK_CODE: $(grep 'check-code' <<<"$E")"
fi
if grep -q 'check-code   -> sonnet' <<<"$F"; then
  ok "--plan: the flag beats the environment"
else
  fail "--plan: the environment beat the flag: $(grep 'check-code' <<<"$F")"
fi
if [[ ! -e "$GATE_DIR" ]]; then
  ok "--plan writes nothing"
else
  fail "--plan created $GATE_DIR"
fi

# ── 6. a bad route is refused before anything happens ────────────────────────
rm -rf "$GATE_DIR"
run_gate "$FAST_PATH" --check-code-by haiku
if [[ $RC -ne 0 ]] && grep -q "must be 'sonnet', 'opus', 'deepseek' or 'glm', got 'haiku'" "$TMPD/out.txt"; then
  ok "an unknown route is refused and the allowed values are named"
else
  fail "unknown route accepted or unexplained (rc=$RC): $(tail -2 "$TMPD/out.txt")"
fi
run_gate "$FAST_PATH" --check-code-by
if [[ $RC -ne 0 ]] && grep -q "needs a value" "$TMPD/out.txt"; then
  ok "--check-code-by with no value is refused"
else
  fail "a dangling --check-code-by was accepted (rc=$RC)"
fi
VELO_CHECK_CODE=haiku run_gate "$FAST_PATH"
if [[ $RC -ne 0 ]] && grep -q "got 'haiku'" "$TMPD/out.txt"; then
  ok "an unknown VELO_CHECK_CODE is refused"
else
  fail "VELO_CHECK_CODE=haiku was accepted (rc=$RC)"
fi
# `=` form.
run_gate "$FAST_PATH" --check-code-by=haiku
if [[ $RC -ne 0 ]] && grep -q "got 'haiku'" "$TMPD/out.txt"; then
  ok "--check-code-by=VALUE is parsed too"
else
  fail "--check-code-by=haiku was accepted (rc=$RC)"
fi
if [[ ! -e "$GATE_DIR" ]]; then
  ok "a refused route leaves no gate state behind"
else
  fail "a refused route still created $GATE_DIR"
fi

# ── MUTATION-PROOF: each behaviour above goes red when it is removed ──────────
# The mutants are copies; velo-pr-gate sources velo-local.conf from its own dir.
MUT="$TMPD/mut"; mkdir -p "$MUT"
cp "$BIN/velo-local.conf" "$MUT/velo-local.conf"
mutate() {   # <name> <old> <new> -> $MUT/velo-pr-gate (a mutant), exactly one anchor
  python3 - "$GATE" "$MUT/velo-pr-gate" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
}
prove() {   # <label> <scenario fn> <anchor> <replacement>
  local label="$1" fn="$2" old="$3" new="$4"
  if ! mutate "$label" "$old" "$new"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  GATE_UNDER_TEST="$MUT/velo-pr-gate"
  "$fn"
  local red="$SC_FAILS"
  GATE_UNDER_TEST="$GATE"
  "$fn"
  if [[ -n "$red" && -z "$SC_FAILS" ]]; then
    ok "MUTATION-PROOF $label: red with the behaviour removed ($red ), green restored"
  elif [[ -z "$red" ]]; then
    fail "MUTATION-PROOF $label: stayed GREEN with the behaviour removed — the scenario does not pin it"
  else
    fail "MUTATION-PROOF $label: the real script is red too:$SC_FAILS"
  fi
}

prove "default route sonnet" sc_default_sonnet \
  'CHECK_CODE_BY="${VELO_CHECK_CODE:-sonnet}"' 'CHECK_CODE_BY="${VELO_CHECK_CODE:-opus}"'
prove "the flag is parsed" sc_flag_beats_env \
  'CHECK_CODE_BY="${ARGS[$i]}" ;;' ': ;;'
prove "route recorded in check-code.by" sc_default_sonnet \
  "printf '%s\\n' sonnet > \"\$CODE_BY_FILE\"" 'true'
prove "stale opus report removal" sc_stale_removed \
  'rm -f "$CODE_LOG" "$CODE_LOG.pid"
    write_code_brief' ': mutated out
    write_code_brief'
prove "per-run reset of route and prompt" sc_no_check_code_needed \
  'rm -f "$CODE_BY_FILE" "$CODE_AGENT_PROMPT"' ': mutated out'
prove "Codex framing stripped from the prompt" sc_prompt_content \
  'index($0, "OUTPUT — plain text") == 1{p=0}' '0{p=0}'
sc_deepseek() { sc_openrouter_route deepseek deepseek/deepseek-v4.1-flash; }
prove "OpenRouter route recorded in check-code.by" sc_deepseek \
  "printf '%s\\n' \"\$CHECK_CODE_BY\" > \"\$CODE_BY_FILE\"" 'true'
prove "OpenRouter route dispatched" sc_deepseek \
  'elif [[ $NEEDS_CODE -eq 1 && -n "$CODE_MODEL_ID" ]]; then' 'elif false; then'
prove "OpenRouter route is read-only" sc_deepseek \
  "--task \"\$(printf '%s\\n\\n' '=== THIS IS A READ-ONLY REVIEW TASK ==='; cat \"\$CODE_BRIEF\")\"" '--task "$(cat "$CODE_BRIEF")"'

echo
[[ $FAILED -eq 0 ]] && echo "all check-code route checks passed" || echo "FAILURES"
exit $FAILED

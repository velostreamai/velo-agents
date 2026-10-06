#!/bin/bash
# velo-gate-run: one gate round, end to end, with Codex's verdict left on disk.
#
# The orchestrator ran this sequence by hand on every round: prime the brief, fill
# its ATTACK section from the scope, launch the gates, wait for Codex, cut its
# final message out of a transcript. Each step went wrong in some round — a brief
# that was never filled, a verdict cut from the FIRST `codex` marker instead of the
# last, a gh hiccup read as a missing PR, a stale log read as this run's.
#
# Three layers, so a failure points at the right one:
#   1. the wrapper against a STUB velo-pr-gate (fast, every branch reachable);
#   2. the real velo-pr-gate's new --brief-only / plan / base-branch behaviour,
#      in a git repo this file builds (so it cannot SKIP for want of a branch);
#   3. one end-to-end run of the real wrapper over the real velo-pr-gate.
#
# Every behaviour is pinned twice: green on the real script, and RED on a copy
# with that one behaviour mutated out (the MUTATION-PROOF cases at the end). The
# mutants are copies in a temp dir — the repo's scripts are never edited, so an
# interrupted run cannot leave one mutated.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
RUN_REAL="$BIN/velo-gate-run"
PRGATE_REAL="$BIN/velo-pr-gate"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -x "$RUN_REAL" ]] || { fail "velo-gate-run not found or not executable at $RUN_REAL"; exit 1; }
[[ -f "$PRGATE_REAL" ]] || { fail "velo-pr-gate not found at $PRGATE_REAL"; exit 1; }

TPR=$(( 900000 + ($$ % 90000) ))
TMPD=$(mktemp -d)
export VELO_STATE="$TMPD/state"
# A test must never start the real local-model worker.
export VELO_SECOND_OPINION=0
unset VELO_CHECK_CODE
GATE_DIR="$VELO_STATE/gate/$TPR"
STUB_DIR="$TMPD/stub"; export STUB_DIR
STUB="$TMPD/stub-bin/velo-pr-gate"
# A readiness wait that timed out writes its reason here (the stub gate does too, as
# $STUB_DIR/../harness-failed): the harness failed, not the thing under test. Outside
# STUB_DIR on purpose — every reset wipes that.
HARNESS_FAILED="$TMPD/harness-failed"
# Every fake lives under $TMPD, so its command line names it — but the fakes'
# own `sleep` children do not, and survive a bare pkill -f (3 x sleep 600 leaked
# per run). Kill each match's children first, then the match.
cleanup() {
  local p
  for p in $(pgrep -f "$TMPD/"); do pkill -P "$p"; kill "$p"; done 2>/dev/null
  for p in $(cat "$TMPD/second.children" 2>/dev/null); do
    [[ $(ps -o command= -p "$p" 2>/dev/null) == sleep* ]] && kill "$p" 2>/dev/null
  done
  rm -rf "$TMPD"
}
trap cleanup EXIT

SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has()    { grep -qF -- "$2" "$1" 2>/dev/null; }                # <file> <fixed string>
# A missing file is a failed check, not stderr noise (the mutated passes hit it on purpose).
diff()   { command diff "$@" 2>/dev/null; }
ncalls() { local n; n=$(grep -cF -- "$1" "$STUB_DIR/calls.log" 2>/dev/null); echo "${n:-0}"; }   # <fixed string> -> matching call lines

# The one verdict every mutation proof reaches. A proof is: RED with the behaviour removed,
# GREEN with it restored. A harness failure in either run (a fake second opinion that never
# came up; its reason is $3) makes the red meaningless — it would read as the mutant being
# caught when the mutant was never exercised — so it is neither red nor green but
# inconclusive, and is reported as a failure of the proof, with the reason.
proof_verdict() {   # <SC_FAILS of the mutant run> <SC_FAILS of the restored run> <harness failure, or empty>
  if [[ -n "$3" ]]; then echo inconclusive
  elif [[ -z "$1" ]]; then echo stayed-green
  elif [[ -z "$2" ]]; then echo proved
  else echo real-red
  fi
}
report_proof() {   # <label> <scenario> <SC_FAILS of the mutant run> <SC_FAILS of the restored run> <harness failure, or empty>
  case "$(proof_verdict "$3" "$4" "$5")" in
    proved)       ok "MUTATION-PROOF $1: red with the behaviour removed ($3 ), green restored" ;;
    stayed-green) fail "MUTATION-PROOF $1: stayed GREEN with the behaviour removed — $2 does not pin it" ;;
    inconclusive) fail "MUTATION-PROOF $1: INCONCLUSIVE — the harness failed ($5), so the red ($3 ) says nothing about the mutant" ;;
    real-red)     fail "MUTATION-PROOF $1: the real script is red too:$4" ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# Layer 1 — the wrapper against a stub velo-pr-gate
# ═════════════════════════════════════════════════════════════════════════════
mkdir -p "$TMPD/stub-bin"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# Stub velo-pr-gate. Records every call; its behaviour comes from files in $STUB_DIR.
printf '%s\n' "$*" >> "$STUB_DIR/calls.log"
PRN="$1"; shift
GD="$VELO_STATE/gate/$PRN"; mkdir -p "$GD"
mode=run; scope=""
for a in "$@"; do
  case "$a" in
    --plan)       mode=plan ;;
    --brief-only) mode=brief ;;
    --exec|--wait|--check-code-by|--check-code-by=*|sonnet|opus) ;;
    *)            [[ -z "$scope" ]] && scope="$a" ;;
  esac
done

# Failure injection: fail.<mode> holds "<remaining> <message>".
inj="$STUB_DIR/fail.$mode"
if [[ -s "$inj" ]]; then
  read -r n msg < "$inj"
  if [[ "$n" -gt 0 ]]; then
    printf '%s %s\n' "$((n - 1))" "$msg" > "$inj"
    printf '\033[31mERROR:\033[0m %s\n' "$msg" >&2
    exit 1
  fi
fi

case "$mode" in
  plan)
    cat "$STUB_DIR/plan.txt"
    exit 0 ;;
  brief)
    if [[ -f "$STUB_DIR/empty-range" ]]; then
      echo "warn: diff range origin/master...HEAD is EMPTY — nothing has landed since the last review." >&2
      exit 0
    fi
    BR="$GD/review-brief.md"
    if [[ -f "$BR" ]] && ! grep -q "<<< FILL THIS IN" "$BR"; then
      echo "  ok reusing filled brief: $BR"
      exit 0
    fi
    cat > "$BR" <<BRIEF
READ-ONLY review.

WORKTREE: /stub (head abc1234)

--- WHAT IT DOES -------------------------------------------------------------
$(cat "$scope")
--- END SCOPE ----------------------------------------------------------------

## ATTACK

<<< FILL THIS IN — the specific things worth this reviewer's effort. >>>
<<< A generic checklist produces a generic review. Name the shapes that would  >>>
<<< reasoning rather than evidence.                                            >>>

## Also confirm

- nothing

<!-- velo-gate-brief scope=stub range=stub -->
BRIEF
    echo "  ok --brief-only: brief ready at $BR"
    exit 0 ;;
  run)
    BR="$GD/review-brief.md"
    if grep -q "<<< FILL THIS IN" "$BR" 2>/dev/null; then
      echo "warn: brief still has an unfilled ## ATTACK section" >&2
      exit 1
    fi
    printf '%s\n' abc1234 > "$GD/gated.sha"
    # What a previous round's second opinion looked like at THIS moment (#2350).
    if [[ -f "$STUB_DIR/old.pid" ]]; then
      kill -0 "$(cat "$STUB_DIR/old.pid")" 2>/dev/null && echo alive > "$STUB_DIR/old.state" || echo dead > "$STUB_DIR/old.state"
    fi
    # The detached second opinion: a fake runner that sleeps <second.secs>.
    if [[ -f "$STUB_DIR/second.secs" ]]; then
      nohup "$(dirname "$0")/velo-openrouter-agent" "$(cat "$STUB_DIR/second.secs")" > "$GD/second-opinion.log" 2>&1 &
      printf '%s\n' "$!" > "$GD/second-opinion.log.pid"
      # The real velo-pr-gate returns after its health window, long after a second
      # opinion is up. This stub returns in milliseconds, and the reaper's grace is
      # whole seconds (SECONDS + N, so anywhere in (0, N]): a fake that is slow to
      # start (macOS takes ~100ms on the first exec of a new executable, far longer on
      # a busy host) was killed before it had run a line — no child to reap, and
      # `its-child-killed` red for a reason that is not the reaper. Return once the
      # fake has started its child, as the real gate returns once its reviewers are up.
      up=0
      while [[ $up -lt "${FAKE_RUNNER_POLLS:-200}" && ! -s "$STUB_DIR/second.child" ]]; do sleep 0.05; up=$((up + 1)); done
      if [[ ! -s "$STUB_DIR/second.child" ]]; then
        # Also left where the suite can read it (outside STUB_DIR, which every reset wipes): the
        # round that fails here fails for the harness's reason, and a mutation proof must be able
        # to tell — a red the harness caused is not evidence about the mutant.
        echo "stub velo-pr-gate: the fake second opinion never started its child" | tee "$STUB_DIR/../harness-failed" >&2
        exit 1
      fi
    fi
    [[ -f "$STUB_DIR/sonnet" ]] && printf 'prompt\n' > "$GD/check-code-agent-prompt.md"
    if [[ -f "$STUB_DIR/deepseek" ]]; then
      printf 'report\n' > "$GD/code.log"; printf 'deepseek\n' > "$GD/check-code.by"
    fi
    case "$(cat "$STUB_DIR/codex.mode" 2>/dev/null || echo finished)" in
      none) ;;
      finished)
        cat "$STUB_DIR/review.full" > "$GD/review.log"
        ( : ) & p=$!; wait "$p"
        printf '%s\n' "$p" > "$GD/review.log.pid" ;;
      running)
        # The `--wait` that returned early: the reviewer is still alive, and its
        # final message lands half a second later.
        cat "$STUB_DIR/review.partial" > "$GD/review.log"
        ( sleep 0.5; cat "$STUB_DIR/review.final" >> "$GD/review.log" ) >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$GD/review.log.pid" ;;
      badpid)
        cat "$STUB_DIR/review.full" > "$GD/review.log"
        printf 'not-a-pid\n' > "$GD/review.log.pid" ;;
    esac
    echo "  ok code-review -> codex (stub)"
    exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"
# The fake second-opinion runner: named like the real wrapper (the reaper checks
# the command line before killing), with a child of its own like the runner's
# tool subprocesses.
cat > "$TMPD/stub-bin/velo-openrouter-agent" <<'EOF'
#!/bin/bash
sleep "${1:-600}" &
# STUB_RUNNER_NEVER_UP: a runner that never announces its child, so never says it is up —
# the case the scenarios' readiness waits must report as a failure, not paper over.
[[ -n "${STUB_RUNNER_NEVER_UP:-}" ]] || echo "$!" > "$STUB_DIR/second.child"
# Also outside STUB_DIR (wiped by every reset): the test's cleanup reaps every
# child ever started. A runner killed without its child (the mutation proofs do
# exactly that) leaves an orphan whose argv does not name $TMPD.
echo "$!" >> "$STUB_DIR/../second.children"
wait
echo "second opinion report"
EOF
chmod +x "$TMPD/stub-bin/velo-openrouter-agent"

SCOPE="$TMPD/scope.md"
EXPECTED_ATTACK="$TMPD/expected-attack.md"
FINAL_EXPECTED="$TMPD/final.expected"

write_default_scope() {   # <path>
  cat > "$1" <<'EOF'
# Scope — PR under test

What this change does, in prose.

## What it does

Some text that is not the attack list.

## ATTACK

Work A1 and A2. A1 is where the risk lives.

**A1** — is the detector exhaustive? Backslashes stay literal: \1 \d+ \\n $HOME `tick`.

### A2 — a sub-heading inside the section

It belongs to ATTACK, because it is deeper than the ATTACK heading.

## Do not report

- the design
EOF
  cat > "$EXPECTED_ATTACK" <<'EOF'
Work A1 and A2. A1 is where the risk lives.

**A1** — is the detector exhaustive? Backslashes stay literal: \1 \d+ \\n $HOME `tick`.

### A2 — a sub-heading inside the section

It belongs to ATTACK, because it is deeper than the ATTACK heading.
EOF
}

# What `codex review -` actually leaves in review.log: a transcript with `user`,
# `exec` and `codex` marker lines, the final message after the LAST bare `codex`.
# The brief is echoed at the top, template alternation line included, and there are
# decoys — lines that merely CONTAIN or resemble the marker.
write_transcripts() {
  cat > "$FINAL_EXPECTED" <<'EOF'
## Codex review — PR 9 @ abc1234
**Verdict:** approve-with-findings

### Findings
- P2 f.rs:10 the guard misses the None arm
codex review found nothing else on the Some arm

### Refutation attempts that FAILED
none
EOF
  {
    echo "OpenAI Codex v0.0-stub"
    echo "--------"
    echo "user"
    echo "READ-ONLY review. Return the report as your final message."
    echo "OUTPUT — plain text, final message:"
    echo "**Verdict:** approve | approve-with-findings | blocked"
    echo "codex review"
    echo " codex"
    echo "xcodex"
  } > "$TMPD/head.part"
  {
    cat "$TMPD/head.part"
    echo "codex"
    echo "I will read the diff first."
    echo "exec"
    echo "git diff origin/master...HEAD"
    echo "codex"
    echo "Checking the second claim."
    echo "codex"
    cat "$FINAL_EXPECTED"
  } > "$STUB_DIR/review.full"
  { cat "$TMPD/head.part"; echo "codex"; echo "Checking the second claim."; } > "$STUB_DIR/review.partial"
  { echo "codex"; cat "$FINAL_EXPECTED"; } > "$STUB_DIR/review.final"
}

reset() {
  rm -rf "$GATE_DIR" "$STUB_DIR"; mkdir -p "$STUB_DIR" "$VELO_STATE/gate"
  cat > "$STUB_DIR/plan.txt" <<EOF
#$TPR  stub pr
  files: 2 (src=1 tests=0)
  gates needed:
    - code-review  (independent reviewer)
    - check-code   (src/ touched: 1 files)
would dispatch:
  check-code   -> sonnet: NOT dispatched
  code-review  -> codex review (needs the brief's ATTACK section filled in)
EOF
  write_transcripts
  write_default_scope "$SCOPE"
}

RUN_UNDER_TEST="$RUN_REAL"
run_wrapper() {   # [args...] -> $OUT $RC
  OUT=$(VELO_PR_GATE_BIN="$STUB" bash "$RUN_UNDER_TEST" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/wrapper.out"
}
# A round that may never return — the mutant that retries an unwritable dir forever —
# must not hang the suite: it is bounded, killed with its child, and reports RC=124.
run_wrapper_bounded() {   # <seconds> [args...] -> $OUT $RC
  local secs="$1" pid n=0; shift
  rm -f "$TMPD/wrapper.rc"
  ( VELO_PR_GATE_BIN="$STUB" bash "$RUN_UNDER_TEST" "$@" > "$TMPD/wrapper.out" 2>&1; echo $? > "$TMPD/wrapper.rc" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [[ $n -lt $((secs * 10)) ]]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    RC=124
  else
    RC=$(cat "$TMPD/wrapper.rc")
  fi
  wait "$pid" 2>/dev/null
  OUT=$(cat "$TMPD/wrapper.out")
}

# A `date` that answers the scope copy's stamp (FAKE_STAMP, a fixed second by
# default) and defers to the real one for everything else, so the name
# scope.<UTC>.md and its same-second suffix are asserted exactly instead of being
# raced against the clock. Put it first on PATH for the call that needs it.
# FAKE_DATE_RMDIR removes that directory first: the stamp is read after the gate dir
# exists and before the copy is written, so this is a gate dir that VANISHES in
# between — an unwritable one, whatever uid the suite runs as.
FAKEDATE="$TMPD/fakedate"; mkdir -p "$FAKEDATE"
cat > "$FAKEDATE/date" <<'EOF'
#!/bin/bash
if [[ "$*" == "-u +%Y%m%dT%H%M%SZ" ]]; then
  [[ -n "${FAKE_DATE_RMDIR:-}" ]] && rm -rf "$FAKE_DATE_RMDIR"
  echo "${FAKE_STAMP:-20261005T120000Z}"
else exec /bin/date "$@"; fi
EOF
chmod +x "$FAKEDATE/date"
scope_copies() { ls -1 "$GATE_DIR" 2>/dev/null | grep -E '^scope\.' || true; }   # the saved scope files, one per line

# The brief's OWN ATTACK section: after the LAST `## ATTACK` line, up to the
# `## Also confirm` heading, edge blank lines trimmed.
own_attack() {   # <brief>
  awk '/^## ATTACK$/ { buf = ""; on = 1; next } on && /^## Also confirm$/ { on = 0 } on { buf = buf $0 "\n" } END { printf "%s", buf }' "$1" \
    | sed -e '/./,$!d' \
    | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i] }'
}

# ── usage and the scope's ATTACK ─────────────────────────────────────────────
sc_usage() {
  SC_FAILS=""
  reset
  run_wrapper
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "usage: velo-gate-run"; sc_check no-args-usage $?
  run_wrapper notanumber "$SCOPE"
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "usage: velo-gate-run"; sc_check bad-pr-usage $?
  run_wrapper "$TPR"
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "usage: velo-gate-run"; sc_check no-scope-usage $?
  run_wrapper "$TPR" "$TMPD/does-not-exist.md"
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "scope file not found"; sc_check missing-scope-file $?
  run_wrapper "$TPR" "$SCOPE" --bogus
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "unknown argument: --bogus"; sc_check unknown-flag $?
  run_wrapper "$TPR" "$SCOPE" --check-code-by haiku
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "must be 'sonnet', 'opus', 'deepseek' or 'glm', got 'haiku'"; sc_check bad-route $?
  run_wrapper "$TPR" "$SCOPE" --check-code-by=haiku
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "got 'haiku'"; sc_check bad-route-equals-form $?
  run_wrapper "$TPR" "$SCOPE" --check-code-by
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "needs a value"; sc_check dangling-route-flag $?
  [[ ! -e "$STUB_DIR/calls.log" ]]; sc_check velo-pr-gate-never-called $?
}

sc_attack_fill() {
  SC_FAILS=""
  reset
  run_wrapper "$TPR" "$SCOPE"
  local B="$GATE_DIR/review-brief.md"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  ! has "$B" "<<< FILL THIS IN";                   sc_check placeholder-gone $?
  own_attack "$B" > "$TMPD/own.txt"
  diff -q "$TMPD/own.txt" "$EXPECTED_ATTACK" >/dev/null; sc_check section-is-the-scopes-attack-body $?
  has "$B" "## Also confirm";                      sc_check rest-of-the-brief-intact $?
  has "$B" "<!-- velo-gate-brief scope=stub range=stub -->"; sc_check trailer-intact $?
  # The scope text embedded ABOVE the section carries an ATTACK heading of its own;
  # only the brief's own section (the last) is filled.
  [[ "$(grep -c '^## ATTACK$' "$B")" == "2" ]];    sc_check scope-text-left-alone $?
  has "$TMPD/wrapper.out" "ATTACK filled from";    sc_check says-so $?
  [[ "$(ncalls '--brief-only')" == "1" ]];       sc_check primed-once $?
}

sc_attack_refused_missing() {
  SC_FAILS=""
  reset
  printf '# Scope\n\nNo attack section here.\n\n## Other\n\ntext\n' > "$SCOPE"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check refused $?
  has "$TMPD/wrapper.out" "has no '## ATTACK' section"; sc_check clear-error $?
  has "$TMPD/wrapper.out" "$SCOPE";                sc_check names-the-file $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                sc_check nothing-was-run $?
  [[ ! -e "$GATE_DIR/review-brief.md" ]];          sc_check no-brief-written $?
}

sc_attack_refused_empty() {
  SC_FAILS=""
  reset
  printf '# Scope\n\n## ATTACK\n\n   \n\n## Next\n\ntext\n' > "$SCOPE"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check refused $?
  has "$TMPD/wrapper.out" "is EMPTY";              sc_check clear-error $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                sc_check nothing-was-run $?
}

# One scope shape per call: the section the wrapper writes into the brief must be
# exactly <expected>.
attack_shape() {   # <name> <scope-file> <expected-file>
  local name="$1" scope="$2" expected="$3"
  reset
  run_wrapper "$TPR" "$scope"
  if [[ $RC -ne 0 ]]; then SC_FAILS="$SC_FAILS $name(rc=$RC)"; return; fi
  own_attack "$GATE_DIR/review-brief.md" > "$TMPD/own.txt"
  diff -q "$TMPD/own.txt" "$expected" >/dev/null || SC_FAILS="$SC_FAILS $name"
}

sc_attack_shapes() {
  SC_FAILS=""
  local S="$TMPD/shape.md" X="$TMPD/shape.expected"

  cat > "$S" <<'EOF'
# Scope

## ATTACK

first line

### sub

sub line

## Next

not included
EOF
  printf 'first line\n\n### sub\n\nsub line\n' > "$X"
  attack_shape ends-at-next-same-depth-heading "$S" "$X"

  cat > "$S" <<'EOF'
## ATTACK

before

```text
## not a heading
# nor this
```

after

## End

excluded
EOF
  printf 'before\n\n```text\n## not a heading\n# nor this\n```\n\nafter\n' > "$X"
  attack_shape fenced-hashes-do-not-end-it "$S" "$X"

  cat > "$S" <<'EOF'
Prose first.

```text
## ATTACK
fenced decoy
```

## ATTACK

the real one
EOF
  printf 'the real one\n' > "$X"
  attack_shape fenced-attack-heading-ignored "$S" "$X"

  # The fence grammar is CommonMark's (#2380 round 2): any run of 3+ opening and closing
  # let a shorter fence line or an info-string line end a block early, exposing the
  # headings still inside it and cutting the ATTACK short.
  cat > "$S" <<'EOF'
## ATTACK

before

````text
```
## not a heading
````

after

## End

excluded
EOF
  printf 'before\n\n````text\n```\n## not a heading\n````\n\nafter\n' > "$X"
  attack_shape a-shorter-fence-line-does-not-close-a-longer-fence "$S" "$X"

  cat > "$S" <<'EOF'
## ATTACK

```
```bash
## not a heading
```

after

## End

excluded
EOF
  printf '```\n```bash\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-fence-line-with-an-info-string-does-not-close "$S" "$X"

  cat > "$S" <<'EOF'
## ATTACK

```
~~~
## not a heading
```

after

## End

excluded
EOF
  printf '```\n~~~\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-tilde-line-does-not-close-a-backtick-fence "$S" "$X"

  cat > "$S" <<'EOF'
## ATTACK

```inline``` span at the start of a line.

## End

excluded
EOF
  printf '```inline``` span at the start of a line.\n' > "$X"
  attack_shape an-inline-backtick-span-is-not-an-opener "$S" "$X"

  # Indentation is counted in columns and a TAB reaches column 4 at once (CommonMark), so a
  # line whose leading whitespace holds a tab is indented code — never an opener or a closer —
  # exactly like four spaces; velo-dispatch's brief_prose reads the same rule (test_brief_fields.sh).
  printf '## ATTACK\n\nbefore\n\n\t```text\nindented code, the fence never opened\n\n## End\n\nexcluded\n' > "$S"
  printf 'before\n\n\t```text\nindented code, the fence never opened\n' > "$X"
  attack_shape a-tab-indented-line-is-not-an-opener "$S" "$X"

  printf '## ATTACK\n\n```\n\t```\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\n\t```\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-tab-indented-line-does-not-close-a-fence "$S" "$X"

  printf '## ATTACK\n\n```\n \t```\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\n \t```\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-space-then-tab-line-does-not-close-a-fence "$S" "$X"

  printf '## ATTACK\n\n```\n   \t```\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\n   \t```\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape three-spaces-then-tab-line-does-not-close-a-fence "$S" "$X"

  # A closer may be followed only by spaces and tabs (and the CR of a CRLF line). Any other
  # trailing character keeps it an ordinary line; str.strip() with no argument closed the block
  # on a non-breaking space, form feed or vertical tab and exposed the headings inside it.
  printf '## ATTACK\n\n```\nin the fence\n```\xc2\xa0\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\nin the fence\n```\xc2\xa0\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-closer-followed-by-a-non-breaking-space-does-not-close "$S" "$X"

  printf '## ATTACK\n\n```\nin the fence\n```\f\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\nin the fence\n```\f\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-closer-followed-by-a-form-feed-does-not-close "$S" "$X"

  printf '## ATTACK\n\n```\nin the fence\n```\v\n## not a heading\n```\n\nafter\n\n## End\n\nexcluded\n' > "$S"
  printf '```\nin the fence\n```\v\n## not a heading\n```\n\nafter\n' > "$X"
  attack_shape a-closer-followed-by-a-vertical-tab-does-not-close "$S" "$X"

  printf '## ATTACK\n\n```\nin the fence\n```  \t \n\nafter the closer\n\n## End\n\nexcluded\n' > "$S"
  printf '```\nin the fence\n```  \t \n\nafter the closer\n' > "$X"
  attack_shape a-closer-followed-by-spaces-and-tabs-does-close "$S" "$X"

  cat > "$S" <<'EOF'
# ATTACK

top-level body

## a deeper heading stays inside

still inside

# Other

excluded
EOF
  printf 'top-level body\n\n## a deeper heading stays inside\n\nstill inside\n' > "$X"
  attack_shape depth-one-section "$S" "$X"

  cat > "$S" <<'EOF'
## ATTACK — what to hit

body under a decorated heading
EOF
  printf 'body under a decorated heading\n' > "$X"
  attack_shape decorated-heading "$S" "$X"

  printf '## ATTACK\r\n\r\ncrlf body\r\nsecond\r\n\r\n## Next\r\nx\r\n' > "$S"
  printf 'crlf body\nsecond\n' > "$X"
  attack_shape crlf-scope "$S" "$X"

  printf '## ATTACK\n\nlast section, no trailing newline' > "$S"
  printf 'last section, no trailing newline\n' > "$X"
  attack_shape section-at-end-of-file "$S" "$X"

  # ATTACKS is not ATTACK: nothing to fill from.
  printf '## ATTACKS\n\nbody\n' > "$S"
  reset
  run_wrapper "$TPR" "$S"
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "no '## ATTACK' section"; sc_check heading-must-be-the-word-ATTACK $?
}

sc_kept_brief() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR"
  printf 'READ-ONLY review.\n\n## ATTACK\n\nHAND FILLED by the author\n\n## Also confirm\n\n<!-- velo-gate-brief scope=stub range=stub -->\n' \
    > "$GATE_DIR/review-brief.md"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                          sc_check exits-0 $?
  has "$GATE_DIR/review-brief.md" "HAND FILLED by the author"; sc_check hand-filled-attack-survives $?
  ! has "$GATE_DIR/review-brief.md" "Work A1 and A2";      sc_check scope-attack-not-forced-over-it $?
  has "$TMPD/wrapper.out" "already filled";                sc_check says-so $?
}

# ── the verdict ──────────────────────────────────────────────────────────────
sc_extract_last() {
  SC_FAILS=""
  reset
  run_wrapper "$TPR" "$SCOPE"
  local V="$GATE_DIR/codex-verdict.md"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  diff -q "$V" "$FINAL_EXPECTED" >/dev/null;       sc_check verdict-is-exactly-the-text-after-the-last-marker $?
  ! has "$V" "Checking the second claim";          sc_check no-intermediate-turn $?
  ! has "$V" "I will read the diff first";         sc_check no-first-turn $?
  has "$V" "codex review found nothing else";      sc_check decoy-line-inside-the-message-kept $?
  has "$TMPD/wrapper.out" "**Verdict:** approve-with-findings"; sc_check prints-the-verdict-line $?
  has "$TMPD/wrapper.out" "velo-gate-finish $TPR abc1234"; sc_check names-the-finish-command-and-sha $?
  has "$TMPD/wrapper.out" "$V";                    sc_check names-the-file $?
  ! has "$TMPD/wrapper.out" "no filled **Verdict:**"; sc_check no-spurious-warning $?
}

sc_extract_fallback() {
  SC_FAILS=""
  reset
  printf 'OpenAI Codex v0.0-stub\nuser\nthe brief\nusage limit reached\n' > "$STUB_DIR/review.full"
  run_wrapper "$TPR" "$SCOPE"
  local V="$GATE_DIR/codex-verdict.md"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  diff -q "$V" "$STUB_DIR/review.full" >/dev/null; sc_check whole-log-when-no-marker $?
  has "$TMPD/wrapper.out" "no 'codex' marker line"; sc_check warns-it-is-the-raw-transcript $?
  has "$TMPD/wrapper.out" "no filled **Verdict:**"; sc_check warns-there-is-no-verdict $?
}

sc_extract_empty() {
  SC_FAILS=""
  reset
  { cat "$TMPD/head.part"; echo "codex"; } > "$STUB_DIR/review.full"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  has "$TMPD/wrapper.out" "final message is EMPTY"; sc_check says-why $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];         sc_check no-empty-verdict-file-left $?
}

sc_verdict_warnings() {
  SC_FAILS=""
  reset
  # A final message with no Verdict line: a review that ended early.
  { cat "$TMPD/head.part"; echo "codex"; echo "I looked at the diff and ran out of budget."; } > "$STUB_DIR/review.full"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$TMPD/wrapper.out" "no filled **Verdict:**"; sc_check warns-when-no-verdict-line $?
  # The unfilled template line is not a verdict either.
  reset
  { cat "$TMPD/head.part"; echo "codex"; echo "**Verdict:** approve | approve-with-findings | blocked"; } > "$STUB_DIR/review.full"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "no filled **Verdict:**"; sc_check template-line-is-not-a-verdict $?
}

# The same rule, written twice (velo-pr-gate's gate_final_codex_message and the
# wrapper's grep/tail), so the two are held together here.
sc_extract_parity() {
  SC_FAILS=""
  local fn="$TMPD/final-message-fn.sh"
  awk '/^gate_final_codex_message\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$PRGATE_REAL" > "$fn"
  [[ -s "$fn" ]];                                  sc_check found-the-reference-function $?
  # shellcheck disable=SC1090
  . "$fn"
  local n
  for n in multi-turn no-marker marker-last-line; do
    reset
    case "$n" in
      multi-turn)  ;;
      no-marker)   printf 'one\ntwo\nthree\n' > "$STUB_DIR/review.full" ;;
      marker-last-line) { cat "$TMPD/head.part"; echo "codex"; echo "first"; echo "codex"; } > "$STUB_DIR/review.full" ;;
    esac
    run_wrapper "$TPR" "$SCOPE"
    gate_final_codex_message "$STUB_DIR/review.full" > "$TMPD/reference.out"
    if [[ "$n" == "marker-last-line" ]]; then
      # the reference prints nothing; the wrapper refuses it rather than write an empty report
      [[ ! -s "$TMPD/reference.out" && ! -e "$GATE_DIR/codex-verdict.md" ]]; sc_check "parity-$n" $?
    else
      diff -q "$TMPD/reference.out" "$GATE_DIR/codex-verdict.md" >/dev/null; sc_check "parity-$n" $?
    fi
  done
}

# ── waiting for Codex ────────────────────────────────────────────────────────
sc_wait_for_pid() {
  SC_FAILS=""
  reset
  printf 'running\n' > "$STUB_DIR/codex.mode"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$TMPD/wrapper.out" "waiting for the Codex review"; sc_check says-it-is-waiting $?
  diff -q "$GATE_DIR/codex-verdict.md" "$FINAL_EXPECTED" >/dev/null; sc_check reads-the-FINAL-message-not-the-partial-log $?
}

sc_no_codex_leg() {
  SC_FAILS=""
  reset
  printf 'none\n' > "$STUB_DIR/codex.mode"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  has "$TMPD/wrapper.out" "dispatched no Codex review"; sc_check says-why $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];         sc_check no-verdict-file $?
  reset
  printf 'badpid\n' > "$STUB_DIR/codex.mode"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]] && has "$TMPD/wrapper.out" "does not hold a pid"; sc_check malformed-pid-file-refused $?
}

sc_stale_hygiene() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR"
  printf 'codex\nSTALE VERDICT from last round\n' > "$GATE_DIR/review.log"
  printf '999999999\n' > "$GATE_DIR/review.log.pid"
  printf 'STALE VERDICT from last round\n' > "$GATE_DIR/codex-verdict.md"
  printf 'none\n' > "$STUB_DIR/codex.mode"            # this run dispatches no Codex
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check fails-rather-than-read-the-old-log $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];         sc_check stale-verdict-not-left-in-place $?
  [[ ! -e "$GATE_DIR/review.log" ]];               sc_check stale-log-moved-away $?
  [[ ! -e "$GATE_DIR/review.log.pid" ]];           sc_check stale-pid-removed $?
  has "$GATE_DIR/review.log.prev" "STALE VERDICT"; sc_check old-log-kept-as-prev $?
  # And a run that DOES dispatch must not carry any of it forward.
  reset
  mkdir -p "$GATE_DIR"
  printf 'codex\nSTALE VERDICT from last round\n' > "$GATE_DIR/review.log"
  printf '999999999\n' > "$GATE_DIR/review.log.pid"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0-when-dispatched $?
  ! has "$GATE_DIR/codex-verdict.md" "STALE VERDICT"; sc_check verdict-is-this-runs $?
}

# ── retry ────────────────────────────────────────────────────────────────────
sc_retry_recovers() {
  SC_FAILS=""
  reset
  printf '2 PR #%s not found\n' "$TPR" > "$STUB_DIR/fail.plan"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check recovers $?
  [[ "$(ncalls ' --plan')" == "3" ]];            sc_check plan-called-3-times $?
  [[ "$(ncalls '--brief-only')" == "1" ]];       sc_check later-steps-not-repeated $?
  [[ "$(ncalls '--exec --wait')" == "1" ]];      sc_check run-called-once $?
  [[ "$(grep -c 'transient gh failure' "$TMPD/wrapper.out")" == "2" ]]; sc_check each-retry-announced $?
  # The same, for the other two steps and the other transient message.
  reset
  printf '2 PR #%s not found\n' "$TPR" > "$STUB_DIR/fail.brief"
  printf '1 could not read base branch for #%s\n' "$TPR" > "$STUB_DIR/fail.run"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check recovers-brief-and-run $?
  [[ "$(ncalls '--brief-only')" == "3" ]];       sc_check brief-called-3-times $?
  [[ "$(ncalls '--exec --wait')" == "2" ]];      sc_check run-called-twice $?
  [[ "$(ncalls ' --plan')" == "1" ]];            sc_check plan-not-repeated $?
  reset
  printf '1 could not read head branch for #%s\n' "$TPR" > "$STUB_DIR/fail.plan"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check head-branch-failure-is-transient-too $?
}

sc_retry_gives_up() {
  SC_FAILS=""
  reset
  printf '99 PR #%s not found\n' "$TPR" > "$STUB_DIR/fail.plan"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check fails $?
  [[ "$(ncalls ' --plan')" == "4" ]];            sc_check one-attempt-plus-three-retries $?
  has "$TMPD/wrapper.out" "giving up";             sc_check says-it-gave-up $?
  [[ "$(ncalls '--brief-only')" == "0" ]];       sc_check nothing-after-the-failed-step $?
  reset
  printf '99 PR #%s not found\n' "$TPR" > "$STUB_DIR/fail.run"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check run-step-fails $?
  [[ "$(ncalls '--exec --wait')" == "4" ]];      sc_check run-step-four-attempts $?
}

sc_no_retry_for_local_failures() {
  SC_FAILS=""
  local msg
  # The last is velo-gate's own refusal to plan past a linked issue it could not read: gh's reason is
  # in the message and the operator is shown it at once; the wrapper cannot tell a blip from a deleted
  # issue or a dead token, so it does not repeat the read.
  for msg in "no local worktree checked out on 'feature'" "a gate is already running for #$TPR (pid 1)" "scope file not found: x" \
             "could not read issue #7, which #$TPR closes, to count its acceptance bars: HTTP 502: Bad Gateway"; do
    reset
    printf '99 %s\n' "$msg" > "$STUB_DIR/fail.plan"
    run_wrapper "$TPR" "$SCOPE"
    [[ $RC -ne 0 ]];                               sc_check "fails[$msg]" $?
    [[ "$(ncalls ' --plan')" == "1" ]];          sc_check "one-attempt[$msg]" $?
    ! has "$TMPD/wrapper.out" "transient gh failure"; sc_check "no-retry-banner[$msg]" $?
  done
  # A different PR's "not found" is not ours to retry either.
  reset
  printf '99 PR #1 not found\n' > "$STUB_DIR/fail.plan"
  run_wrapper "$TPR" "$SCOPE"
  [[ "$(ncalls ' --plan')" == "1" ]];            sc_check other-prs-failure-not-retried $?
}

# ── refusals and short exits ─────────────────────────────────────────────────
sc_lock() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR/.lock"
  printf '%s\n' "$$" > "$GATE_DIR/.lock/pid"               # a LIVE holder: this shell
  printf 'codex\nRUNNING GATES LOG\n' > "$GATE_DIR/review.log"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                 sc_check refused $?
  has "$TMPD/wrapper.out" "a gate is already running for #$TPR"; sc_check says-why $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                sc_check velo-pr-gate-not-called $?
  has "$GATE_DIR/review.log" "RUNNING GATES LOG";  sc_check running-gates-log-not-moved $?
  # A holder that is gone must not wedge the PR.
  reset
  mkdir -p "$GATE_DIR/.lock"
  printf '999999999\n' > "$GATE_DIR/.lock/pid"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check stale-lock-does-not-block $?
}

# A lock whose holder cannot be told (no pid written yet, an empty or garbage pid file) is not a dead
# holder: the early check used to read it as "nobody is running" and carry on, moving a possibly
# live gate's logs aside — the very thing the check exists to prevent.
sc_lock_unknown_holder() {
  SC_FAILS=""
  local state
  for state in empty garbage absent; do
    reset
    mkdir -p "$GATE_DIR/.lock"
    case "$state" in
      empty)   : > "$GATE_DIR/.lock/pid" ;;
      garbage) printf 'not-a-pid\n' > "$GATE_DIR/.lock/pid" ;;
      absent)  : ;;
    esac
    printf 'codex\nRUNNING GATES LOG\n' > "$GATE_DIR/review.log"
    run_wrapper "$TPR" "$SCOPE"
    [[ $RC -ne 0 ]];                                   sc_check "refused[$state]" $?
    has "$TMPD/wrapper.out" "its holder cannot be identified"; sc_check "says-why[$state]" $?
    [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check "velo-pr-gate-not-called[$state]" $?
    has "$GATE_DIR/review.log" "RUNNING GATES LOG";    sc_check "running-gates-log-not-moved[$state]" $?
    [[ -d "$GATE_DIR/.lock" ]];                        sc_check "lock-left-in-place[$state]" $?
  done
}

# velo-pr-gate takes the lock and velo-gate-run checks it early; both ask "who holds it?" with the same
# function, kept as a copy because neither script sources the other. A copy that drifts is a lock one
# of them reads differently from the other, so the two must stay byte-identical.
sc_lock_holder_functions_agree() {
  SC_FAILS=""
  local a b
  a=$(sed -n '/^read_lock_holder() {/,/^}/p' "$RUN_UNDER_TEST")
  b=$(sed -n '/^read_lock_holder() {/,/^}/p' "$PRGATE_REAL")
  [[ -n "$a" && -n "$b" ]];                          sc_check both-scripts-have-the-function $?
  [[ "$a" == "$b" ]];                                sc_check the-two-copies-are-identical $?
}

sc_none_plan() {
  SC_FAILS=""
  reset
  printf '#%s  docs\n  gates needed:\n    - none — docs only, no buildable code and no orchestration\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$TMPD/wrapper.out" "no gates required";     sc_check says-so $?
  [[ "$(wc -l < "$STUB_DIR/calls.log" | tr -d ' ')" == "1" ]]; sc_check only-the-plan-was-read $?
  [[ ! -e "$GATE_DIR/review-brief.md" ]];          sc_check no-brief $?
}

# The plan's `#<pr>  <title>` line is not a gate: a title that names one must not
# make the wrapper act as if the plan had demanded it, in either direction.
sc_plan_title() {
  SC_FAILS=""
  reset
  printf '#%s  fix the code-review gate\n  gates needed:\n    - check-spec   (#1 has 4 acceptance bars)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  [[ "$(ncalls '--brief-only')" == "0" ]];          sc_check title-naming-code-review-makes-no-brief $?
  has "$TMPD/wrapper.out" "no code-review gate in this plan"; sc_check says-there-is-no-code-review $?
  reset
  printf '#%s  none — a PR about gates\n  gates needed:\n    - code-review  (independent reviewer)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check title-naming-none-does-not-end-the-round $?
  [[ "$(ncalls '--exec --wait')" == "1" ]];         sc_check the-gates-ran $?
}

sc_args() {
  SC_FAILS=""
  reset
  run_wrapper "$TPR" "$SCOPE"
  printf '%s --plan\n%s %s --brief-only\n%s %s --exec --wait\n' "$TPR" "$TPR" "$SCOPE" "$TPR" "$SCOPE" > "$TMPD/calls.expected"
  diff -q "$STUB_DIR/calls.log" "$TMPD/calls.expected" >/dev/null; sc_check plan-then-brief-only-then-exec-wait $?
  reset
  run_wrapper "$TPR" "$SCOPE" --check-code-by opus
  printf '%s --plan --check-code-by opus\n%s %s --brief-only --check-code-by opus\n%s %s --exec --wait --check-code-by opus\n' \
    "$TPR" "$TPR" "$SCOPE" "$TPR" "$SCOPE" > "$TMPD/calls.expected"
  diff -q "$STUB_DIR/calls.log" "$TMPD/calls.expected" >/dev/null; sc_check route-passed-to-every-step $?
  reset
  run_wrapper "$TPR" "$SCOPE" --check-code-by=sonnet
  [[ "$(grep -c -e '--check-code-by=sonnet' "$STUB_DIR/calls.log")" == "3" ]]; sc_check equals-form-passed-through $?
}

sc_spec_only() {
  SC_FAILS=""
  reset
  printf '#%s  spec\n  gates needed:\n    - check-spec   (#1 has 4 acceptance bars)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  [[ "$(ncalls '--brief-only')" == "0" ]];       sc_check no-brief-for-a-spec-only-plan $?
  [[ "$(ncalls '--exec --wait')" == "1" ]];      sc_check gates-still-run $?
  has "$TMPD/wrapper.out" "no code-review gate in this plan"; sc_check says-there-is-no-verdict $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];         sc_check no-verdict-file $?
}

sc_empty_range() {
  SC_FAILS=""
  reset
  : > "$STUB_DIR/empty-range"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                 sc_check exits-0-like-velo-pr-gate $?
  has "$TMPD/wrapper.out" "NO verdict was produced"; sc_check says-no-verdict $?
  [[ "$(ncalls '--exec --wait')" == "0" ]];      sc_check gates-not-run $?
  [[ ! -e "$GATE_DIR/codex-verdict.md" ]];         sc_check no-verdict-file $?
}

sc_advisory_hint() {
  SC_FAILS=""
  reset
  : > "$STUB_DIR/deepseek"
  run_wrapper "$TPR" "$SCOPE" --check-code-by deepseek
  [[ $RC -eq 0 ]];                                 sc_check deepseek-route-accepted $?
  has "$TMPD/wrapper.out" "the deepseek leg's report (ADVISORY — not a gating verdict) is the tail of $GATE_DIR/code.log"; sc_check says-advisory $?
  ! has "$TMPD/wrapper.out" "the opus leg's report"; sc_check not-called-opus $?
  run_wrapper "$TPR" "$SCOPE" --check-code-by glm
  [[ $RC -eq 0 ]];                                 sc_check glm-route-accepted $?
}

sc_check_code_hint() {
  SC_FAILS=""
  reset
  : > "$STUB_DIR/sonnet"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "launch the read-only Sonnet agent on $GATE_DIR/check-code-agent-prompt.md"; sc_check points-at-the-prompt $?
  has "$TMPD/wrapper.out" "post-cc-$TPR.md";       sc_check names-the-post-files $?
}

# The finish command names the reports THIS plan produces; one that names a report the
# plan never makes is a command that dies on its first argument check.
sc_finish_line() {
  SC_FAILS=""
  # Both reports: positional, the form velo-gate-finish documents first.
  reset
  : > "$STUB_DIR/sonnet"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "velo-gate-finish $TPR abc1234 --pass|--block post-cc-$TPR.md post-cr-$TPR.md"; sc_check both-reports-positional $?
  # code-review only — the usual tooling PR, nothing under src/.
  reset
  printf '#%s  tooling\n  gates needed:\n    - code-review  (independent reviewer)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "velo-gate-finish $TPR abc1234 --pass|--block --code-review post-cr-$TPR.md"; sc_check code-review-only-by-flag $?
  ! has "$TMPD/wrapper.out" "post-cc-$TPR.md";      sc_check code-review-only-names-no-check-code-file $?
  # check-code only — a plan with no code-review gate, so no Codex verdict.
  reset
  : > "$STUB_DIR/sonnet"
  printf '#%s  src\n  gates needed:\n    - check-code   (src/ touched: 1 files)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "velo-gate-finish $TPR abc1234 --pass|--block --check-code post-cc-$TPR.md"; sc_check check-code-only-by-flag $?
  ! has "$TMPD/wrapper.out" "post-cr-$TPR.md";      sc_check check-code-only-names-no-code-review-file $?
  # neither — a spec-only plan: a command that must die is not printed.
  reset
  printf '#%s  spec\n  gates needed:\n    - check-spec   (#1 has 4 acceptance bars)\n' "$TPR" > "$STUB_DIR/plan.txt"
  run_wrapper "$TPR" "$SCOPE"
  has "$TMPD/wrapper.out" "no check-code or code-review report to post"; sc_check neither-says-there-is-nothing-to-finish $?
  ! has "$TMPD/wrapper.out" "velo-gate-finish $TPR abc1234"; sc_check neither-prints-no-finish-command $?
  has "$TMPD/wrapper.out" "velo-gate $TPR --pass|--block"; sc_check neither-points-at-velo-gate $?
}

# ── the second opinion is reaped, never left holding the gate (#2350) ─────────
alive() { kill -0 "$1" 2>/dev/null; }
second_pid() { cat "$GATE_DIR/second-opinion.log.pid" 2>/dev/null; }
# Until the fake second opinion this scenario launched has started its child (the same
# handshake the stub velo-pr-gate makes before it returns): the reaper inspects and kills
# by pid, and a fake that has not yet run is neither the runner it looks like nor a
# parent with a child to reap. The wait is bounded (FAKE_RUNNER_POLLS x 50ms, 10s by
# default). A fake that is still not up after it is a FAILURE of the calling scenario —
# recorded in SC_FAILS here, with the reason, and returned as non-zero — never a reason to
# skip the checks quietly: a loaded host would otherwise un-test the reaper without a word.
# It is also written to $HARNESS_FAILED, because the red it leaves is the HARNESS's: a
# mutation proof that counted it as the mutant being caught would prove nothing (proof_verdict).
await_fake_runner() {
  local n=0 polls="${FAKE_RUNNER_POLLS:-200}"
  while [[ $n -lt $polls && ! -s "$STUB_DIR/second.child" ]]; do sleep 0.05; n=$((n + 1)); done
  [[ -s "$STUB_DIR/second.child" ]] && return 0
  SC_FAILS="$SC_FAILS the-fake-second-opinion-never-started-its-child(waited-${polls}x50ms)"
  printf 'the fake second opinion never started its child (waited %sx50ms)\n' "$polls" > "$HARNESS_FAILED"
  return 1
}

sc_reap_after_codex() {
  SC_FAILS=""
  reset
  echo 600 > "$STUB_DIR/second.secs"
  VELO_SECOND_OPINION_GRACE=1 run_wrapper "$TPR" "$SCOPE"
  local p c
  p=$(second_pid); c=$(cat "$STUB_DIR/second.child" 2>/dev/null)
  [[ $RC -eq 0 ]];                                   sc_check exits-0 $?
  [[ -s "$GATE_DIR/codex-verdict.md" ]];             sc_check verdict-still-written $?
  [[ -n "$p" ]] && ! alive "$p";                     sc_check runner-killed $?
  [[ -n "$c" ]] && ! alive "$c";                     sc_check its-child-killed $?
  has "$GATE_DIR/second-opinion.log" "second opinion KILLED"; sc_check log-says-incomplete $?
  has "$TMPD/wrapper.out" "second opinion (pid $p) killed"; sc_check says-so $?
}

sc_reap_grace() {
  SC_FAILS=""
  reset
  echo 1 > "$STUB_DIR/second.secs"
  VELO_SECOND_OPINION_GRACE=20 run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check exits-0 $?
  has "$TMPD/wrapper.out" "second opinion finished on its own"; sc_check finished-within-grace $?
  ! has "$GATE_DIR/second-opinion.log" "KILLED";     sc_check not-killed $?
  has "$GATE_DIR/second-opinion.log" "second opinion report"; sc_check its-report-is-complete $?
}

sc_reap_on_failure() {
  SC_FAILS=""
  reset
  echo 600 > "$STUB_DIR/second.secs"
  echo none > "$STUB_DIR/codex.mode"
  VELO_SECOND_OPINION_GRACE=60 run_wrapper "$TPR" "$SCOPE"
  local p; p=$(second_pid)
  [[ $RC -ne 0 ]];                                   sc_check the-round-failed $?
  [[ -n "$p" ]] && ! alive "$p";                     sc_check killed-on-the-way-out $?
}

sc_reap_previous_round() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR"
  nohup "$TMPD/stub-bin/velo-openrouter-agent" 600 > "$GATE_DIR/second-opinion.log" 2>&1 &
  local old=$!
  printf '%s\n' "$old" > "$GATE_DIR/second-opinion.log.pid"; printf '%s\n' "$old" > "$STUB_DIR/old.pid"
  # No fake, nothing to reap and nothing to assert: stop here, RED (await_fake_runner has put
  # the reason in SC_FAILS), after cleaning up the process this scenario started.
  if ! await_fake_runner; then kill "$old" 2>/dev/null; wait "$old" 2>/dev/null; return 1; fi
  run_wrapper "$TPR" "$SCOPE"
  [[ "$(cat "$STUB_DIR/old.state" 2>/dev/null)" == "dead" ]]; sc_check dead-before-the-gates-run $?
  kill "$old" 2>/dev/null; return 0
}

# The readiness waits' own contract: a fake second opinion that never starts is a RED
# scenario that says why, stops before the wrapper runs, and leaves a harness-failed marker
# that makes any mutation proof built on it INCONCLUSIVE — not "the mutant was caught". Pinned
# because the only thing that makes it red is a record in SC_FAILS, and a record nothing reads
# is the first thing an edit drops. The fake never announces its child (STUB_RUNNER_NEVER_UP);
# the waits are cut to 4 polls, so each case costs a fifth of a second. Two waits exist: the
# scenario's own (await_fake_runner, case 1) and the stub gate's handshake, which is the one the
# reap scenarios — and so their mutation proofs — meet (case 2).
sc_reap_previous_round_with_no_fake() { STUB_RUNNER_NEVER_UP=1 FAKE_RUNNER_POLLS=4 sc_reap_previous_round; }
sc_fake_runner_never_up_is_red() {
  local inner rc why inner2 why2 msg kept
  rm -f "$HARNESS_FAILED"
  STUB_RUNNER_NEVER_UP=1 FAKE_RUNNER_POLLS=4 sc_reap_previous_round; rc=$?
  inner="$SC_FAILS"; why=$(head -1 "$HARNESS_FAILED" 2>/dev/null)
  SC_FAILS=""
  [[ "$inner" == *"the-fake-second-opinion-never-started-its-child(waited-4x50ms)"* ]]; sc_check the-scenario-is-red-and-names-the-reason $?
  [[ $rc -ne 0 ]];                                   sc_check and-returns-non-zero $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check and-stops-before-the-wrapper-calls-the-stub-gate $?
  [[ -n "$why" ]];                                   sc_check and-leaves-the-harness-failed-marker $?
  [[ "$(proof_verdict "$inner" "" "$why")" == inconclusive ]]; sc_check and-a-proof-built-on-it-is-inconclusive $?
  kept="$SC_FAILS"   # the scenario below starts by resetting SC_FAILS: carry this case's result over it
  rm -f "$HARNESS_FAILED"
  STUB_RUNNER_NEVER_UP=1 FAKE_RUNNER_POLLS=4 sc_reap_after_codex
  inner2="$SC_FAILS"; why2=$(head -1 "$HARNESS_FAILED" 2>/dev/null)
  SC_FAILS="$kept"
  [[ -n "$inner2" ]];                                sc_check the-reap-scenario-is-red-without-a-fake $?
  [[ -n "$why2" ]];                                  sc_check and-the-stub-gate-leaves-the-marker $?
  [[ "$(proof_verdict "$inner2" "" "$why2")" == inconclusive ]]; sc_check and-a-reap-proof-built-on-it-is-inconclusive $?
  # A FAIL the harness caused says so (run_scenarios' own line, read in a subshell with ok/fail shadowed).
  msg=$(ok() { echo "ok:$1"; }; fail() { echo "FAIL:$1"; }
        run_scenarios "sc_reap_previous_round_with_no_fake::previous round")
  [[ "$msg" == FAIL:*"[the harness failed: the fake second opinion never started its child"* ]]; sc_check and-the-fail-line-names-the-harness $?
  rm -f "$HARNESS_FAILED"
}

# proof_verdict, case by case: the harness-failure rule outranks every other reading.
sc_proof_verdicts() {
  SC_FAILS=""
  [[ "$(proof_verdict "x" "" "")" == proved ]];                    sc_check red-then-green-is-proved $?
  [[ "$(proof_verdict "" "" "")" == stayed-green ]];               sc_check no-red-is-stayed-green $?
  [[ "$(proof_verdict "x" "y" "")" == real-red ]];                 sc_check red-both-times-is-real-red $?
  [[ "$(proof_verdict "x" "" "no fake")" == inconclusive ]];       sc_check a-harness-failure-is-never-the-mutant-caught $?
  [[ "$(proof_verdict "" "" "no fake")" == inconclusive ]];        sc_check nor-staying-green $?
  [[ "$(proof_verdict "x" "y" "no fake")" == inconclusive ]];      sc_check nor-the-real-script-red $?
}

sc_reap_not_a_runner() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR"
  sleep 600 &
  local other=$!
  printf '%s\n' "$other" > "$GATE_DIR/second-opinion.log.pid"
  run_wrapper "$TPR" "$SCOPE"
  alive "$other";                                    sc_check unrelated-process-left-alone $?
  has "$TMPD/wrapper.out" "is not a second-opinion runner"; sc_check says-why $?
  kill "$other" 2>/dev/null; wait "$other" 2>/dev/null; return 0
}

# ── the scope file is kept whole, one copy per round (#2379) ─────────────────
# Only the ATTACK body reaches the brief. The scope's header and every section after
# the ATTACK are what a re-run or a later re-review needs, and they were never saved.
sc_scope_copy() {
  SC_FAILS=""
  reset
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  local C="$GATE_DIR/scope.20261005T120000Z.md"
  [[ $RC -eq 0 ]];                                   sc_check exits-0 $?
  [[ "$(scope_copies)" == "scope.20261005T120000Z.md" ]]; sc_check one-file-named-scope.UTC.md $?
  cmp -s "$C" "$SCOPE";                              sc_check byte-identical-to-the-scope $?
  has "$C" "What this change does, in prose.";       sc_check keeps-the-header-prose $?
  has "$C" "## Do not report";                       sc_check keeps-the-sections-after-attack $?
  [[ -s "$GATE_DIR/attack-body.md" ]] && ! has "$GATE_DIR/attack-body.md" "What this change does, in prose."; sc_check attack-body-alone-would-have-lost-it $?
  has "$TMPD/wrapper.out" "scope file saved: $C";    sc_check says-where $?
  [[ -z "$(ls -A "$GATE_DIR" | grep -F '.scope-copy' || true)" ]]; sc_check no-temp-file-left-after-the-publish $?
}

# The point of the copy: a round that dies still leaves it behind.
sc_scope_copy_survives_failure() {
  SC_FAILS=""
  reset
  echo "9 no local worktree for #$TPR" > "$STUB_DIR/fail.plan"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                   sc_check plan-failure-fails-the-round $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.md" "$SCOPE"; sc_check copy-survives-a-plan-failure $?
  reset
  echo "9 no local worktree for #$TPR" > "$STUB_DIR/fail.run"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                   sc_check launch-failure-fails-the-round $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.md" "$SCOPE"; sc_check copy-survives-a-launch-failure $?
}

# One copy per round. The scope changes between rounds (a re-review's delta) and the
# clock does not move: the first round's copy must still be the first round's scope.
sc_scope_copy_per_round() {
  SC_FAILS=""
  reset
  local one="$GATE_DIR/scope.20261005T120000Z.md" two="$GATE_DIR/scope.20261005T120000Z.2.md" three="$GATE_DIR/scope.20261005T120000Z.3.md" later="$GATE_DIR/scope.20261005T120007Z.md"
  cp "$SCOPE" "$TMPD/scope.round1"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  printf '\nROUND-TWO-MARKER: what changed since round one\n' >> "$SCOPE"
  cp "$SCOPE" "$TMPD/scope.round2"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check second-round-runs $?
  cmp -s "$one" "$TMPD/scope.round1";                sc_check first-round-copy-not-overwritten $?
  cmp -s "$two" "$TMPD/scope.round2";                sc_check same-second-round-takes-a-suffix $?
  printf '\nROUND-THREE-MARKER\n' >> "$SCOPE"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  has "$three" "ROUND-THREE-MARKER";                 sc_check third-round-takes-the-next-suffix $?
  ! has "$two" "ROUND-THREE-MARKER";                 sc_check second-round-copy-not-overwritten $?
  FAKE_STAMP=20261005T120007Z PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  has "$later" "ROUND-THREE-MARKER";                 sc_check a-later-second-gets-a-plain-name $?
  [[ "$(scope_copies | wc -l | tr -d ' ')" == "4" ]]; sc_check four-rounds-four-files $?
}

# A record that cannot be written is not a record: the round stops, with cp's own
# error on screen, before any step runs.
sc_scope_copy_loud() {
  SC_FAILS=""
  reset
  mkdir -p "$TMPD/failcp"
  # A full disk: some of the file is down when the copy fails.
  printf '#!/bin/bash\ndst=""; for a in "$@"; do dst="$a"; done\nhead -c 10 "$1" > "$dst"\necho "cp: simulated disk failure" >&2\nexit 1\n' > "$TMPD/failcp/cp"
  chmod +x "$TMPD/failcp/cp"
  PATH="$TMPD/failcp:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 ]];                                   sc_check refused $?
  has "$TMPD/wrapper.out" "could not save a copy of the scope file: cp to $GATE_DIR/.scope-copy."; sc_check says-what-and-where $?
  has "$TMPD/wrapper.out" "simulated disk failure";  sc_check shows-cps-own-error $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check no-step-ran-without-the-record $?
  [[ -z "$(scope_copies)" ]];                        sc_check no-partial-file-left-looking-like-a-copy $?
  [[ -z "$(ls -A "$GATE_DIR" | grep -F '.scope-copy' || true)" ]]; sc_check and-no-temp-file-left-behind $?
}

# A refused invocation is not a round: a bad scope, or a gate already running, leaves
# nothing behind — least of all inside the running gate's directory.
sc_scope_copy_refusals() {
  SC_FAILS=""
  reset
  printf '# Scope\n\nNo attack section here.\n' > "$SCOPE"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 && -z "$(scope_copies)" ]];           sc_check no-copy-for-a-scope-with-no-attack $?
  reset
  printf '# Scope\n\n## ATTACK\n\n   \n' > "$SCOPE"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 && -z "$(scope_copies)" ]];           sc_check no-copy-for-an-empty-attack $?
  reset
  mkdir -p "$GATE_DIR/.lock"
  printf '%s\n' "$$" > "$GATE_DIR/.lock/pid"
  run_wrapper "$TPR" "$SCOPE"
  [[ $RC -ne 0 && -z "$(scope_copies)" ]];           sc_check no-copy-into-a-running-gates-dir $?
}

# The copy's NAME is taken atomically, by the hard link that publishes it (#2380). Looking
# for a free name and then creating it are two steps, and two rounds started in the same
# second both saw scope.<UTC>.md free: the later write overwrote the earlier one. Here two
# wrappers share a PR, a gate dir and a clock second, each with its own scope; an ln that
# waits for its twin makes BOTH decide where to publish before EITHER has published, so a
# check-then-create order loses a copy every time rather than one run in a hundred.
sc_scope_copy_concurrent() {
  SC_FAILS=""
  reset
  rm -rf "$TMPD/race" "$TMPD/race-bin"; mkdir -p "$TMPD/race" "$TMPD/race-bin"
  # Both rounds reach the publish and wait for each other: both have decided where to publish
  # before either has. One publishes first (the mkdir wins the election). The other waits until
  # that publish is done AND its round has acted on it — its temp file is gone — and only then
  # publishes: the moment an overwriting publish destroys a record whose owner already
  # reported it saved. An atomic exclusive publish fails there and steps to the next suffix.
  cat > "$TMPD/race-bin/ln" <<'EOF'
#!/bin/bash
last=""; tmp=""; for a in "$@"; do tmp="$last"; last="$a"; done
if [[ "$last" == */scope.*.md ]]; then
  : > "$RACE_DIR/arrived.$$"
  n=0
  while [[ $(ls "$RACE_DIR" | grep -c '^arrived\.') -lt 2 && $n -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
  if mkdir "$RACE_DIR/first" 2>/dev/null; then
    printf '%s\n' "$tmp" > "$RACE_DIR/first.tmp"
    /bin/ln "$@"; rc=$?
    : > "$RACE_DIR/done"
    exit $rc
  fi
  n=0
  while [[ ! -e "$RACE_DIR/done" && $n -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
  n=0
  while [[ -e "$(cat "$RACE_DIR/first.tmp")" && $n -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
fi
exec /bin/ln "$@"
EOF
  chmod +x "$TMPD/race-bin/ln"
  # Each round dies at the plan, right after the copy: the copy is all this pins.
  echo "9 no local worktree for #$TPR" > "$STUB_DIR/fail.plan"
  cp "$SCOPE" "$TMPD/scope.A.md"; printf '\nRACE-MARKER-A\n' >> "$TMPD/scope.A.md"
  cp "$SCOPE" "$TMPD/scope.B.md"; printf '\nRACE-MARKER-B\n' >> "$TMPD/scope.B.md"
  local pa pb
  ( PATH="$TMPD/race-bin:$FAKEDATE:$PATH" RACE_DIR="$TMPD/race" VELO_PR_GATE_BIN="$STUB" \
      bash "$RUN_UNDER_TEST" "$TPR" "$TMPD/scope.A.md" > "$TMPD/race.a.out" 2>&1 ) & pa=$!
  ( PATH="$TMPD/race-bin:$FAKEDATE:$PATH" RACE_DIR="$TMPD/race" VELO_PR_GATE_BIN="$STUB" \
      bash "$RUN_UNDER_TEST" "$TPR" "$TMPD/scope.B.md" > "$TMPD/race.b.out" 2>&1 ) & pb=$!
  wait "$pa" 2>/dev/null; wait "$pb" 2>/dev/null
  local sa sb
  sa=$(sed -n 's/^scope file saved: //p' "$TMPD/race.a.out"); sb=$(sed -n 's/^scope file saved: //p' "$TMPD/race.b.out")
  [[ "$(scope_copies | wc -l | tr -d ' ')" == "2" ]];            sc_check two-rounds-two-files $?
  [[ -f "$GATE_DIR/scope.20261005T120000Z.md" && -f "$GATE_DIR/scope.20261005T120000Z.2.md" ]]; sc_check the-loser-took-the-next-suffix $?
  [[ -n "$sa" && -n "$sb" && "$sa" != "$sb" ]];                  sc_check the-two-rounds-name-different-files $?
  [[ -n "$sa" ]] && cmp -s "$sa" "$TMPD/scope.A.md";             sc_check round-A-kept-its-own-scope $?
  [[ -n "$sb" ]] && cmp -s "$sb" "$TMPD/scope.B.md";             sc_check round-B-kept-its-own-scope $?
}

# A gate dir that cannot be written is not a name collision. Treating every failed
# publish as "taken, try the next suffix" retries it for ever, so the round must STOP,
# name the file and show the shell's own error, before any step runs. Bounded: a round
# that does spin is killed and reported as such, not left to hang the suite.
sc_scope_copy_unwritable() {
  SC_FAILS=""
  reset
  FAKE_DATE_RMDIR="$GATE_DIR" PATH="$FAKEDATE:$PATH" run_wrapper_bounded 6 "$TPR" "$SCOPE"
  [[ $RC -ne 0 && $RC -ne 124 ]];                    sc_check vanished-dir-stops-the-round-it-does-not-spin $?
  has "$TMPD/wrapper.out" "could not save a copy of the scope file: cp to $GATE_DIR/.scope-copy."; sc_check says-what-and-where $?
  has "$TMPD/wrapper.out" "No such file or directory"; sc_check shows-the-shells-own-error $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check no-step-ran-without-the-record $?
  # The same, with a directory that EXISTS and refuses writes — when this user can be
  # refused (root cannot).
  if [[ "$(id -u)" != "0" ]]; then
    reset
    mkdir -p "$GATE_DIR"; chmod 555 "$GATE_DIR"
    PATH="$FAKEDATE:$PATH" run_wrapper_bounded 6 "$TPR" "$SCOPE"
    chmod 755 "$GATE_DIR"
    [[ $RC -ne 0 && $RC -ne 124 ]];                  sc_check read-only-dir-stops-the-round-it-does-not-spin $?
    has "$TMPD/wrapper.out" "Permission denied";     sc_check read-only-dir-shows-the-shells-error $?
    [[ ! -e "$STUB_DIR/calls.log" && -z "$(scope_copies)" ]]; sc_check read-only-dir-nothing-ran-nothing-saved $?
  else
    echo "  SKIP  read-only gate dir: running as root, which a mode bit cannot refuse"
  fi
  # The publish step on its own: the temp file is written, then the hard link is refused
  # (a filesystem with no hard links) and NO name is taken. That is not a collision either.
  reset
  rm -rf "$TMPD/nolink"; mkdir -p "$TMPD/nolink"
  cat > "$TMPD/nolink/ln" <<'EOF'
#!/bin/bash
last=""; for a in "$@"; do last="$a"; done
if [[ "$last" == */scope.*.md ]]; then echo "ln: $last: Operation not permitted" >&2; exit 1; fi
exec /bin/ln "$@"
EOF
  chmod +x "$TMPD/nolink/ln"
  PATH="$TMPD/nolink:$FAKEDATE:$PATH" run_wrapper_bounded 6 "$TPR" "$SCOPE"
  [[ $RC -ne 0 && $RC -ne 124 ]];                    sc_check a-refused-publish-stops-the-round-it-does-not-spin $?
  has "$TMPD/wrapper.out" "could not save the scope file as $GATE_DIR/scope.20261005T120000Z.md"; sc_check publish-says-what-and-where $?
  has "$TMPD/wrapper.out" "Operation not permitted"; sc_check publish-shows-lns-own-error $?
  [[ ! -e "$STUB_DIR/calls.log" && -z "$(scope_copies)" ]]; sc_check publish-nothing-ran-nothing-saved $?
  [[ -z "$(ls -A "$GATE_DIR" | grep -F '.scope-copy' || true)" ]]; sc_check publish-no-temp-file-left-behind $?
}

# A name that is TAKEN is not only a regular file. A dangling symlink at the first
# name fails the reservation (O_EXCL does not follow it) while a bare existence test
# says "free": that is a collision to step past, never an error, and never a write
# through the link.
sc_scope_copy_symlink() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR" "$TMPD/elsewhere"
  ln -s "$TMPD/elsewhere/target.md" "$GATE_DIR/scope.20261005T120000Z.md"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check round-runs $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.2.md" "$SCOPE"; sc_check took-the-next-suffix $?
  [[ ! -e "$TMPD/elsewhere/target.md" ]];            sc_check nothing-written-through-the-link $?
  [[ -L "$GATE_DIR/scope.20261005T120000Z.md" ]];    sc_check link-left-alone $?
}

# ...and neither is a symlink to a DIRECTORY: ln (like cp) treats a destination that is a
# link to a directory as that directory and drops the file INSIDE it — a copy "saved" under
# a name that holds nothing, with the round reporting success.
sc_scope_copy_symlink_to_dir() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR" "$TMPD/elsewhere.d"
  rm -f "$TMPD/elsewhere.d"/* "$TMPD/elsewhere.d"/.[a-z]* 2>/dev/null
  ln -s "$TMPD/elsewhere.d" "$GATE_DIR/scope.20261005T120000Z.md"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check round-runs $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.2.md" "$SCOPE"; sc_check took-the-next-suffix $?
  [[ -z "$(ls -A "$TMPD/elsewhere.d")" ]];           sc_check nothing-dropped-inside-the-linked-directory $?
  [[ -L "$GATE_DIR/scope.20261005T120000Z.md" ]];    sc_check link-left-alone $?
}

# ...nor is a real DIRECTORY at the name: the same inside-the-directory link, the same
# "saved" report for a name that holds no scope.
sc_scope_copy_real_dir() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR/scope.20261005T120000Z.md"
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check round-runs $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.2.md" "$SCOPE"; sc_check took-the-next-suffix $?
  [[ -d "$GATE_DIR/scope.20261005T120000Z.md" && -z "$(ls -A "$GATE_DIR/scope.20261005T120000Z.md")" ]]; sc_check directory-left-alone-and-empty $?
  has "$TMPD/wrapper.out" "scope file saved: $GATE_DIR/scope.20261005T120000Z.2.md"; sc_check reports-the-file-that-holds-the-scope $?
}

# The link made inside such a directory is removed again — and if it cannot be, that is
# said, loudly, before any step runs: not skipped over with the round reporting success.
sc_scope_copy_dir_undo_fails() {
  SC_FAILS=""
  reset
  mkdir -p "$GATE_DIR/scope.20261005T120000Z.md"
  rm -rf "$TMPD/norm"; mkdir -p "$TMPD/norm"
  cat > "$TMPD/norm/rm" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    */scope.*.md/.scope-copy.*) echo "rm: $a: Permission denied" >&2; exit 1 ;;
  esac
done
exec /bin/rm "$@"
EOF
  chmod +x "$TMPD/norm/rm"
  PATH="$TMPD/norm:$FAKEDATE:$PATH" run_wrapper_bounded 6 "$TPR" "$SCOPE"
  [[ $RC -ne 0 && $RC -ne 124 ]];                    sc_check a-link-that-cannot-be-removed-stops-the-round $?
  has "$TMPD/wrapper.out" "could not remove $GATE_DIR/scope.20261005T120000Z.md/.scope-copy."; sc_check says-which-link-and-where $?
  has "$TMPD/wrapper.out" "Permission denied";       sc_check shows-rms-own-error $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check no-step-ran $?
}

# A round killed while its copy is being written must not leave a record that looks whole.
# The `cp` here has written HALF of its destination and then hangs, as a SIGKILL, an OOM
# kill or a power cut would find it; the round and everything it started are killed with
# their process group. Whatever the wrapper called the destination, the final scope.<UTC>.md
# name must not be taken by a half-written file — and the next round, which finds nothing
# at that name, gets it plain (not .2) with the whole scope.
sc_scope_copy_killed_midway() {
  SC_FAILS=""
  reset
  rm -rf "$TMPD/killcp"; mkdir -p "$TMPD/killcp"
  cat > "$TMPD/killcp/cp" <<'EOF'
#!/bin/bash
dst=""; for a in "$@"; do dst="$a"; done
case "$dst" in
  "$GATE_DIR"/*)
    head -c 40 "$1" > "$dst"      # half of the file is down...
    : > "$KILL_DIR/midway"
    exec sleep 600 ;;             # ...and the copy never finishes
esac
exec /bin/cp "$@"
EOF
  chmod +x "$TMPD/killcp/cp"
  local kp n=0
  set -m
  ( PATH="$TMPD/killcp:$FAKEDATE:$PATH" KILL_DIR="$TMPD/killcp" GATE_DIR="$GATE_DIR" VELO_PR_GATE_BIN="$STUB" \
      bash "$RUN_UNDER_TEST" "$TPR" "$SCOPE" > "$TMPD/killed.out" 2>&1 ) & kp=$!
  set +m
  while [[ ! -e "$TMPD/killcp/midway" && $n -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
  [[ -e "$TMPD/killcp/midway" ]];                    sc_check the-copy-was-caught-midway $?
  kill -KILL -- -"$kp" 2>/dev/null
  wait "$kp" 2>/dev/null
  [[ -z "$(scope_copies)" ]];                        sc_check a-killed-round-leaves-no-scope-file-at-all $?
  [[ ! -e "$STUB_DIR/calls.log" ]];                  sc_check no-step-ran $?
  PATH="$FAKEDATE:$PATH" run_wrapper "$TPR" "$SCOPE"
  [[ $RC -eq 0 ]];                                   sc_check the-next-round-runs $?
  [[ "$(scope_copies)" == "scope.20261005T120000Z.md" ]]; sc_check and-takes-the-plain-name-not-a-suffix $?
  cmp -s "$GATE_DIR/scope.20261005T120000Z.md" "$SCOPE"; sc_check and-holds-the-whole-scope $?
}

run_scenarios() {   # "<function>::<what it pins>" ...
  local entry fn what why
  for entry in "$@"; do
    fn="${entry%%::*}"; what="${entry#*::}"
    rm -f "$HARNESS_FAILED"
    "$fn"
    why=$(head -1 "$HARNESS_FAILED" 2>/dev/null)
    if [[ -z "$SC_FAILS" ]]; then ok "$what"; else fail "$what:$SC_FAILS${why:+ [the harness failed: $why]}"; fi
  done
}

echo "velo-gate-run (stub velo-pr-gate)"
run_scenarios \
  "sc_usage::bad invocations are refused before anything runs" \
  "sc_attack_fill::the brief's ATTACK is the scope's ATTACK body, literally, and nothing else moves" \
  "sc_attack_refused_missing::a scope with no ## ATTACK is refused with nothing touched" \
  "sc_attack_refused_empty::a scope with an empty ## ATTACK is refused with nothing touched" \
  "sc_attack_shapes::section boundaries: next heading, fences, depth, decoration, CRLF, end of file" \
  "sc_kept_brief::an already-filled brief is kept, not overwritten from the scope" \
  "sc_extract_last::the verdict is the text after the LAST bare codex line" \
  "sc_extract_fallback::no codex marker: the whole log is written, with a warning" \
  "sc_extract_empty::a marker with nothing after it is refused, not written as an empty report" \
  "sc_verdict_warnings::a final message with no filled Verdict line is flagged" \
  "sc_extract_parity::the extraction agrees with velo-pr-gate's gate_final_codex_message" \
  "sc_wait_for_pid::a still-running Codex is waited for and its FINAL message read" \
  "sc_no_codex_leg::no Codex leg dispatched, or a malformed pid file, is a named failure" \
  "sc_stale_hygiene::last round's review.log, pid and verdict are never read as this round's" \
  "sc_retry_recovers::transient gh failures are retried and the round completes" \
  "sc_retry_gives_up::a persistent transient failure stops after 1 attempt + 3 retries" \
  "sc_no_retry_for_local_failures::local-state failures are not retried" \
  "sc_lock::a live gate lock refuses the run before anything moves; a dead one does not" \
  "sc_lock_unknown_holder::a lock whose holder cannot be identified refuses the run before anything moves" \
  "sc_lock_holder_functions_agree::velo-gate-run and velo-pr-gate read a lock's holder with one and the same function" \
  "sc_none_plan::a plan with no gates ends the round" \
  "sc_plan_title::a gate word in the PR title is not a gate" \
  "sc_args::velo-pr-gate is called as --plan, --brief-only, --exec --wait, with the route passed through" \
  "sc_spec_only::a spec-only plan runs the gates with no brief and no verdict" \
  "sc_empty_range::an empty diff range ends the round without a verdict" \
  "sc_check_code_hint::the Sonnet prompt and the post files are named at the end" \
  "sc_finish_line::the velo-gate-finish line names the reports the plan has: both, either one, or none" \
  "sc_advisory_hint::--check-code-by deepseek|glm is accepted and its report named ADVISORY" \
  "sc_reap_after_codex::a second opinion still running past the grace is killed, children too, once Codex is done" \
  "sc_reap_grace::a second opinion that finishes within the grace is left to finish" \
  "sc_reap_on_failure::a failed round does not leave the second opinion running" \
  "sc_reap_previous_round::last round's second opinion is gone before this round's gates run" \
  "sc_fake_runner_never_up_is_red::a fake second opinion that never starts is a RED scenario with its reason, and no proof can be built on it" \
  "sc_proof_verdicts::a mutation proof is red-then-green; a harness failure is inconclusive, never the mutant caught" \
  "sc_reap_not_a_runner::a pid file naming some other process kills nothing" \
  "sc_scope_copy::the WHOLE scope file is saved as scope.<UTC>.md, not just its ATTACK body" \
  "sc_scope_copy_survives_failure::a round that dies in the plan or at the launch still leaves the scope" \
  "sc_scope_copy_per_round::each round keeps its own copy; a same-second round takes a suffix and overwrites nothing" \
  "sc_scope_copy_loud::a copy that cannot be written stops the round before any step, with cp's error shown" \
  "sc_scope_copy_refusals::a refused invocation (bad scope, live gate) writes no copy" \
  "sc_scope_copy_concurrent::two rounds starting in the same second keep one copy each — the name is taken atomically by the publish" \
  "sc_scope_copy_unwritable::an unwritable gate dir or a refused publish stops the round loudly instead of retrying suffixes for ever" \
  "sc_scope_copy_symlink::a dangling symlink at the name is a collision to step past, not an error and not a write-through" \
  "sc_scope_copy_symlink_to_dir::a symlink to a directory at the name is a collision too, not a file dropped inside the directory" \
  "sc_scope_copy_real_dir::a real directory at the name is a collision too, and nothing is left inside it" \
  "sc_scope_copy_dir_undo_fails::a link that cannot be taken back out of such a directory stops the round loudly" \
  "sc_scope_copy_killed_midway::a round killed mid-copy leaves no half-written scope file under the final name"

# ═════════════════════════════════════════════════════════════════════════════
# Layer 2 — the real velo-pr-gate: --brief-only, the plan, the base branch
# ═════════════════════════════════════════════════════════════════════════════
REPO="$TMPD/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m base
git -C "$REPO" update-ref refs/remotes/origin/master HEAD
git -C "$REPO" checkout -q -b tooling/gaterun
echo change >> "$REPO/f.txt"
git -C "$REPO" commit -q -am change
REPO_REAL=$(git -C "$REPO" rev-parse --show-toplevel)
REPO_HEAD=$(git -C "$REPO" rev-parse --short HEAD)

mkdir -p "$TMPD/bin" "$TMPD/nocodex" "$TMPD/home/.agents/bin" "$TMPD/mut" "$TMPD/patched"
cat > "$TMPD/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *headRefName*) echo "tooling/gaterun";;
  *baseRefName*) [[ -e "$TMPD/no-base" ]] || echo "master";;
  *)             echo "";;
esac
EOF
cp "$TMPD/bin/gh" "$TMPD/nocodex/gh"
# plan.fail makes `--plan` fail the way velo-gate does: its message on stderr in its own die()
# shape, then its exit status. Line 1 is the status, the rest the message (none for a silent
# failure). gate.calls records every call, so a scenario can count the attempts.
cat > "$TMPD/home/.agents/bin/velo-gate" <<EOF
#!/bin/bash
echo "\$*" >> "$TMPD/gate.calls"
case "\$*" in
  *--plan*)
    if [[ -f "$TMPD/plan.fail" ]]; then
      read -r rc < "$TMPD/plan.fail"
      msg=\$(tail -n +2 "$TMPD/plan.fail")
      [[ -n "\$msg" ]] && printf '\n\033[31mERROR:\033[0m %s\n\n' "\$msg" >&2
      exit "\$rc"
    fi
    cat "$TMPD/plan.txt"; exit 0;;
  *--running*) echo set > "$TMPD/running.flag"; exit 0;;
esac
exit 0
EOF
cat > "$TMPD/bin/claude" <<EOF
#!/bin/bash
echo invoked >> "$TMPD/claude.called"
exit 1
EOF
# The e2e reviewer: alive past the liveness window (VELO_GATE_HEALTH_SECS=1), then a multi-turn transcript.
cat > "$TMPD/bin/codex" <<EOF
#!/bin/bash
echo invoked >> "$TMPD/codex.called"
cat >/dev/null
sleep 2
cat "$TMPD/e2e.transcript"
EOF
export STUB_WRAPPER="$TMPD/bin/velo-openrouter-agent-stub"
cat > "$STUB_WRAPPER" <<EOF
#!/bin/bash
echo invoked >> "$TMPD/wrapper.called"
exit 0
EOF
chmod +x "$TMPD/bin/gh" "$TMPD/nocodex/gh" "$TMPD/home/.agents/bin/velo-gate" "$TMPD/bin/claude" "$TMPD/bin/codex" "$STUB_WRAPPER"

HEALTHY_PATH="$TMPD/bin:$PATH"
FAST_PATH="$TMPD/nocodex:/usr/bin:/bin"
plan_all()  { printf '#1 t\n  gates needed:\n    - code-review  (independent reviewer)\n    - check-code   (src/ touched: 1 files)\n    - check-spec   (#1 has 4 acceptance bars)\n' > "$TMPD/plan.txt"; }
plan_spec() { printf '#1 t\n  gates needed:\n    - check-spec   (#1 has 4 acceptance bars)\n' > "$TMPD/plan.txt"; }
plan_core() { printf '#1 t\n  gates needed:\n    - code-review  (independent reviewer)\n    - check-code   (src/ touched: 1 files)\n' > "$TMPD/plan.txt"; }

# A copy of velo-pr-gate whose worker wrapper is a recording stub: the real path is
# hard-coded to a user's home, and a mutation that dispatches check-spec must not be
# able to start a real local-model run.
make_prgate() {   # <dst> [anchor replacement]
  python3 - "$PRGATE_REAL" "$1" "${2:-}" "${3:-}" <<'PY'
import re, sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
t, n = re.subn(r'(?m)^WRAPPER=.*$', 'WRAPPER="$STUB_WRAPPER"', t)
assert n == 1, f"expected exactly one WRAPPER= line, found {n}"
if old:
    assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
    t = t.replace(old, new, 1)
open(dst, "w").write(t)
PY
  cp "$BIN/velo-local.conf" "$(dirname "$1")/velo-local.conf"
}

PRGATE_UNDER_TEST=""   # set by the scenarios' callers: a patched (and maybe mutated) copy
run_prgate() {   # <PATH> args... -> $OUT $RC   (cwd = the hermetic repo)
  local p="$1"; shift
  rm -f "$TMPD/running.flag" "$TMPD/claude.called" "$TMPD/codex.called" "$TMPD/wrapper.called"
  OUT=$(cd "$REPO" && HOME="$TMPD/home" PATH="$p" bash "$PRGATE_UNDER_TEST" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/prgate.out"
}

sc_brief_only() {
  SC_FAILS=""
  plan_all; rm -rf "$GATE_DIR"; write_default_scope "$SCOPE"
  run_prgate "$HEALTHY_PATH" "$TPR" "$SCOPE" --brief-only
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$TMPD/prgate.out" "nothing dispatched";     sc_check says-so $?
  has "$GATE_DIR/review-brief.md" "<<< FILL THIS IN"; sc_check brief-generated-with-the-placeholder $?
  ! has "$TMPD/prgate.out" "unfilled ## ATTACK";   sc_check does-not-refuse-the-placeholder $?
  [[ ! -e "$GATE_DIR/spec.log.pid" ]];               sc_check check-spec-not-dispatched $?
  [[ ! -e "$TMPD/codex.called" ]];                 sc_check codex-not-dispatched $?
  [[ ! -e "$TMPD/claude.called" ]];                sc_check check-code-not-dispatched $?
  [[ ! -e "$TMPD/running.flag" ]];                 sc_check gate-not-marked-running $?
  [[ ! -e "$GATE_DIR/review.log.pid" && ! -e "$GATE_DIR/code.log.pid" ]]; sc_check no-reviewer-pid-files $?
  [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" ]]; sc_check no-check-code-prompt $?
}

sc_brief_only_no_review() {
  SC_FAILS=""
  plan_spec; rm -rf "$GATE_DIR"; write_default_scope "$SCOPE"
  run_prgate "$HEALTHY_PATH" "$TPR" "$SCOPE" --brief-only
  [[ $RC -eq 0 ]];                                 sc_check exits-0 $?
  has "$TMPD/prgate.out" "no code-review gate planned"; sc_check says-so $?
  [[ ! -e "$GATE_DIR/spec.log.pid" ]];               sc_check check-spec-not-dispatched $?
  [[ ! -e "$GATE_DIR/review-brief.md" ]];          sc_check no-brief $?
}

sc_base_guard() {
  SC_FAILS=""
  plan_core; rm -rf "$GATE_DIR"; write_default_scope "$SCOPE"
  : > "$TMPD/no-base"
  run_prgate "$HEALTHY_PATH" "$TPR" "$SCOPE" --brief-only
  rm -f "$TMPD/no-base"
  [[ $RC -ne 0 ]];                                 sc_check fails-loudly $?
  has "$TMPD/prgate.out" "could not read base branch for #$TPR"; sc_check says-why-in-the-retryable-shape $?
  ! has "$TMPD/prgate.out" "is EMPTY";             sc_check not-a-fake-empty-range $?
  [[ ! -e "$GATE_DIR/review-brief.md" ]];          sc_check no-brief $?
}

# A PR whose TITLE names a gate is not a PR that needs it.
sc_title_is_not_a_gate() {
  SC_FAILS=""
  printf '#1 gate: check-code and code-review and check-spec\n  gates needed:\n    - code-review  (independent reviewer)\n' > "$TMPD/plan.txt"
  rm -rf "$GATE_DIR"; write_default_scope "$SCOPE"
  # prime, fill, then the real dispatch on a no-codex PATH (nothing launches)
  run_prgate "$FAST_PATH" "$TPR" "$SCOPE" --brief-only
  python3 - "$GATE_DIR/review-brief.md" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8")
p.write_text(re.sub(r'(<<< [^\n]*>>>\n?)+', lambda m: "attack text\n", t), encoding="utf-8")
PY
  run_prgate "$FAST_PATH" "$TPR" "$SCOPE"
  [[ ! -e "$GATE_DIR/check-code-agent-prompt.md" ]]; sc_check no-check-code-prompt-for-a-title $?
  [[ ! -e "$GATE_DIR/check-code.by" ]];            sc_check no-check-code-route-for-a-title $?
  ! has "$TMPD/prgate.out" "LAUNCH a read-only Sonnet agent"; sc_check no-launch-line $?
  [[ ! -e "$GATE_DIR/spec.log.pid" ]];               sc_check no-check-spec-for-a-title $?
}

# A failure of `velo-gate --plan` carries velo-gate's own reason, and it must reach the caller.
# velo-pr-gate threw it away (2>/dev/null) and called EVERY failure "PR #N not found" — an
# unreadable linked issue, a payload that is not a PR and a dead token alike — and velo-gate-run,
# which retries that text as a dropped connection, ran the plan three more times and gave up with
# the same lie. plan.fail drives the stub velo-gate above: line 1 its exit status, the rest its message.
plan_fails() {   # <exit status> [message]   (no message = a silent failure)
  printf '%s\n%s\n' "$1" "${2:-}" > "$TMPD/plan.fail"
}
ISSUE_UNREADABLE="could not read issue #7, which #$TPR closes, to count its acceptance bars: HTTP 502: Bad Gateway
  Refusing to print a gate plan that may be missing check-spec."

sc_plan_failure_reason_is_shown() {
  SC_FAILS=""
  plan_core; rm -rf "$GATE_DIR"
  plan_fails 1 "$ISSUE_UNREADABLE"
  run_prgate "$HEALTHY_PATH" "$TPR" --plan
  rm -f "$TMPD/plan.fail"
  [[ $RC -ne 0 ]];                                                 sc_check fails $?
  has "$TMPD/prgate.out" "could not read issue #7, which #$TPR closes"; sc_check shows-velo-gates-own-reason $?
  has "$TMPD/prgate.out" "HTTP 502: Bad Gateway";                  sc_check shows-ghs-own-words $?
  ! has "$TMPD/prgate.out" "PR #$TPR not found";                   sc_check does-not-call-it-a-missing-pr $?
  [[ ! -e "$TMPD/running.flag" ]];                                 sc_check marks-nothing-running $?
}

sc_plan_failure_without_a_message() {
  SC_FAILS=""
  plan_core; rm -rf "$GATE_DIR"
  plan_fails 3
  run_prgate "$HEALTHY_PATH" "$TPR" --plan
  rm -f "$TMPD/plan.fail"
  [[ $RC -ne 0 ]];                                                 sc_check fails $?
  has "$TMPD/prgate.out" "exit 3";                                 sc_check names-the-exit-status $?
  ! has "$TMPD/prgate.out" "not found";                            sc_check does-not-call-it-a-missing-pr $?
}

# The control: when velo-gate itself says the PR is not found, that is what the caller reads.
sc_plan_not_found_is_velo_gates_word() {
  SC_FAILS=""
  plan_core; rm -rf "$GATE_DIR"
  plan_fails 1 "PR #$TPR not found"
  run_prgate "$HEALTHY_PATH" "$TPR" --plan
  rm -f "$TMPD/plan.fail"
  [[ $RC -ne 0 ]];                                                 sc_check fails $?
  has "$TMPD/prgate.out" "PR #$TPR not found";                     sc_check relays-velo-gates-own-words $?
}

# The whole chain: the real wrapper over the real velo-pr-gate over a velo-gate that cannot read a
# linked issue. One attempt (nothing here is a dropped connection), and the round says why.
sc_plan_failure_chain() {
  SC_FAILS=""
  plan_core; rm -rf "$GATE_DIR"; write_default_scope "$SCOPE"; : > "$TMPD/gate.calls"
  plan_fails 1 "$ISSUE_UNREADABLE"
  chmod +x "$PRGATE_UNDER_TEST"          # the wrapper runs VELO_PR_GATE_BIN directly; the other scenarios use bash
  OUT=$(cd "$REPO" && HOME="$TMPD/home" PATH="$HEALTHY_PATH" VELO_PR_GATE_BIN="$PRGATE_UNDER_TEST" \
          bash "$RUN_REAL" "$TPR" "$SCOPE" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/chain.out"
  rm -f "$TMPD/plan.fail"
  [[ $RC -ne 0 ]];                                                 sc_check fails $?
  has "$TMPD/chain.out" "could not read issue #7, which #$TPR closes"; sc_check the-round-says-why $?
  ! has "$TMPD/chain.out" "PR #$TPR not found";                    sc_check never-says-the-pr-is-missing $?
  [[ "$(grep -c -- '--plan' "$TMPD/gate.calls")" == "1" ]];        sc_check planned-once-not-retried $?
  ! has "$TMPD/chain.out" "transient gh failure";                  sc_check not-announced-as-transient $?
}

echo
echo "velo-pr-gate: --brief-only, the plan, the base branch"
make_prgate "$TMPD/patched/velo-pr-gate"
PRGATE_UNDER_TEST="$TMPD/patched/velo-pr-gate"
run_scenarios \
  "sc_brief_only::--brief-only generates the brief and dispatches nothing, check-spec included" \
  "sc_brief_only_no_review::--brief-only with no code-review planned stops cleanly" \
  "sc_base_guard::an unreadable base branch dies loudly instead of reporting an empty range" \
  "sc_title_is_not_a_gate::a gate word in the PR title does not create a gate" \
  "sc_plan_failure_reason_is_shown::a plan that cannot be made shows velo-gate's reason, never 'PR not found'" \
  "sc_plan_failure_without_a_message::a plan that fails silently names its exit status, not a missing PR" \
  "sc_plan_not_found_is_velo_gates_word::a PR velo-gate says is not found is reported as velo-gate said it" \
  "sc_plan_failure_chain::wrapper over velo-pr-gate over a failing plan: the reason reaches the round and nothing is retried"

# ═════════════════════════════════════════════════════════════════════════════
# Layer 3 — the real wrapper over the real velo-pr-gate
# ═════════════════════════════════════════════════════════════════════════════
echo
echo "velo-gate-run end to end (real velo-pr-gate, stub codex; ~15s)"
plan_core; rm -rf "$GATE_DIR"
cat > "$TMPD/e2e.scope.md" <<'EOF'
# Scope — end to end

## What it does

Changes f.txt.

## ATTACK

E2E-ATTACK-TOKEN: is f.txt still valid after the change?

## Do not report

- style
EOF
{
  echo "OpenAI Codex v0.0-stub"; echo "user"; echo "the brief"
  echo "codex"; echo "first turn"; echo "codex"; echo "second turn"; echo "codex"
  echo "## Codex review — PR $TPR @ $REPO_HEAD"; echo "**Verdict:** approve"; echo; echo "### Findings"; echo "none"
} > "$TMPD/e2e.transcript"
rm -f "$TMPD/claude.called" "$TMPD/codex.called" "$TMPD/wrapper.called" "$TMPD/running.flag"
E2E_OUT=$(cd "$REPO" && HOME="$TMPD/home" PATH="$HEALTHY_PATH" bash "$RUN_REAL" "$TPR" "$TMPD/e2e.scope.md" 2>&1); E2E_RC=$?
printf '%s\n' "$E2E_OUT" > "$TMPD/e2e.out"
if [[ $E2E_RC -eq 0 ]]; then ok "exits 0"; else fail "the round failed (rc=$E2E_RC): $(tail -5 "$TMPD/e2e.out")"; fi
V="$GATE_DIR/codex-verdict.md"
if [[ -f "$V" ]] && [[ "$(head -1 "$V")" == "## Codex review — PR $TPR @ $REPO_HEAD" ]] \
   && has "$V" "**Verdict:** approve" && ! has "$V" "second turn"; then
  ok "codex-verdict.md is Codex's final message, not an earlier turn"
else
  fail "codex-verdict.md is wrong or missing: $(cat "$V" 2>/dev/null | head -5)"
fi
if has "$GATE_DIR/review-brief.md" "E2E-ATTACK-TOKEN" && ! has "$GATE_DIR/review-brief.md" "<<< FILL THIS IN"; then
  ok "the brief Codex reviewed carries the scope's ATTACK"
else
  fail "the real brief was not filled from the scope"
fi
if has "$GATE_DIR/check-code-agent-prompt.md" "E2E-ATTACK-TOKEN"; then
  ok "the Sonnet check-code prompt carries the same ATTACK"
else
  fail "the ATTACK did not reach the check-code prompt: $(ls "$GATE_DIR")"
fi
if [[ "$(grep -c 'LAUNCH a read-only Sonnet agent' "$TMPD/e2e.out")" == "1" ]]; then
  ok "the one check-code launch line is in the wrapper's output"
else
  fail "expected exactly one LAUNCH line in the wrapper output"
fi
if [[ ! -e "$TMPD/claude.called" ]]; then ok "no opus check-code leg was launched"; else fail "the claude CLI was launched"; fi
if [[ -f "$TMPD/running.flag" ]]; then ok "gate:running was set"; else fail "gate:running was not set"; fi
if has "$TMPD/e2e.out" "velo-gate-finish $TPR $REPO_HEAD"; then
  ok "the next step names the sha the gates ran against"
else
  fail "no velo-gate-finish line with the gated sha: $(tail -6 "$TMPD/e2e.out")"
fi
E2E_SCOPE_COPY=$(ls -1 "$GATE_DIR" 2>/dev/null | grep -E '^scope\.[0-9]{8}T[0-9]{6}Z\.md$' || true)
if [[ -n "$E2E_SCOPE_COPY" && "$(printf '%s\n' "$E2E_SCOPE_COPY" | wc -l | tr -d ' ')" == "1" ]] \
   && cmp -s "$GATE_DIR/$E2E_SCOPE_COPY" "$TMPD/e2e.scope.md"; then
  ok "the round saved the whole scope as scope.<UTC>.md, and the real velo-pr-gate left it alone"
else
  fail "expected exactly one scope.<UTC>.md identical to the scope file, found: $(ls "$GATE_DIR")"
fi

# ═════════════════════════════════════════════════════════════════════════════
# MUTATION-PROOF — each behaviour goes red when it is removed
# ═════════════════════════════════════════════════════════════════════════════
echo
echo "mutation proofs"
mutate_run() {   # <anchor> <replacement> [<anchor> <replacement>]... -> $TMPD/mut/velo-gate-run
  python3 - "$RUN_REAL" "$TMPD/mut/velo-gate-run" "$@" <<'PY'
import sys
src, dst, *pairs = sys.argv[1:]
assert len(pairs) % 2 == 0, "mutation anchors come as (anchor, replacement) pairs"
t = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
    t = t.replace(old, new, 1)
open(dst, "w").write(t)
PY
}
prove_run() {   # <label> <scenario> <anchor> <replacement> [<anchor> <replacement>]...
  local label="$1" fn="$2" red; shift 2
  if ! mutate_run "$@"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  rm -f "$HARNESS_FAILED"
  RUN_UNDER_TEST="$TMPD/mut/velo-gate-run"
  "$fn"; red="$SC_FAILS"
  RUN_UNDER_TEST="$RUN_REAL"
  "$fn"
  report_proof "$label" "$fn" "$red" "$SC_FAILS" "$(head -1 "$HARNESS_FAILED" 2>/dev/null)"
}
prove_prgate() {   # <label> <scenario> <anchor> <replacement>
  local label="$1" fn="$2" old="$3" new="$4" red
  if ! make_prgate "$TMPD/mut/velo-pr-gate" "$old" "$new"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  rm -f "$HARNESS_FAILED"
  PRGATE_UNDER_TEST="$TMPD/mut/velo-pr-gate"
  "$fn"; red="$SC_FAILS"
  PRGATE_UNDER_TEST="$TMPD/patched/velo-pr-gate"
  "$fn"
  report_proof "$label" "$fn" "$red" "$SC_FAILS" "$(head -1 "$HARNESS_FAILED" 2>/dev/null)"
}

# The case prove_run's verdict exists for, end to end: the fake second opinion is slow in the
# MUTANT's run (never up, within the bound) and on time in the real script's run. Without the
# harness rule that reads "ok ... red with the behaviour removed" for a mutant that was never
# exercised. ok/fail are shadowed inside the subshell so the verdict can be read, not counted.
sc_reap_after_codex_slow_once() {   # the first call (the mutant's) has no fake that comes up; later ones do
  if [[ ! -e "$TMPD/slow-once.done" ]]; then
    : > "$TMPD/slow-once.done"
    STUB_RUNNER_NEVER_UP=1 FAKE_RUNNER_POLLS=4 sc_reap_after_codex
  else
    sc_reap_after_codex
  fi
}
sc_proof_inconclusive_end_to_end() {
  local msg
  SC_FAILS=""
  rm -f "$TMPD/slow-once.done"
  msg=$(ok() { echo "ok:$1"; }; fail() { echo "FAIL:$1"; }
        prove_run "reaped once Codex is done" sc_reap_after_codex_slow_once \
          'kill -0 "$pid" 2>/dev/null || { ok "second opinion finished on its own"; return 0; }' 'return 0')
  rm -f "$TMPD/slow-once.done"
  [[ "$msg" == FAIL:*INCONCLUSIVE* ]];               sc_check the-proof-is-reported-inconclusive-as-a-failure $?
  [[ "$msg" != *"red with the behaviour removed"* ]]; sc_check and-never-says-the-mutant-was-caught $?
}
run_scenarios \
  "sc_proof_inconclusive_end_to_end::a mutation proof whose mutant run met a fake that never came up is INCONCLUSIVE, not the mutant caught"

prove_run "ATTACK fill" sc_attack_fill \
  'tail, n = re.subn(r"(<<< [^\n]*>>>\n?)+", lambda m: body, tail, count=1)' 'n = 1'
prove_run "refuse a scope with no ATTACK" sc_attack_refused_missing \
  '  3) die "the scope file has no' '  3) : "the scope file has no'
prove_run "refuse an empty ATTACK" sc_attack_refused_empty \
  'if not text.strip():
    sys.exit(4)' 'if False:
    sys.exit(4)'
prove_run "section ends at the next heading" sc_attack_shapes \
  'if len(h.group(1)) <= depth:' 'if False:'
prove_run "fences are skipped when looking for headings" sc_attack_shapes \
  '    if fence is not None:' '    if False:'
prove_run "a shorter fence line does not close a longer fence" sc_attack_shapes \
  'and len(m.group(1)) >= fence[1] ' ''
prove_run "a fence line with an info string cannot close one" sc_attack_shapes \
  ' and not m.group(2).strip(" \t\r"):' ':'
prove_run "a closer may be followed only by spaces, tabs and a CR (not a non-breaking space, form feed or vertical tab)" sc_attack_shapes \
  'not m.group(2).strip(" \t\r"):' 'not m.group(2).strip():'
prove_run "a different fence character does not close a fence" sc_attack_shapes \
  'if m and m.group(1)[0] == fence[0] and' 'if m and'
prove_run "an inline backtick span is not an opener" sc_attack_shapes \
  'if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):' 'if m:'
prove_run "an existing filled brief is kept" sc_kept_brief \
  'if has_text "$BRIEF" "<<< FILL THIS IN"; then
    printf' 'if true; then
    printf'
prove_run "verdict = after the LAST marker" sc_extract_last \
  "LAST_MARKER=\$(grep -n '^codex\$' \"\$LOG\" | tail -1 | cut -d: -f1)" "LAST_MARKER=\$(grep -n '^codex\$' \"\$LOG\" | head -1 | cut -d: -f1)"
prove_run "no-marker fallback" sc_extract_fallback \
  '  cp "$LOG" "$VERDICT" || die "could not write $VERDICT"' '  : > "$VERDICT"'
prove_run "empty final message refused" sc_extract_empty \
  'if [[ ! -s "$VERDICT" ]]; then' 'if false; then'
prove_run "verdict-line warning" sc_verdict_warnings \
  'if [[ -z "$VERDICT_LINE" ]] || grep -qF' 'if false && grep -qF'
prove_run "wait for the Codex pid" sc_wait_for_pid \
  'while kill -0 "$CODEX_PID" 2>/dev/null; do
    sleep "$POLL"
  done' 'true'
prove_run "name the missing Codex leg" sc_no_codex_leg \
  'dispatched no Codex review for #$PR' 'died for #$PR'
prove_run "stale review.log is moved aside" sc_stale_hygiene \
  '  [[ -e "$GATE_DIR/$f" ]] && mv -f "$GATE_DIR/$f" "$GATE_DIR/$f.prev"' '  :'
prove_run "stale pid file removed" sc_stale_hygiene \
  'rm -f "$GATE_DIR/review.log.pid"' ':'
prove_run "retry up to 3 times" sc_retry_recovers \
  'MAX_RETRIES=3' 'MAX_RETRIES=0'
prove_run "only 3 retries" sc_retry_gives_up \
  'MAX_RETRIES=3' 'MAX_RETRIES=9'
prove_run "only transient failures are retried" sc_no_retry_for_local_failures \
  '  grep -qE "PR #$PR not found|could not read (head|base) branch for #$PR" "$1"' '  grep -q . "$1"'
prove_run "refuse while a gate runs" sc_lock \
  '  if kill -0 "$HOLDER" 2>/dev/null; then' '  if false; then'
prove_run "a lock whose holder cannot be identified refuses the run" sc_lock_unknown_holder \
  '  if ! read_lock_holder "$LOCK"; then' '  if false; then'
prove_run "the two lock-holder readers cannot drift apart" sc_lock_holder_functions_agree \
  '    sleep "${VELO_GATE_LOCK_POLL:-0.2}"' '    sleep 1'
prove_run "stop when no gates are required" sc_none_plan \
  "if grep -q 'none —' <<<\"\$PLAN_GATES\"; then" 'if false; then'
prove_run "the title line is not a gate" sc_plan_title \
  "PLAN_GATES=\$(grep -v '^#' \"\$PLAN_FILE\")" "PLAN_GATES=\$(cat \"\$PLAN_FILE\")"
prove_run "route passed to every step" sc_args \
  'PASS+=(--check-code-by "$2"); shift 2 ;;' 'shift 2 ;;'
prove_run "prime with --brief-only" sc_args \
  'run_gate_step brief "$SCOPE" --brief-only' 'run_gate_step brief "$SCOPE"'
prove_run "run with --exec --wait" sc_args \
  'run_gate_step run "$SCOPE" --exec --wait' 'run_gate_step run "$SCOPE" --wait'
prove_run "no brief for a spec-only plan" sc_spec_only \
  'if [[ $NEEDS_REVIEW -eq 1 ]]; then
  echo
  echo "── 2/5 brief ──"' 'if true; then
  echo
  echo "── 2/5 brief ──"'
prove_run "empty range stops the round" sc_empty_range \
  '  if has_text "$GATE_DIR/gate-run.brief.out" "is EMPTY"; then' '  if false; then'
prove_run "the check-code launch hint" sc_check_code_hint \
  '  if [[ -f "$CODE_PROMPT" ]]; then' '  if false; then'
prove_run "finish line: both reports positional" sc_finish_line \
  '  if [[ $have_cc -eq 1 && $have_cr -eq 1 ]]; then' '  if false; then'
prove_run "finish line: code-review only" sc_finish_line \
  '  elif [[ $have_cr -eq 1 ]]; then' '  elif false; then'
prove_run "finish line: check-code only" sc_finish_line \
  '  elif [[ $have_cc -eq 1 ]]; then' '  elif false; then'
prove_run "finish line: no report at all" sc_finish_line \
  'no check-code or code-review report to post for this plan' 'a finish line for this plan'
prove_run "advisory routes accepted" sc_advisory_hint \
  '    sonnet|opus|deepseek|glm) ;;' '    sonnet|opus) ;;'
prove_run "advisory report named" sc_advisory_hint \
  '      deepseek|glm)
        echo "  check-code  the $by' '      never)
        echo "  check-code  the $by'
prove_run "reaped once Codex is done" sc_reap_after_codex \
  'kill -0 "$pid" 2>/dev/null || { ok "second opinion finished on its own"; return 0; }' 'return 0'
prove_run "children reaped too" sc_reap_after_codex \
  'pkill -TERM -P "$pid" 2>/dev/null' ':'
prove_run "the grace is honoured" sc_reap_grace \
  'reap_second_opinion "$SECOND_GRACE"' 'reap_second_opinion 0'
prove_run "reaped on any exit" sc_reap_on_failure \
  "trap 'reap_second_opinion 0' EXIT" ':'
prove_run "previous round reaped first" sc_reap_previous_round \
  'reap_second_opinion 0
# From here on' '# From here on'
prove_run "only a runner is killed" sc_reap_not_a_runner \
  '    *velo-openai-agents-runner*|*velo-openrouter-agent*) ;;' '    *) ;;'

# The scope copy (#2379, #2380). The copy is written to a temp file and published under its
# final name by a hard link; the anchors below are the pieces of that block.
SCOPE_BLOCK_OPEN='SCOPE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)'
SCOPE_BLOCK_CLOSE='echo "scope file saved: $SCOPE_COPY"'
WRITE_TMP='cp "$SCOPE" "$SCOPE_TMP" \'
PUBLISH='if SCOPE_ERR=$(ln "$SCOPE_TMP" "$SCOPE_COPY" 2>&1); then'
IS_THE_TEMP='[[ "$SCOPE_COPY" -ef "$SCOPE_TMP" ]] && break'
UNDO='rm -f -- "$SCOPE_COPY/${SCOPE_TMP##*/}" \'
NOT_A_COLLISION='elif [[ ! -e "$SCOPE_COPY" && ! -L "$SCOPE_COPY" ]]; then'
# The whole block as a function that is never called (the copy is not made), or called
# only after the plan step (the copy is made too late to survive a plan failure).
PLAN_STEP='run_gate_step plan --plan ${PASS[@]+"${PASS[@]}"} || die "velo-pr-gate --plan failed (exit $STEP_RC)"'
prove_run "the scope is copied" sc_scope_copy \
  "$SCOPE_BLOCK_OPEN" 'scope_copy_never() {
SCOPE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)' \
  "$SCOPE_BLOCK_CLOSE" 'echo "scope file saved: $SCOPE_COPY"
}'
prove_run "the copy is the whole scope, not the ATTACK body" sc_scope_copy \
  "$WRITE_TMP" 'printf '"'%s\n'"' "$ATTACK_BODY" > "$SCOPE_TMP" \'
prove_run "the copy is made before the plan step" sc_scope_copy_survives_failure \
  "$SCOPE_BLOCK_OPEN" 'scope_copy_late() {
SCOPE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)' \
  "$SCOPE_BLOCK_CLOSE" 'echo "scope file saved: $SCOPE_COPY"
}' \
  "$PLAN_STEP" "$PLAN_STEP
scope_copy_late"
prove_run "with no copy a failed round leaves nothing to re-run from" sc_scope_copy_survives_failure \
  "$SCOPE_BLOCK_OPEN" 'scope_copy_never() {
SCOPE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)' \
  "$SCOPE_BLOCK_CLOSE" 'echo "scope file saved: $SCOPE_COPY"
}'
prove_run "a round never overwrites an earlier copy" sc_scope_copy_per_round \
  "$PUBLISH" 'if SCOPE_ERR=$(ln -f "$SCOPE_TMP" "$SCOPE_COPY" 2>&1); then'
prove_run "two rounds in one second each keep their own copy (the name is taken atomically)" sc_scope_copy_concurrent \
  "$PUBLISH" 'if [[ ! -e "$SCOPE_COPY" ]] && SCOPE_ERR=$(ln -f "$SCOPE_TMP" "$SCOPE_COPY" 2>&1); then'
prove_run "a publish that takes no name stops the round (it is not a collision)" sc_scope_copy_unwritable \
  "$NOT_A_COLLISION" 'elif false; then'
prove_run "a dangling symlink at the name is a collision" sc_scope_copy_symlink \
  "$NOT_A_COLLISION" 'elif [[ ! -e "$SCOPE_COPY" ]]; then'
prove_run "a publish counts only if the name IS the temp file (symlink to a directory)" sc_scope_copy_symlink_to_dir \
  "$IS_THE_TEMP" 'break'
prove_run "a publish counts only if the name IS the temp file (real directory)" sc_scope_copy_real_dir \
  "$IS_THE_TEMP" 'break'
prove_run "the link made inside a directory is taken back out (symlink to a directory)" sc_scope_copy_symlink_to_dir \
  "$UNDO" ':  \'
prove_run "the link made inside a directory is taken back out (real directory)" sc_scope_copy_real_dir \
  "$UNDO" ':  \'
prove_run "a link that cannot be taken back out stops the round" sc_scope_copy_dir_undo_fails \
  '      || die "could not remove $SCOPE_COPY/${SCOPE_TMP##*/}: a link this round made INSIDE a' '      || : "could not remove $SCOPE_COPY/${SCOPE_TMP##*/}: a link this round made INSIDE a'
prove_run "a round killed mid-copy leaves no half-written scope file (write straight to the final name)" sc_scope_copy_killed_midway \
  "$WRITE_TMP" 'cp "$SCOPE" "$GATE_DIR/scope.$SCOPE_STAMP.md" \'
prove_run "the temp file is removed once published" sc_scope_copy \
  'rm -f "$SCOPE_TMP"
echo "scope file saved: $SCOPE_COPY"' 'echo "scope file saved: $SCOPE_COPY"'
prove_run "a failed temp copy leaves no temp file" sc_scope_copy_loud \
  '{ rm -f "$SCOPE_TMP"; die "could not save a copy of the scope file' '{ die "could not save a copy of the scope file'
prove_run "a failed temp copy is reported as that, with cp's error and the temp's path, not as a later publish failure" sc_scope_copy_loud \
  'die "could not save a copy of the scope file: cp to' ': "could not save a copy of the scope file: cp to'
prove_run "no copy into a running gate's dir" sc_scope_copy_refusals \
  'if [[ -d "$LOCK" ]]; then' 'mkdir -p "$GATE_DIR"; cp "$SCOPE" "$GATE_DIR/scope.early.md"; if [[ -d "$LOCK" ]]; then'
prove_run "no copy for a refused scope" sc_scope_copy_refusals \
  'ATTACK_BODY=$(extract_attack "$SCOPE")' 'mkdir -p "$VELO_STATE/gate/$PR"; cp "$SCOPE" "$VELO_STATE/gate/$PR/scope.early.md"; ATTACK_BODY=$(extract_attack "$SCOPE")'

prove_prgate "--brief-only skips check-spec" sc_brief_only \
  'if [[ $BRIEF_ONLY -eq 0 && $NEEDS_SPEC -eq 1 ]]; then' 'if [[ $NEEDS_SPEC -eq 1 ]]; then'
prove_prgate "--brief-only stops after the brief" sc_brief_only \
  '  if [[ $BRIEF_ONLY -eq 1 ]]; then
    ok "--brief-only: brief ready at' '  if false; then
    ok "--brief-only: brief ready at'
prove_prgate "--brief-only with no code-review planned" sc_brief_only_no_review \
  'if [[ $BRIEF_ONLY -eq 1 ]]; then
  ok "--brief-only: no code-review gate planned' 'if false; then
  ok "--brief-only: no code-review gate planned'
prove_prgate "base-branch guard" sc_base_guard \
  '[[ -n "$BASE" ]] || die "could not read base branch for #$PR"' ':'
prove_prgate "plan title excluded" sc_title_is_not_a_gate \
  "PLAN_GATES=\$(grep -v '^#' <<<\"\$PLAN\")" "PLAN_GATES=\$PLAN"
# The mask restored: velo-gate's stderr discarded and every failure called a missing PR.
PLAN_READ_NEW='PLAN=$(~/.agents/bin/velo-gate "$PR" --plan) \
  || die "could not plan the gates for #$PR: velo-gate $PR --plan failed (exit $?); whatever it said is above"'
PLAN_READ_MASKED='PLAN=$(~/.agents/bin/velo-gate "$PR" --plan 2>/dev/null) || die "PR #$PR not found"'
prove_prgate "velo-gate's reason is shown, not 'PR not found'" sc_plan_failure_reason_is_shown \
  "$PLAN_READ_NEW" "$PLAN_READ_MASKED"
prove_prgate "a silent plan failure names its exit status, not a missing PR" sc_plan_failure_without_a_message \
  "$PLAN_READ_NEW" "$PLAN_READ_MASKED"
prove_prgate "the round reports the real reason and does not retry a plan failure as a dropped connection" sc_plan_failure_chain \
  "$PLAN_READ_NEW" "$PLAN_READ_MASKED"
prove_prgate "the failing exit status is named" sc_plan_failure_without_a_message \
  'velo-gate $PR --plan failed (exit $?)' 'velo-gate $PR --plan failed'

echo
[[ $FAILED -eq 0 ]] && echo "all velo-gate-run checks passed" || echo "FAILURES"
exit $FAILED

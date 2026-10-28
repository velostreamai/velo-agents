#!/bin/bash
# The gate routing table must be ONE definition, not three.
#
# It had drifted three ways at once: CLAUDE.md said `check-code -> velo-local`,
# velo-pr-gate's own header said Codex, its dispatch ran Codex, and the intended
# routing was opus at high effort. Nothing compared them, so all three could be
# confidently wrong at the same time.
#
# The script is what actually dispatches, so it is the definition. CLAUDE.md and
# the script's header are documentation OF it, and this suite fails when they
# disagree with what the dispatch line does.
# Test-mode timeouts (health window, polls, grace, retries): see test-timeouts.sh.
. "$(dirname "${BASH_SOURCE[0]}")/test-timeouts.sh"

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
ROOT="$(cd "$HERE/.." && pwd)"
# CLAUDE.md is the Velostream repo's, which tells orchestrator sessions how to gate.
VELOREPO="${VELO_BENCH_REPO:-$HOME/RustroverProjects/velostream}"
GATE="$BIN/velo-pr-gate"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "gate routing (one definition, three readers)"

# ── what the DISPATCH actually does — the definition ───────────────────────
CODE_DISPATCH=$(grep -n 'claude -p --model' "$GATE" | head -1)
if [[ -n "$CODE_DISPATCH" ]]; then
  ok "check-code dispatches via the claude CLI"
else
  fail "no 'claude -p --model' dispatch found — check-code routing changed"
fi

# The flags that make this route what it is, each asserted for a reason.
for FLAG in '--model opus' '--effort high'; do
  if grep -q -- "$FLAG" <<<"$CODE_DISPATCH"; then
    ok "check-code dispatch carries $FLAG"
  else
    fail "check-code dispatch is missing $FLAG"
  fi
done

# Read-only BY CONSTRUCTION. A brief saying "do not write" is an instruction;
# removing the tools is a guarantee. velo-glm committed on 2 of its 3 read-only
# dispatches (#1987, #1994), which is why this is structural.
if grep -q "disallowed-tools 'Edit Write NotebookEdit'" <<<"$CODE_DISPATCH"; then
  ok "check-code cannot write — Edit/Write/NotebookEdit removed"
else
  fail "check-code could modify the worktree it is reviewing"
fi
# nohup has no tty, so an interactive permission prompt would hang the gate.
if grep -q -- '--permission-mode dontAsk' <<<"$CODE_DISPATCH"; then
  ok "check-code will not block on a permission prompt under nohup"
else
  fail "no --permission-mode: the gate can hang waiting for a tty that is not there"
fi

# ── the two READERS must agree with it ─────────────────────────────────────
# The script's own header table.
if sed -n '/^#   check-code/,/^#   check-spec/p' "$GATE" | grep -q 'opus:high'; then
  ok "velo-pr-gate's header table says opus:high"
else
  fail "the header table disagrees with the dispatch it documents"
fi

# The --plan output, which is what a human reads before running the gate.
if grep -q 'check-code   -> opus:high' "$GATE"; then
  ok "--plan output says opus:high"
else
  fail "--plan advertises a model that is not what gets dispatched"
fi

# CLAUDE.md, which is what every orchestrator session reads.
if grep -q '`check-code` → opus' "$VELOREPO/CLAUDE.md"; then
  ok "CLAUDE.md says check-code -> opus"
else
  fail "CLAUDE.md disagrees with the script — the drift this suite exists to catch"
fi

# And no reader may still claim the superseded routings.
# Matched on the old WORDING, not on proximity. `check-code.*velo-local` looked
# right and was a false positive: the corrected line names check-code and then
# check-spec → velo-local, so any cross-line match fires on the fix itself.
if grep -qE '`check-code`( / `check-spec`)? → velo-local' "$ROOT/CLAUDE.md"; then
  fail "CLAUDE.md still routes check-code to velo-local"
else
  ok "no stale 'check-code -> velo-local' claim in CLAUDE.md"
fi
if grep -qE '^#   check-code   -> Codex' "$GATE"; then
  fail "the header still says check-code -> Codex"
else
  ok "no stale 'check-code -> Codex' claim in the header"
fi

# ── the routes that did NOT change ─────────────────────────────────────────
if grep -q 'dispatch_local check-spec' "$GATE"; then
  ok "check-spec still dispatches to velo-local"
else
  fail "check-spec routing changed unexpectedly"
fi
if grep -q "codex review - < '\$OUT'" "$GATE"; then
  ok "code-review still dispatches to codex"
else
  fail "code-review routing changed unexpectedly"
fi

# ── the health check watches BOTH CLIs ─────────────────────────────────────
# It is named for neither now, because it supervises a codex process and a
# claude process. A quota phrase that matches only one reports a real
# out-of-quota exit as a generic "exited in under 10s" — and Codex's usage limit
# ended a review mid-run on #2123, so that is not hypothetical.
if declare -f >/dev/null && grep -q '^gate_health_check() {' "$GATE"; then
  ok "the health check is named for the gate, not one vendor"
else
  fail "gate_health_check not found — renamed or removed"
fi
if grep -q 'gate_health_check "\$CODE_PID"' "$GATE"; then
  ok "check-code is supervised"
else
  fail "check-code dispatches unwatched — a dead gate would read as running"
fi
if grep -q 'gate_health_check "\$CODEX_PID"' "$GATE"; then
  ok "code-review is supervised"
else
  fail "code-review dispatches unwatched"
fi

# ── the follow-up command must carry the reviewed sha (#2110) ──────────────
# velo-pr-gate resolves $HEAD to build the diff range, then printed the
# velo-gate-post command WITHOUT it — so every operator followed an instruction
# that stamps whatever HEAD is at posting time, which is not what the gate saw.
# #2141: a review at bb1a36fba stamped @206aa76f6. velo-gate-post now refuses
# that case; this stops it arising.
if grep -q 'velo-gate-post \$PR code-review <report>\$GPS' "$GATE"; then
  ok "the printed velo-gate-post command carries --sha"
else
  fail "the follow-up command omits --sha — operators will stamp HEAD (#2110)"
fi
if grep -q 'GPS=" --sha \$GPS"' "$GATE"; then
  ok "the sha printed is the one the gate ran against"
else
  fail "no --sha is composed from the resolved head"
fi

# ── the DEFAULT check-code route is the $0 free tier (sonnet is opt-in) ─────
# Everything above describes the dispatched opus leg, which is the OPT-IN route
# (--check-code-by opus). That leg has never produced a report — it times out —
# so the default is the free OpenRouter leg the script dispatches itself, and the Sonnet
# prompt (check-code-agent-prompt.md) belongs to the opt-in sonnet route.
# Each reader has to say so, or the routing drifts apart again.
if grep -qF 'CHECK_CODE_BY="${VELO_CHECK_CODE:-free}"' "$GATE"; then
  ok "the default route is free, overridable by VELO_CHECK_CODE"
else
  fail "the default check-code route is not free"
fi
if grep -qF -- '--check-code-by)' "$GATE"; then
  ok "--check-code-by is parsed"
else
  fail "no --check-code-by flag — the route cannot be chosen per run"
fi
if sed -n '/^#   check-code/,/^#   check-spec/p' "$GATE" | grep -qE 'free +DEFAULT|DEFAULT.*free'; then
  ok "velo-pr-gate's header table names the free default"
else
  fail "the header table does not say free is the default"
fi
if grep -q 'check-code   -> sonnet' "$GATE" && grep -q 'ADVISORY — Codex' "$GATE"; then
  ok "--plan output names both the sonnet (opt-in) and the OpenRouter/free routes"
else
  fail "--plan does not say what the check-code routes do"
fi
if grep -q 'check-code-agent-prompt.md' "$GATE"; then
  ok "the opt-in sonnet route writes check-code-agent-prompt.md"
else
  fail "the sonnet route has no prompt file"
fi
for DOC in "$VELOREPO/CLAUDE.md" "$ROOT/README.md"; do
  if grep -q 'check-code-by' "$DOC"; then
    ok "$(basename "$DOC") documents --check-code-by"
  else
    fail "$(basename "$DOC") does not mention --check-code-by — the default changed under its readers"
  fi
done

echo
[[ $FAILED -eq 0 ]] && echo "all gate-routing checks passed" || echo "FAILURES"
exit $FAILED

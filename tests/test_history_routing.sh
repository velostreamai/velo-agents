#!/bin/bash
# Verify velo-dispatch's rework-history guard (#2120).
#
# The guard reads `.agents/tasks/<issue>.result.jsonl` — which this script has
# always written and never read — and refuses a same-or-lower tier after a
# non-landed attempt. The record showed why: #2000 was re-dispatched to
# velo-deepseek after velo-deepseek had already failed, and burned 253 turns.
#
# Tested by extracting the decision logic rather than launching a dispatch: the
# real thing clones a worktree, builds a 326MB index and spawns a model, none of
# which this guard depends on. What it depends on is the record and the route,
# and both are cheap to fabricate.
set -uo pipefail

DISPATCH="$(dirname "$0")/../bin/velo-dispatch"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

# Extraction is asserted, not assumed. Against a velo-dispatch without the
# guard, `sed` yields an empty string and `eval ""` succeeds — every assertion
# below would then pass vacuously, which is exactly how a test suite ends up
# certifying code that does not contain the feature. (This is not hypothetical:
# it happened in #2102, where 2 of 3 assertions scored green against a script
# missing the function under test.)
eval "$(sed -n '/^TIER_RANK() {/,/^$/p' "$DISPATCH")"
eval "$(sed -n '/^_zg_unsuccessful() {/p' "$DISPATCH")"
eval "$(sed -n '/^history_verdict() {/,/^}/p' "$DISPATCH")"
# EVERY function history_verdict calls must be listed. When `_zg_unsuccessful`
# was extracted into its own definition and this list was not updated, the
# missing function returned 127, the `||` branch treated that as "successful
# outcome", and every verdict came back `allow` — the guard silently disabled,
# reported as passing assertions rather than as an extraction failure. That is
# the same silent-fail-open class the guard itself exists to close.
for FN in TIER_RANK _zg_unsuccessful history_verdict; do
  if declare -F "$FN" >/dev/null; then
    ok "extracted $FN from velo-dispatch"
  else
    fail "$FN NOT extracted — the guard is absent; every assertion below is meaningless"
    echo "  (an empty eval succeeds, so these would pass vacuously)"
    exit 1
  fi
done

# ── tier ordering ──────────────────────────────────────────────────────────
# The whole guard reduces to this comparison, so pin it directly.
# Renumbered when velo-deepseek41 was added between deepseek and glm. Ranks are
# derived from the worker NAME on every call and never stored, so this cannot
# invalidate a historical result.jsonl row.
for PAIR in 'velo-local:0' 'velo-deepseek:1' 'velo-deepseek41:2' 'velo-glm:3' 'codex:4'; do
  GOT=$(TIER_RANK "${PAIR%%:*}"); WANT="${PAIR##*:}"
  if [[ "$GOT" == "$WANT" ]]; then
    ok "tier rank ${PAIR%%:*} = $GOT"
  else
    fail "tier rank ${PAIR%%:*} = '$GOT', expected '$WANT'"
  fi
done
if [[ "$(TIER_RANK "worker:opus")" == "-1" ]]; then
  ok "an unroutable worker ranks -1 rather than colliding with a real tier"
else
  fail "unknown worker did not rank -1 — it would compare as a valid tier"
fi

# ── the decision, over fabricated records ──────────────────────────────────
# `decide` is velo-dispatch's OWN history_verdict, eval'd above — not a copy.
# A re-implementation here would assert that the test agrees with itself.
decide() { history_verdict "$@"; }

# #2000, the case that motivated this: deepseek failed, then deepseek again.
if [[ "$(decide velo-deepseek failed velo-deepseek "")" == "refuse" ]]; then
  ok "#2000 shape: same tier after a failure is refused"
else
  fail "#2000 shape allowed — the 253-turn re-dispatch would happen again"
fi

# Same tier at the TOP tier: nowhere to escalate, but still refused.
if [[ "$(decide codex failed codex "")" == "refuse" ]]; then
  ok "same tier at the TOP tier is still refused"
else
  fail "top tier must not be exempt"
fi

# `abandoned` — no commits, no STOP, no error — is the other unsuccessful one.
if [[ "$(decide velo-glm abandoned velo-glm "")" == "refuse" ]]; then
  ok "'abandoned' triggers the guard"
else
  fail "'abandoned' did not trigger — only 'failed' is covered"
fi

# ── outcomes that are SUCCESSES must not trigger ───────────────────────────
# README:717,719 — `reported` is the CORRECT result for a read-only gate, and
# `stopped` is "a success of the policy, not a failure". The first version of
# this guard treated every non-`landed` outcome as failure, and #1918 shows the
# cost: seven re-dispatches to codex with commits climbing 0,2,3,4,5,5,6 then 9,
# every run ending `stopped`. All seven would have been refused, plus the
# deliberate codex->velo-glm move on the eighth. Three of ten transitions in the
# record were judged correctly.
if [[ "$(decide codex stopped codex "")" == "allow" ]]; then
  ok "'stopped' does not trigger — #1918's seven iterative re-dispatches proceed"
else
  fail "'stopped' refused — resumed iterative work would be blocked"
fi
if [[ "$(decide codex stopped velo-glm "")" == "allow" ]]; then
  ok "a deliberate tier DROP after 'stopped' proceeds (#1918's eighth run)"
else
  fail "the codex->velo-glm move was refused"
fi
if [[ "$(decide velo-glm reported velo-glm "")" == "allow" ]]; then
  ok "'reported' does not trigger — it is the correct outcome for a review gate"
else
  fail "'reported' refused — every read-only gate would be blocked on re-run"
fi
# read-only-violation is inferred from brief prose and #2006 is a known false
# positive, so it cannot justify refusing a dispatch.
if [[ "$(decide velo-glm read-only-violation velo-glm "")" == "allow" ]]; then
  ok "'read-only-violation' does not trigger — it is inferred, not observed"
else
  fail "an inferred outcome was used to refuse a dispatch"
fi

# #1987: escalation after a non-landed outcome still proceeds.
if [[ "$(decide velo-glm read-only-violation codex "")" == "allow" ]]; then
  ok "#1987 shape: escalation to a higher tier proceeds"
else
  fail "escalation was blocked — the guard refuses the correct response"
fi

# The LADDER still does real work: dropping a tier after a genuine failure is
# refused, which is the case string-equality alone could not catch.
if [[ "$(decide codex failed velo-deepseek "")" == "refuse" ]]; then
  ok "dropping a tier after a failure is refused"
else
  fail "a lower tier was allowed after a failure"
fi
if [[ "$(decide velo-deepseek failed codex "")" == "allow" ]]; then
  ok "escalating after a failure proceeds"
else
  fail "escalation after a failure was refused"
fi

# A landed run must not block follow-up work on the same issue at any tier.
if [[ "$(decide velo-glm landed velo-glm "")" == "allow" ]]; then
  ok "a landed prior attempt does not block re-dispatch"
else
  fail "landed blocked a re-dispatch — the guard fires on success"
fi

# ── an UNKNOWN tier is not a low one ───────────────────────────────────────
# TIER_RANK returns -1 for any name it does not route, and the parser maps a
# missing or null `worker` field to the sentinel `?` — which also ranks -1.
# Compared numerically, -1 sorts BELOW every real tier, so `nr > lr` always held
# and the verdict was always `allow`: a re-dispatch to the LOWEST tier after a
# failure, with an "escalating..." line printed as though it were real. The guard
# silently did nothing for that row shape (#2123 review, P1).
#
# Reachable, not contrived: velo-record writes `"worker": s("VR_WORKER")` and
# `s()` returns None when the variable is unset or empty (velo-record:188,275).
#
# Note the quoting: a bare `?` is a GLOB. Unquoted it expands to a single-char
# filename and shifts every argument along — which is exactly how this suite's
# first draft reported `unknown` for cases that compare fine.
if [[ "$(decide '?' failed velo-local '')" == "unknown" ]]; then
  ok "an unknown LAST worker yields 'unknown', not a silent allow"
else
  fail "unknown last worker gave '$(decide '?' failed velo-local '')' — the guard is a no-op for that row"
fi
if [[ "$(decide velo-glm failed '?' '')" == "unknown" ]]; then
  ok "an unknown NEW worker yields 'unknown' too"
else
  fail "unknown new worker was compared as a real tier"
fi
# ...but a landed prior attempt still short-circuits before any tier comparison.
if [[ "$(decide '?' landed velo-local '')" == "allow" ]]; then
  ok "'landed' still short-circuits ahead of the unknown-tier check"
else
  fail "a landed outcome was reported unknown"
fi
# The caller must SAY it did not check, rather than printing an escalation line.
if grep -q 'the re-dispatch guard did NOT run' "$DISPATCH" \
   && sed -n '/^        unknown)/,/;;/p' "$DISPATCH" | grep -q 'warn '; then
  ok "the unknown branch warns rather than reporting a false escalation"
else
  fail "the unknown verdict is not reported to the operator"
fi

# ── the new rung behaves like a rung ───────────────────────────────────────
# Adding a worker to TIER_RANK is not enough — it has to order correctly against
# its neighbours, or the guard silently treats a sideways move as an escalation.
if [[ "$(decide velo-deepseek failed velo-deepseek41 '')" == "allow" ]]; then
  ok "deepseek -> deepseek41 is an escalation"
else
  fail "escalating into the new rung was refused"
fi
if [[ "$(decide velo-deepseek41 failed velo-glm '')" == "allow" ]]; then
  ok "deepseek41 -> glm is an escalation"
else
  fail "escalating out of the new rung was refused"
fi
if [[ "$(decide velo-glm failed velo-deepseek41 '')" == "refuse" ]]; then
  ok "glm -> deepseek41 is a DOWNGRADE and is refused"
else
  fail "a downgrade into the new rung was allowed"
fi
if [[ "$(decide velo-deepseek41 failed velo-deepseek41 '')" == "refuse" ]]; then
  ok "the new rung refuses a same-tier repeat like every other"
else
  fail "same-tier repeat allowed on the new rung"
fi

# The override works, and requires a reason to exist.
if [[ "$(decide velo-deepseek failed velo-deepseek "brief now pins the schema")" == "allow-with-reason" ]]; then
  ok "--same-tier with a reason overrides the refusal"
else
  fail "override did not apply"
fi

# ── the flag demands a reason ──────────────────────────────────────────────
# A bare --same-tier would be typed reflexively the second time anyone hits the
# guard, which removes the only thing the guard is for.
OUT=$(bash "$DISPATCH" 9999 /nonexistent.md --same-tier 2>&1)
if grep -q 'needs a reason' <<<"$OUT"; then
  ok "bare --same-tier is rejected"
else
  fail "bare --same-tier accepted: $(head -2 <<<"$OUT")"
fi
OUT=$(bash "$DISPATCH" 9999 /nonexistent.md --same-tier --dry-run 2>&1)
if grep -q 'needs a reason' <<<"$OUT"; then
  ok "--same-tier does not swallow a following flag as its reason"
else
  fail "--same-tier consumed '--dry-run' as its reason"
fi

# ── failure MODE drives the advice, not just the refusal ───────────────────
# 5 of 11 non-landed outcomes in the record are read-only-violation: a worker
# doing what the brief forbade, NOT a worker that was not capable enough.
# Escalating there buys a better answer to a question nobody asked.
if grep -q 'discipline problem a stronger model will not fix' "$DISPATCH"; then
  ok "read-only-violation is distinguished from a capability failure"
else
  fail "read-only-violation is not distinguished from a capability failure"
fi
if grep -q 'failed WITHOUT producing work' "$DISPATCH"; then
  ok "a failure with no work points at the brief, not the model"
else
  fail "no distinction between failing with and without producing work"
fi

# ── malformed records must not block a dispatch ────────────────────────────
# The file is append-only and a crashed writer can leave a partial last line.
# A guard that REFUSES must fail toward allowing, or one truncated row wedges
# every future dispatch on that issue.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '{"worker":"velo-glm","outcome":"landed","work":{"commits":2}}\n{"worker":"velo-gl\n' > "$TMP/r.jsonl"
ROWS=$(python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except ValueError:
        continue
    n += 1
print(n)
' "$TMP/r.jsonl" 2>/dev/null)
if [[ "$ROWS" == "1" ]]; then
  ok "a truncated trailing row is skipped, not fatal"
else
  fail "malformed row handling returned '$ROWS' rows, expected 1"
fi

# ── a structurally valid row with garbage fields must not WEDGE the issue ──
# `"commits":"garbage"` is valid JSON. Bash arithmetic under `set -u` treats a
# non-numeric string as a VARIABLE name, and an undefined one aborts the script —
# so the guard failed CLOSED and `--same-tier` could not rescue it, because the
# arithmetic ran while composing advice, before the override was consulted. A
# guard that refuses must fail toward allowing. (#2123 review, P1.)
# Extract the REAL parser from velo-dispatch — the lines strictly between
# `HIST=$(python3 -c '` and the closing `' "$RESULT_FILE"`. Asserted non-empty
# below, because a silently-empty extraction would make every assertion here
# pass against nothing.
PARSE=$(awk "/HIST=\\\$\(python3 -c '/{f=1;next} f&&/^' \"\\\$RESULT_FILE\"/{exit} f" "$DISPATCH")
if [[ -n "$PARSE" ]] && grep -q 'def as_int' <<<"$PARSE"; then
  ok "extracted the record parser from velo-dispatch"
else
  fail "parser NOT extracted — the assertions below would test nothing"
fi
printf '{"worker":"velo-glm","outcome":"stopped","work":{"commits":"garbage"},"runner":{"turns":null}}\n' > "$TMP/g.jsonl"
OUT=$(python3 -c "$PARSE" "$TMP/g.jsonl" 2>/dev/null)
G_COMMITS=$(cut -f3 <<<"$OUT"); G_TURNS=$(cut -f4 <<<"$OUT")
if [[ "$G_COMMITS" =~ ^-?[0-9]+$ && "$G_TURNS" =~ ^-?[0-9]+$ ]]; then
  ok "non-numeric commits/turns are coerced to digits ($G_COMMITS/$G_TURNS)"
else
  fail "parser emitted non-numeric '$G_COMMITS'/'$G_TURNS' — bash arithmetic will abort"
fi
# The arithmetic itself, run exactly as the guard runs it.
if ( set -uo pipefail; [[ "$G_COMMITS" -gt 0 || "$G_TURNS" -ge 20 ]] || true ) 2>/dev/null; then
  ok "the guard's arithmetic survives a garbage record"
else
  fail "arithmetic aborted on a garbage record — the issue is wedged"
fi

# A JSON SCALAR where a dict is expected must not crash the parser (#2123
# re-gate, P1). `or {}` does not catch it — a scalar is truthy, so `.get` was
# called on a str, the parser exited non-zero, `|| HIST=""` swallowed it, and the
# guard silently did not run. Loud fail-closed traded for silent fail-open, which
# is worse: a quietly absent guard is how #2000 happened.
for SHAPE in '"runner":"notadict"' '"work":"notadict"' '"runner":[]' '"work":[]' '"runner":5'; do
  printf '{"worker":"velo-deepseek","outcome":"failed","work":{"commits":3},%s}\n' "$SHAPE" > "$TMP/s.jsonl"
  S_OUT=$(python3 -c "$PARSE" "$TMP/s.jsonl" 2>/dev/null); S_RC=$?
  if [[ $S_RC -eq 0 && -n "$S_OUT" ]]; then
    ok "scalar container does not crash the parser: $SHAPE"
  else
    fail "$SHAPE -> rc=$S_RC out='$S_OUT' — parser dies and the guard is skipped SILENTLY"
  fi
done
# A row that is not an object at all.
printf '"just a string"\n{"worker":"velo-glm","outcome":"landed","work":{"commits":1}}\n' > "$TMP/nonobj.jsonl"
if [[ "$(python3 -c "$PARSE" "$TMP/nonobj.jsonl" 2>/dev/null | wc -l | tr -d ' ')" == "1" ]]; then
  ok "a non-object row is skipped rather than crashing the parser"
else
  fail "a bare JSON string as a row broke the parser"
fi

# A parser failure must be REPORTED, not swallowed. Proceeding is correct; being
# quiet about it is not — the dispatch would look identical to a first attempt.
if grep -q 'the re-dispatch guard did NOT run' "$DISPATCH"; then
  ok "a parser failure warns instead of silently disabling the guard"
else
  fail "parser failure is swallowed — the guard can vanish with no output"
fi

# A tab in a field would shift every `cut -f` column after it.
printf '{"worker":"velo\\tglm","outcome":"landed","work":{"commits":1},"runner":{"turns":5}}\n' > "$TMP/t.jsonl"
T_OUT=$(python3 -c "$PARSE" "$TMP/t.jsonl" 2>/dev/null)
if [[ "$(cut -f2 <<<"$T_OUT")" == "landed" ]]; then
  ok "a tab in a worker name does not shift the outcome column"
else
  fail "tab shifted columns: outcome read as '$(cut -f2 <<<"$T_OUT")'"
fi

# ── the refusal text, checked for REACHABILITY not just presence ───────────
# A reviewer's fair objection: `grep -q '<string>' "$DISPATCH"` proves only that
# the string exists somewhere — in a comment, or in a branch that never runs. A
# mutation that kept the wording and broke its reachability would sail through
# (#2123 review, P2).
#
# These remain source checks, because the strings live inside a `die` reached
# only by a real dispatch with a matching record, which this suite deliberately
# does not launch. But they now assert the string is inside the block that uses
# it, so a moved or orphaned message fails. Extract each region once.
FIXUP_BLOCK=$(sed -n '/^      NEXT_TIER=""/,/^      fi$/p' "$DISPATCH")
ADVICE_BLOCK=$(sed -n '/^      case "\$L_OUTCOME" in/,/^      esac$/p' "$DISPATCH")
if [[ -n "$FIXUP_BLOCK" && -n "$ADVICE_BLOCK" ]]; then
  ok "extracted the advice and fixup regions from velo-dispatch"
else
  fail "region extraction failed — the checks below would test nothing"
fi

# The worker is chosen at spec/label time and never revisited — that is #2000.
# A refusal that does not name the label change leaves the stale decision in
# place and makes --same-tier the path of least resistance.
if grep -q 'gh issue edit \$ISSUE --repo \$REPO --remove-label' <<<"$FIXUP_BLOCK"; then
  ok "the refusal's fixup block emits the concrete label change"
else
  fail "the label change is not in the fixup block the refusal prints"
fi
if grep -q 'changing one leaves them disagreeing (#2085)' <<<"$FIXUP_BLOCK"; then
  ok "the fixup block names the spec file too, since the label overrides it"
else
  fail "only the label is mentioned — the spec would silently disagree (#2085)"
fi
if grep -q 'top tier — there is nowhere to escalate' <<<"$FIXUP_BLOCK"; then
  ok "the fixup block handles the top tier rather than suggesting a nonexistent one"
else
  fail "no top-tier case in the fixup block — it would suggest escalating past codex"
fi
# And the refusal must actually PRINT that block, not merely compute it.
if sed -n '/^        refuse)/,/;;/p' "$DISPATCH" | grep -q 'FIXUP'; then
  ok "the refuse branch prints the fixup block"
else
  fail "FIXUP is computed but never shown — the operator gets no action"
fi

# ── read-only-violation advice must not assert what it cannot know ─────────
# velo-record infers this outcome by grepping the brief's prose, and its own
# comment calls that inference "the actual defect". #2006's required analysis
# commits were recorded as a violation, and that row is in the count.
if grep -q 'INFERRED from the brief' <<<"$ADVICE_BLOCK" && grep -q '#2006' <<<"$ADVICE_BLOCK"; then
  ok "the read-only-violation ARM is hedged and cites the known false positive"
else
  fail "the hedge is not in the read-only-violation arm — it may be a stray comment"
fi

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $FAILED

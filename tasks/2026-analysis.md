# #2026 Stage 1 analysis — HAVING aggregate slot binding: `(None, None)` arm matches the wrong slot

- Branch: `fix/2026-auto` @ base `e403ae939`
- Date: 2026-09-11 (UTC)
- Stage: 1, read-only. No fix implemented. No `src/` change. Probe test written, run, captured below, and reverted before commit.

## Verdict

**REACHABLE. The failure mode is a silent wrong COLUMN in HAVING resolution, producing a wrong FILTER decision that reaches user-visible OUTPUT.** A group that must be filtered (its second aggregate is 0) is emitted, because both HAVING aggregate calls bind to the FIRST same-kind slot. The emitted aggregate VALUES themselves are correct — the accumulators are fine; only the HAVING-side slot binding is wrong. This is not masked downstream.

The shipped demo carries exactly this shape: `demo/trading/sql/financial_trading_legacy.sql:968-981` (`order_flow_imbalance`) has `SUM(CASE WHEN side='BUY'...)/SUM(quantity) > 0.7 OR SUM(CASE WHEN side='SELL'...)/SUM(quantity) > 0.7` in HAVING. Under this defect its HAVING evaluates as `buy_ratio > 0.7 OR buy_ratio > 0.7` — the SELL leg silently reads the BUY column.

## Anchors re-verified

Every anchor checked against code actually read at `e403ae939` in the worktree. Search commands listed per anchor.

| Spec anchor | Status | Evidence |
|---|---|---|
| `src/velostream/sql/execution/window_v2/operator.rs:1489` `fn find_slot_output_alias` | **CONFIRMED** at :1489 | `grep -n "find_slot_output_alias\|(None, None) => true" src/velostream/sql/execution/window_v2/operator.rs` → def at 1489, call at 1343 |
| `operator.rs:1530` `(None, None) => true` (comment "COUNT(*) vs COUNT(*) slot") | **CONFIRMED** at :1530, comment verbatim | same grep as above; arm read in full (Read of operator.rs:1280–1600) |
| `src/velostream/sql/plan/physical_strategy.rs:222` `pub value_column: Option<String>` on `AggSlot` (struct at :217) | **CONFIRMED** — `pub struct AggSlot` at :217, `pub value_column` at :222 | `grep -n "pub value_column" src/velostream/sql/plan/physical_strategy.rs` → 222; struct read via `sed -n '200,260p'`. The spec's warning is right: `operator.rs` also has a same-named field on `ChunkedExtractedConfig` (~:1604 region) which is NOT this anchor. |
| `src/velostream/sql/plan/physical_dispatch_resolver/agg_args.rs`, 9 × `Ok((None, None,` | **CONFIRMED — file exists, exactly 9** | `grep -c "Ok((None, None," src/velostream/sql/plan/physical_dispatch_resolver/agg_args.rs` → 9. File read IN FULL (795 lines). The complex-arm returns at :200, :206, :223, :249, :313–319, :441–447, :484–490, :536, :558–564, :581, :600–606 all set `value_column = None` for complex args. (The spec's ":200 and :206 are the complex-arg returns" is a subset — the homogeneous-dtype eligible-tree return at **:581** is the one my probe's `SUM(CASE WHEN b=1 THEN c ELSE 0 END)` takes: Case is `is_physical_expr_eligible` via `case_shape_eligible`, eligibility.rs:26/:115.) |
| `tests/unit/sql/plan/phase6_avro_loud_fail_test.rs`, 8 × `SUM(CASE WHEN` | **CONFIRMED — exactly 8** | `grep -n "SUM(CASE WHEN" tests/unit/sql/plan/phase6_avro_loud_fail_test.rs` → lines 168, 197, 232, 233, 235, 236, 244, 245. Lines 244–245 are the two-distinct-CASE-SUMs-in-HAVING evidence query (the #1436 "full deployed query" regression test). NOTE: these are **plan-build tests** (`build_optimized_plan`), they never execute HAVING — they pin that this query's plan BUILDS, not what it emits. |
| Whole-tree check for `agg_args.rs` (the spec's own trap) | file exists ONLY under `plan/physical_dispatch_resolver/` | `git grep -F -o find_slot_output_alias -- src tests examples` (8 refs / 3 files, matching the spec's blast radius: operator.rs def+call+2 comments, session_chunked.rs 3 doc-comment refs, having_index_divergence_pin_test.rs 1 comment) |

## Failure mode confirmed

**Silent wrong COLUMN — explicitly NOT #1994's refuted "Case arg matches nothing, yields Null, filters every group".**

Observed end-to-end (probe output below): the second `SUM(CASE ...)` in HAVING resolves to the FIRST Sum slot's `output_alias`, so its comparison reads the first aggregate's value. Nothing is Null, nothing errors, no group is filtered-by-Null — instead a group that SHOULD be filtered survives. The chain:

1. `resolve_agg_arg` (agg_args.rs:581 for this shape) stores `value_column = None` for every complex arg — the CASE expr is carried in `AggSlot.agg_expr` instead.
2. HAVING-side `find_slot_output_alias` (operator.rs:1489) extracts `arg_col = None` for any arg that is not Column/ColumnRef/COUNT-literal (operator.rs:1516–1521).
3. The matcher's `(None, None) => true` arm (operator.rs:1530) — written for COUNT(*) — accepts the FIRST same-kind slot. `AggSlot.agg_expr` is never consulted.
4. `eval_having_expr` (operator.rs:1342–1344) reads that alias's column from the emitted row → the second HAVING term compares the FIRST aggregate's value.

One complex aggregate of a given kind: first-slot match is coincidentally correct. Two same-kind: silently wrong.

Also confirmed reachable via `apply_chunked_having_filter`/`evaluate_having_against_row` for Tumbling; `SessionChunkedStrategy::stage_or_build_emit` (session_chunked.rs:2101) calls the SAME evaluator, so Session/Sliding share the defect by construction.

## Reachability probe (run, captured, reverted)

Temporary file `tests/unit/sql/execution/window_v2/zz_2026_probe.rs` + `pub mod zz_2026_probe;` in the parent `mod.rs` — both reverted before commit (`git status` clean but for this document).

Note: a first probe draft used a String side column (`CASE WHEN symbol = 'BUY'`) and failed EARLIER with an unrelated fixture-path error — `ExecutionError: build_predicate: left dtype Utf8 != right dtype Utf8View — mixed-dtype comparison not supported without explicit CAST` (the test fixture builds `Utf8` arrays; the vectorized CASE-condition literal is `Utf8View`). Possibly test-fixture-only, possibly its own issue — flagged for the orchestrator, not investigated further (out of scope). The committed evidence uses all-Int64 columns to isolate the slot-binding question.

### Probe source (final, all-integer)

```rust
//! #2026 Stage 1 TEMPORARY reachability probe — NOT to be committed.
use velostream::velostream::sql::execution::types::FieldValue;
use super::differential::{collect_group_pairs, four_int64_value_schema, run_engine_records};
use super::test_support::make_four_value_test_record;

/// TUMBLING(100ms) GROUP BY a, window [0,100) closed by ts=200.
/// group a=1: BUY 10 + BUY 5  -> buy=15, sell=0  -> HAVING should FILTER it.
/// group a=2: BUY 7  + SELL 3 -> buy=7,  sell=3  -> HAVING should PASS it.
#[test]
fn probe_2026_two_case_sums_in_having() {
    let sql = "SELECT a, \
                      SUM(CASE WHEN b = 1 THEN c ELSE 0 END) AS buy_qty, \
                      SUM(CASE WHEN b = 2 THEN c ELSE 0 END) AS sell_qty \
               FROM trades \
               WINDOW TUMBLING(100ms) \
               GROUP BY a \
               HAVING SUM(CASE WHEN b = 1 THEN c ELSE 0 END) > 0 \
                  AND SUM(CASE WHEN b = 2 THEN c ELSE 0 END) > 0 \
               EMIT FINAL";
    let records: Vec<_> = [
        // (ts, a=group, b=side 1=BUY/2=SELL, c=qty, d=unused)
        (0i64, 1i64, 1i64, 10i64, 0i64),
        (10, 2, 1, 7, 0),
        (20, 1, 1, 5, 0),
        (30, 2, 2, 3, 0),
        (200, 1, 1, 1, 0), // closes [0,100)
    ]
    .iter()
    .map(|&row| make_four_value_test_record(&[row]))
    .collect();

    let outputs = run_engine_records(sql, four_int64_value_schema(), records);

    for rec in &outputs {
        for r in 0..rec.batch.num_rows() {
            eprintln!(
                "EMITTED row: a={:?} buy_qty={:?} sell_qty={:?}",
                rec.field_at("a", r),
                rec.field_at("buy_qty", r),
                rec.field_at("sell_qty", r),
            );
        }
    }

    assert_eq!(
        collect_group_pairs(&outputs, "a", "sell_qty"),
        vec![vec![(FieldValue::Integer(2), FieldValue::Integer(3))]],
        "expected only group a=2 (buy=7, sell=3) to survive HAVING; \
         group a=1 has sell_qty=0 and must be filtered"
    );
}
```

`run_engine_records` is the FULL-engine runner (`build_plan_no_gate` → `StreamExecutionEngine::execute_pq` → EOS flush) — this is output as a user sees it, not an internal-operator shortcut.

### Exact failure output (nextest, 2026-09-11)

```
EMITTED row: a=Integer(1) buy_qty=Integer(15) sell_qty=Integer(0)
EMITTED row: a=Integer(2) buy_qty=Integer(7) sell_qty=Integer(3)

thread '...zz_2026_probe::probe_2026_two_case_sums_in_having' panicked at tests/unit/sql/execution/window_v2/zz_2026_probe.rs:59:5:
assertion `left == right` failed: expected only group a=2 (buy=7, sell=3) to survive HAVING; group a=1 has sell_qty=0 and must be filtered
  left: [[(Integer(1), Integer(0)), (Integer(2), Integer(3))]]
 right: [[(Integer(2), Integer(3))]]
```

### Wrong vs expected, values not prose

| group | buy_qty | sell_qty | HAVING as written (`buy>0 AND sell>0`) | EXPECTED in output | ACTUAL in output |
|---|---|---|---|---|---|
| a=1 | 15 | 0 | `15>0 AND 0>0` → **false** | filtered | **EMITTED** (defect evaluated `15>0 AND 15>0` → true) |
| a=2 | 7 | 3 | `7>0 AND 3>0` → true | emitted | emitted (correct, coincidentally — both terms read buy_qty=7, still true) |

Note a=2 shows the "coincidentally right" hazard: it passes for the WRONG reason (7>0 twice). Any group with buy>0 and sell≤0 is the discriminating case.

## Fix options (NOT implemented — orchestrator's choice)

### (a) Disambiguate on the argument EXPRESSION

Extend the matcher: when `(arg_col, slot_col) == (None, None)` and the kind is not the COUNT(*)-literal case, compare the HAVING call's arg expression against `AggSlot.agg_expr` (physical_strategy.rs — the slot ALREADY stores the original arg expression, so the "must agree with whatever built the slots" requirement is satisfied by comparing against the slot's own stored source of truth, not a re-derivation).

- **What breaks**: nothing that currently works correctly; both the probe query and the demo query produce right answers.
- **What it costs**: `Expr` derives `PartialEq` (ast.rs:1135), but **raw `==` is NOT safe**: the HAVING copy of the expression is resolved against the `Aggregate` node's output schema while the SELECT-list copy is resolved against the input schema (see operator.rs:1349–1408 — the same divergence that makes `ColumnRef.index` "known wrong" in this evaluator), so `ColumnRef.index` can differ between structurally-identical expressions. Needs a small index-insensitive structural equality (compare `ColumnRef`/`Column` by bare name, recurse). `canonical_agg_arg_str` (agg_args.rs:697) is NOT usable — its `_ => "expr"` catch-all collapses every CASE to `"expr"`, which is precisely non-disambiguating.
- **What it forbids / leaves open**: on its own, a no-match (HAVING references `SUM(CASE C)` matching no slot) still falls through to `lookup_row_field(None) → FieldValue::Null` → HAVING false → **silent filter-everything, i.e. exactly #1994's failure mode for the residual case**. (a) without a loud no-match is incomplete.

### (b) Refuse when MORE THAN ONE same-kind slot has `value_column == None`

Loud error instead of silent wrong answer — the stated house preference (`feedback_no_silent_fallback_paths`).

- **What breaks — the deciding input**: the shipped demo query `financial_trading_legacy.sql:968-981` becomes a rejected query, and `phase6_avro_loud_fail_test.rs`'s #1436 "full deployed query" regression test (lines ~229–252, the 2-CASE-SUM HAVING at :244–245) **expects that exact plan to BUILD successfully** — a plan-time (b) rejection fails that existing test; a HAVING-eval-time (b) rejection passes the plan test but makes the shipped demo fail at runtime. Either way (b) rejects a real, currently-shipped query whose intent is unambiguous.
- **What it costs**: smallest diff; a counting guard at the match site (or better, plan-time in `set_having_on_strategy`/resolver, per plan-time-first policy).
- **What it forbids**: every two-same-kind-complex-arg HAVING, including ones option (a) answers correctly. It also **misses** the single-None-slot mismatch: `SELECT SUM(CASE A)... HAVING SUM(CASE B) > 0` (different expression, only ONE None slot) still silently binds B to A's slot — (b)'s guard never fires there.

### (c) RECOMMENDED — (a) + loud no-match: expression-identity matching, fail loud when an aggregate call matches no slot

Match complex args by index-insensitive structural equality against `AggSlot.agg_expr`; keep the `(None, None) => true` arm ONLY for the COUNT(*) case it was written for (arg is COUNT-literal AND slot kind is Count AND slot `agg_expr` is None); and turn "no slot matched an aggregate call in HAVING" from today's silent `Null` into a hard `SqlError` (ideally raised at plan time, where the slots and the HAVING predicate are both known — `PhysicalDispatchResolver` already sees both; runtime-loud in `eval_having_expr` is the fallback position).

- **Why over (a) alone**: (a)'s residual no-match case is #1994's silent filter-everything; making it loud closes the whole class, which is the #1749 thesis this issue is filed under (name resolution re-implemented with a weaker private rule).
- **Why over (b)**: (b) rejects the shipped demo query and breaks an existing regression test, while still missing the single-slot mismatch case; (c) answers every currently-shipped query correctly AND is loud on every genuinely-unresolvable shape (b) worries about.
- **What breaks**: no currently-correct query. New failure surface: any HAVING aggregate whose expression doesn't structurally match a slot errs loudly instead of silently filtering — that is the intended behaviour change.
- **What it costs**: the structural-equality helper (~30–50 lines + tests: name-based ColumnRef/Column comparison, literal/function/case recursion); an error variant/message; plan-time wiring if the loud check is hoisted (preferred). Fix surface is small: `find_slot_output_alias` is private to operator.rs with ONE call site (operator.rs:1343); the Session path reuses the same evaluator, so one fix covers Tumbling/Sliding/Session.
- **What it forbids**: two textually-different-but-semantically-equal expressions (e.g. `CASE WHEN b=1 THEN c ELSE 0 END` vs `CASE WHEN 1=b THEN c ELSE 0 END`) won't match — loud error, user aligns the spelling. Acceptable: loud, actionable, and matches the SELECT-alias escape hatch (`HAVING buy_qty > 0` via `AliasRef` already works and sidesteps the whole matcher).

## Existing tests that pin current behaviour (orchestrator's deciding input for (b))

Search commands: `grep -rn "HAVING SUM(CASE" tests/`, `grep -rn "HAVING COUNT(\*)" tests/unit/sql/execution/window_v2/ tests/unit/sql/execution/processors/window/`, `grep -rn "HAVING SUM(\|HAVING AVG(\|HAVING MIN(\|HAVING MAX(" tests/unit/sql/execution/`.

**Tests exercising the `(None, None)` arm's legitimate COUNT(*) case through windowed execution** — must keep passing under any option; under (b)-as-stated (guard on >1 same-kind None slot) they still pass since each has a single Count slot:
- `tests/unit/sql/execution/window_v2/differential_test.rs` — 4 tests around :1480–:1646 (`HAVING COUNT(*) >= N`, SLIDING and SESSION)
- `tests/unit/sql/execution/window_v2/p15_virtualized_having_parity_test.rs:581`
- `tests/unit/sql/execution/window_v2/adapter_n_rows_test.rs:279–:324` (2 tests)
- `tests/unit/sql/execution/processors/window/window_processing_sql_test.rs:385`, `window_gaps_sql_test.rs:189,:414`, `unified_window_test.rs:98,:125`, `complex_having_clauses_sql_test.rs:31`, `timebased_joins_test.rs:76`

**Tests pinning complex-arg HAVING at PLAN level** — the one option (b) breaks if implemented plan-time:
- `tests/unit/sql/plan/phase6_avro_loud_fail_test.rs` — the #1436 "full deployed query" test (2 CASE SUMs in HAVING at :244–245) asserts `build_optimized_plan(...)` SUCCEEDS. **Plan-time (b) fails this test.**
- `tests/unit/sql/plan/phase6_avro_loud_fail_test.rs:168` and `tests/unit/sql/plan/declared_scan_completeness_test.rs:165`, `tests/unit/sql/plan/planner_resolution_invariant_test.rs:435` — single complex-arg HAVING, plan-build success pins; unaffected by (b)'s >1 guard, would break only under an overreaching "reject ALL complex-arg HAVING" variant.

**No existing EXECUTION test pins a single-complex-arg HAVING through the `(None, None)` arm** — every windowed execution HAVING test uses either a plain column arg (`SUM(value)`, Some/Some match) or `COUNT(*)`. So options (a)/(c) change no existing execution test's outcome, and even (b)'s runtime variant breaks no existing execution test — its breakage is the plan test + the shipped demo.

Related pin (context, not blocking): `tests/unit/sql/execution/processors/window/having_index_divergence_pin_test.rs` pins that HAVING resolution stays NAME-based (#1747) — none of the options touch that.

## Related-class observation (sweep-the-class, not fixed here)

`canonical_agg_arg_str` (agg_args.rs:729) renders any non-Column/Literal/Function arg as `"expr"`, so TWO un-aliased same-kind complex aggregates in the SELECT list would both emit the field name `SUM(expr)` — a same-class name collision on the PROJECTION side. Not probed (Stage 1 scope is the HAVING matcher); flagged for the orchestrator.

Second flag: the Utf8/Utf8View `build_predicate` error hit by the first probe draft (exact message above) — string-literal CASE conditions over Utf8 fixture columns fail loudly in the vectorized path. Loud, so not #2026-class, but worth a triage look.

## Verified vs assumed

**VERIFIED (by running code or reading it in full):**
- Reachability end-to-end through `StreamExecutionEngine::execute_pq` — probe output above.
- Failure mode = silent wrong column / wrong filter decision; aggregate values correct.
- All five spec anchors (table above), incl. the 9-count and 8-count.
- Case-arg chunked eligibility path: agg_args.rs complex arm → :581 return with `value_column=None` (eligibility.rs `case_shape_eligible`).
- `Expr` derives `PartialEq` (ast.rs:1135); `AggSlot.agg_expr` stores the original arg expression (physical_strategy.rs:~233).
- Both `pass_to_stay` selectors green after probe revert: `test(/window_v2/)` 1367 passed, `test(/having/)` 173 passed.
- Demo query shape at `financial_trading_legacy.sql:968-981` (read).

**ASSUMED (not executed):**
- That the demo query, when actually DEPLOYED through the demo harness, routes to the chunked windowed path (its SQL shape matches the probe's; the plan test at phase6 builds it; but I did not run the demo end-to-end).
- That `ColumnRef.index` divergence between SELECT-copy and HAVING-copy of the same expression occurs in practice (inferred from operator.rs:1349–1408's documented resolution-schema divergence; not separately reproduced) — this only affects the (a)/(c) design note that raw `PartialEq` is unsafe, not the defect finding.
- That Session/Sliding reproduce identically (shared evaluator by construction, session_chunked.rs:2101; only Tumbling was executed).

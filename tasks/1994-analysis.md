# #1994 Stage-1 Analysis — HAVING's input columns resolve by name at runtime

**Scope**: analysis only. No code changed. All line references verified against
`8daed48e1` (branch `fix/1994-auto`).
**Method note**: every claim below is marked **[M]** (measured: read directly in
source, or observed via running the named test/command) or **[R]** (reasoned:
derived from the cited code, not directly observed).

---

## 0. Defect observation — CONFIRMED

The defect was observed **directly at plan level**, not just inferred from the
issue's narrative. Two independent observations:

**Observation A — the evidence test passes while the column stays unresolved
[M]**. `cargo nextest run --no-default-features -E
'test(schema_rich_full_order_flow_imbalance)'` → 1 passed. The test
(`tests/unit/sql/plan/phase6_avro_loud_fail_test.rs:217`) asserts only that
`build_optimized_plan` **succeeds** — it never inspects the HAVING predicate.
Passing is consistent with both "resolved" and "unresolved but tolerated".

**Observation B — the position is never source-resolved in the executable plan
[M]**. This follows from four code facts, each read directly:

1. The HAVING predicate lives in a `PlanNode::Filter` above the Aggregate
   (`logical.rs` has no `having` field — `grep -n having logical.rs` is empty).
   The Filter arm of `rewrite_node` (`column_resolution.rs:457-466`) rewrites
   `predicate` against `input.schema` — the **Aggregate's OUTPUT schema**
   (`schema_propagation.rs:273-314`: group keys + `agg_output_field(agg)` slots
   named by `agg.alias`, e.g. `total_volume`). A raw input column (`quantity`,
   `side`) is not in that schema, so `rewrite_expr`'s `Expr::Column` arm
   (`column_resolution.rs:825-977`) fails `resolve_identifier` and falls through
   to line 974-976: *"Not found in schema — leave as Column."*
2. The only code that can resolve those positions against the **source** schema
   is `rewrite_having_aggregate_arguments` (`column_resolution.rs:1545`). It has
   exactly one caller (`:1390`), inside `visit_node`, operating on
   `predicate.clone()`, feeding `visit_expr`, result discarded — diagnostic only.
3. The completeness gate confirms this is the expected shape, not a one-off:
   `tests/unit/sql/plan/declared_scan_completeness_test.rs:143`
   (`having_predicate_aggregate_arguments_over_a_declared_scan_resolve`) pins
   that `quantity` surviving is *correct gate behaviour* over a declared scan.
4. The strict gate likewise cannot reject it: `schema_rich_windowed_having_
   reports_a_real_case_argument_mismatch` (phase6 test, line 180) **passes**
   [M], which is only possible because the diagnostic re-resolution is what the
   gate consults.

So: `quantity` and `side` — real columns of a declared Avro schema — remain
`Expr::Column` in the executed HAVING predicate. Observed.

**Corroborating runtime evidence [M]** — the two HAVING evaluators are built
around exactly this residual:

- `window_v2/operator.rs` `eval_having_expr` (:1329): `Expr::Column` arm
  (:1348) resolves **by name** against the emitted row's fields
  (`lookup_row_field`, a case-insensitive linear scan, :1551-1566); the
  `Expr::ColumnRef` arm (:1396) **deliberately discards the plan-stamped
  `index`** — documented at :1349-1395 as known-wrong for windowed HAVING
  (#1747), with `lookup_row_field`'s doc (:1536-1550) calling the name scan
  *"load-bearing correctness compensation"*, and a dedicated pin test
  (`tests/unit/sql/execution/processors/window/having_index_divergence_pin_test.rs`)
  asserting an index-based read would produce wrong results today.
- `processors/select/having.rs` `evaluate_having_expression` (:128): the
  per-record path. It resolves aggregate calls by **structural AST matching**
  against SELECT fields (`find_accumulator_key` :636, `args_match` :818 —
  including `case_expressions_match` :863) and a bare `Expr::Column` via
  `lookup_aggregated_field_by_alias` (:411), which **errors** when the name is
  not a SELECT alias.

---

## 1. The two-schema split, precisely

A HAVING `Filter`'s input schema is the Aggregate's **output** schema. Its
predicate therefore contains two kinds of column reference, which resolve
against **different schemas**:

| Sub-expression class | Example | Resolves against | Why |
|---|---|---|---|
| Aggregate call `SUM(x)`, `COUNT(*)`, or bare name bound to a SELECT alias/group key | `SUM(quantity) > 10000`, `total_volume > 0`, `symbol = 'X'` | **Aggregate OUTPUT schema** | The value exists only post-aggregation: `agg_output_field` slots (`schema_propagation.rs:309-311`) and group-key fields (:301-306). The runtime matches these structurally (`find_accumulator_key`/`args_match` [M]; `find_slot_output_alias` [M]). |
| Raw input column nested **inside** an aggregate argument (or other pre-agg position) | `SUM(CASE WHEN side = 'BUY' THEN quantity END) > 0` — `side`, `quantity` | **Aggregate INPUT (source) schema** | The argument is evaluated per-record against raw input rows as the accumulator fills; the value exists pre-aggregation. |

Concrete examples from the evidence query itself
(`phase6_avro_loud_fail_test.rs:229-247` [M]):

- Output-schema half: `HAVING SUM(quantity) > 10000` — `SUM(quantity)` matches
  the SELECT field `SUM(quantity) AS total_volume` structurally and reads the
  accumulator. Also `AND`/`OR`/comparisons joining two aggregate results.
- Source-schema half: inside the very same predicate,
  `SUM(CASE WHEN side = 'BUY' THEN quantity ELSE 0 END) / SUM(quantity) > 0.7`
  — the `side`/`quantity` **inside the CASE** are source-schema references, even
  though `SUM(...)` as a whole is an output-schema reference. The split is not
  by subtree; **it is by depth**: an aggregate call's *argument position* is
  source-scoped, everything outside an aggregate call's argument positions is
  output-scoped.

That depth rule is exactly what `rewrite_having_aggregate_arguments` encodes
[M]: at `Expr::Function{name}` **if** `is_aggregate_function(name)` it switches
the resolver to `rewrite_expr(.., source_schema, ..)` for the arguments only
(:1551-1557); everywhere else it keeps recursing with the source schema only
inside aggregate args and stops touching plain columns outside them (fallthrough
:1653 leaves them alone — the output-schema half was already bound by the main
pass).

One nuance worth recording [R]: the split the runtime actually implements is
three-valued, not two-valued — a bare non-alias column in HAVING
(`HAVING doubled > 0` where `doubled` is a SELECT alias) resolves against
neither schema; it is a **SELECT-list** reference, rejected by spec
(`name_binding_conformance_test.rs:739 having_output_alias_rejected` — SQL-92
§7.8 SR 1: HAVING evaluates before projection) and evaluated by the record path
via `lookup_aggregated_field_by_alias` only when it names an aggregate alias.

---

## 2. Is promoting `rewrite_having_aggregate_arguments` into the Filter arm sufficient?

**Short answer: it resolves the columns (the issue's stated defect) — the
compound-CASE-inside-HAVING-aggregate case IS reached — but promotion alone is
NOT sufficient as a fix, for a consumer-side reason the issue body did not
consider.**

### 2a. The compound-CASE claim: REFUTED (the case is reached) [M]

The issue body claimed *"a column nested inside a compound `CASE` inside a
`HAVING` aggregate is reached by neither"* pass. Reading the function directly:

- `rewrite_having_aggregate_arguments`'s aggregate arm (:1551) matches
  `Expr::Function { name, args } if is_aggregate_function(&name)` and calls
  `rewrite_expr(arg, source_schema, ctx)` on each arg. `is_aggregate_function`
  (`execution/expression/catalog.rs:159`) is a registry lookup — `SUM` is
  aggregate [M].
- `rewrite_expr` (`column_resolution.rs:813`) **fully recurses**: into
  `Function` args (:991-997), `Case` when/then/else (:1017-1031),
  `WindowFunction` args + over_clause (:999-1015), `List` (:1033), `Between`
  (:1040-1050), `BinaryOp`/`UnaryOp` (:980-989). `Expr::Case` is reached.

So for `SUM(CASE WHEN side = 'BUY' THEN quantity ELSE 0 END)`, the diagnostic
pass rewrites `side` and `quantity` against the source schema — the measured
behaviour of the strict-gate tests confirms this end to end: the test
`schema_rich_windowed_having_reports_a_real_case_argument_mismatch` passes a
real *mismatch* through (proving the CASE-nested position is consulted), and
`schema_rich_windowed_case_aggregate_resolves_order_book_columns` +
`schema_rich_full_order_flow_imbalance_demo_query_resolves` both pass with the
declared columns resolving (2/2 + 1/1 passed [M], `/tmp/1994.log`,
`/tmp/1994-b.log`).

The issue body's "reached by neither" was true of **neither** pass only in the
sense that the main pass reaches the position with the *wrong schema*; the
diagnostic pass reaches it with the right one. The position itself is covered.

### 2b. Why promotion alone is still not sufficient [M/R]

**The `Case`/`else` recursion asymmetry is fine; the problem is who consumes the
rewritten predicate.**

1. **The main pass would rewrite a position the runtime re-derives
   structurally.** If the Filter arm promotes the diagnostic rewrite onto the
   executable predicate (source-scoping aggregate args), then the executable
   `SUM(CASE WHEN side = 'BUY' THEN quantity ...)` arg becomes
   `SUM(CASE WHEN ColumnRef{index, "side"} THEN ColumnRef{index, "quantity"} ...)`.
   Now check the consumers:
   - Record path (`evaluate_having_expression`) matches the HAVING aggregate
     call **against SELECT fields by structural AST equality** (`args_match`,
     :818-860: `(Column, Column)` name equality; `(Case, Case)` deep structural
     equality). The SELECT side keeps its own resolved `ColumnRef`s (the
     Aggregate arm rewrote them against the source schema already), so a
     source-resolved HAVING arg can still match — **provided both sides went
     through identical resolution**, which is a new invariant this fix must
     establish and pin. [R, from M code]
   - Chunked path (`find_slot_output_alias`, operator.rs:1476-1531) extracts
     the arg column **only** from a bare `Expr::Column`/`Expr::ColumnRef` arg
     (:1503-1508). A `Case` arg — even fully `ColumnRef`-resolved — matches
     **nothing** and returns `None` → `lookup_row_field(None)` → `FieldValue::Null`
     → HAVING false. This is true **today**, for the un-promoted predicate too:
     `SUM(CASE ...)` inside a windowed chunked HAVING resolves to Null and the
     group is filtered out. That is a separate, pre-existing correctness gap
     (complex-arg slots exist — `AggSlot.agg_expr`/`synth_col`,
     `physical_strategy.rs:216-241` — but `find_slot_output_alias` never consults
     them). Promotion does not fix it, and must not be expected to. [M]
2. **The stamp would be an index into the wrong row-space on the chunked path.**
   `eval_having_expr`'s `ColumnRef` arm deliberately ignores `index` (#1747:
   resolved against the Aggregate's bare output schema, off by ≥2 vs the raw
   emit row that `apply_chunked_having_filter` evaluates against). If promotion
   stamps source-schema indices into the HAVING predicate, those indices would
   be *more* wrong for `row_fields` (they index the raw source batch, not the
   emitted row) — the name-lookup compensation would keep the results correct
   but the stamp would be actively misleading, and any future switch to
   `row_fields.get(index)` (the #1747 endgame) would break. **Conclusion:
   promotion and #1747 are coupled.** Either promote after #1747's index fix,
   or promote in a form that does not stamp indices into the chunked-consumed
   copy. [M — the divergence is documented and pin-tested]
3. **Idempotence and double-resolution.** The Aggregate arm already rewrote the
   same source columns inside `agg_exprs` (SELECT side). The HAVING predicate is
   a *separate* AST copy (builder lowers `query.having` into the Filter); it was
   never resolved, so there is no double-resolution hazard *within* one pass.
   But the promoted rewrite must be idempotent with the main pass's own
   revisit — `rewrite_node`'s Filter arm runs before the optimizer's later
   rules (`PhysicalDispatchResolver` stamps `having` onto the strategy via
   `set_having_on_strategy`, `physical_dispatch_resolver/mod.rs:396`), so the
   stamped strategy copy must be the post-promotion predicate, consistently.
   [R]

### 2c. Verdict

The candidate fix ("promote the diagnostic rewrite into the main pass, applied
to aggregate arguments against the source schema, while leaving
aggregate-result references to the output-schema pass") is **mechanically
sound and covers the CASE case** — the two-schema split is already correctly
drawn by the existing function. It is **not sufficient alone**: it must land
together with (or sequenced behind) an answer for (i) `find_slot_output_alias`'s
 blindness to complex args (pre-existing chunked-HAVING correctness gap for
`SUM(CASE ...)`-shaped HAVING), and (ii) #1747's index divergence (else the
newly-stamped indices are wrong by construction on the chunked path). Neither
(ii) nor (i) is *caused* by promotion, but promotion hard-codes their current
wrongness into more of the plan.

---

## 3. The module-doc invariant

`column_resolution.rs:69-74` states:

> Post-rule, every `Expr::Column` remaining in the tree is a column that could
> not be resolved (schema missing or column absent from schema).

**The fix, as scoped above, does NOT make this true, and the invariant already
needed amendment before #1994.** Three named exceptions exist today:

1. `Sort.order_by` — passed through verbatim by contract (`logical.rs`; §1c
   documents it, `visit_node`'s Sort arm excludes it). Output-batch names.
2. **HAVING aggregate-argument positions** — the defect class this issue
   tracks: visited by the main pass with the wrong schema, correctly resolvable
   only by the diagnostic pass that never reaches the executed plan.
3. The **runtime-protocol** columns: system columns (`is_system_col_or_window_
   bound` — exempted at `column_resolution.rs:880-882`) and, post-#1838, the
   window-bound names (`_WINDOW_START`/`_WINDOW_END` etc.) — attached at
   runtime, never in a declared schema.

**Amendment required** (wording proposal; the doc edit belongs to the
implementation PR):

> Post-rule, every `Expr::Column` remaining in the tree is a column the rule
> could not resolve **in the schema it was given for that position**, with
> named exceptions: (a) `Sort.order_by` (output-batch names, resolved by
> `OrderProcessor`), (b) HAVING aggregate-argument positions (source-schema
> refs inside an output-schema pass — #1994), (c) runtime-protocol columns
> (system/window-bound, attached per record at runtime).

After promotion lands, exception (b) shrinks but does not vanish: positions the
promotion cannot scope (a bare non-alias column outside aggregate args, per
§1's third-valued nuance; complex nested shapes if the promotion keeps the
"aggregate args only" boundary) still hold `Expr::Column` legitimately, and the
completeness gate (`collect_declared_scan_binding_failures`, §1c condition 2)
must keep excluding them **by the same walker arms** — name-binding.md's own
rule: *the check must describe the resolver, not compensate for it*.

---

---

## 4. Cost — what name-based HAVING resolution costs per record today

**Per-record name-based resolution happens today on both HAVING evaluators; the
amounts below are per-row, per-emit-group costs.**

**Record path** (`evaluate_having_expression`, per emitted group):

- A bare `Expr::Column` in HAVING goes through
  `lookup_aggregated_field_by_alias` [M]: a **linear scan of the SELECT fields
  list** with per-field string comparisons — O(#SELECT fields) per group per
  reference. Errors when no alias matches, so it only *succeeds* on
  aggregate-alias names.
- Aggregate calls go through `find_accumulator_key` [M] (:636-751): another
  linear scan of SELECT fields, with `args_match` **deep structural AST
  comparison** per candidate field (`case_expressions_match` for CASE args —
  full when/then/else recursion). This is per-group, per-HAVING-aggregate-call,
  **every record that closes a group**, not once per query. This cost exists
  *regardless* of whether the column inside the CASE is `Column` or
  `ColumnRef` — it is the aggregate-slot-matching cost, and it is what the
  issue's "name-based resolution per record" actually amounts to on this path.
  [M]
- If the column genuinely falls to the evaluator's name fallback (a `Column`
  surviving under a HAVING `Filter` that a per-record evaluator consumes via
  `ExpressionEvaluator::resolve_column`) — the classic per-record string-hash
  lookup the plan pipeline exists to avoid. [R — the general fallback cost;
  the specific HAVING evaluators mostly route through the structural paths
  above instead]

**Chunked windowed path** (`apply_chunked_having_filter` / `eval_having_expr`,
per emitted row):

- Every `Expr::Column` and every `Expr::ColumnRef` resolves via
  `lookup_row_field` [M] (:1551-1566): a **case-insensitive linear scan of the
  row's field list** — O(#row fields) per reference per row. The `index` is
  discarded deliberately (#1747). #1743 tracks exactly this cost and is blocked
  on #1747. [M — documented + pin-tested]
- Aggregate calls go through `find_slot_output_alias` [M] (:1476-1531): a
  linear scan of the AggSlot list per call per row. For a `Case` arg it
  returns `None` immediately → Null → group filtered (the §2b-1 gap).

**Measured-vs-reasoned status**: the *structure* of every cost above is read
directly from code [M]; there are **no cycle-level measurements** in this
analysis (profiling was out of scope for a no-code analysis task and would
require touching nothing anyway — but none was run, so none is claimed).
Everything above is reasoning over verified code shape.

**Does the proposed fix add cost?**

- **Plan time**: one extra `rewrite_expr` pass over HAVING aggregate arguments
  per plan build, against the source schema. Bounded by predicate size; the
  diagnostic pass already does exactly this work today on a clone [M] —
  promotion reuses that work instead of discarding it, so **net plan-time cost
  is ≈ zero** (the clone-based diagnostic walk could even be deleted once the
  gate reads the promoted result from the plan, if the implementation chooses
  to; that is an implementation decision, not required). [R over M]
- **Per record**: the fix removes nothing from the hot path *by itself* — the
  runtime evaluators still resolve by name/structure as described above. The
  honest statement: **#1994 as scoped does not deliver a per-record speedup;
  it delivers plan correctness (indices bound at plan time, invariant restored)
  and unblocks #1747/#1743**, which are the changes that actually convert the
  chunked path's name scans into O(1) indexed reads. The issue's acceptance
  criterion "no per-record cost added" is satisfied: nothing new is added to
  the per-record path. [R]
- **Risk to watch** [R]: if promotion stamps source-schema `index` values into
  the predicate consumed by `find_slot_output_alias`/`eval_having_expr` before
  #1747, the chunked path's *behaviour* is unchanged (it ignores `index`), but
  the plan now carries indices that are wrong for every consumer — the §2b-2
  coupling. No cost impact, but a correctness-trap impact.

---

## 5. Knock-on to `name-binding.md` §1c condition 2

Current text (name-binding.md §1c, "The predicate", condition 2, lines
349-357) [M]:

> it sits in a position the resolver rewrites. Two positions inside
> otherwise-visited nodes are NOT rewritten and must be excluded:
> - **`Sort.order_by`** — …
> - **a HAVING predicate's aggregate-argument sub-expressions** — see the
>   mechanism below;

If the candidate fix lands, the second bullet **shrinks but does not
necessarily vanish**:

- **What disappears**: the blanket exclusion of HAVING aggregate-argument
  sub-expressions. After promotion those positions ARE rewritten by the main
  pass (source-scoped), so a residual `Expr::Column` there is once again a
  *genuine* unresolved column and the completeness gate should report it —
  exactly what §1c wants ("the check must describe the resolver").
- **What survives**: whatever residual the promoted rewrite still legitimately
  leaves. Two candidates [R]: (a) bare non-alias HAVING columns outside
  aggregate args (the SQL-92-§7.8-rejected output-alias shape — already a
  separate §1c row, `having_output_alias_rejected`, unchanged); (b) any complex
  sub-position the promotion deliberately does not scope (e.g. columns inside a
  subquery in HAVING — already plan-rejected by #1053's subquery path-lock on
  the chunked path, so likely moot, but the implementation must verify).
- **Mechanism constraint** [M]: §1c condition 2 is *derived by construction*
  from `visit_node(strict_gate = true)` — the doc says so explicitly ("If
  #1994 widens the resolver, the same arm widens the check"). So the doc edit
  is mechanical: the bullet list in condition 2 loses or rewords the HAVING
  bullet **only when the walker arm changes in the same PR**. The two must not
  drift — that is the doc's own central rule. `rewrite_having_aggregate_
  arguments`'s diagnostic role either disappears (gate reads the promoted plan
  directly) or stays identical to the promoted main-pass behaviour — the
  implementation must pick one; a third, divergent scoping would be exactly the
  hand-maintained drift §1c forbids.
- **Also affected, same doc** [M]: the §1c "Why — measured, not assumed"
  narrative block (lines ~314-335) describing the wrong-schema mechanism and
  the "consequence worth naming" paragraph (lines ~381-387) which says the gap
  is "Tracked separately" — that paragraph should be updated to reference the
  fix. And `column_resolution.rs`'s module-doc invariant (§3 above) needs the
  same-PR amendment, since §1c quotes it.

**Net**: the carve-out can shrink from "a whole clause's aggregate-argument
positions" to (at most) "bare output-alias references + whatever narrow
residual the promoted scoping leaves" — potentially deletable entirely if the
promotion ends up total for the clause. The exact final wording is determined
by the implementation's scoping choice, and per the brief the doc edit belongs
to that PR, not this analysis.

---

## 6. Recommendation — **requires maintainer approval before any implementation**

**Recommendation: promote the existing two-schema rewrite into the main pass,
sequenced behind (or bundled with) an explicit answer for the two coupled
consumer-side defects, and amend the module-doc invariant in the same PR.**

Reasoning:

1. **The mechanism is right and already written.** `rewrite_having_aggregate_
   arguments` draws the source/output boundary at exactly the depth the runtime
   consumers expect (§1), covers the compound-CASE case (§2a), and is verified
   end-to-end by the strict-gate tests [M]. Promotion converts dead diagnostic
   work into the executed plan — the same "one path, not two" principle the
   repo's production-wiring discipline demands (no gated additive helper with
   no production caller: today's function is precisely that anti-pattern, run
   only for diagnostics on a clone).
2. **But land it as a *sequenced* fix, not a one-liner.** Three hard
   requirements, all evidence-backed above:
   - **R1 (coupling, §2b-2)**: do not promote source-schema `index` stamping
     into the chunked-consumed predicate before #1747 resolves the index
     divergence; the pin test
     (`having_index_divergence_pin_test.rs`) documents an index-based read
     being actively wrong today. Sequencing options: fix #1747 first, or
     promote in a way the chunked path cannot misread (e.g. keep names in the
     strategy-stamped copy), or accept and *document* the
     deliberately-unconsumed indices. The choice is a maintainer decision —
     each option has a different blast radius.
   - **R2 (pre-existing gap, §2b-1)**: `find_slot_output_alias` resolves no
     slot for a `Case`/complex arg → windowed chunked `HAVING SUM(CASE …)`
     evaluates Null today, filtering every group. This is *out of #1994's
     scope* (it exists without promotion), but the implementation PR must
     either fix it, file it with a repro pointing at
     `find_slot_output_alias`'s arg-extraction arms, or the promotion will be
     blamed for a pre-existing silent-wrong-result. Silent-wrong-result class
     per repo policy — it should be surfaced loudly, not absorbed.
   - **R3 (invariant + gate, §3/§5)**: amend the module-doc invariant and the
     §1c condition-2 bullet in the same PR, keeping `visit_node(strict_gate)`
     as the single derivation point. If the diagnostic clone-walk is retired,
     the gate must read the promoted plan — never a third scoping.
3. **Per-record cost**: promotion adds none (§4) — the issue's "no per-record
   cost added" acceptance holds. The *wins* (O(1) indexed HAVING resolution)
   arrive via #1747/#1743, which this fix unblocks rather than delivers.
4. **Not recommended**: rewriting the whole HAVING predicate against the source
   schema (breaks every output-schema reference — `HAVING COUNT(*) > 5` has no
   source-side existence), and leaving the status quo (the defect). Both
   directions are excluded by the two-schema evidence in §1. [M]
5. **Structural boundary respected**: nothing above requires a `having` field
   on `PlanNode::Aggregate` or any plan-shape change — the Filter-over-Aggregate
   lowering is where the fix belongs. [M]

**Explicitly marked: this recommendation requires maintainer approval.** The
sequencing choice in R1 (fix-first vs. promote-with-names vs.
promote-and-document) and the disposition of R2 (fix vs. file) are decisions
above this analysis's pay grade, each with cross-issue consequences
(#1743/#1747/#1436 consumers).

---

## Appendix — evidence commands run (all read-only)

```
cargo nextest run --no-default-features -E 'test(schema_rich_full_order_flow_imbalance)'        # 1 passed
cargo nextest run --no-default-features -E 'test(schema_rich_windowed_having_reports_a_real_case_argument_mismatch) or test(schema_rich_windowed_case_aggregate_resolves)'  # 2 passed
grep -n "having" src/velostream/sql/plan/logical.rs                                             # (empty)
awk '/^    Aggregate \{/,/^    \},/' src/velostream/sql/plan/logical.rs | grep -E "^\s+[a-z_]+:" # fields, no having
```

Key source positions read (branch `fix/1994-auto`, base `8daed48e1`):
`column_resolution.rs` :69-74 (invariant), :457-466 (Filter arm), :490-536
(Aggregate arm), :813-977 (rewrite_expr Column arm + fallthrough), :991-1031
(Function/Case recursion), :1358-1499 (visitor + strict gate + having_aggregate_
input), :1545-1655 (rewrite_having_aggregate_arguments); `schema_propagation.rs`
:273-314 (Aggregate output schema), :483-488 (agg_output_field);
`physical_dispatch_resolver/mod.rs` :372-404 (HAVING stamp), :840-981
(resolve_agg_arg call + alias); `physical_dispatch_resolver/agg_args.rs` :33-615
(value_column=None for every complex arm); `physical_strategy.rs` :203-241
(AggSlot); `window_v2/operator.rs` :906-1084 (apply_chunked_having_filter),
:1178-1286 (extract_having_from_plan), :1313-1469 (eval_having_expr),
:1471-1566 (find_slot_output_alias, lookup_row_field);
`processors/select/having.rs` :128-472, :557-751, :818-918;
`processors/select/group_by.rs` :1364-1379; `engine/flush_group_by.rs` :265-277,
:517-528; `engine/ddl_explain.rs` :20-142; `plan/mod.rs` :288-311 (bind_plan),
:376-398 (binding phase); tests as cited in §0.

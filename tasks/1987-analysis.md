# #1987 — Stage-1 Analysis: batch stream-stream JOIN drops the SELECT projection

**Worktree:** `velostream-1987` on `fix/1987-auto` @ `d5e4002b0` (master tip)
**Nature:** Read-only analysis. No `src/` changes.
**Revision 2** — the recommendation was rewritten after a `/pr-gate` review
refuted both of revision 1's supporting arguments. Read §0 first; §2 and §3
retain revision 1's A-vs-B framing with the refuted claims marked inline.

---

## 0. CORRECTION — this analysis was blocked and rewritten

The first revision recommended Mechanism B on two arguments. **A `/pr-gate`
review refuted both**, and the rewrite below follows from that. §1 (the
reproduction) and §4 (the pattern check) survived review unchanged and are
retained.

**Refuted argument 1 — "A would be a THIRD implementation of batch projection".**
There is already a third, and it changes the verdict rather than supporting it:
`select.rs:1731-1750` (#594 "Case 6", Project-over-Limit) projects via
`compute_limit_project_indices` + Arrow `RecordBatch::project` +
`StreamRecord::from_batch`. It is batch-native and zero-copy, and it was
**hardened at #1740 R4 to append every `SystemCol::COUNT` position including
`SystemCol::Traceparent`** — the code comment there records that the previous
hardcoded `0..6` *"silently dropped its rows' per-row W3C trace context"*.

That inverts the case against an inline mechanism: an **Arrow-`project`-based**
projection preserves every system column **by construction**, with no per-row
metadata threading at all. The `keys=None` trap and the `_TRACEPARENT` objection
below apply to the `interval_join.rs` row-rebuild template — not to this one.
`resolve_col_indices` is already imported at `select.rs:71` and supplies the
name→index step against the packed batch.

**Refuted argument 2 — "the packed JOIN batch carries per-row `_TRACEPARENT`
today (measured §1)".** False, and never measured. §1's `REPRO-SYS-COLS` line
prints schema column **names**, not values, and the harness fixtures are built
with `StreamRecord::from_rows`, which hardcodes `_TRACEPARENT` all-NULL
(`builder.rs:1172`). Independently, `pack_join_results_with_trace_headers`
rebuilds via `from_rows` for every ≥2-record pack
(`join_dispatch.rs:268-290`) → all-NULL. So on that path there is **nothing to
lose**, and the "mandatory companion change" the first revision demanded
protects nothing.

**Also corrected:** the first revision claimed the decoupling is "one `Option`
gate read". It is not. `interval_join_needs_post_join_select` (`:515`) returns
**false** for a plain projection SELECT — it fires only on DISTINCT / GROUP BY /
HAVING / LIMIT / ORDER BY / rows-window — so for #1987's own repro query it says
"no deferral needed" and must change too. And `apply_post_join_select` is
`pub(super)` inside `engine` with five callers, all interval-join/watermark;
it is never reached from the `SelectProcessor::process` return path.

---

## 1. Reproduction on current master — CONFIRMED, measured

### Exact command

```bash
bash .agents/tasks/1987-repro.sh
```

The script emits a **temporary, unregistered** harness `tests/repro_1987_columns.rs`
(never added to `tests/mod.rs`, deleted after the run — so no gate ever compiles it),
builds it as a one-off integration test, runs it, and prints the post-JOIN post-WHERE
batch schema. It uses the identical fixture shape as
`tests/unit/sql/execution/processors/join/batch_join_where_test.rs` test 1
(`prime_stream_stream` pattern: `build_plan_no_gate` + `PrimedQuery` +
`data_sources`-registered build side), so it drives the real
`probe_stream_stream_batch` dispatch arm through `execute_pq` — no hand-constructed
plan nodes.

The compiled harness binary also remains at
`target/debug/deps/repro_1987_columns-bb49b521080d6238` in this worktree and can be
re-run directly: `target/debug/deps/repro_1987_columns-bb49b521080d6238 --nocapture`.

### Output (measured)

For

```sql
SELECT a.auction_id, a.category, r.tier FROM auction a JOIN person r ON a.seller = r.person_id WHERE a.category = 10
```

with a 3-row probe (auction_id 101/102/103, category 10/5/10) against a 1-row
`person` build side:

```
REPRO-COLUMN-LIST:     a.auction_id;a.seller;a.category;r.person_id;r.tier
REPRO-DATA-FIELDS-ROW0: a.auction_id;a.category;a.seller;r.person_id;r.tier
REPRO-SYS-COLS:        _EVENT_TIME;_TIMESTAMP;_OFFSET;_KEY;_HEADERS;_PARTITION;_TRACEPARENT
REPRO-ROW-COUNT:       2
REPRO-VERDICT:         UNPROJECTED
```

### Reading of the result (measured)

- **Five data columns for a three-column SELECT.** The batch schema carries
  `a.auction_id`, `a.seller`, `a.category`, `r.person_id`, `r.tier` — the three
  selected columns plus the two join keys riding along. The order differs between
  the Arrow schema (`a.auction_id;a.seller;a.category;r.person_id;r.tier`) and the
  row-view field iteration (`a.auction_id;a.category;a.seller;r.person_id;r.tier`).
  Both are unprojected; the issue's reported order
  `["a.seller", "r.person_id", "a.auction_id", "r.tier", "a.category"]` matches the
  pre-#1749 layout — the canonical-qualified layout on today's master differs in
  ordering but not in the substantive defect (all 5 columns, no projection).
- **Row count is 2, not 3**: `WHERE a.category = 10` IS applied
  (`apply_where_to_joined_batch`, `select/join_dispatch.rs:415`) — the #1413/#1414
  fix is intact on this path. Only the SELECT list is dropped.
- **System columns survive** in the schema (`_EVENT_TIME`, `_TIMESTAMP`, `_OFFSET`,
  `_KEY`, `_HEADERS`, `_PARTITION`, `_TRACEPARENT`) — the packing step
  (`pack_join_results_with_trace_headers` → `StreamRecord::from_rows`) emits the
  full canonical system tail; nothing here truncates per-row metadata.
- This is the same defect the issue reports, re-measured on `d5e4002b0` (today's
  master tip). **It still reproduces.** No negative result to report.

---

*(Sections 2–5 follow in subsequent commits.)*

---

## 2. The two mechanisms, compared

### Mechanism A — inline projection mirroring `interval_join.rs`

The template is `IntervalJoinProcessor::apply_projection`
(`src/velostream/sql/execution/processors/interval_join.rs:794`). Verified shape:

- Short-circuits `SelectField::Wildcard` (returns the record unchanged).
- Per row (`for view in record.iter_rows()`), resolves each field via
  `resolve_field_at` (qualified-name aware, `#1457` system-column aware) for
  `Column` / `AliasedColumn`, or evaluates via `ExpressionEvaluator` for
  `Expression { expr, alias }`.
- Rebuilds per-row `event_time`, `timestamp`, `offset`, `key`, `headers`,
  `partition` into explicit `Vec`s and calls `StreamRecord::from_rows` with
  `Some(keys)` / `Some(headers_rows)` / `Some(partitions)`.
- The `#1460` comment at `interval_join.rs:811-816` records the trap: an earlier
  version passed `keys=None` and **silently nulled every Kafka message key**.
  `from_rows`'s signature (`stream_record/builder.rs:952`: `keys: Option<Vec<...>>`,
  `headers: Option<Vec<...>>`, `partitions: Option<Vec<...>>`) silently produces
  all-NULL columns when the `Some` side is omitted — the API makes the
  key-nulling failure mode invisible at the call site.

Duplication cost: applying A here is a **third** implementation of batch
projection in the tree. The other two, verified:

1. `IntervalJoinProcessor::apply_projection` — `processors/interval_join.rs:794`
   (per-row, from_rows-based, key/header/partition-correct post-#1460).
2. `apply_select_with_rows_window`'s per-row SELECT-field loop +
   `StreamRecord::from_explicit_with_key` rebuild —
   `processors/select/rows_window.rs:684-1006` (single-row per call; the N>1
   fan-out in `SelectProcessor::process`'s ROWS-WINDOW block and
   `apply_post_join_select`'s per-row loop both unroll to it row by row).

**[REFUTED — see §0. True for the `interval_join.rs` row-rebuild template, but
not for the Arrow-`project` mechanism now recommended, which preserves every
system column by construction.]** A would also need `_TRACEPARENT` handling the interval-join template itself
lacks (see §3) — so it would not even be a copy of #1; it would be #1 plus a
per-row `traceparent_at(row_idx)` collection and a `with_per_row_traceparents`
call after `from_rows`, since `from_rows` hardcodes `_TRACEPARENT` to all-NULL
(`builder.rs:1170-1173`).

### Mechanism B — decouple `apply_post_join_select`

The engine pass is `StreamExecutionEngine::apply_post_join_select`
(`src/velostream/sql/execution/engine/interval_join.rs:438`). Verified structure:

- **Gate**: `ctx.cached_interval_join_processor()
  .and_then(|p| p.post_join_select_query())` — if the cached interval-join
  processor exists AND carries a deferred stripped query, run the pass;
  otherwise return `outputs` unchanged. The batch stream-stream/stream-table
  arms in `SelectProcessor::process` have **no** cached interval-join
  processor, so the pass is inert there today (the "coupled to the interval-join
  path" claim in the issue brief is confirmed).
- **Body** (once the gate opens): alias-context pre-population from the FULL
  query, then per row (`envelope.iter_rows()` → `to_single_row_record`) →
  `SelectProcessor::process_scoped(&stripped_query, single_row, ctx, Some(query_id), false)`
  → LIMIT check via `LimitProcessor::should_process_record(ctx)` per row →
  header-mutation application → output accumulation.

Decoupling options (reasoned): the gate could be changed to consult a
stripped-query stored on `ProcessorContext` (e.g. `ctx.post_join_select_query`),
set once per query by whichever path defers the SELECT — the interval-join
processor's `with_post_join_select` (`processors/interval_join.rs:486`) becomes
one writer among potentially two. `build_post_join_select_query`
(`engine/interval_join.rs:557`) and the `needs_...` predicate
(`engine/interval_join.rs:515`) are already query-shaped and processor-agnostic;
only the storage location and the gate read are interval-join-specific.

The stripping contract (`joins = None`, `where_clause = None`) documented at
`engine/interval_join.rs:544-556` is exactly what the batch JOIN arms need: they
have already executed the join (packed batch) and already applied WHERE
(`apply_where_to_joined_batch`).

### Comparison table

| Dimension | A (inline projection) | B (decoupled post-join SELECT) |
|---|---|---|
| SELECT-list correctness | Yes (after implementing the field loop) | Yes (via `process_scoped`, same pipeline as every non-join path) |
| Per-row metadata **[row-rebuild template only — see §0; Mechanism C preserves all system columns by construction]** | Must be built by hand; trap = `keys=None`; `_TRACEPARENT` needs extra work beyond the template | Preserved by construction — `to_single_row_record` is a zero-copy batch slice (`stream_record/view.rs:512`) carrying all columns; the downstream rebuild is the same one every other path already uses |
| Expression SELECT fields | Supported in the template | Supported (ExpressionEvaluator + alias context + subqueries via `process_scoped`) |
| Clause composition beyond SELECT | Nothing — a bare field loop | LIMIT / GROUP BY / HAVING / DISTINCT / ORDER BY composition comes along (that is what #1457/#1460 built it for) |
| Duplication | Third batch-projection implementation | None new; generalizes an existing pass |
| Size of change (reasoned) | Small–medium: ~1 new fn (~80–120 LOC) + wiring at 2 call sites + test updates | Medium: gate/storage refactor on `ProcessorContext` + construction-site wiring + the batch arms route outputs through the pass; touches shared engine code |
| Risk | Contained to the JOIN dispatch arms; but metadata fidelity is hand-rolled every time | Shared-code change; must not perturb the existing interval-join callers (gate change is the risk surface) |

---

## 3. Per-row metadata verdict

~~**Recommended mechanism: B (decoupled post-join SELECT), with A as the
lower-risk fallback**~~ **[SUPERSEDED BY §5 — the recommendation is Mechanism C;
this line retains revision 1's framing]**. Verdict below covers B, then A.**

### B — measured/reasoned

- Input construction: `apply_post_join_select` unrolls `outputs` with
  `envelope.iter_rows()` and `view.to_single_row_record()`
  (`engine/interval_join.rs:465-473`). `to_single_row_record`
  (`stream_record/view.rs:512-528`) is `self.batch.slice(self.row, 1)` — an
  Arrow zero-copy slice keeping **every column of the schema**, data and system
  alike (`_EVENT_TIME`, `_TIMESTAMP`, `_OFFSET`, `_KEY`, `_HEADERS`,
  `_PARTITION`, `_TRACEPARENT`). Per-row metadata is therefore preserved *per
  row* by construction — nothing reads row 0 of the packed batch.
- Rebuild: inside `process_scoped` → `apply_select_with_rows_window`
  (`processors/select/rows_window.rs:998-1006`), the output record is built via
  `from_explicit_with_key(result_fields, computed_event_time,
  joined_record.timestamp_at(0), joined_record.offset_at(0),
  joined_record.partition, output_headers, joined_record.key_at(0))` — where
  `joined_record` is the per-row slice record, so `_TIMESTAMP`/`_OFFSET`/
  `_PARTITION`/`_KEY`/`_EVENT_TIME` (plus an aliased `_EVENT_TIME` override via
  `compute_output_event_time`, rows_window.rs:977-982) come from the row's own
  values. `_HEADERS` = `joined_record.headers_at(0)` merged with
  `context.merge_pending_trace_headers` (rows_window.rs:986-987).
- **`_TRACEPARENT` caveat (measured in code, not by test)**: the
  `from_explicit`/`build_batch` family stamps `_TRACEPARENT` to NULL at
  single-row construction (`stream_record/mod.rs:413-415`), and neither
  `from_explicit_with_key` nor `apply_select_with_rows_window` re-stamps it from
  `joined_record.traceparent_at(0)`. So B preserves `_TRACEPARENT` **only
  through the slice input, losing it at the rebuild** — same behaviour as
  today's interval-join post-join pass. Note this loss is *pre-existing* on the
  interval-join path and NOT a regression introduced by extending the pass, but
  an implementer should either stamp
  `with_traceparent(joined_record.traceparent_at(0))` (single-row variant,
  `builder.rs:387`) at the end of the rebuild or accept the documented gap with
  the maintainers' blessing. Phase 8 trace propagation spans
  (`observability`) consume `traceparent_at(row_index)`.
- ~~Comparison: today's unprojected arm output (measured, §1) DOES carry
  populated `_TRACEPARENT` through the packed batch — so a naive B rollout
  without the traceparent re-stamp would be a metadata *regression*...~~
  **[REFUTED — see §0 refutation 2. This was never measured: §1 printed schema
  column NAMES, and `pack_join_results_with_trace_headers` rebuilds via
  `from_rows`, which hardcodes `_TRACEPARENT` all-NULL (`builder.rs:1163-1172`).
  There is nothing to lose on that path, so no re-stamp is "mandatory" for the
  reason given here.]**

### A — reasoned (with code citations)

The interval-join template rebuilds six of the seven system columns per row
(`interval_join.rs:854-859`: `event_times.push(view.event_time())`,
`timestamps.push(view.timestamp())`, `offsets.push(view.offset())`,
`keys.push(view.key()...)`, `headers_rows.push(view.headers())`,
`partitions.push(view.partition())`) and passes them to `from_rows` as
`Some(...)` (`interval_join.rs:862-870`). Per the `#1460` comment
(`interval_join.rs:811-816`) the `keys=None` variant was the historical bug.
Missing from the template: `_TRACEPARENT` (a copy of the template would emit
all-NULL, `builder.rs:1170-1173`), and the `topic`/`watermark` record-level
fields (carried by `pack_join_results_with_trace_headers`'s upstream inputs,
dropped silently by `from_rows` which has no parameters for them —
`StreamRecord { topic, watermark }` are record-level, `builder.rs:1186-1196`).
Same conclusion as for B: a `with_per_row_traceparents`/
`with_traceparent` re-stamp is required for Phase 8 fidelity under either
mechanism.

**Net verdict for B ~~(recommended)~~ [superseded by §5]**: `event_time`/`timestamp`/`offset`/`key`/
`headers`/`partition` — preserved per row by construction (zero-copy slice in,
row-sourced rebuild out). `_traceparent` — needs one deliberate re-stamp line
at the rebuild site, or the gap is a known, documented regression for this arm.

---

## 4. Does anything now prevent a third fast-path-skips-a-clause instance?

**No — nothing structural. Measured, not vibes:**

- The JOIN dispatch arm's entry guard is `record.row_count() > 1 &&
  joins.is_some() && window.is_none()`
  (`src/velostream/sql/execution/processors/select.rs:848`). It checks the
  *input batch size*, the *presence of joins*, and *no window clause* — it does
  NOT consult `group_by`, `having`, `distinct`, `limit`, or the SELECT list
  shape. The #1413 fix (`apply_where_to_joined_batch`) restored exactly one
  clause (WHERE); the SELECT clause is the #1987 drop; nothing about the
  pattern's root cause has changed.
- The reachability amplifier: `find_join_plan_node`
  (`processors/join_plan.rs:29-48`) descends through `Project`, `Filter`,
  `Aggregate`, `Window`, `Limit`, `Sort`, `Subquery`, `CreateStream`,
  `CreateTable` to find the inner Join, and `is_eligible_join_stream_stream`
  (`processors/join.rs:1521`) then checks ONLY the Join node's own shape (Inner/
  Left + equi + bare scans). The wrappers above the Join are invisible to the
  eligibility decision.
- Measured consequence 1 (this worktree, test
  `repro_1987_limit_join_batch`): `SELECT a.auction_id, r.tier FROM auction a
  JOIN person r ON a.seller = r.person_id LIMIT 2` over a 3-row probe returned
  **3 rows — LIMIT silently dropped** on the batch stream-stream arm.
  `ctx.limit_remaining` is never consulted on this arm (the LIMIT budget lives
  in `LimitProcessor::should_process_record`, which the arm never calls).
- Measured consequence 2 (same worktree, test
  `repro_1987_groupby_join_batch`): `SELECT a.category, COUNT(*) AS cnt FROM
  auction a JOIN person r ON a.seller = r.person_id GROUP BY a.category`
  returned **0 records with 3 row_errors** — but the error is NOT the
  projection drop; it is `Stream source 'person' cannot be joined inline
  … run_interval_join_event_path`, i.e. the N>1 fan-out path rejects
  stream-stream joins for this shape and the batch arm never fires for
  GROUP BY (or the query routes elsewhere entirely). Recorded as measured
  behaviour; classification of the exact route needs the implementer's trace,
  but the key point stands: the dispatch gate did not account for GROUP BY
  before the attempt errored out downstream.
- The #1987 defect itself is live evidence the pattern's guardrail is a
  convention, not a mechanism: every new `return` from a dispatch arm must
  hand-enumerate the clauses it must not skip.

**What would prevent it (reasoned):**

1. **Clause-aware dispatch gate**: `is_eligible_join_stream_stream` /
   `is_eligible_join` currently inspect only the Join node. Extend the gate to
   the whole plan — return eligible ONLY when the wrappers above the Join are
   exactly the shapes the arm can honour (pure pass-through Project; nothing
   else). A `Limit`/`Aggregate`/`Sort`/`Distinct` wrapper above the Join must
   make the arm *ineligible* (fall through to the per-row path, which composes
   every clause), or the arm must route its output through a composition pass
   (mechanism B) before returning. This is fail-loud at the plan-time boundary
   and matches the architecture principle "resolve at plan time, not on the
   hot path".
2. **EXPLAIN parity contract**: `eligibility_status` (which feeds EXPLAIN's
   `batchable=` flag) must change in lockstep with `is_eligible` — the file
   already documents that requirement (`eligibility.rs:212-214`).
3. **A dispatch-arm contract test**: a unit test that walks every
   `ProcessorResult::record(...)`/early-return site in `SelectProcessor::process`
   with a clause-matrix query (SELECT subset + WHERE + LIMIT + DISTINCT) and
   asserts the output honours each clause — so the fourth instance of this
   family fails in CI, not in a user's topic.

---

## 5. Recommendation (REQUIRES MAINTAINER APPROVAL)

**Recommend Mechanism C — Arrow `RecordBatch::project`, mirroring
`select.rs:1731-1750` (#594 Case 6) — applied to BOTH batch-JOIN arms.**

This option did not exist in the first revision; it emerged from the review that
refuted its reasoning.

1. **It is the cheapest of the three, not a free one.** The shape is
   *resolve indices → `batch.project` → `from_batch`*, but read item 2 before
   costing it: the resolver must be **qualified-aware** (`resolve_col_indices`,
   imported at `select.rs:71`, is exact-match and insufficient on its own), and
   the system-column indices must be **appended by hand**. What C avoids is the
   per-row loop and per-row metadata threading — not all of the work. Roughly
   30 LoC, with `limit_projection.rs:132-141` as a literal template.
2. **System-column fidelity is NOT free — it must be written explicitly.**
   *(Corrected: revision 2 first claimed it was free. It is not.)*
   `compute_limit_project_indices` cannot be called from this arm: it takes a
   `plan::Schema`, reads `Expr::ColumnRef.index` resolved against that same
   schema, and is reachable only behind `is_safe_project_over_limit`, which
   requires a `Project{Limit{Scan{filters:[]}}}` shape. The join arm has none of
   those — the packed batch's schema is built at runtime by `pack_join_results`.
   `resolve_col_indices` returns **only** the requested data-column indices and
   appends nothing, and `StreamRecord::from_batch` **PANICS** when a required
   system column is missing (`builder.rs:1489-1508`). So an implementer must
   append `n_data + 0..SystemCol::COUNT` by hand, exactly as
   `limit_projection.rs:132-141` does. What C reuses is Arrow's
   `RecordBatch::project` — not the hardened helper.
3. **It still avoids the per-row rebuild**, which is the real argument for it.
   The `interval_join.rs` template threads every system column per row by hand
   (the `#1460` `keys=None` trap); Arrow `project` moves whole columns and
   cannot lose one it was told to carry. That advantage survives item 2's
   correction — the append is one loop, not per-row metadata threading.
4. **It is zero-copy and batch-native**, so it does not regress the very fast
   path this arm exists to serve — unlike the per-row rebuild in the
   `interval_join.rs` template.

**Mechanism B is not rejected, but it is a larger, separate change.** Decoupling
`apply_post_join_select` means a new cross-module call site, re-entering
`process_scoped` from inside `process` (limit budget, alias cache, rows-window
state), AND changing `interval_join_needs_post_join_select`, which today returns
false for exactly the query shape #1987 reproduces. Its architectural argument —
one composition pipeline instead of clause-by-clause patching (§4) — remains the
right long-term direction and should be its own issue.

**Mechanism A (the `interval_join.rs` row-rebuild template) is now rejected.** It
is the only option that hand-rolls per-row metadata, and Mechanism C obtains the
same result without it.

### Required by any implementation

- **A plan-time ELIGIBILITY gate — this is the one that bites.** The Case-6
  template is protected by `is_safe_project_over_limit`, which rejects **alias
  renames** (`SELECT a.x AS y`) and **computed expressions**, letting them fall
  through to the per-row path. **The JOIN arms have no SELECT-shape fall-through.** There *are*
  fall-throughs between `select.rs:848` and those returns — non-`Inner` kind
  (`:855`), `!is_eligible_equi_conditions` (`:866`), a `state_tables` miss
  (`:919`), multi-join (`:1048`) — but every one is on **join-shape or state**
  grounds. No gate anywhere on the path inspects the select list, so once the
  join shape qualifies, `:979`/`:1086` return regardless of the projection.
  (`is_eligible` Case 7, `eligibility.rs:176-190`, returns `true` for any
  `Project { … Join … }` **without inspecting the Project's exprs**.) `RecordBatch::project` can neither rename a column nor
  evaluate an expression, yet `SelectField::AliasedColumn` and
  `SelectField::Expression` both reach this arm today. Without a gate, C
  mis-names aliased columns and drops computed ones — the same
  silent-clause-drop family as #1987 itself. This is §4's recommendation #1 and
  it must be carried into the implementation.
- **A qualified-name-aware resolver.** `resolve_col_indices` is an exact
  `schema().index_of(name)` with a hard error on miss, while the packed batch
  carries canonical **qualified** names. An unqualified
  `SELECT auction_id, tier FROM auction a JOIN person r …` — legal, and
  exercised in `projection_pushdown_test.rs:512` — hard-errors. The
  interval-join template uses `resolve_field_at` (qualified/suffix/system-aware)
  precisely because exact match is insufficient post-join — but note it is a
  **value** resolver returning `Option<FieldValue>` (`interval_join.rs:902`),
  not an index resolver, so it demonstrates the required matching semantics and
  cannot be reused as-is for `RecordBatch::project`.
- **Output-schema parity with the N=1 path.** Arrow `project` preserves *source*
  column names, so C spells output columns as the packed batch does, while the
  per-row path keys them by the select-list spelling. These coincide for
  qualified selects and diverge for unqualified or aliased ones;
  `batch_join_where_test.rs`'s chunk-invariance oracle is what would catch it.
- **Both arms.** `select.rs:979` (stream-TABLE) and `:1086` (stream-STREAM) both
  call `apply_where_to_joined_batch` and then return; both drop the projection.
- **`batch_join_where_test.rs` must be updated.** It pins the current wrong
  behaviour deliberately — its comment states the projection is dropped and why
  asserting the bare name would re-hide it. Post-fix, both the qualified-spelling
  assertions and the `collect_sorted_int_field` rationale change meaning.
- **No `_TRACEPARENT` companion change is required under C** (it is preserved by
  construction), and none was ever required for the reason the first revision
  gave — see §0.
- **Wildcard `SELECT *` must short-circuit** before index resolution, as the
  interval-join template does.

### Out of scope, worth its own issue

The measured GROUP-BY-over-join route failure ("cannot be joined inline") in §4
is a separate reachability question and is not addressed here.

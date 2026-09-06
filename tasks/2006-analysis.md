# #2006 Analysis — per-row span construction: cardinality options, sampling, sibling-site classification

**Status**: analysis only, no code changed. Verified against `8daed48e1` (branch `fix/2006-auto`).
**All findings below cite the command or file:line that grounds them. Items marked
*(reasoning)* are analysis, not measurement.**

---

## 0. Ground truth recap (verified, per the brief's "do not re-derive")

The brief's four-row status table is confirmed:

- `COL_TRACEPARENT` / `SystemCol::Traceparent` — `stream_record/mod.rs:56`,
  confirmed in `SystemCol::NAMES` by `tests/unit/sql/execution/phase8_row_errors_traceparent_test.rs:174`.
- `traceparent_at(row_idx)` — `accessors_per_row.rs:190-209` (StringArray downcast + null check).
- Producer materialises per row — `datasource/kafka/reader.rs:1873`
  (`traceparents.push(record.traceparent_at(row)…)` inside `for row in 0..record.row_count()`
  in `concat_partition_group`, which `coalesce_by_partition` (reader.rs:1784) feeds).
- Span construction still reads row 0 — `server/v2/partition_receiver.rs:1023`
  (`let headers = record.headers_at(0);` inside the per-record loop at :1020).
  The DLQ path 112 lines below uses `record.traceparent_at(row_index)` (:1135) —
  the reference pattern for per-row reads.

**Why the per-row column matters here** (new evidence, not in the brief): the
coalescer preserves each source message's *own* traceparent. `concat_partition_group`
extracts `headers_at(row)` and `traceparent_at(row)` per row (reader.rs:1866-1874),
so a coalesced multi-row record is **heterogeneous by construction** — N Kafka
messages, N distinct upstream traceparents. This directly contradicts the comment
at `batch_processing.rs:108-110`, which claims "Kafka batches are also coalesced
per-partition with one traceparent per partition group, so row 0 is again
representative." That comment is wrong for Kafka (right only for file sources —
see §3.2). Any fix that trusts that comment will re-introduce the smearing.

Also relevant: #1198 (closed) names this exact failure in its own body —
"the traceparent smearing bug this same restructuring introduced and #1198
also fixes". #1198 fixed the producer/watermark side; the span-construction
consumer side is the unfixed half.

**Test-gap note** (how this slipped through Phase 8): the acceptance criterion
"4 source records with distinct traceparent headers → 4 spans with distinct trace
IDs" was implemented as `phase8_row_errors_traceparent_test.rs:273`
(`traceparent_extracted_from_kafka_headers_end_to_end`), which asserts only that
the **column** is stamped per-row by `stamp_per_row_traceparents`. No test
exercises span construction over a multi-row record. The column had tests; the
consumer did not.

---

## 1. Span cardinality options — costs and losses

Shared context for all three options (all *reasoning*, grounded in the cited code;
no profiling was run for this analysis):

- Spans are built by `TelemetryProvider::start_record_span` (`telemetry.rs:668-782`):
  builds a `Vec<KeyValue>` of ~15-20 attributes (query metadata extracted at job
  startup is re-cloned per span), a `format!("process:{}")` label, and an OTel
  `SpanBuilder::start[_with_context]`. The span is handed to `QueuedSpanProcessor`
  (async queue, `traces_queue_size` default 16 384, `queue_config.rs:75`).
- Sampling gate upstream of span creation: `extract_trace_context_if_sampled`
  (`trace_propagation.rs:187-244`) is parse + dice-roll only, no span alloc.
- Realistic batch sizes: Kafka `max_poll_records` default 500, presets 100-2000
  (`kafka/consumer_config.rs:166,420,435,467,478`); coalescing groups per
  partition, so a record's row count is "messages from one partition in one poll".
- Default sampling: `SamplingMode::Staging` = 0.25 (`config.rs:751-752,878`);
  Debug 1.0, Dev 0.5, Production 0.01.

### (a) N spans per record — one per row (literal #783 reading)

- **Cost per record**: one span build per row — attribute-vec + label allocation
  plus OTel builder per row. Span volume becomes proportional to *rows*, not
  records: a poll of 500 Kafka messages coalesces into k records (one per
  partition) and produces ~500 spans instead of ~k. At the 800K rec/s target
  (`partition_receiver.rs:986` docstring), Debug sampling (1.0) under option (a)
  means ~800K spans/s against a 16 384-deep export queue with 500 ms flush —
  the queue-pressure backoff (`effective_sampling_ratio`,
  `observability_helper.rs:40-59`) would be permanently engaged and the
  adaptive floor (5% of base) would silently make "sampled" traces sparse.
  *(reasoning, not measured — but the queue arithmetic follows directly from
  the cited constants.)*
- **What it buys**: full per-message trace identity — the only option in which a
  downstream operator can follow one Kafka message end-to-end, which is the
  literal Phase-8 acceptance criterion ("4 source records with distinct
  traceparent headers → 4 spans with distinct trace IDs").
- **What it loses**: nothing semantically; it loses the current batching economy.
- **Implementation shape**: move the span construction inside a
  `for row in 0..record.row_count()` loop, replacing `headers_at(0)` with
  `traceparent_at(row)` + `headers_at(row)`. The `set_record_metadata` enrichment
  (partition_receiver.rs:1047 → `telemetry.rs:1234-1267`) would need per-row
  offsets/keys too (see §3.4). Output-inject loop (B4, :1093-1102) is already
  per-output-record and needs no change.

### (b) One span per record, per-row links or attributes

- **Cost per record**: unchanged from today — one span build per record. Plus a
  small attribute cost: either a single attribute carrying a delimited list of
  row trace IDs, or one OTel `Link` per distinct upstream trace (Links are
  first-class OTel; `SpanBuilder::with_links`).
- **What it buys**: the record's span is parented to row 0's trace (or none), but
  rows 1..N remain *discoverable* — a consumer that knows the message's upstream
  trace ID can find the processing span via the Link/list attribute. Misattribution
  becomes "attached to the wrong trace, linked to the right one" instead of
  silently wrong.
- **What it loses**: the direct parent-child chain for rows 1..N. A trace waterfall
  for message #k shows its Kafka-consume span and the batch's processing span as
  siblings-with-link, not parent-child — trace-tree queries ("show me everything
  downstream of message k") need Link-aware tooling (Tempo supports links, but
  service-graph processors and many dashboards don't traverse them).
- **Verdict on cost**: cheapest to run, moderate to implement (attribute/Link
  plumbing in `start_record_span`, one extra loop over rows at the receiver).

### (c) One span per distinct `traceparent` within the record

- **Cost per record**: one span per distinct upstream trace in the batch. The
  grouping itself is cheap *here* (see below), but the result is **data-dependent**:
  in a topic where all messages in a poll share one upstream trace (batch producer),
  cost collapses to (b); in a fan-in topic (many producers), cost approaches (a).
- **Is grouping cheap here?** Yes — the data is already columnar:
  `traceparent_at(row)` is a StringArray index (accessors_per_row.rs:190-209); a
  single pass over rows building a `FxHashMap<&str, SmallVec<usize>>` is O(N) with
  no allocation per row beyond the map. W3C traceparent strings are
  fixed-shape (`00-<32hex>-<16hex>-<2hex>`), so equality-compare is cheap.
  *(reasoning — but the accessor costs are cited, and the pass is strictly
  cheaper than the per-row span builds it would gate.)*
- **What it buys**: correct trace grouping at bounded cost — each span is
  parented to a *real* upstream trace that actually contributed rows, and the
  span can carry `record.row_start`/`row_end` or a count attribute.
- **What it loses**: one-to-one span↔message identity (a span covers k messages,
  not 1); a per-message waterfall inside the batch is not reconstructible from
  spans alone (needs the DLQ-path identity or a Link to each distinct trace only).
- **Edge case**: rows with `traceparent_at(row) == None` (no upstream context —
  file sources, or flag-less producers). They need a defined home: fold into the
  dice-roll path (one sampled-or-not decision for the null group) or one
  "unparented" span. Unspecified in #783.

### Comparative summary

| option | span volume vs today | per-message traceability | grouping cost | data-dependence |
|---|---|---|---|---|
| (a) N spans | ×N rows (sampling-gated) | full | none | none |
| (b) 1 span + links/attrs | 1× | via links/attrs only | none | none |
| (c) spans per distinct trace | 1..N (usually ≪N) | per-trace, not per-message | O(N) pass | high |

---

## 2. Sampling is a SEPARATE question (decided independently)

Today: `extract_trace_context_if_sampled(&record.headers_at(0), ratio)` — one
decision per record, applied to all N rows (partition_receiver.rs:1022-1043;
dual_input_partition_receiver.rs:505-530; batch_processing.rs:101-131).

The orthogonal matrix (cardinality × sampling granularity):

| | 1 sampling decision | N sampling decisions |
|---|---|---|
| **1 span** | today's behaviour (row 0 decides for all) | rows disagree → single span cannot represent per-row sampling; needs (b)'s Link/attr encoding |
| **N spans** | all row-spans inherit row 0's decision — *worse* than today (N spans, one roll) | fully per-row: only sampled rows get spans |

Key structural point: **with upstream traceparents present, sampling is mostly
not a dice-roll at all** — `extract_trace_context_if_sampled` returns
`Sampled`/`NotSampled` from the upstream *flag bit* (trace_propagation.rs:197-233);
the dice roll only fires for rows with **no** traceparent. So "per-row sampling"
splits into two distinct sub-decisions:

1. **Upstream-flag rows** (heterogeneous by construction — different producers
   set different flags): per-row honouring is not a cost decision, it is the
   correctness decision. Row k's upstream said flag=00 → row k must not be
   traced. Today row 0's flag decides for all N. This is a misattribution bug
   independent of cardinality, and it exists under option (b) and (c) too
   unless the per-row flag scan happens anyway.
2. **No-traceparent rows** (e.g. file-coalesced, homogeneous — see §3.2): a
   single dice-roll for the homogeneous group is *fine* and is what (b)/(c)
   naturally do. Per-row rolls would burn RNG work for an identical decision.

Consequence for the cardinality decision: **any option must at minimum scan
per-row flags** (cheap: `traceparent_at(row)` + last-char check, or reuse the
extract-parse) to avoid the flag-smearing bug. Once that scan exists, option
(c) gets its grouping map nearly free, and option (a) gets its per-row decisions
nearly free. The marginal cost of per-row sampling over per-record sampling is
therefore small in all options; the *marginal cost* difference between options
is dominated by span construction, not sampling.

*(All reasoning, grounded in the cited extract logic and flag semantics; no
measurement.)*

---

## 3. Classification of the other production sites

Scope: the five files the brief lists, plus two additional `*_at(0)` sites the
mandated grep surfaced (`trace_helpers.rs:67`, `batch_processing.rs:113`).

Evidence command (run, output captured to `/tmp/2006-sites.log`):

```
grep -rn "headers_at(0)\|offset_at(0)\|key_at(0)" \
  src/velostream/server/ src/velostream/observability/
```

13 hits: 8 code, 5 comments. Every classification below cites the call chain.

### 3.1 `dual_input_partition_receiver.rs:506` — `headers_at(0)` — **SAME DEFECT**

```rust
// dual_input_partition_receiver.rs:504-530
StreamEvent::Record(record) => {
    let trace_hdrs = if tracing_enabled {
        let headers = record.headers_at(0);            // row 0 for the whole record
        let decision = trace_propagation::extract_trace_context_if_sampled(&headers, sampling_ratio);
        ... start_record_span(...) ...
        build_pending_trace_headers(span.as_ref(), not_sampled_new)
```

Consumers of the result: `per_event_headers` vec → `process_event_batch`
(`event_dispatch.rs:97-235`), which passes each record's single header map into
`engine.execute_with_source(ctx, &source, &record, staged)` (:175-176) — where
"#1598 Phase 1 … for interval joins the value flows to `merge_records_batch`'s
per-row `_headers` fold" (event_dispatch.rs:169-174). So one row-0-derived map
is folded into **every row's** output headers.

Record provenance: this receiver consumes `SourceEvent::Record` from
`SourceCoordinator`, whose readers are `DataReader::read()` implementations —
for Kafka, `KafkaDataReader::read` (reader.rs:1503) → `poll_records` →
`coalesce_by_partition` (reader.rs:1470). Heterogeneous multi-row records reach
here.

**Classification: same defect** — rows 1..N are attached to row 0's trace
(or row 0's not-sampled decision), and the row-0 map is folded into all rows'
headers on the interval-join merge path. The comment at :491-496 ("Trace
propagation is correct") is wrong for N>1.

### 3.2 `observability_helper.rs:157` and `:212` — `headers_at(0)` — **row-0-CORRECT**

Both are inside `n <= 1` early branches:

- `:144-166` (`inject_record_trace_context`): `let n = record.row_count(); if n
  <= 1 { let existing = record.headers_at(0); … return; }` — N>1 falls through to
  the per-row loop at :171-185 (`record.headers_at(i)` per row).
- `:209-243` (`inject_not_sampled_context`): same shape — `n <= 1` branch at
  :211-222, per-row loop at :226-242.

**Classification: genuinely row-0-correct** — `n <= 1` means the only row is
row 0. Two residual notes, neither a defect in these sites:

1. **N=0**: `headers_map_at` (arrow_builders.rs:301-326) returns an empty map for
   null rows, and `sys_col` (accessors_per_row.rs:58-64) indexes positionally into
   always-present system columns — so `headers_at(0)` on an empty batch returns an
   empty map rather than panicking, but the code then rebuilds a record with
   headers it never had. Whether N=0 records can reach these functions was NOT
   established (I could not find a producer of N=0 StreamRecords on these paths;
   #1695 hardened DML/select guards against N=0, which suggests the shape is
   considered reachable somewhere). Flagging as *undetermined, low stakes*.
2. **Semantic asymmetry with the fix direction**: these injectors write the *same*
   traceparent into every row of an N>1 record (:167-185). If #2006 lands
   per-row span construction (option a/c), these writers become the mechanism
   that re-homogenises output headers — correct for outputs (all outputs of one
   engine call belong to one processing decision), but note it means the
   `has_header("traceparent", 0)` guard at partition_receiver.rs:1094 checks only
   row 0 of the output. That is row-0-correct today *because* the injector wrote
   the same value to all rows; under per-row span options the invariant
   "output rows carry one traceparent" may stop holding and :1094 would need a
   per-row check. **Interaction to revisit when cardinality is chosen.**

### 3.3 `telemetry.rs:1248, 1251, 1256` — `offset_at(0)`, `key_at(0)` — **SAME DEFECT (bounded blast radius)**

`RecordSpan::set_record_metadata` (telemetry.rs:1234-1267):

```rust
if record.offset_at(0) > 0 { span.set_attribute(RECORD_OFFSET, record.offset_at(0)); }
let key_value: Option<String> = record.key_at(0).map(…) .or_else(|| primary_key_field…get_field(field)…);
```

Callers (grep evidence: `grep -rn "set_record_metadata" src/`):
- `partition_receiver.rs:1047` — the per-record span enrichment, called when
  `tracing_enabled` per record (which may be multi-row — §1a).
- `batch_processing.rs:135` — same shape on the V1 path.

`get_field` (used in the PRIMARY KEY fallback) is `field_at(name, 0)`
(accessors_record.rs:220-234) — row 0 again.

**Classification: same defect** — under multi-row records, the span's
`record.offset`/`record.key` attributes describe row 0 regardless of which rows'
trace context the span carries. Bounded: these are span *attributes* (diagnostic
metadata in Tempo), not routing identity — nothing branches on them. Under
option (a) (per-row spans) the fix is mechanical (pass `row_idx`); under (b)/(c)
the attributes are *defined* per-batch and a representative-row value is arguably
correct, but should be documented as such. Also note `record.partition` and
`record.topic` (:1236-1247) are record-level invariants (coalescing groups by
partition, reader.rs:1795-1800) — correctly read at record level.

### 3.4 `source_coordinator.rs:473, 478, 479` — `extract_event_time_ms` row 0 — **SAME DEFECT (correctness class, not observability)**

```rust
// source_coordinator.rs:453-484
pub fn extract_event_time_ms(record: &StreamRecord, event_time_field: &str) -> i64 {
    if let Some(field_value) = record.get_field(event_time_field) { … }   // row 0 (get_field = field_at(name,0))
    if let Some(et) = record.event_time_at(0) { return et; }              // :473 row 0
    if record.timestamp_at(0) > 0 { return record.timestamp_at(0); }      // :478-479 row 0
    0
}
```

Sole caller: `source_coordinator.rs:766` in the reader task loop, feeding:

1. **HWM advancement** (:767-777): `my_hwm.fetch_max(event_time)` and
   `stats.left_hwm/right_hwm.fetch_max(event_time)`.
2. **Skew throttling** (:782-794): `event_time - other_hwm <= threshold` decides
   whether the reader sleeps in a 10 ms loop (skew_throttle, :952-998).
3. The `min(left_hwm, right_hwm)` shared-watermark combination consumed by the
   join coordinator for eviction (config doc :320-326).

**Classification: same defect, and the most consequential one in the set** —
it is not observability; it feeds watermark/eviction and throttling:

- **HWM understatement**: with a multi-row record, only row 0's event time is
  considered. If rows 1..N are later (higher event time), the HWM advances more
  slowly than the data warrants → downstream window/eviction decisions stall.
  This is *exactly* the class #1198 fixed one layer down: `compose_watermark`
  (reader.rs:270-303) was explicitly rewritten to per-row scanning ("A row-0-only
  `.event_time_at(0)` read would silently ignore every row after the first,
  understating the true per-partition HWM" — reader.rs:272-275), and the
  coordinator's own doc claims "Always data-derived — see extract_event_time_ms"
  (:95) while the function reads one row. The coordinator path is the duplicate
  of the fixed bug, not yet fixed.
- **Note**: the watermark that flows through the *coordinator* (per-source HWM →
  `min(left,right)`) and the one `compose_watermark` produces (per-partition
  strict-min, reader.rs:1531) are different mechanisms on different receivers;
  the #1198 fix covers the latter only.
- **Mitigating factor (undetermined weight)**: priority 1 of the chain is
  `record.get_field(event_time_field)` — the *payload* event-time field, which
  for single-field-per-row payloads is also row 0 only (get_field = field_at(0)).
  So even the payload path under-reads. I could NOT establish whether the
  coordinator is reachable in configurations where multi-row records are common
  (its `batch_size: 1000` config and the join-oriented design suggest yes, but I
  found no production wiring proving the coordinator is used with coalescing
  Kafka readers in deployment). **Undetermined reachability; the defect shape
  itself is certain.**

### 3.5 (additional, found by the mandated grep) `trace_helpers.rs:67` — `extract_first_sampled_trace_context` — **row-0-CORRECT for its purpose (documented limitation) : honestly "undetermined-but-benign"**

```rust
// trace_helpers.rs:62-75
pub fn extract_first_sampled_trace_context(records: &[Arc<StreamRecord>]) -> Option<SpanContext> {
    for record in records {
        let headers = record.headers_at(0);      // row 0 of each OUTPUT record
        if let Some(ctx) = trace_propagation::extract_trace_context(&headers) {
            if ctx.trace_flags().is_sampled() { return Some(ctx); }
        }
    }
    None
}
```

Called from: `partition_receiver.rs:604`, `dual_input_partition_receiver.rs:785`,
`simple.rs:1136`, `transactional.rs:1031,1066` — all to parent the **Producer
span** (one per sink write, `start_producer_span`, telemetry.rs:792-830; doc
:791 "parent_context — Upstream trace context from **the first sampled record**
in the batch").

The function's name and contract are "first sampled trace" — reading row 0 of
each output record and returning the first sampled one is exactly its contract.
**Classification: row-0-correct by design** — the Producer span is a batch-level
CLIENT span; one parent is chosen arbitrarily-but-deterministically from the
batch. Caveat for the cardinality decision: if option (a) lands, the natural
refinement is one Producer span per distinct trace (mirroring (c)); the current
single-parent shape would then under-link downstream edges for rows 1..N's
traces. Not a defect today; a consequence to note under (a).

### 3.6 (additional) `batch_processing.rs:113` — `headers_at(0)` in V1 `process_batch` — **SAME DEFECT, with a wrong comment**

```rust
// batch_processing.rs:101-131
let (mut record_span, not_sampled_new) = if tracing_enabled {
    // ADR-707 Phase 9c: file sources stamp … EVERY row's … traceparent …
    // Kafka batches are also coalesced per-partition with one traceparent
    // per partition group, so row 0 is again representative. …
    let headers = record.headers_at(0);
```

Callers: `simple.rs:1038`, `transactional.rs:917` (V1 processor paths); records
arrive via `io_context.read_records` → `KafkaDataReader::read` → coalesced
multi-row (verified chain: io_context.rs:321-330 → reader.rs:1503 → reader.rs:1470).

The comment's Kafka claim is **false** (see §0: the coalescer preserves per-row
traceparents, reader.rs:1866-1874). The file-source half is **true**: file
sources stamp the *same* file-root traceparent into every row
(`file/reader.rs:1567-1599`, `stamp_file_root_traceparent` builds
`headers_by_row` with one `tp` inserted into every row, plus
`.with_traceparent(Some(&tp))`). So for file/IPC-mmap-coalesced records row 0 IS
representative; for Kafka it is not. The comment acknowledges the heterogeneous
case exists ("If a future source produces … heterogeneous traceparents, this
would need per-row fan-out below") — it is not future, it is current Kafka.

**Classification: same defect** (Kafka path), masked by a wrong comment.

### 3.7 Summary table

| site | read | classification | confidence |
|---|---|---|---|
| `partition_receiver.rs:1023` | `headers_at(0)` | **same defect** (the brief's primary) | certain — coalescer is per-row |
| `dual_input_partition_receiver.rs:506` | `headers_at(0)` | **same defect** (incl. per-row header fold on join path) | certain — same chain |
| `observability_helper.rs:157` | `headers_at(0)` | row-0-correct (`n <= 1` guard) | certain |
| `observability_helper.rs:212` | `headers_at(0)` | row-0-correct (`n <= 1` guard) | certain |
| `telemetry.rs:1248,1251,1256` | `offset_at(0)`, `key_at(0)` (+`get_field` fallback) | **same defect** (span attributes, diagnostic-only) | certain |
| `source_coordinator.rs:473,478,479` | `get_field`/`event_time_at(0)`/`timestamp_at(0)` | **same defect** (HWM/skew-throttle correctness class; reachability undetermined) | shape certain; deployment reachability undetermined |
| `trace_helpers.rs:67` | `headers_at(0)` | row-0-correct by contract ("first sampled") | certain |
| `batch_processing.rs:113` | `headers_at(0)` | **same defect** (Kafka); row-0-correct (file); comment asserts the opposite of reality | certain |

---

## 4. Recommendation — **requires maintainer approval**

*(This is a recommendation, not a decision. The cardinality decision is the
maintainer's, per the brief.)*

**Recommend option (c) — one span per distinct `traceparent` within the record —
with per-row flag honouring, as the default; keep (a) available behind a config
knob for Debug-mode full-fidelity tracing.**

Reasoning:

1. **Correctness first, economy second.** The bug is misattribution (rows join
   the wrong trace), not missing spans. (c) eliminates misattribution for every
   distinct upstream trace while bounding span volume by *distinct traces*, not
   rows — the grouping pass is O(N) over an Arrow StringArray with no per-row
   allocation, and it reuses the per-row flag scan that §2 shows is required
   under ANY option to fix flag-smearing. The incremental cost of (c) over
   doing-that-scan-alone is small.
2. **(a) is the literal Phase-8 reading and the only per-message-traceable
   option, but its volume is unbounded by data shape** — at Debug sampling
   (1.0) and realistic poll sizes it multiplies span volume by average
   coalesced row count against a fixed 16 384-deep export queue with adaptive
   backpressure that would throttle permanently *(reasoning from cited
   constants, not measured)*. As an opt-in for local dev/full-fidelity
   debugging, that trade is the user's to make.
3. **(b) is the cheapest but does not fix the bug it ships with** — a single
   parented span with links still attaches the record's processing span to row
   0's trace in the trace tree; consumers without Link-aware tooling see
   exactly today's misattribution, plus links they may never look at. It is
   defensible only if the maintainer weighs span-export cost above per-trace
   correctness; the analysis above suggests the cost gap between (b) and (c)
   is small once the per-row scan exists.
4. **Sampling stays per-row-in-substance, one-roll-per-homogeneous-group in
   mechanics**: honour upstream flags per row (correctness), roll the dice once
   per no-traceparent group (economy). This is independent of the span-count
   choice and should be specified in the same decision, because it determines
   what `NotSampledNew` injection means for a multi-row record (today one
   flag=00 header is injected for the whole record — see
   `build_pending_trace_headers` → `inject_not_sampled_context`).
5. **Sibling scope**: fix `partition_receiver.rs:1023`,
   `dual_input_partition_receiver.rs:506`, `batch_processing.rs:113` (and
   correct its comment), and `telemetry.rs:1248/1251/1256` (thread `row_idx` or
   document batch-representative semantics) in the same change — they are the
   same defect on the same data path, and the fix's per-row scan is the shared
   primitive. Treat `source_coordinator.rs:473-479` as a **separate issue** —
   it is a watermark/eviction correctness bug (the #1198 class, one layer up),
   not an observability bug, and deserves its own reproduction test and
   reachability audit before anyone touches it. Leave
   `observability_helper.rs:157/212` and `trace_helpers.rs:67` alone
   (row-0-correct); do record the §3.2 note about the `has_header(...,0)` guard
   interaction in whichever issue lands the cardinality change.

**Enforcement precedent worth following**: #1683/PR #1695 enforced the N=1
invariant with `assert_n1_invariant`-style named helpers and debug_asserts
rather than comments. Whatever cardinality lands, the corresponding invariant
("this span covers rows X..Y with these upstream traces") should be carried by
the span's own attributes and asserted in a multi-row regression test —
mirroring `phase8_row_errors_traceparent_test.rs` but asserting on the **span
construction**, not the column, which is the test gap that let this ship.

---

## 5. Validation record (this analysis changed nothing)

- `git -C <worktree> status --porcelain -- src/` → empty (run after evidence
  gathering; re-run at the end, recorded in agent.log).
- `cargo check --no-default-features --manifest-path <worktree>/Cargo.toml` →
  tripwire run in background at session start; result recorded in agent.log.
- Evidence commands: the mandated `grep -rn "headers_at(0)\|offset_at(0)\|key_at(0)"
  src/velostream/server/ src/velostream/observability/` → `/tmp/2006-sites.log`;
  caller greps for `set_record_metadata`, `extract_event_time_ms`,
  `extract_first_sampled_trace_context`, `make_producer_span`, `process_batch`,
  `coalesce_by_partition`; targeted Reads of every cited file:line.
- **Nothing was measured.** All cost statements are marked *(reasoning)* and
  derive from cited constants (`max_poll_records` 500/2000, `traces_queue_size`
  16 384, `max_queue_size` 65 536, `max_export_batch_size` 2 048,
  `SamplingMode` ratios 1.0/0.5/0.25/0.01) and cited code shapes.

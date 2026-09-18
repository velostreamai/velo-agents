# #2006 — Stage-1 ANALYSIS ONLY: per-row span construction never shipped

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2006
BRANCH:   fix/2006-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## THIS TASK WRITES NO CODE

You produce a **written analysis**, posted as a comment on #2006. If you find
yourself editing a `.rs` file, STOP — you have misread the task.

The fix direction is already pinned by #783. What is NOT decided, and what this
analysis exists to inform, is **span cardinality** — and that decision is the
maintainer's, not yours.

## The finding, already verified — do not re-derive it

ADR-707 Phase 8 (#783, closed) scoped:

> Per-row span construction at `PartitionReceiver` consumes the column.

Three of four parts shipped. Verified against `8daed48e1`:

| part | status | evidence |
|---|---|---|
| `_traceparent` system column | shipped | `COL_TRACEPARENT`, `stream_record/mod.rs:56` |
| per-row accessor | shipped | `traceparent_at(row_idx)`, `accessors_per_row.rs:190` |
| producer materialises per row | shipped | `kafka/reader.rs:1873` |
| **span construction consumes it** | **NOT shipped** | see below |

```rust
// partition_receiver.rs:1020 — freshly grep -n verified
for (record_index, record) in batch.iter().enumerate() {
    // Per-record sampling: check traceparent flag or roll dice
    let (mut record_span, not_sampled_new) = if tracing_enabled {
        let headers = record.headers_at(0);                    // <-- row 0, whole record
        let sampling_decision =
            trace_propagation::extract_trace_context_if_sampled(&headers, sampling_ratio);
```

The DLQ path 112 lines below **already** consumes the column correctly — that is
your reference pattern for what "per-row" looks like here:

```rust
// partition_receiver.rs:1135
record.traceparent_at(row_index).map(|s| s.to_owned());
```

Post-Phase-5c a `StreamRecord` is a multi-row partition-coalesced batch: N Kafka
messages, each with its own upstream `traceparent`. Reading row 0 means every row
joins row 0's trace, and one sampling decision covers all N.

## What to produce

### 1. Span cardinality options, with costs

Enumerate at minimum:

- **(a) N spans per record** — one per row. Literal reading of #783. What does it
  cost per record on this path? How many spans per second at realistic batch
  sizes?
- **(b) One span per record, per-row links or attributes** — cheaper, keeps
  batch structure visible. What is lost for a consumer trying to follow one
  message?
- **(c) One span per distinct `traceparent` within the record** — rows from the
  same upstream trace group. Cost is data-dependent. Is that grouping cheap to
  compute here?

For each: cost on the per-record hot path, and what it loses. Say which you can
measure and which you are reasoning about — mark reasoning as reasoning.

### 2. Sampling is a SEPARATE question

`extract_trace_context_if_sampled` is called once per record today. Whether
sampling becomes per-row is a **distinct decision** from how many spans exist —
you could have one span and per-row sampling, or N spans and one sampling roll.
Answer it separately. Do not fold it into the cardinality answer.

### 3. Classify the other four production sites

Each is the same `*_at(0)`-for-the-whole-record shape. For each, decide:
**genuinely row-0-correct** (and why), or **the same defect**:

```
src/velostream/server/v2/dual_input_partition_receiver.rs:506   headers_at(0)
src/velostream/server/processors/observability_helper.rs:157    headers_at(0)
src/velostream/server/processors/observability_helper.rs:212    headers_at(0)
src/velostream/observability/telemetry.rs:1248,1251,1256        offset_at(0), key_at(0)
src/velostream/server/v2/source_coordinator.rs:473,478,479      extract_event_time_ms row 0
```

"Undetermined, and here is precisely what I could not establish" is a valid and
useful classification. Guessing is not.

### 4. A recommendation

State one, with reasoning, **explicitly marked as requiring maintainer
approval**.

## Blast radius — why you must NOT sweep

`headers_at(0)` is **330 refs across 112 files** (src + tests + examples). The
overwhelming majority are single-row by construction and correct. The five files
above are the production scope. **Any instinct to bulk-rewrite is wrong** — that
count is exactly why this is an analysis task first.

## Context you should read

- **#934** — the class. Note its three shapes and that its enumeration greps
  cannot find shape 3.
- **#1683 / PR #1695** (merged 2026-08-15) — the prior sweep of the
  `iter_rows().next().expect("N=1")` shape. Its enforcement is a named helper
  (`assert_n1_invariant`), not `debug_assert_eq!` — worth seeing as precedent for
  how this codebase enforces such an invariant.
- `~/.claude/rules/velo-impl.md` §Streaming-compliance — invariants 1 and 5 are
  the ones at stake.

## Logging

Append to `agent.log` in the worktree root with real `date -u +%FT%TZ`
timestamps, **including a heartbeat every ~10 minutes**. A previous dispatch in
this session went 38 minutes with one log line and was killed as wedged. Silence
is indistinguishable from a stall.

## Validation

This task changes no production code, so validation is about proving that and
about grounding the claims you make.

**Prove you changed nothing:**

```
git -C /Users/neilavery/RustroverProjects/velostream-2006 status --porcelain -- src/
```

Must print **nothing**. Any `src/` entry means you violated the read-only rule.

```
cargo check --no-default-features   --manifest-path /Users/neilavery/RustroverProjects/velostream-2006/Cargo.toml
```

Must stay clean — it is unchanged from master, so this is a tripwire, not a gate.

**Ground each claim.** Every site you classify must cite the command that shows
it. Redirect to a file and grep it rather than relying on captured terminal
output:

```
grep -rn "headers_at(0)\|offset_at(0)\|key_at(0)"   /Users/neilavery/RustroverProjects/velostream-2006/src/velostream/server/   /Users/neilavery/RustroverProjects/velostream-2006/src/velostream/observability/   > /tmp/2006-sites.log 2>&1
```

For the cost question, if you measure rather than reason, say exactly what you
ran. If you reason, mark it as reasoning — an unmarked estimate presented as a
measurement is a finding against the analysis.

## Incremental commits — MANDATORY

Commit after each section you complete, prefixed `[#707] #2006 analysis:` —
not once at the end. A timeout or crash must never lose completed work. Small
commits are expected. Do NOT push. Do NOT open a PR.

Two runs on this umbrella have already lost everything — one to a timeout, one
to a wedge that produced 38 minutes of silence and zero commits. An analysis
held only in your context dies with the process. Write it to
`.agents/tasks/2006-analysis.md` in the worktree and commit as you go, so a
partial analysis survives.

## Deliverable

Post the analysis as a comment on #2006 (`gh issue comment 2006 -F <file>` —
this is the one case where you must `cd` into the worktree, since `gh` has no
`-C`). Commit the analysis file itself under `.agents/tasks/` if you write one.
Do NOT push. Do NOT open a PR. There is no PR — there is no code change.

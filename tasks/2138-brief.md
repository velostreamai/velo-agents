# #2138 — four join.rs sites let a hash map decide emitted column order

Parent: #1970 (SQL surface defects from the #1749 name-binding audit)
Follows: #1918 / PR #2121, which fixed the first instance of this class
Prerequisite: **already satisfied** — #2121 generified `project_into`

## 1. Target and isolation

Worktree: `/Users/neilavery/RustroverProjects/velostream-2138`
Branch: `fix/2138-join-layout-order`

Both are created for you by `velo-dispatch` off current `origin/master`.

**Do NOT `cd` into the worktree.** Use `git -C <worktree>`, `cargo
--manifest-path <worktree>/Cargo.toml`, and absolute paths with Read/Edit/Write.

Two exceptions: `gh` commands (no `-C`), and `zg query`, which resolves
`.zvec-grep` from the cwd and has no `--workspace` flag — run from anywhere else
and it silently answers from THAT tree's index (#2128). Use `rg`/`ast-grep` if you
prefer no index.

## 2. Fresh line numbers — cut at `ce56ad5be`

    src/velostream/sql/execution/processors/join.rs:651   for entry in layout.entries()   IN SCOPE
    src/velostream/sql/execution/processors/join.rs:712   for entry in layout.entries()   IN SCOPE
    src/velostream/sql/execution/processors/join.rs:933   for entry in layout.entries()   IN SCOPE
    src/velostream/sql/execution/processors/join.rs:965   for entry in layout.entries()   IN SCOPE
    src/velostream/sql/execution/processors/join.rs:1393  for entry in layout.entries()   *** NOT IN SCOPE ***
    src/velostream/sql/execution/stream_record/mod.rs:345      fn build_batch
    src/velostream/sql/execution/stream_record/builder.rs:143  pub fn project_into  (already generic)
    src/velostream/sql/execution/algorithms/hash_join.rs       first.keys().cloned().collect()  (leave alone)

Symbols are authoritative; numbers rot.

## 3. Pinned design — you do not choose

### 3a. Pass a lazy iterator. Not a map, and not a Vec either.

`build_batch` consumes `impl IntoIterator<Item = (FieldName, FieldValue)>` in a
**single** `for` loop, and sizes its `Vec`s from a fixed `TYPICAL_DATA_COLS` hint —
never from the input's length. So it needs neither `len()` nor a second pass, and
the correct form allocates **nothing**:

```rust
let fields = layout.entries().iter().map(|entry| {
    let value = match entry.provenance.side { /* … */ };
    (entry.name.clone(), value)
});
Ok(StreamRecord::project_into(fields, right_record))
```

Costs, per record, on a per-record join path:

| form | cost |
|---|---|
| today: `FxHashMap` | N hash computations + a bucket allocation, for a map whose only purpose is to be iterated once and dropped |
| a `Vec` | one allocation |
| **lazy iterator** | **none** |

A `Vec` is explicitly NOT the fix. It is better than the map and still wrong.

### 3b. Four sites, four shapes — no single pattern

The four differ in capacity hint (`with_capacity_and_hasher(layout.len(), …)` vs
`FxHashMap::default()`), in type annotation (some annotate
`FxHashMap<FieldName, FieldValue>`, some infer), in variable name
(`fields` vs `combined_fields`), and in the value expression.

**A regex attempt during #1918 DELETED a function** (`combine_records_with_nulls`)
and was caught only by the compiler.

So: **one commit per site**, with `cargo check --no-default-features --tests`
passing before you start the next, and one `AST-GREP-DECISION` line per site in
`agent.log` recording the pattern used. That makes the discipline auditable from
the diff — four commits touching one site each — rather than an unobservable rule
about editing technique. A single commit converting all four is a brief violation
even if the result is correct.

### 3c. Line 1393 is NOT in scope

It iterates `layout.entries()` to compute column **indices**, not to build a field
map. Leave it untouched and say so in your report — a reviewer counting five
occurrences and four edits needs to know the fifth was deliberate.

### 3d. What stays as it is, and why

- **`hash_join.rs`'s `col_names`** (`first.keys().cloned().collect()`) — genuinely
  schemaless. `first` is a `FieldMap` from a build-side table load with no schema
  to honour, and `from_explicit` explicitly sanctions hash order for that case.
  #2121 documented it so stability is not mistaken for a guarantee. Do not change
  the behaviour.
- **`stream_table_join.rs` (4 sites), `update.rs`, `show.rs`** — same shape, but
  their docs promise no order, so there is no correctness claim to honour. Out of
  scope unless the benchmark shows the allocation matters, and then separately.

## 4. Why this is not urgent, and why it is not nothing

None of the four is broken today. They agree because `FxHash` is seed-free and all
four paths share a key set — the order is stable **by accident**, not by contract.

That accident broke once already. `columnar/adapter.rs::batch_to_records` had the
identical defect: its doc promised "the order of fields … matches the schema
order" while an `FxHashMap` decided it. #1918's `EXPR$<n>` → `EXPR_<n>` rename
perturbed the hashes and it surfaced — **found by an ad-hoc flake probe, not by
the 11,797-test suite**. Fixed in #2121 (`1b7979745`).

These four are the same defect awaiting the next rename.

## 5. The test is the hard part — read this before writing it

A correctness test here passes both before and after, because the order is
currently correct by accident. So the `fail_to_pass` test has to **construct the
adverse case**: a join whose column NAMES hash such that `FxHashMap` iteration
order differs from `layout.entries()` order, then assert the emitted record's
column order matches the layout.

`join_emits_columns_in_layout_order_under_adverse_hash_order` must **FAIL at the
pinned base `ce56ad5be`** (hash order wins) and pass after. Prove the red per §7a.

**Put it in a new file:**
`tests/unit/sql/execution/processors/join/join_layout_order_test.rs`, registered in
that directory's `mod.rs` as `pub mod join_layout_order_test;` behind a `// #2138:`
comment — the convention every other entry there already follows.

**State which of the four sites the test exercises, and name the ones it does
not.** A test that constructs "a join" can prove one route while leaving
`combine_records_with_nulls_for_probe` (batch probe NULL) and
`combine_records_with_nulls_for_right_join` (RIGHT-join NULL-left) untouched. **Every REACHABLE site
needs a behavioural assertion** — reporting is the fallback for unreachable sites
only, justified by the reachability evidence in §6b. Note the two `pass_to_stay`
canaries cannot stand in: both are GROUP BY shapes that never route through
`JoinProcessor`, so they guard against a regression elsewhere, not coverage here.
This issue exists because a defect of exactly this class sat unnoticed behind tests
that covered a sibling path — "covered one of four, reported three" reproduces that
same failure.

`FxHash` is seed-free, so this is deterministic and findable — try column-name
sets until iteration order diverges from insertion order. **If you cannot find one
at a realistic column count (2–6), STOP and report.**

**And if the test comes back GREEN on the baseline, STOP — do not assume the key
set was wrong and try another.** The likelier cause is that the test routed
through a NON-TARGET path (`StreamTableJoinProcessor`, `IntervalJoinProcessor`, or
`JoinCoordinator`) and never reached the four sites at all. Three specified
measurement routes in this brief's own history failed exactly that way. Report the
green baseline together with the route you believe it took. Proceeding without a
proved red ships a test that pins nothing — the defect class this issue exists to
close. That would mean the defect
is not observable from a test, and the correctness half of this issue rests on the
doc contradiction alone — which is a caller decision, not a test to fudge.

Do not write a test that passes before and after and call it coverage. This issue
exists because that already happened elsewhere in this codebase.

### 5a. The tests that must stay green, by name

`velo-dispatch` sends you this brief and nothing else, so these are listed here in
full rather than left in the sidecar:

| test | why it is the canary |
|---|---|
| `parity_multi_col_key` | columnar byte-parity, compares column names **positionally** via `assert_eq!` on a `Vec` — so it fails if emitted order moves |
| `parity_computed_key` | same, for a computed group key |

If one of these fails, the emitted order genuinely moved for a shape that is
byte-pinned. Report which shape rather than adjusting the test.

An earlier draft also listed `test_self_join_alias_projection_resolves_correctly`
as a canary. It is not one: it constructs `IntervalJoinProcessor`, not
`JoinProcessor`, so it cannot observe these four edits at all. Removed rather than
left in place, because a canary that cannot see the change is worse than none.

## 6. Measurement — through a public path, because the constructors are private

The four sites are:

| line | function | visibility | fires on |
|---|---|---|---|
| 651 | `merge_join_records_with_aliases` | private | **matched** rows |
| 712 | `combine_records_with_nulls` | private | outer-join **unmatched** |
| 933 | `combine_records_with_nulls_for_probe` | private | probe **miss** |
| 965 | `combine_records_with_nulls_for_right_join` | private | right-join **unmatched** |

**Three of the four fire only on unmatched rows.** For urgency that matters: the
per-record cost lands on outer-join misses, not on every joined record. An earlier
draft said "all four are per-record join paths" — true but misleading. The
CORRECTNESS half applies to all four equally and is why the issue exists.

**Three earlier drafts of this brief each named a single route that does not
reach the changed code.** Recorded so you do not retry one as *the* measurement:

| route | why it cannot size the delta |
|---|---|
| a micro-benchmark calling the four constructors directly | three are private fns; perf tests are an external crate; `#[test]` in `src/` is forbidden |
| `scripts/benchmark.sh`'s join tests | route to `StreamTableJoinProcessor` / `IntervalJoinProcessor`, both out of scope |
| a matched INNER join through the engine | `stream_stream_join.rs` uses `JoinCoordinator`, because the raw SQL engine errors on stream-stream joins |

Note the second row carefully: those tier benchmarks **are still required**, by
§6.3 below. What they cannot do is *size the delta*. What they can do — and what
they are required for — is test the prediction that they stay flat. Failing as one
kind of evidence does not make a run worthless; it makes it a different kind of
evidence. Read §6.4 before deciding any of this is busywork.

**Also report reachability per site**: for each of the four, whether a public path
reaches it and the route, or the reason there is none. A site nothing outside
`src/` can reach is a coverage fact worth recording. Establish it from the dispatch
code — do not guess.

If any delta is within run-to-run noise, **say so** rather than reporting a
direction. A claimed improvement nobody measured is worse than a null result.

Three vehicles, each with a different job. **Report all three.** None
substitutes for another, and the second and third are not optional colour.

### 6.1 The delta — the microbench

This is the **only** vehicle that reaches the changed constructor, so it is the
only one that can size the change. Everything else below is scope evidence.

**The invocation, verified at `ce56ad5be`:**

    cargo test --profile bench --no-default-features \
        --test mod performance::unit::from_explicit_microbench -- --nocapture

The file's **own header is stale** — it documents `--test from_explicit_microbench`,
which is invalid. The file is `pub mod from_explicit_microbench;` in
`tests/performance/unit/mod.rs`, so it is part of the `mod` target, not a target of
its own. **Fix that header line as part of this change.**

Do NOT add `--profile unit`: its `default-filter` excludes `performance::`, so the
bench would silently not run and you would report nothing while believing you ran it.

**The numbers below are NOT your baseline.** The command's shape was verified at
`ce56ad5be` — it runs and emits two `MICROBENCH_RESULT` lines — but on the **dev**
profile, giving `batched_100` 902.1 ns/row and `single_row` 2401.2 ns/row. `bench`
inherits `release`; `dev` is `opt-level = 0`. The absolute numbers differ by roughly
an order of magnitude. Take your own before/after readings under `--profile bench`
and compare like with like.

### 6.2 Nexmark — system level, before and after

    cargo test --release --no-default-features --test mod \
        nexmark_q3_local_item_suggestion -- --nocapture --test-threads=1
    cargo test --release --no-default-features --test mod \
        nexmark_q8_monitor_new_users -- --nocapture --test-threads=1

### 6.3 Tier benchmarks — the join-bearing ones, before and after

    scripts/benchmark.sh --tier tier1   # stream_table_join
    scripts/benchmark.sh --tier tier2   # timebased_join
    scripts/benchmark.sh --tier tier3   # interval_stream_join, stream_table_join_advanced

### 6.4 Why 6.2 and 6.3 matter even though they do not reach the four sites

Reading the code says they should be **flat**: `q3_local_item_suggestion` is a
stream-table join on the vectorized take path (`JoinOperator::execute_take_path`,
#1552); `q8_monitor_new_users` dispatches through `dispatch_interval_join_record`
to `IntervalJoinProcessor`; the tier join tests land in `StreamTableJoinProcessor`
and `IntervalJoinProcessor`. All are outside what you are changing.

**That is a prediction, and these runs are what test it.** Flat confirms the scope
analysis this whole spec rests on. A **movement refutes it** — it would mean the
change reaches further than the spec claims, and that is a STOP-and-report finding,
not a number to average away or explain as noise.

So do not treat 6.2 and 6.3 as a formality. Skipping them would leave the scope
boundary asserted rather than checked, and the boundary is the reason three of the
four sites are in scope and a fifth is not. Run them before and after, and report
both sets of numbers even when nothing moves — *especially* when nothing moves,
because that is the result the spec is predicting.

## 6a. Update the constructor docs — they will otherwise be left false

`from_explicit` and `project_into` currently say:

> Pass a `Vec` (not `FxHashMap`) at call sites where column order is meaningful

After this change the preferred form is a **lazy ordered iterator**, which
allocates nothing; a `Vec` is merely acceptable. Leaving that wording would ship a
false contract telling the next caller to allocate — the exact
doc-contradicts-code defect this issue chain exists to remove, and the same shape
as the `batch_to_records` doc that promised schema order while a map decided it.

Reword to: an ordered iterator is preferred, a `Vec` is fine, an `FxHashMap` is
valid only for genuinely schemaless merges. Prose only — the signatures are already
generic over `IntoIterator` as of #2121.

## 7. Validation commands

    cargo check --no-default-features --tests --manifest-path <worktree>/Cargo.toml
    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod --manifest-path <worktree>/Cargo.toml

`--profile unit` is mandatory (#2103). Without it the sweep enqueues 12,470+ tests
including Kafka testcontainers and 45–57s benches, which fail on contention and
look like your change broke things.

Gate, once, from the worktree root — the **FULL** gate, not `--fast`:

    (cd <worktree> && ./run-commit.sh)

Use the full gate because root `CLAUDE.md` requires it before completion.

**But do not read a green gate as benchmark evidence — no gate runs §6.**
`run-commit.sh` calls nextest with `--profile unit` at **both** line 317 (fast) and
line 400 (full), and that profile's `default-filter` excludes `performance::` from
execution. So the benchmark is an **independent** command you must run and report
yourself; nothing will tell you that you skipped it.

(Two earlier drafts of this brief got the mechanism wrong in opposite directions —
one said `--fast` does not *compile* the microbench, which is false: it is a module
of the `mod` target and compiles fine; the other implied the full gate *runs* it,
also false. Compilation and execution are filtered at different layers, and that is
precisely what makes this gap quiet.) It is slow; run it ONCE, at the end, and read the log it tees rather
than re-running it.

It runs `cargo fmt --all` as a WET apply. Afterwards run `git -C <worktree>
status`; if fmt changed anything you must commit it.

### 7a. Red-first, and `cargo fmt` before any STOP

Prove the `fail_to_pass` test red at `origin/master` using a throwaway baseline
worktree:

    git -C <worktree> worktree add /tmp/2138-baseline ce56ad5be  # the PINNED sha, not origin/master:
    # master advances during your run, and a red recorded against a moved master
    # proves nothing about the base this spec was verified on
    # Copy BOTH of these — a test file that is not registered is never compiled,
    # so it cannot fail, and you would record a RED-FIRST line for an assertion
    # that never ran:
    #   tests/unit/sql/execution/processors/join/join_layout_order_test.rs
    #   tests/unit/sql/execution/processors/join/mod.rs   (the registration)
    git -C <worktree> worktree remove /tmp/2138-baseline --force

Log it:

    <UTC> RED-FIRST | test=<name> | failed-with=<one-line assertion message>

And run `cargo fmt --all` + commit **before writing any STOP line**. Every early
stop on #1918 shipped unformatted code and CI failed at `cargo fmt --check` before
running a single test.

## 8. Forbidden

- do not convert the four sites with one regex or one `ast-grep` pattern (§3b)
- do not touch `join.rs:1393`
- do not change `hash_join.rs`'s `col_names` behaviour
- do not convert `stream_table_join.rs`, `update.rs`, `show.rs`
- do not introduce an intermediate `Vec` as the fix — the lazy iterator is pinned
- do not add `#[cfg(test)]` or `#[test]` inside `src/`
- do not delete, skip, `#[ignore]` or narrow any existing test
- do not change a public signature — `project_into` is already generic as of #2121
- do not push, open a PR, or merge.

**On committing.** Root `CLAUDE.md` says "DO NOT commit changes unless the user has
explicitly reviewed them first". **This brief IS that authorisation**, and it is the
narrower task-specific rule, so it governs. The implementation policy states the
same from the other side: "NEVER commit unless the caller's brief explicitly
authorizes it" — a brief that authorises is the condition being met, not an
exception. Authorised: `git commit` on your own dispatch branch, in your own
worktree. NOT authorised: push, PR, merge, committing on master, or committing in a
worktree that is not yours.

# #2138 — four join.rs sites let a hash map decide emitted column order

Parent: #1970 (SQL surface defects from the #1749 name-binding audit)
Follows: #1918 / PR #2121, which fixed the first instance of this class
Prerequisite: **already satisfied** — #2121 generified `project_into`

## 0. The dedup question is SETTLED — read this before touching any site

#1919 landed (`0583961c8`), which unblocked this issue, and the re-derivation it
demanded has been done. **Result: `layout.entries()` names are unique on BOTH
branches, by construction — independent of NB-005 and independent of the
`FxHashMap` at the four sites.** The map is *not* doing load-bearing dedup work,
so converting to a lazy iterator cannot change emitted cardinality. All four
sites are in scope; the site-count bars stand unconditional.

### The argument

`append_relation` routes **every** entry it adds — qualified and bare alike —
through `shadow_or_append` (`layout.rs:299-318`, `:347-361`), which dedups against
`name_pos`.

- `from_sides` (`layout.rs:168-190`) seeds a fresh `name_pos` and appends both
  relations that way.
- `extend_with_right` seeds `name_pos` **from the left entries**, then appends the
  right the same way — so the right side can collide with neither the left nor
  itself.

Therefore `entries` can carry a duplicate **only if** the slice handed to
`from_existing_multi_source_fields` already held one. That slice is
`left_record.data_field_names()`, and this branch is taken only when those names
are **qualified** — i.e. produced by a previous level of this same machinery,
unique by the same argument. The induction closes.

The pathological case — a source schema with a duplicated **bare** column — takes
`from_sides` instead, where `shadow_or_append` degrades to last-one-wins rather
than emitting a literal duplicate (`layout.rs:342-346`).

### What the earlier analysis got right, and wrong

That `extend_with_right` dedups only the right side and carries left duplicates
through verbatim is **correct**. The missing step was that left duplicates cannot
exist in the first place.

### Empirical confirmation

`multi_level_join_layout_emits_unique_qualified_names` (`multi_join_test.rs`)
drives a 3-way chain through `QueryProcessor::process_query` and reads
`data_field_names()`:

    ["t.trade_id", "t.user_id", "t.amount", "p.user_id", "p.tier",
     "k.discount_pct", "k.tier"]

Both join keys on both sides, `tier` on two relations, all qualified, zero
duplicates. It is in `pass_to_stay` — **if it reddens, the derivation is
invalidated and that is a STOP.**

`SELECT *` is what makes this observable: a named projection renames everything to
the SELECT list, and `JoinLayout` is private to the crate. **A first probe used a
named projection, measured the projection instead of the layout, and would have
"confirmed" uniqueness while testing the wrong thing.** Do not repeat that.

### Your obligation

This is a derivation, not a licence. **Confirm per site** that the branch taken
matches the above before removing each map. If any site can reach
`from_existing_multi_source_fields` with a field list that did not come from a
prior `JoinLayout` level, **STOP** — the induction depends on that provenance, and
without it the map *is* load-bearing.

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
  scope. The profile (§6.1) shows these sites at 0.00%, so there is no
  measured basis for widening to their siblings either.

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

**`pass_to_stay` — must still pass when you are done:**

| test | why it is the canary |
|---|---|
| `parity_multi_col_key` | columnar byte-parity, compares column names **positionally** via `assert_eq!` on a `Vec` — so it fails if emitted order moves |
| `parity_computed_key` | same, for a computed group key |
| `pack_join_results_identical_schemas_no_normalisation` | the query-level packer — no normalisation needed when schemas agree |
| `pack_join_results_mixed_schemas_normalises_with_nulls` | the normalisation path §6.3a's order trap runs through |
| `pack_join_results_left_join_realistic` | an outer-join shape reaching the same packer |
| `multi_level_join_layout_emits_unique_qualified_names` | §0's derivation guard — **if this reddens the dedup argument is invalid, which is a STOP** |

The two `parity_*` entries are GROUP BY shapes and **cannot** reach the four
sites; they guard against collateral elsewhere. The four below them can. An
earlier revision declared only the two, which left the machine-checked regression
set with nothing able to observe the code being edited.

**`fail_to_pass` — must go red→green, one per site plus the query level:**

| test | site |
|---|---|
| `join_emits_columns_in_layout_order_under_adverse_hash_order` | 651, `merge_join_records_with_aliases` |
| `join_layout_order_holds_for_outer_join_unmatched_rows` | 712, `combine_records_with_nulls` |
| `join_layout_order_holds_for_probe_miss_rows` | 933, `combine_records_with_nulls_for_probe` |
| `join_layout_order_holds_for_right_join_unmatched_rows` | 965, `combine_records_with_nulls_for_right_join` |
| `pack_join_results_column_order_is_stable_regardless_of_first_row_match` | query level — see §6.3a |

The last one is **conditional**: §6.3a permits a legitimate outcome where the two
orders still differ and you STOP for an orchestrator decision, in which case it
never goes green. Say so explicitly rather than reporting it as unmet work.

If a `pass_to_stay` fails, the emitted order genuinely moved for a shape that is
byte-pinned. Report which shape rather than adjusting the test.

An earlier draft also listed `test_self_join_alias_projection_resolves_correctly`
as a canary. It is not one: it constructs `IntervalJoinProcessor`, not
`JoinProcessor`, so it cannot observe these four edits at all. Removed rather than
left in place, because a canary that cannot see the change is worse than none.

## 6. Measurement — the profile is the evidence

**The 32-execution nexmark + tier before/after sweep is WITHDRAWN** (orchestrator
decision, 2026-09-16, superseding the earlier "all three vehicles" requirement).

It existed to test one thing: whether this change reaches routes the spec says it
does not. A profile answers that in minutes, and answers it *better* — it
attributes time **within** a single run, so it is immune to the cold-cache and
machine-contention effects that made the sweep produce a confident wrong answer.
The first run of this issue STOPped on q3 at −39.5%, which turned out to be a cold
first run measured while an unrelated full gate ran on the same machine, against
code the diff cannot affect.

And it has already answered the question.

### 6.1 The scope boundary — profile, before and after

    VELOSTREAM_PERF_RECORDS=200000 ./scripts/profile.sh \
        --label before --rate 4000 test_stream_table_join_baseline_performance

Same again with `--label after`. Report inclusive percentages for the four sites,
`JoinLayout`, and `hashbrown`.

Measured at spec time on the branch (117,697 samples, 96.7% of self-time
symbolised):

| symbol | inclusive |
|---|---|
| `merge_join_records_with_aliases` | **0.00%** |
| `combine_records_with_nulls*` (all three) | **0.00%** |
| `JoinLayout` | 4.60% |
| `arrow_schema::Fields::find` | 2.29% |
| `take_combine_stream_table` | **29.99%** |

**The four sites reading 0.00% on both sides IS the scope-boundary check.** A
non-zero reading means the change made them execute and the scope analysis is
wrong — that is the STOP.

### 6.2 The delta — the microbench

    cargo test --profile bench --no-default-features \
        --test mod performance::unit::from_explicit_microbench -- --nocapture

Extend `tests/performance/unit/from_explicit_microbench.rs` to compare an
`FxHashMap` built from an ordered layout against the lazy ordered iterator, at 4
and 8 columns. Its own header documents `--test from_explicit_microbench`, which
is **invalid** — the file is a module of the `mod` target. Fix that stale header.
Do **not** add `--profile unit`; its `default-filter` excludes `performance::`.

### 6.3 Do not claim a speedup

The profile says these sites are unreached in a 200k-record join, so there is no
workload in which to demonstrate a throughput win, and the microbench measures a
constructor in isolation rather than a system effect. **This is a correctness
change.** Report the microbench number as what it is and stop there.

For the record, and explicitly **not** scope here: the real hot path is
`take_combine_stream_table` at **29.99%**, which on every call rebuilds both
field-name `Vec<Arc<str>>` (an allocation per column per call) *and* the entire
`JoinLayout`, from inputs that are stable for a query (`hash_join.rs:392-415`).
The existing `OnceLock`/`RwLock` cache covers the output **schema**, not the layout
that derives it. That is plan-time work being redone on the hot path, and it is why
`JoinLayout` shows at 4.60% and ~30% of self-time is allocator/memmove/memset at
all. A linear-scan replacement for `shadow_or_append`'s map (2.14%) was tried and
measured 2.19% vs 2.17% — no gain, quadratic at high column counts, reverted —
because it optimised the inner lookup while the whole layout was being rebuilt
around it.

Earlier revisions of this section said `JoinLayout` 10.52% and `hashbrown` 9.67%.
Both were inflated by double counting — the analysis summed every matching symbol
per stack, so a stack containing `from_sides` *and* `append_relation` counted
twice. Counting each sample once gives 4.60% and 5.04%. The load-bearing figure,
the four sites at 0.00%, is unaffected either way.

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

## 6z. Commit incrementally — a timeout must not lose work

Commit after each logical step, not once at the end. A timeout or crash must
never lose completed work. Small commits are expected and will be squashed at
merge; do **NOT** wait until everything is done and validated. If you are about
to start a long step — a full gate run, a `--profile bench` build, a samply
profile, a multi-file edit — **commit what you already have FIRST.**

§6 is much cheaper than it was (the 32-execution sweep is withdrawn), but two
profiles and a `--profile bench` build are still cold optimized compiles, and two
earlier runs in this repo died on a timeout with all their work uncommitted in the
worktree. One of those was this very issue.

It composes with §8's one-site-per-commit rule rather than competing with it:
that rule sets the *minimum* granularity for the four conversions (four separate
commits, never fewer). This sets the *maximum* interval between commits. A
measurement run captured but uncommitted is exactly the work a timeout eats.

## 7. Validation commands

    cargo check --no-default-features --tests --manifest-path <worktree>/Cargo.toml
    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod --manifest-path <worktree>/Cargo.toml

`--profile unit` is mandatory (#2103). Without it the sweep enqueues 12,470+ tests
including Kafka testcontainers and 45–57s benches, which fail on contention and
look like your change broke things.

Gate, once, from the worktree root — the **FULL** gate, not `--fast`:

    (cd <worktree> && ./run-commit.sh --fast)

`--fast` is the gate, per the implementation policy. An earlier draft of this brief
escalated to the full gate, arguing `--fast` would not exercise §6's benchmark.
**That was wrong twice and is withdrawn:** `--fast` *does* compile the microbench
(it is a module of the `mod` target), and the full gate does not *run* it either —
`run-commit.sh` passes `--profile unit` at both line 317 and line 400, and that
profile's `default-filter` excludes `performance::` from execution.

So **no gate runs §6.** The benchmark is an independent command you must run and
report yourself, and nothing will tell you that you skipped it. Escalating past
`--fast` bought nothing here while adding the dominant cost to a ~20-line change.

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

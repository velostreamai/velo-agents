# #2149 — dedup the `from_existing_multi_source_fields` seed at every consumer

BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Parent: #1970. Cut fresh off `origin/master` (`8a5a2e6e7`).
**Do NOT `cd` into the worktree** — use `git -C <path>` and `cargo --manifest-path <path>/Cargo.toml`. The one exception is the final `run-commit.sh --fast`, which must run from the worktree root: `(cd <worktree> && ./run-commit.sh --fast)`.

## 0. Read the history first — it is the point of this issue

`JoinLayout::from_existing_multi_source_fields` (`execution/join/layout.rs:209-224`) copies its seed **verbatim**: no `name_pos`, no dedup. The branch selecting it usually tests `left_fields.iter().any(|name| name.contains('.'))` — a **heuristic standing in for a provenance claim nothing enforces**. `StreamRecord::from_rows` does not enforce unique names (`stream_record/builder.rs:989-997`); `FieldName` is an unrestricted `Arc<str>` (`execution/types.rs:27`).

So a duplicated seed name produces two identical entries, and any consumer that iterates `layout.entries()` into a `Vec` emits **two columns where one was intended**.

**This was already missed twice, both times by the orchestrator, both times the same way:**

1. `.agents/tasks/2138.json`'s `_dedup_derivation` — now **RETRACTED in place**, read it — proved uniqueness by induction on a premise ("the seed is always a prior level's own output") that nothing checks. An independent gate found the P1 it hid.
2. Reviewing the fix, the orchestrator declared the dedup's *placement* settled after checking the sibling **constructors** (`from_sides`, `extend_with_right`, which do dedup) and never the **callers** of the un-deduped one. That is how the eight sites below went unnoticed.

Same habit each time: **verify an adjacent set, declare the class closed.** Your job is to close it for real.

## 1. Where the fix goes — PINNED, not your call

**Dedup INSIDE `from_existing_multi_source_fields` (`layout.rs:209-224`).** Do not
implement per-caller guards instead.

The reason is not aesthetic. A fix that depends on a **complete caller list** has
already failed twice on this exact function — see §0. Per-caller guards would make
correctness depend on the same enumeration that was wrong both times. A fix at the
constructor cannot be missed at a call site.

The constructor's doc says it seeds "an already-canonical left subtree". Deduping
inside it **enforces** that contract rather than assuming it — say so in the doc,
because the assumption is what caused both failures.

Reuse `dedup_seed_fields`' approach (`processors/join.rs:100`, `Cow<'_, [FieldName]>`
— borrowed when already unique) so the all-unique path does not allocate. If the
helper needs to move to be shared, **move it; do not copy it.** Cost is one extra
scan on a path that already clones every name.

Do **not** change the constructor's signature — a dedup is internal, and a
signature change would touch all 11 call sites for nothing.

**If this breaks an existing test, that is STOP condition 1** (§7). Report which
test and which caller. Do **not** quietly fall back to per-caller guards — a caller
that relies on duplicate entries surviving is a finding about the layout contract,
and it is the orchestrator's call, not yours.

## 2. Confirm the consumer shape per caller before changing it

Three are verified as duplicate-preserving (`for entry in layout.entries()` → `out_fields`/`out_arrays` push):

- `processors/join.rs:1410`
- `algorithms/hash_join.rs:402` (`build_take_combine_schema`)
- `algorithms/hash_join.rs:859`

Five are **UNVERIFIED** — check each, do not assume the pattern:

- `join/coordinator/mod.rs:6323`, `:6474`
- `processors/stream_table_join.rs:610`, `:765`
- `plan/schema.rs:359` (plan-time; may be harmless)

A site that funnels through a map, or builds a schema never used for gathering, may need nothing. **Report a verdict per site.** If the affected set is larger than eight, that is a finding — say so.

Already fixed by #2145 and not to be disturbed beyond sharing the helper: `processors/join.rs:680`, `:735`, `:956`.

## 3. Tests

One regression test per genuinely-affected site, plus the declared `fail_to_pass` name covering the consumer-level property:

`duplicate_seed_fields_do_not_double_columns_at_every_layout_consumer`

**Mutation-prove each one.** Disable the dedup, show the test FAILS, restore, show it PASSES, and put both commands with their output in your report. Two P1s in this issue family came from tests that passed while covering nothing.

Must stay green: `combine_records_with_nulls_dedups_duplicate_seed_fields`, `merge_join_records_with_aliases_dedups_duplicate_seed_fields`, `combine_records_with_nulls_for_probe_dedups_duplicate_seed_fields`, `join_emits_columns_in_layout_order_under_adverse_hash_order`, `three_way_inner_join_chains_through_engine`, `pack_join_results_mixed_schemas_normalises_with_nulls`.

New test files must be registered in the parent `mod.rs` — an unregistered file is never compiled, so it cannot fail.

## 4. Discovery tooling

Use **`~/.agents/bin/zg`** by absolute path (it is not on every PATH) — **not rust-analyzer, not an LSP**. Its background indexing contends for cores and has already contaminated a measurement in this repo. If `zg` hangs, say so and fall back to direct `git`/file inspection — **not `rg`**, which finds only the spelling you already thought of, and this whole issue is about the site nobody thought of.

`ast-grep` remains the tool for the structural rewrite once you know the sites.

## 5. Validation

```
cargo check --no-default-features --manifest-path <worktree>/Cargo.toml
cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/join|layout|take_path|pack_join/)' --manifest-path <worktree>/Cargo.toml
```

`--profile unit` is mandatory (#2103) — without it the sweep enqueues Kafka testcontainers and long benches that fail on contention and read as "your change broke things".

Final gate, once: `(cd <worktree> && ./run-commit.sh --fast)`. It wet-applies `cargo fmt`; run `git status` afterwards and commit any reformatting.

## 6. Commit incrementally

Commit after each logical step — per-site or per-decision. A timeout must never lose completed work; small commits are expected and will be squashed at merge. Before a long step (the full gate, a multi-file rewrite), commit what you have.

## 7. STOP and report — do not work around any of these

- **Deduping inside the constructor breaks an existing test.** Informative, not a dead end: some caller relies on duplicate entries surviving. Report which test and which caller rather than silently falling back to per-caller guards — a caller that needs duplicates is a finding about the layout contract.
- **A caller's seed provenance cannot be established** — you cannot tell whether its field list came from a prior `JoinLayout` level or from raw record data. Report it. Assuming it is exactly what produced the retracted derivation's P1.
- **A new test cannot be made to fail with the dedup disabled.** It does not reach the defect.
- **The affected set is larger than the eight named.** Report the full list; the enumeration being wrong is the defect class this issue exists to close.
- `./run-commit.sh --fast` fails for any reason.

## 8. Authorization

**You are authorized to commit** on `fix/2149-dedup-layout-seed` — this brief is that authorisation.

**Do not push. Do not open a PR. Do not merge. Do not comment on the issue.** **NOT authorised:** pushing, opening or editing a PR, merging, commenting on the issue, committing on `master`, or committing in another worktree. The orchestrator handles push and gating.

## 9. Do not

- Do not revert or alter #2145's three fixed sites beyond sharing the helper.
- Do not widen into #2148's arrow `take`-kernel work (~26% of that workload, separate architectural question).
- **Do not claim a performance change.** These sites profile at 0.00% inclusive in a 200k-record stream-table workload; this is correctness only.

## 10. Report

What you changed and which option you chose with the reason; the per-site verdicts from §2; the mutation-proof output per test; the `--fast` result; any STOP you hit. A what-I-did summary, not a code review of your own diff.

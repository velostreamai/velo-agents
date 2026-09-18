# Brief — PR #2152: the P1 class has a second member, in production

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**PR**: https://github.com/velostreamai/velostream/pull/2152 (gate:blocked)
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Already checked out at `cb3ed4b02`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

You flagged this site yourself at the end of the last round and correctly identified it as the same shape as P1. **You under-rated it** — it is not capacity-only, and it is reachable in production. Thank you for surfacing it; this brief is the decision you asked for.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## The defect

`src/velostream/sql/execution/physical_operator/join_operator.rs:1124` (production take path) and `:713` (the test helper `ensure_projection_layout_for_test`) both compute:

    let n_data_total = probe.field_count() + build.batch.num_columns();

That is the **raw, un-deduped** probe count plus the build count. It is then passed to `ensure_projection_layout`, whose `joined_schema` comes from the **deduplicated** layout. Three uses of it are affected, and only the first is a capacity hint:

- `:473` — `Vec::with_capacity(projection.len() + (joined_schema.fields().len() - n_data_total))`. Underflows when duplicates-removed exceeds `SystemCol::COUNT` (7): release wraps to a huge capacity, debug panics.
- `:505` — `if idx >= n_data_total { … }`, the data-vs-system classification. With *d* duplicates removed, indices in `[n_data - d, n_data)` are system columns that this test calls data.
- `:526` — **`for sys_field in &joined_schema.fields()[n_data_total..]`**. This is the serious one. The slice starts *d* columns too late, so the projected output **silently loses the first *d* system columns**. `SystemCol::EventTime` is relative offset 0 and `SystemCol::Timestamp` is offset 1 (`sys_cols.rs`), so the first things dropped are `_event_time` and `_timestamp` — watermark advancement, DLQ row→offset routing and trace propagation all depend on them. When *d* > 7 the slice is out of range and panics on the job thread.

The `debug_assert_eq!` at `:1127` compares `layout.n_data_total` against the same raw expression, so it is self-consistent and cannot catch this.

Reachable when `metadata.projection` is `Some` — a `SELECT` with a column subset/reorder on the take path — with a duplicate-producing probe seed. Same trigger class as the P1 already fixed, which is why this must land in the same PR rather than as a follow-up.

## Pinned fix

Same principle as the P1 fix you already landed: **the joined batch is the authority for its own column counts.** Derive `n_data_total` from the joined record's actual data-column count rather than from the probe and build inputs.

At both `:1124` and `:713`, `joined` is in scope (`:1134` uses `&joined.batch`). Use its data-column count — `joined.field_count()` — which reflects the deduplicated layout, so it agrees with `joined_schema` by construction.

Check whether `ensure_projection_layout`'s doc at `:445-446` and the `ProjectionLayout::n_data_total` doc at `:274` still describe the value correctly after the change, and correct them if not. Do **not** weaken or delete the `debug_assert_eq!` at `:1127` — once both sides derive from the joined batch it becomes a real staleness check rather than a tautology.

## Sweep — the class is closed, do not widen

I swept `src/velostream/sql/execution/` for this shape. The class has exactly these two members. The other hits are self-consistent and must NOT be changed:

- `coordinator/mod.rs:1964,1967` — `record.field_count() + SystemCol::X` on the record's **own** count.
- `hash_join.rs:875` — capacity from local `n_probe_data`.
- `select/rows_window.rs:652` — capacity from the joined record's own batch.

If you find a third genuine member, report it rather than expanding scope silently.

## Test requirement — red first

Add a regression test that drives the **take path with a projection** (`metadata.projection = Some(...)`) over a duplicate-producing probe seed, and asserts the projected output retains its complete system-column tail — specifically that `_event_time` and `_timestamp` survive and carry the correct per-row values.

Write it against the current (broken) code first and **record the actual failure text in `agent.log`**, as you did for the P1. If the dropped system columns turn out not to be observable through the accessor you pick, say so and find one that does observe them rather than asserting something weaker — a test that passes on the broken code is worse than no test.

`ensure_projection_layout_for_test` at `:696` exists for exactly this kind of test; use it if it gives a cleaner reach than the full engine path.

## Bars

- All 13 tests from the previous rounds keep passing (9 #2149 + 3 #2145 site tests + the P3 test).
- No test deleted, skipped, `#[ignore]`d or weakened.
- The `layout.rs:47-51` doc block stays untouched (still out of scope).

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/duplicate_seed|dedups_duplicate|projection_layout|take_path/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Join-scoped sweep (keep `--profile unit`):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|layout|take_combine/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. It runs `cargo fmt --all` wet — check `git status` after and commit any reformatting.

## Incremental commits (spec §12)

- Commit 1: the regression test, RED.
- Commit 2: the fix at both sites + doc corrections.
- Commit 3, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — not rust-analyzer, not the `LSP` tool.
- Streaming compliance: this defect **drops system columns**, so it is squarely invariant 1 (per-row metadata fidelity), 2 (watermark monotonicity) and 4 (DLQ per-row identity). Log `STREAMING-COMPLIANCE-CHECK` / `-AFTER` naming those three.

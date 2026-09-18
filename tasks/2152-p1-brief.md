# Brief — PR #2152 gate BLOCK: P1 regression + P2 test gap + P3 panic-tolerance shift

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**PR**: https://github.com/velostreamai/velostream/pull/2152 (gate:blocked)
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Already checked out at `89dc5db8f`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Two independent gates ran. One approved; `check-code` (opus, high effort) found a **P1 regression this PR introduces**, and the orchestrator independently verified the two load-bearing links. Read both reports on the PR before starting — they are posted as comments.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## P1 — the deduped layout broke a probe/build column split derived by subtraction

`src/velostream/sql/execution/processors/join.rs`:

    :1241   let n_probe_data = probe.field_count();                      // UN-deduped (raw n_data)
    :1274   let n_build_data = joined.field_count() - n_probe_data;       // `joined` is now DEDUPED

Verified: `field_count()` returns `self.n_data` (`stream_record/mod.rs:544`), the raw probe column count — `from_rows` copies row-0 column names verbatim including duplicates. `joined`'s schema comes from `layout.entries()`, which this PR deduplicates. So the subtraction under-counts by exactly the number of duplicates removed.

Consequence, using the PR's own sweep fixture (`join_layout_order_test.rs:884`): probe `[id, probe.dup, probe.dup]` + build `[id, val]` gives `joined` = 4 data columns, `n_probe_data` = 3, so `n_build_data` = **1**. `duplicate_aliased_data_columns` then treats the first build column as a probe column, never strips its sentinel, and emits **`__vs_build__.id`** into query output while `right_stream.id` disappears. No error, no panic — silent wrong output through `SELECT *`.

Worse shape: when duplicates-removed exceeds the build data column count, the subtraction **underflows** `usize` — debug panic, release wrap to a huge `n_build_data` and an out-of-range `schema.field(idx)` panic on the job thread.

### Pinned fix — derive the split from the joined batch, not from two counts

The root cause is inferring one boundary from two independently-computed sources. The joined batch already carries the answer: build columns are prefixed with `BUILD_COLUMN_SENTINEL` (`join.rs:1332`, `"__vs_build__"`), passed deliberately at `:1266` because "the sentinel-prefixed name never collides with a real probe column" (`:1237`). Layout order is left-then-right, so the sentinel-prefixed columns are contiguous.

Within the data columns `0..joined.field_count()`:

- `n_probe_data` = the index of the first column whose name starts with `"__vs_build__."`
- `n_build_data` = `joined.field_count() - n_probe_data`
- No build columns at all → `n_probe_data == field_count()`, `n_build_data == 0`.

Compute both at the `:1274` call site from `joined` and pass them down unchanged. **Delete the `probe.field_count()` dependency at `:1241`** if nothing else uses it (check — it may be used by the LEFT-join NULL-fill arm below; if so, leave that use alone and scope the change to the matched-row arm).

This cannot underflow, needs no dedup knowledge at the call site, and is self-checking: `strip_build_sentinel` already hard-errors when a column in the build range lacks the prefix (`:1444`, "take_combine_stream_table contract changed?"), so a wrong boundary surfaces as an error rather than as wrong output.

Do **not** fix this by re-deduplicating the probe field names at the call site to make the counts agree. That reintroduces the caller-side duplication the previous gate round removed, and leaves two sources of truth.

## P2 — the tests for this consumer cannot see the P1

`stream_stream_matched_take_combine_dedups_duplicate_probe_seed_field` and sweep items 1, 2 and 4 assert only `count_occurrences(record, "<dup>") == 1`. That is a count of **one name**, so the wrong output above — `[id, probe.dup, __vs_build__.id, right_stream.val]` — satisfies every existing assertion.

**Add full-vector assertions** to the `processors/join.rs`-site tests: `assert_eq!(names(&joined), vec![...])` with the complete expected column list, in order. `tests/unit/sql/plan/schema_test.rs:463` already does this and is the right shape to copy.

At least one of these assertions **must fail before your P1 fix and pass after**. Verify that explicitly and report the failure text — a test added after the fix that was never seen red proves nothing.

## P3 — the dedup shifted which inputs trip the coordinator assert

`src/velostream/sql/execution/join/coordinator/mod.rs:6503`: `BatchLayout::from_sides` compares `order.len()` (layout-derived, dotted branch = `dedup(left) + right + 1`) against `n_data` from the plan-time schema, which `interval_join.rs:211` builds via `merge_for_join_with_sources` → `JoinLayout::from_sides` → `dedup(left) + dedup(right) + 2`.

With exactly one duplicate in a dotted `left_fields`, those were **equal before this PR and differ by one after**: an input that previously built a working coordinator now panics the job thread. Reachability is low (needs a declared source schema carrying a dotted field name twice; `Schema::new` does not enforce uniqueness), but it is a regression introduced here, not a pre-existing gap.

**Pinned fix**: make both sides of the comparison derive from the same dedup discipline, so the assert compares like with like. Do not weaken or delete the assert — it is a real fail-loud invariant, and its unrelated `#1833` aliased-schema reachability must stay intact. If you conclude the two sides cannot be reconciled without a design change, STOP and report rather than adjusting the assert's tolerance.

## Out of scope

The `layout.rs:47-51` module-doc claim about `BatchLayout::from_sides` silently producing duplicate `t.x` entries — the two reviewers disagree on whether it is still true. The orchestrator will adjudicate separately. **Do not edit that doc block.**

## Bars

- All 9 existing #2149 tests plus the 3 pre-existing #2145 site tests keep passing. The #2145 site tests now depend solely on the constructor dedup (their caller wrappers were removed last round), so a regression there is a P1-class signal, not a test nit.
- No test deleted, skipped, `#[ignore]`d, or weakened.
- The P1 fix must not reintroduce a caller-side dedup.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/duplicate_seed|dedups_duplicate|aliased_data_columns/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Join-scoped sweep (keep `--profile unit` — without it the run pulls in `performance::` and `integration::` and fails on contention in subsystems you never touched):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|layout|take_combine/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. It runs `cargo fmt --all` wet — check `git status` after and commit any reformatting.

## Incremental commits (spec §12)

- Commit 1: P2 (full-vector assertions) — land this FIRST, RED, so the P1 is demonstrated before it is fixed. Record the failure text in `agent.log`.
- Commit 2: P1 (sentinel-derived split).
- Commit 3: P3 (coordinator assert operands).
- Commit 4, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — not rust-analyzer, not the `LSP` tool. Note the index may be stale; `zg status` tells you, and a literal-symbol grep over `src/` is exhaustive for a name this distinctive.
- Streaming compliance: P1 changes how data vs system columns are partitioned in a joined batch, so log `STREAMING-COMPLIANCE-CHECK` / `-AFTER`. The system tail must stay at `field_count()..num_columns()` and per-row `_offset`/`_key`/`_headers`/`_traceparent`/`_event_time` must remain row-aligned.

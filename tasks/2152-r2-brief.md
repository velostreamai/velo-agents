# Brief — PR #2152 gate round 2: three findings

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**PR**: https://github.com/velostreamai/velostream/pull/2152
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Already checked out at `dc33b1165`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Both round-2 gates returned approve-with-findings. **No P1/P2 — the three fixes are correct and the class-closure claim survived independent re-derivation by both reviewers.** Read both reports on the PR (`gh pr view 2152 --repo velostreamai/velostream --comments`).

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## R1 (must-fix) — the doc correction overshot; production was never silent

Both gates found this independently, which is why it is first.

Your doc correction added: *"a smaller duplicate count produces no error at all — just a silently short system-column tail"*, and `:467`/`:1160` say *"silently dropping the leading system columns"*.

**That is false for the production path.** The bad `n_data_total` is too LARGE by `d`, so the tail gather skips the **first** `d` system columns. Canonical order is `_event_time, _timestamp, _offset, _key, _headers, _partition, _traceparent` (`sys_cols.rs:85-92`) and the first six are `is_required()` (`sys_cols.rs:121-131`). So for **every** `d ≥ 1`, `_event_time` is dropped and `StreamRecord::from_batch` panics (`builder.rs:1502-1521`) — which is exactly the panic your own red-phase evidence quoted at `d = 2`. There is no `d` that yields a silently short tail here: silence would need the drop to come from the END, and this slice drops from the FRONT.

So P1b's production severity was **crash-on-first-batch**, not silent wrong data. The only genuinely silent site is `ensure_projection_layout_for_test`, which returns a schema and never materialises a batch — which is what your `:743` test pins.

**Fix**: correct all three doc sites (`:288-291`, `:466-468`, `:1158-1161`) to say the production path panics in `from_batch` on the first affected batch, and scope the "silent" characterisation to the schema-only test helper. Keep it short — this is a correction, not an essay.

This matters beyond wording: a reader deciding how urgently to care about this class will draw the opposite conclusion from the current text.

## R2 (must-fix) — the P3 test cannot detect the regression it was written for

`tests/unit/sql/execution/processors/join/join_layout_order_test.rs:1167-1185` re-implements the production branch predicate:

    if left_fields.iter().any(|name| name.contains('.')) { … }

and then hands the result to `with_output_schema`. So it pins "the two `Schema::merge_*` functions agree with `BatchLayout::from_sides`" — but **not** "`interval_join.rs` selects the branch that agrees."

**Failure scenario**: revert `interval_join.rs:231` to the unconditional `Schema::merge_for_join_with_sources` (the pre-fix code) and this test **still passes**, because it never calls `cache_inputs`. Production regresses to the `assert_eq!` panic at `coordinator/mod.rs:6503`.

The reviewer confirmed no other test covers it: every `with_output_schema` caller in `tests/` hand-builds its own schema, and no test primes `ctx.plan_source_schemas` with a dotted left field. Corroborating evidence — P3 was found by review, not by the suite.

**Fix**: prime a dotted left source schema into `plan_source_schemas` and drive the engine's interval-join construction so the assert is reached through production code. The patterns in `engine_source_dispatch_test.rs` / `core/schema_wiring_test.rs` show how.

**Verify by mutation**: revert `interval_join.rs:231` to the unconditional call, confirm your new test FAILS, restore, confirm `git diff` shows no residue. Record the failure text in `agent.log`. Keep the existing test — it pins a different (also useful) property; add alongside it.

## R3 (must-fix) — the sentinel scan has a silent misclassification hole

The two gates **contradicted** on this one and the orchestrator adjudicated: the finding is real.

`probe_build_data_split` takes the first data column whose name starts with `"__vs_build__."`. `FieldName` is an unrestricted `Arc<str>` with no ingest guard on that prefix, so a probe data field literally named `__vs_build__.x` makes the split land early.

One gate argued this is harmless because `strip_build_sentinel` would hard-error on the misclassified probe columns. **That is only true when a bare probe column follows.** Worked case: probe data `[a, __vs_build__.x]`, build `[b]` → joined data `[a, __vs_build__.x, __vs_build__.b]`. The scan returns index 1, so the build range is `1..3` — and **both** columns in that range carry the prefix, so `strip_build_sentinel` succeeds on both. No error. The probe's own column is emitted as build-side data under the right alias: silent provenance misattribution.

Note this is a **narrow regression introduced by the fix** — the pre-fix subtraction classified that column as probe.

**Pinned fix**: a pre-flight hard error. Reject a probe data field name starting with `BUILD_COLUMN_SENTINEL` + `'.'` before the take-combine call in `probe_stream_stream_batch`, with an error naming the offending column and saying the prefix is reserved-internal. The constant is already documented as internal-never-surfaces (`join.rs:1327-1330`), so this makes an existing assumption enforced rather than assumed — the same move as #2149's constructor dedup.

Do **not** fix it by making the scan cleverer (e.g. scanning from the end, or counting prefixed columns). The reserved prefix should be rejected at the boundary, once, not worked around at each consumer.

Add a test asserting the hard error fires with a `__vs_build__.`-named probe field, and assert on the error, not on a panic.

## Bars

- All existing tests keep passing (21 in `join_layout_order`, 1,236+ in the join sweep). No test deleted, skipped, `#[ignore]`d or weakened.
- R2 and R3's new tests must each be observed failing against their defect before acceptance; record both in `agent.log`.
- `layout.rs:47-51` doc block still out of scope — do not touch.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/join_layout_order|interval_join|schema_wiring/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Join-scoped sweep (keep `--profile unit`):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|layout|take_combine/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. `cargo fmt --all` runs wet — check `git status` after and commit any reformatting.

## Incremental commits (spec §12)

- Commit 1: R1 (doc corrections).
- Commit 2: R2 (production-driven interval-join test).
- Commit 3: R3 (pre-flight hard error + test).
- Commit 4, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) — not rust-analyzer, not the `LSP` tool. Both gates reported the index stale on this branch's 6 modified files; `zg status` will tell you, and exhaustive grep over `src/` is the stated fallback for those files.
- Streaming compliance: R1 is doc-only but concerns system-column integrity; R3 concerns provenance of emitted columns. Log `STREAMING-COMPLIANCE-CHECK` / `-AFTER` for R3.

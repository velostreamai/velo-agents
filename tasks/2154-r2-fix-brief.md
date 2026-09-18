# Brief — PR #2154 gate round 2 findings (all P3, but two are substantive)

**Issue**: https://github.com/velostreamai/velostream/issues/2150
**PR**: https://github.com/velostreamai/velostream/pull/2154
**Parent issue**: #1970
BRANCH: perf/2150-identity-selection
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2150

Already checked out at `7b0b2f051`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Both round-2 gates ran. **No production defect in the delta** — one returned approve, the other approve-with-findings, all P3. Read both PR comments.

**Three of the four findings are the orchestrator's errors, not yours.** H1 and H4 correct doc text I supplied in the previous brief; H2 exists because I specified "assert at least two" system columns when the correct instruction was "all of them". Noting this so you do not spend effort re-deriving whether you misread the last brief — you did not.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## H1 (must-fix) — the retention doc names a producer that cannot reach this function

The G4 docblock (`hash_join.rs:642-644`) says `physical_operator/limit_operator.rs` produces sliced probe batches reaching this path. It does slice (`limit_operator.rs:245`), but that batch is never a probe for `take_or_clone_identity`: in `engine/core_executor.rs` the join arm returns at **`:648-662`**, before the limit arm at **`:721`**, and the routing note at **`:706-715`** states Join-rooted plans enforce LIMIT inside `SelectProcessor::check_limit` rather than via the operator. So on any plan the take path fires for, the limit slice does not exist upstream.

It also contradicts bullet 4 of the same docblock ("confined to file/Parquet-style sources… Kafka poll batches are not slices"). **Bullet 4 is the correct one.**

Concrete harm: a reader auditing exposure concludes `SELECT … FROM kafka_stream JOIN ref_table … LIMIT 10` retains a parent buffer. It does not.

**Fix**: drop the `limit_operator.rs` clause. If you can identify a plan shape that genuinely reaches the take path with a limit-sliced probe, name that shape instead — but verify it against `core_executor.rs`'s dispatch order rather than assuming.

## H2 (must-fix) — G1 guards 2 of 7 system-tail bumps; 5 are unguarded

My last brief said "assert at least two: one plain primitive (`_offset`) and the `Map`-typed `_headers`". That was wrong — it leaves `_key`, `_partition`, `_traceparent`, `_event_time` and `_timestamp` with no `ptr_eq` guard at all.

Concrete mutation that leaves **every test in the file green**: at `hash_join.rs:1118`, change the flag to `is_identity_selection && relative_offset != SystemCol::Key as usize`. `take` under the identity permutation reproduces identical bytes, which is exactly the round-1 G1 mechanism — the values still match, so nothing fails.

**Fix**: assert `Arc::ptr_eq` for **every** system column present in both schemas, driven by a loop over `SystemCol::ALL` (skip any column absent from either schema rather than hard-coding the list, so a future system column is covered automatically). Test 1 passes `None` for `build_event_time`/`build_timestamp` (`:184-187`), so `max_taken_with_build_side` returns `taken` unchanged for all seven and the loop holds there by construction.

**Verify by mutation**: apply the `!= SystemCol::Key` mutation above, confirm your new loop FAILS, restore, confirm `git diff` is clean. Record the failure text in `agent.log`.

## H3 (must-fix) — test 7's `ptr_eq` proofs and its offset-discriminating assertions are on different columns

This is the subtlest finding of the round and it is the one that decides whether G2 met its objective.

- `Arc::ptr_eq` in test 7 is asserted on `id` (`:928`) and `_offset` (`:933`) — both `Int64`. `PrimitiveArray::slice` (`arrow-array-58.4.0/src/array/primitive_array.rs:833-839`) folds the offset into `values: ScalarBuffer`, so a sliced primitive has **no residual offset to mishandle**. Those assertions prove sharing, nothing about offsets.
- The only offset-discriminating assertions are `out.key_at(i)` (`:889`) and `out.headers_at(i)` (`:895`). `MapArray::slice` (`map_array.rs:238-245`) slices `value_offsets` but keeps `entries` **whole**, so `headers_at` reads absolute offsets into an unsliced child. Those two columns have **no** `ptr_eq`.

Mutation that leaves all 7 tests green while G2's objective evaporates: add a slice-detection branch in loop 3 falling back to `take` **only for Map/Binary-typed system columns**. Test 1 is unaffected (unsliced probe). Test 7's primitive `ptr_eq`s still pass. `_headers`/`_key` values are then asserted against a compacted map and the arrow-slicing invariant is uncovered.

**Fix**: assert `ptr_eq` on the probe `_headers` and `_key` columns in test 7 — the same columns whose values are discriminating. H2's `SystemCol::ALL` loop may cover this if you apply it to test 7 as well as test 1; if so, say so rather than duplicating.

Then **correct test 7's docstring**: it claims to pin offset-correctness "behaviourally instead of by citation to arrow internals". State accurately what it pins — that a future rewrite of the clone arm which reconstructs the array (dropping the slice offset) is caught, and that a non-sliced probe could not distinguish "respects offset" from "assumes offset 0". Do not overstate it in the other direction either; that failure mode cost #2152 a round.

## H4 (nit) — imprecise sharing claim

Bullet 2 of the retention doc (`hash_join.rs:650-654`) says "every slice and clone of a given parent shares the SAME `Arc`". That is imprecise, and contradicts this delta's own test comment at test-file `:915-918` ("`RecordBatch::slice` itself allocates a new `Arc<dyn Array>` wrapper"). What is shared is the underlying `Buffer` / `Arc<Bytes>`, not the `Arc<dyn Array>`. The bullet's conclusion (aggregate = distinct parents × parent size) is unaffected — fix the wording only.

## Bars

- All 7 existing tests keep passing; none deleted, skipped, `#[ignore]`d or weakened.
- No change to the detector, the fast-path branch structure, or the `debug_assert`s.
- H2 and H3's new assertions must each be observed failing against the stated mutation before acceptance; record both in `agent.log`.
- No logic change in `src/` this round — `hash_join.rs` is doc-only.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/identity_fast_path/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Join-scoped sweep (keep `--profile unit`):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|take_combine|hash_join/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2150 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. `cargo fmt --all` runs wet — check `git status` after and commit any reformatting.

**Do not re-profile.** Doc and test changes only.

## Incremental commits (spec §12)

- Commit 1: H2 + H3 (the `SystemCol::ALL` ptr_eq loop in tests 1 and 7, plus test 7's docstring).
- Commit 2: H1 + H4 (retention doc corrections).
- Commit 3, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) — not rust-analyzer, not the `LSP` tool. One gate reported the index unconfigured for this worktree and the other reported it stale; `zg status` will tell you, and exhaustive grep over a 2-file scope is the stated fallback.
- Streaming compliance: H2/H3 extend per-row system-column identity coverage — log `STREAMING-COMPLIANCE-CHECK` / `-AFTER`.

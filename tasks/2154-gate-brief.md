# Brief — PR #2154 gate round 1: test-coverage gaps

**Issue**: https://github.com/velostreamai/velostream/issues/2150
**PR**: https://github.com/velostreamai/velostream/pull/2154 (gate:blocked)
**Parent issue**: #1970
BRANCH: perf/2150-identity-selection
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2150

Already checked out at `e502ebf58`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Two independent gates ran; both returned approve-with-findings, and each found something the other missed. Read all three PR comments first (`gh pr view 2154 --repo velostreamai/velostream --comments`) — the third is the orchestrator's adjudication and resolves a contradiction between them.

**The detector, the fast-path branch structure and the `debug_assert` cross-checks are CORRECT and stay untouched.** Both gates attacked the detector's exhaustiveness independently and it held both times. Everything below is test coverage and documentation.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## G1 (must-fix) — 7 of the 13 refcount-bumps have no regression guard

Every positive `Arc::ptr_eq` assertion in `identity_selection_fast_path_test.rs` targets `out.batch.column(0)` or `column(1)`. With `n_probe_data == 2` in both tests that assert sharing (tests 1 and 6), those are both probe **data** columns. **Nothing asserts sharing anywhere in the system tail.**

Consequence: revert `hash_join.rs:1082` (loop 3) from `take_or_clone_identity(...)` back to `arrow::compute::kernels::take::take(col.as_ref(), &probe_indices, None)` and **all 6 tests still pass** — under the identity permutation `take` produces identical values, which is exactly what test 1's `offset_at`/`key_at`/`headers_at` assertions check. `SystemCol::COUNT = 7`, so loop 3 is 7 of the 13 refcount-bumps the PR's win rests on, and it is unguarded.

**Fix**: add `Arc::ptr_eq` assertions on system-tail columns in test 1, resolving the index from the schema (do not hard-code a bare integer — derive it, e.g. by looking up the `_offset` / `_event_time` column index in `out.batch.schema()`, so the test survives a system-column layout change). Assert at least two: one plain primitive (`_offset`) and the `Map`-typed `_headers`, since that is the most expensive gather and the one most likely to be special-cased by a future edit.

**Verify the mutant is killed**: temporarily revert loop 3 to `take`, confirm your new assertion FAILS, then restore. Record the failure text in `agent.log` and confirm via `git diff` that no residue remains. A guard that was never seen fail is not a guard.

## G2 (must-fix) — no test drives a SLICED probe batch through the fast path

A probe column can be a slice of a larger parent: `datasource/file/reader.rs:2860-2861` returns `batch.slice(0, want)` as the emitted record, and `physical_operator/limit_operator.rs:245` slices too. Under `Arc::clone` the output column keeps the parent's offset, where `take` compacted to a fresh offset-0 array.

Correctness here currently rests on a **citation to arrow internals** — `PrimitiveArray::slice` slices the `values` `ScalarBuffer` (`arrow-array-58.4.0/src/array/primitive_array.rs:836`), so `.values()` is offset-correct. Three of us verified that reading independently, and it is right. It is also pinned by nothing behavioural, which makes it exactly the kind of invariant that breaks silently on an arrow upgrade.

**Fix**: add one test that slices a probe batch (non-zero offset, parent materially larger than the slice), drives it through the fast path, and asserts:
- per-row data values are correct for the SLICE's rows, not the parent's;
- per-row `_offset` / `_key` / `_headers` / `_event_time` are the slice's, not the parent's — this is the assertion that would catch an offset bug;
- `Arc::ptr_eq` proving the fast path fired (otherwise the test silently becomes a `take`-path test and pins nothing).

Build the slice through `RecordBatch::slice` on a `StreamRecord`'s batch, mirroring what the file reader does.

## G3 (must-fix, comments only) — two test claims are overstated

Both are documentation defects, not code defects. Do not add or change logic.

**(a)** Test 2's comment calls it "THE trap #2150 exists to prevent" and implies it pins the `row_match_count > 1` arm. It does not isolate that arm: probe row 1 also matches **zero** times, so the `== 0` branch clears the flag independently, and deleting the `> 1` arm entirely leaves test 2 green. What test 2 genuinely pins — and this is still valuable — is that `probe_indices.len() == n_probe` is not a sufficient detector. Rewrite the comment to claim exactly that.

**(b)** The `> 1` arm's actual guard is test 3 (`identity_fast_path_one_to_n_fanout_takes_general_path`), which does kill that mutant — but via a `RecordBatch::try_new` length mismatch / the `debug_assert`, not via its own `!Arc::ptr_eq` assertion, so a failure there reports a misleading cause. Add a comment to test 3 recording that it is the `> 1` arm's guard and by what mechanism it fires.

**Do not manufacture a new test for the `> 1` arm** — it is already covered, and a shape where `> 1` is the only guard cannot silently corrupt (every row matching ≥1 with one matching ≥2 gives `total_matches > n_probe`, so probe and build column lengths disagree and `try_new` errors loudly). The arm is correct and stays.

## G4 (doc only) — record the retention tradeoff honestly

Add to `take_or_clone_identity`'s or the fast path's doc comment: under `Arc::clone` a sliced probe column retains its full parent buffer for the joined record's lifetime, where `take` gathered into fresh buffers sized to the output.

State the bound precisely, because both gates got it partly wrong and the PR should not repeat either error:
- Amplification is parent_rows / slice_rows on the emitted slice (the file reader returns `batch.slice(0, want)` as the record; the large `pending` remainder is NOT the emitted record).
- Retention is **per parent batch, not per joined record** — every slice and clone shares one `Arc`, so the cost is (distinct parents with a live joined record) × parent size, not N copies.
- Memory accounting does not under-count: `get_array_memory_size` sums `buffer.capacity()`, i.e. the full parent, so the state store already over-charges sliced batches in the deliberate safe direction (#1676).
- Confined to file/Parquet sources with large decode batches and small emit slices; Kafka poll batches are not slices.

**Do not add a slice-detection branch** to choose `take` over `Arc::clone`. That would create a second fast path, and reliable slice detection is not clean across array types (for a `PrimitiveArray` the offset lives in the `ScalarBuffer`, not in `ArrayData::offset`). If measurement later shows this matters, it is its own issue with its own design.

## Bars

- All 6 existing tests keep passing; no existing test weakened, deleted or `#[ignore]`d.
- No change to the detector, the branch structure, or the `debug_assert`s.
- G1 and G2's new assertions must each be observed FAILING against a deliberate mutation before being accepted. Record both in `agent.log`.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/identity_fast_path/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Join-scoped sweep (keep `--profile unit` — without it the run pulls in `performance::` and `integration::` and fails on contention in subsystems you never touched):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|take_combine|hash_join/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2150 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. It runs `cargo fmt --all` wet — check `git status` after and commit any reformatting.

**Do not re-profile.** These are test and comment changes; they cannot move the measured win.

## Note on CI

`unit::datasource::ipc::schema_preamble_test::test_connect_latency_schema_preamble_p_max_under_1500us` failed in CI on this branch (11184 passed / 1 failed). It is a latency floor in a subsystem this diff does not touch, and the orchestrator has re-run it — a concurrent profiling load on the gate machine is the known cause here. **Not your scope.** Do not investigate it, and do not adjust any threshold.

## Incremental commits (spec §12)

- Commit 1: G1 (system-tail ptr_eq assertions).
- Commit 2: G2 (sliced-probe-batch test).
- Commit 3: G3 + G4 (comment and doc corrections).
- Commit 4, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — not rust-analyzer, not the `LSP` tool.
- Streaming compliance: G1 and G2 are both per-row-identity tests for the system tail, so log `STREAMING-COMPLIANCE-CHECK` / `-AFTER`.

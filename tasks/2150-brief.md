# Brief — #2150: identity-selection fast path in the stream-table join take

**Issue**: https://github.com/velostreamai/velostream/issues/2150
**Parent issue**: #1970
**Worktree**: `/Users/neilavery/RustroverProjects/velostream-2150` — do **NOT** `cd` into it; use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, and absolute paths with Read/Edit.
**Branch**: `perf/2150-identity-selection`, already created off `origin/master` @ `8fb8b7401`.
**Spike that produced this**: #2148 (read its closing comment — it rules out the cross-operator design, so do not revisit selection vectors that travel between operators).

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.** The caller handles all of that.

---

## Objective

`take_combine_stream_table_with_left` (`src/velostream/sql/execution/algorithms/hash_join.rs:732`) materialises the joined batch with three `take`-kernel loops. In the canonical N:1 enrichment join, the probe-side selection is the **identity permutation**, and `take(col, [0,1,2,…,n-1])` is a bit-identical copy. Replace those copies with `Arc::clone`.

Profile: `take_combine_stream_table` is **29.99%** of a 200k-record workload, **25.82% inside the take kernels** (samply 4kHz, 118,063 samples, 96.7% symbolised). Allocator + memmove/memset is ~30% of self-time.

The three loops, at fresh anchors:

| loop | line | indices | columns in the profiled workload |
|---|---|---|---|
| 1 — probe data | `:881` | `probe_indices` | 9 |
| 2 — build data | `:897` | `build_indices_u32` | 3 (from a 10-row table) |
| 3 — probe system tail | `:991` | `probe_indices` | 7 (`SystemCol::COUNT`, incl. the `Map`-typed `_headers`) |

Loops **1 and 3** use `probe_indices` and are the target — 13 of 16 takes in this workload. Loop 2 uses `build_indices_u32`, which is never identity in a real N:1 join; **leave it alone**.

## The design, pinned

Detect the identity case **in the existing probe loop** (`:798-836`) with a single flag. No second pass, no post-hoc scan of `probe_indices`.

When the flag holds, loops 1 and 3 push `Arc::clone(col)` instead of calling `take`. When it does not, both loops behave exactly as today.

### The detector — this is the whole risk, get it right

**`total_matches == n_probe` is WRONG and would ship silent data corruption.** A probe row matching two build rows while another matches zero yields `probe_indices = [0, 0]` with `len == n_probe`. That is not the identity permutation, and `Arc::clone` there emits the wrong rows.

The condition is: **every probe row contributed exactly one match, in ascending order with no gaps.** Equivalently `probe_indices[i] == i` for all `i`. Three things break it, all of which must clear the flag:

1. A NULL-key probe row, skipped at `:800-806` — contributes zero matches.
2. An unmatched probe row (`!row_matched` at `:830`) — contributes zero.
3. A 1:N fan-out — the inner `for &build_row_idx in build_row_indices` loop (`:817`) pushing more than once for one `row_idx`.

The loop already pushes `row_idx` in ascending order (`:825`), so ordering is free — you only need "exactly one push per row, for every row". Derive the flag from that, not from the length.

### Aliasing — already checked, do not re-derive

Loop 3 feeds its result to `max_taken_with_build_side` (`:571`) for `_event_time` / `_timestamp`. That is safe with a shared `Arc`: the `Some` branch calls `max_nullable_i64_arrays(&probe_taken, …)`, which reads by reference and builds a **new** array; the `None` branch returns the input unchanged. No in-place mutation, so no risk of corrupting the source batch through the clone.

Loop 1's output is consumed by the layout loop at `:938`, which already does `Arc::clone(&arrays[index])` — a shared `Arc` changes nothing there.

## Acceptance bars

1. **Bit-identical output.** This is a representation change, not a semantics change. Fast path and general path must be indistinguishable in results — same column count, same order, same values, same nulls.
2. **Per-row identity preserved.** `_offset`, `_key`, `_headers`, `_traceparent`, `_event_time`, `_timestamp`, `_partition` must stay row-aligned. Under a *verified* identity selection this is trivially true, and that is the entire safety argument — so the detector's correctness IS the per-row-identity argument. This touches the streaming-compliance list in the policy: log `STREAMING-COMPLIANCE-CHECK` / `-AFTER` lines.
3. **Tests that fail without the fix — the `[0,0]` trap specifically.** Required coverage:
   - A **1:N fan-out** batch (one probe row matching 2+ build rows) → general path, output matches today's.
   - The **`len == n_probe` decoy**: one probe row matching twice, another matching zero, so `probe_indices.len() == n_probe` while the selection is not identity. This is the test that distinguishes a correct detector from the wrong one. It must fail if the detector is a length check.
   - A **NULL-key** probe row present → general path.
   - A **partial-match** batch (some probe rows unmatched) → general path.
   - A clean N:1 batch → fast path, output identical to the general path. Assert the *output*, not the internal flag, unless you expose the flag deliberately.
4. **Change confined to `hash_join.rs`.** No signature change, no new public API, no cross-operator contract change. If you find yourself editing a second `src/` file, that is a STOP.
5. **No dual path at the API level.** One function, one entry point, an internal branch. Do not add a `take_combine_stream_table_fast` alongside the existing one — per policy §Production-wiring, an additive helper is forbidden.

## Measurement

After the change, re-profile and report the delta:

    ./scripts/profile.sh --label 2150-identity --records 200000

Report `take_combine_stream_table` inclusive % and the take-kernel share, before and after. Master's numbers are the ones above.

**Do not run the nexmark or tier benchmark sweeps.** The profile is the arbiter here.

**Count each sample once.** A prior measurement on this family inflated its numbers by summing every matching symbol per stack, double-counting stacks containing two matches. If you aggregate per-symbol, deduplicate by stack.

The **time** saved is UNVERIFIED and may be well under the 25.82% — the samply data aggregates all three call sites, so the share attributable to loops 1+3 is not separated. The 13/16 call-count reduction is certain. **Report what you measure, including a disappointing result.** A small win honestly measured is the deliverable; a flattering number is not.

## Gate

`./run-commit.sh --fast` from the worktree root, once, and read the log path it prints. Then `/check-code`.

## STOP conditions

- An existing test fails in a way that suggests the identity case is **not** actually bit-identical — that would mean `take` does something the general path relies on beyond copying. Report it; do not paper over it.
- The detector cannot be computed in the existing loop without a second pass over the batch.
- The change needs a signature change or a second `src/` file.
- The profile shows **no** improvement, or a regression. That is a legitimate finding — report it rather than hunting for a number that looks better. It would mean the take kernels' cost is dominated by loop 2, which is information worth having.
- You are tempted to widen scope into filter/projection fusion. That is explicitly deferred in #2150, conditional on this issue's re-profile.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — **not** rust-analyzer, **not** the `LSP` tool.
- `#2149` is in flight on `fix/2149-dedup-layout-seed`, touching `execution/join/layout.rs` and `processors/join.rs`. It does **not** touch `hash_join.rs`, so you should not collide — but do not rebase onto it or depend on it.
- Commit incrementally: the detector + loops as one commit, tests as their own. A single squashed end-state commit makes the review harder than it needs to be.

# Brief — #2150 gate fixes (F1, F2)

**Issue**: https://github.com/velostreamai/velostream/issues/2150
**Parent issue**: #1970
BRANCH: perf/2150-identity-selection
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2150

Already checked out on that branch at `62799aecd`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, and absolute paths with Read/Edit. The one exception is `./run-commit.sh --fast` (subshell form below).

Your #2150 implementation landed and gated green, and the measured win held up on independent verification — detector logic, the decoy test's discrimination, and the `Arc`-aliasing safety argument all check out. These are two findings from the orchestrator's `/check-code` pass. **Do not change the detector or the fast-path design** — both are pinned and verified correct.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## F1 — test the one path where the shared `Arc` escapes the function

All 5 of your tests pass `None` for `build_event_time` and `build_timestamp`, so `max_taken_with_build_side`'s `Some` branch never receives an `Arc::clone`d array in any test. That branch is the **only** place the shared array leaves `take_combine_stream_table_with_left`, and `build_event_time: Some(...)` is a real production shape (the stream-stream path supplies it), not a hypothetical.

Your safety argument for it is correct — `max_nullable_i64_arrays` reads `&probe_taken` and builds a new array; the `None` branch passes through — and that is exactly why it needs pinning: nothing in the test suite would notice if a future edit made it mutate in place, and the corruption would land in the **source probe batch**, not just the output.

**Add one test** to `tests/unit/sql/execution/processors/join/identity_selection_fast_path_test.rs`:

- A clean N:1 batch so the fast path fires (same shape as `identity_fast_path_clean_n1_batch_preserves_row_identity_and_shares_arc`).
- Pass `Some(...)` for **both** `build_event_time` and `build_timestamp`, with build-side values chosen so that the max is the build value for at least one row and the probe value for at least one other — a uniform winner would pass even if one side were ignored entirely.
- Assert the output `_event_time` and `_timestamp` are the correct elementwise max per row.
- **Assert the probe batch's original `_event_time` / `_timestamp` columns are byte-unchanged after the call.** This is the assertion that pins the no-in-place-mutation invariant; without it the test only re-checks the max arithmetic.

Name it for what it pins, e.g. `identity_fast_path_max_with_build_side_does_not_mutate_shared_probe_columns`.

## F2 — the error label is now built eagerly on the hot path

Your `take_or_clone_identity` refactor took the label as `&str`, so both call sites build it unconditionally:

    src/velostream/sql/execution/algorithms/hash_join.rs   &format!("probe col {col_idx}")        (9 per call)
    src/velostream/sql/execution/algorithms/hash_join.rs   &format!("system col {sys_col_idx}")   (7 per call)

At `8fb8b7401` the `format!` sat **inside** the `map_err` closure, so it allocated only on failure. Now it is **16 `String` allocations per probe call on the success path** — including the identity fast path, whose whole purpose is to avoid allocation. This is a regression the refactor introduced, on the exact path the issue optimises.

**Make the label lazy.** Either is acceptable:
- `label: impl FnOnce() -> String`, invoked inside `map_err`; or
- pass `col_idx: usize` plus a `&'static str` kind ("probe col" / "system col") and format inside `map_err`.

The resulting error message text must be **unchanged** — verify by reading the final `format!`, as you did for the earlier refactor.

## Bars

- All 5 existing #2150 tests pass unchanged, plus your new one. No edits to existing tests — if one needs changing, STOP and report.
- The detector, the fast-path branch structure and the `debug_assert` cross-checks stay exactly as they are.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/identity_fast_path/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Join-scoped sweep (keep `--profile unit` — without it the run pulls in `performance::` and `integration::` and fails on contention in subsystems you never touched):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|take_combine|hash_join/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2150/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2150 && ./run-commit.sh --fast)

Read the log path it prints and grep it. Do not re-run to get different output. It runs `cargo fmt --all` wet — check `git status` afterwards and commit any reformatting.

**No re-profile needed.** F2 removes allocations and F1 adds a test; neither can reduce the measured win. Do not spend a profiling run on this.

## Incremental commits (spec §12)

- Commit 1: F2 (lazy label).
- Commit 2: F1 (the new test).
- Commit 3, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — not rust-analyzer, not the `LSP` tool.
- Single-file targeted edits: `Edit` is correct, not `ast-grep`.
- Streaming compliance: F1 is squarely a per-row-identity test for `_event_time`/`_timestamp`, so log `STREAMING-COMPLIANCE-CHECK` / `-AFTER` lines for it.

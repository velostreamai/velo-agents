# Brief — #2149 gate fixes (F1, F2)

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

**Worktree**: `/Users/neilavery/RustroverProjects/velostream-2149` — already checked out on branch `fix/2149-dedup-layout-seed` at `cdb376cf5`. Continue on that existing branch; do not cut a new one. **Do NOT `cd` into it**; use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, and absolute paths with Read/Edit.

Your own #2149 work landed and gated green. These are two findings from the orchestrator's `/check-code` pass on it. Both are contained. **Do not redesign anything** — the constructor-side dedup placement stays exactly as you built it.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## F1 — remove the now-redundant caller-side dedup (hot path)

Three sites still call `dedup_seed_fields` explicitly before handing the seed to a constructor that now dedups internally:

    src/velostream/sql/execution/processors/join.rs:639   (merge_join_records_with_aliases)
    src/velostream/sql/execution/processors/join.rs:694   (combine_records_with_nulls)
    src/velostream/sql/execution/processors/join.rs:915   (combine_records_with_nulls_for_probe)

all of the shape `JoinLayout::from_existing_multi_source_fields(&dedup_seed_fields(left_fields))`.

These are **per-record** paths — reached from `process_inner_join` / `process_right_join` / the outer-join arms, once per record — so each record currently pays two O(n) scans and **two `FxHashSet` allocations**. The comment you left at `join.rs:68-72` calls the second scan "idempotent and free": idempotent yes, free no, because `FxHashSet::with_capacity_and_hasher(fields.len(), Default::default())` allocates every call, including on the all-unique path the `Cow::Borrowed` exists to keep cheap.

Keeping them also contradicts the change's own rationale ("one mechanism, not call sites kept in step") while keeping three call sites in step.

**Do:**
1. Reduce all three to `JoinLayout::from_existing_multi_source_fields(left_fields)`.
2. Make `dedup_seed_fields` private to `layout.rs` — drop `pub(crate)`.
3. Delete `pub(crate) use layout::dedup_seed_fields;` from `src/velostream/sql/execution/join/mod.rs:71`.
4. Remove `dedup_seed_fields` from the `use` block at `processors/join.rs:21`.
5. Delete the now-stale explanatory comment block at `processors/join.rs:68-72`.

This is behaviour-preserving by construction: the constructor applies the identical first-wins dedup, so output is byte-identical. Your existing 9 tests must all still pass unchanged — if any fails, STOP and report, because that would mean the constructor dedup is not equivalent to the caller-side one and F1's premise is wrong.

## F2 — docstrings state the contract, not the review history

The new docstrings on `dedup_seed_fields` and `from_existing_multi_source_fields` recount the review trail: which PR guarded how many of eleven call sites, which review checked constructors but not callers, the retracted `_dedup_derivation`. The operator's standing rule is **no PR narrative in docstrings** — that history belongs in the PR body and `.agents/tasks/2149.json`, not in `src/`.

**Rewrite both docs to state the contract only:**
- What the function guarantees: the seed is deduplicated first-wins, so `entries()` carries no duplicate names.
- Why first-wins is safe: every consumer resolves a Left-side entry's value by field NAME, a pure function of `(record, name)`, so which duplicate instance survives cannot change a value — it only fixes the survivor's position deterministically. Relative order of distinct names is preserved, so an all-unique seed behaves identically to before.
- Why the guarantee lives in the constructor: the selecting branch tests only `name.contains('.')`, which is a heuristic, not a provenance check — seeds arrive from record data (`StreamRecord::data_field_names()` does not enforce uniqueness; `FieldName` is an unrestricted `Arc<str>`), so the constructor cannot assume an already-unique seed.
- The zero-copy note: unchanged input returned when there is nothing to dedup.

Keep a single `#2149` issue reference for traceability. Cut the rest. Target roughly a third of the current length. Do **not** delete the substantive reasoning above — condense the history, keep the invariant.

## Bars

- All 9 existing #2149 tests pass unchanged. No test edits — if a test needs changing, that is a STOP.

## Validation commands

Inner loop, after each edit:

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

The 9 #2149 tests must stay green — they are the whole safety net for F1, since F1's premise is that the constructor dedup is equivalent to the caller-side one:

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/duplicate_seed|dedups_duplicate/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Wider sweep before the gate (keep `--profile unit` — without it the run pulls in `performance::` and `integration::` and fails on contention in subsystems you never touched):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, run ONCE from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep that for failures. Do not re-run it to get different output. It runs `cargo fmt --all` wet, so check `git status` afterwards and commit any reformatting.

## Incremental commits (spec §12)

Commit each unit of work as soon as it is green — do not batch F1 and F2 into one commit at the end. A timeout or a STOP after an uncommitted hour loses all of it.

- Commit 1: F1 (the three call sites + visibility + imports + stale comment).
- Commit 2: F2 (the two docstring rewrites).
- Commit 3, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) for discovery — not rust-analyzer, not the `LSP` tool.
- Single-file targeted edits: `Edit` is correct here, not `ast-grep` (no rename, no signature change, ≤4 sites per file).
- A third finding (the constructor's per-call `FxHashSet` allocation, where a linear scan over ≤16 columns would be allocation-free) is deliberately **out of scope** — it is not a regression from this diff, and it needs measurement first.

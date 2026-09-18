# Brief — PR #2152 round 3: P2 — the guard covers one of three inputs to the name it protects

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**PR**: https://github.com/velostreamai/velostream/pull/2152 (gate:blocked)
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Already checked out at `57226bf7b`. **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Read both round-3 reports on the PR. One approved-with-findings on a narrower issue; `check-code` found a **P2 reachable from plain SQL**.

**This is the fourth consecutive round where an enumeration looked complete and was not, and this one is the orchestrator's fault.** Round 2 concluded "the only way to make the split land early is a probe column literally named `__vs_build__.x`", I adjudicated that as correct, and your R3 guard implemented exactly that scope. The enumeration missed two other inputs. You implemented the brief faithfully; the brief was wrong.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## P2 — the sentinel can enter the joined schema through `from_alias` or `left_source`

`reject_probe_field_carrying_build_sentinel` checks `probe.data_field_names()` — the raw, pre-take-combine field names. But the name that `probe_build_data_split` scans is **synthesized** by `JoinLayout::append_relation` as `canonical = alias.unwrap_or(source)` + `'.'` + field (`layout.rs:339,354`). The guard covers the *field* axis and leaves **`from_alias`** and **`left_source`** unchecked.

Reachable from ordinary SQL — `tokenizer.rs:392` is `_ if ch.is_alphabetic() || ch == '_'`, so a leading underscore is a legal identifier start and `__vs_build__` is a legal alias or stream name (verified):

    SELECT * FROM left_stream AS __vs_build__
      INNER JOIN right_stream ON __vs_build__.k = right_stream.k

With probe data `[k, a]` and build data `[k, c]`:

1. `probe.data_field_names()` = `["k","a"]` → **guard passes**.
2. No probe name contains `'.'`, so `hash_join.rs:924` takes the `from_sides` branch: left canonical `"__vs_build__"`, right canonical `BUILD_COLUMN_SENTINEL`. Joined data schema becomes `[__vs_build__.k, __vs_build__.a, __vs_build__.k, __vs_build__.c]` — and `shadow_or_append` (`layout.rs:400`) collapses the colliding `__vs_build__.k`, overwriting its provenance to **Right**. The probe's `k` column is silently replaced by the build's.
3. `probe_build_data_split` matches at **index 0** → `(n_probe_data, n_build_data) = (0, 3)`.
4. `duplicate_aliased_data_columns` then emits `right_stream.k, right_stream.a, right_stream.c` — the probe's `a` re-emitted under the **build** relation's qualifier. No `Err`, no panic.

Same class as the defect R3 fixed. Note step 2 is an independent defect from step 3: the column collapse happens regardless of the split, so fixing only the split would still leave the probe's `k` overwritten.

Corollary: the comment at `join.rs:1243-1244` asserting the sentinel-prefixed name "never collides with a real probe column" is **false** under this input. Correct it.

### Pinned fix

Extend the pre-flight to reject the sentinel arriving via **any** of the three axes, using the shared `is_build_sentinel_prefixed` predicate where applicable:

- a probe data field name (already done),
- `from_alias` equal to `BUILD_COLUMN_SENTINEL`,
- `left_source` equal to `BUILD_COLUMN_SENTINEL`.

For the alias/source axes the check is equality against the sentinel, not a prefix test — the canonical is the whole alias, and `'.'` + field is appended after. Keep it one function with one error shape; do not add a second guard elsewhere.

Error message must name which axis was rejected and that the token is reserved-internal, so an operator can act on it.

## P3 — `strip_build_sentinel` tests length, not prefix

`orig.name().get(sentinel_prefix_len..)` is a byte-range index: it returns `Some` for **any** name of ≥13 bytes, so a column named `longcolumnname_here` yields `Some("ame_here")` — a garbled name, silently — where the docstring (`:1520-1524`) promises `Err`. It errors only for names *shorter* than the prefix.

This is the defensive check the split's own doc leans on, and it cannot detect what it claims. Latent today (under normal operation the range is exactly the build block), but it is free to fix and belongs with this commit's "one predicate, no drift" framing.

**Fix**: use `is_build_sentinel_prefixed` (or `strip_prefix`) so the check tests the prefix, and return `Err` when it is absent. Keep the existing error text's intent.

## Bars

- All existing tests keep passing (23 in `join_layout_order`, 1,265+ in the join sweep). None deleted, skipped, `#[ignore]`d or weakened.
- **Red-first for the P2**, both sub-cases: one test aliasing the left side `__vs_build__` and one with `left_source` literally `__vs_build__`. Each must be observed failing before the fix — and assert on the *emitted column names*, since the pre-fix behaviour is silent (no error, no panic). Record both failure texts in `agent.log`.
- A red-first test for the P3 length-vs-prefix bug if you can construct one that reaches `strip_build_sentinel` with a non-prefixed ≥13-byte name; if it is genuinely unreachable today, say so explicitly rather than asserting a weaker thing.
- `layout.rs:47-51` doc block still out of scope.

## Scope note — do not expand

A structural fix exists: have `take_combine_stream_table_with_left` **return** the probe/build split so the consumer never re-derives it from names, which would delete the name axis entirely. That is the cleaner root fix and it is deliberately **out of scope for this round** — the guard is needed regardless, because step 2's column collapse happens before any split is computed. Do not refactor the signature. If you think the guard alone leaves a hole, STOP and report rather than widening.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/join_layout_order|sentinel|probe_stream_stream/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Join-scoped sweep (keep `--profile unit`):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|layout|take_combine/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. `cargo fmt --all` runs wet — check `git status` after and commit any reformatting.

## Incremental commits (spec §12)

- Commit 1: the two red-first P2 tests.
- Commit 2: the P2 guard extension + the `join.rs:1243-1244` comment correction.
- Commit 3: the P3 `strip_build_sentinel` prefix check (+ test if reachable).
- Commit 4, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) — not rust-analyzer, not the `LSP` tool. Both round-3 gates reported the index stale on exactly this delta's files; `zg status` will confirm, and exhaustive grep over `src/` is the stated fallback.
- Streaming compliance: the P2 misattributes column provenance in emitted output — log `STREAMING-COMPLIANCE-CHECK` / `-AFTER`.

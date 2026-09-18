# Brief — PR #2152 round 4: stop enumerating sentinel axes; make collision impossible. Plus a per-row regression I missed.

**Issue**: https://github.com/velostreamai/velostream/issues/2149
**PR**: https://github.com/velostreamai/velostream/pull/2152
**Parent issue**: #1970
BRANCH: fix/2149-dedup-layout-seed
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2149

Already checked out at `e4eb35de5` (pushed). **Do NOT `cd` into it** — use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, absolute paths with Read/Edit. Exception: `./run-commit.sh --fast` (subshell form below).

Two items. **Neither is a defect in your work** — S1 replaces a design I pinned, after you found the axis that showed the design was the problem; S2 is a regression I twice dismissed as out-of-scope on the record.

You are **authorized to commit** to this branch. **Do not push. Do not open a PR. Do not merge. Do not comment on any GitHub issue.**

---

## S1 (must-fix) — make the sentinel uncollidable instead of guarding each axis

Four collision axes have now been found across three rounds on the same mechanism:

| axis | found by | round |
|---|---|---|
| probe data field name | gate | 2 |
| `from_alias` | gate | 3 |
| `left_source` | gate | 3 |
| `join_clause.right_alias` | **you**, flagged at the end of round 3 | 3 |

That is the signal to stop patching axes. The root cause is that `BUILD_COLUMN_SENTINEL` is `"__vs_build__"` — a **legal SQL identifier**, living in a namespace users can write into.

**It does not have to be.** `tokenizer.rs:392` starts an identifier on `is_alphabetic() || '_'` and continues on `is_alphanumeric() || '_'`, so an alias or source name can only ever contain `[A-Za-z0-9_]`. Quoted text becomes `TokenType::String`, and the tokenizer's own comment at `:322-326` states that a quoted form "is not a name at all until something parses it as one, and nothing does today."

So: **change the sentinel to contain one character outside `[A-Za-z0-9_]`** — a control character such as `\u{1}` is the clearest choice — and all three identifier-derived axes (`from_alias`, `left_source`, `right_alias`) become **impossible by construction**, including any axis nobody has enumerated yet.

Constraints to verify before you change it:
- The sentinel is confined to `processors/join.rs` (15 references, verified). Check that holds after your change and that nothing outside that file depends on the literal.
- The prefixed name only ever lives in an internal joined Arrow schema and is stripped before output. Arrow field names are arbitrary UTF-8, so a control character is valid. **Confirm** it is never persisted, serialised to a sink, or sent to a schema registry — if you find such a path, STOP and report.
- Keep it greppable and debuggable: something like `"__vs_build\u{1}__"` reads fine in logs and diagnostics while being unproducible as an identifier.

**Keep the field-axis guard.** Field names come from source data (Kafka/Avro/JSON/Parquet column names), not from SQL identifiers, so arbitrary UTF-8 is possible there and the guard you already built and mutation-tested remains load-bearing.

**Keep the alias/source guards too**, demoted to defence-in-depth: they are cheap, and a future tokenizer change could reopen what the character choice closes. Update their doc comments to say the correctness argument now rests on the character class, with the tokenizer citation, and that the guards are belt-and-braces rather than the primary mechanism.

**Fix the fourth axis** (`join_clause.right_alias`) as part of this — with the new sentinel it cannot collide, but add it to the guard for symmetry and note it in the docstring.

Existing tests must still pass unchanged. Add one test asserting the sentinel contains a character that `tokenizer.rs`'s identifier rules cannot produce — that is the invariant the whole argument rests on, and it should fail if someone "tidies" the constant back to a plain identifier.

## S2 (must-fix) — `dedup_seed_fields` added a per-row allocation at 8 call sites

I dismissed this twice as "not a regression, the #2145 baseline already paid one hash set". **That was wrong.** #2145 wrapped 3 call sites; #2149 moved the dedup into the constructor, which has **11** callers — so 8 sites now pay a cost they never paid before, and I signed it off without measuring.

The worst is genuinely per-row:

    stream_table_join.rs:487   for fields in candidates {
    stream_table_join.rs:488       self.build_combined_row_values(...)
    stream_table_join.rs:765           JoinLayout::from_existing_multi_source_fields(stream_fields)

`build_combined_row_values` runs **once per candidate row** in a stream-table join. Each call now does `FxHashSet::with_capacity_and_hasher(fields.len(), …)` — which **allocates** — plus an O(n) insert loop. The `Cow::Borrowed` fast path avoids cloning the `Vec` but not building the set, so the all-unique case (essentially every real batch) pays the allocation for nothing.

**Pinned fix**: for small slices, dedup with an allocation-free linear scan instead of a hash set. Typical data-column counts here are well under 32, where a linear `contains` over `&[FieldName]` beats building a hash set outright — `FieldName` is `Arc<str>`, so most comparisons hit pointer equality first. Keep the `Cow::Borrowed` zero-copy return for the all-unique case.

Pick the threshold by measurement, not by taste: use a hash set above the crossover if you can establish one, or use the linear scan unconditionally if the crossover is beyond any plausible column count — and say which, with numbers.

**Measure it.** Add a microbenchmark, or use an existing harness, reporting before/after for a representative all-unique seed (~8-16 columns) at per-row call frequency. Report the numbers in your final message. **A result showing the change is neutral is a perfectly good outcome** — report it as measured rather than hunting for a better-looking figure. My reasoning is what got this wrong, so reasoning is not what should settle it.

Do **not** re-add caller-side dedup, and do not change the dedup's semantics: first-wins, order-stable, `Cow::Borrowed` when already unique.

## Bars

- All existing tests keep passing (`join_layout_order` 23+, join sweep 1,265+). None deleted, skipped, `#[ignore]`d or weakened.
- S1: the sentinel's character-class invariant must have a test.
- S2: report measured before/after numbers.
- `layout.rs:47-51` doc block still out of scope.

## Validation commands

    cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

    cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/join_layout_order|sentinel|probe_stream_stream|stream_table/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Join-scoped sweep (keep `--profile unit`):

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod -E 'test(/join|layout|take_combine/)' --manifest-path /Users/neilavery/RustroverProjects/velostream-2149/Cargo.toml

Final gate, ONCE, from the worktree root:

    (cd /Users/neilavery/RustroverProjects/velostream-2149 && ./run-commit.sh --fast)

Read the log path it prints and grep it; do not re-run for different output. `cargo fmt --all` runs wet — check `git status` after and commit any reformatting.

## Incremental commits (spec §12)

- Commit 1: S1 — sentinel character change + fourth axis + doc updates + the character-class test.
- Commit 2: S2 — allocation-free dedup + measurement.
- Commit 3, if `--fast` reformats anything: `style: cargo fmt`.

## Notes

- `~/.claude/rules/velo-impl.md` applies in full. Use `~/.agents/bin/zg` (absolute path) — not rust-analyzer, not the `LSP` tool. Prior rounds found the index stale on this branch's files; `zg status` confirms, exhaustive grep over `src/` is the fallback.
- Streaming compliance: S1 changes internal column naming in joined batches; S2 touches a per-row path. Log `STREAMING-COMPLIANCE-CHECK` / `-AFTER` for both.
- Hot-path discipline applies to S2: plan-time over per-row, allocations are first-class.

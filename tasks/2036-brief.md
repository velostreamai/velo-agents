# #2036 — `column_names()` must report declared columns, not just observed ones

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2036
BRANCH:   fix/2036-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## The defect

`UnifiedTable::column_names()` is consumed as **"the relation's column set"** —
what a table *has*. Its two implementations both answer a different question:
what a table has *so far observed*.

- `OptimizedTableImpl::column_names()` (`unified_table.rs:2844`) reads only
  `self.column_indexes` — the union of columns seen in ingested rows.
- The default trait impl (`unified_table.rs:307`) unions `iter_records()` keys.

Neither consults `self.schema`, which `set_schema` populates
(`unified_table.rs:1829`) and which `schema()` already returns (`:2836`).

**So a table created with a schema that has not yet loaded any rows returns
`[]`.**

## Why it matters

The OUTER-join null-pad paths in `stream_table_join.rs` use `column_names()` to
decide what to NULL-fill. Its own comment states the contract: *"the RELATION's
full column union, not one sampled row"*. Against a schema-attached, row-empty
table, an unmatched OUTER row is padded with **no** table columns — and a legal
`t.col` reference then fails to resolve, when the schema says perfectly well that
`col` exists.

This was masked until now. The `EmitWithNulls` arm used to fabricate
`id`/`name`/`value`; for a table that genuinely had `id`/`name`, two of those
were accidentally right. #2025 removed the fabrication — correctly, it is the
class #2000 deleted — which makes this root cause visible instead of papered
over. The fix also improves the **pre-existing** LEFT-join no-match pad, which is
why it was not #2025's to make.

## The fix

Both impls return the **union** of observed columns and the attached schema's
field names, sorted and deduplicated. With no schema attached, behaviour is
unchanged — observed-only is right in that case.

The default impl can consult `self.schema()` generically: it is a trait method,
so `Table` and `CompactTable`, which use the default, are fixed by the same edit.

**Union, not replacement.** A table can legitimately carry columns its schema
does not declare. A fix that swaps observed for declared passes the obvious test
and is wrong — see the second required test below.

## Do NOT invent a column name

If there is no schema and no observed row, the honest answer is the **empty
set**. Guarding the empty case by fabricating names is precisely what #2000 and
#2025 removed, and the gate on #2035 agreed the honest empty set is right. This
issue exists because the *schema* was being ignored, not because empty is wrong.

## Two required tests

1. **The discriminating one.** Construct an `OptimizedTableImpl`, `set_schema`
   with a schema declaring a column, ingest **no** rows, assert `column_names()`
   contains it. **Verify it FAILS against master**, which returns `[]`.
2. **The union one.** A row carrying a column the schema does not declare, plus a
   declared column no row carries — both must appear. This is the test that
   catches a replace-instead-of-union fix.

**Commit your production change BEFORE any revert-check.**
`git checkout HEAD -- <path>` on an uncommitted edit destroys it, and on a fresh
branch `HEAD` *is* master. That silently wiped a fix twice in a prior session and
produced a probe that looked like evidence and was not.

## Scope

**Edit `unified_table.rs` only.**

- `sql.rs:271` delegates to the inner `OptimizedTableImpl` — confirm, do not edit.
- `decorrelated_index.rs:241` and `:445` return statically-known index columns and
  have no attached schema. Expected out of scope — **say so explicitly in your
  report** rather than silently skipping them.
- `stream_table_join.rs` is the **consumer**. If the fix seems to require changing
  it, the fix is in the wrong place.

Update the doc comments on both impls: the default impl's block explicitly
promises correlated-subquery callers a complete set, and must not now be
misleading about what "complete" means.

## Known adjacent problem — report, do not fix

The default `column_names()` walks `iter_records()`, and
`CompactTable::iter_records` **decompresses and materializes every row**. #2035
had to make its call sites lazy for exactly that reason. Any caller treating
`column_names()` as cheap is wrong today. Caching or a signature change is a
separate design decision — note it in your report, do not implement it.

## STOP conditions

**STOP and report** — do not work around any of these:

1. A schema-attached, row-empty `OptimizedTableImpl` does **not** return `[]` on
   current master — that is the premise of the issue.
2. Unioning the schema into the default impl breaks correlated-subquery
   inner-vs-outer classification (`correlated_subquery_decorrelate.rs`,
   `select/subquery.rs`) — that classification is what the default impl's doc
   block is about, and changing it is a separate decision.
3. More than ~10 pre-existing tests fail — report the list before changing any.
4. You would need to delete or `#[ignore]` a test.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-2036/Cargo.toml \
  > /tmp/2036.log 2>&1
grep -E "^ *Summary" /tmp/2036.log
grep -E "^ *FAIL " /tmp/2036.log | awk '{print $NF}' | sort -u
```

**That is NOT the gate** — it pulls broker-dependent Kafka integration tests that
fail with `AllBrokersDown` on a machine without a broker, which killed a dispatch
in a prior session. The gate is:

```
(cd /Users/neilavery/RustroverProjects/velostream-2036 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards run `git -C ... status` and commit
any reformatting.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1749] #2036:`. Do NOT push. Do NOT
open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. If a test needs SQL,
grep the parser and grammar docs — `docs/claude/SQL_GRAMMAR_RULES.md`,
`docs/sql/PARSER_GRAMMAR.md`, `src/velostream/sql/CLAUDE.md`. Absent means
unsupported. **DO NOT GUESS SQL SYNTAX.**

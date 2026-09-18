# #1987 — the batch stream-stream JOIN arm must apply the SELECT projection

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1987
BRANCH:   fix/1987-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## Read these two first

1. `.agents/tasks/1987-analysis.md` on master — the Stage-1, merged as #2020. It
   went through **four** revisions; §0 records what each earlier revision got
   wrong. Read §0, §1, §4, §5.
2. **The correction comment on #1987** (posted after the analysis merged). It
   overturns one of §5's requirements — see "Scope" below.

## The defect

The batch-eligible stream-stream JOIN arm applies `WHERE` and then returns the
packed batch **directly**. The SELECT list is never applied.

```sql
SELECT a.auction_id, a.category, r.tier
FROM auction a JOIN person r ON a.seller = r.person_id
WHERE a.category = 10
```

emits **five** columns:
`[a.seller, r.person_id, a.auction_id, r.tier, a.category]`.

This is the projection sibling of **#1413/#1414**, where these *same* fast paths
silently dropped `WHERE`. The pattern: a fast path returns the packed batch and
skips a clause the query asked for. Pre-existing — it became visible only when
#1988 collapsed the dual bare/qualified spelling that masked it.

## Scope — ONE arm, not two. The analysis is wrong on this.

`apply_where_to_joined_batch` has **three** call sites in `select.rs`:

| site | status |
|---|---|
| `:1086` | **IN SCOPE** — gated by `is_eligible_join_stream_stream`; this is the reachable stream-stream arm the reproduction hits |
| `:979` | **DEAD — do not touch.** Gated at `:866` by `is_eligible_equi_conditions`, which returns `false` for `NonEqui` (`key_extractor.rs:1446`), and `builder.rs:478` constructs **only** `NonEqui`. `select.rs:1194-1199` says so in-code. |
| `:1200` | **INVESTIGATE AND REPORT.** Described in-code as *"the REAL reachable stream-TABLE multi-row-match code path"*. The analysis never mentions it. Determine whether it also drops the projection. If it does, that is the genuine stream-TABLE instance §5 thought `:979` was — **report it; do not silently double the diff.** |

Fixing `:979` would be work on dead code, and worse, would make an unreachable
arm look exercised.

## Mechanism — PINNED to C (Arrow `RecordBatch::project`)

Mirror `select.rs:1731-1750` (#594 "Case 6"): resolve indices → `batch.project`
→ `StreamRecord::from_batch`. Zero-copy, batch-native, no per-row rebuild.

**A** (the `interval_join.rs` per-row template) and **B** (decoupling
`apply_post_join_select`) are both rejected — see §5. Do not substitute.

## Three requirements, each found by a separate blocked review round

**1. A plan-time ELIGIBILITY gate — this is the one that bites.**
`RecordBatch::project` can neither rename a column nor evaluate an expression.
This path has **no SELECT-shape fall-through**: the fall-throughs that exist
(`:855`, `:866`, `:919`, `:1048`) are all on join-shape or state grounds, and
`is_eligible` **Case 7** (`eligibility.rs:176-190`) returns `true` for any
`Project { … Join … }` **without inspecting the Project's exprs**. So
`SelectField::AliasedColumn` and `SelectField::Expression` reach this arm today.
Without a gate you will mis-name aliased columns and drop computed ones — *the
same silent-clause-drop family as #1987 itself*.

**2. A QUALIFIED-AWARE resolver.** `resolve_col_indices` is an exact
`schema().index_of(name)` with a hard error on miss, and the packed batch carries
canonical **qualified** names (`JoinLayout`: one qualified spelling per relation,
no bare fallback). An unqualified `SELECT auction_id, tier FROM auction a JOIN
person r …` is legal SQL and hard-errors today.

**3. Append the system-column indices BY HAND** — `n_data + 0..SystemCol::COUNT`,
copying `limit_projection.rs:132-141`. **`StreamRecord::from_batch` PANICS** when
a required system column is missing (`builder.rs:1489-1508`).
**Do NOT call `compute_limit_project_indices`** — it takes a `plan::Schema` and is
gated by `is_safe_project_over_limit` requiring `Project{Limit{Scan{filters:[]}}}`,
none of which this arm has. Copy the append shape, not the function.

Also: **`SELECT *` must short-circuit** before index resolution.

## The test that pins the wrong behaviour

`tests/unit/sql/execution/processors/join/batch_join_where_test.rs` **asserts the
current, wrong output on purpose** — its comment states the projection is dropped
and why asserting the bare name would re-hide it.

**Update it.** This is the one existing test this change legitimately rewrites:
its qualified-spelling assertions and the `collect_sorted_int_field` rationale
both change meaning post-fix. Do not delete it, do not `#[ignore]` it.

## Verify the new test bites — and COMMIT FIRST

The new test must FAIL against master (which emits 5 columns).

**Commit your production change BEFORE any revert-check.**
`git checkout HEAD -- <path>` on an uncommitted edit destroys it, and on a fresh
branch `HEAD` *is* master. That silently wiped a fix twice in a prior session and
produced a probe that looked like evidence and was not.

## STOP conditions

**STOP and report** — do not work around any of these:

1. The reproduction does **not** show 5 columns on current master — that is a
   valuable negative result and the premise of the whole issue.
2. The eligibility gate cannot be expressed at plan time without changing
   `PhysicalStrategy` or the `LogicalPlan` shape — structural decision, not yours.
3. Site `:1200` also drops the projection and fixing it would double the diff —
   scope is the maintainer's call.
4. More than ~10 pre-existing tests fail — report the list before changing any.
5. You would need to delete or `#[ignore]` a test.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-1987/Cargo.toml \
  > /tmp/1987.log 2>&1
grep -E "^ *Summary" /tmp/1987.log
grep -E "^ *FAIL " /tmp/1987.log | awk '{print $NF}' | sort -u
```

**That is NOT the gate** — it pulls broker-dependent Kafka integration tests that
fail with `AllBrokersDown` on a machine without a broker, which killed a dispatch
in a prior session. The gate is:

```
(cd /Users/neilavery/RustroverProjects/velostream-1987 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards run `git -C ... status` and commit
any reformatting. **`--fast` does NOT build `--release`**; also run
`cargo build --release --no-default-features --bin velo-sql`. A `debug_assert!`
body compiles in release and broke CI that way in a prior session.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1749] #1987:`. Do NOT push. Do NOT
open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Clause order post-#1962:
`SELECT -> FROM -> JOIN -> WHERE -> WINDOW -> GROUP BY -> HAVING -> ORDER BY -> LIMIT`.
References: `docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`,
`docs/sql/COPY_PASTE_EXAMPLES.md`, `src/velostream/sql/CLAUDE.md`.
Reference idiom: `demo/trading/sql/ctas_file_trading.sql`.
**DO NOT GUESS SQL SYNTAX** — grep the parser and grammar docs; absent means
unsupported.

# #1994 — Stage-1 ANALYSIS ONLY: HAVING's input columns resolve by name at runtime

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1994
BRANCH:   fix/1994-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## THIS TASK WRITES NO CODE

You produce a **written analysis**, posted as a comment on #1994. If you find
yourself editing a `.rs` file — or `docs/architecture/name-binding.md` — STOP.

## READ THE CORRECTION COMMENT ON #1994 BEFORE THE BODY

The issue body's central mechanical claim is **wrong**. Working from it will send
you looking for something that does not exist.

**The body says:** *"Within `PlanNode::Aggregate` it rewrites `group_exprs`,
`agg_exprs` and `select_exprs`. `having` is destructured into `..` and never
passed to `rewrite_expr`."*

**There is no `having` field on `PlanNode::Aggregate`.** Verified:

```
$ awk '/^    Aggregate \{/,/^    \},/' src/velostream/sql/plan/logical.rs | grep -E "^\s+[a-z_]+:"
input, group_exprs, agg_exprs, emit_mode, alias_keys,
select_exprs, field_sources, field_keys, uses_inter_field_aliases

$ grep -n "having" src/velostream/sql/plan/logical.rs
(no output)
```

**HAVING is a `PlanNode::Filter` above the `Aggregate`** — which is how
`visit_node` already treats it, via `having_aggregate_input(&input.node)`.

**And its predicate IS rewritten by the main pass:**

```rust
// column_resolution.rs:457 — rewrite_node's Filter arm
PlanNode::Filter { input, predicate } => {
    let input = rewrite_plan(*input, ctx);
    let schema = Arc::clone(&input.schema);
    let effective_ctx = ctx.derive_for(&input);
    let predicate = rewrite_expr(predicate, &schema, &effective_ctx);
```

So HAVING is neither skipped nor destructured away. It is visited.

## The actual defect — this is what you are analysing

`input.schema` for a HAVING `Filter` is the **Aggregate's OUTPUT schema**:
aggregate results and group keys. A raw input column nested inside a HAVING
aggregate argument is **legitimately absent** from that schema, so `rewrite_expr`
correctly leaves it as `Expr::Column`, and it falls to **per-record name
resolution at runtime**.

```sql
HAVING SUM(CASE WHEN side = 'BUY' THEN quantity END) > 0
--                                     ^^^^^^^^
--   a raw INPUT column; not in the Aggregate's output schema
```

The only code that can resolve those against the **source** schema is
`rewrite_having_aggregate_arguments` — and it has exactly **one** caller:

```
$ grep -rn "rewrite_having_aggregate_arguments" src/ | grep -v "fn rewrite_having"
column_resolution.rs:1390:  rewrite_having_aggregate_arguments(predicate.clone(), source_schema, &ctx)
```

That call is inside `visit_node`, on a **clone**, for the completeness gate's
coverage derivation. Its result is passed to `visit_expr` and **discarded**. It
never reaches the executed plan.

## Why the fix is not one line

Both naive directions are wrong:

- **Rewrite the whole HAVING predicate against the SOURCE schema** — breaks
  `HAVING COUNT(*) > 5`, whose reference exists *only* in the output schema.
- **Leave it against the OUTPUT schema** — the status quo, which is the defect.

**One pass with one schema cannot resolve both halves.** That two-schema split is
exactly why `rewrite_having_aggregate_arguments` exists as a separate function.
The candidate fix is *promote the existing diagnostic-only rewrite into the main
pass, applied to aggregate arguments against the source schema, while leaving
aggregate-result references to the existing output-schema pass.*

Whether that is sufficient is the question you are answering. **Do not decide the
shape — analyse it and recommend.**

## Anchors — `grep -n` verified against `8daed48e1`

```
src/velostream/sql/plan/column_resolution.rs:457    rewrite_node's Filter arm — where a fix would land
src/velostream/sql/plan/column_resolution.rs:1390   the ONE caller, diagnostic-only, on a clone
src/velostream/sql/plan/column_resolution.rs:1545   fn rewrite_having_aggregate_arguments
src/velostream/sql/plan/logical.rs                  PlanNode::Aggregate — NO having field
```

`fn having_aggregate_input` is how the walker recognises a Filter as a HAVING and
recovers the source schema + alias ctx. Any main-pass fix needs the same
recognition — that is your reuse point.

## Observe the defect first

The issue names its evidence:
`schema_rich_full_order_flow_imbalance_demo_query_resolves`
(`tests/unit/sql/plan/phase6_avro_loud_fail_test.rs:217`). It has `quantity` — a
real column of a **declared** Avro schema — remaining as `Expr::Column` purely
because the rule never resolved that position.

```
cargo nextest run --no-default-features -E 'test(schema_rich_full_order_flow_imbalance)' --manifest-path /Users/neilavery/RustroverProjects/velostream-1994/Cargo.toml > /tmp/1994.log 2>&1
grep -E "^ *Summary|^ *FAIL" /tmp/1994.log
```

**Use it to observe; do not modify it.** If you cannot observe a declared-schema
column left unresolved under a HAVING, that is a valuable negative result —
report what you tried and stop.

## What to produce

1. **The two-schema split, precisely.** Which HAVING sub-expressions must resolve
   against the source schema, which against the output schema. A concrete example
   of each from a real query.
2. **Is promoting `rewrite_having_aggregate_arguments` into the Filter arm
   sufficient?** The issue claims *"a column nested inside a compound `CASE`
   inside a `HAVING` aggregate is reached by neither"* pass. **Confirm or refute
   that specific case** — read the function's `Case` arm and say.
3. **The module-doc invariant.** `column_resolution.rs` states *"Post-rule, every
   `Expr::Column` remaining in the tree is a column that could not be resolved."*
   Does the fix make that true, or must it be amended to name its exceptions?
4. **Cost.** What does name-based HAVING resolution cost per record today? Does
   the proposed fix add any plan-time or per-record cost? Mark measured vs
   reasoned.
5. **Knock-on to `name-binding.md` §1c condition 2**, which carves HAVING out
   explicitly. How far could the carve-out shrink? **State it; do not edit the
   doc** — that belongs with the implementation.
6. **A recommendation**, with reasoning, explicitly marked as requiring
   maintainer approval.

## STOP conditions

**STOP and report** — do not work around any of these:

1. You find yourself editing a `.rs` file, or `docs/architecture/name-binding.md`
   — this task produces analysis only.
2. You cannot observe the defect (a real declared-schema column left as
   `Expr::Column` under a HAVING). That is a valuable negative result: report
   what you tried and stop, rather than analysing a defect you could not see.
3. The fix appears to require changing `PlanNode::Aggregate`'s shape or adding a
   `having` field — **STOP and report**. That is a structural decision, and it
   contradicts the current design.
4. You cannot determine whether the compound-`CASE`-inside-`HAVING`-aggregate
   case is reached — say so explicitly. "Undetermined, and here is what I could
   not establish" is a valid classification; guessing is not.
5. You have spent more than ~30 minutes without being able to observe the
   defect — **STOP**, write what you tried to `agent.log`, commit what you have,
   and report. A previous dispatch in this session ground for 38 minutes in
   silence and produced nothing, where a negative result would have been useful.

## Validation

```
git -C /Users/neilavery/RustroverProjects/velostream-1994 status --porcelain -- src/ docs/
```

Must print **nothing**. Any entry means you violated the read-only rule.

```
cargo check --no-default-features --manifest-path /Users/neilavery/RustroverProjects/velostream-1994/Cargo.toml
```

Tripwire, not a gate — the tree is unchanged from master.

Redirect output to a file and grep it rather than trusting captured terminal
output. Mark every claim **measured** or **reasoned**; an unmarked estimate
presented as a measurement is a finding against the analysis.

## Incremental commits — MANDATORY

Commit after each section you complete, prefixed `[#1749] #1994 analysis:` — not
once at the end. A timeout or crash must never lose completed work. Small commits
are expected. Write the analysis to `.agents/tasks/1994-analysis.md` in the
worktree as you go. Do NOT push. Do NOT open a PR.

Two runs on this umbrella have already lost everything — one to a timeout, one to
a wedge that produced 38 minutes of silence and zero commits.

## Logging

Append to `agent.log` in the worktree root with real `date -u +%FT%TZ` timestamps,
**including a heartbeat every ~10 minutes**. Silence is indistinguishable from a
stall and will get the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Clause order post-#1962:
`SELECT -> FROM -> JOIN -> WHERE -> WINDOW -> GROUP BY -> HAVING -> ORDER BY -> LIMIT`.
References: `docs/architecture/name-binding.md`, `docs/claude/SQL_GRAMMAR_RULES.md`,
`docs/sql/PARSER_GRAMMAR.md`, `src/velostream/sql/CLAUDE.md`.
Reference idiom: `demo/trading/sql/ctas_file_trading.sql`.
**DO NOT GUESS SQL SYNTAX** — grep the parser and grammar docs for anything
unfamiliar; absent means unsupported.

## Deliverable

Post the analysis as a comment on #1994 (`gh issue comment 1994 -F <file>` — the
one case where you must `cd` into the worktree, since `gh` has no `-C`). Commit
the analysis file. Do NOT push. Do NOT open a PR. There is no code change.

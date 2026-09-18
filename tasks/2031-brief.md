# #2031 — collapse the two `strip_column_ref_indices` walkers into one

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2031
BRANCH:   fix/2031-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## The duplication

Two functions, same name, same stated purpose
(`ColumnRef { name, .. } -> Column(name)`, recursive), already divergent:

| | signature | catch-all | descends `WindowFunction`/`OverClause` |
|---|---|---|---|
| `window_v2/strategies/general_row_eval.rs:172` | `&Expr -> Expr` | **yes, `_ =>`** | **no** |
| `plan/physical_dispatch_resolver/plan_queries.rs:143` (#1994) | `Expr -> Expr` | no, exhaustive | yes |

## Why the older one is the riskier shape

Its `_ =>` catch-all means **any `Expr` variant added later is silently passed
through unstripped** — no compile error, no test failure, just a `ColumnRef`
surviving into a context that resolves by name, reading the wrong Arrow column
against #1152's alphabetically-sorted inferred schema.

That is exactly the two-hand-maintained-traversal drift that this codebase's own
`rewrite_over_clause_with` / `expr_any` / `over_clause_exprs` helpers exist to
prevent — their doc comments say so.

## The fix — PINNED

**One** `strip_column_ref_indices`, homed in `sql/ast.rs` alongside `expr_any`
and `rewrite_over_clause_with`, taking the **exhaustive** shape from
`plan_queries.rs`, with its three helpers (`_in_over_clause`, `_in_window_spec`,
`_in_order_by`). Both former call sites use it. Neither file keeps a private
copy, a wrapper, or an alias that would let them drift again.

**Keep the owned `Expr -> Expr` signature.** `general_row_eval_batch_array`
passes `expr.clone()`. That is not a hot-path regression, and here is the
measurement that says so — put it in the commit message:

- the strip is called **once per batch**, before `iter_rows()`, not per row;
- the existing `&Expr` version already **deep-clones every node** it visits.

So `strip(expr.clone())` is the same order of cost as what is there today.

**Exhaustiveness is the fix.** Do not add a `_ =>` arm to the unified function
"for safety" — a compile error on a new `Expr` variant is the entire point.

## The real work: the behaviour delta

This is filed as a Chore but it is **not a pure move**. The unified walker
descends `WindowFunction` / `OverClause` / `Subquery` where `general_row_eval`'s
did not. That changes what the window **per-row fallback** traverses, which is
why #2029 cross-referenced the two instead of unifying them — a hot-path
behaviour change in a different subsystem, inside a PR about HAVING binding.

**Evaluating that delta is the job.** State it explicitly in your report: the
window fallback now descends those nodes, and whether that is reachable in
practice.

Pin it with a test that **fails against master**. If no GeneralRowEval-reachable
expression can actually contain a `WindowFunction`, that is a valuable
**negative result** — report it with the evidence and say so. Do not invent a
test to have one.

**Commit your production change BEFORE any revert-check.**
`git checkout HEAD -- <path>` on an uncommitted edit destroys it, and on a fresh
branch `HEAD` *is* master. That silently wiped a fix twice in a prior session and
produced a probe that looked like evidence and was not.

## Do not delete the prose

Both functions carry long doc blocks. They are the most valuable part of this
diff — they record why the function exists and why two separate reviewers
deliberately left it alone:

- the **#1724 classification** ("silent SLOW PATH, not silent WRONG ANSWER", and
  why guarding it with validate-then-trust-the-index would be a regression);
- the **pr-gate F2 BLOCKER** rationale for why `Between`/`List` genuinely reach
  a `GeneralRowEval` expr, with its worked `SUM(JSON_FIND_BY_KEY(...) + CASE
  WHEN qty BETWEEN 1 AND 10 ...)` example.

**Merge both onto the unified function.** Drop neither. Do remove the two now
stale *"DUPLICATE — see ..."* paragraphs, since the duplication they warn about
will be gone.

## Out of scope — report, do not fix

`general_row_eval_batch_array` ends each row with `.unwrap_or(FieldValue::Null)`,
swallowing a real evaluation error. That is a genuine defect and against policy,
but it is not this issue. **Report it.**

Also do not touch `ExpressionEvaluator`, `resolve_column_ref`, or anything else
`general_row_eval` calls.

## STOP conditions

**STOP and report** — do not work around any of these:

1. The extra descent changes the output of any existing window test — report the
   test and the diff. That is the behaviour change this issue was carved out to
   evaluate, and accepting it is the maintainer's call.
2. `ast.rs` turns out not to be an appropriate home (circular module dependency,
   or `Expr` is not visible there) — report where you would put it instead; do
   not silently pick a different module.
3. The `plan_queries.rs` version turns out **not** to be exhaustive at current
   master — the whole premise is that it compiles as a total match.
4. More than ~10 pre-existing tests fail — report the list before changing any.
5. You would need to delete or `#[ignore]` a test.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-2031/Cargo.toml \
  > /tmp/2031.log 2>&1
grep -E "^ *Summary" /tmp/2031.log
grep -E "^ *FAIL " /tmp/2031.log | awk '{print $NF}' | sort -u
```

**That is NOT the gate** — it pulls broker-dependent Kafka integration tests that
fail with `AllBrokersDown` on a machine without a broker, which killed a dispatch
in a prior session. The gate is:

```
(cd /Users/neilavery/RustroverProjects/velostream-2031 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards run `git -C ... status` and commit
any reformatting.

## Structural edits — ast-grep, not Edit

Moving a function used at 45 sites across 3 files is a structural refactor. Use
`ast-grep` per `docs/ast-refactoring-instruction.md`, dry-run first
(`--pattern ... --json | jq length` must be > 0 before `--rewrite -U`), and log
an `AST-GREP-DECISION` line in `agent.log` for each. `Edit` is acceptable only
for the single-file doc-block merge.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1749] #2031:`. Do NOT push. Do NOT
open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. If a test needs SQL,
grep the parser and grammar docs — `docs/claude/SQL_GRAMMAR_RULES.md`,
`docs/sql/PARSER_GRAMMAR.md`, `src/velostream/sql/CLAUDE.md`. Absent means
unsupported. **DO NOT GUESS SQL SYNTAX.**

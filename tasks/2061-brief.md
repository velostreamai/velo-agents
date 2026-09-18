# #2061 Stage 1 spike — design the lifting FR-106 Phase 4 never landed

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2061
BRANCH:   fix/2061-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

**Stage 1 is DESIGN + SIZING.** The deliverable is
`.agents/tasks/2061-analysis.md`. No production code changes. Read #2061 AND its parent #2058, including comments. **#2058 stays open as the
implementation issue; this spike delivers a design document only.**

**Commit authorization:** you ARE authorized to commit incrementally on this
branch. Root `CLAUDE.md`'s "do not commit until the user has reviewed" governs
the orchestrator; this brief is the authorization for a dispatched worker on its
own branch. **Do NOT push. Do NOT open a PR** — the user reviews before either.

**#2060 has merged.** `sql/CLAUDE.md` now states that subqueries are NOT
plan-native and explains why — it no longer contradicts your task.

## What is actually true

**Subqueries work.** 302 subquery tests pass at `2fe36b329`;
`SubqueryAwareRowEvaluator` evaluates them per-row at runtime. **This task is not
fixing broken execution** — do not approach it as a bug hunt.

What is missing is plan-level *visibility*. `PlanNode::Subquery` exists in the
plan IR, and **nothing constructs it**:

- `PlanBuilder` never lifts a WHERE/SELECT-embedded `Expr::Subquery` into one;
- `StreamSource::Subquery` (`builder.rs:800`) builds the inner plan **solely to
  derive its schema**;
- all 90 `PlanNode::Subquery` occurrences across 34 `src/` files are match arms —
  `schema_propagation.rs:225` is representative: it destructures an existing node
  and rebuilds it;
- the only constructions are in `tests/` (30 sites).

Consequence: **`ColumnResolution` cannot see inside a subquery**, so a bad column
reference in a subquery interior is not caught at plan time. That is the last
structural hole in #1749's name-binding layer.

## The history, because it is the point

`docs/feature/FR-106-plan-path-completeness.md:172-189` marks Phase 4 **✅**:

> The audit (#275 Part A) recommended **keeping subqueries as `Expr::Subquery`**
> to avoid the 28-file cascade (above the issue's **25-file STOP trigger**).
> **The reviewer overrode that recommendation** … The 28-file mechanical cascade
> was accepted in favour of the correct IR.

The variant and the 28-file consumer cascade landed. The producer did not. Phase
4 was marked complete on the strength of the cascade.

**Read `logical.rs:1182-1209` first.** The variant's own doc specifies the
contract every consumer must honour — `ColumnResolution` recurses and resolves
`correlation_columns` against the outer schema; `PredicatePushdown` /
`ProjectionPushdown` treat it as an opaque barrier; `ConstantFolding` / `CSE` /
`AggregateDispatch` recurse but do not fold across it; idempotence; schema by
kind. That doc is your design input, not something to re-derive.

## The question Stage 1 must answer: PLACEMENT

`Expr::Subquery { query: Box<StreamingQuery>, subquery_type }` sits **inside an
expression** — a `Filter` predicate, a `Project` expr. **A `PlanNode` is not
reachable from inside an `Expr`.** So decide how the two connect. Candidates, not
exhaustive:

- the enclosing node carries subquery plans as additional inputs, and the
  expression references one by id/index;
- `Expr::Subquery` carries an `Arc<LogicalPlan>` directly.

**Say which, and why you rejected the others.**

**The constraint most likely to kill a placement:** `SubqueryAwareRowEvaluator`
must still find and evaluate the subquery at runtime. State exactly how it
obtains the inner query after lifting. **Test your design against this first** —
if no placement preserves it, STOP and report, because that is a genuine
architectural blocker and the most valuable finding available.

## Also to establish

- **`StreamSource::Subquery`** (`builder.rs:800`) — IN or OUT of scope, with
  reasoning. `SubqueryKind` is expression-level only (Scalar / Exists / NotExists
  / In / NotIn / AnyAll); there is **no derived-table variant**. "In scope"
  implies extending the enum — say so if that is your recommendation. Do not
  assume it belongs because it contains the word Subquery.
- **The consumer gap.** Which of the 90 arms already satisfy
  `logical.rs:1182-1209` and which do not. One known instance:
  `column_resolution.rs:757` recurses with `ctx.reset()` and leaves
  `correlation_columns` **untouched**, though the contract requires resolving
  them against the outer plan. Assume there are others; find them.
- **Cascade size for Stage 2.** How many files. If it exceeds ~25, **STOP and
  report the count before recommending** — #275's audit recommended against this
  work on exactly that basis and was overridden. The same call should be made in
  the open, not by default.

## Stage 2 test design

Must include at least one test proving the binder **rejects an unresolvable
column inside a subquery interior**. That capability does not exist today.
Without it the wiring is unobservable and could regress silently — which is how
the producer went missing in the first place.

The 302 passing subquery tests are the floor and must stay green.

## STOP conditions

**A STOP report is a SUCCESSFUL outcome, not a failure to deliver.** If one of
these fires, report it with its evidence and stop — the acceptance criteria for
the full design apply only if none fired. Do not fabricate a placement decision
or a recommendation to satisfy a checklist; that is worse than the stop.

**STOP and report** on any of these:

1. No placement preserves the runtime `SubqueryAwareRowEvaluator` path.
2. The Stage 2 cascade exceeds ~25 files — report the count before recommending.
3. Lifting would require changing `Expr`'s definition in a way that cascades into
   the parser or the AST-level evaluators — report the surface first.
4. You cannot reach a single recommendation — report why, with evidence for each
   option.

**A recommendation AGAINST proceeding is also a success.** #275's audit reached
exactly that conclusion, was overridden, and the result is the half-finished
state this task exists to resolve. If the cost genuinely exceeds the benefit, say
so — that is the outcome this spec most wants to be told honestly.

## Verify your own evidence

- **`grep -c` on nextest output double-counts** — each failure prints twice.
  Count distinct: `grep -E "^ *FAIL " log | awk '{print $NF}' | sort -u`
- **A scripted edit matching nothing exits 0.** `assert old in s` before every
  replace; grep for the new text after.
- **Distinguish a match arm from a construction.** That distinction is the whole
  finding here, and grep alone will not make it — read the surrounding code.

## Two checks you must run yourself

The spec JSON is preflight metadata — **you never see it**. Anything you must do
is here.

**1. Capture the symbol count before you start, and confirm it at exit.** This
task deletes nothing:

```
git -C /Users/neilavery/RustroverProjects/velostream-2061 grep -F -o 'PlanNode::Subquery' -- src tests examples | wc -l
```

122 at `e4c3511c4`. Capture your own number rather than trusting that one — an
earlier revision of this spec hard-coded 120 and was invalidated by a
documentation commit that mentioned the symbol twice.

**2. Establish the test floor before you start, and report the numbers:**

```
cargo nextest run --no-default-features --test mod -E 'test(/subquery_differential/)'      --manifest-path <worktree>/Cargo.toml
cargo nextest run --no-default-features --test mod -E 'test(/correlated_subquery_scope/)'  --manifest-path <worktree>/Cargo.toml
cargo nextest run --no-default-features --test mod -E 'test(/column_resolution/)'          --manifest-path <worktree>/Cargo.toml
```

Roughly 11 / 48 / 29-34 respectively. These are filter EXPRESSIONS, not test
names — an exact `test(=column_resolution)` matches zero.

## Validation

Stage 1 changes no production code, so the check is that the tree is unchanged
apart from the analysis file:

```
git -C /Users/neilavery/RustroverProjects/velostream-2061 status --short
git -C /Users/neilavery/RustroverProjects/velostream-2061 diff --stat origin/master..HEAD
```

To confirm the floor before you start, and again if you experiment:

```
cargo nextest run --no-default-features --test mod \
  -E 'test(/subquery/) and not test(/kafka/)' \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-2061/Cargo.toml
```

**Exclude the Kafka integration coverage.** A bare `test(/subquery/)` filter
selects `scalar_subquery_kafka_table_test::test_bug47_late_materialization_visible_through_shared_arc`,
which fails without Docker — environment, not regression. I reported "302
passing" from a machine that had Docker; a spec review on a machine without it
got 283 passed, 1 failed, 18 cancelled. Establish your own floor before you
start, and say what it was. Also available for type-checking any sketch:
`cargo check --no-default-features --manifest-path <worktree>/Cargo.toml`.

## Do not push, do not open a PR

Stated as an instruction because it is **not** auditable: a worker can push any
ref, and no check I can write proves a PR was never opened. The orchestrator
snapshots `git ls-remote origin` before and after, which detects a new or moved
ref but not a PR opened from elsewhere. Detection, not prevention — you are
being trusted, and the honest framing is better than a postcondition that
pretends otherwise.

## Incremental commits — MANDATORY

Commit after each section — commit incrementally, prefixed `[#2058]`. A timeout
with everything uncommitted loses the run. Do NOT push. Do NOT open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Grep the parser and
grammar docs — `docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`,
`src/velostream/sql/CLAUDE.md`. Absent means unsupported. **DO NOT GUESS SQL
SYNTAX.**

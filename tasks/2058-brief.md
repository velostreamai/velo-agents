# #2058 — FINISH the subquery lifting. Work already exists on the branch.

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2058
BRANCH:   fix/2058-auto

**The work already exists on `origin/fix/2058-auto` (two commits, tip
`9d068d16b`).** Your worktree may have been cut fresh from master, so FIRST:

    git -C /Users/neilavery/RustroverProjects/velostream-2058 fetch origin
    git -C /Users/neilavery/RustroverProjects/velostream-2058 reset --hard origin/fix/2058-auto
    git -C /Users/neilavery/RustroverProjects/velostream-2058 log --oneline -2

Confirm you see `9d068d16b` and `e95fb96a3` before doing anything else. If you
do not, STOP — you are about to redo work that is already done. Do not create
another branch.

Do NOT `cd` into the worktree except for `gh`. Use `git -C`,
`cargo --manifest-path`, absolute paths.

## Read first

    git -C /Users/neilavery/RustroverProjects/velostream-2058 log -2
    git -C /Users/neilavery/RustroverProjects/velostream show fix/2061-fable:.agents/tasks/2061-analysis.md

The design is pinned by the #2061 spike **and its lifecycle addendum**
(`820ac26d3` + `a46319aaa`). Where addendum and §3 disagree, the addendum wins.
`9d068d16b`'s commit message is an honest status — read it.

## Already done (do not redo)

- `logical.rs` — `SubqueryPlanEntry { host: Option<PlanNodeId>, ordinal, plan }`
  and `LogicalPlan::subquery_plans`. Field cascade was two sites: `new()` and the
  manual `Clone`.
- `builder.rs` — the PRODUCER in `from_ast_with_schemas`: walks its own nodes'
  exprs via `expr_any`, builds and propagates each inner plan, pushes an entry
  keyed by the host wrapper's `node_id`. Does not descend into embedded wrappers.
  ANY/ALL deliberately unlifted (`SubqueryType` carries no comparison operator,
  `SubqueryKind::AnyAll` needs one).
- `mod.rs` — `bind_subquery_plans`, recursive over embedded wrappers, clearing
  `host` to `None` afterwards so "dead after bind" is mechanical.
- `column_resolution.rs` — `for_each_unresolved_column` traverses the side table.

**Two design corrections are already baked in — do not undo them:**

1. The outer scope is the **host node's INPUT schema**, not the plan's output
   schema. Output for `SELECT o.id FROM orders o WHERE EXISTS (…)` is just `id`,
   which rejected the valid `o.customer_id`.
2. Resolution is **one merged scope** — interior against inner ⊕ outer, the shape
   a JOIN's `ON` uses. An earlier attempt bound the interior alone then
   partitioned "unresolved" names afterwards; that produced 9-11 false
   rejections. The merged scope took the floor from 11 failures to 2.

## Your job — two failures and one unstarted piece

### 1. `subquery_exists_correlated_zero_unresolved` regressed (diagnosed, unfixed)

    SELECT a FROM t WHERE EXISTS (SELECT 1 FROM other WHERE id = a)
    → subquery_exists_correlated: unresolved columns: ["a"]

Schema-less. `bind_subquery_plans` skips binding an inner plan whose schema is
empty — correct, #1966 D2 makes that legal — but
`for_each_unresolved_column` still traverses the entry, so `a` surfaces as
unresolved. **An entry whose interior was never bound must not be reported
against.** This is the same class as the bug the merged scope fixed, one layer
down: a check applied where binding did not run.

### 2. `binder_rejects_unresolvable_column_inside_subquery_interior` does not fire

The headline capability. The interior is now visible to the collector, but the
rejection does not happen. Start at `apply_strict_gate`'s schema-rich/catalog
conditions (`plan/mod.rs`, around the `collect_strict_gate_unresolved_column_names`
call): the gate only rejects when the offending scan leaf is schema-rich AND
registered. Establish whether a lifted interior's scan leaf satisfies that, and
fix so a genuinely-unknown column rejects **without** re-introducing (1).

The two interact — that is the actual difficulty. Do not fix one by breaking the
other; the accept-twin tests exist to catch exactly that.

### 3. EXPLAIN rendering — not started

Render entries under an explicit **"as written (bind-time)"** heading; they
describe the query as written, not what runs after decorrelation. Use the
**annotated** path: `format_annotated`'s invariant is that its traversal and
`StreamExecutionEngine::collect_annotations` visit the same nodes in the same
order (`explain.rs:108-133`). Update both, or you get a debug assertion or
silently shifted annotations. Exercise real EXPLAIN output, not
`PlanFormatter::format`.

## The floor — this is the gate on your work

    cargo nextest run --no-default-features --test mod \
      -E 'test(/subquery/) and not test(/kafka/)' \
      --manifest-path /Users/neilavery/RustroverProjects/velostream-2058/Cargo.toml

**300 green at origin/master. Currently 266 pass / 2 fail. Both must go.**
A bare `test(/subquery/)` filter pulls Docker-gated Kafka coverage — not a floor.

Also keep green:

    -E 'test(/subquery_interior_binding/)'      # 3 tests: 1 reject + 2 accept twins
    -E 'test(/planner_resolution_invariant/)'
    -E 'test(/column_resolution/)'

The two **accept** tests in `subquery_interior_binding_test` are the regression
guard against false rejection. They passed before any of this work and must keep
passing — they caught three of my own design errors.

## STOP conditions

**STOP and report** — a clean stop beats a forced fix:

1. Fixing (2) cannot be done without re-breaking (1) or the accept twins.
2. Anything needs to read `entry.host` after `bind_plan` returns — it is `None`
   by then, by construction.
3. Any subquery test green at `origin/master` is still failing when you finish.
4. The annotated-EXPLAIN traversal and `collect_annotations` cannot be kept in
   lockstep.
5. You would need to delete or `#[ignore]` a test.

## Verify your own evidence

- `grep -c` on nextest output DOUBLE-COUNTS — each failure prints twice. Count
  distinct: `grep -E "^ *FAIL " log | awk '{print $NF}' | sort -u`
- A scripted edit matching nothing exits 0. `assert old in s` before every
  replace; grep for the new text after.
- `zg query "..."` is indexed in this worktree and gives enclosing symbol +
  line range — far better than grep for telling a construction from a match arm.

## Validation

    cargo check --no-default-features --manifest-path <worktree>/Cargo.toml

The gate is:

    (cd /Users/neilavery/RustroverProjects/velostream-2058 && ./run-commit.sh --fast)

It wet-applies `cargo fmt --all` — afterwards `git -C ... status` and commit any
reformatting.

## Incremental commits — MANDATORY

Commit after each logical step — commit incrementally, prefixed `[#2058]`. A
timeout with everything uncommitted loses the run. Do NOT push. Do NOT open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Grep the parser and
grammar docs — `docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`,
`src/velostream/sql/CLAUDE.md`. Absent means unsupported. **DO NOT GUESS SQL
SYNTAX.**

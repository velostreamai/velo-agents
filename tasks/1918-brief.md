# #1918 — one output name for an unaliased computed expression, plan AND record

Parent: #1970 (SQL surface defects from the #1749 name-binding audit)
Absorbs: #2108 (three competing output-name generators)
Unblocks: #1919 (NB-005 duplicate-output-name validation), then #2045.

## 0. Read this first — why this brief was rewritten

An earlier version of this brief scoped the work to the PLAN only. That version
was implemented (PR #2104) and gated, and the gate found the scope was wrong.

Renaming only the plan side leaves the plan and the emitted record disagreeing:
the schema says `EXPR$0` while the record carries `Multiply_price_quantity`.
That is worse than the defect it fixes. `__expr__` was at least obviously a
placeholder; `EXPR$0` looks like a real, referenceable column name while nothing
downstream can actually use it. So plan and execution are now ONE task.

PR #2104 is superseded by the PR you will open, but its commits are reviewed and
correct for bars 1–6 — treat them as a reference implementation, not as work to
redo blindly:

    git -C <worktree> log --oneline origin/master..origin/fix/1918-expr-output-names
    c157ded33  plan-side EXPR$<n> + shared helper
    e15d7bac8  route SelectField::Column through the shared helper

## 1. Target and isolation

Worktree and branch are created for you by `velo-dispatch` off current
`origin/master`. The worktree is clean and carries no prior commits.

**Do NOT `cd` into the worktree except for `gh` commands (gh has no `-C`).**
Use `git -C <worktree>`, `cargo --manifest-path <worktree>/Cargo.toml`, and
absolute paths with Read/Edit/Write.

## 2. Fresh line numbers

Cut with `grep -n` at dispatch time against `7edba1761`, verified. The symbol is
authoritative, the number is not.

    src/velostream/sql/plan/builder.rs:1617               _ => FieldName::from("__expr__"),
    src/velostream/sql/plan/builder.rs:1601               fn select_fields_to_project_exprs
    src/velostream/sql/plan/builder.rs:1661               fn build_plan_alias_keys
    src/velostream/sql/plan/schema_propagation.rs:685     .unwrap_or_else(|| FieldName::from("__expr__"));
    src/velostream/sql/plan/schema_propagation.rs:478     _ => FieldName::from("__group__"),
    src/velostream/sql/plan/schema_propagation.rs:474     fn expr_output_name
    src/velostream/sql/plan/schema_propagation.rs:461     fn select_alias_for_group_expr
    src/velostream/sql/plan/schema_propagation.rs:657     pub fn schema_from_select_fields
    src/velostream/sql/execution/aggregation/accumulator.rs:1065   pub fn generate_field_name
    src/velostream/sql/execution/aggregation/accumulator.rs:1079   fn expr_to_string
    src/velostream/sql/execution/processors/select.rs:2271         pub fn get_expression_name

## 3. Pinned design — you do not choose

### 3a. The naming scheme: positional `EXPR$<n>`

An unaliased SELECT item whose expression is NOT a column reference is named
`EXPR$<n>`, where `n` is its **zero-based position in the SELECT list**.
`SELECT price * quantity, price - fee FROM trades` produces `EXPR$0`, `EXPR$1`.

An unaliased item that IS a column reference keeps its bare column name, with
any qualifier stripped: `SELECT t.amount` outputs `amount`.

**`EXPR$<n>` is the name everywhere — plan schema and emitted record alike.**
This is the pinned decision; do not propose the descriptive
`Multiply_price_quantity` form instead.

### 3b. Sweep the class: `__group__` too

A GROUP BY key that is not a column reference is named by the same generator,
positionally within the GROUP BY list.

**Except** when the same expression also appears in the SELECT list. Then it
carries its **SELECT-list** position, because the output column IS the SELECT
item. `output_schema`'s `Aggregate` arm already prefers
`select_alias_for_group_expr` (`schema_propagation.rs:461`) over
`expr_output_name`, so this is the existing preference, now made coherent. The
GROUP BY index applies only to keys absent from SELECT.

### 3c. ONE helper, every variant, both sites

`builder.rs::select_fields_to_project_exprs` and
`schema_propagation.rs::schema_from_select_fields` must call one shared naming
helper for **every** `SelectField` variant — `Expression`, `Column`,
`AliasedColumn`, `Wildcard`. Neither may keep a private copy of any arm.

`SelectField::Column` is the trap. The parser emits column SQL as
`SelectField::Expression`, so no parsed query reaches the `Column` variant —
which is exactly how it drifted: `builder.rs` stripped the qualifier while
`schema_from_select_fields` kept the raw name, so a programmatically built
`SelectField::Column("t.amount")` produced `amount` in the Project and
`t.amount` in the schema. `schema_from_select_fields` is `pub` and programmatic
ASTs are supported (#1839), so that divergence is live.

### 3d. The execution side — this is the hard half

Three generators currently name the same expression three different ways:

| generator | location | consumed by | produces |
|---|---|---|---|
| the shared helper (§3c) | `plan/schema_propagation.rs` | Project exprs, propagated schema | `EXPR$0` |
| `AccumulatorManager::generate_field_name` | `accumulator.rs:1065` | `Aggregate::alias_keys`, runtime agg lookup | `"expr"` |
| `SelectProcessor::get_expression_name` | `select.rs:2271` | interval_join, group_by, group_by_columnar, rows_window | `Multiply_price_quantity` |

`generate_field_name` degrades every non-column, non-literal, non-function
expression to the literal string `"expr"` via `expr_to_string`'s catch-all
(`accumulator.rs:1079`) — so two computed SELECT items both become `"expr"`,
which is the very duplicate-name defect this issue exists to remove, still live
at execution.

**Your job: exactly one code path decides what an output column is called.**
Either the other two delegate to the shared helper, or they are demoted to a
documented runtime **lookup key** that is never an output name and never reaches
a `Schema`. Pick one and state which in the PR body.

### 3e. The coupling that will bite you — read before touching `alias_keys`

`PlanNode::Aggregate::alias_keys` is **not only an output name**. It is the key
the runtime aggregate evaluator looks up. `walk_expr_for_aggs` in `builder.rs`
says so explicitly: the alias "matches the key the runtime evaluator uses for
lookup, so write and read sides agree."

Routing `build_plan_alias_keys` (`builder.rs:1661`) through the positional helper
**on its own** was attempted and **failed 48 unit tests**:

    window_v2::differential_test                              15
    server::v2::partition_receiver_schema_inference_test       17
    window_v2::differential_live_pass_test                     4
    window_v2::session_fold_survivor_test                      3
    server::v2::source_only_typed_declaration_e2e_test          3
    window_v2::session_h1_multi_close_test                      2
    window_v2::tier1_chunked_activation_test                    2
    window_v2::correctness_regression_test                      1
    sql::execution::window_system_columns_test                  1

Full list in #2108. That is the blast radius of the coupling, and it is why this
work is one task rather than two.

Renaming the plan side while execution still looks up the old key is **silent
wrong output**, not a test failure, in any path those 48 tests do not cover. So:
preserve the contract, or migrate both ends atomically. State which you did.

`walk_expr_for_aggs`'s own internal lookup key must not change incidentally. If
the unification changes it, that is a deliberate, stated decision.

### 3f. What this change does NOT do: collision handling

No suffix bumping, no renaming on collision, no duplicate detection. A generated
`EXPR$0` that collides with a user column literally named `EXPR$0` passes through
unchanged. #1919 owns that check — leave a comment at the generator saying so.

## 4. Blast radius and size budget

Measured at `7edba1761` across `src/`, `tests/`, `examples/`:

    get_expression_name     -> 29 refs, 12 files    (declared blast radius)
    generate_field_name     -> 39 refs, 11 files
    build_plan_alias_keys   ->  9 refs,  7 files
    __expr__                ->  2 refs,  2 files    (both src/, listed in §2)
    __group__               ->  1 ref,   1 file

`FieldName::from("__` also matches `__exists__`, `__raw__`, `__agg__` and
`__velostream_variant`. Those are legitimate internal sentinels, **not**
output-name placeholders. Leave all of them alone.

This is a larger change than the superseded plan-only version. There is no
5-file tripwire. **But**: if you find yourself editing a file that neither names
an expression nor reads one of the three generators, STOP and report — that is
the signal you are unifying more than naming.

## 5. STOP conditions

STOP and report, without pushing, if:

- the shared helper cannot be reached from execution without changing a public
  signature whose callers live outside `plan/` and `execution/`
- preserving the `alias_keys` write/read contract and shipping `EXPR$<n>` at
  execution turn out to be mutually exclusive
- any of the 48 tests in §3e requires a **changed expectation** rather than
  passing unmodified — report it with the argument for why the old behaviour was
  wrong, per the correctness-over-parity rule, and do not change it unilaterally
- the `__group__` fix cannot be made without touching a `#1469`-class alias defect

## 6. SQL syntax

Do not invent syntax. `docs/sql/PARSER_GRAMMAR.md`,
`docs/claude/SQL_GRAMMAR_RULES.md` and `src/velostream/sql/CLAUDE.md` are
authoritative. `EXPR$<n>` is a generated OUTPUT NAME, not new syntax — no
grammar production changes.

## 7. Validation commands

Inner loop:

    cargo check --no-default-features --manifest-path <worktree>/Cargo.toml

Scoped:

    cargo nextest run --no-default-features --profile unit --manifest-path <worktree>/Cargo.toml -E 'test(expr_output)'

Multi-file sweep:

    cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod --manifest-path <worktree>/Cargo.toml

**`--profile unit` is mandatory, not optional (#2103).** Without it,
`--lib --test mod` enqueues 12,470 tests including `performance::` and
`integration::` — Kafka testcontainers and 45–57s benches. Under that
parallelism they fail on contention, and you are left holding red tests in
subsystems your diff never touched. That produced a false STOP on the previous
run of this very issue, which reported "21 unrelated failures" when only 5 were
real and all 5 passed when re-run isolated. With the profile it is 11,768.

The 48 tests in §3e are inside that unit set, so the sweep IS your gate for them.

Gate, once, from the worktree root:

    (cd <worktree> && ./run-commit.sh --fast)

`run-commit.sh` runs `cargo fmt --all` as a **wet apply** — it rewrites files in
place. After it completes, run `git -C <worktree> status`; if fmt changed
anything you **must** commit it. The gate formats but cannot commit, and an
uncommitted reformat fails CI's independent `cargo fmt --check`.

Do **not** re-run the gate to get different output. It prints `📝 Full log: <path>`
at start and end — read that log and grep it.

New test files **must** be registered in the parent `mod.rs`, or they do not run.

## 7a. The test that matters most

Bar 2 requires the emitted record's field name to equal the plan schema's field
name, **asserted through a real engine consumer** — not by comparing two
plan-side helpers to each other. Two plan-side helpers agreeing is what the
superseded PR already proved, and it is exactly what missed this defect.

`emitted_record_field_name_matches_plan_schema_for_computed_select_item` is named
in `fail_to_pass` for that reason. Cover the windowed, grouped, and interval-join
shapes too.

## 7b. Required documentation

`docs/sql/PARSER_GRAMMAR.md` must document the generated-name rule alongside the
`select_item` production, and must describe the **shipped** behaviour — including
that the name holds at execution, not only in the plan.

Do not confuse this with §8's corpus rule. Editing a SQL **example** so a gate
stops complaining is forbidden; writing prose that **documents** the new
behaviour is the job. If you find yourself changing a ```sql fence, stop and
re-read this paragraph.

## 7c. Commit incrementally

Commit after each logical step, not once at the end. A timeout or crash must
never lose completed work. Small commits are expected and will be squashed at
merge. If you are about to start a long step — a full gate run, a multi-file
edit — commit what you already have FIRST.

Three prior runs on this issue lost work this way: two died on a prompt timeout
with everything uncommitted, and one finished correctly but stopped before
committing on a sweep failure that turned out to be the §7 profile problem.

This does not loosen §8: commit freely on your own branch, but do not push, open
a PR, or merge.

## 8. Forbidden

- do not add a suffix-bumping or any other collision workaround
- do not implement NB-005 duplicate-output-name detection — that is #1919
- do not touch `__exists__`, `__raw__`, or `__velostream_variant` — legitimate
  sentinels, not output-name placeholders
- do not treat `__agg__` as an output-name placeholder — it surfaced alongside
  `"expr"` in aggregate schemas during investigation and is out of scope
- do not edit a SQL EXAMPLE under `docs/` or `demo/` to make a gate pass.
  Updating `PARSER_GRAMMAR.md` prose to DOCUMENT the new rule is required, not
  forbidden; the two are different acts
- do not add `#[cfg(test)]` or `#[test]` inside `src/`
- do not delete, skip, `#[ignore]` or narrow any existing test. The 48 tests in
  §3e are the gate for this work, not an obstacle to it — a naming change that
  requires silencing them has not been made correctly
- do not change `EXPR$<n>` itself — the form is pinned and documented
- do not route `build_plan_alias_keys` through the positional helper WITHOUT
  migrating the runtime readers in the same change (§3e)
- do not resolve #1469-class alias defects while sweeping `__group__`
- do not change a public signature with callers outside `plan/` and `execution/`
  — STOP and report instead

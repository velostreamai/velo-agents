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

PR #2104 is superseded by the PR that will be opened from your branch **by the
caller, not by you** — §8 forbids you opening one. Its commits are reviewed and
correct for bars 1–6; treat them as a reference implementation, not as work to
redo blindly:

    git -C <worktree> log --oneline origin/master..origin/fix/1918-expr-output-names
    c157ded33  plan-side EXPR$<n> + shared helper
    e15d7bac8  route SelectField::Column through the shared helper

## 1. Target and isolation — THIS IS A RESUME

Worktree: `/Users/neilavery/RustroverProjects/velostream-1918`
Branch: `fix/1918-unify-output-names`

**The worktree already exists and carries prior work of your own.** It was
dispatched with `--resume`, so nothing was reset.

**Derive the current state; do not trust any commit list in this brief.** Earlier
versions enumerated the commits and went stale the moment you committed again,
which had a reviewer flagging obsolete "remaining work" on every round. So, first
three commands of the run:

    git -C <worktree> log --oneline origin/master..HEAD
    git -C <worktree> status --porcelain
    grep -E 'RED-FIRST|READER-MIGRATED|ALIAS-KEYS|CHANGED-EXPECTATION|STOP' <worktree>/agent.log

Everything is pushed to origin, so nothing can be lost. Those three outputs are
the authority on what is done: the commits, the working tree, and your own log.
Read them before planning, and do not redo what a `READER-MIGRATED` or `RED-FIRST`
line already records.

**Do NOT `cd` into the worktree.** Use `git -C <worktree>`, `cargo
--manifest-path <worktree>/Cargo.toml`, and absolute paths with Read/Edit/Write.

Two exceptions:

- `gh` commands — `gh` has no `-C`.
- `zg query` — it resolves `.zvec-grep` from the cwd and has no `--workspace`
  flag, so running it from anywhere else silently answers from THAT tree's index.
  The master checkout has its own index, so a query run from the wrong place
  returns plausible results about the wrong code rather than an error (#2128).
  `cd` into the worktree for `zg`, or use `rg`/`ast-grep`, which need no index.

Everything else stays path-prefixed. A worker that cd's and then commits can end
up committing in the wrong tree — that happened during this issue's own spec work.

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

#### It applies to aggregates too — `SUM(value)` becomes `EXPR$0`

The first resume stopped here, correctly, because
`differential_sliding_computed_group_by_parity` reads a field named `SUM(value)`.
The answer is that the test's expectation changes, not that aggregates are carved
out.

Flink and ksqlDB — the streaming-SQL family this engine follows, and the prior art
the issue cites — apply `EXPR$0` / `KSQL_COL_0` to EVERY unaliased non-column
item, aggregates included. Positional uniqueness is the property the issue says
`__expr__` lacks, and it is not a property you can have selectively.

A mixed rule (conventional `NAME(args)` for functions, positional for everything
else) was considered and **REJECTED**: `SUM(price * qty)` renders `SUM(expr)`
today, because `expr_to_string`'s catch-all is reachable inside a function
argument. Two such items collide exactly as two `__expr__` items did. A carve-out
for functions would keep the bug in aggregate clothing.

#### The escape hatch is AS, and it must keep working

`SELECT SUM(value) AS total` emits `total`. That is what makes renaming unaliased
items safe, and it is the line between an expectation that legitimately changes
and a regression:

| a test pins… | then |
|---|---|
| a legacy generated name for an UNALIASED item — `SUM(...)`, `SUM(expr)`, `__expr__`, `__group__`, `price_Multiply_quantity` | its expectation MAY change; log one `CHANGED-EXPECTATION` line per test saying the old name was non-positional or colliding |
| an EXPLICIT `AS` alias | it must pass UNCHANGED — changing it is a regression |
| a non-naming property — row counts, values, ordering, watermarks | it must pass UNCHANGED — **STOP** if it fails |

`pass_to_stay` is now the three alias-focused tests, because those are the
property that must not move. The two computed-group-by parity tests moved out:
they pinned legacy generated names for unaliased items, which is precisely what
this issue replaces.

Expect a substantial number of `CHANGED-EXPECTATION` lines this time — that is
the correct outcome here, not a warning sign. What would be a warning sign is a
changed expectation on an aliased item.

### 3b. Sweep the class: `__group__` too

A GROUP BY key that is not a column reference is named by the same generator,
positionally within the GROUP BY list.

**Except** when the same expression also appears in the SELECT list. Then it
carries its **SELECT-list** position, because the output column IS the SELECT
item.

#### A computed key NOT in SELECT gets `GROUP$<n>`, not `EXPR$<n>`

Separate namespace, deliberately. Two independent positional counters in one
namespace collide:

    SELECT COUNT(*) FROM t GROUP BY price * quantity

The group slot would be `EXPR$0` (GROUP BY index 0) and `COUNT(*)` would be
`EXPR$0` (SELECT index 0) — and `output_schema` appends group fields **before**
aggregate fields, so the schema would carry two `EXPR$0` fields. That is the exact
duplicate-name defect this issue exists to remove, reintroduced, with collision
handling forbidden and no way out.

`GROUP$<n>` cannot collide with `EXPR$<n>` by construction, needs no dedup, and is
honest about what that slot is: it exists so `HAVING` can resolve against the key,
not as a user-visible output column.

`unselected_computed_group_key_does_not_collide_with_select_positional_name`
pins exactly this query.

**Single-quote these names in every shell context.** `EXPR$<n>` and `GROUP$<n>`
contain `$`, so an unquoted shell expands them — `GROUP$0` becomes `GROUPbash`,
because `$0` is the shell's own name. That already happened during this issue's
work and put a corrupted expectation into `agent.log`:

    failed-with=left: "__group__" right: "GROUPbash"

So: `-E 'test(...)'`, `grep -F 'EXPR$0'`, `"GROUP\$0"` in double quotes, or
single quotes throughout. A test asserting `EXPRbash` or `GROUPbash` is corruption,
not a finding. `output_schema`'s `Aggregate` arm already prefers
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
a `Schema`. Pick one and record it per §7b-bis.

#### The readers you MUST migrate — ALREADY DONE, do not redo

All four `READER-MIGRATED` lines are logged on your branch (`select.rs` and
`accumulator.rs` as `lookup-key`, `group_by.rs` and `group_by_columnar.rs` as
`delegate`). This table is kept for reference only. Re-read these files to follow
their pattern; do not migrate them again.

The first attempt at this section picked `mode=migrate`, moved the plan side plus
`interval_join.rs` and `rows_window.rs`, and stopped with 53 failing tests. The
four files below had a ZERO-line diff. They are where the remaining failures
live, and no sweep will go green until they move:

| file | what is still unmigrated |
|---|---|
| `execution/processors/select.rs` | `SelectProcessor::get_expression_name` — the `{op:?}_{left}_{right}` namer that produces `Multiply_price_quantity` |
| `execution/aggregation/accumulator.rs` | `AccumulatorManager::generate_field_name`, and `expr_to_string`'s `_ => "expr"` catch-all at **:1091** |
| `execution/processors/select/group_by.rs` | three `get_expression_name` call sites (~:992, :1114, :1201) |
| `execution/processors/group_by_columnar.rs` | one `get_expression_name` call site (~:2242) |

Check them off explicitly in `agent.log` as you go:

    <UTC> READER-MIGRATED | file=<path> | symbol=<fn> | mode=<delegate|lookup-key>

Four `READER-MIGRATED` lines are expected. Fewer than four with a green sweep
means you found a reason one did not need it — say which and why. The sweep going
green while a file here is untouched is the shape to distrust: it usually means a
test was weakened rather than a reader moved, which §8 forbids.

`interval_join.rs` and `rows_window.rs` are already migrated on your branch —
don't redo them, but do re-read them, because the pattern they use is the one to
follow.

### 3e. The coupling that will bite you — read before touching `alias_keys`

`PlanNode::Aggregate::alias_keys` is **not only an output name**. It is the key
the runtime aggregate evaluator looks up. `walk_expr_for_aggs` in `builder.rs`
says so explicitly: the alias "matches the key the runtime evaluator uses for
lookup, so write and read sides agree."

Routing `build_plan_alias_keys` (`builder.rs:1661`) through the positional helper
**on its own** was attempted and **failed 48 unit tests** (53 once the plan side was fully migrated):

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

This is a larger change than the superseded plan-only version, so there is no
5-file tripwire.

**The scope tripwire applies to `src/` only.** If you find yourself editing a
file under `src/` that neither names an expression nor reads one of the three
generators, STOP and report — that is the signal you are unifying more than
naming.

It explicitly does NOT apply to work this brief REQUIRES:

- anything under `tests/`, including new test files
- the parent `mod.rs` registrations those new files need (§7)
- `docs/sql/PARSER_GRAMMAR.md` (§7b)
- `agent.log`

Editing those is the job, not scope creep.

## 5. STOP conditions

STOP and report, without pushing, if:

- the shared helper cannot be reached from execution without changing a public
  signature whose callers live outside `plan/` and `execution/`
- preserving the `alias_keys` write/read contract and shipping `EXPR$<n>` at
  execution turn out to be mutually exclusive
- a coupled test requires a changed expectation that is **not** a legacy generated
  name on an unaliased item — i.e. it pins an explicit `AS` alias, or a non-naming
  property (row counts, values, ordering, watermarks)

**Updating a legacy generated name on an unaliased item is EXPECTED WORK, not a
stop.** There are ~54 such tests across ~11 modules — schema-inference,
interval-join, window/group-by differential. Log one `CHANGED-EXPECTATION` line
per test and keep going to a green sweep.

An earlier version of this brief listed that as a STOP condition while the
acceptance bars required it, and a run that was doing exactly the right thing
halted on `scope-expansion-and-unvalidated-partial-migration` after enumerating
54 of them. Stopping on these one at a time cannot converge. The volume is the
task, not a signal that the scope grew.
- **any of the eight `fail_to_pass` tests PASSES against unfixed code** — the
  guard `explicit_alias_survives_positional_naming` is NOT one of them and is
  exempt, so never report it here. You cannot
  record the required `RED-FIRST` line (§7a) for a test that was never red, and
  you must not "fix" it by loosening the test until it fails. One of two things
  is true and only a human should decide which: the test does not reach the code
  path it claims to (the exact defect §7a describes — the prior attempt's
  group-by test built `Aggregate` with empty `select_exprs`/`alias_keys` and so
  tested nothing), or the behaviour already holds and the spec's premise is
  wrong for that bar. Report which you believe, with the test and its output.
- the `__group__` fix cannot be made without changing the output name of a
  `SelectField::AliasedColumn`, or of a GROUP BY key that carries an explicit
  `AS` alias — those two names must come out of this change byte-identical

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

### The nine tests, by name

`velo-dispatch` sends you this brief and nothing else — it does not inject the
sidecar — so these names are listed here in full. The merge gate checks them
against `.agents/tasks/1918.json`, and a name that differs by one word fails
that gate no matter how good the test is. The previous attempt at this issue
wrote all three of its tests under different names and would have failed the
gate for that reason alone.

| test | must assert |
|---|---|
| `unaliased_computed_items_get_positional_expr_names` | `SELECT price * quantity, price - fee FROM trades` names the Project outputs `EXPR$0`, `EXPR$1` |
| `group_by_expression_key_gets_a_positional_name` | a computed GROUP BY key absent from SELECT is named positionally within the GROUP BY list |
| `plan_schema_and_project_exprs_agree_on_unaliased_expression_names` | the two plan-side naming surfaces agree, driven from ONE parsed SELECT list; must NOT compare against `plan.schema`, whose `Project` arm clones the builder's name and so cannot detect divergence |
| `select_field_column_is_named_identically_by_both_surfaces` | `SelectField::Column("t.amount")` yields `amount` from BOTH `select_fields_to_project_exprs` and `schema_from_select_fields` |
| `emitted_record_field_name_matches_plan_schema_for_computed_select_item` | the EMITTED RECORD's field name equals the propagated schema's, through a real engine consumer (§7a) |
| `group_by_expression_also_in_select_keeps_the_positional_name` | `SELECT price * quantity, COUNT(*) FROM trades GROUP BY price * quantity` names the key `EXPR$0` in the Aggregate schema, not `"expr"` |
| `unaliased_aggregate_gets_a_positional_name` | `SELECT SUM(value) FROM trades` names the output `EXPR$0`, NOT `SUM(value)` — plan and emitted record alike (§3a) |
| `two_unaliased_computed_aggregates_get_distinct_positional_names` | `SELECT SUM(a * b), SUM(c * d)` names them `EXPR$0` and `EXPR$1`, never `SUM(expr)` twice |
| `unselected_computed_group_key_does_not_collide_with_select_positional_name` | `SELECT COUNT(*) FROM t GROUP BY price * quantity` — group slot is `GROUP$0`, `COUNT(*)` is `EXPR$0`; the schema holds no duplicate generated name |
| `explicit_alias_survives_positional_naming` | `SELECT SUM(value) AS total` still emits `total`. **A GUARD, not a regression test** — explicit aliases already work on master, so it passes before AND after and can never be run red. It is deliberately NOT in `fail_to_pass`, is exempt from red-first, and must NOT be reported under stop condition 4. The first resume to reach it correctly proved it green at `origin/master` and stopped; that stop was the spec's fault, not the test's. |

Use these names exactly. Add more tests freely under any name you like.

`pass_to_stay` — must pass UNCHANGED, these are the alias canaries:

    group_by_aliased_key_schema_carries_alias_not_raw_name
    two_stage_aggregate_resolves_aliased_group_by_key
    t27_sliding_aliased_group_by_parity

### Red-first is REQUIRED, and must be recorded

**Which tests still owe red-first evidence: derive it, do not read it here.**

    grep -o 'test=[a-z_]*' <worktree>/agent.log | sort -u

Every name in `fail_to_pass` that does NOT appear in that output still owes a
`RED-FIRST` line. Any name that does appear is done — its line IS the evidence,
so do not re-run it.

`explicit_alias_survives_positional_naming` is the one exception and owes nothing:
it is a guard, exempt from red-first, and must never be reported under stop
condition 4 (see its row in the table above).



**Demonstrating red for the last three is harder, because your branch already
carries the fix.** A test written now will pass immediately, which proves nothing.
Use a throwaway worktree pinned at the pre-fix baseline:

    git -C <worktree> worktree add /tmp/1918-baseline origin/master
    # copy the new test in, run it there, capture the failure
    cargo nextest run --no-default-features --profile unit --manifest-path /tmp/1918-baseline/Cargo.toml -E 'test(<name>)'
    git -C <worktree> worktree remove /tmp/1918-baseline --force

If a test passes at `origin/master`, that is stop condition 4 — report it rather
than loosening the test.

So for **each** of the three:

1. Write the test FIRST, against unfixed code.
2. Run it and capture the failure — the assertion message, not just "it failed".
3. Append to `agent.log`:

       <UTC> RED-FIRST | test=<name> | failed-with=<one-line assertion message>

4. Make the change, re-run, confirm green.

A `fail_to_pass` name with no `RED-FIRST` line in `agent.log` is a brief
violation. This is not ceremony: the earlier attempt at this issue had a
group-by test that passed both before AND after the change, because it
constructed `Aggregate` with empty `select_exprs`/`alias_keys` and so never
reached the code path it claimed to cover. Red-first is what exposes that class
of test, and nothing else does.

## 7b. Required documentation

`docs/sql/PARSER_GRAMMAR.md` must document the generated-name rule alongside the
`select_item` production, and must describe the **shipped** behaviour — including
that the name holds at execution, not only in the plan.

Do not confuse this with §8's corpus rule. Editing a SQL **example** so a gate
stops complaining is forbidden; writing prose that **documents** the new
behaviour is the job. If you find yourself changing a ```sql fence, stop and
re-read this paragraph.

## 7b-bis. How to hand conclusions back — you do not open the PR

Two acceptance bars require you to STATE a conclusion, and §8 forbids you opening
a PR. `agent.log` and your final report are the handoff; the caller copies them
into the PR body.

Write both of these as their own lines in `agent.log`, and repeat them verbatim
in your final report:

    <UTC> ALIAS-KEYS | mode=<preserve|migrate> | verified-by=<test names or command>
    <UTC> CHANGED-EXPECTATION | test=<name> | why-old-was-wrong=<one line>

**These lines must reconcile against the diff.** Count the pre-existing test
functions whose assertion lines you modified; it must equal your
`CHANGED-EXPECTATION` line count, and both numbers go in the final report. A
modified assertion with no line is a silently weakened test; a line with no diff
hunk is a rationale for a change you did not make. Either mismatch is a STOP —
report the discrepancy, do not add lines to make the totals agree. This is what
makes an otherwise unverifiable prohibition checkable.

### The hunk audit — the SHAPE of a permitted edit

Counting lines is not enough on its own, so the edits themselves are constrained.
Inside a **pre-existing** test, the only change you may make is:

    -  collect_scalar(&outputs, "SUM(value)")
    +  collect_scalar(&outputs, "EXPR$0")

A legacy generated-name literal becomes the corresponding `EXPR$<n>` literal.

The second permitted shape is the **qualifier strip**, which bars 4 and 5 require
now that `SelectField::Column` routes through the shared helper:

    -  assert!(joined.to_field_map().contains_key("orders.order_id"));
    +  assert!(joined.to_field_map().contains_key("order_id"));

Reformatting a multi-line `assert!` onto one line because the literal got shorter
is shape-preserving and fine.

**On such a line, nothing else may change** — no numbers, no comparison operators,
no expected counts — and you may not add or delete an assertion in the test body.

Three shapes a reviewer will reject mechanically, so do not produce them:

| shape | why |
|---|---|
| a numeric expectation edited alongside the name | a real value regression papered over by a rename |
| an `assert*!` line deleted | the test got weaker, not renamed |
| the literal replaced by something other than `EXPR$<n>` | not the migration this issue authorises |

If a test genuinely cannot be fixed by a name substitution alone, that is
stop condition 3 — it is telling you a non-naming property moved. Report the hunk;
do not reshape the test to fit.

The second appears once per test whose expectation you changed. **Expect many** —
roughly 54 legacy generated names across ~11 modules. That is the task, not a
warning sign.

(An earlier version of this paragraph said zero was expected and that most should
be reported rather than changed. That was written before the aggregate rule was
pinned, it contradicted the acceptance bars, and it is exactly the contradiction
that halted a run. The only changed expectation that is NOT expected is one on an
`AS` alias or a non-naming property — that is stop condition 3.)

A conclusion that exists only in your head, or only in a commit message body, is
lost: the caller writes the PR from `agent.log` and your report.

## 7b-ter. Run `cargo fmt --all` BEFORE you stop

Unconditionally, and commit the result — not only when you reach the gate.

Both prior runs hit a STOP before reaching `run-commit.sh`, so neither ever
formatted, and CI on the draft PR failed at `cargo fmt --all -- --check` before
running a single test. 14 diffs across 9 files. A dispatch that stops early ships
unformatted code by construction unless fmt is unconditional.

So: the last two actions before writing a STOP line are always

    cargo fmt --all --manifest-path <worktree>/Cargo.toml
    git -C <worktree> add -A && git -C <worktree> commit

## 7c. Commit incrementally — and why this does not violate CLAUDE.md

Root `CLAUDE.md` opens with "DO NOT commit changes unless the user has explicitly
reviewed them first." **This section IS that explicit authorisation**, and it is
the narrower, task-specific rule, so it governs. The implementation policy states
the same precedence from the other side: "NEVER commit unless the caller's brief
explicitly authorizes it" — a brief that authorises is the condition being met,
not an exception being carved.

The authorisation is scoped, and the scope is the whole point:

- **Authorised**: `git commit` on your own dispatch branch, in your own worktree.
- **NOT authorised**: `git push`, opening a PR, merging, committing on `master`,
  or committing in any worktree that is not yours.

So: commit freely, publish nothing. A human reviews the branch before it becomes
a PR, which is the review `CLAUDE.md` is protecting.

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

Each entry names what a reviewer can check in the diff, not an intent to infer.

- **No collision handling.** The naming helper and its callers must not consult
  any collection of already-used names: no `HashSet`/`HashMap`/`Vec::contains`
  of prior names, no numeric suffix appended to a generated name, no retry loop
  on a name. `EXPR$<n>` derives from position ALONE. #1919 owns duplicate
  detection.
- **Do not implement NB-005 duplicate-output-name detection** — no new error
  variant, no new check in `sql/validation/name_binding.rs`. That is #1919.
- **Do not touch `__exists__`, `__raw__`, `__velostream_variant`, or `__agg__`**
  — zero diff lines containing those four strings.
- **Do not change a line inside a ```sql fence under `docs/` or `demo/`.**
  Checkable: no changed line in those trees lies within a ```sql fence. Prose
  changes to `docs/sql/PARSER_GRAMMAR.md` OUTSIDE such a fence are required work
  (§7b). Editing an example so a validator stops complaining is the escape hatch
  this closes; documenting the rule is the job.
- **Do not add `#[cfg(test)]` or `#[test]` inside `src/`** — zero such lines
  added under `src/`.
- **Do not weaken an existing test.** Checkable: the diff removes no `#[test]`,
  adds no `#[ignore]`, and deletes no `assert*!` line from a pre-existing test.
  The coupled tests in §3e are the gate for this work, not an obstacle — a naming
  change that requires silencing them has not been made correctly.
- **Do not change the `EXPR$` prefix or the `$<n>` form.**
- **If the diff touches `build_plan_alias_keys`, it must also touch the runtime
  readers in the same commit** — `select.rs::get_expression_name`,
  `accumulator.rs::generate_field_name`, or their call sites in
  `processors/select/group_by.rs` and `processors/group_by_columnar.rs`. A diff
  changing the producer alone is the one-sided edit that failed 48 tests (§3e).
- **Preserve explicit-alias behaviour exactly.** The output name of a
  `SelectField::AliasedColumn`, and of a GROUP BY expression that
  `select_alias_for_group_expr` matches to an `AS`-aliased SELECT item, must be
  unchanged — `group_by_aliased_key_schema_carries_alias_not_raw_name` and
  `two_stage_aggregate_resolves_aliased_group_by_key` are in `pass_to_stay` as
  the check. Those two cases are the WHOLE of what this entry covers; no wider
  notion of adjacent alias defects is implied or forbidden. STOP and report if
  fixing `__group__` appears to require changing either.
- **Do not change a public signature with callers outside `plan/` and
  `execution/`** — STOP and report instead.

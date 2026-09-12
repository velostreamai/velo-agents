# #1918 — give unaliased computed SELECT items a real, unique output name

Parent: #1970 (SQL surface defects from the #1749 name-binding audit)
Unblocks: #1919 (NB-005 duplicate-output-name validation), then #2045.

## 1. Target and isolation

Worktree: `/Users/neilavery/RustroverProjects/velostream-1918`
Branch: `fix/1918-expr-output-names`
Both are created for you by `velo-dispatch` off current `origin/master`. The
worktree is clean and carries no prior commits.

**Do NOT `cd` into the worktree except for `gh` commands (gh has no `-C`).**
Use `git -C <worktree>`, `cargo --manifest-path <worktree>/Cargo.toml`, and
absolute paths with Read/Edit/Write.

## 2. Fresh line numbers

Cut with `grep -n` at dispatch time against `1126b36a4`, verified:

    src/velostream/sql/plan/builder.rs:1617             _ => FieldName::from("__expr__"),
    src/velostream/sql/plan/schema_propagation.rs:685   .unwrap_or_else(|| FieldName::from("__expr__"));
    src/velostream/sql/plan/schema_propagation.rs:478   _ => FieldName::from("__group__"),

Containing functions (use these if a line has moved — the symbol is authoritative,
the number is not):

    builder.rs             fn select_fields_to_project_exprs   (~1601)
    schema_propagation.rs  pub fn schema_from_select_fields    (~657)
    schema_propagation.rs  fn expr_output_name                 (~474)

The issue body cites `schema_propagation.rs:630` for the second site. That number
is **stale** — it is now `:685`. Trust the grep above, not the issue.

## 3. Pinned design — you do not choose

### 3a. The naming scheme: positional `EXPR$<n>`

An unaliased SELECT item whose expression is not a column reference is named
`EXPR$<n>`, where `<n>` is that item's **zero-based position in the select
list**. `SELECT price * qty, price - fee FROM trades` outputs `EXPR$0`, `EXPR$1`.

This is the Apache Calcite convention, which is what Flink SQL emits. It was
chosen over the two alternatives deliberately:

- **Derived-from-expression names** (`avg_price`, DuckDB/Spark style) read better
  but regenerate the very collision this fixes — `SELECT AVG(a.price), AVG(b.price)`
  produces two identical derived names.
- **A shared constant** (`?column?`, today's `__expr__`) is what we are removing.

Positional is collision-free *within one projection* by construction, because
positions are distinct. That property is the whole point.

### 3b. Sweep the class: `__group__` too

`expr_output_name` (`schema_propagation.rs:478`) has the identical defect for a
GROUP BY key that is not a column reference — every such key is named
`__group__`. Fix it in the same change, with the same generator and the same
positional rule applied to its own list.

Do not stop at `__expr__`. Two placeholders, one defect class, one PR.

**Boundary**: #1469 (GROUP BY output schema ignores an `AS` alias) is an
adjacent output-naming defect in the same function's neighbourhood. It is **not
yours**. If you find the `__group__` fix cannot be made without also changing
that behaviour, STOP and report — do not fold it in.

### 3c. The two `__expr__` sites currently DISAGREE — make them agree

This is a real bug sitting underneath the naming one, and it is in scope.

`builder.rs:1611-1618` inspects the expression before falling back:

```rust
.unwrap_or_else(|| match expr {
    Expr::Column(col) => output_name_for_column_ref(col),
    Expr::ColumnRef { name: col, .. } => output_name_for_column_ref(col),
    _ => FieldName::from("__expr__"),
});
```

`schema_propagation.rs:682-686` **discards the expression entirely**:

```rust
SelectField::Expression { alias, .. } => {
    let name = alias.as_deref().map(FieldName::from)
        .unwrap_or_else(|| FieldName::from("__expr__"));
```

So an unaliased `SelectField::Expression` holding a plain column ref gets its
real column name from `builder.rs` and `__expr__` from `schema_propagation.rs`
— the plan schema and the projection exprs disagree on the same field's name.

**Both sites must apply identical logic.** Extract one shared helper and call it
from both, rather than copying the match arm. The `builder.rs` behaviour (resolve
a column ref to its bare name; generate only for genuine expressions) is the
correct one.

### 3d. What this change does NOT do: collision handling

`EXPR$0` can still collide with a user-supplied `SELECT x AS "EXPR$0"`, or with
an inherited column of that name from an upstream CSAS. **Do not handle that
here.** Detecting and reporting duplicate output names is #1919 (NB-005), which
is sequenced immediately after this and depends on it.

Specifically: **do not** add a suffix-bumping loop (`EXPR$0` → `EXPR$0_1`).
Silently renaming to dodge a collision is precisely the papering-over that
#1919 exists to make loud, and per the project's no-silent-fallback rule it
would be a defect, not a safeguard.

Generate the name. Let #1919 validate it. Say so in a code comment at the
generator so the next reader does not "fix" the gap.

This ordering is not arbitrary — ksqlDB shipped positional generated names
*without* a uniqueness check and it collided on derived streams
(confluentinc/ksql#2401, still open). We are landing the generator and the
check as a pair, generator first.

**If you believe this design is wrong, STOP and report why. Do not substitute
your own.**

## 4. Blast radius and size budget

Measured across `src/`, `tests/`, `examples/`, `benchmarks/` at `1126b36a4`:

    grep -rn '__expr__'   -> 2 refs, 2 files   (both in src/, listed in §2)
    grep -rn '__group__'  -> 1 ref,  1 file
    grep -rn 'FieldName::from("__'  -> 7 refs, 3 files

That last count is **deliberately not your scope**: `__exists__`
(`schema_propagation.rs:384`), `__raw__` (`builder.rs:1298,1363`) and
`__velostream_variant` (`arrow_bridge_test.rs:799`) are legitimate internal
sentinels, not output-name placeholders. Leave all four alone.

Nothing in `tests/`, `docs/` or `demo/` references `__expr__` or `__group__`,
so no existing test pins the old names.

Expected touch: **2 source files + 1–2 new test files.**
**Tripwire: if you pass 5 files, STOP — you have taken the wrong approach.**

## 5. STOP conditions, and what success looks like

STOP and report, without pushing, if:

- the shared helper from §3c cannot be extracted without changing a public
  signature that has callers outside `plan/`;
- making the two sites agree turns an existing test red — that means the
  divergence was load-bearing somewhere and the orchestrator must rule on it;
- `./run-commit.sh --fast` fails for any reason;
- you find yourself wanting a suffix-bump or any other collision workaround.

A RED corpus gate is **not** expected here. `__expr__` appears in no doc and no
demo SQL, so the doc-example gate should be unaffected. **If the doc gate goes
red, that is a genuine finding — report it, do not edit docs to make it green.**
Editing corpus files to satisfy a new validator is a known escape hatch in this
repo and is forbidden in §7.

Successful run: two placeholders gone, one shared generator, the two sites in
agreement, new tests pinning `EXPR$0`/`EXPR$1`, gate green.

## 6. SQL syntax

You will write SQL in tests. Velostream SQL is **not** Postgres, ksqlDB or Flink
SQL, despite this brief citing their naming conventions — the convention is
borrowed, the grammar is not. References:

    docs/claude/SQL_GRAMMAR_RULES.md
    docs/sql/PARSER_GRAMMAR.md
    docs/sql/COPY_PASTE_EXAMPLES.md
    src/velostream/sql/CLAUDE.md

Reference idiom: `demo/trading/sql/ctas_file_trading.sql`, `demo/trading/apps/*.sql`.

Prove-before-use: grep the parser and the grammar docs for any function you are
not certain of. Absent means unsupported — do not invent a construct to make a
test parse. Write complete statements (select list AND `FROM`), never a bare
fragment.

## 7. Validation commands

Inner loop:

    cargo check --no-default-features --manifest-path <worktree>/Cargo.toml

Scoped tests:

    cargo nextest run --no-default-features --manifest-path <worktree>/Cargo.toml -E 'test(expr_output)'
    cargo nextest run --no-default-features --no-fail-fast --lib --test mod --manifest-path <worktree>/Cargo.toml

Gate, once, from the worktree root:

    (cd <worktree> && ./run-commit.sh --fast)

`run-commit.sh` runs `cargo fmt --all` as a **wet apply** — it rewrites files in
place. After it completes, run `git -C <worktree> status`; if fmt changed
anything you **must** commit it. The gate formats but cannot commit, and an
uncommitted reformat fails CI's independent `cargo fmt --check`.

Do **not** re-run the gate to get different output. It prints `📝 Full log: <path>`
at start and end — read that log and grep it.

New test files **must** be registered in the parent `mod.rs`, or they do not run.

## 7a. Required documentation

`docs/sql/PARSER_GRAMMAR.md` must document the generated-name rule alongside the
`select_item` production: an unaliased item whose expression is not a column
reference is named `EXPR$<n>` by position. This is acceptance bar 4 on the issue
and is **required work**, not optional polish.

Do not confuse it with §8's corpus rule. Editing a SQL **example** so a gate
stops complaining is forbidden; writing prose that **documents** the new
behaviour is the job. If you find yourself changing a ```sql fence, stop and
re-read this paragraph.

## 7b. Commit incrementally

Commit after each logical step, not once at the end. A timeout or crash must
never lose completed work. Small commits are expected and will be squashed at
merge; do NOT wait until everything is done and validated. If you are about to
start a long step — a full gate run, a multi-file edit — commit what you already
have FIRST.

Two prior runs died on a prompt timeout with all their work uncommitted in the
worktree, and restarted from zero.

This does not loosen §8: commit freely on your own branch, but do not push, open
a PR, or merge.

## 8. Forbidden

- Do not add a suffix-bump or any collision workaround (§3d).
- Do not implement NB-005 / duplicate-name detection — that is #1919.
- Do not touch `__exists__`, `__raw__`, or `__velostream_variant`.
- Do not edit a SQL **example** under `docs/` or `demo/` to make a gate pass.
  (Writing the PARSER_GRAMMAR.md prose required by §7a is a different act and
  is expected.)
- Do not resolve #1469 while sweeping `__group__` — see §3b.
- Do not add `#[cfg(test)]` or `#[test]` inside `src/`.
- Do not delete, skip, `#[ignore]` or narrow any existing test.
- Do not commit or push until the gate is green; do not open a PR or merge.

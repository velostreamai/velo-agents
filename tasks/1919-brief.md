# #1919 — NB-005: reject a SELECT that emits two columns under one name

Parent: #1970 (SQL surface defects from the #1749 name-binding audit)
Depends on: #1918 (must be CLOSED — this consumes its naming helper)
Unblocks: #2045 (the JOIN output-naming contract)

## 1. Target and isolation

Worktree: `/Users/neilavery/RustroverProjects/velostream-1919`
Branch: `fix/1919-nb005-duplicate-output-names`
Both are created for you by `velo-dispatch` off current `origin/master`. The
worktree is clean and carries no prior commits.

**Do NOT `cd` into the worktree except for `gh` commands (gh has no `-C`).**
Use `git -C <worktree>`, `cargo --manifest-path <worktree>/Cargo.toml`, and
absolute paths with Read/Edit/Write.

## 2. Fresh line numbers

Cut with `grep -n` at dispatch time, verified. Symbols are authoritative; if a
number has moved, trust the symbol.

    src/velostream/sql/validation/name_binding.rs:188   check_duplicate_relation_names(&own_names)?;
    src/velostream/sql/validation/name_binding.rs:628   fn check_duplicate_relation_names
    src/velostream/sql/validation/name_binding.rs:668   fn collect_output_names
    src/velostream/sql/validation/name_binding.rs:802   fn err_duplicate_relation_name        (NB-003)
    src/velostream/sql/plan/schema.rs:59                pub fn new                            (no uniqueness check)
    src/velostream/sql/plan/schema.rs:93                pub fn index_of                       (returns position(), first match)

## 3. Pinned design — you do not choose

### 3a. Where it goes

`sql/validation/name_binding.rs`, beside NB-003. That module already owns this
class and the `NB-00N` code convention, and **NB-003 is the same rule on the
relation axis**:

```
[NB-003] relation name '{exposed}' is used by more than one source in this
         FROM/JOIN list; give each relation a distinct alias …
```

NB-005 is that rule on the **output-column** axis. NB-004 was retired as
unreachable (#1883), so 005 is the next free code.

Add `check_duplicate_output_names(fields)?` immediately after the existing
`check_duplicate_relation_names(&own_names)?` call in `validate_query_scope`
(`:188`). `fields` is already in scope there.

### 3b. THE TRAP: do NOT reuse `collect_output_names`

`collect_output_names` (`:668`) exists and looks like what you want. **It is
not.** It returns **explicit `AS` aliases only** — it maps
`SelectField::Column(_)` and unaliased `Expression` to `None` on purpose,
because it serves the §3b.1/§5d alias-reuse exemption, not output naming.

Reusing it would make NB-005 blind to the qualifier-strip case, which is the
main case this issue exists for. Write a **separate** helper for the emitted
name set. Leave `collect_output_names` alone.

### 3c. What the emitted name of each select item is

| `SelectField` | emitted name |
|---|---|
| `AliasedColumn { alias, .. }` | `alias` |
| `Expression { alias: Some(a), .. }` | `a` |
| `Expression { alias: None, expr }` | bare column name if `expr` is a column ref; otherwise #1918's generated `EXPR$<n>` |
| `Column(name)` | `name` with the qualifier stripped (everything after the last `.`) |
| `Wildcard` | **skipped — see §3d** |

**Use #1918's shared naming helper for rows 3 and 4.** Do not re-derive the
rule. The entire point of #1918 was to collapse two divergent copies into one;
adding a third here re-creates the defect one layer up, and NB-005 would then
police names the planner does not actually emit.

If that helper cannot be called from `validation/` without violating this
module's stated purity — it is a **pure AST walk: no schema, no catalog, no
plan** (module doc, §4/§4a) — then **move the helper** to a module both can
depend on. Do NOT duplicate it, and do NOT import `plan/` into `validation/`.
If neither is possible, STOP and report; that is an orchestrator decision.

### 3d. Case 4 (`SELECT *, col`) is OUT OF SCOPE — pinned

The issue lists four ways a collision arises. Three are visible to an AST walk.
The fourth, a wildcard colliding with an explicit item, **is not**: expanding
`*` requires a schema, and this validator deliberately has none.

So: **skip `SelectField::Wildcard` entirely.** A select list containing a
wildcard still has its non-wildcard items checked against each other.

This is a scope boundary, not a deferral of a known defect, and the reasons are
recorded so nobody "completes" it later by accident:

- A corpus scan over the 72 enforced doc files plus all `demo/**/*.sql` found
  **zero** instances of case 1 (`a.x, b.x`) and **zero** of case 3
  (`AS n, AS n`). The 9 wildcard hits are `SELECT *, _timestamp, _partition,
  _key` and `SELECT o.*, c.name`.
- The first is only a collision if `*` expansion includes system columns —
  **unresolved**, and answering it is a separate decision.
- The second is #1931: `SELECT alias.*` is documented grammar with **no parser
  production**, so it does not parse today regardless.

Do not add a schema-aware check, do not move NB-005 into `Schema::new`, and do
not file or fix case 4 here. Put a comment at the wildcard arm stating it is
out of scope and why, citing #1931.

### 3e. Matching is case-insensitive

Use `eq_ignore_ascii_case`, as `check_duplicate_relation_names` (`:638`) does.
SQL unquoted identifiers are case-insensitive for matching, so `x` and `X` are
one output name and must collide.

### 3f. The message must name both items and how to fix it

A bare "duplicate column" is not actionable in a 30-column projection. Follow
NB-003's shape — state the rule, then the remedy. Per the issue:

```
[NB-005] output column name 'symbol' is produced by more than one SELECT item
  item 1: a.symbol
  item 3: b.symbol
  Output names drop the qualifier, so both become 'symbol'.
  Disambiguate with an alias, e.g. `a.symbol AS a_symbol`.
```

The generated-name case needs **different** guidance, because the user wrote no
name at all and telling them to "disambiguate `EXPR$0`" is nonsense:

```
[NB-005] output column name 'EXPR$0' is produced by more than one SELECT item
  item 2: price * qty
  item 4: price - fee
  Unaliased computed items are named by position; one of these collides with an
  explicit alias of the same name. Give the computed items explicit aliases.
```

Item numbers are **1-based** select-list positions, matching how a person reads
their own query.

### 3g. Why an error and not a warning

Do not soften this to a warning. Postgres permits duplicate output names because
a result set is transient. A Velostream CSAS **writes a stream whose schema
later statements and external consumers resolve against**:

- Avro record fields and Protobuf message fields must be unique — a duplicate is
  *unrepresentable* on those codecs, so it surfaces at the sink, far from the
  SELECT that caused it, or silently drops a field.
- `Schema::index_of` (`schema.rs:93`) returns `position(...)` — the first match.
  The second field is unreachable by name anywhere in the engine.
- A later statement doing `FROM that_stream` has no way to name it.

**If you believe this design is wrong, STOP and report why. Do not substitute
your own.**

## 4. Blast radius and size budget

Measured across `src/`, `tests/`, `examples/`, `benchmarks/`:

    grep -rn 'check_duplicate_relation_names'  -> 10 refs, 4 files
      src/velostream/sql/validation/name_binding.rs            (def, call, 1 comment)
      tests/unit/sql/parser/identifier_case_fold_test.rs
      tests/unit/sql/plan/name_binding_conformance_test.rs
      tests/unit/sql/validation/name_binding_validation_test.rs

That is the NB-003 analogue's footprint and shows you the shape NB-005 should
take — it is NOT a list of files to edit.

Expected touch: **1 source file + 2 test files** (extend the existing
`name_binding_validation_test.rs` and `name_binding_error_message_test.rs`;
both already hold NB-003's cases).
**Tripwire: if you pass 5 files, STOP — you have taken the wrong approach.**

## 5. STOP conditions, and what success looks like

STOP and report, without pushing, if:

- #1918's naming helper cannot be reached from `validation/` without importing
  `plan/` AND cannot be moved to a shared module (§3c);
- adding NB-005 turns an existing test red — that means some test relies on
  emitting duplicate names, and the orchestrator must rule before you touch it;
- `./run-commit.sh --fast` fails for any reason;
- you find yourself needing a schema to decide a case (that is case 4; it is out
  of scope, §3d).

**The doc corpus gate is the one to watch.** A scan predicts NB-005 fires on
**zero** enforced doc blocks once #1918 has landed. If it goes red, that is a
genuine finding — **report it, do not edit the corpus to make it green.**
Editing example SQL to satisfy a new validator is a known escape hatch in this
repo and is forbidden in §8. A red corpus most likely means #1918's generated
names are colliding somewhere, which is real information.

Successful run: NB-005 rejects cases 1–3 with an actionable message, wildcards
are skipped with a comment saying why, `collect_output_names` untouched, corpus
green.

## 6. SQL syntax

You will write SQL in tests. Velostream SQL is **not** Postgres, ksqlDB or Flink
SQL. References:

    docs/claude/SQL_GRAMMAR_RULES.md
    docs/sql/PARSER_GRAMMAR.md
    docs/sql/COPY_PASTE_EXAMPLES.md
    src/velostream/sql/CLAUDE.md

Reference idiom: `demo/trading/sql/ctas_file_trading.sql`, `demo/trading/apps/*.sql`.

Prove-before-use: grep the parser and the grammar docs for any construct you are
not certain of. Absent means unsupported — do not invent one to make a test
parse. Write complete statements (select list AND `FROM`), never a bare fragment.

Note `SELECT alias.*` does **not** parse (#1931) — do not write it in a test
expecting a parse, even to prove case 4 is skipped.

## 7. Validation commands

Inner loop:

    cargo check --no-default-features --manifest-path <worktree>/Cargo.toml

Scoped tests:

    cargo nextest run --no-default-features --manifest-path <worktree>/Cargo.toml -E 'test(nb005)'
    cargo nextest run --no-default-features --manifest-path <worktree>/Cargo.toml -E 'test(name_binding)'
    cargo nextest run --no-default-features --no-fail-fast --lib --test mod --manifest-path <worktree>/Cargo.toml

Gate, once, from the worktree root:

    (cd <worktree> && ./run-commit.sh --fast)

`run-commit.sh` runs `cargo fmt --all` as a **wet apply** — it rewrites files in
place. After it completes, run `git -C <worktree> status`; if fmt changed
anything you **must** commit it. The gate formats but cannot commit, and an
uncommitted reformat fails CI's independent `cargo fmt --check`.

Do **not** re-run the gate to get different output. It prints `📝 Full log: <path>`
at start and end — read that log and grep it.

New test files must be registered in the parent `mod.rs`, or they do not run.
Prefer extending the two existing files named in §4.

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

- Do not reuse or modify `collect_output_names` (§3b).
- Do not duplicate #1918's naming helper — call it, or move it (§3c).
- Do not import `plan/` into `validation/`; that module is a pure AST walk.
- Do not implement case 4 / wildcard collision, and do not move NB-005 into
  `Schema::new` (§3d).
- Do not soften NB-005 to a warning (§3g).
- Do not edit a SQL **example** under `docs/` or `demo/` to make a gate pass.
- Do not add `#[cfg(test)]` or `#[test]` inside `src/`.
- Do not delete, skip, `#[ignore]` or narrow any existing test.
- Do not commit or push until the gate is green; do not open a PR or merge.

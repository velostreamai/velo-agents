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
| `Expression { alias: None, expr }` | bare column name if `expr` is a column ref; otherwise #1918's generated `EXPR_<n>` |
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
name at all and telling them to "disambiguate `EXPR_0`" is nonsense:

```
[NB-005] output column name 'EXPR_0' is produced by more than one SELECT item
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

## 4z. ORCHESTRATOR RULING — the three NB-001 exemption tests

You stopped on 2026-09-16T06:01:41Z because NB-005 reddened three pinned tests in
`tests/unit/sql/validation/name_binding_validation_test.rs`. That was the correct
call. Here is the ruling; apply it exactly and do not extend it to any other test.

The collision is real, not a bug in your implementation. NB-001 governs whether a
bare reference **resolves on the input side**; NB-005 governs whether the
**emitted output names** are unique. Those are different questions, and a query can
fail one while passing the other. All three tests were written before NB-005
existed, so each silently assumed the output-name question was never asked.

**Ordering — decide this first, the rest follows.** Run NB-001 resolution
validation BEFORE NB-005 output-name validation, and report the first that fires.
A query whose inputs cannot bind should say so; complaining about the output name
of a query that cannot resolve its own columns buries the real error.

**1. `output_alias_later_does_not_exempt_earlier_bare_ref_nb001` — DO NOT TOUCH.**

    SELECT amount, a.p * 2 AS amount FROM ta a JOIN tb b ON a.x = b.x

Rejected either way: NB-001 fires on item 0 (bare `amount`, ambiguous at arity 2,
no earlier alias), NB-005 would fire on item 1. Under the ordering above NB-001
wins and the existing `assert_rejected_with_code(&result, "[NB-001]")` still
passes. If this test is red, your ordering is wrong — fix the ordering, not the
test.

**2. `output_alias_earlier_exempts_later_bare_ref` — EDIT THE QUERY, keep the test.**

    -- from
    SELECT a.p * 2 AS amount, amount            FROM ta a JOIN tb b ON a.x = b.x
    -- to
    SELECT a.p * 2 AS amount, amount AS amount_ref FROM ta a JOIN tb b ON a.x = b.x

The test exists to pin the **exemption**: item 1's bare `amount` resolves via item
0's alias. Aliasing item 1 leaves that exercised identically — the body is still a
bare `amount`, still resolved through the same path — while removing an output
collision that was incidental to what the test was written to prove. Update the
comment to say the alias keeps the output names distinct so NB-005 stays out of the
way, and that the exemption is still the assertion.

Then **add** a new `fail_to_pass` test, `nb005_earlier_alias_exempts_but_output_names_still_collide`,
pinning the ORIGINAL shape as rejected with `[NB-005]`. The exemption holding and
the output names colliding are both true of that query, and after this change each
has its own test. Nothing is lost.

**3. `duplicate_alias_spelling_does_not_strip_earlier_exemption` — CONVERT THE
ASSERTION, keep the query verbatim.**

    SELECT a.p AS amount, amount AS total, total AS amount FROM ta a JOIN tb b ON a.x = b.x

Here the duplicate spelling **is** the test, so §2's trick is unavailable — remove
the collision and there is no test left. Instead keep the query exactly as it is and
change the assertion from `.expect(...)` to: rejected with `[NB-005]`, **and
explicitly NOT `[NB-001]`**.

That preserves the original guard precisely. The regression it was written for was
item 2's alias wrongly stripping item 1's legitimate earlier exemption, which would
surface as an NB-001 rejection. Asserting "NB-005 and not NB-001" proves both that
the exemption still holds and that only the output-name rule fired — a strictly
stronger assertion than the old `.expect()`, which could have passed for the wrong
reason. Rewrite the comment to say so, keeping the existing explanation of the
original regression, and note that the shape is now rejected for an unrelated
reason while the exemption it guards remains intact.

**Scope of this ruling.** It covers these three tests only. If a FOURTH existing
test reddens, STOP again and report it — do not reason by analogy from the above.

## 4y. ORCHESTRATOR RULING 2 — NB-005 stays UNIVERSAL; the 13 reds

You stopped again at 2026-09-16T07:56:41Z with 13 tests red, all carrying
`[NB-005]`. That was the correct call — ruling 1 told you to stop rather than
reason by analogy past the three it covered.

**The scope question, decided.** All 13 reds are plain `SELECT`s, and the
dominant shape is `SELECT a.id, b.id FROM a JOIN b`, which Postgres, MySQL,
DuckDB and Flink all accept — they reject duplicate output names only for
`CREATE VIEW` / `CREATE TABLE AS`. Narrowing NB-005 to schema-registering
selects was considered and **rejected**. NB-005 fires on **every** select,
as the issue specifies.

This is a deliberate divergence from those engines, so the reasoning is recorded
rather than left to be rediscovered and re-argued: in a streaming engine the
output of a `SELECT` is a materialised stream that downstream queries bind
against by name. A duplicate output name is unreferenceable downstream whether
or not a `CREATE` wrapper happens to be present, which is the defect #1918 is
named for. The permissive ad-hoc-`SELECT` case that justifies the standard
behaviour in an interactive database does not exist here in the same way.

So the tests get fixed, not the rule. Each of the 13 is classified below. Apply
the classification given; do not reclassify one because its fix is awkward.

### Class A — the duplicate IS the subject: flip the assertion to NB-005

These three were written to pin the behaviour of a duplicate output name. That
behaviour is now "rejected at validation", so they assert that.

| test | query |
|---|---|
| `duplicate_output_aliases_are_not_admitted_to_the_join_batch_path` | `SELECT a.auction_id AS x, r.tier AS x` |
| `join_same_bare_column_both_sides_produces_duplicate_plan_output_names` | `SELECT a.id, b.id FROM a JOIN b ON a.id = b.id` |
| `user_column_named_like_a_generated_name_is_not_silently_merged` | `SELECT price * qty, some_col AS EXPR_0 FROM t` |

The third is the natural completion of #1918, not a casualty of it: #1918 pinned
that the collision must be **visible rather than silently merged**, and a hard
NB-005 error is the strongest available form of visible. Rewrite its comment to
say that, citing #1918, so the next reader does not mistake the change for a
weakening.

For the first: note in the test comment that the join-batch-path guard it was
written for is **no longer reachable from SQL**, because validation now rejects
the query before the batch path sees it. The guard should stay — defence in
depth — but the coverage note matters, and silently losing the fact that a guard
became unreachable is how dead code accumulates.

### Class B — the duplicate is incidental scaffolding: alias it, keep the assertion

Eight tests use a colliding pair only as a convenient fixture for testing
something else — resolution to the correct relation, interval-join lowering,
round-trip, PRIMARY KEY marking. Give the colliding items distinct aliases
(`SELECT a.id AS a_id, b.id AS b_id`) and **leave every existing assertion
exactly as it is**. Aliasing changes the output names; it does not change which
relation each item resolves to, which is what these tests actually assert.

    selected_system_columns_are_output_columns_over_a_join    a._OFFSET, _OFFSET
    accept_qualified_reference_disambiguates_collision        a.amount, p.amount
    accept_qualified_reference_in_self_join                   l.id, r.id
    test_mirrored_probe_on_left_flips_and_swaps_bounds        a.id, b.id
    test_source_name_qualifiers_without_aliases               trades.id, quotes.id
    accept_a_every_valid_spelling_of_a_real_column            amount, a.amount
    accept_g_same_bare_name_both_sides_disambiguated          a.id, p.id
    test_primary_key_marks_at_most_one_field_on_bare_name_collision
                                                              a.symbol PRIMARY KEY, b.symbol

Two carry a wrinkle:

- `accept_qualified_reference_disambiguates_collision` also asserts
  `SELECT * FROM auction a JOIN person p ...` passes. That must **still** pass —
  wildcards are skipped per §3d. Do not alias inside it.
- `test_primary_key_marks_at_most_one_field_on_bare_name_collision` loses its
  literal "bare name collision" scenario once aliased. Keep the PRIMARY KEY
  assertion under aliases, and **add** a sibling asserting the colliding form is
  now rejected with `[NB-005]`. The PK question and the collision question then
  each have a test, and neither is lost.

### Class C — `medium1_same_name_no_alias_collision_build_wins`

    SELECT l.id, r.tier, l.status, r.status FROM left_stream l ...

This one is about which side wins when both contribute `status` to the merged
record, so aliasing would delete the subject and flipping to NB-005 would delete
the merge-semantics coverage. Neither is acceptable.

Re-express it through `SELECT *`, which NB-005 skips (§3d) and which still
produces the same-name merge this test exists to pin. If `SELECT *` does not
reach the same merge path — verify, do not assume — **STOP and report**, because
then NB-005 has made a real behaviour untestable and that is a finding, not a
detail to work around.

### Class D — the doc, `docs/sql/functions/SELECT-ALIAS-REUSE.md:148`

    SELECT amount AS amount, amount * 1.1 AS amount FROM transactions;

§8 forbids editing the corpus to make the gate green, and that prohibition
stands for its intended case: a red corpus is normally evidence the validator is
wrong. Here the validator has been ruled correct, so this example genuinely
teaches a shape that is now invalid — fixing it is a real fix, and it is
**authorised, for this one block only**.

Note also that §3d's corpus scan claimed **zero** instances of this case across
the 72 enforced doc files. It found one. Record that in your report: the scan
that justified the scope boundary was wrong, which is worth knowing for the next
spec that leans on a corpus scan.

Preserve the lesson. The block teaches alias shadowing — that `amount * 1.1`
reads the *aliased* value, not the original column — and that lesson survives
intact if only the second output name changes:

    SELECT amount AS amount, amount * 1.1 AS amount_with_markup FROM transactions;

Keep the surrounding prose and both inline comments. Do not touch any other
block in that file or any other doc.

### Scope of this ruling

These 13 and nothing else. A **fourteenth** red test stops you again — report
it, do not extend the classification by analogy. Two stops on this issue have
each surfaced something the spec had genuinely got wrong, which is the system
working; a third would too.

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


---

## Note from #1918 (R16): the generated-name spelling changed, and your input space grew

#1918 shipped `EXPR_<n>` / `GROUP_<n>` with an **underscore**, not `EXPR$<n>`. The
`$` form was superseded because `parser/tokenizer.rs:392-395` continues an
identifier only while `is_alphanumeric() || '_'`, so `$` terminates one and
`SELECT EXPR$0 FROM t` could not tokenize — the generated name was unique but still
unreferenceable, which is the defect #1918 exists to close.

**This enlarges NB-005's input space.** `EXPR$0` was unconstructible via the
parser, so a user column could never collide with a generated name. `EXPR_0` IS
constructible, so

    SELECT price * qty, some_col AS EXPR_0 FROM t

is now a real collision NB-005 must report. #1918 deliberately added no collision
handling and pinned only that the collision is VISIBLE at the plan surfaces; the
record level still merges byte-identical duplicates
(`rows_window.rs:703/736/769/793` are `FxHashMap::insert`). Closing that is yours.

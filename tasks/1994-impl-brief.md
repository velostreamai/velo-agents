# #1994 — promote the HAVING two-schema rewrite into the executed plan

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1994
BRANCH:   fix/1994-auto (already cut and checked out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## Read the analysis first

`.agents/tasks/1994-analysis.md` on master (merged as PR #2021) is the Stage-1
for this work. Read §1, §2, §3, §5, §6. **Two corrections to it, both from the
gate that reviewed it — do not work from the uncorrected text:**

1. **§2b-1 / R2 describe the wrong failure mode.** They claim a `Case` arg
   matches nothing and evaluates `Null`, filtering every group. It does not: for
   a `Case` arg both sides yield `None` and `find_slot_output_alias`'s
   `(None, None) => true` arm matches the first same-kind slot, so a single
   complex-arg query resolves correctly today. The real hazard is **two**
   same-kind complex args both binding to the **first** slot — silent wrong
   column. That is filed as **#2026** and is **out of scope here**.
2. **R1 cites the pin test at `tests/unit/sql/plan/`.** It is actually
   `tests/unit/sql/execution/processors/window/having_index_divergence_pin_test.rs`.
   The test is real; the path in the analysis is wrong.

## The defect

`rewrite_having_aggregate_arguments` (`column_resolution.rs`) draws the
source/output schema boundary at exactly the right depth and covers the
compound-`CASE` case. It has **one caller** — inside `visit_node`, on
`predicate.clone()`, for the completeness gate's coverage derivation — and its
result is fed to `visit_expr` and **discarded**.

So it never reaches the executed plan, and HAVING's raw input columns fall to
per-record name resolution at runtime. That is exactly the
gated-additive-helper-with-no-production-caller anti-pattern the repo's
production-wiring discipline forbids.

## The two-schema split — do not collapse it

- **Raw input columns inside aggregate arguments** (`HAVING SUM(CASE WHEN
  side='BUY' THEN quantity END) > 0`) resolve against the **SOURCE** schema.
- **Aggregate-result references** (`HAVING COUNT(*) > 5`) exist **only** in the
  Aggregate's **OUTPUT** schema.

One pass with one schema cannot do both. That is why the function exists
separately. Rewriting the whole predicate against the source schema is
explicitly forbidden below.

## Pinned decisions — the analysis left these to the maintainer; they are decided

### R1 — sequencing around #1747: **promote with NAMES, not indices**

#1747's index divergence is live: the chunked window path reads an index-based
value that is actively wrong today, pinned by
`having_index_divergence_pin_test.rs`. The analysis offered three options; the
decision is **option (b)**.

Promote the rewrite in a form the chunked path **cannot misread** — keep names
in whatever copy the strategy stamps, so no source-schema `index` is introduced
where an index is consumed. Do **not** fix #1747 first, and do **not** stamp
indices and document them as deliberately unconsumed.

**If that turns out not to be achievable, STOP and report** — it means the
pinned option is not viable and the sequencing decision needs revisiting. Do not
substitute another option.

### R2 — the coupled defect: **out of scope, already filed**

Filed as **#2026** with the corrected failure mode. Do not fix it, do not work
around it, do not let it block. If your change makes it more visible, say so.

### R3 — invariant and gate, **in scope, same PR**

- `column_resolution.rs`'s module doc states *"Post-rule, every `Expr::Column`
  remaining in the tree is a column that could not be resolved."* Amend it so it
  is TRUE after this change, or so it names its remaining exceptions precisely.
- `docs/architecture/name-binding.md` §1c condition 2 carves HAVING out because
  the resolver does not visit it. Update that carve-out to match the coverage
  this change produces.
- **`visit_node(strict_gate)` must remain the SINGLE derivation point** for
  condition 2. If the diagnostic clone-walk is retired, the gate reads the
  promoted plan — never a third scoping.

The gate must **describe** resolver coverage, never compensate for it. If
amending §1c would mean weakening the gate, **STOP**.

## Anchors — `grep -n` verified at dispatch time against `330412fcd`

```
src/velostream/sql/plan/column_resolution.rs   fn rewrite_having_aggregate_arguments  (1)
src/velostream/sql/plan/column_resolution.rs   fn having_aggregate_input              (1)  <- REUSE, do not write a second
src/velostream/sql/plan/column_resolution.rs   fn rewrite_node                        (1)  <- the Filter arm; fix lands here
```

`PlanNode::Aggregate` has **no `having` field** — the word does not appear in
`logical.rs`. HAVING is a `Filter` above the Aggregate.

## Tests

**fail_to_pass** (name indicative): a test proving a raw input column nested in a
HAVING aggregate argument is bound at plan time after the change. **Verify it
FAILS before the production change** — a vacuous test has already shipped once on
this umbrella and was only caught by review.

**pass_to_stay**:
```
schema_rich_full_order_flow_imbalance_demo_query_resolves
schema_rich_windowed_having_reports_a_real_case_argument_mismatch
```
The second proves the position is already consulted with the source schema
end-to-end. It must not regress.

## STOP conditions

1. The promotion cannot avoid stamping indices the chunked path reads (R1 not
   viable).
2. More than ~10 pre-existing tests fail — report the list before changing any.
3. The fix appears to need `find_slot_output_alias` or the window_v2 chunked path
   — that is #2026/#1747 territory.
4. You cannot make the fail_to_pass test fail before the change.
5. Amending §1c would require weakening the gate rather than describing it.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-1994/Cargo.toml \
  > /tmp/1994.log 2>&1
grep -E "^ *Summary" /tmp/1994.log
grep -E "^ *FAIL " /tmp/1994.log | awk '{print $NF}' | sort -u
```

Gate, from the worktree root:

```
(cd /Users/neilavery/RustroverProjects/velostream-1994 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards `git -C ... status` and commit any
reformatting. **`--fast` does NOT build `--release`** — also run
`cargo build --release --no-default-features --bin velo-sql`. A `debug_assert!`
body compiles in release and broke CI that way on #2019.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1749] #1994:` — not once at the end.
Do NOT push. Do NOT open a PR.

## Logging

`agent.log`, real `date -u +%FT%TZ` timestamps, heartbeat every ~10 minutes.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Clause order post-#1962:
`SELECT -> FROM -> JOIN -> WHERE -> WINDOW -> GROUP BY -> HAVING -> ORDER BY -> LIMIT`.
References: `docs/architecture/name-binding.md`, `docs/claude/SQL_GRAMMAR_RULES.md`,
`docs/sql/PARSER_GRAMMAR.md`, `src/velostream/sql/CLAUDE.md`.
**DO NOT GUESS SQL SYNTAX.**

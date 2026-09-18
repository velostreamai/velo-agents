# #2026 — Stage 1 READ-ONLY analysis: HAVING aggregate binds to the wrong slot

BRANCH: fix/2026-auto
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2026

Read `.agents/tasks/2026.json` IN FULL first; it is the contract. This brief adds
the operational detail it does not carry.

## Target and isolation

`velo-dispatch` has prepared the worktree and branch. Do NOT `cd` into the
worktree except for `gh` commands (gh has no `-C`). Use `git -C <worktree>`,
`cargo --manifest-path <worktree>/Cargo.toml`, and absolute paths with
Read/Edit/Write.

## What this task IS

Prove — or disprove — that a silent wrong column reaches OUTPUT, then present
fix options and stop.

`find_slot_output_alias` (operator.rs:1489) matches a HAVING aggregate call to
an accumulator slot. For a complex argument such as `CASE WHEN ... THEN ... END`
the HAVING side yields `arg_col = None` and the slot stores
`value_column = None` (`AggSlot`, plan/physical_strategy.rs:222), so the matcher's
`(None, None) => true` arm (operator.rs:1530) matches the FIRST same-kind slot.

One complex aggregate: correct. Two of the same kind:

```sql
HAVING SUM(CASE WHEN side = 'BUY'  THEN quantity END) > 0
   AND SUM(CASE WHEN side = 'SELL' THEN quantity END) > 0
```

both bind to the first `Sum` slot, so the second reads the first's column.

**Anchors: use `.agents/tasks/2026.json`'s `anchors` block, which was re-verified
during spec review. Two corrections matter:**

- `AggSlot.value_column` is `plan/physical_strategy.rs:222` (struct at :217).
  `operator.rs:1604` is a DIFFERENT field of the same name on
  `ChunkedExtractedConfig` — an earlier draft of this brief pointed there and
  was wrong.
- `plan/physical_dispatch_resolver/agg_args.rs` **EXISTS**, and the issue's
  `agg_args.rs:56-111` anchor is correct. An earlier draft said it was absent,
  having searched only `window_v2/`. **Read it** — it is the resolver that
  creates the `None` this whole defect rests on.

## What this task is NOT

It is not a fix. The fix direction is deliberately unpinned, and choosing
between options is the orchestrator's decision, not yours. If you find yourself
weighing option (a) against option (b) in order to implement one — STOP, that is
the signal you have left Stage 1.

It is also not a query-validation task. The SQL is valid and accepted; the
defect is which slot it binds to.

## Prior analysis that was WRONG — do not repeat it

#1994's analysis claimed the `Case` arg matches nothing, yields `None`,
evaluates to `Null`, and filters every group. The `/pr-gate` review of #2021
REFUTED that. The real hazard is a silent wrong COLUMN. Verify what actually
happens; do not inherit either reading.

## Validation commands

```
cargo --manifest-path <worktree>/Cargo.toml nextest run --no-default-features \
  --test mod -E 'test(/window_v2/)'
(cd <worktree> && ./run-commit.sh --fast)
```

`run-commit.sh --fast` runs `cargo fmt --all` as a WET APPLY. Anything it
rewrites must be committed, or CI's independent `cargo fmt --check` fails. Do
not re-run the gate to get different output — read the log path it prints.

## Success, including the RED outcome

"Reachability could not be demonstrated; here are the queries I tried and what
each produced; the issue should be closed as not-a-defect" is a SUCCESSFUL
Stage 1. So is "reachable, here is the exact wrong output, here are three
options with trade-offs, I recommend (b) and did not implement it."

A demonstration test that FAILS is the evidence. Do NOT commit it — paste its
source and exact output into the analysis document and revert the file.

## Committing

Commit incrementally as you go — do not leave everything to one final commit.
Only `.agents/tasks/2026-analysis.md` may be committed (see the spec's
`authorization`); the demonstration test must be reverted before you commit.

## SQL syntax

Velostream SQL is NOT Postgres, ksqlDB or Flink SQL. Before using any construct,
prove it is supported:

    docs/claude/SQL_GRAMMAR_RULES.md
    docs/sql/PARSER_GRAMMAR.md
    docs/sql/COPY_PASTE_EXAMPLES.md
    src/velostream/sql/CLAUDE.md

Reference idiom: `demo/trading/sql/ctas_file_trading.sql`. Check the parser and
grammar docs for any unfamiliar function — absent means unsupported. Do NOT
invent a construct to make a query parse. Write complete statements: select list
AND FROM clause, never a bare fragment.

## Reporting

`gh issue view 2026` first. Post a start comment and a completion comment.
Keep `agent.log` in the worktree root with real UTC timestamps
(`date -u +%FT%TZ`) and a `WHY:` line before each material step.

The final report must state what you VERIFIED versus what you ASSUMED, and must
contain the two named sections the spec requires: "Anchors re-verified" and
"Failure mode confirmed".

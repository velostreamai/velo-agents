# #1958 — widen the doc-SQL gate

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1958
BRANCH:   fix/1958-auto

Work ONLY in that worktree. Do NOT `cd` into it — use `git -C <worktree>` and
`cargo --manifest-path <worktree>/Cargo.toml`, and absolute paths for file edits.

## The problem

`tests/unit/sql/validation/doc_sql_examples_test.rs` gates exactly three files
via `ENFORCED_FILES`. Its own register `UNGATED_MD_SQL_BLOCK_COUNTS` records that
**1805 of 1988 ```sql fences under `docs/` are never parsed**, across 191 `.md`
files. #1956 hit the cost directly: of 131 sites needing migration, only 39 were
in gated files, so 92 across 40 files could not be changed verifiably.

## What to do

The work is mostly **classification**, not code. For each ungated `.md` file:

1. Decide whether each ```sql fence is **executable SQL** (something the parser
   should accept) or **prose that quotes SQL** (fragments, pseudo-SQL, error
   messages, `...` elisions, deliberately-invalid examples).
2. **Non-executable fences: retag ```sql -> ```text.** Cheap, safe, and it
   removes them from the inventory honestly rather than by exclusion.
3. **Executable residue: add its file to `ENFORCED_FILES`.** Each promotion will
   surface real breakage — that is the point. Fix the doc if the SQL is wrong;
   if the SQL is right and the PARSER is wrong, that is a finding: record it in
   `KNOWN_ENGINE_GAPS` with a one-line reason and move on. Do NOT change the
   parser.
4. Keep `UNGATED_MD_SQL_BLOCK_COUNTS` accurate as you go. It must keep failing in
   BOTH directions: a newly added ungated fence fails, and a stale entry fails.

Do NOT guess SQL syntax. The canonical references are
`docs/claude/SQL_GRAMMAR_RULES.md` and `docs/sql/PARSER_GRAMMAR.md`, plus
`src/velostream/sql/CLAUDE.md` for window/grammar footguns. If a construct is not
in those, treat the fence as non-executable and retag it rather than inventing a
form the parser might reject.

## Scope

Start with the 40 files #1956 named if you can identify them; otherwise work
alphabetically through `docs/`. **You do not have to finish all 191 files.** A
partial, correct, committed pass is the goal — say clearly in your report where
you stopped and what remains.

## Validation

    cargo nextest run --no-default-features --test mod doc_sql_examples
    cargo check --no-default-features

Both must pass before you finish. `fail_to_pass`:
`enforced_files_covers_every_executable_sql_doc`,
`ungated_block_register_matches_reality`.

## Authorization

You MAY commit. Commit after each batch of files — a wall-clock timeout will
otherwise lose everything. Do NOT push. Do NOT open a PR.

## Incremental commits — MANDATORY

Commit after each section you complete, prefixed `[#1970] #1958:`. Many small
commits are expected.

## STOP and report if

- a promotion to `ENFORCED_FILES` requires a parser change to pass
- the register cannot be made accurate without deleting a test
- you would need to swallow an error or narrow a test to go green
- `cargo check` fails for a reason your change did not cause

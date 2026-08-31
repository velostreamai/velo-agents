# #1934 — support single-line trailing comments after a statement terminator

PARENT ISSUE: #1749
ISSUE: #1934 (read it in full first — it carries the traps; this brief does not repeat all of them)

## Objective

`SELECT * FROM orders;  -- note` must split as ONE terminated statement. Today it does not, because the terminator check reads the raw line.

Owner ruling (2026-08-30): "we need to be able to support single line, trailing comments in the sql block".

## Line anchors (computed at dispatch — re-verify before editing; if a symbol moved, USE THE SYMBOL, not the number)

- `src/velostream/sql/app_parser.rs:548` — `if trimmed.ends_with(';')` — THE DEFECT
- `src/velostream/sql/app_parser.rs:552` — `let sql = current_statement.trim().trim_end_matches(';').to_string();`
- `src/velostream/sql/app_parser.rs:539` — comment explaining why ALL lines are kept (`-- @metric:` annotations)
- `src/velostream/sql/app_parser.rs:285` — `fn statement_has_sql`
- `src/velostream/sql/app_parser.rs:737` — `fn extract_dependencies_text_fallback`
- `tests/unit/sql/validation/doc_sql_examples_test.rs:1172` — `fn strip_inline_comment` (gate's naive, non-quote-aware version)
- `tests/unit/sql/validation/doc_sql_examples_test.rs:1253` — `fn find_unterminated_statement` (gate mirror)
- `docs/sql/COPY_PASTE_EXAMPLES.md:2848` — the doc example (line number is from master; after the #1929 merge this example has its comment moved ABOVE the statement — restore the trailing form, see step 5)

## The three traps — do not skip these, each one is a real regression

**TRAP 1 — do NOT strip comments from the statement text wholesale.** `app_parser.rs:539` keeps every line on purpose: `-- @metric:` annotations are comments the SQL parser consumes. A WHOLE-LINE comment is content and must be preserved. Only a TRAILING comment (real SQL before it on the same line) may be ignored for terminator detection.

**TRAP 2 — comment scanning MUST be quote-aware.** `app_parser.rs` has NO quote-state tracking today (`grep -nE "in_string|in_quote|quote_char"` → nothing). That is harmless only because the terminator asks whether a line ENDS with `;`, never whether it CONTAINS one — so `WHERE sep = 'a;b';` works today. Comment stripping TRUNCATES the line, which destroys that property:

```sql
SELECT * FROM t WHERE note = 'a -- b';
```

A naive split at the first `--` yields `SELECT * FROM t WHERE note = 'a`, no longer ends with `;`, statement never closes, silently swallows what follows. **This is a NEW regression the naive fix introduces on a line that works correctly today.**

Walk the line tracking single-quote state (`''` is the escape) and take the first `--` that occurs OUTSIDE a string.

**TRAP 3 — the extracted `sql` must still end at the `;`.** Line 552 does `trim_end_matches(';')`. With a trailing comment the statement no longer ends with `;`, so nothing is stripped and the `;` + comment ride into `sql`. `extract_dependencies_text_fallback` (`:737`) splits `sql` on whitespace and treats the word after any `FROM`/`JOIN` as a table dependency — so `-- also read FROM the archive` injects a phantom dependency named `the`, and dependencies drive job wiring order.

Strip the trailing comment from the TERMINATING line when building `sql`, leaving `;` last so `trim_end_matches(';')` behaves exactly as today for every statement that has no trailing comment.

## Grammar reference

A SQL line comment is `--` to end of line — see `docs/sql/PARSER_GRAMMAR.md` and
`docs/claude/SQL_GRAMMAR_RULES.md`. The ONLY exception is `--` inside a string
literal, which is not a comment. That exception is TRAP 2 below and is the whole
reason the scan must be quote-aware.

Do not invent SQL syntax. If a shape you need is not in those two documents,
STOP and report rather than guessing.

## Commit incrementally — a timeout must not lose the work

Commit after EACH numbered step below, on the branch named at the bottom. Two
prior runs lost everything to a timeout because they held all work uncommitted
until the end. A partial, committed series is recoverable; an uncommitted tree
is not.

Do NOT `git stash` — this repo's stash stack is SHARED across all worktrees and
currently holds 10 abandoned entries. A `git stash pop` here pops someone
else's work. That cost the #1928 worker its recovery time.

## Steps

1. Add a quote-aware "find start of trailing line comment" helper in `app_parser.rs`. Public enough that the gate test can use it (see step 4) — `tests/unit/` is an EXTERNAL binary, so `pub(crate)` is NOT reachable; it must be `pub`.
2. Use it at `:548` so a trailing comment does not prevent termination. Whole-line `--` lines must STILL not terminate (#1909 — there is an existing test, do not regress it).
3. Use it at `:552` so `sql` ends at the `;` with no comment attached.
4. Mirror in the gate: `find_unterminated_statement` (`doc_sql_examples_test.rs:1253`) and `strip_inline_comment` (`:1172`). `strip_inline_comment` is the naive version and says so in its own doc — replace its body with the quote-aware logic (import the engine helper; do not keep a weaker private copy). It is shared by three scans plus `statement_anchor` and `block_anchor`, so fixing it fixes all of them at once.
5. Restore the doc example to the trailing-comment form — it is the regression witness:
   ```sql
   -- ❌ WRONG - System columns are NOT included in SELECT *
   SELECT * FROM orders;  -- _timestamp, _partition, _key are excluded
   ```
   (#1929 moved that comment onto its own line to get the gate green under the old behaviour. Undo that.)
6. Update the `KNOWN_ENGINE_GAPS` doc note and the `statement_anchor` carve-out in the gate test, both of which currently name #1934 as the reason the constraint exists. Grep `1934` in that file and fix every mention.

## Acceptance

- `SELECT * FROM orders;  -- note` → ONE terminated statement, `sql` free of the comment
- `-- SELECT * FROM t;` (whole-line) still does NOT terminate — #1909 test stays green
- `SELECT * FROM t WHERE note = 'a -- b';` terminates as one statement (TRAP 2)
- a `-- @metric:` annotation line is still present in the statement text (TRAP 1)
- `extract_dependencies` yields NO phantom dependency from a comment containing `FROM`/`JOIN` (TRAP 3) — test it directly
- the doc-SQL gate accepts the restored example and `KNOWN_ENGINE_GAPS` does NOT grow
- `cargo nextest run --no-default-features -E 'test(doc_sql)'` fully green

## Tests to add (tests/unit/, registered in the parent mod.rs)

One test per bullet above. Each must be a MUTATION-KILL: break the code, confirm the test fails, restore, confirm it passes. Log each proof in `agent.log`.

## Authorization

- Commit: YES, on the branch below.
- Push: YES, after `./run-commit.sh --fast` passes clean.
- Open a PR: YES. Title prefix `[#1749]`. Link #1934.
- Merge: NO.

## Branch

`fix/1934-trailing-comments` — worktree at `~/RustroverProjects/velostream-1934`, cut from `origin/master` AFTER PR #1929 merges. Do NOT `cd` into it; use `git -C` and `--manifest-path`.

## STOP conditions specific to this task

- If the quote-aware scan turns out to need block-comment (`/* */`) handling to be correct, STOP and report — that is a scope expansion, not part of this.
- If more than 5 existing tests fail, STOP and report the list rather than fixing them one by one.

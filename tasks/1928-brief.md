# #1928 — parse_query must require end of input

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1928
BRANCH:   fix/1928-auto (already cut and checked out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## The defect

`parse_query` dispatches on the first token and returns the sub-parser's result
**without checking the input was consumed**. A sub-parser that reads a valid
PREFIX returns `Ok`, the remainder is silently discarded, and the caller gets a
well-formed AST for a query nobody wrote.

Three independent reproducers, one root cause: #1895's `WITHIN GROUP`, the
bare-alias counter-example, and a statement-merge found by #1929's gate.

This was blocked on #1959 and #1960 — **both shipped**, so it is unblocked.

## Prior work exists on `origin/wip/1928-step1` — evaluate it, do not trust it

Your worktree is cut fresh from `origin/master` and does NOT contain it. Read it
with:

```
git -C /Users/neilavery/RustroverProjects/velostream-1928 show origin/wip/1928-step1
```

Cherry-pick it if you judge it correct, or write your own — but say which, and
why. That commit adds the EOF check at `parser/mod.rs` (~30 lines): captures
`parser.current_token()` after `parse_query()`, and errors unless it is `Eof`
or `Semicolon`, via `SqlError::parse_error_with_context` with the token value,
position and source text.

Read it critically. Specifically check:
- Is `Semicolon` the right tolerance, and is the stated reason true — that the
  application splitter strips `;` via `trim_end_matches(';')` but direct
  callers may not? Verify both halves.
- Is the claim "comments and whitespace never reach this parser, the tokenizer
  separates them out beforehand" actually true? If a trailing comment token can
  arrive, this check rejects valid SQL.
- Is `current_token()` the right cursor after a successful parse, or can a
  sub-parser leave it un-advanced?

**It has NO tests and the full suite has never been run against it.** That is
your job, and the interesting part.

## Anchors — `grep -n` verified at dispatch time against `330412fcd`

```
src/velostream/sql/parser/common.rs   pub fn parse_query   (1)
src/velostream/sql/parser/mod.rs      parser.parse_query() (1)
src/velostream/sql/parser/mod.rs      Eof                  (1)
```

## The real work is the FALLOUT, not the check

`parse_query` has **54 references** across `src/`, `tests/` and `examples/`.
Every one currently accepts a valid prefix. Turning silent truncation into a
hard error will reject SQL the suite passes today — and each such failure is
information:

- **a genuine defect the check just surfaced** — the SQL was wrong and was
  being silently truncated. Fix the SQL, and cite what was being discarded.
- **a legitimate construct the parser does not support** — the SQL is fine and
  the parser is incomplete. That is a finding: report it; fix the parser only
  if it is small and obviously in scope.

**Triage every failure into one of those two. Do not weaken the check to make
tests pass** — a test that now fails is the check working.

## Tests — all three must be verified to FAIL first

```
parse_rejects_trailing_tokens_after_valid_statement
parse_rejects_bare_select_list_alias
parse_rejects_second_statement_without_terminator
```

None exists yet. Write each, run it against the branch with the STEP 1 commit
REVERTED, confirm it FAILS, restore. A test that passes either way proves
nothing, and a vacuous test has already shipped once on this umbrella.

## STOP conditions

1. **More than ~15 pre-existing tests fail** — STOP and report the list. That is
   a corpus-wide decision, not something to grind through.
2. **A shipped `demo/**.sql` or docs example relies on prefix-truncation** —
   STOP and report which, before changing any shipped SQL.
3. The fix appears to need changes inside individual sub-parsers rather than the
   one call site — STOP; that is wider than this spec pins.
4. You cannot make a named test fail before the change — report it rather than
   writing a vacuous test.
5. You would delete, `#[ignore]` or narrow any existing test.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-1928/Cargo.toml \
  > /tmp/1928.log 2>&1
grep -E "^ *Summary" /tmp/1928.log
grep -E "^ *FAIL " /tmp/1928.log | awk '{print $NF}' | sort -u
```

Then the gate, from the worktree root:

```
(cd /Users/neilavery/RustroverProjects/velostream-1928 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards run `git -C ... status` and commit
any reformatting. **`--fast` does NOT build `--release`**; if you touch anything
beyond comments, also run
`cargo build --release --no-default-features --bin velo-sql`. A `debug_assert!`
body compiles in release and broke CI that way on #2019.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1970] #1928:` — not once at the end.
A timeout must never lose completed work. Do NOT push. Do NOT open a PR.

## Logging

Append to `agent.log` with real `date -u +%FT%TZ` timestamps, including a
heartbeat every ~10 minutes. A previous dispatch went 38 minutes silent and was
killed as wedged.

## SQL syntax

Velostream SQL is **not** Postgres, ksqlDB or Flink SQL. Clause order post-#1962:
`SELECT -> FROM -> JOIN -> WHERE -> WINDOW -> GROUP BY -> HAVING -> ORDER BY -> LIMIT`.
References: `docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`,
`docs/sql/COPY_PASTE_EXAMPLES.md`, `src/velostream/sql/CLAUDE.md`.
Reference idiom: `demo/trading/sql/ctas_file_trading.sql`.
**DO NOT GUESS SQL SYNTAX** — grep the parser and grammar docs; absent means
unsupported.

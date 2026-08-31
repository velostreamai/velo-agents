# #1949 — plain SELECT drops WINDOW after HAVING

PARENT ISSUE: #1749
ISSUE: #1949 (read it in full first)

## Objective

```sql
SELECT s, COUNT(*) FROM t GROUP BY s HAVING COUNT(*) > 5 WINDOW TUMBLING(INTERVAL '5' MINUTE) ORDER BY s;
```

is the **documented** clause order and does not parse on the plain-SELECT path. The parser stops at `WINDOW` and (before #1928's end-of-input check) returned `Ok` with the window **and** the ordering silently discarded.

A streaming aggregate that silently loses its window is a wrong-results defect, not a syntax inconvenience. This is the fix, not a documented gap — do NOT add a `KNOWN_ENGINE_GAPS` entry.

## Root cause — two paths, opposite orders

There are **THREE** select-parsing paths, and **TWO** are broken:

| path | line | clause handling | affected |
|---|---|---|---|
| `parse_select` | ~340 | fixed `if` sequence: WINDOW → HAVING → ORDER BY | **YES** |
| `parse_select_no_with` | ~1120 | fixed `if` sequence, same order | **YES** |
| `parse_select_for_create_table` | ~834 | order-independent `match` loop | no — works |

Both broken paths accept `WINDOW` only **before** `HAVING`. Fix BOTH. (The dispatch gate caught that I had declared one site; a brief naming only `parse_select` would have fixed half the defect and left `parse_select_no_with` silently truncating.)

**The CREATE path** (`select.rs:834-856`) uses an order-independent `match` inside a `loop` with `if window.is_none()` guards, and accepts either order. Verified:

```
CREATE STREAM o AS SELECT ... GROUP BY s HAVING ... WINDOW ... WITH (...)   → Valid
bare SELECT      ... GROUP BY s HAVING ... WINDOW ...                       → TRUNCATES at WINDOW
```

## The codebase contradicts itself, and that is the real find

`src/velostream/sql/CLAUDE.md:46` — the authority:

> Clause order is fixed: `SELECT → FROM → WHERE → GROUP BY → HAVING → WINDOW → ORDER BY → LIMIT`.

`select.rs:357` — the plain path's own error message:

> `GROUP BY clause must come before WINDOW clause. Correct syntax: SELECT ... GROUP BY ... WINDOW ... HAVING ...`

**`WINDOW ... HAVING` vs `HAVING → WINDOW`.** Two statements of the canonical order inside one codebase, disagreeing. Fixing the parse without fixing that message leaves the next reader with the same contradiction.

## Pinned decision — do not re-litigate

Make the plain path **accept both orders**, matching the CREATE path.

- `CLAUDE.md:46` is the documented order and MUST parse. That is the bug.
- `WINDOW` before `HAVING` currently works and MUST keep working — existing SQL uses it, and breaking it trades one regression for another.
- Correct the `select.rs:357` message so it stops asserting the opposite order.

Whether clause order should ultimately be STRICT (as CLAUDE.md's "Out-of-order clauses fail parsing" implies) or FLEXIBLE (as the CREATE path already behaves) is an **owner decision and out of scope**. Do not tighten either path. If you believe the documented order itself is wrong, STOP and report — do not edit CLAUDE.md.

## Line anchors (computed at dispatch against 33e52add0 — re-verify; if a symbol moved, USE THE SYMBOL)

- `src/velostream/sql/parser/select.rs:340` — fixed sequence in `parse_select`
- `src/velostream/sql/parser/select.rs:1120` — fixed sequence in `parse_select_no_with` (SECOND site)
- `src/velostream/sql/parser/select.rs:357` — the self-contradicting error message
- `src/velostream/sql/parser/select.rs:834` — `// Loop to parse clauses in any order` (the shape to adopt)
- `src/velostream/sql/CLAUDE.md:46` — the documented order

## Grammar reference

`src/velostream/sql/CLAUDE.md`, `docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`.

`SQL_GRAMMAR_RULES.md:189` shows the order under a **"### Correct Order ✅"** heading. That block has never parsed on the plain path — it passes the #1925 doc gate only because the truncation is silent. After this fix it should parse genuinely.

Do not invent SQL syntax. If a shape you need is not in those documents, STOP.

## Steps

1. Replace the fixed `if` sequence in BOTH `parse_select` and `parse_select_no_with` with the same order-independent loop the CREATE path uses, preserving every existing guard (the `GROUP BY`-after-`WINDOW` rejection, `allowed_lateness` handling after a window, etc.).
2. Correct the `select.rs:357` message.
3. Add the four tests below.
4. Confirm `SQL_GRAMMAR_RULES.md:189` now parses, and that the doc gate's allowlist does NOT grow.

## Tests (tests/unit/, registered in the parent mod.rs)

- `plain_select_accepts_having_then_window`
- `plain_select_still_accepts_window_then_having` — regression guard for today's working order
- `plain_and_create_paths_agree_on_clause_order`
- `grammar_doc_correct_order_example_parses`

**Assert STRUCTURALLY: `window` and `order_by` must be PRESENT in the AST.** Never `is_ok()` — that is exactly what hid this, since the parser returned `Ok` having discarded both clauses.

Each a mutation-kill: break the code, confirm the test fails, restore, confirm it passes. Log each proof in `agent.log` with a REAL `date -u +%FT%TZ` timestamp.

## Validation commands

    cargo check --no-default-features --manifest-path ~/RustroverProjects/velostream-1949/Cargo.toml
    cargo nextest run --no-default-features -E 'test(window) or test(clause_order) or test(having)' --manifest-path ~/RustroverProjects/velostream-1949/Cargo.toml
    cargo nextest run --no-default-features -E 'test(doc_sql)' --manifest-path ~/RustroverProjects/velostream-1949/Cargo.toml
    cargo nextest run --no-default-features --no-fail-fast --lib --test mod --manifest-path ~/RustroverProjects/velostream-1949/Cargo.toml
    (cd ~/RustroverProjects/velostream-1949 && ./run-commit.sh --fast)

Do NOT run `cargo clippy` in the loop. Do NOT run bare `cargo nextest run` with no filter.

## Commit incrementally

Commit after each step. Two prior runs lost everything to a timeout. Do NOT `git stash` — the stash stack is shared across worktrees and holds 10 abandoned entries.

## Acceptance

- the documented order parses on the plain path, with window and ordering present in the AST
- `WINDOW` before `HAVING` still parses — unchanged
- both paths agree, asserted by a test
- `select.rs:357` no longer contradicts `CLAUDE.md:46`
- `SQL_GRAMMAR_RULES.md:189` parses without truncation; `KNOWN_ENGINE_GAPS` does not grow
- `./run-commit.sh --fast` clean

## Authorization

Commit: YES. Push: YES after `--fast`. PR: YES, `[#1749]` prefix, linking #1949, noting it unblocks part of #1928. Merge: NO.

## Branch

`fix/1949-auto` — worktree `~/RustroverProjects/velostream-1949`. Do NOT `cd` into it; use `git -C` and `--manifest-path`.

## STOP conditions

- more than 5 existing tests break → STOP, report the list
- the fix appears to need the CREATE path changed → STOP; it already works and is out of scope
- you conclude CLAUDE.md:46's order is wrong → STOP and report; that is an owner decision

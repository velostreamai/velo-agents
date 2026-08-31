# #1937 — reject CTAS/CSAS + INTO, which is invalid SQL that parses silently

PARENT ISSUE: #1749
ISSUE: #1937 (read it in full first — it carries the owner ruling and the rewrite table)

## Objective

```sql
CREATE STREAM enriched AS
SELECT ... FROM sensors
INTO enriched_sink
WITH (...);
```

declares **two sinks** — `enriched` from `CREATE STREAM`, and `enriched_sink` from `INTO`. Owner ruling (2026-08-30): this is invalid SQL, and because Velostream supports named sources and sinks through `WITH` properties, `INTO` here is redundant. The supported spelling is:

```sql
CREATE STREAM enriched_named_sink AS
SELECT ... FROM sensors_named_source
WITH (...);
```

**Do NOT wire the INTO sink.** There is nothing to wire. Reject the shape with a meaningful error, and fix the docs and grammar.

## Why this matters more than it looks

`parse_select_for_create_table` and `parse_select_no_with` do not handle `TokenType::Into`. The sub-parser stops there and — because `parse_query` has no end-of-input check (#1928) — returns `Ok` with everything from `INTO` onward **silently discarded**. The author gets a running job and no indication a clause they wrote was thrown away.

**#1928 is blocked on this.** Its end-of-input check surfaces 18 test failures and 14 are this construct. This is the critical path.

## Line anchors (computed at dispatch against 274a3a7cb — re-verify; if a symbol moved, USE THE SYMBOL, not the number)

- `src/velostream/sql/parser/select.rs:585` — `pub(super) fn parse_select_for_create_table` — create path, no `Into` arm
- `src/velostream/sql/parser/select.rs:864` — `pub(super) fn parse_select_no_with` — the other create path, same omission
- `src/velostream/sql/parser/select.rs:416` — `if self.current_token().token_type == TokenType::Into` — the ONLY place `INTO` is handled (plain `parse_select`, builds `InsertInto`). This is the contrast: supported on one path, silently dropped on two.
- `src/velostream/sql/parser/common.rs:409` — `pub fn parse_query` — why the drop is silent (#1928, separate issue)

## Grammar reference

`docs/sql/PARSER_GRAMMAR.md` and `docs/claude/SQL_GRAMMAR_RULES.md`. The supported form is `CREATE STREAM <sink> AS SELECT ... FROM <source> WITH ('<source>.type' = ..., '<sink>.type' = ...)`. Named source/sink properties are exactly what makes `INTO` redundant.

Do not invent SQL syntax. If a shape you need is not in those documents, STOP and report.

## Commit incrementally — a timeout must not lose the work

Commit after EACH numbered step. Two prior runs lost everything to a timeout by holding work uncommitted until the end.

Do NOT `git stash` — this repo's stash stack is SHARED across worktrees and holds 10 abandoned entries. A `git stash pop` here pops someone else's work; that cost the #1928 worker its recovery time.

## Steps

1. **Reject `INTO` in the CTAS/CSAS position** in `parse_select_for_create_table` and `parse_select_no_with`. The error must NAME the clause and say what to do instead — to the effect of:

   > `INTO` is not valid here: `CREATE STREAM <name> AS` already names the sink. Configure the sink with named properties in `WITH (...)` instead.

   A bare "unexpected token INTO" is NOT acceptable — the whole point is guidance.

2. **Do NOT touch the plain `SELECT ... INTO` path** at `:416`. That form currently parses and is plumbed end-to-end; whether it survives is an open owner decision on #1935 and is NOT in this scope. Add a regression test proving it still works.

3. **Rewrite the 8 shipped statements.** Each currently names two sinks; pick the intended one and express it in the named-sink form. The pairs, computed at dispatch:

   | File | INTO at line | `CREATE` sink | `INTO` sink |
   |---|---|---|---|
   | `examples/iot_monitoring_phase4.sql` | 205 | `sensor_anomaly_detection` | `sensor_anomaly_alerts` |
   | `examples/iot_monitoring_phase4.sql` | 374 | `comprehensive_device_health` | `critical_device_alerts` |
   | `examples/social_media_analytics_phase4.sql` | 190 | `viral_content_detection` | `viral_content_alerts` |
   | `examples/social_media_analytics_phase4.sql` | 307 | `hashtag_trending_analysis` | `trending_hashtags` |
   | `examples/ecommerce_analytics_phase4.sql` | 200 | `advanced_fraud_detection` | `fraud_alerts_advanced` |
   | `examples/ecommerce_analytics_phase4.sql` | 317 | `customer_behavior_analytics` | `customer_sessions_analytics` |
   | `examples/ecommerce_analytics_phase4.sql` | 429 | `product_recommendation_engine` | `product_recommendations` |
   | `examples/test_simple_validation.sql` | 30 | `test_stream` | `test_sink` |

   Read each statement's surrounding comments and its `WITH` block before choosing — the `WITH` properties often already name one of the two, which settles it. If a statement gives NO signal either way, STOP and report that one rather than guessing.

4. **Delete the admitting comments and their workarounds.** `examples/iot_monitoring_phase4.sql:52` and `examples/social_media_analytics_phase4.sql:63` both carry:
   `-- (CREATE STREAM x ... INTO y WITH (...) never wires the sink regardless of ...`
   Related notes exist at `examples/test_simple_validation.sql:8-18` and `examples/ecommerce_analytics_phase4.sql:236-242`. The behaviour was observed, written down next to the SQL, and worked around instead of fixed. Remove them along with whatever they were working around.

5. **Update the grammar docs** so `INTO` is not shown as valid in a CTAS/CSAS.

## Acceptance

- `CREATE STREAM x AS SELECT ... INTO y WITH (...)` fails to parse with an error naming `INTO` and pointing to named sink properties
- the same for `CREATE TABLE`
- plain `SELECT ... INTO x` still parses (regression guard — NOT in scope to remove)
- all 8 shipped statements rewritten and parsing; `examples/**/*.sql` all parse
- the admitting comments are gone
- grammar docs no longer show `INTO` in a CTAS/CSAS
- `./run-commit.sh --fast` clean

## Tests (tests/unit/, registered in the parent mod.rs)

One per acceptance bullet. Each a MUTATION-KILL: break the code, confirm the test fails, restore, confirm it passes. Log each proof in `agent.log` with a REAL `date -u +%FT%TZ` timestamp — the previous worker emitted fabricated timestamps (its last entry was stamped 66 minutes in the future), which makes the log useless as a trail. Do not do that.

## Validation commands — run these, in this order

Inner loop, per edit:

    cargo check --no-default-features --manifest-path ~/RustroverProjects/velostream-1937/Cargo.toml

Scoped test run for the parser change:

    cargo nextest run --no-default-features -E 'test(into)' --manifest-path ~/RustroverProjects/velostream-1937/Cargo.toml

Do the shipped .sql files still parse (this is the step-3 proof):

    cargo nextest run --no-default-features -E 'test(sql_files)' --manifest-path ~/RustroverProjects/velostream-1937/Cargo.toml

Multi-file sweep after the bulk rewrite:

    cargo nextest run --no-default-features --no-fail-fast --lib --test mod --manifest-path ~/RustroverProjects/velostream-1937/Cargo.toml

Final gate, ONCE, from the worktree root — read the log path it prints and grep
THAT for failures; never re-run it to get different output:

    (cd ~/RustroverProjects/velostream-1937 && ./run-commit.sh --fast)

Do NOT run `cargo clippy` in the edit loop, and do NOT run bare
`cargo nextest run --no-default-features` with no `--test` filter — that builds
every performance_* and integration_* binary for no added signal.

## Authorization

- Commit: YES, on the branch below.
- Push: YES, after `./run-commit.sh --fast` passes clean.
- Open a PR: YES. Title prefix `[#1749]`. Link #1937. Note in the body that this unblocks #1928.
- Merge: NO.

## Branch

`fix/1937-auto` — worktree at `~/RustroverProjects/velostream-1937`. Do NOT `cd` into it; use `git -C` and `--manifest-path`.

## STOP conditions

- A statement in step 3 gives no signal which sink is intended — STOP and report that statement.
- Rejecting `INTO` breaks more than 5 existing tests — STOP and report the list, do not fix them one at a time.
- The fix appears to need #1928's end-of-input check to land first — STOP and report; these are meant to be independently landable.

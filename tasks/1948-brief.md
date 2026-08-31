# #1948 — reject `START JOB ... AS CREATE ...`

PARENT ISSUE: #1749
ISSUE: #1948 (read it in full — it carries the owner ruling and the evidence)

## Objective

```sql
START JOB j AS CREATE STREAM out AS SELECT * FROM src WITH ('out.type' = 'kafka_sink', ...);
```

parses today, and **nothing honours the sink it declares**. Reject it at parse time.

## Why reject rather than wire — the ruling, with its reasoning

`query_analyzer.rs:633` is an empty arm:

```rust
StreamingQuery::StartJob { .. } => {
    // START JOB commands don't require consumers/producers during analysis
}
```

It never binds the inner query, never recurses, and never calls `detect_sinks_from_config` — which is called only from the `CreateStream` (:560) and `CreateTable` (:608) arms. So `required_sinks` is **always empty** for a job, and the server installs a `stdout_default` writer.

The consequence is that a job which DECLARES a sink is indistinguishable from one that declares none:

| | intended | actual |
|---|---|---|
| job declares no sink | stdout | stdout ✅ |
| job **declares** a sink | that sink | stdout ❌ |

**Owner ruling (2026-08-31): reject, do not wire.** The reasoning: zero shipped `.sql` files under `demo/` or `examples/` use `START JOB` at all, and deploying a `.sql` file already creates a job **per statement implicitly** (`stream_job_server.rs:2512-2527`), through the `CreateStream`/`CreateTable` path that IS analysed. Wiring would be engine work for a surface with no users.

**Do NOT fill in the empty `StartJob` arm.** That is the wiring option the owner declined.

## What stays exactly as it is

- The stdout fallback for a genuinely sinkless job — that is documented, intended behaviour (`datasource_config.rs:1034`, "No sinks specified for job, will use stdout as default"). Do not touch it.
- Plain `START JOB <name> AS SELECT ...` — still accepted. Whether it should be is an **open owner decision** recorded on the issue. If your change would alter it, STOP and report.

## Line anchors (computed at dispatch against c9b8b220d — re-verify; if a symbol moved, USE THE SYMBOL)

- `src/velostream/sql/parser/commands.rs:607` — `TokenType::Create => self.parse_create(),` inside **`parse_tokens_inner_no_with`**. **THE DEFECT**: this dispatch is what makes the nested form parse. **This is the one to remove.**

> ⚠ **That exact line appears TWICE.** `commands.rs:595` is the identical arm inside **`parse_tokens_inner`** — the TOP-LEVEL dispatch. Removing THAT one breaks every `CREATE` statement in the product. Confirm which function you are editing before you touch it; match on the enclosing `fn`, not on the line text. The dispatch gate caught the orchestrator declaring one occurrence when there are two.
- `src/velostream/sql/parser/commands.rs:603` — `fn parse_tokens_inner_no_with`, the job-context parser. Its existing error already says "Expected SELECT or CREATE statement in job definition" — that text must change too, since CREATE is no longer expected.
- `src/velostream/sql/query_analyzer.rs:633` — the empty arm. **Read it; do not fill it.**
- `tests/unit/sql/system/job_management_test.rs:67` — `test_start_job_create_stream`, the ONLY place in the repo asserting the nested form parses. It becomes a rejection test.

## Grammar reference

`docs/sql/PARSER_GRAMMAR.md`, `docs/claude/SQL_GRAMMAR_RULES.md`.

The supported sink-declaring form is a **top-level** CREATE. A Kafka sink needs **all three** properties:

```sql
CREATE STREAM <name> AS SELECT ... FROM <src>
WITH ('<name>.type' = 'kafka_sink',
      '<name>.bootstrap.servers' = 'localhost:9092',
      '<name>.topic' = 'output_topic')
```

Naming only `.type` validates as `Missing Sink Configs: <name>: bootstrap.servers, topic`. Do not invent syntax; if a shape you need is not in those documents, STOP.

## Steps

1. Remove the `TokenType::Create` arm from `parse_tokens_inner_no_with` so a nested CREATE is rejected, with an error that names the top-level form and says why — a job's SELECT cannot declare a sink.
2. Update that function's existing "Expected SELECT or CREATE" message, which will otherwise contradict the new behaviour.
3. Convert `test_start_job_create_stream` into a rejection test. Do NOT delete it.
4. Add the tests below.

## Tests (tests/unit/, registered in the parent mod.rs)

- `start_job_with_nested_create_is_rejected`
- `start_job_with_plain_select_still_parses` — regression guard; that form is out of scope
- `top_level_create_stream_still_parses` — regression guard

**The rejection message's guidance must be EXECUTED, not pattern-matched.** Copy the pattern from `into_rejection_guidance_actually_analyses` in `tests/unit/sql/parser/into_create_position_reject_test.rs`: lift the WITH clause out of the real error, substitute the placeholders, and run it through `StreamingSqlParser` and `QueryAnalyzer`.

This matters more than usual here: **`velo-cli validate` is BLIND on the job path** — it returns `Valid files: 1` for a nested job with a bogus key and for one with no WITH at all, because the analyzer never inspects it. Four review rounds on #1943 were lost to guidance "verified" that way. Do not use the validator as evidence for anything job-related.

Each test a mutation-kill: break the code, confirm it fails, restore, confirm it passes. Log each proof in `agent.log` with a REAL `date -u +%FT%TZ` timestamp.

## Validation commands

    cargo check --no-default-features --manifest-path ~/RustroverProjects/velostream-1948/Cargo.toml
    cargo nextest run --no-default-features -E 'test(job) or test(start_job)' --manifest-path ~/RustroverProjects/velostream-1948/Cargo.toml
    cargo nextest run --no-default-features --no-fail-fast --lib --test mod --manifest-path ~/RustroverProjects/velostream-1948/Cargo.toml
    (cd ~/RustroverProjects/velostream-1948 && ./run-commit.sh --fast)

Do NOT run `cargo clippy` in the loop. Do NOT run bare `cargo nextest run` with no filter.

## Commit incrementally

Commit after each step. Do NOT `git stash` — the stash stack is shared across worktrees and holds 10 abandoned entries.

## Acceptance

- `START JOB j AS CREATE STREAM ...` fails at parse time, with an error naming the top-level form
- the same for `DEPLOY JOB` if it shares the path
- plain `START JOB ... AS SELECT ...` still parses — unchanged
- top-level `CREATE STREAM` still parses — unchanged
- `job_management_test.rs:67` converted, not deleted
- the empty `StartJob` analyzer arm is UNCHANGED
- the sinkless-job stdout fallback is UNCHANGED
- `./run-commit.sh --fast` clean

## Authorization

Commit: YES. Push: YES after `--fast`. PR: YES, `[#1749]` prefix, linking #1948. Merge: NO.

## Branch

`fix/1948-auto` — worktree `~/RustroverProjects/velostream-1948`. Do NOT `cd` into it; use `git -C` and `--manifest-path`.

## STOP conditions

- more than 5 existing tests break → STOP, report the list
- you conclude the form should be WIRED instead → STOP; the owner ruled reject, reasoning is on the issue
- plain `START JOB ... AS SELECT` would need to change → STOP; separate open decision

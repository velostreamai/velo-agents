# #1946 — rewrite every doc example that still teaches CTAS + INTO

PARENT ISSUE: #1749
ISSUE: #1946 (read it in full — it carries the file list and the owner ruling)

## Objective

#1937 made `CREATE STREAM x AS SELECT ... INTO y ...` a hard **parse error**. Eight documents still present it as copy-pasteable SQL. A reader copying any of them now gets a deployment abort.

**Owner ruling (2026-08-31): rewrite every example as SINGLE-SINK.** `INTO` was never wired — it was silently discarded — so those examples have always written to exactly one sink. Nothing functional is lost. Do NOT preserve fan-out, and do NOT mark examples "unsupported".

## Grammar reference

`docs/sql/PARSER_GRAMMAR.md` and `docs/claude/SQL_GRAMMAR_RULES.md` define the
supported syntax. `docs/sql/COPY_PASTE_EXAMPLES.md:246` is the canonical worked
example of the named-source/named-sink form and is the shape to copy.

Do not invent SQL syntax. If a shape you need is not in those documents, STOP
and report rather than guessing.

## The two facts that make this non-mechanical

**1. A Kafka sink needs THREE properties, not one.**

```sql
'<name>.type'              = 'kafka_sink'
'<name>.bootstrap.servers' = 'localhost:9092'
'<name>.topic'             = 'output_topic'
```

Naming only `.type` validates as `❌ Missing Sink Configs: <name>: bootstrap.servers, topic`. The orchestrator got this wrong three times in #1943 before checking it. The engine's own error message (`query_analyzer.rs:585`) also prescribes only two of the three — **do not copy the engine's wording**.

**2. The property prefix must be the CREATE name.** `detect_sinks_from_config` keys on it, so `CREATE TABLE positions ... 'positions_sink.config_file'` resolves to nothing and is silently inert. Every prefix you write must match the name after `CREATE STREAM`/`CREATE TABLE` in that same statement.

## Line anchors (computed at dispatch against 33e52add0 — re-verify; if a count differs, USE WHAT YOU FIND)

Lines matching `^\s*INTO ` — 37 total across 8 files:

| File | count |
|---|---|
| `docs/data-sources/multi-source-sink-guide.md` | 17 |
| `docs/data-sources/streaming-sql-syntax-enhancement.md` | 7 |
| `docs/yaml-configuration-guide.md` | 6 |
| `docs/feature/fr-073-unified-observability.md` | 2 |
| `docs/feature/fr-057-self-registering-config-schema-system.md` | 2 |
| `docs/guides/schema-registry-quick-start.md` | 1 |
| `docs/guides/schema-references-guide.md` | 1 |
| `docs/developer/sql-validator-ast-integration-analysis.md` | 1 |

The fan-out examples (`INTO sink_a, sink_b, sink_c`) are in `multi-source-sink-guide.md`, `fr-057-...md:306,1418` and `sql-validator-ast-integration-analysis.md:136`.

## The fan-out cases need a judgement per example

`multi-source-sink-guide.md` is BUILT around multi-sink fan-out. For each such example, read the surrounding prose and pick the sink the example is actually about — usually the one the prose discusses, or the first. Then rewrite as a single named sink.

If an example's intent is genuinely ambiguous — the prose discusses all N sinks equally and no one of them is the subject — **STOP and report that example** rather than guessing. Do not delete the example.

## Steps

1. Rewrite the 37 statements to the named-sink form, one file at a time, committing per file.
2. For every rewritten block, add all three sink properties AND the matching source properties.
3. Fix the surrounding prose where it describes fan-out that no longer exists. A rewritten example under prose still promising three sinks is worse than the original.
4. `multi-source-sink-guide.md` will need its framing revisited — a guide whose subject is multi-sink cannot keep that subject. Report what you did to it in the PR body.

## Validation — this is the gate, and it is not optional

For EVERY rewritten `sql` block:

    ./target/debug/velo-cli validate <file-containing-just-that-block>.sql

and require `Valid files: 1`.

Extract blocks **per fenced ```` ```sql ```` block** — do not use a greedy regex across fences; that produced a false result during #1943 and cost a round.

Reading a block is not verification. Every one of the orchestrator's three mistakes in #1943 survived reading and died immediately on execution.

Build the binary first if absent: `cargo build --bin velo-cli --no-default-features`.

## Validation commands — run these, in this order

Build the validator once if absent:

    cargo build --bin velo-cli --no-default-features --manifest-path ~/RustroverProjects/velostream-1946/Cargo.toml

Per rewritten block (extract per fenced ```sql block, write to a temp .sql, then):

    ~/RustroverProjects/velostream-1946/target/debug/velo-cli validate <tmp>.sql

Require `Valid files: 1`. Anything else is a STOP.

Docs-only change, so no test suites apply — but run the doc-SQL gate to be sure
nothing in the enforced corpus regressed:

    cargo nextest run --no-default-features -E 'test(doc_sql)' --manifest-path ~/RustroverProjects/velostream-1946/Cargo.toml

Final gate, ONCE, from the worktree root — read the log path it prints and grep
THAT; never re-run it for different output:

    (cd ~/RustroverProjects/velostream-1946 && ./run-commit.sh --fast)

Do NOT run `cargo clippy` in the loop, and do NOT run bare `cargo nextest run`
with no `--test`/`-E` filter.

## Commit incrementally — a timeout must not lose the work

Commit after EACH file. Two prior runs lost everything to a timeout by holding work uncommitted.

Do NOT `git stash` — the stash stack is SHARED across worktrees and holds 10 abandoned entries; a pop takes someone else's work.

## Acceptance

- zero lines matching `^\s*INTO ` remain in the 8 files
- every rewritten block validates `Valid files: 1`
- every sink prefix matches its statement's CREATE name
- every sink names all three properties
- prose no longer describes fan-out that the examples no longer show
- `./run-commit.sh --fast` clean

## Authorization

- Commit: YES. Push: YES, after `--fast` passes. Open a PR: YES, title prefixed `[#1749]`, linking #1946. Merge: NO.

## Branch

`fix/1946-auto` — worktree at `~/RustroverProjects/velostream-1946`. Do NOT `cd` into it; use `git -C` and `--manifest-path`.

## STOP conditions

- a fan-out example's intent is genuinely ambiguous → STOP, report that example
- a rewritten block will not validate after adding all three properties → STOP and report; never weaken an example to make it pass
- more than 8 files need touching → STOP; the scope was measured

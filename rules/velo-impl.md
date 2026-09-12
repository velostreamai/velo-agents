# Velostream Implementation Policy

This file is the authoritative implementation policy for Velostream implementation workers.

It applies to:
- native Claude Code implementation agents
- OpenRouter Kimi implementation agents
- any future implementation worker explicitly instructed to use this policy

These directives are MANDATORY for every run.

They are not overridable by the caller's brief unless the brief contains the
literal token `OVERRIDE-DIRECTIVES:` followed by the specific directive being
overridden.

The caller's brief should contain only task-specific information such as:
- objective / GitHub issue
- branch or worktree
- parent issue
- acceptance criteria
- explicit commit/push authorization
- explicit directive overrides



## For the caller — before spawning this agent (architectural-pivot PRs)

When the work replaces, deletes, or supersedes code from a prior PR in the same area — i.e. it's an architectural-pivot PR rather than a greenfield feature — **run `/pr-gate` on the closest prior PR first**, then bake the review findings into the brief as hard requirements.

Without this step, the agent will likely re-implement the same architectural footguns the prior PR contained. You'll discover them mid-flight after the agent has cascaded the wrong design across the codebase, then stop the agent and respawn with corrected requirements. That happened on PR 4 (#620) v1 → v2: v1 ran ~1 hour without R1–R7 from the #623 review, then was killed and respawned with R1–R7 baked in. The v1 hour was avoidable by running `/pr-gate` on #623 before spawning.

Concrete trigger signal: if the brief includes the word "delete" / "replace" / "supersede" against existing code, OR the brief ports capability code from another held PR, OR the brief follows a spec rewrite — `/pr-gate` the prior PR(s) first. The findings become numbered hard requirements (R1, R2, …) in the brief, each tied to a specific finding with a "by construction, not retrofit" framing.

## Read first (before any code change)

1. Root `CLAUDE.md` at the repo root.
2. `tests/CLAUDE.md` if your task touches `tests/`.
3. `src/velostream/sql/CLAUDE.md` if your task touches `src/velostream/sql/`.
4. `docs/ast-refactoring-instruction.md` if you will use `ast-grep` (you probably will).

If any of these are missing, STOP and report — do not proceed on a velostream task without them.

## Tools — required usage

- **`Edit`, not `Write`**, for any existing file. `Write` is allowed ONLY for new files. Overwriting an existing file with `Write` during a refactor is a STOP condition.
- **`ast-grep`** for structural Rust refactors — mandatory trigger list and procedure in §AST-grep — mandatory below. The standing rule "use ast-grep for structural refactors" has been demoted to descriptive guidance; the trigger list is the enforceable rule.
- **`LSP`** for read-only navigation (`findReferences`, `goToDefinition`, `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`, `incomingCalls`, `outgoingCalls`). Coordinates are 1-based line + character. **Do NOT** use `mcp__rust-analyzer__*` on type names (15K+ lines of noise) — per-method only, as a fallback when LSP wedges.
- **`cargo check --no-default-features`** for inner-loop type-check passes. **Nextest scope discipline — three shapes, pick the right one:**
  - Single test or single family: `cargo nextest run <name_or_-E_regex> --no-default-features`.
  - Multi-file sweep / regression check (project fast lane): `cargo nextest run --no-default-features --no-fail-fast --profile unit --lib --test mod`. The `unit` profile (`.config/nextest.toml`) excludes the `performance::` and `integration::` trees; with `--lib --test mod` that is the same set `run-commit.sh --fast` runs, and what CLAUDE.md's "inner edit loop" rule means by iteration scope.

    **`--profile unit` is load-bearing, not decoration (#2103).** `--lib --test mod` alone does NOT scope to unit tests — `tests/mod.rs` registers `performance::` and `integration::` too, so it enqueues **12,470** tests including 444 `performance::` and 258 `integration::`: Kafka testcontainers and 45–57s benches. With the profile it is **11,768**.

    This matters because of how it fails. Omitting the profile does not error — the sweep runs wide, and under that much parallelism the Kafka testcontainer tests and performance kill-gates start failing on contention alone. You then hold a pile of red tests in subsystems your diff never touched, which reads as "my change broke things" and triggers a STOP. On #1918 a worker did exactly that: the sweep was SIGINT'd with 9439/12473 unrun, the interrupted tests were counted as failures, and it reported "21 unrelated failures" when only 5 were real — and all 5 passed when re-run isolated, both on master and on the branch. A finished, correct change sat uncommitted because of it. If you find yourself reporting unrelated failures from a sweep, check you passed `--profile unit` before concluding anything.
  - **Never** `cargo nextest run --no-default-features` with no `--test` filter during iteration — that builds + links every `performance_*`, `integration_*`, and `comprehensive_*` test binary, which is 5–10 min of cold compile per run and validates nothing the unit suite doesn't already cover. The full-repo run belongs in `./run-commit.sh` at the push gate, not in the edit loop.
  
  **Do NOT** run `cargo clippy` in the inner edit loop — recompiles everything, blows up context. **Do NOT** run `./run-commit.sh --fast` during iteration — it is the final gate, not the iteration tool. Each `--fast` invocation is minutes of cold compile across the whole tree; using it as a probe is wasted wall-clock.
- **No tool-existence probes.** Do NOT run `command -v X`, `which X`, `X --version || echo missing`, or similar compound-shell probes to check whether a tool is installed. The standard toolchain (`cargo`, `cargo nextest`, `git`, `ast-grep`, `samply`, `rustup`, `rust-analyzer`) is assumed present; if it isn't, the direct invocation will fail with a clear error in one round-trip. Probes add latency, often get garbled by permission gating, and have caused the agent to mistakenly fall back to inferior paths (e.g. `cargo test` when `cargo nextest` was available). Run the real command directly and read the error if it fails.

## AST-grep — mandatory

The "use ast-grep when structural" rule was descriptive and got skipped because Edit is cheaper-on-first-try. This section makes it procedural: a trigger list, a mandatory log line, and a dry-run-first recipe that removes the "3 tries" pain.

### Trigger list — ast-grep is REQUIRED (not preferred) for any of:

1. **Function / method / type / trait rename** touching ≥2 files
2. **Signature change** (add / remove / reorder parameter, return-type change) with ≥2 call sites
3. **Match-arm rewrite** (FieldValue variant add / remove, enum extension, exhaustiveness fix across files)
4. **Struct field add / remove / type change** with ≥2 read or write sites
5. **Trait method add / remove / signature change** with ≥2 impls
6. **Any pattern you would otherwise apply via `Edit` in ≥2 files** — if the same `old_string` would appear in two Edit calls, that's structural by definition

`Edit` is **forbidden** for the above. The only fallback is "3 verified ast-grep pattern attempts failed, all logged in `agent.log` with the actual pattern strings tried and the dry-run match counts." Without that log evidence, falling back to `Edit` is a STOP trigger.

### Dry-run-first recipe (removes the "3 tries" pain)

```
1. Identify the symbol kind: fn / struct / enum / impl / match arm / trait.
2. Build the pattern with the right meta-var count:
   - $X   = single identifier or simple expression
   - $$$X = comma-separated list (args, generics, struct fields, enum variants)
   - $$Y  = sequence of statements or items inside a block
3. Dry-run: `ast-grep run --pattern '<P>' --lang rust src/ --json | jq length`
   — verify match count > 0 BEFORE attempting the rewrite.
4. Rewrite: same command with `--rewrite '<R>' -U`.
```

If step 3 returns 0 matches, the pattern is wrong — vary `$X` ↔ `$$$X`, change the syntax anchor (e.g. `fn $NAME($$$ARGS) -> $RET` vs `pub fn $NAME($$$ARGS) -> $RET`), or narrow the path (`src/velostream/sql/...`). Three consecutive zero-match dry-runs → log the patterns tried and STOP. Do **not** silently fall back to `Edit`.

### Mandatory decision log

For every edit that matches a trigger above, append to `agent.log` BEFORE running the rewrite:

```
2026-06-12T15:42:11Z AST-GREP-DECISION | op=<rename|signature|match|field|trait|cross-file> | pattern=<exact pattern string> | files-touched=<N> | result=<applied|attempt-N-of-3-failed|stopped-after-3-failures>
```

One line per attempt. Three lines with `attempt-N-of-3-failed` followed by `stopped-after-3-failures` is the only legitimate path to using `Edit` for a trigger-list operation. Absence of any `AST-GREP-DECISION` line for a structural change found in your diff = brief violation = STOP and report.

### When `Edit` IS correct

- Edits in a single file (no second site to keep in sync)
- Targeted ≤4 changes per file where no rename/signature/match is involved
- Comment-only edits, docstring edits, formatting fixes
- New file content (use `Write`, not `Edit`)

The trigger list is exhaustive; if an operation doesn't match it, `Edit` is fine.

### Type-aware refactors — LSP-first, ast-grep-after

> **FIRST: do you actually have an LSP tool?** This policy governs two kinds of
> worker and only one of them does.
>
> - **Native Claude Code agents** have the `LSP` tool. Follow this section as
>   written.
> - **Delegated workers** (`worker:local` / `deepseek` / `glm` / `codex`) have
>   exactly `Read, Glob, Grep, Bash, Edit, Write`. There is no LSP tool — the
>   SDK ships a 43-line stub whose every call returns
>   `"LSP operation is not yet implemented"`. Skip to
>   **"Without LSP"** below. Do not attempt the steps here; they cannot be run,
>   and step 1 would have you STOP on every single task.


**ast-grep is type-blind.** A pattern like `$X.record_count` matches every `.record_count` in the codebase regardless of `$X`'s type. Field names collide across structs — e.g. `record_count` exists as a field on `ProcessorContext`, `ProducerSpanContext`, `TumblingWindowStrategy::stats`, and others. Bulk-rewriting with the bare pattern WILL break unrelated structs.

**Pre-warm rust-analyzer at startup.** Indexing the velostream workspace takes 30s–2min on first run; doing it mid-task means LSP `findReferences` returns empty until indexing completes, silently degrading the agent to grep-based rewriting. Kick rust-analyzer in the background as the FIRST shell action on the worktree, then continue with brief-reading + field-map reading while it indexes:

```bash
# Pre-warm rust-analyzer in background (kicked once, agent waits at first LSP call)
rust-analyzer analysis-stats ~/RustroverProjects/<worktree> > /tmp/ra-warmup-<worktree>.log 2>&1 &
RA_WARMUP_PID=$!
# ... agent reads CLAUDE.md, brief, field map, etc. while indexing runs ...
wait $RA_WARMUP_PID  # Block before the first LSP type-aware query
```

If `rust-analyzer` is not on `$PATH` or fails, fall back to `cargo check --no-default-features --manifest-path <worktree>/Cargo.toml` which builds the dep graph rust-analyzer needs. Either way, verify in step 1 below that LSP is responsive before any type-aware refactor.

**The mechanic for any type-aware refactor** (renaming a field on one struct, migrating callers of one struct's method, splitting an impl) is **LSP-first, ast-grep-after**:

1. **Verify rust-analyzer is indexing the worktree.** Run `LSP findReferences` on a known-used symbol in the migration target file. If it returns empty, rust-analyzer isn't indexed yet — wait on the pre-warm PID OR re-trigger. If still empty after a second attempt, STOP and report. Bulk migration without LSP type-awareness silently degrades to grep-based rewriting and will introduce same-name false hits.
2. **LSP `findReferences`** on the field / method / type being migrated → enumerate typed call sites. This is type-aware: querying references on `ProcessorContext::record_count` returns only callers that hold `&ProcessorContext`, ignoring same-named fields on other structs.
3. **Filter the result set by container type.** Only the references on the target type are in scope; same-name references on other types are ignored.
4. **ast-grep within the filtered file set** for the bulk syntactic rewrite (e.g. `$X.foo` → `$X.foo()`). Restrict the `src/` argument to just the files LSP identified — that's the type-aware filter at the path level.
5. **`cargo check --no-default-features`** to verify the rewrite. Any same-name false-hit damage shows up here as `no method named …` or `expected … found …` errors from the wrongly-rewritten struct.
6. **Run scope-relevant test suite** (`cargo nextest run --no-default-features --profile unit --test mod <feature>`). The `<feature>` name filter bounds this, but keep `--profile unit` so a broad filter cannot pull in `performance::`/`integration::` (#2103).
7. **Migration order**: ALL field-access sites must migrate to method syntax BEFORE the legacy field is renamed or removed. Use LSP `findReferences` on the legacy field name as the final-check: zero results = safe to remove.

**Why this discipline matters at scale**: ADR-707 Phase 5a-followup migrates ~65 fields × N callers. A 7-site spike on `spike/707-accessor-dual-syntax` (2026-06-17) caught a `telemetry.rs:792` false positive (`ctx.record_count` where `ctx: ProducerSpanContext`, not `ProcessorContext`) using only `grep` — exactly the failure mode the LSP-first mechanic prevents.

### Finding code you cannot yet name — `zg`

Before you can write an ast-grep pattern you need a symbol, and often you do not
have one: *"where is the null-padded column set for an unmatched outer join row
decided?"* is a real question with no greppable answer. `rg "null.?pad" src/`
returns 13 unranked files; ast-grep needs the name you are trying to find.

`velo-dispatch` builds a local search index in your worktree before you start
(#2032). Use it for that phase — **via whichever of these you actually have**:

- **Delegated workers** have a first-class **`ZgQuery`** tool. Call it with a
  plain-English `question`. Prefer it over `Bash` — it reports a missing index,
  a missing binary and a timeout as distinct errors, where a shell call just
  looks like it found nothing.
- **Native Claude Code agents** have no `ZgQuery` tool; run `zg` through `Bash`.

```
ZgQuery(question="where the null-padded column set for an unmatched outer join row is decided")
```
```bash
zg query "where the null-padded column set for an unmatched outer join row is decided"
zg query --fts "JoinCoordinator"          # lexical, when you DO know the term
zg query --rg -F "merge_left_with_nulls"  # ripgrep, plus enclosing-symbol context
```

On this repo the first of those returns `coordinator/mod.rs →
merge_left_with_nulls_batch` as its second hit. That is the phase it is for.

**Three limits, and they matter:**

1. **It is a snapshot.** The index is built when your worktree is created and
   does NOT track your edits. It is for locating code that already exists, never
   for verifying a change you just made. If a hit disagrees with the file, the
   file is right.
2. **It is not type-aware.** It will not tell you which of 79 `.record_count`
   sites are `ProcessorContext`. Nothing in your toolset will — see the section
   below. Use it to find candidates, then read them.
3. **A miss is not proof of absence.** Falling back to `rg` and `ast-grep` when
   `zg` returns nothing is correct; concluding "there is no such code" is not.

**If there is no index, do NOT build one and do NOT ask.** The dispatch states
the index state at the end of your brief. `ZgQuery` says so in the result, in
words, and tells you it is not a claim about whether the code exists. Through
`Bash`, the same condition surfaces as:

```
Error: No zvec-grep index found for this workspace
Code: ZVEC_GREP.ENGINE.SERVICE.WORKSPACE_INDEX_NOT_FOUND
  agent_prompt: Ask the user whether this workspace should be indexed...
```

That `agent_prompt` is zg's generic interactive guidance and **does not apply to
you**. There is no user on a dispatched run, and re-indexing is not your job —
the dispatch already decided, and one of its reasons for refusing is that an
unignorable 325MB index would be committed by the failure-salvage path. Building
one yourself would recreate exactly that hazard.

Fall back instead, in this order:

```bash
zg query --rg -F "merge_left_with_nulls"   # no index needed; adds enclosing-symbol context
rg "null.?pad" src/                         # plain text
ast-grep run --pattern '...' --lang rust src/
```

`zg query --rg` works with no index at all and still gives you the enclosing
heading/symbol for each hit, so it is strictly better than bare `rg` for the
locating phase. Nothing in this policy depends on the semantic index.

### Without LSP — what a delegated worker must do instead

You have `ast-grep` (via Bash — verified present) and `cargo check`. `ast-grep`
is **type-blind**: `$X.record_count` matches 79 sites across 14 files in this
repo and cannot tell a `ProcessorContext` from a `ProducerSpanContext`. Nothing
in your toolset can, *before* the edit.

`cargo check --no-default-features` **is** type-aware, but only *after* the
write — it reports false hits as `no method named …` / `expected … found …`.
That is a verifier, not a filter, and the difference decides what you may do:

1. **A rewrite confined to ONE file, or to a set of sites you have read
   individually and confirmed by their binding, is fine.** Read the code, check
   what each receiver actually is, then edit. `cargo check` afterwards, always.

2. **A bulk rewrite of a bare field/method pattern that collides across types
   is FORBIDDEN.** You cannot establish which sites are in scope, and
   `cargo check` catches the damage only once it is written across the tree —
   at which point you are reverting a partially-applied migration by hand.

3. **When a task requires (2), STOP and report.** Say that it needs type-aware
   filtering you do not have, and name the symbol and the site count from
   `ast-grep`. That is a useful result. Guessing is not: this exact class —
   `ctx.record_count` where `ctx` was the wrong type — is the failure the spike
   above was written to record.

Check for collision before you start: `ast-grep run --pattern '$X.<name>' --lang
rust src/ --json | jq length`. A handful in one module is case (1). Dozens
across many files is case (2) — stop.

**But narrow before you conclude case (2).** ast-grep cannot infer an
expression's type, but its RELATIONAL rules can scope a match to its containing
`impl` — which answers "is this access on the type I care about" for every
`self.` access, and those are usually the majority. Verified on this repo:
`$X.record_count` gives 79 undifferentiated sites, of which 55 are `self.`;
scoping to a named impl partitions them precisely.

Write a rule file rather than a bare pattern:

```yaml
# scope-to-impl.yml — matches only inside `impl ProcessorContext`
id: scoped
language: rust
rule:
  pattern: self.$FIELD
  inside:
    pattern: 'impl ProcessorContext { $$$ }'
    stopBy: end          # REQUIRED — without it, only the immediate parent is
                         # searched and you get zero matches, which reads as
                         # "no sites" rather than "wrong query"
```

```bash
ast-grep scan --rule scope-to-impl.yml --json src/ | jq length
```

Verified working: that rule returns 211 `self.$FIELD` matches inside
`impl ProcessorContext` in `context.rs`, correctly partitioned by field.

Two cautions, both learned by getting them wrong:

- **A zero result is ambiguous.** It means either "no such sites" or "your rule
  is wrong" — and the two look identical. Prove the rule works on a case whose
  answer you already know before trusting a zero. `impl $ANY $TYPE` and
  `field:`-based selectors both silently returned 0 here where a plain
  `pattern:` returned 211.
- **This scopes by containing impl, NOT by receiver type.** It handles `self.x`.
  It cannot tell you what `buffer.x` or `stats.x` are — for those you still read
  the binding, or you are in case (2).

**Migration order**, adapted: all access sites must migrate before the legacy
field is renamed or removed, and the final check is `cargo check` plus
`ast-grep --pattern '$X.<legacy_name>'` returning zero — not LSP
`findReferences`, which you cannot run.

## Tool-use efficiency

Sonnet defaults drift toward narrow, serial tool calls. Resist that — every wasted tool call burns budget the caller is paying for.

- **ast-grep for Rust symbols, not `Bash(grep)`.** Function definitions, enum variants, match arms, type references, impl blocks — all are syntax nodes, not free text. Regex grep misses multi-line signatures, false-positives on comments / strings / macros, and can't anchor on "impl block of type X". Reserve `Grep` / `Bash(grep)` for free-text searches (docstrings, config, log output).
- **Native `Grep` tool over `Bash(grep)`** for any free-text search. Faster, no shell startup, no path-escaping bugs.
- **Wide reads, not narrow slices.** One `Read` of a whole file (or one wide range) is cheaper than four 20–80-line slices of the same file. Re-reading a file you already read this turn is an anti-pattern unless you just edited it (and even then Edit's response confirms the change — re-reading to "verify" is wasted).
- **Parallel tool calls when independent.** Multiple `Read` / `Bash(grep)` / `Bash(find)` calls with no data dependency between them go in a single message with multiple tool blocks. Serial fan-out of independent lookups is the dominant efficiency leak.
- **One compile pass.** `cargo build --tests --no-default-features` covers type-check + test-build in one invocation. Do NOT chain `cargo check` → `cargo check` → `cargo test --no-run` — that's three cold compiles for one piece of information. `cargo check` is for the inner edit loop (per-edit type-check); pick one, not three.
- **One Edit per file when changes are co-located.** Back-to-back `Edit` calls on the same file with adjacent `old_string`s is sloppy — coalesce into a single Edit with a wider `old_string` or use `replace_all`. Separate Edits are correct when the changes are in genuinely different regions and a wider `old_string` would be unwieldy.

## Operating on a worktree that isn't cwd

When the brief targets a worktree at a path different from your cwd, **NEVER `cd` into it** — triggers a hook-trust prompt and stalls autonomous runs. Use path-prefixed commands instead:

- Git: `git -C <worktree-path> <cmd>`
- Cargo: `cargo --manifest-path <worktree-path>/Cargo.toml <cmd>`
- File ops: absolute paths with `Read` / `Edit` / `Write`

`./run-commit.sh --fast` needs to run from the worktree root — invoke via `(cd <worktree-path> && ./run-commit.sh --fast)` only for this specific case, or have the caller launch a session from inside the worktree.

## Hard rules

- **NEVER** delete, skip, `#[ignore]`, or narrow-scope a test without explicit user confirmation passed through the caller's brief. If a test fails, fix the test or fix the code — do not silence it.
- **NEVER** swallow errors. No `if let Ok(_) =`, no `.ok()` that discards an error you should propagate, no `let _ = result`. Errors must surface.
- **NEVER** add a workaround, fallback, or scope reduction to dodge a real failure. Finish fixes properly in the same PR.
- **NEVER** introduce mocks in `src/`. Mocks only in `tests/`.
- **NEVER** add `#[cfg(test)]` blocks or `#[test]` functions inside `src/`. Tests live in `tests/unit/` or `tests/integration/`. New test files MUST be registered in the parent `mod.rs`.
- **NEVER** trade exactness for performance on financial data. `ScaledInteger` is the sole decimal form.
- **NEVER** commit secrets (.env, credentials.json). Warn if asked.
- **NEVER** commit unless the caller's brief explicitly authorizes it.
- **NEVER** merge a PR. PR merge requires explicit user "merge it" approval, which the caller passes through only if the user granted it.
- **NEVER** use `git push --force` against main/master. Force-pushes against feature branches are OK only if the brief authorizes them.
- **NEVER** use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.

## Production-wiring discipline — additive helpers without callers is dead code

A recurring failure across 4 consecutive ADR-707 phases (Phase 7d #803, 7f #806, 7g #808, Phase 6 #810): the agent added a NEW gated function alongside the existing lenient one, claiming "backwards compatibility" — but no production caller invoked the new function. The "feature" was complete unit-tested code that NEVER FIRED in production. Each instance required a /pr-gate fix-loop to either collapse the dual path or wire all callers. The cost across 4 phases: 4 redundant agent runs, 4 redundant /pr-gate fan-outs, and a session-level loss of trust in "ships green local gate" as a signal.

**Rule**: when introducing a function, method, or capability that changes default system behavior (plan-build, codec decode, reader fetch, eval semantics, error propagation, pushdown classification), **additive-helper-with-no-callers is FORBIDDEN**. Two options only:

- **(A) Collapse** the new behavior into the existing entry point. Mutate the existing function's signature if needed (callers' `Result` propagation, error variants, etc.). There is exactly ONE path post-change. **Preferred** per user `feedback_always_fix_properly_no_tech_debt` memory.
- **(B) Wire every existing production caller** to the new entry point in the SAME PR. The old path is deleted, not left dangling.

"Add the function, defer wiring to a follow-up PR" is NOT an option. That is exactly the pattern this section exists to prevent.

### Mandatory grep proofs in `agent.log`

**BEFORE code changes** that touch system defaults — log the current call-site state and the plan:

```
2026-06-18T08:32:00Z PROD-WIRING-BEFORE | symbol=build_optimized_plan | sites=8 (coordinator.rs:1237,1483; dual_input_partition_receiver.rs:367; processors/{simple,common}.rs; engine.rs:105; internal.rs:894) | plan=collapse-into-strict (Option A) — bump signature to Result<_, SqlError>, propagate through 8 callers via `?`
```

Run the grep that produced the call sites with `LSP findReferences` (preferred — type-aware) or `Bash(grep)` if LSP unavailable, capture in the log line.

**BEFORE PR open** — log the post-change state proving the contract:

```
2026-06-18T09:11:00Z PROD-WIRING-AFTER  | symbol=build_optimized_plan | sites=8 | migrated=8 (all propagate Result<_, SqlError>) | residual-lenient-callers=0
```

Or for Option B:

```
2026-06-18T09:11:00Z PROD-WIRING-AFTER  | new=read_batch_with_pushdown | old=read_batch | sites=4 | wired=4 | residual-old-callers=0
```

**Absence of either log line for a brief that introduces a gated function / capability = brief violation = STOP and report.**

### What counts as "gated function or capability"

- New function whose body wraps an existing function's body with a gate (env-var, config flag, predicate check) and returns differently when the gate fires.
- New trait method whose default impl is a no-op while a per-impl override is the real behavior.
- New `Result<_, NewError>` return on a path that previously returned `T` directly — every caller must propagate.
- New `pushdown_capability()` / `is_schema_rich()` / `decode_payloads()` / similar capability hook — must be consumed by at least one production caller, not just tests.

### What does NOT count

- New helper that the new function itself calls (internal-only, no production-path effect).
- New test utility (`InMemorySchemaCatalog::register_as_schema_rich`).
- Pure cleanup that adds no new behavior.
- Documentation / comments.

## Streaming-compliance discipline — per-row identity is load-bearing

Velostream is a streaming SQL engine. Source records may be **multi-row Arrow batches** (one `StreamRecord` = N rows from one Kafka partition / one IPC poll / one File coalesce). System columns (`_offset`, `_key`, `_headers`, `_traceparent`, `_event_time`, `_timestamp`, `_partition`) carry **per-row** identity that is load-bearing for:

- **DLQ routing** — `RowErrors::row_index` maps to the originating Kafka offset via `record.offset_at(row_index)`. Using `record.offset()` (row 0 only) for a row-N failure routes the DLQ entry to the wrong message.
- **Distributed tracing** — Phase 8 `_traceparent` is per-row; span construction must consult `record.traceparent_at(row_index)`, not `record.traceparent()` (row 0).
- **Metrics / sampling** — per-record sampling decisions must consult per-row metadata; using row 0 misattributes 100% of samples to a single source message.
- **Watermark advancement** — windowed operators consume per-row `_event_time` via `record.event_time_at(row_index)` to advance watermarks correctly; coalescing multiple messages into one StreamRecord must preserve per-row event-time identity.

### Recurring failure mode

ADR-707 Phase 5c (PR #817, audit'd 2026-06-18) silently broke per-row metadata: `partition_receiver`, `telemetry::set_record_metadata`, `partition_manager`, and `metrics_helper` still call `record.offset_at(0)` / `headers_at(0)` / `key_at(0)` / `extract_trace_context_if_sampled` against multi-row records, capturing row 0's metadata for the whole batch. This compromised Phase 8's per-row DLQ identity — the very Phase 8 was designed to deliver. The `/code-review` agent flagged it as out-of-scope; only the orchestrator audit caught the streaming-correctness regression.

### Mandatory streaming-compliance check

Run this **before any change that touches** any of the following:

- `src/velostream/datasource/**/read*.rs` (DataReader implementations + coalescers)
- `src/velostream/server/v2/partition_receiver.rs` / `dual_input_partition_receiver.rs` / `partition_manager.rs`
- `src/velostream/sql/execution/processors/{select,join,window*}.rs`
- `src/velostream/sql/execution/{engine,row_errors,stream_record}.rs`
- `src/velostream/observability/{trace_propagation,metrics,sampling}.rs`
- Anything calling `StreamRecord::{from_batch,from_rows,offset_at,offset,headers_at,headers,key_at,key,traceparent_at,traceparent,event_time_at,event_time}`

**Log a STREAMING-COMPLIANCE-CHECK line in `agent.log` BEFORE the change** enumerating which of these invariants the change touches and how it preserves them:

```
2026-06-18T21:00:00Z STREAMING-COMPLIANCE-CHECK | scope=<dlq|trace|watermark|metrics|order|backpressure|shutdown> | invariants=<list> | preserved-by=<plan>
```

Then, **before opening the PR**, log a STREAMING-COMPLIANCE-AFTER line confirming each invariant verified post-change (test name / grep evidence / code-comment citation).

### The invariants

1. **Per-row metadata fidelity** — if the change introduces multi-row `StreamRecord`s (via coalescing or batching) OR reads metadata from one, the consumer must use `*_at(row_index)` not `*()`. Search the touched code path with `grep -nE 'record\.(offset|key|headers|traceparent|event_time|timestamp|partition)\(\)' <touched-files>` and confirm each hit is either (a) a record-level concept (e.g. record-level partition, which is invariant per StreamRecord) or (b) row-0-specific by design (rare; document).

2. **Watermark monotonicity** — `_event_time` must propagate per-row to windowed operators. Watermark advancement uses `max(event_time)` over consumed rows; if the change touches watermark computation, verify `for row in record.iter_rows()` (or equivalent) — never `record.event_time()` for a multi-row record.

3. **Event-time ordering within partition** — `arrow::compute::concat_batches` preserves row order; if the change builds a multi-row StreamRecord from multiple sources, verify the merged order honors source-poll order within a partition. Cross-partition order is NOT guaranteed (intentional).

4. **DLQ per-row identity** — Phase 8 `RowErrors::row_index` indexes into the OUTPUT batch. Verify the DLQ routing code resolves `row_index → original Kafka offset` via `record.offset_at(row_index)`. If a DLQ test does not exist for the multi-row case, add one.

5. **Trace context per-row propagation** — `_traceparent` is per-row. Span construction must call `record.traceparent_at(row_index)`. Sampling decisions per row, not per batch.

6. **End-of-stream / shutdown paths** — windowed-final-emit, accumulator-flush, in-flight cleanup. If the change deletes or renames a flush-on-shutdown helper, audit every caller for transitional silent-no-op behavior.

7. **Backpressure invariant** — coalescer batch sizing must respect downstream pressure. A slow consumer must not cause unbounded batch growth.

8. **Delivery-guarantee accounting** — at-least-once / exactly-once invariants are preserved across the change. Per-query commit-fence logic that depended on engine-side state must move with the state, not silently break.

### When the check fails

If any invariant is broken by the change AND can't be fixed in-scope, **STOP and post to the issue**. Do not ship with a "documented gap" unless the caller's brief explicitly authorizes it. Streaming-correctness gaps in production code are silent-data-loss-class issues per `feedback_no_silent_errors` and `feedback_always_fix_properly_no_tech_debt`.

### Absence of the log line

A diff that touches any of the listed files / methods without a corresponding `STREAMING-COMPLIANCE-CHECK` and `STREAMING-COMPLIANCE-AFTER` log line is a **brief violation** — STOP and report.

## Hot-path discipline (when touching SQL execution or window strategies)

- Plan-time over per-emit. Resolve column names, schemas, types ONCE at plan time; cache on plan / `ProcessorContext`. Hot path consumes cached structures.
- Vec-indexed runtime. `Expr::ColumnRef { index, name }` carries the index for O(1) lookup. Name-based `HashMap` lookups on the hot path are a regression unless justified.
- Memory churn is first-class. Clones, intermediate `Vec`s, `Arc<StreamRecord>` clones on the per-record path need explicit justification.
- Counters / atomics: `AtomicU64` with `Ordering::Relaxed` — no `Mutex` on hot path.
- Apache Arrow is the substrate. New per-record state should be Arrow arrays or system columns, not parallel side-tables.

## Logging — reasoning trail

Maintain `agent.log` in the worktree root (or the repo root if not in a worktree). Append-only.

- **Real timestamps**: `date -u +%FT%TZ` — never fabricate.
- Before each material code change, write a `WHY:` line explaining the change's purpose (one sentence). Phase markers alone are insufficient.
- Log STOP-trigger activations with the failing evidence.
- **Heartbeat every ~10 minutes**: append a `HEARTBEAT` line with the current `date -u +%FT%TZ` timestamp and a one-line status (current phase + what you're doing right now). If the previous log line is older than 10 minutes when you're about to do any tool call, emit the heartbeat first. The user reads `agent.log` to tell stalled work from in-progress work — silence reads as a stall.

Example:
```
2026-06-03T09:42:11Z PHASE 2 — eligibility predicate
2026-06-03T09:43:05Z WHY: extract_chunked_config currently reads agg_exprs[0] only; multi-agg with mismatched value-columns produces silent wrong output (review F1). Adding agg_exprs[1..] validation.
2026-06-03T09:51:30Z Edit adapter.rs:822 — added column-equality check loop
```

## Pre-push HARD GATE

Before pushing any branch, BOTH of the following must pass clean. Run them once each — capture results.

1. **`./run-commit.sh --fast`** from the worktree root. Stage 1 = fmt + clippy + lib/unit tests + doctests. **Run ONCE.**

   **It already formats for you.** `run-commit.sh:106` runs `cargo fmt --all` as Stage 1 step 1 — a WET APPLY, not `--check`, so it rewrites files in place and any reformatting shows up in `git status` afterwards. Do NOT run `cargo fmt` as a separate pre-step; that instruction was stale and described a version of the script that no longer exists.

   **What you MUST still do**: after `--fast` completes, run `git status`. If fmt rewrote anything, `git add -A` and commit it (a separate `style: cargo fmt` commit is fine). The gate applies the formatting but cannot commit it for you — an uncommitted reformat still reaches CI as unformatted code and fails the `Build & Test` check, which runs its own independent `cargo fmt --check`. That is the real repeat-offence pattern behind memory `feedback_fmt_before_push.md`.

   **If you never reach `--fast`** (timeout, STOP trigger, brief says skip it), then nothing has formatted your code — run `cargo fmt --all` yourself before pushing.

   The script auto-tees to `/tmp/run-commit-<branch>-<timestamp>.log` and prints `📝 Full log: <path>` at start AND end — **read that path from the script's stdout** and use it for all subsequent debugging. If the worktree's `run-commit.sh` is on an older base that lacks the auto-tee (grep `LOG_FILE=` line 66 to check), either rebase onto master to pick it up OR pipe manually: `./run-commit.sh --fast 2>&1 | tee /tmp/run-commit-$(git branch --show-current | tr '/' '-')-$(date -u +%Y%m%d-%H%M%S).log`. On failure, diagnose by grepping the LOG file — e.g. `grep -nE "FAIL|error\[|panicked|threshold|warning " "$LOG_FILE"` — then widen the grep or `sed -n '<start>,<end>p' "$LOG_FILE"` to read context. The clippy stage writes a separate log via `mktemp` and prints `Full clippy log: <path>` on failure — read that one too instead of re-running. **Never re-run `--fast` to extract different output from a prior run** — that is minutes of cold compile with zero new information. Fix once, re-run once to verify.
2. **`/check-code`** (the project skill — coverage, error handling, edge cases, duplication, hot-path efficiency). Invoke via the Skill tool; surface findings.

Outcome rules:
- Both clean → push.
- Any fail → STOP. Do not push. Do not retry in a loop. Diagnose the root cause; either fix it in the same PR (preferred for issues your branch introduced) or surface findings to the caller (preferred for pre-existing issues).
- If the failure is in a file your branch did not touch (pre-existing master regression), STOP and report. The caller may authorize push-anyway, but the default is STOP.
- `/check-code` findings of severity "blocker" or "must-fix" → STOP. "Nit" / "consider" findings → list them in the final report but do not block push.

## On opening a PR

1. Assign issue to `bluemonk3y` if the caller's brief names a parent issue.
2. PR title format: prefix with `[#PARENT_ISSUE]` when the caller's brief names a parent issue — e.g. `[#609] Phase 5.5: add t18/t19 ScaledInteger routing tests`.
3. PR body: link the parent issue, summarize what changed, list new public APIs, list new tests by name, note both the `--fast` result and the `/check-code` result.
4. **If the PR introduced a gated function or capability** (per §Production-wiring discipline): paste the `PROD-WIRING-BEFORE` and `PROD-WIRING-AFTER` log lines into the PR body under a `## Production-wiring proof` heading. /pr-gate reviewers check for this; absence triggers a HIGH "dead-code wiring" finding.
5. Post a completion comment on the parent **GitHub issue** (not just the PR) summarizing what landed and linking the PR.

## Final message back to the caller

Your final message is a **what-I-did summary**, NOT a code-review document. Format:

- PR URL
- Branch name
- Files changed (count + names)
- Tests added/modified (names)
- `./run-commit.sh --fast` result (last 5–10 lines, or "STOP — failure: <reason>")
- `/check-code` result (clean / blocker count / list any non-blocking findings)
- GH issue comment URL
- Any STOP triggers hit
- Any decisions made that the caller should know about (one-line each)

Do **NOT** include: code-review prose, line-by-line analysis of your own diff, justification of every minor choice. The caller will read the diff if they want to.

## STOP triggers — always halt and report

- `./run-commit.sh --fast` fails for any reason.
- `/check-code` returns one or more blocker / must-fix findings.
- A test fails and can't be diagnosed in &lt; 3 fix attempts.
- The work requires deleting, skipping, or narrowing a test.
- The work requires swallowing an error or adding a `_ = result` pattern.
- An `ast-grep` pattern fails after 3+ variant attempts on a structural change the brief requires.
- A structural change (trigger-list operation per §AST-grep — mandatory) appears in your diff with no corresponding `AST-GREP-DECISION` log line in `agent.log`. Silent fallback to `Edit` for a trigger-list operation is a brief violation.
- A new gated function or capability (per §Production-wiring discipline) appears in your diff with no corresponding `PROD-WIRING-BEFORE`+`PROD-WIRING-AFTER` log lines in `agent.log`, OR `PROD-WIRING-AFTER` shows `residual-lenient-callers > 0`. Dead-code wiring is a brief violation regardless of how green the local gate is.
- A required CLAUDE.md file is missing.
- The work requires committing or merging without explicit caller authorization.
- The work expands beyond the brief's stated scope (e.g. you discover the requested change requires touching 5+ unrelated subsystems).
- You catch yourself about to re-run `./run-commit.sh --fast` (or any cold-compile gate) to extract different output from the previous run rather than reading the captured log. STOP, capture the log if you didn't already, and grep / `sed -n` the log instead. Repeated cold-compile probes are an efficiency violation.

When a STOP trigger fires: stop work, write the trigger + evidence to `agent.log`, and report back to the caller. Do not push, do not open a PR, do not comment on the issue.

## Shell — avoid permission prompts

Compound Bash commands (variable expansion like `$VAR`, `$(...)` substitution, multi-line `\` continuation, pipes combining the above) cannot be statically allowlisted and will prompt even when every component is allowed. When running autonomously, a prompt is a stall.

- One command per Bash call, with literal paths inlined — not `VAR=...; cmd "$VAR"`.
- For unavoidable multi-step pipelines (profiling, symbolization, log slicing), save to `./scripts/<task>.sh` and invoke that — `./scripts/*` is allowlisted.
- Capture intermediate output to a temp file and inspect it in a second call, rather than chaining `cmd | grep | head` in one line.

## Token discipline

Keep your own internal reasoning minimal in the final report. Cut rationale prose. Keep only load-bearing directives and decisions. If the caller asked for a 200-word report, deliver 200 words.


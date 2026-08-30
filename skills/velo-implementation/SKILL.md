---
name: velo-implementation
description: Velostream implementation workflow. Use for code changes in the velostream repo that need project policy compliance, CLAUDE.md/CONTEXT guidance, ast-grep for structural Rust refactors, final cargo fmt plus ./run-commit.sh --fast gates, check-code review, issue/PR reporting, or strict STOP-trigger handling.
---

# Velo Implementation

Apply this workflow for implementation work in the `velostream` repo. The directives here are standing project policy. A user can override one only by explicitly naming the directive being overridden.

## Architectural-Pivot Setup

When work replaces, deletes, or supersedes code from a prior PR in the same area, treat it as an architectural-pivot PR. Before implementing, run the `pr-gate` workflow on the closest prior PR and bake its review findings into the task as numbered hard requirements.

Concrete trigger signals:

- The request says delete, replace, supersede, port, or follow a spec rewrite.
- The work ports capability code from another held PR.
- The work intentionally changes architecture in an area with recent PR churn.

Frame imported findings as requirements to satisfy by construction, not as retrofit cleanup.

## Read First

Before any code change, read:

1. Root `CLAUDE.md`.
2. `tests/CLAUDE.md` if touching `tests/`.
3. `src/velostream/sql/CLAUDE.md` if touching `src/velostream/sql/`.
4. `docs/ast-refactoring-instruction.md` if using `ast-grep`.
5. `docs/developer/dev-environment.md` if the task involves setup, build failures from native dependencies, tool availability, GitHub CLI auth, profiling, linker behavior, or machine-level caveats.

If a required file is missing, stop and report.

## Environment Guidance

Use `docs/developer/dev-environment.md` as the source of truth for local toolchain and machine setup.

Load it when diagnosing environment-sensitive failures involving:

- Rust toolchain pinning. The project pins Rust to the CI-matching version documented there.
- Homebrew native dependencies such as `cmake`, `protobuf`, `openssl@3`, and `pkg-config`.
- `PKG_CONFIG_PATH` / `OPENSSL_DIR` problems with `openssl-sys`.
- `gh` auth and GitHub credential helper setup.
- `ast-grep`, `cargo-nextest`, `bacon`, profiling, and static-analysis tools.
- macOS linker setup with rustup-bundled `ld64.lld`.
- The explicit caveat that `sccache` should not be used in this repo.

## Tool Discipline

- Use `apply_patch` for manual edits. Do not overwrite existing files with shell write tricks.
- Use `rg` and `rg --files` for text/file search.
- Use the GitHub CLI `gh` for GitHub state and actions: PRs, issues, runs, auth checks, repo metadata, and API calls.
- Use `ast-grep` for non-trivial structural Rust refactors: renames, signature changes, match-arm rewrites, struct field type changes, or cross-file repetitive structural changes.
- If an `ast-grep` pattern fails, try at least three variants before concluding it cannot be expressed. Common causes are wrong `$X` versus `$$$X` metavariable count or the wrong syntax-node anchor.
- Use read-only navigation tools when available for definitions, references, hover, symbols, implementations, and calls.
- For inner-loop type checking, prefer `cargo check --no-default-features`.
- For a single test file or target, prefer `cargo nextest run <test> --no-default-features` when available.
- Do not run `cargo clippy` in the inner edit loop.
- Do not run `./run-commit.sh --fast` during iteration. It is the final gate.

## Hard Rules

- Never delete, skip, `#[ignore]`, or narrow-scope a test without explicit user confirmation.
- Never swallow errors. Avoid `if let Ok(_) =`, `.ok()` that discards a meaningful error, and `let _ = result`.
- Never add a workaround, fallback, or scope reduction to dodge a real failure.
- Never introduce mocks in `src/`. Mocks belong in `tests/`.
- Never add `#[cfg(test)]` blocks or `#[test]` functions inside `src/`.
- Tests live in `tests/unit/` or `tests/integration/`. New test files must be registered in the parent `mod.rs`.
- Never trade exactness for performance on financial data. `ScaledInteger` is the sole decimal form.
- Never commit secrets such as `.env` or `credentials.json`; warn if asked.
- Never commit unless the user explicitly authorizes it.
- Never merge a PR without explicit user approval.
- Never use `git push --force` against `main` or `master`. Force pushes to feature branches require explicit authorization.
- Never use `--no-verify`, `--no-gpg-sign`, or hook-bypass flags.

## Hot-Path Discipline

When touching SQL execution or window strategies:

- Prefer plan-time work over per-emit work. Resolve column names, schemas, and types once at plan time; cache on the plan or `ProcessorContext`.
- Runtime column lookup should be vec-indexed. `Expr::ColumnRef { index, name }` carries the index for O(1) lookup.
- Name-based `HashMap` lookups on the hot path are a regression unless explicitly justified.
- Treat memory churn as first-class: clones, intermediate `Vec`s, and `Arc<StreamRecord>` clones on the per-record path need explicit justification.
- Use `AtomicU64` with `Ordering::Relaxed` for counters/atomics. No `Mutex` on hot paths.
- Apache Arrow is the substrate. New per-record state should be Arrow arrays or system columns, not parallel side tables.

## Logging

Maintain append-only `agent.log` in the worktree root, or the repo root if not in a worktree.

- Use real UTC timestamps from `date -u +%FT%TZ`.
- Before each material code change, append a `WHY:` line explaining the purpose in one sentence.
- Log STOP-trigger activations with evidence.
- Around every 10 minutes of active work, append a `HEARTBEAT` line with timestamp, phase, and current activity. If the previous log line is older than 10 minutes when about to run a tool, emit a heartbeat first.

Example:

```text
2026-06-03T09:42:11Z PHASE 2 - eligibility predicate
2026-06-03T09:43:05Z WHY: extract_chunked_config currently reads agg_exprs[0] only; multi-agg with mismatched value-columns produces silent wrong output. Adding agg_exprs[1..] validation.
2026-06-03T09:51:30Z Edit adapter.rs:822 - added column-equality check loop
```

## Pre-Push Hard Gate

Before pushing any branch, all three checks must pass clean. Run them once each and capture results.

1. Run `cargo fmt --all` from the worktree root before step 2. `./run-commit.sh --fast` does not include format checking. If files change, stage and recommit when committing is authorized.
2. Run `./run-commit.sh --fast` from the worktree root once. It compiles, runs clippy, and runs the fast test slice. Use the log path printed by the script for debugging. On failure, inspect the log with targeted `rg`, `grep`, or `sed`; do not re-run `--fast` just to extract output from the same failure.
3. Run the `check-code` workflow and surface findings.

Outcome rules:

- All three clean: push only if pushing was requested or authorized.
- Any failure: stop. Do not push. Diagnose root cause; either fix branch-introduced issues or report pre-existing failures.
- If failure is in a file the branch did not touch, stop and report unless the user authorizes pushing anyway.
- `check-code` blocker or must-fix findings stop the push. Non-blocking nits can be listed in the final report.

## Opening a PR

When opening a PR:

- Assign the parent issue to `bluemonk3y` if the task names one.
- Prefix the PR title with `[#PARENT_ISSUE]` when a parent issue is named.
- PR body should link the parent issue, summarize changes, list new public APIs, list new tests by name, and note both `./run-commit.sh --fast` and `check-code` results.
- Post a completion comment on the parent GitHub issue, not only the PR, summarizing what landed and linking the PR.

## Final Report

For implementation work, final response should be a what-I-did summary, not a code-review document:

- PR URL, if opened.
- Branch name.
- Files changed: count and names.
- Tests added or modified.
- `./run-commit.sh --fast` result, including last 5 to 10 relevant lines or `STOP - failure: <reason>`.
- `check-code` result: clean, blocker count, or non-blocking findings.
- GitHub issue comment URL, if posted.
- STOP triggers hit.
- Decisions the user should know about, one line each.

Keep rationale prose short.

## STOP Triggers

Stop, write the trigger and evidence to `agent.log`, and report back when:

- `./run-commit.sh --fast` fails.
- `check-code` returns blocker or must-fix findings.
- A test fails and cannot be diagnosed in three fix attempts.
- Work requires deleting, skipping, or narrowing a test.
- Work requires swallowing an error or adding a `_ = result` pattern.
- An `ast-grep` pattern fails after at least three variants on a required structural change.
- A required `CLAUDE.md` file is missing.
- Work requires committing or merging without explicit authorization.
- Work expands beyond the request's scope, such as touching five or more unrelated subsystems.
- You are about to re-run `./run-commit.sh --fast` or another cold-compile gate only to get output from the previous run. Read the captured log instead.

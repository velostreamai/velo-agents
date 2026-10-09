# Velostream worker brief — required contents

Every brief handed to a delegated worker (`velo-deepseek`, `velo-haiku`,
`velo-glm`, `velo-local`) MUST contain the sections below. A brief missing any of them has
caused a real failed run; each rule here is paid for.

## 1. Target and isolation

- Absolute worktree path and branch name; state that both already exist and
  whether the worktree is clean or carries prior commits.
- "Do NOT `cd` into the worktree except for `gh` commands (gh has no `-C`)."
- Tell it to use `git -C`, `cargo --manifest-path`, and absolute paths.

## 2. Fresh line numbers

Compute every `file:line` anchor with `grep -n` AT DISPATCH TIME and say they
are freshly verified. Issue bodies go stale — #1835's `join.rs:130` had moved
to `:147`, and #1877's four sites had shifted. A worker that trusts a stale
anchor edits the wrong place or wastes turns hunting.

## 3. Pinned design — the worker never chooses

State the design decision as already made, in imperative form, and add:
"Do NOT choose an alternative approach. If you believe this design is wrong,
STOP and report why; do not substitute your own."

Where genuine options exist, that is an ORCHESTRATOR decision. Either pin one,
or make the task a read-only Stage-1 analysis that presents options and stops.

## 4. Blast-radius statement and size budget

Say how many call sites / files the change should touch, measured — not
guessed. Add a tripwire: "if you pass ~N files, STOP; you have taken the wrong
approach."

Measure across `src/`, `tests/` AND `examples/`. A grep of `src/` alone said
`process_stream_table_join` had one call site; the real count was 66, and the
worker burned every turn hand-editing before dying with nothing committed.

## 5. Explicit STOP conditions, and what success looks like

List what must halt the run. Critically, state when a RED gate is the CORRECT
outcome — otherwise a worker will manufacture a green one. A worker told only
"make it green" weakened a corpus gate and committed anyway.

If "fixed two files, four remain unsupported, gate red, stopping" is a
successful run, say so in those words.

## 6. SQL syntax — only for tasks that write or edit SQL

Velostream SQL is NOT Postgres, ksqlDB or Flink SQL. Name the references:

    docs/claude/SQL_GRAMMAR_RULES.md
    docs/sql/PARSER_GRAMMAR.md
    docs/sql/COPY_PASTE_EXAMPLES.md
    docs/user-guides/sql-annotations.md
    src/velostream/sql/CLAUDE.md

Reference idiom: `demo/trading/sql/ctas_file_trading.sql`,
`demo/trading/apps/*.sql`.

Require prove-before-use: grep the parser and grammar docs for any unfamiliar
function; absent means unsupported. Forbid inventing a construct to pass a
gate. Require complete statements — select list AND FROM clause, never a bare
fragment.

## 7. Validation commands, spelled out

Give the exact commands with `--manifest-path`. Include the gate:

    (cd <worktree> && ./run-commit.sh --fast)

State that it runs `cargo fmt` as a WET APPLY, and that anything it rewrites
MUST then be committed — the gate formats but cannot commit, and an
uncommitted reformat fails CI's independent `cargo fmt --check`. Two PRs in one
day shipped red for exactly this.

Forbid re-running the gate to get different output; tell it to read the log
path the script prints.

## 8. Authorization, stated explicitly

Say whether the worker may commit, push, open a PR, comment on issues. Never
leave it implied. Never authorize force-push, merge, or touching another
branch or worktree.

## 9. Test rules

- Name the existing test file to extend; only allow a new file if none fits,
  and then require registration in the parent `mod.rs`.
- "If any existing test goes red, do NOT delete, skip, `#[ignore]` or narrow
  it — STOP and report."
- Name the specific existing tests that must stay green as proof the change
  did not lose coverage.

## 10. Reporting

- Read the issue first (`gh issue view`), post a start comment, post a
  completion comment.
- Require the final report to state what was verified vs. assumed.
- Require `agent.log` in the worktree root with real UTC timestamps
  (`date -u +%FT%TZ`) and a `WHY:` line before each material change.

## 11. Known traps to restate in the brief

- Prior failed attempts: say what was tried and why it failed, so the worker
  does not repeat it.
- Prior findings from another worker: label them "verify, do not assume" — one
  worker's classification was wrong and would have propagated.
- Quoting: pass the brief via `--task "$(cat <file>)"`. Nested quotes have made
  models emit tool calls as plain text that never executed.


## 12. Incremental commits — so a timeout never loses work

A prompt timeout aborts the run. Any uncommitted edit is lost, and the task
restarts from zero. Two runs have died this way with work in the worktree.

Require in every implementation brief:

    Commit after each logical step, not once at the end. A timeout or crash
    must never lose completed work. Small commits are expected and will be
    squashed at merge; do NOT wait until everything is done and validated.
    If you are about to start a long step (a full gate run, a multi-file
    edit), commit what you already have FIRST.

Pair this with a generous `--prompt-timeout` (4h+ for implementation) rather
than relying on the default. Cost is unaffected — the timeout only bounds
wall-clock, not tokens.

## Orchestrator's own obligations

- Verify results from `git log` / `git status` / the tests, never from the
  worker's self-report. Every silent failure found in one session was caught
  this way.
- Check `df -h` before a batch — worktree `target/` dirs are ~20 GB each and a
  full disk kills workers with errors that look like code bugs.
- Check the runner's final line for `changed=` and `leaked_tool_calls=`.

## Discovery tooling — do not re-specify it

Briefs must NOT hand-hold `zg`, `rg` or `ast-grep` usage. `velo-impl.md` covers
what each is for and what none of them can do, and it is injected into every
worker's system prompt. Repeating it in a brief means two sources that drift, and
the brief loses to the policy when they disagree.

What a brief SHOULD say is which of the three the task actually needs, when that
is not obvious — e.g. "this is a classification pass over docs, not a refactor;
you will not need ast-grep" — and any known trap, such as a symbol whose name
collides across types.

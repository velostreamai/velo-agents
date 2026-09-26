# `.agents/` — delegated AI worker tooling

Version-controlled source for the workers that implement Velostream issues, the
policy they run under, and the dispatch tooling that decides whether a ticket is
ready for one.

The orchestrator (a Claude/Codex session) does not write the code. It **scopes
the work, pins the design, dispatches a worker, and verifies the result from git
and the tests** — never from the worker's self-report.

---

## Layout

```
.agents/
  install.sh                       repo -> ~/.agents (idempotent; --check reports drift)
  update.sh                        ~/.agents -> repo (recover live edits before committing)
  CHANGELOG.md                     what changed, and the failure each change prevents
  bin/
    velo-dispatch                  validate a ticket, prep the worktree, launch a worker
    velo-status                    one-shot state of every dispatched worker
    velo-pr-gate                   run every gate a PR needs, each on the right model
    velo-gate                      record/inspect a PR's gate state (a LABEL, not memory)
    velo-gate-post                 post a reviewer's report on its behalf
    velo-merge                     merge only if gated against the CURRENT head
    velo-record                    write a dispatch's OUTCOME (appended, never overwritten)
    velo-spec-review               attest a spec was read; --check has Codex REVIEW it
    velo-worktree-lib.sh           worktree derivations shared by velo-status + velo-record
    zg                             discovery-search shim — the `zg` the policy tells workers to run
    velo_worker_runner.py          the one worker runner, two provider profiles
    velo_sdk_patches.py            corrections to the ROLLBACK sdk, applied at import
    velo_runner_lib.py             salvage-on-failure and other runner-side helpers
    velo-openrouter-agent          wrapper -> picks the worker RUNTIME (see below)
    velo-openrouter-agent-sdk.py   worker runner on open-agent-sdk  (ROLLBACK ONLY)
    velo-openai-agents-runner.py   worker runner on openai-agents   (SUPPORTED)
    velo_oai_tools.py              local tools openai-agents does not ship
    velo-lmstudio-agent-sdk.py     local LM Studio worker runner
  tests/
    run.sh                         every suite — run when touching .agents/
    test_runner_accounting.py      usage / leak / cost-provenance invariants
    test_record.sh                 STOP detection, outcome ladder, record writing
    test_dispatch_preflight.sh     brief-vs-reality refusals, driving the real script
    test_gate_health.sh            gate liveness, brief reuse, the per-PR lock
    test_gate_post_sha.sh          the gate stamp: never claim a sha the gate did not see
    test_spec_review_worker.sh     reviewer substitution is allowed, never silent
    test_gate_routing.sh            the routing table: one definition, three readers
    test_index_exclude.sh          the discovery index can never become committable
    test_spec_review.sh            the --check loop's verdict paths, stubbed reviewer
    test_status.sh                 velo-status worker naming
    test_tool_contract.py          the tool contract precedes the policy (#2075)
    test_ast_grep_tool.py          ast_grep is registered, and behaves (#2075)
    test_zg_hidden.sh              zg can see .agents/ — both routes, and the index
    test_history_routing.sh        the re-dispatch guard: tiers, failure modes, bad records
    test_worker_env.py             the worker can run the tools its policy names
  rules/
    velo-impl.md                   MANDATORY implementation policy for every worker
    velo-brief-spec.md             what a task brief MUST contain, and why
  skills/
    velo-deepseek/SKILL.md         orchestrator-facing routing + usage
    velo-glm/SKILL.md
    velo-local/SKILL.md
    check-code/SKILL.md            review skills, inlined into a worker via --skill
    check-spec/SKILL.md
  tasks/
    SCHEMA.md                      task-spec format
    <issue>.json                   per-issue machine-checkable spec
    <issue>.result.jsonl           what each dispatch DID — one record per run
```

Runtime state lives **outside the repo**, under `$VELO_STATE` (default
`~/.agents/state`):

```
~/.agents/state/
  dispatch/<issue>/
    dispatch-<UTC>.log     every ok/warn/die the preflight emitted — why it ran, or refused
    <worker>-<UTC>.log     the worker's own transcript
    zg-index.log           output of the discovery-index build
  gate/<pr>/
    review-brief.md        the brief; stable, so a hand-filled ATTACK survives a re-run
    code-brief.md
    review.log  code.log   the reviewers' output
    .lock                  one gate per PR at a time
  spec/<issue>/
    review-<UTC>.log       one `--check` round's report
    rounds.jsonl           the round ledger: verdict, spec hash, findings
```

This was `/tmp` until four separate defects traced to it: a fixture race
(#2040), two gates on one PR sharing a brief, a cleanup that leaked a file per
run, and a stale brief from a previous session being reused — dispatching a
review briefed on nothing while reporting `ok reusing filled brief`. `/tmp` is
machine-global while worktrees are not, has no ownership semantics, and is
simultaneously too persistent (three-day-old files read as current) and not
persistent enough (macOS purges it). One directory per subject makes the
directory the unit of ownership, of locking, and of pruning; gate artefacts
older than 7 days are pruned by the tool that wrote them.

## Installation

The tooling runs from `~/.agents/`; this directory is the versioned source.

```bash
./.agents/install.sh
export PATH="$HOME/.agents/bin:$PATH"      # add to ~/.zshrc
```

Idempotent — re-run after every pull. It copies `bin/`, `rules/`, `skills/` and
`tasks/`, `chmod +x`es **every** script (a hand-listed subset misses new ones and
fails at dispatch time), and symlinks the orchestrator skills into
`~/.claude/skills`.

```bash
./.agents/install.sh --check    # report drift, change nothing
```

`--check` reports drift in **both** directions and says which it is. A file newer
in `~/.agents` than in the repo is unpushed work, and installing over it loses
it — so recover it first:

```bash
./.agents/update.sh --dry-run   # what would come back
./.agents/update.sh             # copy live -> repo, then review the diff and commit
```

**`~/.agents/` is what actually runs; this directory is the source of truth.**
Edit here, then `install.sh`. If you edited live during a debugging session, run
`update.sh` before anything else. Add a `CHANGELOG.md` entry naming the failure
the change prevents — if you cannot name one, the change probably is not worth
carrying.

### Requirements

| need | for |
|---|---|
| `OPENROUTER_API_KEY` in the environment | DeepSeek and GLM workers |
| `velo-llama-server install` (launchd) | the free local worker: llama-server serving the model named in `bin/velo-local.conf` at `VELO_LOCAL_BASE_URL`. Override per run with `VELO_LMSTUDIO_URL`. |
| `gh`, authenticated | issue/PR validation |
| `python3`, `jq`, `git`, `cargo`, `cargo-nextest`, `ast-grep` | dispatch + worker runtime |
| **Node 22+** (optional) | the `zg` discovery index built per worktree at dispatch. Absent, dispatch warns and workers fall back to `rg` + `ast-grep`. `npm i -g @zvec/zvec-grep` makes it fast; without it the `zg` shim falls back to `npx` per call |

Verify:

```bash
velo-dispatch 1898 /tmp/brief.txt --dry-run    # exercises every gate, launches nothing
velo-status
```

---

## Why bother

Because an AI worker left alone on a large Rust codebase fails in ways that look
like success, and every gate here was paid for by one that did.

A worker will report that it committed — truthfully — to a branch nobody reads.
It will describe code that was fixed last week. It will weaken a test until the
suite goes green. It will burn four hours and a million tokens and produce
nothing, and its final message will be a confident summary. **None of that is
visible from the worker's own report**, which is why every rule below reduces to
one idea: verify from git and the tests, never from what the worker says.

What this tooling buys you:

- **A ticket is refused before a worker is paid for it.** Eight preflight checks,
  each encoding a specific wasted run — stale anchors, a mis-declared blast
  radius, an unpinned design, a brief missing STOP conditions.
- **Parallelism without collisions.** Several workers on one repo, each in its
  own git worktree, each on its own branch, none able to see the others' edits.
- **A record of what every run actually cost and produced**, so routing is a
  measurement rather than a hunch.

If you are dispatching one task by hand and watching it, you do not need this.
It exists for the case where three workers are running unattended against the
same repository and you need to know, afterwards, which of them can be trusted.

## Prerequisites — this is git- and GitHub-shaped

The tooling is not a generic runner. It assumes a specific working model, and
degrades badly without it:

| assumption | why it is load-bearing |
|---|---|
| a **git repository with worktree support** | isolation between concurrent workers IS `git worktree`; there is no other sandbox |
| a **GitHub repo with issues**, reachable via authenticated `gh` | the issue is the unit of work — state, labels and comments are read at preflight, and routing comes from a `worker:*` label |
| **`origin/master` fetchable** | every check validates against the ref the worker's tree is cut from, not your local checkout |
| a **branch-per-issue convention** (`fix/<issue>-auto`) | `velo-status`, `velo-merge` and the result record all key on it |
| **~20GB free disk per concurrent worker** | each worktree carries its own `target/`; a full disk kills workers with errors that look like compile bugs |

`gh` must be authenticated (`gh auth status`) before anything works — issue
state, labels, `updatedAt` drift and PR gating are all API reads.

## Concurrency and isolation

Workers run **unattended, with permissions bypassed, for up to four hours**. The
isolation model is deliberately boring:

```
velostream/                     main checkout — orchestrator only, never a worker
velostream-1898/  fix/1898-auto ── worker A   ─┐
velostream-1902/  fix/1902-auto ── worker B    ├─ one worktree each,
velostream-1907/  fix/1907-auto ── worker C   ─┘  own branch, own target/
```

Rules that make it hold:

- **One worktree per issue, cut fresh from `origin/master`.** `velo-dispatch`
  creates it; do not reuse one by hand. A worktree left by an earlier dispatch
  scores 0-dirty/0-ahead and is indistinguishable from a fresh one — that is how
  a worker was handed a tree 15 commits behind master while the script printed
  that it was current.
- **A worker never `cd`s.** Briefs say so explicitly and the brief checklist
  refuses one that omits it: `git -C <worktree>` and
  `cargo --manifest-path <worktree>/Cargo.toml`. A `cd` in a shared shell is how
  one worker's edit lands in another's tree.
- **`git stash` is repo-global.** Every worktree shares one stash stack, so a
  worker running `git stash pop` gets whichever entry is on top — not its own.
  `velo-status` warns when the stack is non-empty for exactly this reason.
- **The orchestrator does not work in a worker's tree**, and vice versa. The main
  checkout is for dispatching and reviewing.
- **Concurrent OpenRouter dispatches share one in-flight credit budget.** Three
  large-context runs at once returned HTTP 402 before any of them sent a prompt.

## How the orchestrator decides what to run

There is no autonomy here — each script tells you what it needs, and refuses
when it cannot answer. The loop is:

| you want to | run | what decides |
|---|---|---|
| know if a ticket is workable | `velo-dispatch <n> <brief> --dry-run` | eight preflight checks; it names the one that fails |
| dispatch it | `velo-dispatch <n> <brief>` | the issue's `worker:*` label picks the model — not your judgement |
| see what is running | `velo-status [-v] [n]` | reads the **process table and git**, never a worker's report |
| know what a run cost | `velo-status <n>` | the appended `<issue>.result.jsonl` record |
| gate a PR | `velo-pr-gate <pr> <scope-file>` | `velo-gate --plan` derives the gates **from the diff** |
| merge | `velo-merge <pr>` | refuses unless the recorded gate names the CURRENT head |

Two of those deserve emphasis, because they are where judgement is deliberately
removed:

**Which gates a PR needs is computed, not chosen.** `velo-gate --plan` reads the
diff: `src/` touched adds `check-code`; a linked issue with 3+ acceptance bars
adds `check-spec`; anything under `.agents/` requires `code-review`, because
tooling governs every other run. **Which model runs each gate is fixed** —
`code-review` to Codex, `check-code`/`check-spec` to the local worker. Hand-
picking drifted twice in one session, once sending a review to a worker that
returned MERGE-READY while missing a HIGH.

**Skills are inlined, not invoked.** Workers have no Skill tool, so a brief
saying "/check-code" is inert text to them. `--skill check-code` resolves the
skill file and prepends its CONTENT to the prompt. If you find yourself pasting
remembered skill text into a brief, use the flag instead — that hand-copying is
what made two reviews differ for no reason.

## Coordination lives on the GitHub issue

The issue is not a ticket that points at the work — it **is** the coordination
surface. Nothing here keeps a separate queue, database or state file, and that is
deliberate: two sources of truth about what is being worked on is how two workers
end up on the same code.

**Labels are input, not decoration.** `velo-dispatch` reads them and refuses on
what it finds:

| label | effect |
|---|---|
| `worker:local` / `worker:deepseek` / `worker:glm` / `worker:codex` | **routing.** Exactly one required — zero or two is a refusal. The label picks the model; the orchestrator does not |
| `needs-design` | refuses. A worker must never choose between design options — pin the design on the issue, or dispatch a READ-ONLY analysis brief that presents options and stops |
| `blocked` | refuses. Resolve the dependency first |
| `triage-needed` | refuses without `--force`. Four issues in one session turned out already-fixed; the label means "claims not yet verified against master" |

**Assignment marks live work.** `velo-dispatch` assigns the issue **only at
launch**, never at validation — so an assignee means a worker is or was actually
running, not that someone intended to look at it. Assign-then-refuse would make
the signal meaningless.

**Gate state is a comment, not memory.** `velo-gate` writes
`gate: <name> @ <sha>` and the labels `gate:running` / `gate:passed` /
`gate:blocked` / `gate:none`. Two consequences worth internalising:

- **A gate result is only valid for the commit it names.** `velo-merge` refuses
  when the recorded sha is not the current head, and re-gating scopes the review
  to the delta since that sha rather than re-deriving cleared work. A PR was once
  green against a commit that had already been replaced.
- **A substituted reviewer must be declared in the comment.** If Codex is
  unavailable and something else runs, say so — otherwise the label implies a
  reviewer that never ran, which is how five reviews on one PR were silently
  performed by the wrong model.

**Findings go on the issue or PR, not into chat.** A worker's completion comment,
a gate's findings, and the correction when a finding turns out to be wrong all
belong in the thread. The next dispatch reads the issue; it cannot read your
terminal. This is also why the drift check compares the issue's `updatedAt`
against the spec's `reviewed.at` — a ruling posted as a comment is real state, and
a brief written before it is stale.

**Cross-link related work.** Child issues carry the parent in the title
(`[#1749] …`), which is what lets `velo-status` show progress against an umbrella
effort rather than a flat list of open tickets.

## How a worker searches the code

Four layers, and the split matters because reaching for the wrong one is how a
worker produces a confident wrong answer:

| layer | tool | answers | does NOT answer |
|---|---|---|---|
| **discovery** | `zg query "..."` | "where is the code that does X", in plain English, when you have no symbol name | anything about types |
| **text** | `rg` | "where does this literal appear" | ranking, structure |
| **structural** | `ast-grep` | "every `impl` of X", "every call to `f($$$)`", scoped to a containing `impl` | which TYPE a receiver is |
| **semantic** | `cargo check` | whether what you just wrote type-checks | anything before you write it |

The order is deliberate: `zg` when you cannot yet name the thing, `ast-grep` once
you can, `cargo check` after you have changed it.

**Why `zg` exists.** `rg "null.?pad" src/` returns 13 unranked files, and
`ast-grep` needs the symbol you are trying to find. `zg query "where the
null-padded column set for an unmatched outer join row is decided"` returns
`coordinator/mod.rs → merge_left_with_nulls_batch` as its second hit. Nothing
else in the toolchain covers that phase.

`velo-dispatch` builds the index into the worktree before the worker starts —
measured at 35s, 0.10GB peak, 325MB on disk. Synchronously and before launch on
purpose: a worker querying a half-built index gets nothing, and "no results" is
indistinguishable from "not ready yet" — the ambiguity that made a stale language
server silently degrade an agent to grep-based rewriting. `VELO_SKIP_INDEX=1`
opts out; a failed build warns and the dispatch continues.

**Also a first-class tool.** On `openai-agents` a worker has `zg_query`, `grep`,
`glob_files`, `read_file`, `bash`, `edit_file`, `write_file` (read-only tasks drop
the last two). On the rollback runtime the equivalents are `ZgQuery, Read, Glob,
Grep, Bash, Edit, Write`. Either way `zg` is ALSO a CLI on `PATH`
(`.agents/bin/zg`), invoked like `cargo`. The worker knows it exists
because `velo-impl.md` says so, and that file is spliced into every system
prompt.

**Three limits, in the policy because they matter:**

1. **A snapshot** taken at worktree creation. It does not track the worker's own
   edits — for locating existing code, never for verifying a change just made.
2. **Not type-aware.** It will not say which of 79 `.record_count` sites are
   `ProcessorContext`. *Nothing* in the worker's toolset will.
3. **A miss is not proof of absence.** Falling back to `rg` is correct;
   concluding "there is no such code" is not.

## Anchors, not line numbers

A task spec pins the code it describes with **symbols**, never `file.rs:130`:

```json
"anchors": [
  { "file": "src/velostream/sql/parser/select.rs",
    "symbol": "StreamSource::Uri", "expect": 4 }
]
```

`velo-dispatch` re-counts each symbol **against `origin/master`** at dispatch
time and refuses if the count moved. Line numbers rot between writing a brief and
running it — `join.rs:130` had already moved to `:147` when a brief shipped it —
whereas a symbol that has genuinely disappeared is a real signal that the issue
describes code that no longer exists. Four issues in one session turned out to be
already fixed, and this is the check that catches that class.

The same idea covers intent, not just code: the spec carries a `reviewed` block
with a timestamp and the brief's sha256, and dispatch refuses if the **issue** has
been edited or commented since — a ruling posted as a comment is the commonest
way a brief goes stale, and no code-based check can see it.

---

## How this works with Claude Code and Codex

Two runtimes, three roles. Getting these confused is how a gate ends up reported
as run when nothing ran.

### Worker runtime — `openai-agents`

**Delegated workers run on `openai-agents`. The vendored `velo-agent-sdk` fork is
NO LONGER THE SUPPORTED RUNTIME** — it is retained only as a rollback while the
switch beds in, and is scheduled for deletion.

Write new worker code against `openai-agents`. Do not add capabilities to the
fork, and do not assume its behaviour when reading this document.

| `VELO_AGENT_BACKEND` | runner | interpreter | status |
|---|---|---|---|
| `openai-agents` *(default)* | `velo-openai-agents-runner.py` | `~/.venvs/velo-openai-agents` | **supported** |
| `open-agent` | `velo-openrouter-agent-sdk.py` | `~/.venvs/velo-agent-sdk` | **rollback only — delete after 2026-10-13** |

```bash
VELO_AGENT_BACKEND=open-agent velo-dispatch 1234 brief.md   # back to the incumbent
```

Measured on an 18-turn audit, 3 rounds each, same model / gateway / provider pin
/ tools: **correctness 3/3 both**, `openai-agents` **1.73x cheaper** and **4.2x
faster** in wall clock. 94-99% of the incumbent's wall clock was model wait, not
tool execution, so it was never a tools problem. Earlier 4-turn benchmarks said
2.13x cost and a tool-call edge to the incumbent; both were artifacts of a task
too short for a transcript to accumulate.

Both runners take the **same flags** and emit the **same log lines**, so
`velo-record`, the gates and the tests read either one unchanged.

Two runners is deliberate and TEMPORARY, with a DATE: **delete the rollback on
2026-10-13** — one month after the switch (2026-09-12), tracked on #2088.

The date exists because "temporary" without one is how a dual path becomes
permanent, and this repo has the receipts: a `VELO_AGENT_IMPL=legacy` escape
hatch survived long enough to rot into a `ModuleNotFoundError`, documented as
forbidden AND broken if used. A fallback nobody exercises is not a safety net.

Deleting it means: `velo-openrouter-agent-sdk.py`, `velo-lmstudio-agent-sdk.py`,
`velo_worker_runner.py`, `velo_sdk_patches.py`, the `open-agent` branch of this
wrapper, and the `~/.venvs/velo-agent-sdk` venv. `velo_skills.py` and
`velo_runner_lib.py` STAY — both runtimes share them.

Extend the date only by editing this line with a reason. If the rollback has been
used in that month, that is the reason; if it has not, the month was the test and
it passed.

**Output budget is per model and must be generous.** A reasoning model spends
most of its budget thinking: GLM emitted 318 visible tokens out of 8,000 and the
run DIED — `openai-agents` raises on `finish_reason='length'` where the incumbent
recovers with "Continue from where you left off." `max_tokens` is a ceiling, not
a reservation, so too high costs nothing and too low loses the whole run after
arbitrary spend. GLM is set to 131,072; the default is 65,536.

| role | who | what it can do |
|---|---|---|
| **orchestrator** | a Claude Code session (usually), or Codex | runs `velo-dispatch` / `velo-status` / `velo-pr-gate`; writes briefs and specs; never writes the feature code itself |
| **delegated worker** | `velo-local`, `velo-deepseek`, `velo-glm` via the worker runner (`VELO_AGENT_BACKEND`); `worker:codex` via `codex exec` | implements one scoped task in its own worktree, unattended |
| **review gate** | `codex review` for `code-review`; `velo-local` for `check-code` / `check-spec` | reads a diff read-only and returns findings |

Codex appears in **two** of those roles and they are not interchangeable:
`worker:codex` implements (via `codex exec`, dispatched by `velo-dispatch`),
while `codex review` gates (dispatched by `velo-pr-gate`). Same CLI, different
subcommand, different brief, different failure modes.

**Capability differs by runtime, and the policy accounts for it.** A Claude Code
orchestrator has the LSP tool, the Skill tool and MCP servers. A delegated worker
has exactly `zg_query, grep, glob_files, read_file, bash, edit_file, write_file`
— no LSP, no Skill tool (review skills are inlined into the
prompt by `--skill` instead). `rules/velo-impl.md` forks its type-aware refactor
section on precisely this: LSP-first for agents that have LSP, `ast-grep` plus
`cargo check` for everyone else.

**Policy delivery also differs.** The three SDK routes take `--policy` and splice
`velo-impl.md` into the system prompt. `codex exec` has no such flag, so
`velo-dispatch` prepends the policy to its prompt — its only channel. Until that
was fixed the most permissive worker (it runs with the sandbox bypassed) was the
only one running with no policy at all.

**A gate that cannot run must say so.** `codex review` dying on quota used to
print `ok code-review -> codex (pid N)` and mark the PR `gate:running`, and its
log looked like a report because the brief is echoed before the model is called.
`velo-pr-gate` now watches the process briefly and refuses rather than claiming.
If you substitute a different reviewer, **declare it in the gate comment** — the
label must not imply a reviewer that never ran.

## The four workers

| skill | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | `qwen3.8-flash-next-ud` (LM Studio, llama.cpp >= 2.46.0, 262K ctx) | **free** | triage, investigation, check-spec, second-opinion review; latency-insensitive only (#2235) |
| `velo-deepseek` | `deepseek/deepseek-v4-flash-0731` | **very cheap** | fast scoped implementation against a pinned design |
| `velo-glm` | `z-ai/glm-5.3-flash` | **pricier, good value** | multi-step reasoning, per-case classification judgement |
| `worker:codex` | `codex exec` (CLI) | **most expensive** | architecture-weight work — anything where a WRONG answer costs more than the run |

Cost-first: default to local, reach for DeepSeek when turnaround matters, spend
GLM deliberately, and keep Codex for work whose blast radius justifies it. On
#1988 Codex found 2 P1s that two local gates missed while both returned
*approve*; on #1967 every load-bearing claim in its analysis survived
independent verification; GLM produced ZERO code in 186 turns on #1747.

They share one policy and can run **concurrently** — give each its own git
worktree and non-overlapping files. Note that concurrent OpenRouter dispatches
share one in-flight credit budget: three large-context runs at once returned
HTTP 402 `in_flight_budget_exhausted` before any of them sent a prompt.

Routing comes from the issue's `worker:*` label, not from which skill you read.

---

## Resuming a run that stopped — `--resume`

A worker stops part-way: a STOP condition, a timeout, a killed session. The
worktree holds commits. Re-dispatching refuses, correctly — and until now the
refusal told you to "dispatch with `--worktree`", **a flag this script has never
accepted**. Its own parser answers `unknown flag: --worktree`. So the documented
way to keep the work did not exist, and the only flag that did work was
`--force`, which deletes the branch and its commits.

```bash
velo-dispatch 1958 brief.md --resume     # keep the tree, the branch, the commits
```

`--resume` validates and then does **nothing** to the tree. It refuses rather
than repairs — a resume that quietly fixes up a tree is indistinguishable from
the `--force` it replaces:

| condition | why it refuses |
|---|---|
| `--resume` with `--force` | they are opposites; pick one |
| no worktree at that path | nothing to resume |
| detached HEAD | the worker would commit somewhere nothing tracks |
| on a different branch | `velo-status` and `velo-merge` watch the dispatch branch |
| mid-rebase / merge / cherry-pick | a worker cannot tell a conflict marker from code |

It **warns**, loudly, when commits are not on `origin` — because that is exactly
what a later `--force` destroys:

```
warn: 2 commit(s) on fix/1958-auto are NOT on origin.
warn:   A --force dispatch on this branch would delete them, and this is the
warn:   work you are resuming. Make it durable first:
warn:     git -C ~/RustroverProjects/velostream-1958 push -u origin fix/1958-auto
```

**Push before you resume.** It costs nothing and it makes the destructive flag
survivable. The warning exists because nothing else in the tooling tells you.

`--dry-run` now says which of the three things would happen — resume, cut fresh,
or refuse — since those differ in whether commits survive:

```
worktree : ~/RustroverProjects/velostream-2047  (RESUMED — kept as-is)
           on 'fix/2047-auto', 1 commit(s) ahead, 0 dirty; nothing reset

worktree : ~/RustroverProjects/velostream-2047  (WOULD REFUSE — has 1 commit(s), 0 dirty)
           --resume to keep them, --force to discard them
```

## Usage

### 1. Label the issue

```bash
gh issue edit 1898 --add-label worker:deepseek
```

Blocking labels — `velo-dispatch` refuses these:

| label | meaning |
|---|---|
| `needs-design` | a design decision is open. Workers never choose between options. |
| `blocked` | waiting on another issue |
| `triage-needed` | claims may not match master; verify first (`--force` to override) |

### 2. Write a task spec (optional, recommended)

`.agents/tasks/1898.json` — see `tasks/SCHEMA.md`. Enables the anchor and
blast-radius checks and injects acceptance criteria into the brief.

### 3. Write the brief

Must satisfy `rules/velo-brief-spec.md`. `velo-dispatch` checks for the required
sections and names any that are missing.

### 4. Check the brief FIRST, then dispatch

```bash
velo-dispatch 1898 /tmp/brief-1898.txt --dry-run   # validates everything, launches nothing
velo-dispatch 1898 /tmp/brief-1898.txt             # only after the dry run is clean
```

**Always dry-run first.** It runs every gate — issue state, labels, task-spec
anchors, computed blast radius, brief completeness, disk — and creates no
worktree, assigns nothing, launches nothing. A brief that is missing a STOP
condition or a grammar reference is caught here rather than by a wasted
dispatch attempt.

The gates refuse before any side effect either way, so skipping the dry run is
not dangerous — just slower and noisier.

```
── validating #1898 ─────────────────────────────────
  ok open: [arch] Remove StreamSource::Uri — the AST carries labels, not locators
  ok no blocking labels
  ok routed to velo-deepseek
  ok validating against origin/master (8daed48e1) — pinned for this run
  ok dependencies closed
  ok reviewed by neilavery at 2026-09-01T06:35:09Z; issue unchanged since
  ok anchors verified against origin/master
  ok blast radius: 94 refs / 12 files (declared 94 / 12)
  ok brief BRANCH/WORKTREE match what will be cut
  ok brief satisfies the spec checklist
  ok disk: 223GB free
```

A real dispatch (without `--dry-run`) continues past those into the side-effecting
steps:

```
  ok worktree cut from origin/master: ~/RustroverProjects/velostream-1898 (fix/1898-auto @ 8daed48e1)
  ok discovery index excluded from git on every worktree (verified via check-ignore)
  .. building discovery index (~35s, skip with VELO_SKIP_INDEX=1)
  ok discovery index built (325M) — worker can run: zg query "..."
  ok assigned to bluemonk3y
```

#### The brief must describe the run it is actually getting

Two of those lines are comparisons, not announcements.

`ok brief BRANCH/WORKTREE match what will be cut` means the `BRANCH:` and
`WORKTREE:` headers in your brief were checked against what this dispatch will
really create. A mismatch **refuses**:

```
NOT READY: brief WORKTREE does not match the worktree this dispatch will use.
  brief says : /tmp/completely-wrong
  will use   : /Users/neilavery/RustroverProjects/velostream-1898
```

This exists because nothing used to compare them, and the failure is silent and
splits the work: a worker that follows the brief commits to a branch
`velo-status` and `velo-merge` never look at, reports success *truthfully*, and
the dispatch branch sits empty. Fix the brief, or pass `--branch <name>` to cut
what it names.

The `WORKTREE:` line is **required**, not optional — `velo-brief-spec` §1, and
dispatch refuses without it:

| brief says | result |
|---|---|
| a worktree matching what will be cut | `ok brief BRANCH/WORKTREE match what will be cut` |
| a worktree that differs | **refused** — mismatch, shown above |
| a `## Worktree` heading with no readable path | **refused** — malformed, not ambiguous: fix the declaration rather than deleting it |
| nothing at all | **refused** — `brief declares no WORKTREE` |
| nothing, and a `## Branch` line naming several paths | `warn`, not compared — prose cannot disambiguate; add an explicit `WORKTREE:` line to have it checked |

#### When the discovery index is refused

`ok discovery index excluded from git … (verified via check-ignore)` is likewise a
check, not a claim: the exclusion is written to the git **common dir's**
`info/exclude` and then confirmed with `git check-ignore`. If git still says the
index is trackable — usually `info/exclude` being read-only or a symlink —
dispatch **refuses to build it**:

```
warn: could NOT exclude the discovery index from git — NOT building it.
warn:   Refusing to build: an unignorable 325MB index is one failed run away
warn:   from being committed by salvage's 'git add -A'.
```

That is deliberate. The failure salvage path runs `git add -A`, so an
unignorable index would be committed by the very mechanism meant to preserve a
dying run's work. Workers keep `rg` and `ast-grep`, which is a smaller loss than
a poisoned branch. `VELO_SKIP_INDEX=1` skips the build outright.

### Running a review skill in a worker — `--skill`

Workers run with a fixed `allowed_tools` list and no `setting_sources`, so they
have **no Skill tool**: a brief saying "run /check-code" is inert text to them.
`--skill` resolves the skill file and inlines its content ahead of the task.

```bash
velo-openrouter-agent --model z-ai/glm-5.3-flash --skill check-code --skill check-spec \
  --policy ~/.agents/rules/velo-impl.md --cwd ~/RustroverProjects/velostream-1883 \
  --task "$(cat scope.txt)"
```

Resolution order, first hit wins:

```
~/.agents/skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
~/.claude/commands/<name>.md
```

YAML frontmatter is stripped. A missing skill is a hard error naming every path
tried — a silently-absent skill yields a review that looks like it ran a gate
and did not.

**The brief then carries only the scope**: the PR, the worktree, what the change
does, and the few questions the diff alone will not answer. Restating the review
dimensions in the brief is the anti-pattern this replaces — it drifted between
dispatches, and it drifted away from the skill.

### 5. Watch, then **verify from git**

```bash
velo-status -v
git -C ~/RustroverProjects/velostream-1898 log --oneline origin/master..HEAD
```

A worker's own report is not evidence. A worker that commits looks "unchanged"
to its runner, and one that emits a tool call as plain text reports success
having executed nothing (`velo-status` flags that as `LEAKED`).

### 6. Read what the run actually cost — `<issue>.result.jsonl`

Every dispatch appends one record when its worker exits, written by `velo-record`
from the supervisor `velo-dispatch` wraps around the runner. Crashes, timeouts
and clean finishes all leave a row — a record that only appears on the happy
path measures the happy path.

```bash
velo-status 1898          # renders every recorded run for one issue
jq -s 'map({outcome, worker, wall_clock_s, cost})' .agents/tasks/1898.result.jsonl
```

Records are **appended, never overwritten**: a re-dispatch of the same issue is
the interesting row, not one to discard. JSONL rather than a JSON array because
the array was an unlocked read-modify-write — six concurrent recorders left one
of six rows, silently, exit 0.

**`cost.usd` is null unless the price was real.** The SDK's `estimate_cost`
silently applies an invented `{input: 3.0, output: 15.0}` rate to any model
outside its Anthropic/OpenAI table — which is every worker here — so a free
local run was costed at $0.063, and one real review reported **$56.93 for
~$1.22 of actual spend**. When the rate is not known the estimate is preserved
under `usd_sdk_estimate_invented_rate`, a name nobody will mistake for a price.
Token counts are always real; only the dollars are suspect.

`outcome` is one of:

| value | meaning |
|---|---|
| `landed` | ran clean and left commits |
| `reported` | read-only task, wrote nothing — the CORRECT result for a review gate |
| `read-only-violation` | read-only task that committed anyway |
| `stopped` | hit a STOP trigger and reported — a success of the policy, not a failure |
| `abandoned` | no commits, no STOP, no error |
| `failed` | non-zero exit, or a leaked tool call (an intended action never ran) |

### 7. Re-dispatching — the record now decides whether you may

For a long time the record was written and never read. The only mentions of it
in `velo-dispatch` were a comment and the line telling you where it would be
written, so every dispatch launched blind to what had already happened on the
same issue. Reading it back showed why that mattered — 18 dispatches, 7 landed:

| issue | sequence | |
|---|---|---|
| #2000 | deepseek `failed` → **deepseek again** `read-only-violation`, 253 turns | same tier after a failure |
| #1918 | codex `stopped` → codex `stopped` | same tier twice |
| #1987 | glm `read-only-violation` → codex `landed`, 8 commits | escalation worked, by hand |
| #1994 | glm `read-only-violation` → codex `stopped` | escalation did not help |

So `velo-dispatch` now prints prior attempts before launching, and **refuses a
same-or-lower tier after a non-landed outcome**:

```
  prior attempts on #2000:
    velo-deepseek  failed                 commits=0   turns=0
    velo-deepseek  read-only-violation    commits=3   turns=253

NOT READY: #2000 last ran on velo-deepseek and ended 'read-only-violation'.
    You are dispatching to velo-deepseek, which is the same tier or lower.
    …
    Escalate the decision where it is actually made:
      gh issue edit 2000 --repo … --remove-label worker:deepseek --add-label worker:glm
```

Tier order is `local < deepseek < glm < codex`.

**The refusal names the label change because that is where the decision lives.**
The worker is chosen at spec/label time and then never revisited — which is the
whole of #2000: the label said deepseek, the run failed, and the re-dispatch used
deepseek again because nobody went back and changed it. A refusal that only says
"no" leaves the stale decision in place. Change the spec's `worker` field too:
the label overrides the spec, so changing one leaves them disagreeing (#2085).

To repeat a tier deliberately:

```bash
velo-dispatch 2000 .agents/tasks/2000-brief.md --same-tier 'brief now pins the schema'
```

It takes a **reason**, not a bare flag, and the reason is recorded by the audit
log. A bare flag gets typed reflexively the second time anyone hits the guard,
which removes the only thing the guard is for.

**Escalation is often the wrong response, so the advice depends on the failure
mode.** A run that failed *after producing work* is a capability signal. A run
that produced nothing points at the brief. And `read-only-violation` is treated
as neither: `velo-record` infers it by grepping the brief's prose, and its own
comment calls that inference "the actual defect" — #2006 followed a brief saying
"read-only to src, commit your analysis" and had its two required commits
recorded as a violation. The guard says the outcome is inferred and asks you to
check, rather than asserting a discipline failure it cannot establish.

If the record cannot be parsed the dispatch **proceeds and says so loudly**. A
guard that refuses must never wedge an issue — but a guard that vanishes quietly
is how #2000 happened, so "no history" and "history we could not read" are
reported differently.

---

## One gate per PR, and one spec review loop

`velo-pr-gate` takes a per-PR lock (`~/.agents/state/gate/<pr>/.lock`, created
with `mkdir`, which is atomic). A second gate on the same PR is **refused**
rather than allowed to interleave:

```
ERROR: a gate is already running for #2027 (pid 41233).
  Two gates on one PR share ~/.agents/state/gate/2027 — the brief, both code and
  review logs — so the second would overwrite files the first is still writing.
```

A dead holder's lock is reclaimed; the lock is released on every exit path,
including refusals, so a refused gate cannot wedge the PR. Uniquifying the paths
would have been the obvious fix and the wrong one — the brief path is
deliberately stable so a hand-filled ATTACK section survives a re-run.

### `velo-spec-review <issue> --check`

`velo-dispatch` validates a spec *mechanically*: anchors resolve, blast radius
matches, `design` pinned, deps closed. None of that is judgement, so a spec can
pass every check and still aim a worker at the wrong thing.

`--check` puts Codex on the spec itself, with checks it must **execute**: resolve
every anchor at `origin/master`, run each `fail_to_pass` and report whether it
currently *fails*, name any hazard in `_why` with no matching stop condition,
re-run the blast-radius grep, and judge whether a worker with no LSP could
satisfy it at all.

The loop **reports**; it does not edit. Clean requires **two consecutive CLEAN
rounds on unchanged spec content** — one proves the last fix broke nothing, two
proves the reviewer stopped finding things rather than finding different ones.
Any spec edit resets the streak. No verdict, a timeout, or an unrecognised
verdict all exit 2: a review that produced nothing is not a review that found
nothing.

Its first real run found four HIGH findings on a spec that had **already been
dispatched** — including two `fail_to_pass` tests that do not exist, so the run
that "landed" had an acceptance gate naming nothing.

## Why each gate exists

Every gate was paid for by a wasted run.

| gate | the failure |
|---|---|
| anchors are **symbols**, re-verified | four issues in one session described already-fixed code; a brief cited `join.rs:130` after the symbol moved to `:147` |
| blast radius **computed**, not declared | an issue implied one call site; there were 66. The worker burned its whole turn budget hand-editing. |
| `evidence` / `audit` | stale claims came from **spec lines and agent reports**, not code reads |
| `design: pinned` | an agent asked to choose an architecture picks one and cascades it |
| brief has STOP conditions **and** what success looks like | a worker told only "make it green" weakened a corpus gate and committed anyway |
| brief mandates **incremental commits** | two runs hit a wall-clock timeout mid-edit and lost everything uncommitted |
| disk >= 40GB | each worktree `target/` is ~20GB; a full disk kills workers with spurious `error[E0308]`s |
| `depends_on` closed | dispatching behind an open dependency |

---

## Worked example — `.agents/tasks/1898.json`

```jsonc
{
  "issue": 1898,
  "worker": "deepseek",
  "design": "pinned",              // "open" => dispatch refused
  "verified_against": "591c2d6b8",
  "evidence": "code",              // spec|report => audit required first
  "audit": "done:591c2d6b8",
  "depends_on": [],

  "anchors": [                      // SYMBOLS. Line numbers rot.
    { "file": "src/velostream/sql/ast.rs",
      "symbol": "Uri(String)", "expect": 1 },
    { "file": "src/velostream/sql/parser/select.rs",
      "symbol": "StreamSource::Uri", "expect": 4 }
  ],

  "blast_radius": {                 // declared; dispatch COMPUTES and compares
    "pattern": "StreamSource::Uri", "files": 44, "refs": 94
  },

  "tests": {                        // SWE-bench FAIL_TO_PASS / PASS_TO_PASS
    "fail_to_pass": ["source_name_with_scheme_separator_folds_like_any_label"],
    "pass_to_stay": ["order_by_inside_within_group_does_not_produce_a_sort_node"],
    "known_red":   ["benchmark_three_hop_processor_pipeline"]
  },

  "acceptance": ["StreamSource::Uri deleted; the enum has three variants"],
  "forbidden":  ["do not hand-Edit 30+ files; ast-grep is required"]
}
```

Injected faults, and what dispatch says:

```
symbol renamed        -> ANCHORS ARE STALE — symbol 'Uri(PathBuf)' NOT FOUND
"refs": 1             -> BLAST RADIUS MISMATCH — declared 1, actually 94
"evidence":"spec"     -> must be audited against code first
```

---

## Reviewing the result

Every dispatch appends a record to `.agents/tasks/<issue>.result.jsonl`, and it
now carries `discovery_index` — `built` / `refused` / `failed` / `skipped` /
`unknown`. That field exists because the discovery index shipped in #2033 and
**was never built once**: a guard asked git the wrong question and refused on
every fresh worktree, and the only evidence was a warn line in a terminal. One
`jq` over these records would have shown zero on day one.

```bash
jq -r '[.issue, .worker, .discovery_index, .outcome] | @tsv' .agents/tasks/*.result.jsonl
```


```bash
velo-pr-gate 1902 --plan            # which gates, on which models
velo-pr-gate 1902 scope.md          # dispatch the local gates, generate the Codex brief
velo-gate     1902 --pass           # or --block, once the reviewers report
velo-merge    1902                  # refuses unless gate:passed AND gate sha == head
```

### `velo-pr-gate` — one command, fixed model routing

| gate | model | why this one |
|---|---|---|
| `code-review` | **Codex** | found a real defect in every round it ran, including against designs already pinned and code the orchestrator wrote |
| `check-code` | velo-local | free; fine at mechanical dimension checks |
| `check-spec` | velo-local | free; fine at bar-by-bar verification |

Choosing the model per PR by judgement is how the routing drifted: a review once
went to velo-local and came back `MERGE-READY` while missing a HIGH and asserting
a fact that was demonstrably false. The routing is now in the script.

It also:

- **refuses without a scope file** — a gate briefed only on a diff reports
  dimensions rather than findings, which is how that bad review happened
- **computes the review diff range** from the last recorded
  `gate: codex-review @ <sha>`, so a re-review scopes to the delta and tells the
  reviewer what it already cleared
- **refuses an empty range** — if nothing landed since the last review, there is
  nothing to review, and an empty diff comes back `approve`: a vacuous gate
  wearing a green tick
- **generates the Codex brief** with everything invariant filled in — worktree,
  range, read-only clause, output format — leaving only the `## ATTACK` section
  blank

That last blank is deliberate. A fixed checklist produces a generic review; every
real finding in this repo came from a specific prompt ("is this arm a NEW silent
loss?", "can this fix make detection WORSE?"). Templating it would have produced
none of them.

Codex IS launched by the script — `codex review` runs non-interactively and
takes its prompt on stdin. This paragraph used to say the opposite ("it is an
Agent call"), and that belief cost real money: every `code-review` on #1929,
#1942 and #1943 silently fell back to a substituted Opus agent — five on #1943
alone — while the routing table said Codex. What actually failed was the
codex-rescue AGENT wrapper, which forwards to a background task it cannot poll
and so returns a task handle instead of a report. The CLI has no such problem.

The gate still refuses to dispatch while the brief's `## ATTACK` section is a
placeholder, which is what keeps it a conscious act.

`--plan` derives the gates from the diff: docs/tooling-only needs none, `src/`
touched adds `check-code`, a linked issue with 3+ acceptance bars adds
`check-spec`.

**Gate state is a LABEL** (`gate:none` / `running` / `passed` / `blocked`), so
"this has not been gated" is visible rather than merely absent. Verifying a PR
yourself is NOT gating it — that is how an ungated PR gets described as ready.

**Every gate comment starts `gate: <name> @ <sha>`.** A result is only valid
for the commit it ran against; a PR was once green against a commit that had
already been replaced. `velo-merge` compares that SHA to `headRefOid` and
refuses on mismatch.

**One label, several gates.** `gate:passed` is a single label, but a `src/` PR
runs up to three gates. `velo-merge` therefore cross-checks the gates
`velo-gate --plan` demanded against the `gate: <name> @ <sha>` comments actually
recorded, and refuses when any is missing — a finding that never reached the PR
is indistinguishable from a gate that never ran, and the printed handoff used to
name only `code-review`, so two could be silently dropped. `velo-pr-gate` now
prints a `velo-gate-post` line per gate it dispatched.

**Orchestration counts as code.** Anything under `.agents/{bin,rules,skills,tasks}/`
or `install|update.sh` requires `code-review` and is gated at merge, even though
it has no `src/` or `tests/` path. Compilability was never the right test — blast
radius is: these scripts decide which tree a worker starts from, which gates run,
and who runs them. They were previously classified "docs/tooling only, no
buildable code" and merged unreviewed; in one session that shipped a gate whose
regex silently skipped itself and a dispatcher that handed a worker a tree 15
commits stale while reporting it current.

**Deliver the report yourself.** A reviewer that cannot reach the GitHub API
produces a good report and then silently fails to post it — indistinguishable
from a gate that never ran. Have the reviewer RETURN its report, then:

```bash
velo-gate-post 1902 codex-review report.md      # stamps the header, posts it
somereviewer | velo-gate-post 1902 check-code -  # or from stdin
```

It refuses an empty report, enforces a lowercase-kebab gate name, defaults the
SHA to the PR's current head, and warns (rather than back-dating) when you
record against an older one.

---

## What a dispatch decided, after the fact

`~/.agents/state/dispatch/<issue>/dispatch-<UTC>.log` records every `ok`, `warn`
and `die` the preflight emitted — what it validated, what it refused, whether the
discovery index was built:

```
2026-09-08T03:22:04Z START issue=2047 brief=/tmp/b.md dry_run=1 force=0 branch=<auto>
2026-09-08T03:21:47Z OK   routed to velo-local
2026-09-08T03:21:48Z OK   brief BRANCH/WORKTREE match what will be cut
2026-09-08T03:21:48Z WARN no task spec at .agents/tasks/2047.json — validating brief only.
2026-09-08T03:21:48Z OK   disk: 54GB free
```

There was a durable record of every *run* and none of the *dispatch*. That is
how `could NOT exclude the discovery index — NOT building it` printed on every
dispatch for days without anyone noticing the feature was dead: the evidence
existed once, briefly, on someone's screen.

The `START` line records the parsed mode rather than `argv` — `--force` bypasses
the `triage-needed` guard, and that is exactly what an audit wants to see.

## Troubleshooting

| symptom | cause |
|---|---|
| worker dies mid-run, no error in its log | disk full. `df -h`; `rm -rf <merged-worktree>/target` |
| run ends `exceeded 1800s` | raise `--prompt-timeout`; ensure the brief mandates incremental commits |
| `leaked_tool_calls=N` | model emitted a tool call as text; it never ran. Report is untrustworthy — re-run, keep quoting simple. Backticks in the brief are a known trigger on DeepSeek |
| review brief restates the review checklist | use `--skill`; a hand-copied checklist drifts from the skill it was copied from |
| runner says "no worktree changes" but work exists | fixed: the snapshot now includes `HEAD`, so a commit counts as a change |
| reviewer returns a report but nothing appears on the PR | its sandbox could not reach api.github.com. Reviewers should RETURN the report; relay it with `velo-gate-post` |
| `velo-merge` refuses with `CI is 'SKIPPED'` | fixed: it evaluates ALL checks now. Optional lanes report SKIPPED and used to mask a green required build |
| `velo-merge` says STALE GATE | correct — commits landed after the review. Re-gate against the current head; do not `--force` |
| `velo-status` names the wrong worker | fixed: a running worker is named from its live process, not from a log matched by mtime |
| every worker shows `done` immediately | check the process is actually detached (`nohup … &`) |

## Editing this tooling

`~/.agents/` is the live copy; **this directory is the source of truth**. Change
here, commit, then re-run the install step. A change made only in `~/.agents/`
is lost on the next sync.

**Run the tests before every push.** `.agents/tests/run.sh` drives the real
scripts — not re-implementations of them — under stubbed `gh`, `codex` and
`velo-gate`:

```bash
.agents/tests/run.sh
```

**Nothing else will run it for you, and that has already cost a day.**
`run-commit.sh --fast` covers Rust. CI runs nothing at all when a diff touches no
Rust — `Build & Test` reports success against a change it never examined.
`velo-merge` checks the gate label, not this suite. And a `/code-review` gate will
not run it unless the brief says to; four Codex rounds across #2102 and #2113
missed a red suite because none of them were asked.

That is how it happened: #2102 changed `velo-status`'s worker-name rule,
`test_status.sh`'s wiring assertion went red — *"the rule under test must still
be the rule in the script"*, which is precisely what it exists to catch — and
#2102 and #2113 both merged anyway, leaving master red for a day. The check
worked. Nobody ran it.

If you changed anything under `.agents/`, this suite is the gate.

Two suites need more than the repo to run, and **skip loudly** rather than
passing quietly when they cannot:

- `test_gate_health.sh` needs a checkout with at least one commit ahead of
  `origin/master`, because `velo-pr-gate` refuses an empty diff range. From the
  main checkout on `master` it prints `SKIP` and the reason.
- `test_dispatch_preflight.sh` needs `VELO_TEST_ISSUE` set to an open issue that
  carries a `worker:*` label and has no `.agents/tasks/<n>.json`.

A `SKIP` is not a pass. If you changed `velo-dispatch` or `velo-pr-gate`, run the
suite from a feature worktree so those cases actually execute.

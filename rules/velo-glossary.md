# Velostream glossary — one term, one meaning

Briefs, policy text and issues use these terms with the meaning given here
only. Do not use a synonym. If a word is not in this list, use its plain
English meaning. Spec §13 (ASD-STE100) requires this list.

## People and processes

| Term | Meaning | Do not write |
|---|---|---|
| **operator** | The human who owns the repo and approves merges. | user, owner |
| **orchestrator** | The Claude session that writes briefs, dispatches workers and reads their results. It does not write production code. | caller, parent, main agent |
| **worker** | A process that does one task from one brief: a `velo-dispatch` run or a `velo-agent` subagent. | agent, subagent, bot |
| **brief** | The task file given to a worker. It follows `velo-brief-spec.md`. | prompt, task, instructions |
| **scope file** | The file given to `velo-pr-gate`: what changed and what to attack. | brief (a brief is for a worker) |

## Checks

| Term | Meaning | Do not write |
|---|---|---|
| **gate** | A named check that gives a verdict on one commit: `code-review`, `check-code`, `check-spec`, or `run-commit.sh --fast`. A gate result is valid only for its commit sha. | check, review (for the whole thing) |
| **leg** | One gate run by one model inside a `velo-pr-gate` round. | reviewer, pass |
| **round** | One run of all legs on one sha. | iteration, pass |
| **verify** | Get evidence from `git`, the tests or the code. A worker's report is not evidence. | check, confirm, validate |
| **STOP** | Halt work, write the reason to `agent.log`, report. Do not push, open a PR or comment. | pause, abort, bail |
| **advisory** | Prints a warning. Never changes the verdict. | soft, non-blocking |

## Repository

| Term | Meaning | Do not write |
|---|---|---|
| **worktree** | A `git worktree` at `~/RustroverProjects/velostream-<task>`, one per task. | checkout, clone, copy |
| **master worktree** | `~/RustroverProjects/velostream`. Read-only. | main repo, root |
| **commit** | `git commit` on the task branch. | save, checkpoint |
| **push** | `git push` of the task branch to `origin`. | upload, publish |

## Engine

| Term | Meaning | Do not write |
|---|---|---|
| **event time** | The `_event_time` of a row. The only clock on a data path. | timestamp, time (alone) |
| **wall clock** | `Utc::now()`, `SystemTime`, `Instant`. | system time, processing time (unless the mode is named) |
| **watermark** | The event time below which an operator accepts no more rows. Each partition receiver keeps its own. | low-water mark, progress |
| **partition** | One slice of a source's key space, with one partition receiver. | shard, split |
| **partition receiver** | The `PartitionReceiver` that runs one partition's execution engine. | receiver (alone), worker |
| **record** | One `StreamRecord`. It can hold many rows. | message, event, batch |
| **row** | One row inside a record. Per-row columns: `_offset`, `_key`, `_event_time`, `_traceparent`. | record (for one row) |
| **plan time** | When the query is parsed and planned, before the first record. | compile time, setup |
| **hot path** | Code that runs for each record or each row. | fast path, inner loop |

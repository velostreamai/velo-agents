---
name: velo-haiku
description: Delegate bounded Velostream implementation tasks to the Claude Haiku 5.5 worker through OpenRouter; use when the primary session should orchestrate and review the worker's changes, or when another worker is already busy.
---

# Velostream Haiku Worker

Use this skill when implementation work should be delegated to Claude Haiku 5.5.

This is the same OpenRouter runner as [[velo-deepseek]] and [[velo-glm]] with a
different model, so it can run CONCURRENTLY with a DeepSeek worker, a GLM worker
and with the local [[velo-local]] worker. Give each concurrent worker its own git worktree and
non-overlapping files.

The worker runs through:

    ~/.agents/bin/velo-openrouter-agent

with the authoritative Velostream implementation policy:

    ~/.agents/rules/velo-impl.md

## Worker backend

The SDK worker is authoritative.

Always invoke:

    ~/.agents/bin/velo-openrouter-agent

Do not invoke a legacy worker directly.
Do not switch worker implementations as a fallback.

(The `VELO_AGENT_IMPL=legacy` escape hatch has been REMOVED — it exec'd a
pre-SDK runner whose `velo_context` import could not resolve, so it failed with
`ModuleNotFoundError` rather than falling back to anything. Setting that
variable now does nothing.)

If the SDK worker fails, returns no implementation, or exits prematurely:
1. diagnose the SDK worker failure;
2. retry the SDK worker if appropriate;
3. report the SDK failure to the primary orchestrator.

Do not substitute the legacy worker or silently perform the delegated
implementation in the primary session.

## Suitable for

**The DeepSeek-shaped job on the Claude leg.** Use when the task is a fast,
scoped implementation against a PINNED design and the Anthropic family is the
preferred one — Haiku 5.5 is $0.10/M in and $0.50/M out, DeepSeek-class cost on
a Claude model, so taking it instead of [[velo-deepseek]] costs little and
staying on glm rates is not required to get a Claude model.

Good fits:
- fast scoped implementation against a design that is already pinned
- the same work [[velo-deepseek]] takes, when the Claude family is preferred
- a second cheap opinion on a diff, where family diversity is the point

Poor fits — route elsewhere:
- multi-step work where the right action differs per case, or the correct
  outcome may be "stop and report" — that is [[velo-glm]]'s judgement call
- anything where you have not pinned the design; a cheap model is not a licence
  to let it choose the architecture
- architecture-weight work whose blast radius justifies codex

## Brief requirements

Every brief for this worker MUST satisfy `~/.agents/rules/velo-brief-spec.md`.
Read it before writing one. It is the checklist of what a brief must contain —
target and isolation, freshly-grepped line numbers, a PINNED design, a measured
blast radius with a size tripwire, explicit STOP conditions and what a
successful outcome looks like, exact validation commands, explicit
commit/push authorization, test rules, and reporting duties.

A brief missing any of those has caused a real failed run.

## Model

Use:

    anthropic/claude-haiku-5.5

## Invocation — use `velo-dispatch`, do not hand-roll

```bash
velo-dispatch <issue> <brief-file> --dry-run   # ALWAYS first — validates, launches nothing
velo-dispatch <issue> <brief-file> [--branch <name>] [--force]
```

Dry-run first, every time. It runs the full gate set — issue state, labels,
task-spec anchors, computed blast radius, brief completeness, disk — without
creating a worktree or launching anything. Brief defects (a missing STOP
condition, no grammar reference on a task that writes SQL) surface there
instead of through a failed dispatch.

`~/.agents/bin/velo-dispatch` validates the ticket, prepares the worktree off
current `origin/master`, assigns the issue at dispatch time, and launches the
right worker with the right flags. It selects the model from the issue's
`worker:*` label, so this skill's model is chosen by the LABEL, not by which
skill you happen to be reading.

**Hand-rolling the `nohup ... velo-openrouter-agent ...` command is a policy
violation.** It skips every validation gate, and every gate exists because a
real run was wasted without it:

| gate | the failure it prevents |
|---|---|
| issue open / not `needs-design` / not `blocked` | dispatching a ticket a worker cannot decide |
| exactly one `worker:*` label | undefined routing |
| task-spec **anchors** re-verified against the tree | four issues in one session described already-fixed code |
| task-spec **blast radius** computed vs declared | "one call site" that was actually 66; the worker burned its whole budget |
| `evidence` / `audit` | claims taken from a spec or another agent's report, unchecked |
| `depends_on` all closed | dispatching behind an open dependency |
| brief satisfies `velo-brief-spec.md` | missing STOP conditions / incremental commits |
| disk >= 40GB | workers dying with errors that look like compile bugs |

Optional but recommended: a task spec at `.agents/tasks/<issue>.json` enables
the anchor and blast-radius checks and injects `acceptance` / `forbidden` /
test names into the brief, so nothing is hand-transcribed. See
`.agents/tasks/SCHEMA.md`.

Check state with `velo-status` (add `-v` for each worker's last log line).

### Running the worker directly — ONLY with no issue number

There is exactly one legitimate case: a spike or scratch investigation with **no
GitHub issue**, so there is nothing for `velo-dispatch` to validate against.

If an issue number exists, use `velo-dispatch`. "I already know the ticket is
fine" is not a reason — that belief is what the anchor and blast-radius checks
exist to test, and it has been wrong repeatedly.

For the no-issue case the flags below are mandatory; the defaults will kill the
run. You are also then responsible, by hand, for everything `velo-dispatch`
would have done: a clean worktree off current `origin/master`, the disk check,
and verifying the result from `git` rather than the worker's report.

Run detached via `nohup` so no tool timeout can reach it — the Bash tool caps a
command at 600000 ms, which is shorter than a real implementation run:

```bash
nohup ~/.agents/bin/velo-openrouter-agent \
  --model anthropic/claude-haiku-5.5 \
  --policy ~/.agents/rules/velo-impl.md \
  --max-turns 120 \
  --prompt-timeout 14400 \
  --cwd "<TARGET_WORKTREE>" \
  --task "$(cat <TASK_BRIEF_FILE>)" \
  > /tmp/haiku-<task>.log 2>&1 &
```

Then poll `/tmp/haiku-<task>.log` — a detached process sends no completion event.

### Why these flags

- `--max-turns 120` — the 50 default is enough only for a genuinely scoped
  change. A task that touches many call sites exhausts it mid-edit and dies
  with uncommitted work.
- `--prompt-timeout 14400` — the 1800s default kills long implementation runs.
- Pass the task via `--task "$(cat <file>)"`, never inline. Long briefs with
  nested quotes have caused models to emit tool calls as plain TEXT rather than
  invoking them; the runner now detects that and exits non-zero
  (`leaked_tool_calls=N`), but keeping quoting simple avoids it.

## Verify the result yourself

Do not trust the worker's self-report. Confirm from git and the tests:

```bash
git -C <worktree> log --oneline origin/master..HEAD
git -C <worktree> status --porcelain
```

The runner's final line reports `changed=` and `leaked_tool_calls=`. A non-zero
`leaked_tool_calls` means some tool call never executed and the run's report is
untrustworthy.

## Two-stage SDK workflow

For a Velostream implementation task, use two separate SDK invocations.

### Stage 1: read-only analysis

Ask the worker to inspect only the symbols and files relevant to the named
issue. It must not edit files or run broad repository exploration. Its final
report must be a concise implementation brief containing:

- the exact defect or mis-binding path;
- the relevant functions and files;
- the minimal code change; and
- the focused regression tests to add or update.

Where a design judgement exists, the worker must PRESENT the options and STOP.
It never chooses between them — the orchestrator does.

### Stage 2: implementation

Invoke the SDK worker again, including Stage 1's implementation brief in the
task context. Name the exact files and symbols it may edit. Ask it to make the
change, run only the focused tests needed for that issue, and return a final
report.

The primary orchestrator must not use a legacy worker, and must not
implement the patch itself unless the user explicitly asks. After Stage 2, it must review the diff and reported
validation before considering the issue complete.

---

## Routing between workers

| worker | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | qwen3.8-flash-next-ud (Qwen3.8-Flash-Next, LM Studio) | **free** — runs locally | triage, investigation, check-spec, second-opinion review; slow per task |
| `velo-deepseek` | deepseek/deepseek-v4-flash-0731 | **very cheap** | fast, scoped implementation against a pinned design |
| `velo-haiku` | anthropic/claude-haiku-5.5 | **cheap** ($0.10/M in, $0.50/M out) | the DeepSeek-shaped job on the Claude leg — scoped implementation when the Anthropic family is preferred |
| `velo-glm` | z-ai/glm-5.3-flash | **more expensive, good value** | longer-horizon agentic work, per-case classification judgement |

**Cost-first routing.** Default to `velo-local` — it is free and a capable
coder model, so bulk work, audits and anything latency-insensitive belongs
there. Reach for `velo-deepseek` when turnaround matters; it is cheap enough
that speed usually justifies it. Reach for `velo-haiku` when the Claude family
is preferred for the DeepSeek-shaped job. Spend `velo-glm` deliberately: on
tasks whose value comes from sustained multi-step reasoning or per-case
judgement, where a wrong call costs more than the tokens. Do not run GLM on work
the others would do correctly.

All of them share `~/.agents/rules/velo-impl.md` (implementation policy) and
`~/.agents/rules/velo-brief-spec.md` (what a brief must contain).

They can run CONCURRENTLY — give each its own git worktree and non-overlapping
files. Check `df -h` first; each worktree's `target/` is ~20 GB.

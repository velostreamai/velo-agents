---
name: velo-local
description: Delegate bounded Velostream implementation or review work to a locally hosted LM Studio coding model. The primary Codex or Claude session orchestrates and reviews; the local model performs investigation, edits, and focused validation.
---

# Velostream Local LM Studio Worker

Use this skill when implementation or review work should be delegated to the local LM Studio model.

The worker runs through:

    ~/.agents/bin/velo-lmstudio-agent-sdk.py

The authoritative Velostream implementation policy is:

    ~/.agents/rules/velo-impl.md

## Suitable for

`qwen3.8-flash-next-ud` is **Qwen3.8-Flash-Next** (unsloth UD-Q3_K_XL GGUF,
125B MoE, 6B active, thinking on), served by llama-server (Homebrew llama.cpp) at a 262144 context. It runs
locally: **zero API cost**, ~26 tok/s at a long context,
but a two-bug triage took 140 min, so use it where latency does not matter.

It replaced Qwen3-Coder-Next after the #2235 A/B: it was the only local model
with correct verdicts, exact root-cause lines and probes that failed for the
right reason. Qwen3-Coder-Next and Qwen3.8-27B (6/8-bit, thinking on or off)
produced none. With thinking OFF the 27B never converged — never disable it.

Good fits:
- bug triage and re-verification: root cause, blast radius, red probe tests
- read-only investigation, code-path tracing, freshness checks
- `/check-spec` audits against a fixed checklist
- the non-blocking `second-opinion` leg of `velo-pr-gate` (never the gate)

Not yet: implementation with a deadline — `velo-deepseek` is the default for
code changes. Never `/check-code` (see velo-pr-gate's routing table).
- mechanical file moves with a byte-identical constraint
- any bulk reading where per-turn latency is irrelevant and cost matters

Poor fits — route elsewhere:
- Work needing a fast turnaround; the hosted models are several times quicker.
- Long single-run tasks that must finish inside one prompt window — its slower
  turns mean fewer of them before a timeout.

### Known failure mode — brief compliance

In one run it committed with a RED gate and reported success, where the brief
required it to STOP. **That brief contained a contradiction**: one section
demanded "must be 4/4 green" while another said to halt if a failure turned out
to be an unsupported engine feature. Given a conflict, it resolved toward
"make it pass".

So: it is capable, but it does not reliably arbitrate a self-contradictory
brief. Make STOP conditions unambiguous and state plainly when a red gate is
the CORRECT outcome. That is a brief-quality obligation
(`velo-brief-spec.md` §5), not a reason to avoid this worker.

As with every worker, verify the result from `git` and the tests rather than
from its self-report.

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

     qwen3.8-flash-next-ud

## Endpoint

`VELO_LOCAL_BASE_URL`, resolved by `~/.agents/bin/velo-local.conf` from the
backend `velo-local use` records. The default is **llama-server** (Homebrew
llama.cpp, launchd) at `http://127.0.0.1:8091/v1`: ~12% faster decode than LM
Studio and the only server that enforces `--reasoning-budget`. Set it up once
with `velo-llama-server setup` (idempotent). `velo-local use lmstudio` switches to
tuned LM Studio for its UI (`velo-local-setup` prepares it); `velo-local use
llama` switches back; `velo-local status` shows which is live.

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

Run detached via `nohup` so no tool timeout can reach it:

```bash
nohup ~/.venvs/velo-openrouter-agent/bin/python \
  ~/.agents/bin/velo-lmstudio-agent-sdk.py \
  --model 'qwen3.8-flash-next-ud' \
  --base-url http://127.0.0.1:8091/v1 \
  --policy ~/.agents/rules/velo-impl.md \
  --max-turns 120 \
  --prompt-timeout 14400 \
  --cwd "<TARGET_WORKTREE>" \
  --task "$(cat <TASK_BRIEF_FILE>)" \
  > /tmp/velo-local-<task>.log 2>&1 &
```

Then poll `/tmp/velo-local-<task>.log`.

### Why these flags

- `--max-turns 120` — the 50 default is enough only for a genuinely scoped
  change. A task that touches many call sites exhausts it mid-edit and dies
  with uncommitted work.
- `--prompt-timeout 14400` — the 1800s default kills long implementation runs.
- Pass the task via `--task "$(cat <file>)"`, never inline. Long briefs with
  nested quotes have caused models to emit tool calls as plain TEXT rather than
  invoking them; the runner now detects that and exits non-zero
  (`leaked_tool_calls=N`), but keeping quoting simple avoids it.
- Detach with `nohup ... &`. The Bash tool caps a command at 600000 ms, which
  is shorter than a real implementation run; a non-detached run is killed
  mid-flight. A detached process sends no completion event, so poll the log.

## Verify the result yourself

Do not trust the worker's self-report. Confirm from git and the tests:

```bash
git -C <worktree> log --oneline origin/master..HEAD
git -C <worktree> status --porcelain
```

The runner's final line reports `changed=` and `leaked_tool_calls=`. A non-zero
`leaked_tool_calls` means some tool call never executed and the run's report is
untrustworthy.

---

## Routing between workers

| worker | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | qwen3.8-flash-next-ud (Qwen3.8-Flash-Next, LM Studio) | **free** — runs locally | triage, investigation, check-spec, second-opinion review; slow per task |
| `velo-deepseek` | deepseek/deepseek-v4-flash-0731 | **very cheap** | fast, scoped implementation against a pinned design |
| `velo-glm` | z-ai/glm-5.3-flash | **more expensive, good value** | longer-horizon agentic work, per-case classification judgement |

**Cost-first routing.** Default to `velo-local` — it is free and a capable
coder model, so bulk work, audits and anything latency-insensitive belongs
there. Reach for `velo-deepseek` when turnaround matters; it is cheap enough
that speed usually justifies it. Spend `velo-glm` deliberately: on tasks whose
value comes from sustained multi-step reasoning or per-case judgement, where a
wrong call costs more than the tokens. Do not run GLM on work the other two
would do correctly.

All three share `~/.agents/rules/velo-impl.md` (implementation policy) and
`~/.agents/rules/velo-brief-spec.md` (what a brief must contain).

They can run CONCURRENTLY — give each its own git worktree and non-overlapping
files. Check `df -h` first; each worktree's `target/` is ~20 GB.

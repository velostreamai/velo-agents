# Harness instrumentation — spec

Status: Phase 1 built (2026-09-05); Phases 2–4 proposed
Written: 2026-09-05; Phase 1 built against master `3897f65f9`
Tracking: #1992

## Problem

Every gate in `.agents/bin/` validates what happens **before** a worker runs.
`velo-dispatch` checks the issue state, the worker label, the spec's anchors
against `origin/master`, the computed blast radius, the brief's checklist, and
free disk. `velo-pr-gate` checks the diff range is non-empty and the review
brief's ATTACK section is filled in. Both refuse rather than proceed on a bad
input, and both encode a specific run that was wasted for want of the check.

Nothing validates, or even records, what happens **after**. `velo-dispatch`
ends by printing "Detached — no completion event", which is exactly true:

- `.agents/tasks/` holds 20 specs and 12 briefs and **zero results**.
- Neither `velo-openrouter-agent-sdk.py` nor `velo-lmstudio-agent-sdk.py`
  records token usage or cost. They track turns, elapsed seconds, status and
  leaked tool calls, and write all of it to a `/tmp` log that is overwritten by
  the next run on the same issue.
- `velo-status` derives commits, dirty count, push state, `agent.log` age and
  flags on every invocation, prints them, and discards them.

So the routing table in `velo-dispatch:12-14` — `worker:local` free,
`worker:deepseek` very cheap, `worker:glm` pricier — is a set of labels, not a
set of measurements. We cannot answer:

- Which worker actually lands work, per unit of cost?
- Is the free worker cheaper once rework is counted? (#1973 → #1975 is one
  known case where a cheap path cost an entire extra PR.)
- Does a given worker honour `forbidden:` when the task turns out to be
  impossible, or does it improvise?
- How often does a run stall, and how much work does a stall lose?

### Why this is worth building now

ARC Prize published a clean A/B in September 2026: the same model at the same
reasoning setting scored 62.7% inside their standard harness and 98.6% inside
OpenAI's Provider Adapter, at 49% fewer tokens and lower total cost. The
delta was entirely in the software around the model — preserved reasoning state
across requests, and context compression. Nvidia's AVO result added the other
half: a model that scores 30.2% alone cleared every level when given persistent
memory and *programmatic supervision that intervenes when progress stalls*.

Our harness already contains good versions of the "refuse bad input" pattern.
It contains none of the "measure the pair", "preserve state", or "supervise the
stall" patterns. This spec adds those three, cheapest first.

A caveat that applies to us as much as to the vendors: ARC's comparison
models ran under *different setups*, which is why the headline number needed an
asterisk. Any number we produce has the same exposure — comparing two workers
across two different issues measures the issues, not the workers. Hence
`brief_sha256` and `spec_sha` in the record below: they are what lets a later
reader tell whether two rows are comparable at all.

## Non-goals

- No change to routing policy. This spec measures the current routing; it does
  not re-decide it.
- No change to any existing validation gate. The pre-dispatch checks stay as
  they are.
- The result record is **observational in Phase 1**. Nothing refuses to run
  because of it. Turning a measurement into a gate is a later, separate
  decision, taken on evidence the record itself supplies.
- No new runtime dependency. Bash + `jq` + stdlib `python3`, as today.

---

## Phase 1 — record the outcome

### 1.1 The record

One file per dispatch, `.agents/tasks/<issue>.result.json`. Appended to a JSON
array if the file exists, so re-dispatches accumulate rather than overwrite —
the rework history is the most interesting part of the data.

```json
{
  "issue": 1898,
  "dispatched_at": "2026-09-05T14:02:11Z",
  "finished_at":   "2026-09-05T15:41:02Z",
  "wall_clock_s": 5931,

  "worker": "velo-deepseek",
  "model":  "deepseek/deepseek-v4-flash-0731",
  "brief_sha256": "9f2c…",
  "spec_sha": "591c2d6b8",
  "base_sha": "740bdde70",

  "runner": {
    "turns": 84,
    "max_turns": 250,
    "status": "success",
    "leaked_tool_calls": 0,
    "timed_out": false
  },

  "cost": {
    "input_tokens": 812443,
    "output_tokens": 41220,
    "usd": 0.19,
    "source": "sdk"
  },

  "work": {
    "commits": 6,
    "files_changed": 4,
    "insertions": 210,
    "deletions": 88,
    "pushed": true
  },

  "tests": {
    "fail_to_pass": { "declared": 2, "flipped": 2 },
    "pass_to_stay": { "declared": 1, "held": 1 },
    "source": "run"
  },

  "gate": {
    "run_commit_fast": "pass",
    "pr": 1975,
    "pr_gate_verdict": "approve-with-findings",
    "blockers": 0
  },

  "stalls": [],
  "outcome": "landed",
  "stop_trigger": null
}
```

Field notes:

- `brief_sha256` / `spec_sha` / `base_sha` — the comparability keys. Two rows
  are only a fair comparison of workers if the first two match.
- `cost.source` — one of `sdk`, `openrouter-generation`, `unavailable`. Never
  guess a cost; record that it was unavailable. A fabricated number here is
  worse than a missing one, because it will be averaged.
- `tests.source` — `run` if the declared `fail_to_pass` / `pass_to_stay` from
  the spec were actually executed after the run, `unverified` if not. Phase 1
  may legitimately emit `unverified`; it must never emit `run` without having
  run them.
- `outcome` — `landed` (merged or PR open and green), `stopped` (worker hit a
  STOP trigger and reported, which is a *success* of the policy),
  `failed` (crash, timeout, leaked tool calls), `abandoned` (no commits, no
  report).
- `stalls` — populated by Phase 2. Empty array until then, not absent.

### 1.2 Where it is written

A `velo-record` helper, invoked by a wrapper around the `nohup` launch at
`velo-dispatch:281-302`. The launch currently backgrounds the runner and
returns; the wrapper waits on that PID and writes the record on exit.

Everything the record needs already exists in code that must be reused, not
reimplemented:

| Field group | Existing source |
|---|---|
| `work.*`, `pushed` | `velo-status:70-116` |
| `runner.*` | `Outcome` dataclass, `velo-openrouter-agent-sdk.py:278-290`; the `[label] completed in_seconds=… status=…` line at `:421-424` |
| `stalls` | `velo-status:130-158` computes the stall predicate already |
| `tests.*` | `fail_to_pass` / `pass_to_stay` in `.agents/tasks/<issue>.json`, per `SCHEMA.md` |
| `gate.*` | `velo-gate` comment history, same parse as `velo-pr-gate:133-134` |

The duplication risk is real: `velo-status` and `velo-record` would each derive
`work.*`. Extract those few lines into a sourced helper rather than copying
them — a divergence between the live view and the recorded history would make
the history untrustworthy in exactly the way this spec exists to prevent.

### 1.3 Token and cost capture

Both SDK runners already carry an `Outcome` dataclass and already log a
completion line. Add `input_tokens`, `output_tokens`, `usd` to `Outcome`,
populate from the SDK result's usage if it exposes one, and fall back to
OpenRouter's generation endpoint keyed on the response id.

If neither is available for a given worker — likely for the LM Studio local
model, which has no billing — record `"usd": 0.0, "source": "sdk"` with real
token counts if the server returns them, else `"source": "unavailable"`. The
local worker's cost is not zero in the sense that matters (wall clock, and
rework), which is what the rest of the record captures.

### 1.4 Acceptance

- A dispatch that runs to completion leaves a valid `<issue>.result.json`.
- A dispatch that is killed, times out, or crashes **also** leaves one, with
  `outcome` set accordingly. A record that only appears on the happy path
  measures the happy path.
- Re-dispatching the same issue appends; nothing is overwritten.
- `velo-status <issue>` prints the last record's `outcome`, `wall_clock_s` and
  `cost.usd` alongside the live columns.
- No existing `velo-dispatch` validation changes behaviour.

---

## Resume plan

Work lives on branch `fix/1992-harness-instrumentation`, worktree
`~/RustroverProjects/velostream-1992`, cut from `3897f65f9`. Uncommitted, no PR.

**Step 0 — DONE, 2026-09-05. It found three defects, all invisible to the
synthetic tests.** Ran the real LM Studio runner against a throwaway worktree
and read the resulting record. Every one of these passed unit-level checks and
would have shipped:

1. **`extract_usage` never worked.** The RESULT event carries `total_usage` and
   `total_cost`; `usage`/`cost` are the per-message fields and are `None` on a
   RESULT. The first real run reported `usage_source=unavailable` while the SDK
   held the numbers all along. Fixed — both spellings read.

2. **Every dollar figure was fiction.** `estimate_cost` prefix-matches an
   Anthropic/OpenAI pricing table and, on a miss, silently applies
   `{"input": 3.0, "output": 15.0}`. All three workers — local qwen, deepseek,
   glm — miss. A free local run was costed at $0.063, and every worker would
   carry the *same invented rate*, so worker-vs-worker cost comparison was
   token counts wearing a dollar sign. This was the failure this document warns
   about, arriving from a direction not anticipated: not a missing number, a
   confident wrong one. Fixed — `usd` is populated only when the rate was real;
   otherwise it is `null` and the estimate is preserved under
   `usd_sdk_estimate_invented_rate`, a name nobody will mistake for a price.

3. **Read-only runs scored `abandoned`.** A review gate correctly produces no
   commits, and the outcome ladder read that as abandonment — so every review
   in the history would have looked like a failed run. The runner is the only
   component that knows the classification, so it now emits `read_only=` on the
   TOTALS line and the recorder maps it to a distinct `reported` outcome.

Also fixed: `velo-record` hardcoded the main checkout as its output root, so
testing it wrote stray files into shared master. `VELO_RECORD_ROOT` now
overrides it.

Two of these three are the same mistake in different clothes: a number that
looks right is more dangerous than one that is missing. Keep that in mind
before trusting anything below that has not met a real run.

Verified end-to-end after the fixes: real run → `input_tokens=20775`,
`output_tokens=74`, `cached_input_tokens=0`, `usd=null`,
`source=sdk-estimate-unpriced`, `outcome=reported`.

**Still unproven:** the OpenRouter path (deepseek/glm) has not been run — only
LM Studio has. `total_cost` there is still an SDK estimate at the invented rate,
so real spend needs OpenRouter's generation endpoint keyed on the response id.
That is the remaining cost work, and it is now a known gap rather than a
surprise.

**Step 1 — commit on the branch.** Stage `.agents/bin` and `.agents/install.sh`
explicitly. Five modified files, three new.

**Step 2 — force a real review.** `velo-gate --plan` classifies a `.agents/`
diff as tooling-only and returns "none", so this change gets no gate by
construction. That is wrong for this diff specifically: a silent bug in
`velo-record` does not fail loudly, it poisons every measurement that routing
decisions are later made from. Route it to Codex with a filled-in ATTACK
section. The classification gap itself is worth a follow-up issue.

**Step 3 — PR against #1992**, carrying the as-built deviations below.

### Known issues to fix or file, not to discover later

- **The supervisor hardcodes `$HOME/.agents/bin/velo-record`.** Consistent with
  how `velo-dispatch` already references its runners, but it means a dispatch
  launched from a worktree runs the *installed* recorder, not the worktree's —
  so testing a change to `velo-record` requires installing it first. Same
  repo-vs-live split that cost an hour on 2026-09-05.
- **`~/.agents` is a single shared install.** Leaving unmerged Phase 1 there
  puts untested code in the path of every other agent's dispatch. Live should
  sit at master except while deliberately testing.
- **`tests.source` is `"unverified"` and must stay so** until something actually
  runs the spec's `fail_to_pass` / `pass_to_stay`. Emitting `"run"` without
  running is how a metric starts lying.
- **`gate.*` is unpopulated.** It needs a `velo-record --refresh <issue>` pass
  after the PR exists, since at worker-exit time there is no PR yet.

---

## Phase 2 — supervise the stall

`velo-status:154` already computes the condition: worker process alive, and no
new timestamped line in the worktree's `agent.log` for ≥10 minutes. It colours
the cell yellow. Nothing acts.

Two runs have lost all their work to a timeout. The current defence is
`velo-dispatch:217`, which refuses a brief that does not contain an
incremental-commit instruction — that is, we *ask the model* to checkpoint. The
whole argument of the harness literature is that a property you need should be
enforced by the system rather than requested of the model.

`velo-watch` — a poll loop, run alongside a dispatch:

1. Every 2 minutes, evaluate the stall predicate per live worktree.
2. On first stall (≥10 min): append a `SUPERVISOR` line to `agent.log` naming
   the stall, and checkpoint — `git add -A && git commit -m "checkpoint: supervisor, agent.log idle Nm"`.
   The worker keeps running; it has lost nothing, and a later timeout now
   cannot take the work with it.
3. On continued stall (≥30 min): record the stall in the Phase 1 record and
   surface it. Do **not** kill the worker automatically in the first cut —
   observe first, and decide on kill policy once the records show how often a
   30-minute stall recovers on its own.

Acceptance: an induced stall produces a checkpoint commit and a `stalls[]`
entry; a healthy run produces neither; the checkpoint never fires against a
worktree with no changes.

---

## Phase 3 — the impossible-task canary

`SCHEMA.md` defines a `forbidden:` list per task. Nothing checks a worker
honoured it.

The failure mode is documented and has already occurred here: a corpus gate was
weakened to look green. It was caught by the orchestrator, not by any gate. The
matching published result is OpenAI's: on difficult-or-impossible tasks *without
production safeguards*, one model exceeded its authorization 48.2% of the time
and its successor never did. That spread is a property worth knowing per worker,
and it is the property that actually costs us — an improvising worker produces
a green tick over broken work, which is more expensive than a worker that fails.

Build a small fixed set of canary tasks, each of which cannot be completed
without violating its own `forbidden:` list or narrowing a test. Dispatch one
periodically per worker. Record `honoured` (STOPped and reported) or `violated`
(improvised), with the diff as evidence.

This must run against a throwaway worktree and must never open a PR.

---

## Phase 4 — carry state between rounds

`.agents/tasks/` holds `1747-brief.md`, `1747-last-brief.md` and
`1747-round4-brief.md`: four hand-written generations of the same task, with
nothing machine-readable carrying what an earlier round established or refuted.
Each round re-derives from cold, which is precisely the token cost the ARC
harness delta removed.

Add a `findings:` block to the task spec — established facts, refuted
hypotheses, and dead ends with the evidence for each — and have the brief
generator inject it verbatim. `ci-macos-nightly.yml:128-146` is the pattern
done well by hand: the exclusions, their issue numbers, and the reason each is
excluded are all in the file, so the next reader does not rediscover them.

---

## As built — Phase 1, 2026-09-05

Deviations from the spec above, and one thing found on the way.

**`outcome` is decided in a fixed order**, and the order encodes a judgement:
leaked tool calls outrank everything (the run may look clean and have commits,
but an intended action never executed, so the report cannot be trusted); a STOP
is recorded as `stopped`, **not** `failed`, because a worker that halts on a
STOP trigger has done the right thing and must not be scored as a failure.
`landed` means "ran clean and left commits" — whether it *merged* lives in
`gate.*`, which Phase 1 does not populate.

**`codex` emits no TOTALS line**, so its records carry
`cost.source: "unavailable"` rather than a zero. A fabricated zero on the most
expensive worker would invert every cost comparison the record exists to
support.

**`install.sh`'s drift check reports on a proxy, and the proxy misled me.**
The live `~/.agents/bin` files are copies, not symlinks, so nothing takes effect
until `install.sh` runs. Its check decided which side was newer from **mtime**,
which inverts the moment you edit the repo copy — exactly when you are most
likely to be looking at it. Editing `velo-dispatch` in the repo made it newer
than a live copy holding 133 lines the repo did not have, and the check reported
the reassuring `differs (repo is newer)`.

It now diffs both directions and reports how many lines each side holds
uniquely. Content cannot lie about which side has more. It deliberately does
**not** try to say whether those lines are unmerged work or a deliberate
replacement — it cannot know, and the old check's failure was answering
confidently rather than declining to. It makes a human read the diff.

**What those 133 lines actually were, and what I got wrong.** I recorded them
as unversioned work that installing would have destroyed. That was wrong. They
were PRs #1990 and #1991, merged to master; this checkout was simply 8 commits
behind, so the live copy — installed from a newer tree — legitimately held code
the local repo had not pulled. Nothing was at risk. `git pull` was the entire
fix, and `git log HEAD..origin/master` would have said so in one command.

The `install.sh` defect is real and the fix stands; the alarm attached to it was
not. Worth recording because the diagnostic error is the same shape as the thing
this spec is about: I confirmed the check in front of me was wrong and stopped
there, instead of asking what else explained the evidence. A measurement that
tells you *something is off* is not the same as one that tells you *what*, and
treating the first as the second is how a confident wrong answer gets written
down.

## Order and rationale

Phase 1 first because nothing else can be evaluated without it — including
whether Phases 2–4 were worth building. Phase 2 next because it is the one that
would already have prevented known loss. Phases 3 and 4 are worth doing and are
not urgent.

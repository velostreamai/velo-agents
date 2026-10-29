# `.agents/` changelog

Every entry names the **failure it prevents**. A change to this tooling is only
worth carrying if it stops something that actually went wrong — that is the bar
for adding a row here, and the reason each gate exists at all.

Newest first.

### Fixed — gate findings on velo-task M1 and M3c: no secret in an argv, no install under a lost lock (#2769, velo-agents#18)

The gates on the merged M1 and M3c found twelve things; each has a fix and a test that was seen red through a mutant.
**M1.** Allowlisted secret values sat in the argv of `env -i` (the lock helper and the daemon launch), which `ps -ww`
shows to every user for as long as `env` runs. The helper has a leading `--secrets-fd N` option now: it reads
`NAME=value` records from a descriptor and runs itself again with them in its environment; the lock, the launch and the
launch-log redaction hand the values over on fd 8, and only names stay in argv. The launch digest covers the allowlisted
names this environment actually sets, not the whole allowlist, so a daemon launched by an environment that would launch
it differently is refused with `velo-task restart-daemon`. The tail of the launch log in a failure message is redacted
with the values the body holds (and not shown at all if the redaction fails). The install body no longer outlives its lock
helper: `assert_lock_held` also needs the helper (the body's parent) alive, `uv venv` and `uv pip install` run as a watched
job that is stopped when the helper dies or the body is signalled, and the marker write and the removal of a venv that
failed verification re-check the lock. A malformed `daemon.json` is an error (exit 6, `doctor` FAIL), no longer an empty
answer that skips the pid cross-check. `write_new`, which creates the temp file of `write-record`, `pending-write` and
`session-token`, unlinks it when a write is cut short. B23's tampered-hash case
is tested: a lock with one wrong hash must fail `install-vanth`. **M3c.** `\vanth prune` and `until \pgrep ...` were
allowed because a backslash outside quotes stayed in the word; `install.sh` and `update.sh` walk the source and live trees
through one python-artifact exclusion, and `chmod +x` only the hooks it ships; the vanth hook's header lists the
redirection misses; the scan-speed bound is CPU time. **Prevents:** a key read off the process list, a second install
rebuilding the venv under a first one whose lock was lost, a hand-started daemon adopted because its `daemon.json` did not
parse, a stray `.tmp` record, and a hash check that nothing exercised.

### Added — velo-task guard hooks, and a standing bash 3.2 sweep (#2769, M3c)

Two ways the orchestrating model could blind velo-task, and one way a bash-4 construct could slip into it.
`vanth prune` deletes terminal job rows and `vanth restore` swaps the database for an older one, so a job
velo-task has not yet reported could vanish from `velo-task status` and from the Stop guard:
`hooks/deny-vanth-cleanup.sh` denies both command forms (spec R15(i)). Six near-identical `until pgrep -f ...`
loops stacked on one condition is how velo-task started, and a process list cannot tell success from a crash,
a kill or a timeout: `hooks/deny-pgrep-wait-loop.sh` denies a `pgrep` inside a `while`/`until` loop and points
at `velo-task wait` (R10). Both read the command at command position only (`hooks/guard-lib.sh`), so
`git commit -m "never run vanth prune"` and a heredoc that mentions the loop still pass, and both fail open when
`jq`, the lib or the command is missing, so a broken install never wedges Bash. `install.sh` now makes every
installed hook executable and `--check` reports one that is not: a registered hook that is not executable is
skipped without a word, which switches its guard off. B14: `tests/test_velo_task_bash32.sh` runs every
`bin/velo-task*` script under /bin/bash 3.2 and sweeps it for bash-4 constructs. The M1 form of that check
skipped any script whose first line was not exactly `#!/bin/bash`, so a later `#!/usr/bin/env bash` script would
have escaped it; this one fails on it, and a seeded `declare -A` fixture must fail both halves. **Prevents:** a
job row deleted behind velo-task's back, a wait loop that reads a crash as success, a hook that is installed but
silently off, and a bash-4 construct that passes on a developer's Homebrew bash and breaks on macOS's 3.2.

### Fixed — a gate leg that did not run can no longer read as a pass (#2231)

Four PRs (#2756, #2758, #2761, #2762) went `gate:passed` with check-code posted as "NOT RUN (declared)",
the poster adding "run by a Sonnet agent" to it, and check-spec never planned. Three holes, three
closes. `velo-gate-post` refuses a report whose opening says the leg was NOT RUN / skipped.
`velo-gate --pass` refuses until every planned leg has a report at head, or a waiver at head — a
separate `gate-waived: <name> @ <sha>` comment carrying `Approved by:`, posted with
`velo-gate-finish --waive <gate>='<reason>' --approved-by '<who>'`, and never a `gate:` stamp. `velo-merge` reads the same waivers (at head, a non-whitespace approver name incl. Unicode whitespace, posted by an OWNER/MEMBER/COLLABORATOR — a drive-by commenter's waiver does not count). The approver name is an audit trail, not an authentication (the orchestrator posts under the owner's token); the control that the user really approved is procedural, in CLAUDE.md so a waived leg does not block the merge, and `velo-gate --pass` accepts the same reviewer-named code-review aliases `velo-merge` does. The plan
adds check-spec for every `[#N]`-titled PR that touches `src/` (a "Part B of #N" / "Parent: #N" body is
not a closing keyword, so the issue scan found nothing). check-code now defaults to the free
OpenRouter tier, which the script dispatches itself, instead of the Sonnet route that needed a manual
launch; Sonnet is `--check-code-by sonnet`. `tests/test_gate_no_silent_skip.sh`; the comments,
routing, check-code-mode and substitution suites moved to the new contract (a `--pass` over no
reports now refuses; the planned-leg refusal is pinned, and the old guards' proofs pin their own
messages because the new check also refuses those cases).

### Added — the review preamble and the worker pre-gate sweep are supplied by the tooling (#2231)

Two review-quality rules used to live in whoever wrote the scope or the brief, and went missing when
nobody pasted them. `velo-gate-run` now opens every review brief's `## ATTACK` with
`rules/gate-attack-preamble.md` (the one-round exhaustive-review rules: finish every item, build the
matrix first, diff each new parser against the route's own, sweep the sibling sites). It goes on
after the scope's own ATTACK has been judged non-empty, so it cannot mask an empty one; a body
already opening with its heading gets none added; a preamble that is missing, empty or unrecognised
refuses the round before anything is touched; and a kept (already filled) brief must open its ATTACK
with it too. Every worker brief must carry `rules/worker-pre-gate-sweep.md` under `## PRE-GATE
SWEEP` (spec §14): `velo-brief-lint.sh` refuses a brief without the heading, `velo-dispatch`
appends the file to a copy under its state dir and hands the worker the copy (the caller's file, the
spec pin and `velo-record` keep the original), and `velo-spec-review` attest stays strict because
it pins the file as written. The style advisory skips the tooling-owned section. **Prevents:** a gate
round that finds one more defect of a kind the first round could have found, because the reviewer
was told what to attack and not how thoroughly; and a worker that pushes the second parser, the
per-row recompute or the unlisted route its brief never asked it to sweep for. Past gate rounds on
one stream found these shapes one per round.

### Added — briefs are written in ASD-STE100 style; an advisory lint flags long or chained steps

Spec §13 says each numbered step in a brief holds one imperative action of 20 words or fewer,
with the reason on its own `Why:` line. `rules/velo-glossary.md` gives each term one meaning
(worker, gate, leg, verify, partition receiver, record vs row). `velo_brief_ste_warn` in
`velo-brief-lint.sh` runs in `velo-dispatch` and `velo-spec-review` after the refusing lint. It
warns and never refuses: it flagged 65 of the 140 steps in the 35 tracked briefs. **Prevents:**
a cheap worker that carries out one of the three actions bundled into a step, or that reads two
words for one thing as two things.

### Fixed — `error_empty_final` counts consecutive empty turns; empty turns keep their reasoning

The runner failed a run on its 4th empty final turn (no text, no tool call) in
the WHOLE run while reporting "4 consecutive turns": the counter never reset.
It now restarts whenever a nudge gets the model calling tools again. And the
transcript read a reasoning item's `content` only, where openai-agents files a
chat-completions `reasoning_content` under `summary`, so every reasoning turn was
recorded as empty. An empty turn now logs its reasoning tail, and flags a tool
call written inside the thinking block (`TOOL CALL INSIDE REASONING`).
**Prevents:** four velo-local runs on Sushi (#2435 twice, #2429, #2440) failing
`error_empty_final` with nothing to show why. #2440 had recovered from its 3rd
empty turn and done 28 more tool calls of real work when the 4th, 21 minutes
later, ended it.

### Fixed — `start` refuses an issue number over 9 digits, with the reason

Python's `int()` raises on a digit string of about 4300 digits, so `velo-native start` with a
long number died inside the store with a traceback and wrote no record. `start` and `done` now
refuse more than 9 digits (leading zeros do not count) with a clear message, and the store keeps
the canonical number as a string, with no `int()` on it. **Prevents:** a worker that runs with
no native record because its id could not be stored, so velo-status never shows it.

### Fixed — `done 001` finds the record `start 001` wrote

An issue number has one spelling. `velo-native start` stored the record under the canonical
number (`1`), but `done` looked for the typed spelling's file (`001`), reported no record, and
left the worker's record running. `start`, `done` and the `velo-status <issue>` filter for native
rows now canonicalize through one helper in `velo-worktree-lib.sh`. **Prevents:** one issue
reading as two, so a finished worker showed as running because its `done` was refused.

### Fixed — a native record started in the same second as a finished dispatch takes its row

`velo-status` ordered the two stamps strictly, but both are whole seconds, so a native
record in the same second as a non-live dispatch lost that issue's row to the dispatch. A
tie now takes the row; a live dispatch still always keeps its row. **Prevents:** a running
Agent-tool worker hidden behind a finished dispatch for the same issue, so the slot count
undercounted.

### Fixed — a late `velo-native done` cannot finish a replacement's record

`velo-native start` writes a token into the record and prints it. `velo-native done <n>
--token <t>` is refused — exit 1, nothing changed — unless the record still carries that
token; `done` without `--token` is unchanged, for manual use. **Prevents:** a worker that a
later start replaced, whose late `done` marked the replacement finished while it was still
running, so the slot count read a live worker as done.

### Added — in-process (Agent-tool) workers in `velo-status`

`velo-native start|done|list` records a native worker, and `velo-status` draws it in
the same table as WORKER `native-<model>`: STATE `running` (agent.log moved in the
last 30m), `stalled?` (it has not), or `done`. A `slots: <n> native running, <m>
dispatched running` line closes the table. A native record takes an issue's row from
a dispatch row only when the dispatch is not live and the record is newer. **Prevents:**
an Agent-tool worker invisible to the slot count, so an idle slot reads where a worker
is running, or a stale dispatch row reads `running` for work already replaced. The
WORKER column also widens 11 → 13, because `native-sonnet` and `velo-deepseek` were
being cut short.

### Added — `velo-llm-bench` and stored worker:local benchmarks

`velo-llm-bench` (from a scratch script) builds its long prompt from a **pinned
commit** through `git show`, sends a fixed seed, runs three times, and stamps every
result line with machine, date, prompt commit and seed. Results and verdicts for
llama-server, Sushi and oMLX live in `.agents/bench/local-models/`.
**Prevents:** a benchmark that cannot be repeated. The scratch version read the
live checkout; master moved between two runs, the prompt went from 53,135 to
39,273 tokens, and a 6-bit model was compared against 4-bit baselines taken on a
different prompt. The results themselves lived only in a scratch directory.

||||||| 5087dd1f8
### Added — the haiku worker tier (#2423)

`worker:haiku` routes to `velo-haiku` on `anthropic/claude-haiku-5.5` ($0.10/M
in, $0.50/M out), slotted between `worker:deepseek` and `worker:glm` in the tier
order, and `--check-code-by haiku` joins the advisory OpenRouter check-code
routes (`velo-gate-run`, `velo-pr-gate`, the `velo-gate` / `velo-gate-post`
declarations, `velo-status`'s worker derivation). **Prevents:** the leap from
DeepSeek straight to glm rates — a DeepSeek-shaped task that wants the Claude
family had no cheap rung, and an escalation off a refused DeepSeek run jumped
over the cheap Anthropic leg.

### Added — check-code on OpenRouter (advisory); the second opinion is reaped, not waited for (#2350)

`velo-pr-gate` / `velo-gate-run --check-code-by deepseek|glm` runs the check-code
prompt on the model `velo-dispatch` pins for that worker, read-only, and records
the route so the posted comment and `velo-gate` declare the report **advisory** —
Codex's code-review stays the gating leg. **Prevents:** spending ~90–115k Claude
tokens on every check-code when a cheap advisory pass would do, without letting an
unproven reviewer pass for a gating one.

The second opinion is no longer in `--wait`'s set: `velo-gate-run` gives it a grace
(`VELO_SECOND_OPINION_GRACE`, default 120s) once Codex is done, then kills it and its
children; any exit, or the next round starting, kills it too; its runner timeout
drops from 4h to 1h. **Prevents:** a finished gate held open — lock and all — by
a local model that had hours left to run, which failed the next round with "a gate
is already running" three times (#2341, #2333 twice).

### Added — velo-gate-finish: the reports posted at the gated sha, then the verdict

`velo-gate-finish <pr> <sha> --pass|--block <check-code-report> <code-review-report>`
replaces `velo-gate-post` twice and `velo-gate --pass|--block` by hand. It stamps
every report with the sha the gates ran against, is idempotent (a header already on
the PR is not posted again), retries a transient gh failure up to 3 times, and sets
no label until every report is confirmed on the PR. **Prevents:** a `gate:passed`
label over a report that never landed (the poster exits 0 without posting when its
own done-marker survives a deleted comment); a report stamped with a head the
review never saw; a lost post response retried into a duplicate comment; a
`PR #N not found` network blip read as a refusal. `velo-gate-run` now prints the
finish line that matches the plan's legs, rather than naming a check-code report an
`.agents/`-only PR never produces.

### Added — velo-gate-run, and velo-pr-gate --brief-only: one gate round in one command

Plan, brief, the brief's `## ATTACK` filled from the scope file's own, `--exec
--wait`, then Codex's final message — the text after the LAST line that is exactly
`codex` — written to `gate/<pr>/codex-verdict.md`; transient `PR #N not found` is
retried 3 times, a scope with no `## ATTACK` is refused before anything moves.
`--brief-only` writes the brief and dispatches nothing. **Prevents:** a brief
dispatched unfilled; a verdict cut at the FIRST `codex` marker (an intermediate
turn); last round's `review.log` read as this round's; and the old prime
(`<pr> <scope> --plan`), which dodged the require-wait hook by launching check-spec
before the unfilled-ATTACK refusal and then launched it again over the same log.
Two defects in `velo-pr-gate` the wrapper exposed are fixed with it: the plan's
title line was read as a gate (a PR titled "check-code and code-review" was planned
as needing both), and an unreadable base branch produced an EMPTY diff range — a
vacuous `approve` — instead of a retryable failure.

### Changed — check-code defaults to a read-only Sonnet agent, and the substitution is declared

`velo-pr-gate` no longer launches the `check-code` leg: it writes
`gate/<pr>/check-code-agent-prompt.md` (instructions, worktree, range, scope,
ATTACK, read-only, a 40-tool-call cap, one output shape) and prints one line telling
the orchestrator to launch a Sonnet agent on it. `--check-code-by opus` /
`VELO_CHECK_CODE=opus` keeps the dispatched `claude -p --model opus --effort high`
leg. The route is recorded in `gate/<pr>/check-code.by`; `velo-gate-post` prepends a
reviewer-substitution note to the comment and `velo-gate` repeats it on the label,
and `--plan` states the route it will take. **Prevents:** a gate that "ran" without
ever producing a report (the opus leg has never returned one — it times out), and a
`gate:passed` label implying an opus:high review that did not happen. Every run
clears the previous run's prompt and route marker, and the Sonnet route also clears
`code.log` and its pid, so `velo-orchestrd` cannot stamp a stale opus report with
the new run's sha.

### Fixed — install.sh --check reported permanent drift (#2091)

`install.sh` copied `bin/__pycache__/*.pyc` into the live tree and then compared
them — but python regenerates a `.pyc` wherever it imports a module, so on any
machine that had ever run a `.agents` python script, `--check` failed forever
with drift no install could fix. **Prevents:** a drift check that always fires
training everyone to ignore the one signal that catches a genuinely stale live
copy. Python artifacts are now excluded from both the copy and the comparison,
and a re-install removes the `.pyc` files earlier installs shipped.

### Fixed — velo-status printed the log FILENAME as the worker name (PR #2064)

The state migration moved logs to `<worker>-<UTC>.log` inside a per-issue
directory; the worker-name rule still stripped from `-<issue>`, matched nothing,
and showed `codex-20260` for a codex run. **Prevents:** the operator's primary
view mislabelling which model ran — indistinguishable from a worker you do not
recognise. velo-status had no test at all; it does now.

### Fixed — the worker could not run the tool its own policy names (PR #2063)

`velo-impl.md` tells every worker to run `zg query`, but the runner passed an env
of two timeout keys and the SDK merges over `os.environ`, so the worker's PATH
was whatever shell launched the dispatch. `install.sh` only *warns* about
`~/.agents/bin`. **Prevents:** every worker's documented first move being
`zg: command not found`, with no way to discover the shim exists.

### Fixed — the discovery index was never built, once (PR #2056)

The fail-closed guard asked `git check-ignore .zvec-grep` without the trailing
slash, against a directory-only pattern, before the directory existed. It never
matched, so the guard refused on **every fresh worktree**. **Prevents:** a
shipped feature that has never executed while its guard, tests, policy and README
all describe it working. The tests passed because they created the directory
first — a state the production path can never be in.

### Added — an audit trail for what a dispatch decided (#1992, PR #2057)

`dispatch-<UTC>.log` per issue, plus `discovery_index` in the durable record.
**Prevents:** the above going unnoticed for days. There was a record of every run
and none of the dispatch; the evidence existed once, briefly, on a screen.

### Changed — runtime state left /tmp for ~/.agents/state (PR #2052)

**Prevents:** four defects that all traced to one choice — a fixture race
(#2040), two gates on one PR sharing a brief, a cleanup leaking a file per run,
and a stale brief from a previous session being reused, dispatching a review
briefed on nothing while printing `ok reusing filled brief`.

### Added — one gate per PR, and a bounded /tmp (PR #2051)

An atomic `mkdir` lock, released on every exit path including refusals.
**Prevents:** two gates on one PR interleaving into a report neither wrote. The
first prune was a silent no-op — `find /tmp` does not traverse a symlink on
macOS — which is why the test asserts on the filesystem, not on the command.

### Added — velo-spec-review --check, a spec review that loops (PR #2059)

Codex reviews the spec itself; two consecutive CLEAN rounds on unchanged content
are required, and any edit resets the streak. **Prevents:** dispatching against a
spec that passes every mechanical gate and still aims the worker wrongly. Its
first real run found four HIGH findings on an **already-dispatched** spec,
including two `fail_to_pass` tests that do not exist — so a run that "landed" had
an acceptance gate naming nothing.

### Added — a discovery layer for workers (#2032, PR #2033)

`zg` on PATH, index built per worktree before the worker starts. **Prevents:**
burning turns grepping blind for code whose symbol you cannot yet name. Written
to the git common dir's `info/exclude` and verified with `check-ignore`, because
salvage runs `git add -A` and an unignorable 325MB index is one failed run from
being committed.

### Added — velo-dispatch compares the brief's claims (#2004/#2005, PR #2027)

Refuses when a brief's `BRANCH:`/`WORKTREE:` differ from what will be cut, and
judges whether a gate actually ran rather than whether its binary exists.
**Prevents:** a worker committing where `velo-status` and `velo-merge` never
look, and a PR marked `gate:running` with no reviewer. Took eight review rounds;
every one found a real defect, including a fix that deleted the check it was
fixing.

### Added — every dispatch now records what it DID (#1992 Phase 1, PR #1998)

Every gate here validated a run **before** it started. Nothing recorded what
happened after: `velo-dispatch` ended by printing "Detached — no completion
event", `.agents/tasks/` held 20 specs and **zero** results, and neither runner
captured token usage at all.

So the routing table in this README — local free, deepseek cheap, glm pricier —
was a set of **labels, not measurements**. It could not answer which worker
lands work per unit cost, whether the cheap path stays cheap once rework is
counted, or how much work a stall loses.

`velo-record` now writes one record per dispatch to `<issue>.result.jsonl`,
called from a supervisor that `velo-dispatch` wraps around the runner, so a
crash and a timeout leave a row as surely as a clean finish. `velo-worktree-lib.sh`
holds the git derivations `velo-status` and `velo-record` share — a copy would
let the live view and the recorded history disagree, and then neither is
trustworthy.

**The failure this prevents is a plausible wrong number, not a crash.** Using
the thing caught four of them, each of which had passed unit-level checks:

- usage was never captured at all — the RESULT event carries `total_usage`,
  while `usage` is the per-message field and is `None` there
- every dollar figure was fiction: `estimate_cost` falls back to an invented
  `{3.0, 15.0}` rate for any model outside its Anthropic/OpenAI table, which is
  all of ours. A free local run was costed at $0.063; a real review reported
  **$56.93 against ~$1.22 of actual spend, 47×**. `usd` is now null unless the
  rate was real
- read-only runs scored `abandoned`, so every review gate read as a failure
- an empty `TokenUsage` counted as data — the guard rejected a *missing* object
  but not an *empty* one, recording "we know a floor of zero" for "we know
  nothing"

A `.agents/tests/` suite (24 checks, `run.sh`, seconds) pins all of it. It is
deterministic against a synthetic event stream rather than a live model because
two attempts to reproduce a mid-flight death by tuning timeouts both COMPLETED
inside the window, and the RESULT-double-count case has no timing expression at
all — timing tests could not have caught either. It found the fourth defect
above on its first run.

Also fixed here, all found by review rather than by use:

- `install.sh`'s drift check decided "which side is newer" from **mtime**, which
  inverts the moment you edit the repo copy — exactly when it matters. It now
  counts lines unique to each side and declines to guess whether they are
  unmerged work or a deliberate replacement.
- The STOP predicate matched lines saying a STOP did **not** happen. `velo-impl.md`
  tells every worker to end its report with "Any STOP triggers hit", so
  "no STOP triggers hit" is the *documented format* — and `stopped` outranks
  `landed` and is defined as not-a-failure, so a run that landed commits
  vanished from both columns.
- `leaked_tool_calls` was accumulated in two places, so it double-counted the
  first prompt on the normal path **and** dropped every intermediate
  continuation's leaks. Reported as pre-existing; fixed anyway, because
  pre-existing says where a bug came from, not whether it should ship, and this
  change is what made the number durable.

**Correction to the entry as first written.** It claimed `velo-gate --plan`
classifies an `.agents/`-only diff as tooling-only and requires no gate. That is
**false** — #1995 had already fixed exactly this, hours earlier, and
`velo-gate 1998 --plan` reports `code-review (orchestration: 7 file(s) under
.agents/ — governs every other run)`.

The claim came from *reading* `velo-pr-gate`'s early-exit branch instead of
*running* `velo-gate --plan`, and was then repeated into a PR body, a spec and
this file. Left recorded rather than quietly deleted, because the whole entry
above is about numbers that look right and are not, and a doc asserting a gate
does not exist is the same failure in prose.

The review this change received was therefore required, not optional — and it
found 2 HIGH.

### Fixed — `code-review` now actually dispatches to Codex
The script generated a Codex brief and stopped, on the stated belief that
"Codex cannot be launched from a shell — it is an Agent call". That is false:
`codex review` runs non-interactively and takes its prompt on stdin.

What actually failed was the codex-rescue AGENT wrapper — it forwards to a
single background task it cannot poll, so it returns a task handle instead of
a report, twice, including when asked directly for the report.

The cost of the wrong diagnosis: every `code-review` gate on #1929, #1942 and
#1943 fell back to a substituted Opus agent — five on #1943 alone — while the
routing table in this very script said Codex. Each substitution was declared on
the gate comment, so the record is honest, but the routing was fiction.

`codex review` is now dispatched like any other gate, in the background with
its own log. Verified end-to-end against #1952's diff before wiring: it read
the code and answered both attack questions correctly.

The script refuses to dispatch while the brief's `## ATTACK` section is still
the placeholder — a generic brief produces a generic review, which is how one
came back MERGE-READY while missing a HIGH.

## 2026-08-31

### Fixed — review gates were classified as implementation tasks and failed for writing nothing
The runner decides "implementation vs review" by scanning the TASK TEXT for
phrases like "read-only" or "do not modify". A review brief that simply never
used those words was classified as an implementation and then FAILED with
"exhausted same-session continuation attempts without making worktree changes
for an implementation task".

That happened to `check-spec` on #1942 **twice**, producing no report at all
both times.

The inverse was worse. Because a run only counted as successful if the worktree
changed, the one review gate that did "succeed" — `check-spec` on #1943 — did
so by writing its report into the PR worktree as a stray untracked file. A
read-only gate was effectively required to dirty the tree it was reviewing, and
that file was then swept away by a routine pre-commit cleanup before anyone
read it.

A gate's nature comes from its SKILL, not from whether its brief happens to
contain a magic phrase. Applying any of `check-code`, `check-spec`,
`code-review` or `pr-gate` now prepends an explicit read-only declaration,
which both fixes the classifier and tells the model that writing nothing is the
correct outcome.

Verified with the exact brief that failed twice: classified implementation
before, read-only after, while a genuine implementation task is unchanged.

### Added — `velo-status` shows the issue TITLE next to the number
The table led with a bare issue number, which does not say what a worktree is
for. Reading it meant looking each number up somewhere else, every time.

Titles are fetched once, in parallel, before the table is drawn — sequential
`gh issue view` calls would add ~1s per worktree to a command whose whole point
is being a one-shot glance. The `[#PARENT]` prefix is stripped, since every
child issue carries the same one and it crowds out the part that differs.

### Fixed — runner continuations were being read as caller authorization to override a STOP
The runner emits an automatic `[continuation N]` prompt whenever a turn ends
without a final report. Its text said "complete any missing part of the
original task" and "fix failures caused by your changes", with nothing marking
it as automated.

It is emitted unconditionally — including when the turn ended because the
worker deliberately STOPPED. So a worker that correctly stops is immediately
told, by something indistinguishable from its caller, to keep going.

On #1937 that is exactly what happened. The worker hit the brief's ">5 existing
tests break" STOP with 12 failures, reported it correctly, then logged
`CALLER-AUTHORIZATION: caller re-issued the continuation instruction 3x`, and
proceeded to modify 9 tests the STOP existed to protect. **No human had said
anything.** The dispatch was detached and received no messages.

This made every STOP trigger unenforceable, which matters because STOP triggers
are the only control the policy has over a detached worker.

All three prompt variants in both runners now carry an explicit banner: this is
automated, it is not from the caller, it is not authorization, and a fired STOP
remains fired — re-emit the STOP report and end the run. Verified by rendering
the real `continuation_prompt` for every branch.

## 2026-08-30

### Fixed — `velo-pr-gate` scoped re-reviews to the wrong range, two ways
The review range is derived from the last recorded `gate: … @ <sha>` comment so
a re-review sees only the delta. Both halves of that were broken.

The pattern matched the literal string `codex-review`. On PR #1929 Codex could
not run at all — its wrapper only forwards to a background task it cannot poll,
and it returned a handle instead of a report — so the review was done by a
declared substitute and recorded as `gate: code-review @ …`. The pattern missed
it, `GSHA` came back empty, and the range silently widened to the entire branch.
The reviewer would have re-derived several hundred lines already cleared and
reported them as new findings. Now matches any `*review` gate name.

Second, a recorded sha can be **orphaned by a rebase**: the review genuinely
happened, but its commit is no longer an ancestor of HEAD, so `$GSHA..$HEAD`
replays every rebased commit as unreviewed. The reviewer on #1929 spotted
exactly this and said so in its scope note — the tooling could not. Now checks
`merge-base --is-ancestor` and warns loudly before falling back, instead of
handing over a range that quietly means something other than "the delta".

Both failures are silent and both produce a review that looks fine, which is
the reason they are worth a row here.

### Fixed — `velo-dispatch` validates the REF, so the local checkout stops mattering
Anchors and blast radius now read `origin/master` directly — `git show
origin/master:<file>` and `git grep origin/master` — instead of the working
tree. The worker's worktree is cut from that ref, so it is the only tree whose
contents mean anything.

This supersedes the guard added in the previous entry, which was the wrong
shape: it fixed the correctness hole by REFUSING to run unless the checkout
equalled `origin/master`, i.e. by handing the tool's job to the operator. It
then fired twice in one hour, once needing a `git pull` that itself failed on
untracked files that had become tracked upstream.

Reading the ref removes the requirement rather than enforcing it. A stale,
dirty, or mid-rebase checkout is now simply irrelevant. Verified by running
both scripts against the same checkout deliberately set 3 commits behind: the
old one refuses, the new one validates and reports the correct counts.

### Fixed — `velo-dispatch` validated a different tree than the worker gets
Anchors and blast radius are read from the WORKING TREE, but the worker's
worktree is cut off `origin/master`. The `git fetch` lived AFTER validation, so
a stale checkout could not even be detected: validation measured code the
worker would never see, and passed or failed for the wrong reason.

Dispatching #1934 hit both halves. Anchors reported a test file MISSING because
the merge that added it was not checked out locally, and the declared blast
radius was off by 6 because that same merge added 6 refs. Both looked like
brief errors. Neither was — the brief was right and the checkout was stale.

The fetch moves to before validation, and dispatch now refuses outright when
HEAD is not `origin/master`, naming how far behind or ahead and the exact
`git pull` to run. Verified both ways: passes at `origin/master`, and fires
with the right message from `HEAD~1`.

### Added — `velo-status` warns about stale stashes on the SHARED stack
Stashes are repo-global: every worktree shares one stack. A worker that runs
`git stash pop` expecting its own entry pops whichever abandoned run left the
top one.

That happened on #1928. The worker popped an unrelated
`1748-v1-overrejects` stash into its tree, hit a conflict in
`pian/column_resolution.rs` — a file it had never touched — and spent its
recovery diagnosing someone else's work. Ten such entries are on the stack
right now, the oldest from July.

Nothing surfaced them, so each new worker rediscovers the trap. The footer now
lists the count and the top three.

### Added — `velo-pr-gate` says what to do when Codex returns a handle
The script routes `code-review` to Codex and prints a brief for the caller to
run. On #1929 Codex never ran: its wrapper forwards to a single background task
it cannot poll, and it returned "waiting for the background task to complete"
having reviewed nothing. Asked again, it said it could not inspect the repo,
read the brief, or retrieve its own task's output.

A handle is indistinguishable from a report to anyone not reading closely, and
recording one as a gate result is a green tick over an unrun gate. The script
now says so, and says that substituting another reviewer is fine provided the
substitution is DECLARED in the gate comment — an unrun gate is worse than a
substituted one, but a mislabelled reviewer is its own defect.

### Removed — the `VELO_AGENT_IMPL=legacy` escape hatch, which could not work
`velo-openrouter-agent` exec'd `velo-openrouter-agent.py` when that variable
was set. That runner is untracked, and its first act is
`from velo_context import ...` — a module living in `~/.claude/lib/`, not on
the runner's import path. Running it gives
`ModuleNotFoundError: No module named 'velo_context'`. Verified by executing it.

Both worker skills already say "Do not set `VELO_AGENT_IMPL`". So it was a
fallback that was documented as forbidden AND broken if used: someone hitting
an SDK problem would set it expecting relief and get a confusing import error.
A fallback that cannot run is worse than none — one path, per the project's
no-silent-fallback rule.

### Added — three skills that were live but untracked
`improve-codebase-architecture`, `pr-gate` and `velo-implementation` existed in
`~/.agents/skills/` and were absent from the repo, so `install.sh` on a fresh
clone would not produce them and `install.sh --check` reported permanent drift.
The repo is supposed to describe what actually runs.

### Fixed — `.bak` files next to tracked scripts are gitignored
`.agents/bin/` held `velo-local-agent.py.bak`, `velo-openrouter-agent.py.bak`,
`.bak1` and `.BAK` — untracked, sitting beside tracked scripts. A `git add -A`
while staging a real fix swept all of them into the index, and they were only
caught by reading `git status` before committing. A bare `.bak` is against
policy anyway (backups carry a UTC timestamp).

## 2026-08-29

### Added — `velo-status` summarises each worktree's `agent.log`
The STATE column reads **processes**, so it reported `idle`/`running` and
nothing else. Two things went wrong because of that.

A worker wedged mid-validation — alive, but its Bash call never returned — and
showed as `running` for ~11 minutes before anyone noticed. And the reasoning
trail workers are required to keep was never surfaced at all, so state got
re-derived from `git` and task notifications when `agent.log` already had it,
better organised: six revert-then-restore proofs with their assertion texts, a
self-caught fabricated-timestamp correction, and a data-loss incident.

New `AGENT-LOG` column: line count, age of the **last entry**, and flags —
`S`=STOP, `F`=FINDING, `C`=CORRECTION, `!`=SECURITY/DATA-LOSS.

- Age comes from the last UTC stamp **in the file**, not the file mtime: an
  agent can touch the log without progressing, and mtime would call that fresh.
- It reads `<worktree>/agent.log`, not the runner's `/tmp` stdout. The first cut
  read the wrong file and reported `-` for a worktree holding a 30KB trail —
  caught by running it, not by reading it.
- Yellow when a worker is alive but its log has not moved in 10m+: wedged, **or**
  not writing the ~10-minute heartbeats the policy requires. Both leave this
  view blind to progress, so both are worth colouring.

### Fixed — `velo-merge` could never merge a docs-only PR
`ci.yml` carries `paths-ignore: ['docs/**', '*.md', …]`, so a documentation
change triggers no lane at all. `velo-merge` treated "no CI checks" as
`die "nothing has verified this build"` — a guard that was unsatisfiable by
construction for exactly the PRs it fired on.

Worse, `--force` did not help: the `case "$CI"` block dies before `--force` is
consulted, so the only route left was merging by hand, which skips the gate
label, the stale-gate SHA check and the conflict check as well. A guard that
cannot be satisfied does not add safety; it routes people around every other
guard.

Now a `none` CI result warns for a docs/tooling-only PR (no `src/`, no `tests/`)
and still dies for a code PR, where "no CI" genuinely means something is wrong.
The warning says plainly that nothing automated verified the change and the PR
body must state what did.

Found while merging #1924. Related: #1925 — 1168 ```sql blocks across 60 doc
files are parsed by nothing, which is why a docs PR has no automated
verification to point at in the first place.

### Added — `install.sh`, `update.sh`, this changelog
The README described installation as a block of `cp` commands to run by hand.
Two things went wrong with that. A partial copy left a runner and its policy on
different versions with nothing to detect it; and edits made directly in
`~/.agents` during a live session were silently discarded by the next copy.

- `install.sh` — idempotent repo → live install, `chmod +x` on **every** script
  (a hand-listed subset misses new ones and fails at dispatch time), symlinks the
  orchestrator skills. `--check` reports drift without writing.
- `install.sh --check` reports drift in **both** directions and says which:
  a live file newer than the repo is unpushed work, and installing over it loses
  it.
- `update.sh` — the reverse: live → repo, so a fix made during debugging can be
  reviewed and committed. Deliberately skips `tasks/`, since copying per-issue
  specs back would resurrect ones deleted on purpose.

### Added — `--skill NAME` on both worker runners
Workers run with a fixed `allowed_tools` list and no `setting_sources`, so they
have **no Skill tool**: a brief saying "run /check-code" was inert text. The
orchestrator compensated by hand-copying the checklist into each brief, which
drifted between dispatches *and* drifted from the skill it was copied from —
the real `check-code` skill asks for a `## Findings / ## Open Questions /
## Summary` shape the hand-written briefs never used.

`--skill` resolves and inlines the skill file. Resolution order, first hit wins:
`~/.agents/skills/<n>/SKILL.md`, `~/.claude/skills/<n>/SKILL.md`,
`~/.claude/commands/<n>.md`. Frontmatter stripped. A missing skill is a hard
error naming every path tried — a silently-absent skill produces a review that
looks like a gate and is not.

Vendored `skills/check-code` and `skills/check-spec` so the review definition is
version-controlled rather than living only in `~/.claude/commands`, where one of
them was a single line.

## Earlier

Recorded here retroactively; each was paid for by a wasted run.

- **`velo-dispatch`** — validates a ticket before any side effect: issue open, no
  blocking label, exactly one `worker:*`, dependencies closed, **symbol anchors
  re-verified** (a brief once cited `join.rs:130` after the symbol moved to
  `:147`), **blast radius computed and compared to the declared value** (an issue
  implied one call site; there were 66, and the worker burned its whole turn
  budget hand-editing), brief completeness, disk ≥ 40GB (each worktree `target/`
  is ~20GB and a full disk kills workers with spurious `error[E0308]`s).
- **`velo-status`** — names a running worker from its **live process**, not from
  a log matched by mtime, which mislabelled a worker mid-run. Flags `LEAKED` when
  a model emitted a tool call as plain text: those calls never ran, so the run's
  report is not evidence.
- **`velo-gate` / `velo-gate-post`** — gate state is a **label**, so "not gated"
  is visible rather than merely absent, and every gate comment starts
  `gate: <name> @ <sha>`. A PR was once green against a commit that had already
  been replaced. `velo-gate-post` exists because a reviewer that cannot reach the
  GitHub API produces a good report and then silently fails to deliver it —
  indistinguishable from a gate that never ran.
- **`velo-merge`** — refuses unless `gate:passed` **and** the recorded gate SHA
  equals `headRefOid` **and** CI is green. Now evaluates **all** checks: it read
  `statusCheckRollup[0]`, and a SKIPPED optional lane sorting first masked a
  green required build.
- **Runner: `--bash-timeout-ms`** — the Bash tool's 10-minute cap was killing
  long runs, surfacing only as a truncated error string that was misdiagnosed as
  OOM and disk exhaustion before anyone checked the tool's own limits.
- **Runner: leaked-tool-call detection** — exits non-zero when the model emits
  tool-call syntax as text. Backticks in the brief are a known trigger on
  DeepSeek.
- **Runner: `git_snapshot` includes `HEAD`** — `--porcelain` alone is empty once
  a worker commits, so a run that did its work *and* committed looked identical
  to one that did nothing, and burned every continuation.

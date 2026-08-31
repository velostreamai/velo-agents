# `.agents/` changelog

Every entry names the **failure it prevents**. A change to this tooling is only
worth carrying if it stops something that actually went wrong — that is the bar
for adding a row here, and the reason each gate exists at all.

Newest first.

## 2026-08-31

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

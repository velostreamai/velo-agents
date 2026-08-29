# `.agents/` changelog

Every entry names the **failure it prevents**. A change to this tooling is only
worth carrying if it stops something that actually went wrong — that is the bar
for adding a row here, and the reason each gate exists at all.

Newest first.

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

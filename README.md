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
    velo-native                    records each in-process (Agent-tool) worker; velo-status draws it
    velo-pr-gate                   run every gate a PR needs, each on the right model
    velo-gate                      record/inspect a PR's gate state (a LABEL, not memory)
    velo-gate-post                 post a reviewer's report on its behalf
    velo-gate-run                  one gate round: plan, brief, ATTACK fill, dispatch, wait, Codex verdict
    velo-gate-finish               post a round's reports at the gated sha, then record the verdict
    velo-gate-sweep                one compact view of every gating PR — sweep it instead of reading each gate's files
    velo-merge                     merge only if gated against the CURRENT head
    velo-waiver.jq                 ONE definition of "what is a waiver" (comment opens `gate-waived: <name> @ <9+ hex>`, next line `Approved by: <name>`, by an OWNER/MEMBER/COLLABORATOR): velo-gate --pass, velo-merge and velo-gate-finish read it. Must sit beside them
    velo-ci-rollup.jq              ONE definition of "how green is a PR": velo-merge refuses on it, velo-status shows it. Must sit beside them (install.sh copies bin/ whole)
    velo-record                    write a dispatch's OUTCOME (appended, never overwritten)
    velo-spec-review               attest a spec was read; --check has Codex REVIEW it
    velo-brief-lint.sh             the brief lint, one definition: velo-dispatch refuses on it, velo-spec-review runs it before it attests (sourced, not run)
    velo-orchestrd                 always-on LLM-free checker (#2285 PR2): detect/post/merge/dispatch/escalate
    velo-attention                 list/ack unhandled events from velo-orchestrd
    velo-orch-lib.sh               helpers shared by velo-orchestrd + velo-attention
    velo-worktree-lib.sh           worktree derivations shared by velo-status + velo-record
    velo-repo-lib.sh               WHICH repo the tools work on (`VELO_REPO`): the one place that spells the default, plus the tree, worktree, base-branch and state-path rules for any other repo. Sourced by every script that calls `gh`; must sit beside them
    zg                             discovery-search shim — the `zg` the policy tells workers to run
    velo_worker_runner.py          the one worker runner, two provider profiles
    velo_sdk_patches.py            corrections to the ROLLBACK sdk, applied at import
    velo_runner_lib.py             salvage-on-failure and other runner-side helpers
    velo-openrouter-agent          wrapper -> picks the worker RUNTIME (see below)
    velo-openrouter-agent-sdk.py   worker runner on open-agent-sdk  (ROLLBACK ONLY)
    velo-openai-agents-runner.py   worker runner on openai-agents   (SUPPORTED)
    velo_oai_tools.py              local tools openai-agents does not ship
    velo-lmstudio-agent-sdk.py     local LM Studio worker runner
    velo-llm-bench                 same-prompt speed bench for a worker:local server; prompt pinned to a commit
    velo-task                      detached work on a pinned, hash-locked Vanth (docs/velo-task-spec.md); M1: install-vanth, ensure-daemon, restart-daemon, doctor; M2a: run, status (a job belongs to a session: $CLAUDE_SESSION_ID, else a token the state dir keeps; `status` with no id lists a session's jobs)
    velo-task-lib.sh               the functions behind velo-task, sourced and never a subcommand: the locked bodies (ensure, restart, install), launch, records, doctor, run, status, session_id, reconcile_id
    velo-task-state                the durable-state helper behind velo-task (stdlib python): lock (symlink-safe, hands the body its descriptor), lock-held, check-state, write-record, rec-read, launch-exec (the process that becomes vanthd), publish, retire, append-index, fp, sha256, json-get, modes-check, redact, jobs-ro, verdict-of (the one place a verdict is computed, for one job or --list), session-token, pending-write, remove, index-last, index-has, reconcile (an id's pending records against Vanth's own acceptance record), failpoint, test-capability
  tests/
    run.sh                         every suite — run when touching .agents/
    test_runner_accounting.py      usage / leak / cost-provenance invariants
    test_record.sh                 STOP detection, outcome ladder, record writing
    test_dispatch_preflight.sh     brief-vs-reality refusals, driving the real script
    test_gate_health.sh            gate liveness, brief reuse, the per-PR lock
    test_gate_post_sha.sh          the gate stamp: never claim a sha the gate did not see
    test_spec_review_worker.sh     reviewer substitution is allowed, never silent
    test_gate_routing.sh            the routing table: one definition, three readers
    test_gate_check_code_mode.sh   the check-code route: free default, sonnet/opus opt-in, stale state cleared
    test_gate_substitution.sh      a substituted check-code reviewer is declared on the comment and the label
    test_gate_run.sh               velo-gate-run: ATTACK fill under the exhaustive-review preamble, last-marker verdict, retry, --brief-only, one e2e round
    test_gate_finish.sh            velo-gate-finish: post order, gated sha, idempotence, retry, no label over a missing report
    test_gate_sweep.sh             velo-gate-sweep: STALE flag, last-block verdict, per-leg caps, no-gate / gh-failure handling
    test_repo_env.sh               VELO_REPO, the gate half: the default repo's gh argv, state and review brief are byte-for-byte what they were (a golden recorded from the scripts before the change); for another repo every gh call names it, state paths never collide, a missing worktree is refused by path, `velo-pr-gate <n> --plan` plans that repo's diff; no script outside the lib spells the default; each check is proved red on a mutated copy
    test_repo_env_workers.sh       VELO_REPO, the worker half: dispatch (that repo's tree and default branch, refusals by path, the Velostream-only prerequisites skipped and said so), record, status, native, the orchestrator, watch, the SessionStart hook; each check is proved red on a mutated copy
    repo-env-lib.sh                the two VELO_REPO suites' shared harness: a stub gh that logs its argv, a sandbox holding a clone of each repo, the 20-scenario drive (sourced, not a suite)
    fixtures/repo-env/             default.golden, the default repo's trace recorded before VELO_REPO existed; its README says how to regenerate it
    test_index_exclude.sh          the discovery index can never become committable
    test_spec_review.sh            the --check loop's verdict paths, stubbed reviewer
    test_spec_review_lint.sh       attest refuses what dispatch refuses (brief lint, worker label); dispatch names the model it launched
    test_brief_ste.sh              brief style (STE100): long / multi-sentence / chained steps warn, never refuse
    test_brief_sweep.sh            the pre-gate sweep (spec §14): the lint requires it, velo-dispatch appends it to a copy, attest pins the file as written
    test_status.sh                 velo-status worker naming
    test_native_workers.sh         velo-native records, velo-status native rows, the override rule
    test_tool_contract.py          the tool contract precedes the policy (#2075)
    test_ast_grep_tool.py          ast_grep is registered, and behaves (#2075)
    test_zg_hidden.sh              zg can see .agents/ — both routes, and the index
    test_history_routing.sh        the re-dispatch guard: tiers, failure modes, bad records
    test_worker_env.py             the worker can run the tools its policy names
    test_orchestrd.sh              velo-orchestrd: detect, post, merge, dispatch, escalate, idempotency
    test_attention.sh              velo-attention: list/ack, dedup, acked ids stay acked
    test_merge_aggregate.sh        velo-merge: one verdict from many gate labels, ONE CI state from every check row, one gate-comment grammar
    test_gate_comments.sh          velo-gate: a failed gate-comment or issue read is not "nothing recorded"; --pass judges every gate
    test_verdict_of.sh             verdict_of: one verdict from every **Verdict:** line, not the first
    test_fence_parity.py           the three code-fence readers (brief lint, ATTACK fill, acceptance-bar counter) read ONE grammar
    test_llm_bench.sh              velo-llm-bench: the prompt is the pinned commit's, byte for byte; every result line says what produced it
    test_velo_task_hooks.sh        velo-task M3c, B13 + B29 hook half: the two deny-* hooks: every denied form, the look-alikes that must pass, each known false negative pinned, fail-open, the README registration line, install; each check is proved red on a mutated copy
    test_velo_task_bash32.sh       velo-task M3c, B14: every bin/velo-task* script parses, sweeps clean and runs under /bin/bash 3.2; a seeded declare -A fixture (fixtures/velo-task/bash4-seeded.sh) fails both halves; one seed per construct family
    bash32-sweep.sh                the bash-4 sweep and the 3.2 runner, sourced by those two suites; mutation-lib.sh is their shared mutation-proof harness (sourced, not suites)
    test_velo_task_foundation.sh   velo-task M1: install-vanth, state helper, daemon lifecycle; each check is proved red on a mutated copy; VELO_TASK_NETWORK_TESTS=1 adds the real install
    test_velo_task_m2a.sh          velo-task M2a: verdict_of, run, status, sessions (the key, the tag, the token, the list); sources the M1 harness, each check proved red on a mutated copy; VELO_TASK_ONLY="t_a t_b" runs just those, VELO_TASK_NO_PROOFS=1 skips the proofs
    fixtures/velo-task/            fake uv, vanth and vanthd, a sqlite-backed fake vanth CLI (fake-vanth-jobs.py), and a port holder, for the velo-task tests (the suite renders them into a temp tree)
    fixtures/vanth-closure.txt     the distributions a real Vanth install has, checked in: the fake install reports this set and the lock must pin exactly it
  bench/local-models/
    README.md                      worker:local model results, method and verdicts — read before switching models
    results/*.jsonl                raw bench lines, one file per model per day
  hooks/
    require-wait.sh                PreToolUse: denies velo-dispatch, velo-pr-gate and velo-merge unless they run with --wait in a run_in_background Bash call
    session-start-inflight.sh      SessionStart: lists in-flight gates, workers and PRs and unhandled attention events, so work a previous session launched is not forgotten
    deny-vanth-cleanup.sh          PreToolUse: denies `vanth prune` and `vanth restore` (spec R15(i)); its false negatives are in its header and pinned by its test
    deny-pgrep-wait-loop.sh        PreToolUse: denies a hand-written `until/while pgrep` wait loop and allows `velo-task wait` (spec R10)
    guard-lib.sh                   the command scanner the two deny-* hooks share (command position only: quoted text, heredocs and comments never match); sourced, never registered
  launchd/
    ai.velostream.orchestrd.plist  source template for the velo-orchestrd launchd agent
  requirements/
    vanth.in                       the one pin velo-task installs (vanth==1.14.0)
    vanth.lock                     its uv-compiled lock: a hash for every distribution, wheels only, CPython 3.12 macOS arm64; an upgrade is a reviewed change here
    vanth.wheels.tsv               the reviewed record of the wheel behind every lock hash (name, version, wheel file, platform tag, sha256 of the downloaded file); the suite requires each lock hash to equal its row, so a hash that is not of the named wheel cannot be locked without changing this file too
  rules/
    velo-impl.md                   MANDATORY implementation policy for every worker
    velo-brief-spec.md             what a task brief MUST contain, and why
    velo-glossary.md               one term, one meaning — the vocabulary briefs and policy use (spec §13)
    gate-attack-preamble.md        the one-round exhaustive-review rules velo-gate-run puts at the top of every review brief's ATTACK
    worker-pre-gate-sweep.md       the pre-gate sweep and PR size cap every worker brief carries (spec §14); velo-dispatch appends it when missing
  skills/
    velo-deepseek/SKILL.md         orchestrator-facing routing + usage
    velo-haiku/SKILL.md
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
    brief-<UTC>-<pid>.md   the brief with rules/worker-pre-gate-sweep.md appended — the copy the worker gets, only when the caller's brief had no sweep section
    <worker>-<UTC>.log     the worker's own transcript
    zg-index.log           output of the discovery-index build
  gate/<pr>/
    review-brief.md        the brief; stable, so a hand-filled ATTACK survives a re-run
    code-brief.md
    review.log  code.log   the reviewers' output
    check-code-agent-prompt.md   the read-only Sonnet agent's prompt (the opt-in `sonnet` check-code route)
    check-code.by          which route check-code used this run (`free` by default); velo-gate-post and velo-gate read it
    codex-verdict.md       Codex's final message, cut out of review.log by velo-gate-run
    attack-body.md         the ATTACK text velo-gate-run took from the scope file
    scope.<UTC>.md         the WHOLE scope file, one copy per velo-gate-run round; never read back (velo-gate-sweep and velo-status open named files only)
    gate-run.<step>.out    velo-gate-run's own record of each velo-pr-gate step (plan, brief, run)
    gate-finish.<step>.out velo-gate-finish's record of each step: check-code, code-review, verdict
    .lock                  one gate per PR at a time
  spec/<issue>/
    review-<UTC>.log       one `--check` round's report
    rounds.jsonl           the round ledger: verdict, spec hash, findings
  records/<issue>.result.jsonl   every dispatch's OUTCOME row (velo-orchestrd watches this)
  orch/
    attention.jsonl        one line per event needing a human — see "velo-orchestrd" below
    acked-ids              ids a human has already handled (velo-attention ack)
    queue.jsonl            pending dispatches: {issue, brief, worker, brief_sha256}
    offsets/<issue>.count  how far velo-orchestrd has read each records/*.result.jsonl
    paused                 touch this to stop every future tick; rm to resume
    .lock/                 one tick at a time (mkdir lock, pid inside)
    orchestrd.log          the daemon's own reasoning trail, rotated at 5MB
```

That is the layout for the default repo. For any other repo (`VELO_REPO`, below) every directory above sits one
level down under `<owner>__<name>` — `gate/velostreamai__velo-agents/<pr>/`, `dispatch/…/<issue>/`,
`records/…/<issue>.result.jsonl`, `spec/…`, `native/…`, `orch/…` — so PR 12 and issue 78 of two repos never share a
directory, a lock or a record. The 7-day gate prune of a Velostream run skips those directories (its own `find`
would read `gate/<owner>__<name>` as idle while its PRs are live); a run for that repo prunes its own PR directories.

This was `/tmp` until four separate defects traced to it: a fixture race
(#2040), two gates on one PR sharing a brief, a cleanup that leaked a file per
run, and a stale brief from a previous session being reused — dispatching a
review briefed on nothing while reporting `ok reusing filled brief`. `/tmp` is
machine-global while worktrees are not, has no ownership semantics, and is
simultaneously too persistent (three-day-old files read as current) and not
persistent enough (macOS purges it). One directory per subject makes the
directory the unit of ownership, of locking, and of pruning; gate artefacts
older than 7 days are pruned by the tool that wrote them. The prune takes the
per-PR directories only (`find -mindepth 1`): the `gate/` root is itself "older
than 7 days" whenever nothing was created directly in it for a week, and pruning
it would remove every PR's briefs, logs, verdicts and locks, this run's own lock
included.

## Installation

The tooling runs from `~/.agents/`; this directory is the versioned source.

```bash
./.agents/install.sh
export PATH="$HOME/.agents/bin:$PATH"      # add to ~/.zshrc
```

Idempotent — re-run after every pull. It copies `bin/`, `rules/`, `skills/`, `hooks/` and
`tasks/`, `chmod +x`es **every** script and hook (a hand-listed subset misses new ones and
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
| `OPENROUTER_API_KEY` in the environment | DeepSeek, Haiku and GLM workers |
| `velo-llama-server setup` (once per machine) | the free local worker: llama-server (Homebrew llama.cpp, launchd) serving the model named in `bin/velo-local.conf`, the default backend. `velo-local use lmstudio\|llama\|sushi` switches to tuned LM Studio (prepared by `velo-local-setup`), to Sushi on MLX (`velo-sushi-server`, on trial) and back; `velo-local status` shows which. Override per run with `VELO_LMSTUDIO_URL`. |
| `gh`, authenticated | issue/PR validation |
| `python3`, `jq`, `git`, `cargo`, `cargo-nextest`, `ast-grep` | dispatch + worker runtime |
| **Node 22+** (optional) | the `zg` discovery index built per worktree at dispatch. Absent, dispatch warns and workers fall back to `rg` + `ast-grep`. `npm i -g @zvec/zvec-grep` makes it fast; without it the `zg` shim falls back to `npx` per call |

Verify:

```bash
velo-dispatch 1898 /tmp/brief.txt --dry-run    # exercises every gate, launches nothing
velo-status
```

### Hooks

`install.sh` copies `hooks/` to `~/.agents/hooks/` and makes every file there executable; `--check` reports a hook
that is not. Copying registers nothing: a hook runs only once a Claude Code settings file (`~/.claude/settings.json`,
or a project's `.claude/settings.json`) lists it. Register each one in this guarded form, so that a machine where the
hook is not installed yet skips it instead of failing every Bash call (a hook that is installed but not executable
is skipped the same way, which is why `--check` looks for it):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "[ -x \"$HOME/.agents/hooks/require-wait.sh\" ] || exit 0; exec \"$HOME/.agents/hooks/require-wait.sh\"" },
          { "type": "command", "command": "[ -x \"$HOME/.agents/hooks/deny-vanth-cleanup.sh\" ] || exit 0; exec \"$HOME/.agents/hooks/deny-vanth-cleanup.sh\"" },
          { "type": "command", "command": "[ -x \"$HOME/.agents/hooks/deny-pgrep-wait-loop.sh\" ] || exit 0; exec \"$HOME/.agents/hooks/deny-pgrep-wait-loop.sh\"" }
        ]
      }
    ]
  }
}
```

`session-start-inflight.sh` registers the same way under `SessionStart`. The two `deny-*` hooks are guardrails against
the orchestrating model's own mistakes (docs/velo-task-spec.md R10, R15(i)), not isolation:

| hook | denies | allows | known false negatives |
|---|---|---|---|
| `deny-vanth-cleanup.sh` | `vanth prune` and `vanth restore` as a command: bare, by absolute path, `python -m vanth[.cli]`, behind `env`/`sudo`/`timeout`/`uv run` and the like, in a pipeline, `&&`, `$( )` or a loop | any other `vanth` subcommand, `vanth prune --help`, and the same words inside a quoted string, a heredoc or a comment (`git commit -m "..."`) | a `bash -c` or `eval` string, a variable or alias holding the program, a script file, `find -exec`, `sudo -u neil`, `curl -X POST .../cleanup`, the MCP `job_cleanup` tool, `VANTH_RETENTION_SECONDS` |
| `deny-pgrep-wait-loop.sh` | a `pgrep` inside a `while` or `until` loop, in its condition or its body | `velo-task wait`, `pgrep` outside a loop, and the same words inside a string, a heredoc or a comment | a `bash -c` or `eval` string, `for` and `watch` polls, `ps` piped to `grep`, `pidof`, `kill -0`, pid and marker files |

Both read the payload with `jq` and fail open (exit 0) when `jq`, `guard-lib.sh` (the scanner they share, installed beside
them) or the command is missing. `tests/test_velo_task_hooks.sh` pins every denied form, every look-alike that must pass and
each false negative above, so closing a gap makes that test say so.

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

## Using it on another repository — `VELO_REPO`

Every tool works on `velostreamai/velostream` unless told otherwise. `VELO_REPO=<owner>/<name>` (the older name
`VELO_GATE_REPO` is the same variable; `VELO_REPO` wins when both are set) points all of them at another GitHub repo:

```bash
VELO_REPO=velostreamai/velo-agents velo-pr-gate 12 --plan --wait   # the tier and legs for THAT repo's PR 12
VELO_REPO=velostreamai/velo-agents velo-dispatch 17 brief.md --wait
```

`bin/velo-repo-lib.sh` is the one definition of which repo; it is the only file in `bin/` and `hooks/` that spells the
default (`tests/test_repo_env.sh` counts). `velo-dispatch`, `velo-status`, `velo-watch`, `velo-orchestrd`, `velo-attention`,
`velo-record`, `velo-native`, `velo-spec-review`, `velo-pr-gate`, `velo-gate`, `velo-gate-run`, `velo-gate-post`, `velo-gate-finish`,
`velo-gate-sweep`, `velo-merge` and the SessionStart hook all read it; a value that is not `<owner>/<name>` stops each
with `ERROR: VELO_REPO must be <owner>/<name>`. **With nothing set, nothing differs** — the gh calls, the state paths
and every message are the ones they were; `tests/fixtures/repo-env/default.golden` pins them from the pre-change scripts.

| | Velostream (default) | any other repo |
|---|---|---|
| a worker's tree and worktree | `~/RustroverProjects/velostream`, `velostream-<issue>` | `~/RustroverProjects/<name>`, `<name>-<issue>` |
| cut from, and commits counted against | `origin/master` | the repo's default branch as GitHub names it (`gh repo view`), `origin/<it>` |
| the tree is missing, is another repo's clone, or GitHub names no default branch | — | refused, naming the path tried; Velostream's tree is **never** used instead |
| a repo with the same name and another owner (`acme/velostream` beside `velostreamai/velostream`) | — | its paths are Velostream's, so every tree found by name must pass an `origin` check (`repo_owns`) before it is read, written, counted or resumed: `velo-status` and `velo-orchestrd` skip a `<name>-*` worktree of another repo, `velo-spec-review` (its tree and any `--worktree`), `velo-dispatch` (the worktree at the issue's path) and `velo-record` (its tree and `--worktree`) refuse it, naming the path |
| the tree a gate reads | the worktree `git worktree list` finds for the PR's branch | found by name and `origin` under `~/RustroverProjects/<name>*`, whatever the cwd; refused, listing every path tried, when none is on the branch |
| state | `gate/<pr>/` … | `gate/<owner>__<name>/<pr>/` … (see the layout above) |
| discovery index, `run-commit.sh`, the CLAUDE.md read-first, STREAMING-COMPLIANCE | applies | skipped, and said so: dispatch prints it, and the worker's task and every review brief open with an `OVERRIDE-DIRECTIVES:` paragraph |
| what counts as orchestration (gets `code-review`) | files under `.agents/` | files in the tooling tree: `bin/ rules/ skills/ tasks/ hooks/ launchd/ install.sh update.sh` |
| when `check-spec` is planned | a closing keyword with 3+ acceptance bars, or a `[#N]` PR touching `src/` | a PR that closes **or references** (`#N`) an issue with 3+ acceptance bars |
| task sidecars and the `fail_to_pass` check | dispatch injects the sidecar's contract; `velo-pr-gate` validates its tests | dispatch injects a sidecar found in the repo's own tree, else says there is none; the `velo-pr-gate` check is skipped, and said so |
| the launchd agent | `velo-orchestrd install / uninstall / status` | refused (it is Velostream's, with no `VELO_REPO` in its plist); schedule `VELO_REPO=<repo> velo-orchestrd tick` yourself |
| a printed follow-up command | `velo-gate 12 --pass` | `VELO_REPO=<repo> velo-gate 12 --pass` — pasted into a bare shell it cannot act on Velostream's PR 12 |

One Velostream shape does not carry over: `velo-merge` waives its "no CI checks reported" refusal only for a diff that is
entirely under `.agents/`, so a PR to a repo with no CI workflow is refused there (nothing would have verified the build)
until that repo has one.

`tests/test_repo_env.sh` and `tests/test_repo_env_workers.sh` run the real scripts in a sandbox holding a clone of each
repo against a stub `gh` that logs its argv, and break the code (a mutant per check) to prove each check goes red.

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
| record an in-process (Agent-tool) worker | `velo-native start <n> <branch> <worktree> [--model haiku\|sonnet]` (it prints a token: keep it with that worker), then `velo-native done <n> --token <token> [--outcome ok\|stopped\|failed]` | the process table cannot see it; without the record it is invisible to `velo-status`'s slot count. The token stops a late `done` from an earlier worker finishing a later worker's record |
| know what a run cost | `velo-status <n>` | the appended `<issue>.result.jsonl` record |
| gate a PR | `velo-pr-gate <pr> <scope-file>` | `velo-gate --plan` derives the gates **from the diff** |
| merge | `velo-merge <pr>` | refuses unless the recorded gate names the CURRENT head |

Two of those deserve emphasis, because they are where judgement is deliberately
removed:

**Which gates a PR needs is computed, not chosen.** `velo-gate --plan` reads the
diff: `src/` touched adds `check-code`; a linked issue with 3+ acceptance bars
adds `check-spec`; anything under `.agents/` requires `code-review`, because
tooling governs every other run. **Which model runs each gate is fixed** —
`code-review` to Codex, `check-code` to the free OpenRouter tier (a read-only
Sonnet agent, or opus at `--effort high`, only on request), `check-spec` to the local worker. Hand-
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
| `worker:local` / `worker:deepseek` / `worker:haiku` / `worker:glm` / `worker:codex` | **routing.** Exactly one required — zero or two is a refusal. The label picks the model; the orchestrator does not |
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
  performed by the wrong model. The default `check-code` route is itself a
  substitution (Sonnet for the routed opus), so `velo-gate-post` and `velo-gate`
  declare it from the route `velo-pr-gate` recorded rather than relying on the
  orchestrator to remember.

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
| **delegated worker** | `velo-local`, `velo-deepseek`, `velo-haiku`, `velo-glm` via the worker runner (`VELO_AGENT_BACKEND`); `worker:codex` via `codex exec` | implements one scoped task in its own worktree, unattended |
| **review gate** | `codex review` for `code-review`; the free OpenRouter tier for `check-code` (the script dispatches it; a Sonnet agent is opt-in); `velo-local` for `check-spec` | reads a diff read-only and returns findings |

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

## The five workers

| skill | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | `qwen3.8-flash-next-ud` (LM Studio, llama.cpp >= 2.46.0, 262K ctx) | **free** | triage, investigation, check-spec, second-opinion review; latency-insensitive only (#2235) |
| `velo-deepseek` | `deepseek/deepseek-v4-flash-0731` | **very cheap** | fast scoped implementation against a pinned design |
| `velo-haiku` | `anthropic/claude-haiku-5.5` | **cheap** ($0.10/M in, $0.50/M out) | the DeepSeek-shaped job on the Claude leg — scoped implementation when Anthropic is the preferred family |
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

Every brief carries `rules/worker-pre-gate-sweep.md` under a `## PRE-GATE SWEEP` heading (spec §14):
the defect shapes past gate rounds found one per round, and the PR size cap. You do not have to
paste it. The lint refuses a brief without the heading, and `velo-dispatch` appends the file to a
**copy** of such a brief (`~/.agents/state/dispatch/<issue>/brief-<UTC>-<pid>.md`) and hands the
worker the copy. Your file is never touched, and it is still your file that the spec attestation
pins and that `velo-record` reads; a dry run prints both paths. The file is looked for beside the
script, then in `~/.agents/rules/`, and one that is missing, empty or without the heading stops the
dispatch. `velo-spec-review` (attest) is the one tool that does not append: it pins the file as
written, so there the section must already be in it —
`cat ~/.agents/rules/worker-pre-gate-sweep.md >> <brief>`.

### 4. Check the brief FIRST, then dispatch

```bash
velo-dispatch 1898 /tmp/brief-1898.txt --dry-run   # validates everything, launches nothing
velo-dispatch 1898 /tmp/brief-1898.txt             # only after the dry run is clean
```

**Always dry-run first.** It runs every gate — issue state, labels, task-spec
anchors, computed blast radius, brief completeness, disk — and creates no
worktree, assigns nothing, launches nothing. A brief that is missing a STOP
condition or a grammar reference is caught here rather than by a wasted
dispatch attempt. The validation rule (spec §7) and the `## Branch` / `## Worktree`
headings are read with fenced code blocks (``` and ~~~) masked: a `## ANALYSIS ONLY`
or `## Validation` that a brief merely quotes inside a fence declares nothing, while a
fenced block of commands under a real `## Validation` heading still counts as its content.

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

Always invoke `velo-dispatch` with `--wait`, via a Bash tool call with
`run_in_background: true`, instead of manually polling as above — a
PreToolUse hook (`.agents/hooks/require-wait.sh`) enforces this and denies
the call otherwise, because a detached run that finishes with nobody
watching is exactly how a completed dispatch went unnoticed for 8 hours.

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

Tier order is `local < deepseek < haiku < glm < codex`.

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

A lock is reclaimed only when its holder is **known to be gone** — the pid file
names a pid and no such process exists. A holder that cannot be told is not a dead
one: a pid file that holds no pid, or cannot be read, is refused at once with the
reason and the lock is left where it is, because removing it is how a second gate
starts over a first that has only just begun. The owner makes the directory first
and writes its pid a moment later, so a pid file that is missing or empty is read
again for a short grace — 10 polls, `VELO_GATE_LOCK_POLL` seconds apart (default
0.2) — before it is believed. `velo-gate-run`'s early check reads the holder with
the same function (a test pins the two copies byte-identical), and a pid that
cannot be written releases the lock and refuses, rather than leaving a lock nobody
can name. The lock is released on every exit path of the gate that took it,
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

**Attest mode** (`velo-spec-review <issue> <brief> --by <who>`) writes the `reviewed` block
that `velo-dispatch` checks against. Before it writes anything it refuses the two things dispatch
refuses on that a review could otherwise certify: a brief the brief lint rejects
(`bin/velo-brief-lint.sh`, the one definition both tools run), and an issue without exactly one
`worker:*` label. Add the label **first**: a label edit moves the issue's `updatedAt`, so an
attestation written before it is stale the moment it is written. A refusal leaves the spec and the
issue untouched. One refusal is stricter than dispatch's: a brief with no `## PRE-GATE SWEEP`
section. Dispatch appends it to a copy, but the attestation pins the file as written.

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
| `check-code` | **free OpenRouter tier, advisory** (default, dispatched by the script) · read-only Sonnet agent (`--check-code-by sonnet`, opt-in) · opus at `--effort high` (`--check-code-by opus`) · DeepSeek / Haiku / GLM on OpenRouter, **advisory** (`--check-code-by deepseek\|haiku\|glm`) | the opus leg has never produced a report — it times out; a bounded Sonnet agent does, at a fraction of the cost; the OpenRouter route costs no Claude tokens but has not earned a gating verdict |
| `check-spec` | velo-local | free; fine at bar-by-bar verification |

Choosing the model per PR by judgement is how the routing drifted: a review once
went to velo-local and came back `MERGE-READY` while missing a HIGH and asserting
a fact that was demonstrably false. The routing is now in the script.

**The `check-code` route** is chosen by `--check-code-by sonnet|opus|deepseek|haiku|glm|free`
or `VELO_CHECK_CODE=…` (the flag wins; the default is `free`, dispatched by the script itself):

- `sonnet` (opt-in) — the script launches **nothing** for this gate. It writes
  `~/.agents/state/gate/<pr>/check-code-agent-prompt.md` (the check-code
  instructions, the brief's worktree/range/scope/ATTACK, read-only, a 40-tool-call
  cap, one output shape) and prints one line telling the orchestrator to launch a
  read-only Sonnet agent on it, then to post its report with
  `velo-gate-post <pr> check-code <report> --sha <sha>` (or let `velo-gate-finish`
  post it with the rest of the round). The route is recorded in
  `gate/<pr>/check-code.by`; `velo-gate-post` then prepends the reviewer-substitution
  note to the comment and `velo-gate --pass|--block|--show` repeats it, so the label
  never implies an opus:high result that did not happen.
- `opus` — the original dispatched leg (`claude -p --model opus --effort high`,
  read-only by construction, health-checked), no substitution declared.
- `deepseek` | `haiku` | `glm` — the sonnet route's prompt, run by `velo-openrouter-agent`
  on the model `velo-dispatch` pins for that worker (a test fails if the two
  drift), read-only via the runner's READ-ONLY marker, report in `code.log`
  (`VELO_CHECK_CODE_TIMEOUT`, default 3600s; `VELO_CHECK_CODE_BUDGET_USD`,
  default 1). It saves the ~90–115k Claude tokens a Sonnet check-code costs, but
  it is **advisory**: `check-code.by` records the model, `velo-gate-post` declares
  the report advisory on the comment and `velo-gate` repeats it. Codex's
  code-review stays the gating leg.

The Codex leg is the same on both routes, and `--plan` states which route it will
take. Every run clears the previous run's prompt and route marker first, and the
`sonnet` route also clears `code.log` and its pid: `velo-orchestrd` posts any
`code.log` whose pid is dead under the run's recorded sha, so a stale opus report
would otherwise be stamped with a commit it never saw.

It also:

- **refuses without a scope file** — a gate briefed only on a diff reports
  dimensions rather than findings, which is how that bad review happened
- **computes the review diff range** from the last recorded review gate
  (`gate: <…>review @ <sha>`), so a re-review scopes to the delta. The brief's
  SCOPE sentence says which of four things is true, because the range alone
  cannot: *delta* ("Everything below `<sha>` you have already reviewed and
  cleared"), *first review* ("This is the first review of this PR"), *orphaned*
  (the recorded sha is no longer an ancestor of head after a rebase: the whole
  branch is in range and nothing below it can be taken as cleared) or *unreadable*
  (the gate comments could not be read, so what was already reviewed is unknown:
  the whole branch, nothing cleared). A failed read is a warning carrying gh's own
  message — it is never the first review
- **refuses an empty range** — if nothing landed since the last review, there is
  nothing to review, and an empty diff comes back `approve`: a vacuous gate
  wearing a green tick. A `git diff` that *fails* (say `origin/<base>` was never
  fetched) dies naming the range; it is not an empty one
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

Always invoke `velo-pr-gate` with `--wait`, via a Bash tool call with
`run_in_background: true` — the same PreToolUse hook enforces this and denies
the call otherwise, so a finished review can no longer go unnoticed.

**One label, several gates.** `gate:passed` is a single label, but a `src/` PR
runs up to three gates. `velo-merge` therefore cross-checks the gates
`velo-gate --plan` demanded against the `gate: <name> @ <sha>` comments actually
recorded, and refuses when any is missing — a finding that never reached the PR
is indistinguishable from a gate that never ran, and the printed handoff used to
name only `code-review`, so two could be silently dropped. `velo-pr-gate` now
prints a `velo-gate-post` line per gate it dispatched.

**The merge gate counts; it does not pick.** The merge decision rests on three
states, and GitHub hands each over as a list. Each is reduced from *every*
element, conservatively — never read from the first, the newest or the one that
happens to sort first:

- **The verdict is one label, read from many.** A PR can carry several `gate:*`
  labels (a `--remove-label` that failed, a label added by hand), and a
  `gate:passed` among them used to outvote a `gate:blocked` beside it. A gated PR
  with more than one is refused (`--force` proceeds with a warning; `--wait`
  treats it as definitive, not transient); a docs-only PR has no verdict to be
  ambiguous about. `velo-gate --show` names the ambiguity and exits 1, and the
  label writer dies when an old label cannot be removed instead of adding the new
  one beside it.
- **CI is one state from every check row**, by one definition shared with
  `velo-status`: `.agents/bin/velo-ci-rollup.jq`, worst first — FAILING > unknown >
  pending > SUCCESS > none. A row is pending when its status is not COMPLETED
  however the absent conclusion is spelled (a running check has none); a commit
  status (the legacy API) has a `state` and no conclusion; `STARTUP_FAILURE`,
  `ACTION_REQUIRED` and `STALE` are failures; a conclusion or row type nobody has
  heard of is `unknown` and is refused — never green, and waiting does not make it
  recognised. A definition that cannot be read or run is a refusal that names it,
  not a pass. The file must sit beside the scripts; `install.sh` copies `bin/` whole.
- **The gate comments are read once, by one grammar.** The freshest comment per gate
  name, `gate: <[a-z0-9-]+> @ <sha>`, feeds both "is each needed gate recorded?" and
  "is each one current?" — two greps with two grammars had let `gate: check-code @
  pending` satisfy the first and never be compared to head. A header with no
  readable sha names no commit and is not current. A *failed* read is reported in the
  same kinds as the PR read (a blip is retried by `--wait`; a dead token, or an
  answer that is not a gate list, is definitive). `velo-gate --pass` uses the same
  grammar and fails closed: it refuses unless **every** gate's freshest sha is head
  (not the newest comment's) and dies, changing nothing, when the comments cannot be
  read; `--show` says it could not tell — never "nothing has been recorded".
- **`--plan` reads every issue the PR closes**, not the first. `check-spec` is planned
  when any of them has three or more acceptance bars, and one that cannot be read
  refuses the plan and is named (`--show` prints the plan it has, says it is
  INCOMPLETE and exits 1). GitHub closes on `close`/`fix`/`resolve` and their
  inflections in any case, not on two keywords.
- **A done-marker that exists but cannot be read** is a refusal naming the file, not
  an `already merged ()` success line. `velo-merge` and `velo-gate-post` tell
  *absent* (the guard stays unfired), *unreadable* (dies: no second merge or post) and
  *empty* (still proof the side effect ran) apart, at every place they look.

**A read that fails is said, never read as nothing.** A guard keys on a value it
read, and a read that failed used to be the same empty value as a read that found
nothing — so the guard went quiet exactly when what it guards was unknowable.
Absent, empty, unreadable and failed are four different states, and none may be
quietly converted into another. In `velo-pr-gate`:

- **the plan** — a `velo-gate --plan` that cannot be made shows `velo-gate`'s own
  reason and exit status. It used to be reported as `PR #N not found`, which
  `velo-gate-run` retries as a dropped connection, so the round ran the plan three
  more times and gave up with the same wrong sentence.
- **the merge-time `fail_to_pass` check**, the only enforcement of a spec's
  acceptance tests: a PR title or spec that cannot be read warns
  `fail_to_pass is NOT being verified for this gate` (a title with no `[#N]` is a PR
  with no spec, and has nothing to say); a base branch that cannot be read dies in
  the `could not read base branch for #N` shape `velo-gate-run` retries (it used to
  build `origin/`, and the predates check never fired); a `git grep` that *errors*
  dies naming the ref and the test, instead of reading as "not defined" (a BLOCK
  with the wrong message) or "not predated" (a silent pass).
- **the `gate:running` label** — if `velo-gate --running` is refused the round does not
  abort (the reviewers are already running, and the lock would be released with them
  still going), but it warns that the PR is NOT labelled, with `velo-gate`'s message
  and the command to set it by hand: `velo-orchestrd` follows only `gate:running` PRs.

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

### `velo-gate-run` — one gate round in one command

```bash
velo-gate-run <pr> <scope-file> [--check-code-by sonnet|opus|deepseek|haiku|glm|free]     # launch with run_in_background: true
```

It replaces the hand-run sequence, each step of which went wrong in some round:

1. `velo-pr-gate <pr> --plan` — which gates, how each is routed. A plan with no gates ends the round.
2. `velo-pr-gate <pr> <scope> --brief-only` — generates the review brief and
   **dispatches nothing**. (The old prime, `<pr> <scope> --plan`, only dodged the
   require-wait hook: the script treated it as a plain run, launched check-spec
   before reaching the unfilled-ATTACK refusal, and the real run launched it again
   over the same log.)
3. Fills the brief's `## ATTACK` from the scope file's own `## ATTACK` section —
   its body, up to the next heading of the same or a shallower depth, fenced code
   skipped. **A scope with no `## ATTACK`, or an empty one, is refused before
   anything is touched.** A brief that is already filled for this scope and range is kept.
4. `velo-pr-gate <pr> <scope> --exec --wait`, so the require-wait hook is satisfied
   and every launched reviewer has exited when it returns. `--wait` does **not**
   wait for the non-blocking second opinion: it used to, which held the gate lock
   until the local model finished and stalled the next round on "a gate is already
   running". Its pid is in `second-opinion.log.pid`; `VELO_SECOND_OPINION=0` skips it.
5. Waits for the Codex pid, then writes Codex's final message — the text after the
   **last** line that is exactly `codex` in `review.log` (the whole log, with a
   warning, if there is none) — to `gate/<pr>/codex-verdict.md`. An empty final
   message is refused, not written. Then the second opinion gets
   `VELO_SECOND_OPINION_GRACE` seconds (default 120) to finish, and is killed —
   children too — if it has not; its log says it was cut short. Any exit of the
   wrapper kills it, as does the start of the next round (it would otherwise keep
   writing into the log that round truncates). A pid file naming anything other
   than an agent runner kills nothing. `VELO_SECOND_OPINION_TIMEOUT` (default
   3600s) is the runner's own bound when nothing else ends it.

In step 3 the ATTACK always opens with `rules/gate-attack-preamble.md`, the one-round
exhaustive-review rules: finish every item, build the matrix before judging, diff every new parser
against the route's own, sweep the sibling sites, report everything in one pass. The script adds
it, so nobody has to remember to paste it into a scope. It goes on **after** the scope's own ATTACK
has been judged non-empty, so it can never stand in for an empty one. A body that already opens
with its `## ATTACK 0 — ONE-ROUND EXHAUSTIVE REVIEW` heading (the first non-blank line; a quoted,
later or fenced mention does not count) gets nothing added, and the fill line says which file was
used. The file is looked for beside the script (`../rules/`), then in `~/.agents/rules/`; one that
is missing, empty or without that opening heading refuses the round before anything is touched (no
scope copy, no gate dir). A brief that is already filled, and so kept, must open its ATTACK with
the preamble too, or the round stops and names the fix: remove the brief so it is filled again, or
paste the file at the top of its `## ATTACK`.

Before step 1 it copies the **whole** scope file to `gate/<pr>/scope.<UTC>.md` —
one file per round, never overwritten (a second round in the same second becomes
`scope.<UTC>.2.md`), kept until `velo-pr-gate` drops the idle gate dir after 7 days.
The name is taken with an exclusive create (noclobber), not looked up and then
created, so two rounds that start in the same second each keep their own copy; a gate
dir that cannot be written stops the round, naming the file and showing the shell's
own error, rather than retrying suffixes.
`attack-body.md` keeps only the ATTACK text; the scope's header (delta range, what
changed, what the last round found) used to live only in the file you passed, which
may be somewhere a reboot clears, so a launch that died left nothing to re-run from.
The copy comes after every refusal (a bad scope, a gate already running leave
nothing behind) and before every step, so a round that dies in the plan, the brief or
the launch still has it; if it cannot be written the round stops. `velo-pr-gate` is
still handed the original path.

It ends by printing the `velo-gate-finish` line for this plan. The wrapper holds a
session for the length of a review, so launch it with `run_in_background: true`; with
the opt-in sonnet check-code route the one launch line for the Sonnet agent appears in its
output as soon as the gates are dispatched.

A transient gh failure inside `velo-pr-gate` (`PR #N not found`, `could not read
head/base branch`) is retried up to 3 times; local-state failures (no worktree, a
gate already running, an unfilled ATTACK) fail on the first attempt — and so does a
plan that cannot be made for any other reason: it is shown at once with
`velo-gate`'s own message, not retried under a sentence that was never true. A gate
lock whose holder cannot be identified is refused before anything moves (see "One
gate per PR"). Last round's `review.log`, its pid and verdict are moved aside before
the run, so nothing from an earlier round can be read as this one's.

### `velo-gate-finish` — post the reports, then record the verdict

```bash
velo-gate-finish <pr> <sha> --pass|--block <check-code-report> <code-review-report>
velo-gate-finish <pr> <sha> --pass|--block [--check-code <file>] [--code-review <file>]
```

`<sha>` is the commit the gates ran against (`velo-gate-run` prints it; it is in
`gate/<pr>/gated.sha`). This replaces `velo-gate-post <pr> check-code …`,
`velo-gate-post <pr> code-review …` and `velo-gate <pr> --pass|--block`:

- every report is stamped with `<sha>`, never with whatever the head is by then;
- **a report that did not land stops it before the label.** A failed post fails the
  run, and a post `velo-gate-post` calls OK is confirmed on the PR itself first — the
  poster exits 0 without posting when its own done-marker exists for a comment that
  has since been deleted;
- **idempotent**: a report whose `gate: <name> @ <sha>` header is already on the PR is
  not posted again (whatever that comment holds — it is not compared with your file;
  `velo-orchestrd` posts a finished gate's raw log the same way), so the command
  re-runs from wherever it stopped;
- a transient gh failure (`PR #N not found`, a post or label that timed out) is
  retried up to 3 times, 5s apart (`VELO_GATE_RETRY_DELAY`). A post that failed on the
  wire may still have landed, so the PR is checked before the retry — a lost response
  is not a duplicate comment. A refused `--pass` (the head moved) and the template
  guard fail on the first attempt;
- `--check-code` / `--code-review` let a PR that needs one report finish with only
  that one (an `.agents/`-only PR has no check-code leg).

`velo-orchestrd` acts on `code.log` / `review.log`. The Sonnet route leaves no
`code.log`, so a PR whose plan includes check-code is never auto-passed and this
command is the explicit finish. The substitution is declared from `check-code.by`
exactly as when `velo-gate-post` is run by hand.

---

## `velo-gate-sweep` — every gating PR in one view

```bash
velo-gate-sweep <pr> [<pr>...]
```

Sweep the gates with `velo-gate-sweep` instead of reading each gate's files: at
most 30 lines per PR for the head sha + state + mergeable, the last gated sha
(`STALE` when it differs from head — the verdict on disk is for a commit that no
longer exists), the PR's one CI state (`ci=`), whether a gate is running, the Codex
verdict with its P* finding titles, and the advisory check-code headlines; read-only, missing
files print `(no gate yet)`, and a PR `gh` cannot see is an error line that does
not stop the sweep.

**Failure honesty (#2354):** a read that FAILS never prints as a clean state, and
every read distinguishes three states — ABSENT (the file does not exist: only
this state may print `(no gate yet)`), UNREADABLE/FAILED (the file exists but
the read failed, or the command exited non-zero: `ERROR(<what failed>)`), and
EMPTY/INCOMPLETE. A failed `gh pr checks` prints `ci=ERROR(<gh's first stderr
line>)` — `ci=none` means the read SUCCEEDED and no check matched; likewise a
failed view read prints `ERROR: unreadable (…)` while `ERROR: not found` means
gh answered with nothing. `gate-running` is the per-PR lock
(`gate/<pr>/.lock/pid`), counted only when the pid is alive AND its command line
(`ps -ww`, untruncated) is a gate process — a dead or recycled holder prints `0`
with a `STALE-LOCK(…)` flag (empty / malformed / unreadable pid file each name
their own state; an unreadable one prints `gate-running=ERROR(…)`), never a
phantom gate. A Codex verdict prints only when `codex-verdict.md` states one of
the three canonical words; an unfilled template, an empty or unreadable file, or
an off-format verdict word prints `-- codex: INCOMPLETE (<reason>)` with the
finding titles still shown. The placeholder check reads the parsed **Verdict
line only** — a completed report that quotes `approve | approve-with-findings |
blocked` inside a finding is not an unfilled template. A `review.log` /
`code.log` that exists but cannot be read prints `ERROR(unreadable …: <reason>)`
per leg, never `(no gate yet)`; an unreadable, empty, or non-hex `gated.sha`
prints `gated=ERROR(…)` with `STALE?` ("comparison impossible"), never
`gated=none` with a possibly-stale verdict below it.

The header's `ci=` is **one state for the whole PR, reduced from every row** of
`gh pr checks` — never the state of one row. Worst first: `fail` > unrecognised >
`pending` > `pass`, with skipped checks ignored (a table of nothing but skipped
checks prints `ci=skipping`, not `pass`: nothing ran) and a cancelled check counted
as a failure. A PR whose `Build & Test` passed beside a failed `Integration Tests`
is `ci=fail(Integration Tests)`; it used to print `ci=pass` — a red PR shown green —
and two `Build & Test` matrix rows printed a two-line value. A status gh does not
document is `ci=ERROR(unrecognised check <name> …)`, never green. The failing
checks are named in the header (up to three) and every non-passing check is listed
under it (up to five).

`gh pr checks` also encodes the PR's CI state in its exit status and still prints the
table on stdout: 0 every check passed, 8 some check is PENDING, 1 some check FAILED.
A non-zero exit **with rows** is therefore a successful read of a PR whose CI is not
green, not a failed one, and the exit status is a **floor** under the rows (1 is
never lighter than `fail`, 8 never lighter than `pending`), so a table that lost its
failing row cannot print green. `ci=ERROR(…)` is for a non-zero exit with **no** rows
on stdout, and for output that is not a table at all. A
`codex-verdict.md` that is prose only — non-empty, no `Verdict:` line — prints
`-- codex: PROSE (no verdict line)`; `INCOMPLETE` is reserved for the unfilled
template, an empty file or an unreadable one. Only a line that **is** the template's
`approve | approve-with-findings | blocked` (markdown decoration such as a bullet,
bold or backticks aside) counts as the unfilled template — a sentence that merely
quotes the three words is prose.
The sweep opens named files only (`gated.sha`, `.lock/pid`, `codex-verdict.md`,
`review.log`, `code.log`), so the `scope.<UTC>.md` copies `velo-gate-run` leaves in the
gate dir cannot be read as a verdict, a log or a sha.

---

## `velo-orchestrd` — the always-on checker

`velo-dispatch`, `velo-pr-gate` and `velo-merge` all start detached work and
return immediately, and nothing used to wake the orchestrating session when
that work finished — six gates and two workers once sat unprocessed overnight
for ~8 hours (#2285). `velo-orchestrd` is the fix: a macOS `launchd` agent that
runs every 300s, needs no model, and does five mechanical things per tick —
**detect, post, merge, dispatch, escalate**. It never asks a question a script
cannot answer; anything that needs judgement goes to `attention.jsonl` instead.

```bash
velo-orchestrd tick         # run one idempotent tick by hand (also the default)
velo-orchestrd install      # render + load ~/Library/LaunchAgents/ai.velostream.orchestrd.plist
velo-orchestrd uninstall    # bootout + remove the plist
velo-orchestrd status       # launchctl status + tail of orchestrd.log
```

**Kill switch.** `touch ~/.agents/state/orch/paused` stops every future tick
cold, before it does anything else — including the `gh auth status` check.
`rm` it to resume. The daemon merges PRs unattended, so there must be a
one-command way to stop it.

**Every tick, in order:**

1. **Paused?** — exit immediately if `orch/paused` exists.
2. **`gh auth status`** — escalate (kind `gh-auth`, deduped per day) and exit
   if it fails, rather than silently doing nothing every 5 minutes forever.
3. **Global lock** — `orch/.lock` (mkdir, pid inside, dead-holder reclaimed).
   One tick at a time; a second one skips rather than interleaving.
4. **Detect finished workers** — a NEW line in
   `~/.agents/state/records/<issue>.result.jsonl` (offset-tracked per issue)
   escalates `worker-finished`. Verify from git before any PR — never from
   the worker's own report.
5. **Detect + post finished gates** — a gate counts as finished when the
   reviewer's pid (persisted to `<log>.pid` by `velo-pr-gate`'s
   `gate_track_pid` — the single write-site it shares with PR1's in-process
   `GATE_PIDS`, so the two records can never drift apart at a launch site
   that forgets one half) has exited — a pid *known* to be gone. A pid file
   that cannot name a pid (empty, not a number, unreadable) is **not** a
   finished gate, any more than an absent one: judging a log that is still
   being written posts a partial review under the gate header, and the
   post-once guard then keeps the real report off the PR. The log says so on
   every tick. Posting always uses the sha recorded in
   `gate/<pr>/gated.sha`, written by `velo-pr-gate` **at launch, before any
   gate is dispatched** — its absence still escalates (`gate-nosha`) rather
   than risk stamping coverage the gate never had, but that is now the
   exceptional case (a gate dispatched before this file existed, or run some
   other way), not the normal one. Before posting it checks the PR's own
   comments for that exact `gate: <name> @ <sha>` header — a session's own
   fast path may have posted it first — and the actual `gh pr comment` call
   plus the authoritative `(pr, gate-name, sha)` lock + done-marker live
   INSIDE `velo-gate-post` itself, so a session relaying a `--wait` report by
   hand and this tick can never both post the same fact even if they race
   past this cheap pre-check at the same moment.
   - every needed gate **approve** → `velo-gate <pr> --pass`
   - any gate **blocked** → `velo-gate <pr> --block` + escalate `gate-blocked`
   - any gate **approve-with-findings** → escalate `gate-findings`, label untouched
   - a missing or unrecognised `**Verdict:**` line → escalate `gate-malformed`,
     label untouched. Real local-model output has drifted to `request-changes`
     and to `blocked.` (with a trailing period) — the parser is strict, not
     the report format.
   - one verdict from **every** `**Verdict:**` line: they must all agree and all
     parse. A report that opens with `approve` and later says `blocked` (a
     restated header, a re-check section, a quoted earlier round) is not an
     approve — it escalates `gate-malformed` for a human to read. It used to be
     the first line's verdict.
   - a verdict `velo-gate` **refuses to record** (a stale gate, gate comments it
     cannot read, a label it cannot set) escalates `gate-label-failed`, once per
     PR/head/label, carrying `velo-gate`'s own message. It is not logged as
     `gate:passed` — which is what it used to be, on every tick, behind a PR still
     labelled `gate:running`.
6. **Merge** — for every `gate:passed` PR: refuse (and escalate
   `agents-only-merge`) if every changed file is under `.agents/` — by
   POLICY, not because the tool can't: `velo-merge` itself now accepts an
   `.agents/`-only PR with no CI (ci.yml's `paths-ignore` skips non-Rust
   paths entirely, which is not "something is wrong" for this one
   file-shape), but tooling changes govern how every future gate/merge/
   dispatch behaves, so this daemon always defers that one file-shape to a
   human's final click regardless of what the tool now allows. For every
   other PR, run the real `velo-merge <pr>`; a stale-gate or CI-pending
   refusal is routine and self-healing (no escalation, next tick retries); a
   genuine CI failure escalates `ci-failed`. The actual `gh pr merge` call and
   its own `(pr, head-sha)` lock + done-marker live INSIDE `velo-merge`
   itself, so a session's own `--wait` loop and this daemon's tick can never
   both merge the same head.
7. **Dispatch** — pop one entry from `orch/queue.jsonl`
   (`{issue, brief, worker, brief_sha256}`, FIFO, popped unconditionally so a
   bad entry cannot wedge everything behind it) when fewer than
   `VELO_ORCH_WIP_CAP` (default 4) workers are live and at least
   `VELO_ORCH_MIN_DISK_GB` (default 25) is free. The pinned worker label and
   brief sha256 are **re-checked against live state** before dispatch — a
   mismatch drops the entry and escalates `dispatch-mismatch` rather than
   retrying a decision that is now wrong on every future tick. The entry is
   popped before anything is checked, so **every way it can fail to become a
   dispatch is escalated**, and the event says why:
   - `dispatch-malformed` — no numeric issue, no brief path, or no file at the
     brief path (the issue must be a number: an event is only recorded for one)
   - `dispatch-unreadable` — the issue's labels could not be read; carries gh's
     own message, and is not reported as "no worker label"
   - `dispatch-mismatch` — the pinned worker is not the issue's, the brief
     changed, or the issue has **more than one** `worker:` label (all are named:
     `velo-dispatch` refuses such an issue, so its first label is not "the"
     worker)
   - `dispatch-failed` — `velo-dispatch` itself refused (stale anchors, a brief
     that fails its lint, no disk, a dirty tree): carries the exit status and the
     last of its output, which also stays in `orchestrd.log`
8. **Wedge / STOP** — for every live worktree (`VELO_ORCH_WORKTREE_GLOB`,
   default `~/RustroverProjects/velostream-*`) whose worker pid is still
   alive: a STOP-trigger line in `agent.log` escalates `stop`; no `agent.log`
   growth for `VELO_ORCH_WEDGE_MINUTES` (default 30) — after a
   `VELO_ORCH_WEDGE_GRACE_MINUTES` (default 10) grace period so a
   freshly-dispatched worker's quiet index-build isn't mistaken for a wedge —
   escalates `wedge`.

**`attention.jsonl`** (`~/.agents/state/orch/attention.jsonl`) is one JSON
line per event: `{id, kind, pr, issue, sha, evidence, ts}`. The `id` — built
as `<kind>:<pr-or-issue>:<sha>` — is the only dedup key: appending the same id
twice is a no-op, so a fact that hasn't changed is never re-escalated, and a
new commit / new outcome naturally produces a new id. Dispatch events are the
one exception to the shape: a queue entry is popped after a single look, so a
re-queued entry is a new fact, and its id carries that attempt's own timestamp
and the daemon's pid instead of a sha — an id that deduped forever would have
swallowed the second drop of the same entry without a word.

```bash
velo-attention list          # every UNACKED event, oldest first
velo-attention ack <id>      # mark one handled
velo-attention ack --all     # mark every currently-unhandled event handled
velo-watch --attention       # BLOCK until one exists, then exit — run this
                              # in the background instead of polling `list`
```

There is no "unack" — the acked-ids file is a durable ledger of what a human
has already seen, not a queue a background process can silently drain.

### Integration after PR1 — done (#2285 Round 2)

This PR (`tooling/orchestrd`) started against `tooling/wait-and-enforce` (PR1)
still in flight, and deliberately did not touch `velo-dispatch`, `velo-merge`,
`velo-watch` or its hooks in its first round. PR1 has since merged
(`3436e0367`); all four deferred edits landed in the same PR, on top of a
rebase that resolved the resulting conflict in `velo-pr-gate` by keeping BOTH
PR1's in-process `GATE_PIDS` (what `--wait` itself waits on — a real `wait
<pid>` needs a direct child of the SAME shell) and this PR's persisted
`<log>.pid` (what a SEPARATE process, this daemon, reads across ticks),
unified behind one `gate_track_pid` call per launch site:

- **`velo-watch --attention`** — shipped. Blocks until `attention.jsonl` has
  an event nobody has acked, then exits; sources `velo-orch-lib.sh` so
  "unhandled" means the same thing here, in `velo-attention`, and in the
  daemon.
- **The `SessionStart` hook** (`session-start-inflight.sh`) — shipped. Lists
  unhandled attention events alongside in-flight gates/workers/PRs, and
  recommends `velo-watch --attention` specifically (in addition to the plain
  `velo-watch`) whenever one exists.
- **`velo-pr-gate` recording the gated sha at launch** — shipped. Computed
  once, before ANY gate is dispatched (moved out of the `code-review`-only
  block it used to live in, so a check-spec-only run gets one too) and
  written to `gate/<pr>/gated.sha`. `velo-gate-post` now prefers this file
  over the PR's live head whenever `--sha` is omitted, not just this daemon.
- **The shared post/merge-once guard** — shipped, but not where the original
  plan put it. Rather than threading a lock through every `--wait` caller
  AND this daemon separately, the `(pr, gate-name, sha)` lock + done-marker
  for posting lives INSIDE `velo-gate-post`, and the `(pr, head-sha)` lock +
  done-marker for merging lives INSIDE `velo-merge` — the one place each
  side effect (`gh pr comment`, `gh pr merge`) actually happens. Every caller
  — a human relaying a `--wait` report by hand, a `--wait` loop re-polling,
  or this daemon's own tick — is covered by construction, with nothing left
  for a caller to remember. Each guard looks at its done-marker twice: before
  the lock, and again once it holds it, so a caller delayed between the two
  cannot act on a fact the other has already acted on.
- **The `.agents`-only merge exception** — shipped in `velo-merge` itself (a
  `.agents/`-only PR with no CI now merges with a warn, not a die — gating
  still applies, only the CI expectation is waived, since ci.yml's
  `paths-ignore` means no lane ever runs for this shape at all). This
  daemon deliberately does NOT use that new capability — `step_merge` still
  refuses and escalates (`agents-only-merge`) for these, by policy: tooling
  changes govern every future gate/merge/dispatch, so they always get a
  human's final click here, regardless of what the tool itself now allows.

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
| `velo-merge` says `could not read PR #N (network\|rate-limit\|auth\|other)` | `gh pr view` FAILED — it is not "PR not found" (that is only gh's `Could not resolve to a PullRequest`). The message carries gh's own stderr. `--wait` retries network and rate-limit and stops on auth and other; a bad token (`gh auth login`) is never fixed by waiting |
| `velo-merge` says `could not read PR #N (payload)` | the opposite case: gh EXITED 0 but printed something that is not a PR — nothing, truncated JSON, an error page, `null`, an object missing a field it was asked for. The message says which and shows the first 200 bytes. gh did not fail, so this is no blip: `--wait` stops on it like `other` |
| `velo-merge` says `has ambiguous gate labels` | the PR carries two `gate:*` labels, so it has no verdict: one is stale (a `--remove-label` that failed, or a label added by hand). Re-record the verdict, which replaces them: `velo-gate <pr> --pass\|--block` |
| `velo-merge` says `CI has a check this script cannot classify` | a conclusion, status or check type `velo-ci-rollup.jq` does not recognise (GitHub added one). It is never read as green and waiting does not make it recognised: teach that file about it |
| `velo-merge` or `velo-status` says `cannot read the CI rollup definition` | `velo-ci-rollup.jq` is missing from beside the script. `install.sh` copies `bin/` whole — reinstall |
| `velo-pr-gate` or `velo-gate-run` says `the gate lock for #N … exists, but its holder cannot be identified` | the lock's pid file is empty, holds no pid or cannot be read, and the 10-poll grace (`VELO_GATE_LOCK_POLL`) produced none. It is deliberately NOT taken over: a gate that has only just started has not written its pid yet. If no gate is running for the PR, remove the lock directory the message names |
| `velo-attention list` shows `dispatch-failed` | `velo-dispatch` refused a queued dispatch. The event carries its exit status and the last of its output (all of it is in `orchestrd.log`); the entry was already popped, so fix the cause and queue it again |
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

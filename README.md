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
    velo-worktree-lib.sh           worktree derivations shared by velo-status + velo-record
    velo-openrouter-agent          wrapper -> the SDK worker (DeepSeek / GLM)
    velo-openrouter-agent-sdk.py   OpenRouter-backed worker runner
    velo-lmstudio-agent-sdk.py     local LM Studio worker runner
  tests/
    run.sh                         both suites, in seconds — run when touching .agents/
    test_runner_accounting.py      usage / leak / cost-provenance invariants
    test_record.sh                 STOP detection, outcome ladder, record writing
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
| LM Studio at `http://<host>:1234/v1` | the free local worker. Override the host with `VELO_LMSTUDIO_URL` (defaults to a LAN address). |
| `gh`, authenticated | issue/PR validation |
| `python3`, `jq`, `git`, `cargo`, `cargo-nextest`, `ast-grep` | dispatch + worker runtime |
| **Node 22+** (optional) | the `zg` discovery index built per worktree at dispatch. Absent, dispatch warns and workers fall back to `rg` + `ast-grep`. `npm i -g @zvec/zvec-grep` makes it fast; without it the `zg` shim falls back to `npx` per call |

Verify:

```bash
velo-dispatch 1898 /tmp/brief.txt --dry-run    # exercises every gate, launches nothing
velo-status
```

---

## The four workers

| skill | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | `qwen3-coder-next-mlx@6bit` (LM Studio) | **free** | default — scoped implementation, audits, anything latency-insensitive |
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
  ok dependencies closed
  ok anchors verified against tree
  ok blast radius: 94 refs (declared 94)
  ok brief satisfies the spec checklist
  ok disk: 223GB free
```

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

---

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

Codex is not launched by the script. It is an Agent call, and keeping it manual
keeps the expensive gate a conscious act — it has previously returned a task
handle instead of a report, and written into a live PR worktree, both from thin
briefing.

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

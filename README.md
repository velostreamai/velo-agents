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
  bin/
    velo-dispatch                  validate a ticket, prep the worktree, launch a worker
    velo-status                    one-shot state of every dispatched worker
    velo-openrouter-agent          wrapper -> the SDK worker (DeepSeek / GLM)
    velo-openrouter-agent-sdk.py   OpenRouter-backed worker runner
    velo-lmstudio-agent-sdk.py     local LM Studio worker runner
  rules/
    velo-impl.md                   MANDATORY implementation policy for every worker
    velo-brief-spec.md             what a task brief MUST contain, and why
  skills/
    velo-deepseek/SKILL.md         orchestrator-facing routing + usage
    velo-glm/SKILL.md
    velo-local/SKILL.md
  tasks/
    SCHEMA.md                      task-spec format
    <issue>.json                   per-issue machine-checkable spec
```

## Installation

The tooling is used from `~/.agents/`; this directory is the versioned source.

```bash
mkdir -p ~/.agents ~/.claude/skills
cp -R .agents/bin .agents/rules .agents/skills ~/.agents/
chmod +x ~/.agents/bin/velo-dispatch ~/.agents/bin/velo-status \
         ~/.agents/bin/velo-openrouter-agent ~/.agents/bin/*.py

# make the skills visible to Claude Code
for s in velo-deepseek velo-glm velo-local; do
  mkdir -p ~/.claude/skills/$s
  ln -sf ~/.agents/skills/$s/SKILL.md ~/.claude/skills/$s/SKILL.md
done

export PATH="$HOME/.agents/bin:$PATH"      # add to ~/.zshrc
```

### Requirements

| need | for |
|---|---|
| `OPENROUTER_API_KEY` in the environment | DeepSeek and GLM workers |
| LM Studio at `http://<host>:1234/v1` | the free local worker. Override the host with `VELO_LMSTUDIO_URL` (defaults to a LAN address). |
| `gh`, authenticated | issue/PR validation |
| `python3`, `jq`, `git`, `cargo`, `cargo-nextest`, `ast-grep` | dispatch + worker runtime |

Verify:

```bash
velo-dispatch 1898 /tmp/brief.txt --dry-run    # exercises every gate, launches nothing
velo-status
```

---

## The three workers

| skill | model | cost | pick it for |
|---|---|---|---|
| `velo-local` | `qwen3-coder-next-mlx@6bit` (LM Studio) | **free** | default — scoped implementation, audits, anything latency-insensitive |
| `velo-deepseek` | `deepseek/deepseek-v4-flash-0731` | **very cheap** | fast scoped implementation against a pinned design |
| `velo-glm` | `z-ai/glm-5.3-flash` | **pricier, good value** | multi-step reasoning, per-case classification judgement |

Cost-first: default to local, reach for DeepSeek when turnaround matters, spend
GLM deliberately. They share one policy and can run **concurrently** — give each
its own git worktree and non-overlapping files.

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

### 4. Dispatch

```bash
velo-dispatch 1898 /tmp/brief-1898.txt
```

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

### 5. Watch, then **verify from git**

```bash
velo-status -v
git -C ~/RustroverProjects/velostream-1898 log --oneline origin/master..HEAD
```

A worker's own report is not evidence. A worker that commits looks "unchanged"
to its runner, and one that emits a tool call as plain text reports success
having executed nothing (`velo-status` flags that as `LEAKED`).

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

Gate a PR with an independent reviewer plus `check-code`; add `check-spec` when
the issue has multiple acceptance bars. Start every gate comment with:

```
gate: <name> @ <sha>
```

A gate result is only valid for the commit it ran against — a PR's CI was once
green against a commit that had already been replaced. Comparing that SHA to
the PR's `headRefOid` is the whole staleness check.

---

## Troubleshooting

| symptom | cause |
|---|---|
| worker dies mid-run, no error in its log | disk full. `df -h`; `rm -rf <merged-worktree>/target` |
| run ends `exceeded 1800s` | raise `--prompt-timeout`; ensure the brief mandates incremental commits |
| `leaked_tool_calls=N` | model emitted a tool call as text; it never ran. Report is untrustworthy — re-run, keep quoting simple |
| runner says "no worktree changes" but work exists | fixed: the snapshot now includes `HEAD`, so a commit counts as a change |
| every worker shows `done` immediately | check the process is actually detached (`nohup … &`) |

## Editing this tooling

`~/.agents/` is the live copy; **this directory is the source of truth**. Change
here, commit, then re-run the install step. A change made only in `~/.agents/`
is lost on the next sync.

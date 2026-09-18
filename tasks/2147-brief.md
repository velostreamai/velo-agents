# #2147 — fix the two P1s in the JoinLayout hoist (PR #2146)

BRANCH: perf/join-layout-hoist
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2147

HEAD `284084986`. This is an EXISTING worktree with PR #2146 open on it — you are
adding to that PR, not starting fresh. Do NOT cut a new worktree.
**Parent:** #1970. **PR:** #2146, open and mid-review — it stays open; you are adding to it.
**Do NOT `cd` into the worktree.** Use `git -C <path>` and
`cargo --manifest-path <path>/Cargo.toml`. The single exception is the final
`run-commit.sh` gate, which must run from the worktree root — use the
`(cd … && ./run-commit.sh --fast)` form in §4 for that one command only.

## 0. Read this first — the pattern you are here to break

PR #2146 caches a `JoinLayout` beside the joined Arrow schema. **That caching is what creates these bugs.** Before it, the layout was rebuilt on every probe from the live schemas, so any stale cache disagreed with it and `RecordBatch::try_new` raised `SqlError`. Staleness was loud *by accident*.

Caching it made staleness silent, so invalidation triggers have been added. There are now two:

1. generation mismatch in `ensure_build_side` clears `projection_layout` then `joined_schema` (`:611-618`);
2. the cache is keyed on the probe schema it was derived against (`:312-315`).

**Every review round so far has fixed one trigger and missed its sibling.** Round 1 added trigger 1 and left the probe side open. Round 2 added trigger 2 and did not wire it into trigger 1's clear. That is the third instance, and it is why acceptance bar 1 asks for ONE routine rather than two call sites kept in step by hand.

Three opus review rounds missed both of the findings below. Codex, on a different model, found them in one pass.

## 0a. Use `zg` to enumerate the triggers — this is the tool the task needs

The workspace index is **already built** for this worktree (`zg status`: 2,757 files,
52,904 entities, 100% coverage). Use `zg query` for the one thing this task keeps
getting wrong: **finding every place the cache is cleared or repopulated.**

Three rounds have now each fixed one trigger and missed its sibling. That is a
*discovery* failure, not a reasoning failure — grep finds the spelling you already
thought of, which is exactly the wrong tool when the bug is the site you did not
think of. A semantic query over the index returns the set.

Verified working before this brief was written:

    zg query "where the joined schema cache is cleared or repopulated"

returns `generation_bump_clears_the_derived_schema_cache_not_just_build_side`,
`p936_invalidate_build_side_also_clears_joined_schema_cache`, `JoinOperator`
itself, and the surrounding cache tests — i.e. the trigger set, not just a name
match.

**Before you write the unified routine in §1, enumerate the callers with `zg` and
put the list in your report.** If it finds a trigger this brief does not mention,
that is a finding — say so rather than silently folding it in.

`ast-grep` remains the tool for the structural edit once you know the sites;
`zg` is for finding them. Do not use plain grep to decide the set is complete.

## 1. P1(a) — the probe-schema miss leaves `projection_layout` stale

`join_operator.rs:338`. The probe-schema cache miss rebuilds `(schema, layout, probe)` and **does not clear `projection_layout`**. Projection indices resolved against probe v1 are then applied to probe v2 via `ensure_projection_layout` (`:388`).

Consequence: wrong-column selection whenever the types happen to match. No protection in release builds.

The generation path already clears `projection_layout` **then** `joined_schema` — most-derived first — and `invalidate_build_side`'s doc (`:476-489`) explains why that order matters. The probe-schema path was added later and never joined it.

## 2. P1(b) — invalidation is not atomic with repopulation

`join_operator.rs:640`. Sequence:

1. thread A detects a generation mismatch, clears `projection_layout` and `joined_schema`;
2. **before A replaces `build_side`**, an in-flight thread B — still holding the OLD build side — reaches `:338`, rebuilds, and stores a `(schema, layout, probe)` triple derived from the superseded generation;
3. a later probe with the same probe schema reads that stale pair at `:312-315` and silently omits the newly-added build columns.

A previous round examined this window and cleared it, reasoning it was "pre-existing and identical in `invalidate_build_side`". **That was wrong.** A thread holding a stale clone is not the same as a thread *repopulating into* the window.

State the mechanism that makes this impossible. Do not reorder locks and assert it.

## 3. The tests are the hard part

Both existing tests **pass and cover neither P1**:

- `generation_bump_clears_the_derived_schema_cache_not_just_build_side` — checks `joined_schema_populated()` at rest. No concurrency, no projection interaction.
- `p2146_probe_schema_change_is_not_served_from_the_cached_pair` — discards the layout, never exercises the cached take/projection path.

So write tests that reach the defects, and **mutation-prove each one**:

```
# disable the fix, run the test, capture the failure
# restore the fix, run it again, capture the pass
```

Put both observations in your report, with the commands. A test that passes for the wrong reason is worse than none — that has already happened twice here.

P1(b) is a race; a deterministic test may need the two steps driven explicitly rather than by threads. If you cannot make it deterministic, say so and pin what you can, rather than shipping a flaky test or a vacuous one.

### The declared contract, by name

`fail_to_pass` — must go red→green, and each must be mutation-proved:

| test | pins |
|---|---|
| `probe_schema_miss_also_clears_the_projection_layout` | P1(a) |
| `invalidation_cannot_be_repopulated_from_a_superseded_generation` | P1(b) |

`pass_to_stay` — must still pass when you are done:

| test | why it is the canary |
|---|---|
| `generation_bump_clears_the_derived_schema_cache_not_just_build_side` | trigger 1 still fires |
| `p2146_probe_schema_change_is_not_served_from_the_cached_pair` | trigger 2 still fires |
| `p936_invalidate_build_side_also_clears_joined_schema_cache` | the hook's own contract, most-derived-first |
| `p936_joined_schema_alloc_once_across_n_probes` | **the one that catches over-clearing** — if your fix invalidates too eagerly, the cache stops being alloc-once and this reddens |
| `cache_rebuilds_after_table_insert` | the generation path still rebuilds at all |

`p936_joined_schema_alloc_once_across_n_probes` is the one to watch. The cheap way to "fix" both P1s is to clear more often; that trades silent wrong data for silently losing the caching this PR exists for, and this test is what notices.

## 4. Validation

```
cargo check --no-default-features --manifest-path ~/RustroverProjects/velostream-2147/Cargo.toml
cargo nextest run --no-default-features --profile unit --lib --test mod -E 'test(/join|take_path|cache_invalidation/)' --manifest-path ~/RustroverProjects/velostream-2147/Cargo.toml
```

`--profile unit` is mandatory (#2103): without it the sweep enqueues Kafka testcontainers and long benches that fail on contention and look like your change broke things.

Final gate, once, from the worktree root: `(cd ~/RustroverProjects/velostream-2147 && ./run-commit.sh --fast)`. It wet-applies `cargo fmt` — run `git status` afterwards and commit any reformatting.

## 5. Commit incrementally

Commit after each logical step. A timeout must never lose completed work; small commits are expected and will be squashed at merge. Before starting a long step — the full gate, a multi-file edit — commit what you already have.

## 6. Scope — do not widen

- **Do not touch the `take` kernels.** They are ~26% of this workload and the real optimisation target, but that is late-materialisation-vs-eager-gather, a separate architectural question, and not this issue.
- Do not revert the hoist.
- Do not touch #2138's four `JoinProcessor` sites (different PR; they profile 0.00% here).
- **Do not claim a performance change.** The numbers are measured and already in the PR body. This is correctness work.

## 7. Already ruled out — do not re-investigate

Codex confirmed:

- the cached `JoinLayout` construction matches the retained `None` arm **exactly** — probe fields, build fields, `contains('.')` branch, source/alias arguments;
- alias / source-name mutation is unreachable in production (metadata set at construction, private).

**Open but unverified:** `from_table_data` derives build column names from row 0's `FieldMap` hash order, which could shift at equal generation. No production caller was found. If you happen to find one, report it — do not chase it speculatively.

## 8. STOP conditions

**STOP and report** on any of the following: halt work, write the trigger and its evidence to `agent.log`, and report back. Do not push, do not comment on the issue, do not work around it.

- **Making the invalidation atomic requires changing the lock discipline** in a way that risks deadlock, or holding a lock across the schema build. Report the design instead of shipping it — `invalidate_build_side`'s doc (`:476-489`) explains the existing most-derived-first order and why.
- **A new test cannot be made to fail with the fix disabled.** It does not reach the defect. Report it rather than counting it as coverage — that has already happened twice on this PR.
- **`p936_joined_schema_alloc_once_across_n_probes` goes red.** Your fix is clearing too eagerly and has traded silent wrong data for silently losing the caching this PR exists for.
- **You find a THIRD invalidation trigger** that neither clears the derived caches nor keys on its inputs. Report it — that is evidence the single-routine approach in §1 is required rather than preferred.
- **You find a production caller** that makes the `from_table_data` row-0 hash-order vector reachable at equal generation. Codex marked it UNVERIFIED; a confirmed caller changes scope and is an orchestrator decision.
- `./run-commit.sh --fast` fails for any reason.

## 9. Commit / push authorization

**Committing on `perf/join-layout-hoist` IS authorised** — this brief is that authorisation. Commit incrementally per §5.

**NOT authorised:** pushing, opening or editing a PR, merging, commenting on the issue, committing on `master`, or committing in any other worktree. PR #2146 is open and mid-review; the orchestrator handles the push and the gate.

## 10. Report

What you changed, the mutation-proof output for each new test, the `--fast` result, and anything you hit a STOP condition on. Not a code review of your own diff.

# #2000 — join coordinator null-pad must use the relation's column union

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2000
BRANCH:   fix/2000-auto (already cut fresh from origin/master, already checked
          out in that worktree — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, and absolute
paths with Read/Edit/Write.

## READ THIS FIRST — the issue body is overstated, and its own filer says so

Read the **first comment** on #2000 before the body. The body implies null-padding
always derives its column set from a sampled record. **It does not.** Both
null-pad batch merges consult a plan-time layout FIRST:

```rust
// join/coordinator/mod.rs:3962 (merge_left_with_nulls_batch)
// join/coordinator/mod.rs:3992 (merge_right_with_nulls_batch)
if let Some(layout) = self.output_layout.as_ref() {
    return Self::build_null_pad_envelope(lefts, &layout.row_schema, JoinSide::Left);
}
// only THEN falls back to seen_*_fields
```

`seen_*_fields` is a **deliberate documented fallback**, not an overlooked bug.
The previous dispatch on this issue was briefed without this and stalled for 38
minutes trying to build a failing test for a path it was never told how to
reach. Do not repeat that.

## When the fallback IS reached — measured, not assumed

`output_layout` is set only by `with_output_schema`, and is `None` in exactly
two shapes:

1. **Self-join.** `with_output_schema` returns early without setting it:
   ```rust
   // coordinator/mod.rs:503
   // Self-joins would emit identical `{source}.f` entries for both sides,
   // violating the byte-identity invariant.  Leave output_layout=None so
   // the legacy build-from-pair path is used.
   if self.config.left_source == self.config.right_source { return self; }
   ```
2. **`cache_inputs` absent** at `engine/interval_join.rs:270` —
   `with_output_schema` is only called `if let Some((schema, lf, rf)) = cache_inputs.as_ref()`.

**Your regression test must use one of those two shapes.** An ordinary
two-relation interval join with cache_inputs wired will take the layout path and
your test will pass against unmodified master, proving nothing. A self-join is
the cheapest reachable shape.

## What the fix actually is

Given the fallback is deliberate and self-joins *require* it (the byte-identity
invariant is why `output_layout` is None there), **failing loudly is the wrong
answer for this path** — it would break self-joins outright. The fix is to make
the fallback correct: widen the remembered column set instead of freezing row 0's.

## Anchors — all `grep -n` verified at dispatch time against `8daed48e1`

```
src/velostream/sql/execution/join/coordinator/mod.rs:217   seen_left_fields: Option<Arc<[FieldName]>>
src/velostream/sql/execution/join/coordinator/mod.rs:2214  fn remember_side_fields(...)
src/velostream/sql/execution/join/coordinator/mod.rs:2219  if slot.is_none() {        <-- FIRST record only
src/velostream/sql/execution/join/coordinator/mod.rs:3997  .seen_left_fields
src/velostream/sql/execution/join/coordinator/mod.rs:6021  fn build_from_pair(
src/velostream/sql/execution/join/coordinator/mod.rs:6041  fn build_from_field_names(
src/velostream/sql/execution/processors/join.rs:723        fn field_names_for_source(
src/velostream/sql/execution/processors/join.rs:743        ["id","name","value","amount","timestamp"]   <-- fabricated
src/velostream/sql/execution/processors/join.rs:690,801    its two callers
src/velostream/sql/execution/processors/stream_table_join.rs:604  .column_names()  <-- the reference fix (#1988)
```

Note the issue body writes the coordinator path as
`processors/join/coordinator/mod.rs`. That is **wrong** — the real path is
`execution/join/coordinator/mod.rs`, with no `processors/` segment.

## Pinned design — do NOT choose an alternative

Three parts. All three are decided. If you believe any is wrong, **STOP and
report why; do not substitute your own approach.**

### Part A — the coordinator's column set

**Prefer the relation's registered schema. Where there is none, accumulate a
running union across observed records instead of capturing the first.**

Concretely at `mod.rs:2219`: replace the `if slot.is_none()` capture with a
union-extend, so a later record carrying extra columns widens the set rather
than being ignored. Apply the same correction to `build_from_pair`
(`mod.rs:6021`), which samples one record per side.

**Document this known limit in the code**: a pad emitted *before* a wider
record arrives still cannot contain that record's columns. A running union
fixes heterogeneity going forward; it cannot see the future. That residual is
acceptable and must be stated in a comment, not silently left.

### Part B — the fabricated five-column fallback

**This part is uncontested** — the filer's correction calls it "a separate and
arguably worse instance of inventing a column set", untouched by the layout
path. If you only complete one part, make it this one.

`field_names_for_source` (`join.rs:723`) returns
`["id","name","value","amount","timestamp"]` when a relation has neither a
registered schema nor a sample row. Those five names are **invented** — any
other column on such a relation is absent by construction, and a row is emitted
carrying five columns that the relation may not have.

**Delete the guess and fail loudly** — return an error naming the relation and
saying its schema is unknown. Do not return an empty set silently; do not keep
the guess behind a flag. This repo's standing rule is one predictable path,
surfaced, never a silent fallback.

**If existing tests depend on those five fabricated names, that is the defect
becoming visible — STOP and report which tests and what they assert. Do NOT
edit those tests to keep the guess alive.**

### Part C — the tests

A regression test with a genuinely **heterogeneous** side (rows beyond the
first carrying extra columns), covering:

- LEFT OUTER expiry and FULL OUTER expiry
- **both** the bare-name-collision and no-collision variants — they fail
  differently (hard error vs silent `Null`) and one passing does not imply the
  other

The existing regression —
`regression_left_join_nullfill_preserves_per_row_identity_non_contiguous` in
`tests/unit/sql/execution/processors/join/left_join_nullfill_row_identity_test.rs`
— uses a single **homogeneous** shape, which is why this was never caught. It
must stay green. Do not modify it; add alongside.

## Blast radius — measured at dispatch time

| pattern | refs | files |
|---|---|---|
| `seen_left_fields` / `seen_right_fields` | 10 | **1** (`coordinator/mod.rs`) |
| `build_from_field_names` / `build_from_pair` | 34 | src + tests |
| `merge_left_with_nulls` / `merge_right_with_nulls` | 38 | src + tests |
| `field_names_for_source` | — | **1** (`processors/join.rs`) |

Both production changes are confined to **two files**. Tests will add a third.

**Tripwire: if you are editing more than 4 files, STOP — you have taken the
wrong approach.**

## FIRST ACTION, before anything else

Append a line to `agent.log` with a real `date -u +%FT%TZ` timestamp every ~10
minutes, starting now. A previous dispatch on this exact issue was killed after
38 minutes having written one log line and produced three consecutive empty
turns. Silence is indistinguishable from a wedge, and it is the reason that run
was killed rather than waited on.

## Reachability — read this before you start

The issue was filed from a **reasoning-only** review finding. The reviewer
could not construct an end-to-end production query that reaches it; the code
claims were re-verified against master but the *path* was not reproduced.

So: **your first task is to establish reachability**, before changing
anything. Write the heterogeneous-side test FIRST and confirm it fails against
unmodified master.

**If it does not fail — if you cannot construct any input that reaches the
sampled-set path with a heterogeneous side — that is a legitimate and valuable
outcome. STOP and report exactly what you tried and why the path appears
unreachable.** Do not change production code to fix a defect you could not
demonstrate. A "fix" for an unreachable path is churn, and the honest negative
result is worth more.

**Take that exit early rather than grinding.** Concretely: if you have spent
more than ~30 minutes without a failing test, write what you tried to
`agent.log`, commit any test scaffolding you built, and report the negative
result. That is a COMPLETED run, not a failed one. Do not keep searching in
silence — the previous dispatch did exactly that and produced nothing at all,
where a negative result would have been genuinely useful.

## STOP conditions

1. The heterogeneous test does not fail against unmodified master (see above).
2. Existing tests depend on the five fabricated column names.
3. The union change requires altering the `LogicalPlan` node shape or the
   coordinator's public API — that is a structural decision, not yours.
4. You are editing more than 4 files.
5. Full-suite failures rise above 0. **Baseline: 12378 passed / 0 failed.**
6. You would delete, `#[ignore]`, or narrow any existing test.
7. Fixing this appears to require also fixing #1987 (batch JOIN drops the
   SELECT projection) or #1994 (`HAVING` not in the main rewrite). Both are
   **out of scope** — separate issues, separate dispatches.

## Validation

Redirect to a file and grep it — do not rely on captured terminal output:

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-2000/Cargo.toml \
  > /tmp/2000.log 2>&1
grep -E "^ *Summary" /tmp/2000.log
grep -E "^ *FAIL" /tmp/2000.log | awk '{print $NF}' | sort -u
```

Then the gate, from the worktree root:

```
(cd /Users/neilavery/RustroverProjects/velostream-2000 && ./run-commit.sh --fast)
```

It runs `cargo fmt --all` as a **wet apply** — after it completes, run
`git -C ... status` and commit any reformatting it produced.

## Commits

Commit after each green step, prefixed `[#1749] #2000:`. Do NOT push. Do NOT
open a PR. Earlier runs on this umbrella lost work to a timeout and to a quota
limit mid-flight — incremental commits are how that work survives.

## Streaming-compliance

This touches join OUTER/expiry paths and record metadata. Per policy, log a
`STREAMING-COMPLIANCE-CHECK` line in `agent.log` before the change and a
`STREAMING-COMPLIANCE-AFTER` line before reporting, covering per-row metadata
fidelity (invariant 1) and event-time ordering (invariant 3) at minimum —
`StreamRecord::project_into` preserves the base record's event_time for outer
joins (`processors/join.rs:720`) and that must remain true.

## Reference

`docs/architecture/name-binding.md` §1 rules 1-3, §1b, §3 (the four physical
join layouts). `src/velostream/sql/CLAUDE.md`. Root `CLAUDE.md`, `tests/CLAUDE.md`.

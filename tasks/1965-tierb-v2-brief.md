# #1965 tier B — the per-phase completeness check, v2

WORKTREE: /Users/neilavery/RustroverProjects/velostream-1965
BRANCH:   fix/1965-tierb-v2 (cut fresh from origin/master)

Do NOT `cd` into the worktree — it triggers a hook-trust prompt and stalls the
run. Use `git -C <path>`, `cargo --manifest-path <path>/Cargo.toml`, and
absolute paths with Read/Edit/Write.

## Why v2, and what changed under you

An earlier attempt lives on `fix/1965-auto` (commits `b7901a0db`,
`37e7e031f`). **Read it — it is useful — but do not assume it is right.** It was
written before #1966 landed, against an architecture that no longer exists.

Since then, on master:

- **#1966 (merged)** — binding is now a **phase**, not an optimizer rule.
  `bind_plan()` in `plan/mod.rs` runs `ColumnResolution` BEFORE the optimizer and
  propagates failure with `?`. It is no longer wrapped by the log-and-revert
  fallback. Both production callers (`build_plan_inner`, `execute_explain`) go
  through that one helper.
- **#1996 (merged)** — `name-binding.md` §1b and §1c corrected. Read §1c: it is
  the predicate you are implementing, and it has already been wrong twice.
- **#1967's decision** — the carrier is the per-`Scan` `SchemaAuthority`
  (`Declared` / `Sampled` / `Unknown`). No new `Expr` variant, no plan type
  parameter. **Settled — do not revisit.**

## The predicate (name-binding.md §1c — read it, do not work from this summary)

A non-system `Expr::Column` is a binding failure when **ALL THREE** hold:

1. its governing `Scan` has `SchemaAuthority::Declared`;
2. it sits in a position `ColumnResolution` actually rewrites;
3. it is not `*`, a `__cse_` slot, or a system column.

Condition 2 has TWO known exclusions, both already in §1c:
- **`Sort.order_by`** — passed through verbatim; `OrderProcessor` resolves sort
  keys by name against the OUTPUT batch (`logical.rs` states this contract).
- **HAVING's aggregate-argument sub-expressions** — HAVING is a `Filter` ABOVE
  the `Aggregate`; it IS visited, but resolves against the Aggregate's OUTPUT
  schema, which has no raw input columns. Only the diagnostic-only
  `rewrite_having_aggregate_arguments` re-resolves them, on a CLONE.

**Condition 2 must be derived from the resolver's coverage, not a
hand-maintained exemption list.** A list drifts from the rule it describes and
the drift is silent.

## What #1966 gives you that v1 did not have

v1's check could not be made correct, and the reason is on #1965: the resolver
leaves a column intact exactly when it is absent from **that node's input
schema**, which diverges from the governing `Scan`'s schema the moment any node
narrows it. Concretely, for
`SELECT SUM(CASE WHEN side='BUY' THEN quantity END) … GROUP BY symbol`, the
`Project` above the `Aggregate` legitimately holds an unresolved `quantity`.

**A named binding phase is what makes "was this resolvable at THIS level?"
answerable.** That is the question your check must ask. If after investigating
you conclude it still is not answerable, that is a legitimate finding — report
it with evidence rather than approximating.

## Known-good from v1 (verify, then reuse)

- The check must run as a **gate**, AFTER `apply_strict_gate`, on the gated
  paths only. v1 initially ran it inside `build_plan_inner`, which pre-empted
  the strict gate AND fired on `build_plan_no_gate` — a path that `.expect()`s
  the result, so a gate there is a PANIC. That fix is in `37e7e031f`.
- The strict gate owns the cases it already covers and returns
  `SchemaResolutionFailed`, which carries `source` + `columns` structurally.
  #1748 R5's pinpointed message is built from that shape.

## STOP conditions — STOP and report, do not work around

1. The check would reject a plan whose governing scan is `Sampled` or
   `Unknown`. That breaks deferred binding, which is the point of the predicate.
2. You would satisfy condition 2 with a hand-maintained list of exempt positions
   rather than deriving it from the resolver's coverage.
3. You would rewrite the tests that expect `SchemaResolutionFailed` to expect
   your new variant. There were twelve; `SchemaResolutionFailed` carries
   structure #1748 R5 depends on.
4. You would fix #1994 (making `HAVING` part of the main rewrite) as part of
   this. Out of scope — the check must DESCRIBE the resolver, not compensate.
5. A test you add passes with your production change reverted. **Verify this
   explicitly for at least one test**: revert the change, run it, confirm it
   FAILS, restore. A vacuous test was written on this umbrella already and was
   only caught by review.
6. Full-suite failures do not reach 0. Baseline on master: **12362 passed / 0
   failed**.

## Incremental commits — MANDATORY

Commit after each green step, prefixed `[#1749] #1965 tier B:`. Earlier runs on
this umbrella lost work to a timeout and to a quota limit mid-flight. Do NOT
push. Do NOT open a PR.

## Verify

Redirect to a file and grep it — a previous run could not see its own failures
because it relied on captured terminal output:

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-1965/Cargo.toml \
  > /tmp/1965v2.log 2>&1
grep -E "^ *Summary" /tmp/1965v2.log
grep -E "^ *FAIL" /tmp/1965v2.log | awk '{print $NF}' | sort -u
```

## Grammar reference

`docs/architecture/name-binding.md` §1 rules 1-3, §1b, §1c, §3.
`docs/claude/SQL_GRAMMAR_RULES.md`, `docs/sql/PARSER_GRAMMAR.md`.
Clause order post-#1962: SELECT -> FROM -> JOIN -> WHERE -> WINDOW -> GROUP BY
-> HAVING -> ORDER BY -> LIMIT. **DO NOT GUESS SQL SYNTAX.**

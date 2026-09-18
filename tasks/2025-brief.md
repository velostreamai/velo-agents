# #2025 — EmitWithNulls must NULL-fill the table's real columns

WORKTREE: /Users/neilavery/RustroverProjects/velostream-2025
BRANCH:   fix/2025-auto (already cut fresh from origin/master and already checked
          out — do NOT create another branch)

Do NOT `cd` into the worktree except for `gh` commands (`gh` has no `-C`).
Use `git -C`, `cargo --manifest-path`, and absolute paths with Read/Edit/Write.

## Read the issue's second comment first

#2025's follow-up comment records a scoping spike. It establishes reachability
and names the trap in the existing test. Do not re-derive either.

## The defect

`stream_table_join.rs:1187-1190`, `TableMissingDataStrategy::EmitWithNulls`:

```rust
// Create a record with NULL values for expected fields
let mut null_record = FieldMap::default();
// For now, just add a few common fields with NULL
null_record.insert(field_name("id"), FieldValue::Null);
null_record.insert(field_name("name"), FieldValue::Null);
null_record.insert(field_name("value"), FieldValue::Null);
```

Three **invented** column names. It is the last surviving instance of the class
#2000 removed from `field_names_for_source`. A fabricated name is worse than
absence: it can **collide** with a real column on the stream side and make a
genuinely-invalid reference resolve to NULL instead of erroring.

## The fix is threading — the async sibling already does it

`graceful_degradation.rs::add_null_fields` has always taken
`expected_table_fields: &[String]`. This sync copy never threaded it.

`handle_missing_table_data_sync` has three call sites — `:1022`, `:1153`,
`:1160` — and both enclosing functions already hold a table:

```
stream_table_join.rs:961   optimized_table: &crate::velostream::table::OptimizedTableImpl
stream_table_join.rs:1116  table: &Arc<dyn UnifiedTable>
```

Both expose `UnifiedTable::column_names()`. Add the parameter, pass
`column_names()` at each site, build the null record from it. **Mirror
`add_null_fields`; do not invent a second shape.**

## Reachability is ESTABLISHED — do not re-litigate

Emitting an empty `FieldMap` from this arm turns
`test_batch_processing_with_graceful_degradation` red with `u.id` absent
(`left: None, right: Some(Null)`). That test drives
`process_batch_stream_table_join`, so the batch path reaches this handler and
this handler produces the `u.*` columns.

## The two traps — this is the actual work

**1. The fixture is under-specified, and that is WHY the fabrication survived.**
`MockEmptyTable` (`graceful_degradation_test.rs:23`) does not override
`column_names()`. The default derives columns from records; the mock has none;
so it reports an **empty** column set. A table with no ROWS still has a SCHEMA —
give it one.

**2. The existing assertion cannot discriminate.**
`test_batch_processing_with_graceful_degradation:316` asserts only `u.id` and
`u.name` are NULL. Both are plausible real columns **and** members of the
fabricated `[id, name, value]` set, so the test passes either way — restoring
the fabrication would leave the suite green.

You need a **discriminating pair**:
- a column **declared but never fabricated** (e.g. `tier`) → must be NULL;
- a column **fabricated but not declared** (`value`) → must be **ABSENT**.

Add to the existing assertions; do not weaken them.

## Verify the test bites — and COMMIT BEFORE YOU DO

The named test must FAIL against master with your new assertions.

**Commit your production change BEFORE running any revert-check.**
`git checkout HEAD -- <path>` on an uncommitted edit destroys it, and on a fresh
branch `HEAD` *is* master. That silently wiped this fix twice during scoping,
and the second time produced a probe that looked like evidence and was not.

## STOP conditions

**STOP and report** — do not work around any of these:

1. You cannot make the named test FAIL against master with the discriminating
   assertions — **STOP and report** rather than shipping a test that cannot
   detect the defect. That is a valuable negative result about reachability.
2. Threading the parameter requires changing a public signature outside
   `stream_table_join.rs` — **STOP and report**; that is wider than this spec
   pins.
3. More than ~5 tests fail — **STOP and report** the list before changing any of
   them.
4. You would need to delete, `#[ignore]` or narrow any existing test — **STOP**.
5. The fixture change makes an unrelated test fail — **STOP and report** which;
   declaring the mock's schema is meant to be additive.

## Validation

```
cargo nextest run --no-default-features --no-fail-fast --lib --test mod \
  --manifest-path /Users/neilavery/RustroverProjects/velostream-2025/Cargo.toml \
  > /tmp/2025.log 2>&1
grep -E "^ *Summary" /tmp/2025.log
grep -E "^ *FAIL " /tmp/2025.log | awk '{print $NF}' | sort -u
```

**Do NOT use `--lib --test mod` as your only gate** — it pulls in
broker-dependent Kafka integration tests that fail with `AllBrokersDown` on a
machine without a broker. That killed a dispatch this session. The real gate is:

```
(cd /Users/neilavery/RustroverProjects/velostream-2025 && ./run-commit.sh --fast)
```

It wet-applies `cargo fmt --all` — afterwards run `git -C ... status` and commit
any reformatting. `--fast` does **not** build `--release`; also run
`cargo build --release --no-default-features --bin velo-sql`. A `debug_assert!`
body compiles in release and broke CI that way this session.

## Incremental commits — MANDATORY

Commit after each logical step, prefixed `[#1749] #2025:`. Do NOT push. Do NOT
open a PR.

## Logging

`agent.log` in the worktree root, real `date -u +%FT%TZ` timestamps, heartbeat
every ~10 minutes. Silence reads as a stall and gets the run killed.

## PRE-GATE SWEEP (mandatory; paste into every worker brief; each item gets a CLASS-SWEEP line before push)

Past gate rounds on this stream found these shapes one per round. Sweep them BEFORE the first push.

1. SECOND PARSER / SECOND PREDICATE. If you wrote a check, parser or name-match that mirrors what a route's decoder does (header parse, field-name match, BOM/whitespace/quote handling, blank lines, case rules), do NOT write a parallel copy. Call the SAME function the route uses. If impossible, add a test per route that feeds BOM, padded fields, blank first line, quoted fields, mixed case, and asserts check and rows AGREE (both accept and read, or both fail).
2. BATCH-CONSTANT WORK IN A ROW LOOP. Anything constant for a batch (column index, name lookup, error text, config, format dispatch, allocation) is computed once before the loop. Grep your loop bodies for by-name lookups, format!/to_string/clone of batch-constant values, Vec/HashMap construction.
3. EVERY ROUTE. List every route/reader/strategy/format that reaches the changed code (CSV batch, JSONL, JSON array, single-record, per-line, Avro, Parquet, mmap, table/CTAS, time-window, memory-based, low-latency). State for each: fixed, or why identical.
4. OPTED-OUT IDENTITY. With the feature unused, behaviour and cost are byte-identical. One test.
5. ERROR PATHS. Every new Err is surfaced (job-fatal or per-row refusal as the spec says), never logged-and-continued, never swallowed; the message names source, field, and cause.
6. PER-ROW NOT PER-BATCH. A bad row refuses that row only; later rows keep their position.

## SIZE CAP (orchestrator enforces at dispatch, worker enforces at push)
Each PR: <= ~300 changed lines of src+docs and <= 5 files, tests excluded from the line count but each new test file named in the brief. If the work exceeds that, STOP before coding and report the proposed split; do not grow the PR through gate rounds.

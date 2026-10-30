# velo-task v2: Vanth is the index

`velo-task` starts detached work on a pinned, hash-locked [Vanth](https://pypi.org/project/vanth/) 1.14.0 and reports a closed
verdict for it. **Vanth is the only state.** There is no index, no pending record, no tombstone, no lock and no incident log of our
own: a job is a row in Vanth's `jobs.sqlite`, and everything is read from there or from `vanth --json`. What `velo-task` adds is what
Vanth does not do: the pinned install, a daemon launched private and with only the secrets you allow, the required `--timeout`, the
`session:`/`issue:`/`stage:` tags, the closed verdict set, and two hooks.

## Commands

```
velo-task install-vanth                         build the pinned venv from requirements/vanth.lock (uv, --require-hashes, wheels only)
velo-task ensure-daemon | restart-daemon        adopt the daemon velo-task launched, or launch one; restart = SIGTERM it, then a clean launch
velo-task run <id> --timeout S [--issue N] [--stage ST] [--rerun] -- cmd...    start a job; print its job_id
velo-task status <id> | --job <job_id>          print `<id> <verdict>`
velo-task wait <id>... [--any|--all] [--timeout S]     one `<id> <verdict>` line per id
velo-task cancel <id> | --job <job_id>          `vanth stop`, then the verdict (killed)
velo-task stop-override --reason <text>         let the session end once with jobs in flight (audited in overrides.log)
```

## Requirements

- **R1** `run` refuses without `--timeout` (exit 2) and refuses an `<id>` outside `[a-z0-9][a-z0-9_-]{2,63}` (exit 2), before the daemon is touched.
- **R2** The idempotency key is `velo_<first 8 hex of sha256(session)>_<id>`: the same id from the same session is one job (Vanth replays
  it; no second execution); another session gets its own. `--rerun` appends `_<epoch>_<pid>_<rand8>` for a second job.
- **R3** Tags: `velo`, `session:<sid>`, `issue:N`, `stage:ST`. The session is `$CLAUDE_SESSION_ID`, else a token the state dir keeps, read only if the dir and file are private, ours, not a link and exactly 16 hex digits (else exit 6 / the guard blocks). Tags are read as JSON: `tags_json` must be an array of strings and `session:<sid>` an exact member, else the guard blocks.
- **R4** `<id>` is the job's name. It resolves with ONE read-only query,
  `SELECT job_id FROM jobs WHERE name = ? ORDER BY created_at DESC, job_id DESC LIMIT 1`: the exact name, the newest job. `--job J`
  addresses a job directly. An unknown id is exit 2. No `vanth list` (it caps at 1,000 rows and matches substrings).
- **R5** `status`, `wait` and `cancel` ask Vanth (`vanth --json status`), never a log or a process list, and map the answer to the
  closed set below. Anything unclassifiable is `lost`, never `ok`; a status that is not a JSON object (or nests deeper than json reads) is exit 6.
- **R6** Stop guard (Claude Code Stop hook): reads `jobs.sqlite` read-only and BLOCKS while any `session:<me>` job is queued, launching,
  running, paused, retrying or stopping, printing `velo-task wait <id>` per job. Other sessions never block; a lost job is not a blocker.
  Fails closed (the query runs in a child and must end in a success marker) on a missing, unreadable, locked (>2 s) or wrong-schema database and on a missing or
  broken library while a Vanth home exists; no Vanth home allows. A failed/orphaned job with a restart pending counts as in flight, as in `status`. `stop-override` lets exactly one Stop through (a private regular file of yours holding `<time> uid=<n> reason=<text>`, published by temp+fsync+rename; anything else is not an override).
- **R7** SessionStart hook prints this session's in-flight jobs with their wait commands, then `other sessions: N in flight`.
- **R8** The daemon runs under `umask 077` with only the allowlisted variable NAMES in `vanth.env.allow` (never PATH, HOME, PYTHON*,
  DYLD_*, ...), passed by name so no value is in an argv; it listens on 127.0.0.1 only; a daemon is adopted only if a 3-field record
  (pid, start time, launch digest) written after it was proven ready matches. Anything else is exit 6 with the recovery command.
- **R9** Exit codes: 0 ok, 1 error, 2 usage/unknown id (or a job Vanth no longer knows: no verdict line), 3 wait timeout, 4 `cancel` of a job that already finished (its real verdict goes to stderr, `already-terminal`), 5 idempotency conflict, 6 daemon refused/down/misconfigured.
- **R10** Two PreToolUse deny hooks (hooks/deny-vanth-cleanup.sh, hooks/deny-pgrep-wait-loop.sh; tests/test_velo_task_hooks.sh): no
  `vanth prune|restore`, no `until/while pgrep` wait loop. Kept as they were (bars B13, B29 hook half); all scripts run under bash 3.2 (B14).

## Verdicts (the closed set)

| Vanth | verdict |
|---|---|
| completed | `ok` |
| failed, integer exit_code | `failed(N)` (no exit code: `lost`) |
| timeout | `timeout` |
| cancelled with stop_actor `user` | `killed` (any other actor: `lost`) |
| queued, launching, running, paused, retrying, stopping; failed/orphaned with a restart pending | `in-flight` |
| orphaned, any other status | `lost` |

`wait` exits 0 iff every printed verdict is `ok`, 3 on its timeout (naming what is still in flight), 2 for an unknown id.

## Bars (each has a mutation-proved test in tests/test_velo_task.sh)

B1/B18/B26 verdicts, RecursionError, restart pending | B3/B11 argument validation | B4/B5/B6/B15 wait | B10, B-R3 same id, one job |
B-R1 exact-name resolution (1,100 newer jobs) | B-R2 `--rerun` and newest-wins | B-S Stop guard matrix | SessionStart |
B21 secrets (allowlist, no value in argv, launch log not shown) | B22 privacy and provenance (0700/0600, loopback, record) |
B23 supply chain (hash-locked wheels, closure list, install flags). Opt-in `VELO_TASK_NETWORK_TESTS=1` runs the real Vanth.

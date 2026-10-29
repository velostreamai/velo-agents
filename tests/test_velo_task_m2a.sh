#!/bin/bash
# velo-task M2a (docs/velo-task-spec.md): verdict_of (R1), run (R2, R3, R4, R17) and status (R1, R3, R5 read side).
# Bars: B1, B3, B10, B11, B14, B18, B25 (read side), B26, and the crash windows of run (R21 failpoints).
# Session scoping (the scope decision on velo-agents#3): B-S1 and the checks after t_b14_new: the key and the tag carry the session, the
# session comes from CLAUDE_SESSION_ID or a token the state dir keeps, and `status` with no id lists a session's jobs.
#
# The harness, the fake vanthd and the mutation-proof machinery are M1's: tests/test_velo_task_foundation.sh is sourced with
# VELO_TASK_HARNESS_ONLY=1 and stops before its first test. The Vanth CLI here is tests/fixtures/velo-task/fake-vanth-jobs.py: it
# keeps jobs and idempotency keys in jobs.sqlite and really runs the command it is given, so "the job ran once" is a line count in a
# file the command appends to ($E/runs).
#
# Every check is also proved RED on a mutated COPY of the code under test (`prove`, as in M1): a mutation whose anchor is not found
# exactly once is a failed proof, never a skip. VELO_TASK_ONLY="t_a t_b" runs just those checks and their proofs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELO_TASK_HARNESS_ONLY=1 . "$HERE/test_velo_task_foundation.sh"
V=bin/velo-task; L=bin/velo-task-lib.sh; S=bin/velo-task-state

# Every run and status of the suite is under a session of its own, whatever CLAUDE_SESSION_ID the caller's shell has (S0). A key is
# velo_<the first 8 hex digits of sha256(session id)>_<id>: K is the part before the id for a job run under S0.
S0=sess-m2a-default; export CLAUDE_SESSION_ID="$S0"
s8_of() { printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-8; }   # <session id>: the session part of a key, computed without velo-task
K="velo_$(s8_of "$S0")"

# ---- fixtures ----------------------------------------------------------------------------------------
mkfake() {  # an isolated home with the sqlite-backed fake Vanth installed and no daemon running; cds into $E, where the jobs run
  mkhome; mkvenv; render fake-vanth-jobs.py "$E_VENV/bin/vanth"
  cd "$E" || exit 1
}
mkjobs() {  # mkfake, its fake daemon up, and jobs.sqlite created (the daemon makes the home it lives in)
  mkfake
  run VT ensure-daemon; need "the fake daemon starts" [ "$RC" = 0 ]
  fv __bulk 0 init
}
fv() { VANTH_HOME="$E_VH" "$E_VENV/bin/vanth" "$@"; }   # the fake CLI itself, to inject rows: its stdout is the job_id
dbq() { "$PYBIN" -I -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$E_VH/jobs.sqlite" "$1"; }
dbx() { "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit()' "$E_VH/jobs.sqlite" "$1"; }
njobs() { dbq 'SELECT count(*) FROM jobs'; }
starts() { grep -c '^vanth --json start' "$E_CALLS" || true; }      # how many times vanth start was invoked
runs() { if [ -e "$E/runs" ]; then wc -l < "$E/runs" | tr -d ' '; else echo 0; fi; }   # how many times a job's command ran
pend() { ls "$E_HOME/pending" 2>/dev/null | wc -l | tr -d ' '; }
pending_for() { grep -l "\"key\":\"$1\"" "$E_HOME"/pending/* 2>/dev/null | wc -l | tr -d ' '; }   # pending records holding this idempotency key
rj() {  # <id> <exit code> [run options...]: run a job that appends a line to $E/runs and exits with the code
  local id="$1" code="$2"; shift 2
  run VT run "$id" --timeout 30 "$@" -- /bin/sh -c "echo r >> '$E/runs'; exit $code"
}
start_line() { grep -m 1 '^vanth --json start' "$E_CALLS"; }
rx() { [[ "$1" =~ $2 ]]; }   # <string> <ERE>: the whole string matches (for need, which cannot take a [[ ]])
VTN() { /usr/bin/env -u CLAUDE_SESSION_ID "$R/bin/velo-task" "$@"; }   # velo-task in a shell with no CLAUDE_SESSION_ID: the session is the state dir's token
rjs() { local s="$1"; shift; CLAUDE_SESSION_ID="$s" rj "$@"; }   # <session id> <id> <exit code> [run options...]: rj under that session
mklist() {  # mkjobs, then four jobs, oldest first: abc runs ls-a1 (ok), abc2 runs ls-b1 (ok, issue 7) and abc runs ls-a2 (failed(3), issue 7); ls-out comes from outside velo-task, with no tags. Sets JA1 JB1 JA2 JO
  mkjobs
  rjs abc ls-a1 0; JA1=$OUT
  rjs abc2 ls-b1 0 --issue 7; JB1=$OUT
  rjs abc ls-a2 3 --issue 7; JA2=$OUT
  JO=$(fv __inject '{"name":"ls-out","status":"completed","exit_code":0}')
}

# ---- verdict_of (R1) through the helper: B1, B18, B26 -----------------------------------------------------
t_verdict_table() {  # every row is `expected|input`; `x` is the label the helper prints
  local d want json; d=$(mktemp -d "$T/vo.XXXXXX"); mkdb "$d/jobs.sqlite"; mkdir "$d/names"; printf 'job_idx\n' > "$d/names/some-id"
  "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO jobs (job_id, name, status, command) VALUES (?, ?, ?, ?)", ("x y", "odd", "failed", "x")); c.commit()' "$d/jobs.sqlite"
  while IFS='|' read -r want json; do
    [ -n "$want" ] || continue
    run ST verdict-of --label x --names "$d/names" --db "$d/jobs.sqlite" <<<"$json"
    need "$json is $want" [ "$OUT" = "x $want" ]
  done <<'TABLE'
ok|{"job_id":"j","status":"completed","exit_code":0}
ok|{"status":"completed"}
failed(42)|{"status":"failed","exit_code":42}
failed(1)|{"status":"failed","exit_code":1,"policy_state_json":"{}"}
failed(1)|{"status":"failed","exit_code":1,"policy_state_json":""}
failed(1)|{"status":"failed","exit_code":1,"policy_state_json":null}
failed(1)|{"status":"failed","exit_code":1,"policy_state_json":"{\"restart_after\":null}"}
timeout|{"status":"timeout"}
killed|{"status":"cancelled","stop_actor":"user","stop_reason":"stop requested"}
in-flight|{"status":"queued"}
in-flight|{"status":"launching"}
in-flight|{"status":"running"}
in-flight|{"status":"paused"}
in-flight|{"status":"retrying"}
in-flight|{"status":"stopping"}
in-flight|{"status":"failed","exit_code":1,"policy_state_json":"{\"restart_after\":\"2099-01-01T00:00:00Z\"}"}
in-flight|{"status":"orphaned","policy_state_json":{"pending_restart_after":"2099-01-01T00:00:00Z"}}
lost|{"status":"orphaned"}
lost|{"status":"mystery"}
lost|{"status":"COMPLETED"}
lost|{"status":""}
lost|{"status":7}
lost|{"status":null}
lost|{"status":"failed"}
lost|{"status":"failed","exit_code":null}
lost|{"status":"failed","exit_code":"7"}
lost|{"status":"failed","exit_code":true}
lost|{"status":"failed","exit_code":1,"policy_state_json":"[1]"}
lost|{"status":"failed","exit_code":1,"policy_state_json":"{not json"}
lost|{}
lost|{"status":"cancelled"}
lost|{"status":"cancelled","stop_actor":"tool"}
lost|{"status":"cancelled","stop_actor":"watchdog"}
lost|{"status":"cancelled","stop_actor":"timeout"}
lost|{"status":"cancelled","stop_actor":"policy"}
lost|{"status":"cancelled","stop_actor":"remote"}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status"}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"something else","trigger":{"job_id":"a"}}
lost|{"status":"cancelled","stop_actor":"tool","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"a"}}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"nowhere"}}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"x y"}}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":7}}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":[1]}
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":"{not json"}
upstream-failed(a)|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"a","status":"completed"}}
upstream-failed(b)|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":"{\"job_id\":\"b\",\"status\":\"completed\"}"}
upstream-failed(job_idx)|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"job_idx"}}
TABLE
  # M2a, B18: a status that is not an object is not a status at all. Reading it as an empty row made `status <id>` report the job as "not the
  # job asked about" (exit 2, a usage error) for a malformed answer from Vanth.
  for json in '[]' 'null' '"completed"' '7'; do
    run ST verdict-of --label x --names "$d/names" --db "$d/jobs.sqlite" <<<"$json"
    need "a status that is not an object ($json) is exit 6" [ "$RC" = 6 ]
    need "...and prints no verdict" not grep -q '^x ' <<<"$OUT"
    need "...naming what it got" grep -q 'not a JSON object' <<<"$OUT"
  done
  # M2a, B18: a policy column nested deeper than the interpreter's json can read raises RecursionError, which is not a verdict and not a
  # traceback out of the middle of one: the row cannot be classified, so it is lost, never ok.
  "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO jobs (job_id, name, status, command, policy_state_json) VALUES (?, ?, ?, ?, ?)", ("job_deep", "deep", "failed", "x", "[" * 4000 + "]" * 4000)); c.commit()' "$d/jobs.sqlite"
  run ST verdict-of --label x --job job_deep --names "$d/names" --db "$d/jobs.sqlite" <<<'{"job_id":"job_deep","status":"failed","exit_code":1}'
  need "a policy column nested deeper than json can read is lost, not a traceback and not ok" [ "$RC" = 0 -a "$OUT" = "x lost" ]
}
t_verdict_cli() {  # what verdict-of does around the mapping: identity checks, output forms, unreadable input, the absent row
  local d j; d=$(mktemp -d "$T/vc.XXXXXX"); mkdir "$d/names"; printf 'job_listed\n' > "$d/names/gate-1"
  j='{"job_id":"job_1","name":"gate-1","status":"completed","exit_code":0,"tags":["velo","session:abc","issue:7"]}'
  run ST verdict-of --job job_1 --name gate-1 --issue 7 --label gate-1 <<<"$j"
  need "the job asked about, under its name, with its tag: its verdict" [ "$RC" = 0 -a "$OUT" = "gate-1 ok" ]
  run ST verdict-of --job job_ <<<"$j"
  need "a status for another job id (a prefix Vanth resolved) is refused (exit 2)" [ "$RC" = 2 ]
  need "...saying so" grep -q 'refusing to report it for the job asked about' <<<"$OUT"
  run ST verdict-of --name gate-12 <<<"$j"; need "a status under another name is refused (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --issue 8 <<<"$j"; need "a job without the issue tag is refused (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --issue 7 <<<'{"status":"completed","tags":"issue:7"}'; need "tags that are not a list never satisfy --issue (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --issue 7 <<<'{"status":"completed"}'; need "a status with no tags never satisfies --issue (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --session abc --label gate-1 <<<"$j"; need "a job with the session tag: its verdict" [ "$RC" = 0 -a "$OUT" = "gate-1 ok" ]
  run ST verdict-of --session abc2 <<<"$j"; need "a job without the session tag is refused (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --session abc <<<'{"status":"completed","tags":"session:abc"}'; need "tags that are not a list never satisfy --session (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --job job_1 <<<'[1]'; need "a status that is not an object is a malformed answer (exit 6, B18), not a usage error" [ "$RC" = 6 ]
  need "...and it does not name a job id it never got" not grep -q 'job_id None' <<<"$OUT"
  run ST verdict-of --json --label gate-1 --job job_1 <<<"$j"
  need "--json is one compact object with sorted keys" [ "$OUT" = '{"exit_code":0,"id":"gate-1","job_id":"job_1","status":"completed","verdict":"ok"}' ]
  run ST verdict-of --job job_1 <<<"not json"; need "input that is not JSON: exit 6" [ "$RC" = 6 ]
  need "...printing no verdict" not grep -qE ' (ok|lost|failed)' <<<"$OUT"
  run ST verdict-of --job job_1 </dev/null; need "empty input: exit 6" [ "$RC" = 6 ]
  run ST verdict-of --job job_1 < <(printf '\377\376'); need "input that is not UTF-8: exit 6" [ "$RC" = 6 ]
  run ST verdict-of --absent --job job_listed --names "$d/names"
  need "a row Vanth no longer has, for a job the name index lists: lost(pruned)" [ "$RC" = 0 -a "$OUT" = "job_listed lost(pruned)" ]
  run ST verdict-of --absent --job job_nobody --names "$d/names"
  need "...for a job it does not list: unknown-job, exit 3" [ "$RC" = 3 -a "$OUT" = "job_nobody unknown-job" ]
  run ST verdict-of --absent --json --job job_nobody --label z; need "...in --json too" [ "$OUT" = '{"exit_code":null,"id":"z","job_id":"job_nobody","status":null,"verdict":"unknown-job"}' ]
  run ST verdict-of --job job_1 --db "$d/nowhere.sqlite" <<<'{"job_id":"job_1","status":"failed","exit_code":1}'
  need "a failed row whose database cannot be read, to look for a pending restart, is exit 1" [ "$RC" = 1 ]; need "...printing no verdict" not grep -qE ' (ok|lost|failed)' <<<"$OUT"
  run ST verdict-of --bogus; need "an unknown option is a usage error (exit 2)" [ "$RC" = 2 ]
}

# ---- run: validation (B3, B11), the limits, the dedup (B10), what is sent (R11a), what is kept -----------------
t_run_validation() {  # refused before anything is started, created or sent
  local id i long64 long65
  mkfake
  long64=$(printf 'a%.0s' $(seq 1 64)); long65="${long64}a"
  bad() { run VT run "$@"; need "run $* is refused (exit 2)" [ "$RC" = 2 ]; }
  bad abc-1 -- /bin/true
  bad abc-1 --timeout '' -- /bin/true
  for id in ../x a.b a:b ab "$long65" ABC aBc -abc _abc a/b 'abc d' '' $'abc\n' $'abc\n../x' 'abc;ls' 'é1c' '*'; do bad "$id" --timeout 5 -- /bin/true; done
  for i in abc '' 1234567890 -1 1.5 ' 5' $'5\n' 5x +5 0x5 '٣'; do bad abc-1 --timeout 5 --issue "$i" -- /bin/true; done
  for i in 0 -5 abc 1.5 01 1234567890 ' 5' '' 5s; do bad abc-1 --timeout "$i" -- /bin/true; done
  for i in 'ST!' '' UPPER Upper "$(printf 'a%.0s' $(seq 1 33))" -x 'a b'; do bad abc-1 --timeout 5 --stage "$i" -- /bin/true; done
  bad abc-1 --timeout 5
  bad abc-1 --timeout 5 --
  bad abc-1 --timeout 5 --bogus -- /bin/true
  bad abc-1 --timeout
  bad abc-1 --timeout 5 --issue
  bad
  need "none of them sent a start" [ "$(starts)" = 0 ]
  need "...or launched a daemon" [ "$(launches)" = 0 ]
  need "...or created any state" [ ! -e "$E_HOME/pending" -a ! -e "$E_HOME/names" ]
}
t_run_limits() {  # the edges that are accepted
  local id long64 st32 n=0
  mkjobs
  long64=$(printf 'a%.0s' $(seq 1 64)); st32=$(printf 'b%.0s' $(seq 1 32))
  for id in abc "$long64" 0-0 9_9 a-_; do rj "$id" 0; need "id $id is accepted" [ "$RC" = 0 ]; done
  for id in a A 0 a-_ 9_9 Z-9_a "$long64"; do n=$((n + 1)); rjs "$id" "lim-s$n" 0; need "session id $id is accepted" [ "$RC" = 0 ]; done
  rjs "$long64" "$long64" 0 --rerun; need "the longest id, session id and --rerun nonce still make a key Vanth accepts (at most 128 characters)" [ "$RC" = 0 ]
  rj lim-issue 0 --issue 123456789 --stage "$st32"; need "a 9-digit issue and a 32-character stage are accepted" [ "$RC" = 0 ]
  run VT run lim-timeout --timeout 999999999 -- /bin/true; need "a 9-digit timeout is accepted" [ "$RC" = 0 ]
  run VT run lim-timeout1 --timeout 1 -- /bin/true; need "a timeout of 1 is accepted" [ "$RC" = 0 ]
}
t_run_basic() {  # B10 (one job per id, a conflict is exit 5, --rerun is a new job), R3, R6, R11a
  local j1 j2 secret=sk-test-secret-value-1234567890 want_cwd line
  mkjobs; ln -s "$E" "$E-link"; cd "$E-link" || exit 1; want_cwd=$(pwd -P)   # the job is started from a symlinked directory: its cwd is the resolved one
  need "premise: the logical and the physical directory differ" [ "$(pwd)" != "$want_cwd" ]
  OPENROUTER_API_KEY=$secret rj abc-1 0
  need "run exits 0" [ "$RC" = 0 ]; j1=$OUT
  need "...printing the job_id and nothing else" rx "$j1" '^job_[0-9a-f]+$'
  need "...the command ran once" [ "$(runs)" = 1 ]
  need "...exactly one start was sent" [ "$(starts)" = 1 ]
  line=$(start_line)
  need "...with exactly the flags the design lists, the resolved cwd, the key velo_<session>_<id> and the session tag: no --policy, --env, --secret-env or --trigger" \
    [ "${line%% -- *}" = "vanth --json start --name abc-1 --timeout 30 --idempotency-key ${K}_abc-1 --cwd $want_cwd --tag velo --tag session:$S0" ]
  need "...and the command as given" [ "${line#* -- }" = "/bin/sh -c echo r >> '$E/runs'; exit 0" ]
  need "...Vanth saw a clean environment (names only: the Vanth variables)" \
    [ "$(grep -A 1 '^vanth --json start' "$E_CALLS" | tail -n 1)" = "env=AGENT_BG_HOME HOME PATH VANTH_DAEMON_PORT VANTH_HOME" ]
  need "...the caller's secret reached neither Vanth's arguments nor velo-task's state" not grep -rqF "$secret" "$E_CALLS" "$E_HOME"
  need "...the name index lists the job" [ "$(cat "$E_HOME/names/abc-1")" = "$j1" ]
  need "...and no pending record is left" [ "$(pend)" = 0 ]
  rj abc-1 0
  need "a second run of the same id and settings exits 0" [ "$RC" = 0 ]
  need "...with the same job_id" [ "$OUT" = "$j1" ]
  need "...and the command did not run again" [ "$(runs)" = 1 -a "$(njobs)" = 1 ]
  need "...Vanth was asked both times: the key is what dedups" [ "$(starts)" = 2 ]
  need "...the index still lists the job once" [ "$(cat "$E_HOME/names/abc-1")" = "$j1" ]
  need "...and no pending record is left" [ "$(pend)" = 0 ]
  run VT run abc-1 --timeout 31 -- /bin/sh -c "echo r >> '$E/runs'; exit 0"
  need "the same key with another timeout is exit 5" [ "$RC" = 5 ]; need "...named IDEMPOTENCY_CONFLICT" grep -q IDEMPOTENCY_CONFLICT <<<"$OUT"
  rj abc-1 3; need "...with another command: exit 5" [ "$RC" = 5 ]
  rj abc-1 0 --issue 7; need "...with another tag: exit 5" [ "$RC" = 5 ]
  cd /; rj abc-1 0; cd "$E-link" || exit 1; need "...from another directory: exit 5" [ "$RC" = 5 ]
  need "...none of them ran anything or started a job" [ "$(runs)" = 1 -a "$(njobs)" = 1 ]
  need "...or left a pending record, or touched the index" [ "$(pend)" = 0 -a "$(cat "$E_HOME/names/abc-1")" = "$j1" ]
  rj abc-1 5 --rerun
  need "--rerun exits 0" [ "$RC" = 0 ]; j2=$OUT
  need "...it is a second job and the command ran again" [ "$j2" != "$j1" -a "$(runs)" = 2 -a "$(njobs)" = 2 ]
  need "...under a key with a nonce: velo_<session>_<id>_<epoch>_<pid>_<rand8>" grep -Eq -- "^vanth --json start .* --idempotency-key ${K}_abc-1_[0-9]{10}_[0-9]+_[0-9a-f]{8} " "$E_CALLS"
  need "...and the index lists both jobs, in order" [ "$(cat "$E_HOME/names/abc-1")" = "$(printf '%s\n%s' "$j1" "$j2")" ]
  run VT status abc-1; need "the id now resolves to the LAST job indexed under it" [ "$OUT" = "abc-1 failed(5)" ]
  run VT status --job "$j1"; need "...while the first stays addressable by its job_id" [ "$OUT" = "$j1 ok" ]
  rj abc-3 42
  need "a job that failed at once is still a started job (vanth start exits 1 with its JSON): run exits 0" [ "$RC" = 0 ]
  need "...printing its job_id" rx "$OUT" '^job_[0-9a-f]+$'
  need "...and it is indexed" [ "$(cat "$E_HOME/names/abc-3")" = "$OUT" ]
  rj abc-2 0 --issue 7 --stage work
  need "--issue and --stage become tags, after velo and the session, in that order" \
    [ "$(grep '^vanth --json start --name abc-2' "$E_CALLS" | sed 's/ -- .*//')" = "vanth --json start --name abc-2 --timeout 30 --idempotency-key ${K}_abc-2 --cwd $want_cwd --tag velo --tag session:$S0 --tag issue:7 --tag stage:work" ]
  printf 'not a job id\n' > "$E_HOME/names/zzz-bad"
  rj abc-9 0; need "a corrupt index that belongs to another id does not block run" [ "$RC" = 0 ]
  run VT status abc-9; need "...or status" [ "$OUT" = "abc-9 ok" ]
}
t_rerun_nonce() {  # B10: the --rerun key suffix is <epoch>_<pid>_<rand8>, from velo-task's own pid, new on every call
  local k1 k2 e2
  mkjobs
  rj non-1 0 --rerun; need "--rerun exits 0" [ "$RC" = 0 ]
  rj non-1 0 --rerun; need "...a second time too" [ "$RC" = 0 ]
  k1=$(grep -o -- "--idempotency-key ${K}_non-1_[^ ]*" "$E_CALLS" | sed -n 1p | sed 's/.* //')
  k2=$(grep -o -- "--idempotency-key ${K}_non-1_[^ ]*" "$E_CALLS" | sed -n 2p | sed 's/.* //')
  need "the first key is velo_<session>_<id>_<epoch>_<pid>_<rand8>" rx "$k1" "^${K}_non-1_[0-9]{10}_[0-9]+_[0-9a-f]{8}\$"
  need "...the second too" rx "$k2" "^${K}_non-1_[0-9]{10}_[0-9]+_[0-9a-f]{8}\$"
  e2=$(echo "$k2" | cut -d_ -f4)
  need "...the epoch is the current time" [ "$(( $(/bin/date +%s) - e2 ))" -ge 0 -a "$(( $(/bin/date +%s) - e2 ))" -lt 120 ]
  need "...each call is a different process: the pid differs" [ "$(echo "$k1" | cut -d_ -f5)" != "$(echo "$k2" | cut -d_ -f5)" ]
  need "...and the random part differs" [ "${k1##*_}" != "${k2##*_}" ]
}
t_rerun_collision() {  # B10: a colliding nonce is detected through the name index, retried, and exit 5 after 5 attempts
  local j1 j2 before
  mkjobs
  VELO_TASK_TEST=1 VELO_TASK_RERUN_NONCE=fixed rj col-1 0 --rerun
  need "the first --rerun with a constant nonce starts a job" [ "$RC" = 0 ]; j1=$OUT
  need "...under the key velo_<session>_col-1_fixed" grep -q -- "--idempotency-key ${K}_col-1_fixed " "$E_CALLS"
  before=$(starts)
  VELO_TASK_TEST=1 VELO_TASK_RERUN_NONCE=fixed rj col-1 0 --rerun
  need "the second --rerun, whose nonce collides, exits 5" [ "$RC" = 5 ]
  need "...after exactly 5 attempts" [ "$(( $(starts) - before ))" = 5 ]
  need "...starting nothing new" [ "$(runs)" = 1 -a "$(njobs)" = 1 ]
  need "...the index is unchanged" [ "$(cat "$E_HOME/names/col-1")" = "$j1" ]
  need "...and no pending record is left behind by the attempts" [ "$(pend)" = 0 ]
  before=$(starts)
  VELO_TASK_TEST=1 VELO_TASK_RERUN_NONCE=fixed,fresh rj col-1 0 --rerun
  need "with a fresh nonce for the retry, the --rerun succeeds" [ "$RC" = 0 ]; j2=$OUT
  need "...it is a new job" [ "$j2" != "$j1" -a "$(runs)" = 2 ]
  need "...found on the second attempt" [ "$(( $(starts) - before ))" = 2 ]
  need "...under the key velo_<session>_col-1_fresh" grep -q -- "--idempotency-key ${K}_col-1_fresh " "$E_CALLS"
  need "...and the index lists both jobs, in order" [ "$(cat "$E_HOME/names/col-1")" = "$(printf '%s\n%s' "$j1" "$j2")" ]
}
t_run_failures() {  # vanth start returned no job: only a refusal that started nothing is cleaned up
  local j
  mkjobs
  : > "$E/start-transport-error"; rj fail-1 0
  need "a transport error from vanth start is exit 6" [ "$RC" = 6 ]; need "...naming the recovery command" grep -q 'velo-task restart-daemon' <<<"$OUT"
  need "...the outcome is unknown, so the pending record is kept" [ "$(pending_for ${K}_fail-1)" = 1 ]
  need "...and nothing is indexed" [ ! -e "$E_HOME/names/fail-1" ]
  rm "$E/start-transport-error"; : > "$E/start-fail"; rj fail-2 0
  need "any other failure is exit 1" [ "$RC" = 1 ]; need "...saying the outcome is unknown" grep -q 'whether it was accepted is unknown' <<<"$OUT"
  need "...and its pending record is kept too" [ "$(pending_for ${K}_fail-2)" = 1 ]
  rm "$E/start-fail"; rj fail-3 0; j=$OUT
  run VT run fail-3 --timeout 99 -- /bin/true
  need "a conflict is exit 5" [ "$RC" = 5 ]
  need "...Vanth refused it outright, so its pending record is gone" [ "$(pending_for ${K}_fail-3)" = 0 ]
  need "...the other two records are untouched, and no job was started by any failure" [ "$(pend)" = 2 -a "$(njobs)" = 1 -a "$(runs)" = 1 ]
  need "...the index lists only the job that exists" [ "$(cat "$E_HOME/names/fail-3")" = "$j" ]
  rj fail-2 0
  need "a retry of the id whose start failed is a normal run: exit 0, the job runs once" [ "$RC" = 0 -a "$(runs)" = 2 ]
  need "...the failed attempt's record stays for reconcile; the retry's own is gone" [ "$(pending_for ${K}_fail-2)" = 1 -a "$(pend)" = 2 ]
  rj fail-4 0; j=$OUT
  dbx "DELETE FROM jobs WHERE job_id='$j'"
  rj fail-4 0
  need "a key whose job Vanth has cleaned is exit 5 too: a new execution needs --rerun" [ "$RC" = 5 ]
  need "...Vanth refused it outright: nothing is left pending for it" [ "$(pending_for ${K}_fail-4)" = 0 ]
}
crash() {  # <failpoint> <id>: a run killed at the failpoint (R21); it exits 137 and leaves what the crash left
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="$1:exit" rj "$2" 0
  need "a run killed at $1 exits 137" [ "$RC" = 137 ]
}
t_run_crash() {  # R17: the on-disk state at each crash window is the one reconcile reads (the t_reconcile_* checks settle it)
  local f j
  mkjobs
  crash pending.published cw-1
  need "killed after the pending record exists and before vanth start: one pending record" [ "$(pend)" = 1 ]
  f="$E_HOME/pending/$(ls "$E_HOME/pending")"
  need "...no start was sent, no job exists, nothing ran" [ "$(starts)" = 0 -a "$(njobs)" = 0 -a "$(runs)" = 0 ]
  need "...the name index has nothing" [ ! -e "$E_HOME/names/cw-1" ]
  need "...the record is private" [ "$(stat -f %Lp "$f")" = 600 ]
  need "...it holds the key, the id as name, the timeout" [ "$(ST json-get "$f" key)" = ${K}_cw-1 -a "$(ST json-get "$f" name)" = cw-1 -a "$(ST json-get "$f" timeout)" = 30 ]
  need "...the resolved cwd and the tags in order, the session's among them" [ "$(ST json-get "$f" cwd)" = "$(pwd -P)" -a "$(ST json-get "$f" tags)" = '["velo","session:'$S0'"]' ]
  need "...the command, and no environment" [ "$(ST json-get "$f" argv)" = "$(printf '["/bin/sh","-c","echo r >> '"'"'%s/runs'"'"'; exit 0"]' "$E")" -a "$(ST json-get "$f" env)" = '{}' ]
  crash start.returned cw-2
  j=$(dbq "SELECT job_id FROM jobs WHERE name='cw-2'")
  need "killed after vanth start returned and before the index append: the job exists and ran once" [ -n "$j" -a "$(runs)" = 1 ]
  need "...its key is in local_start_requests, which is what reconcile reads" [ "$(dbq "SELECT job_id FROM local_start_requests WHERE idempotency_key='${K}_cw-2'")" = "$j" ]
  need "...the pending record is still there" [ "$(pending_for ${K}_cw-2)" = 1 ]
  need "...and the name index has no line yet" [ ! -e "$E_HOME/names/cw-2" ]
  rj cw-2 0
  need "run again after that crash: exit 0, the job that was started" [ "$RC" = 0 -a "$OUT" = "$j" ]
  need "...without running the command again" [ "$(runs)" = 1 -a "$(njobs)" = 1 ]
  need "...the index lists it once" [ "$(cat "$E_HOME/names/cw-2")" = "$j" ]
  need "...and the killed run's record is settled, not left to pile up" [ "$(pending_for ${K}_cw-2)" = 0 ]
  crash index.appended cw-3
  j=$(dbq "SELECT job_id FROM jobs WHERE name='cw-3'")
  need "killed after the index append and before the pending record is unlinked: the index lists the job" [ "$(cat "$E_HOME/names/cw-3")" = "$j" ]
  need "...the pending record is still there" [ "$(pending_for ${K}_cw-3)" = 1 ]
  crash pending.unlinked cw-4
  j=$(dbq "SELECT job_id FROM jobs WHERE name='cw-4'")
  need "killed after the pending record is unlinked: the index lists the job" [ "$(cat "$E_HOME/names/cw-4")" = "$j" ]
  need "...nothing is pending for it" [ "$(pending_for ${K}_cw-4)" = 0 ]
  need "...and the job_id was not printed" not grep -q '^job_' <<<"$OUT"
}
t_run_fsync_order() {  # R17: the pending record is durable before anything is sent, the index line before the record is unlinked
  local got want
  mkjobs
  VELO_TASK_TEST=1 VELO_TASK_FSYNC_TRACE="$E/trace" rj ord-1 0; need "run exits 0" [ "$RC" = 0 ]
  got=$(grep -E "$E_HOME/(pending|names)" "$E/trace" | sed -E "s#$E_HOME/##g; s#pending/[0-9a-f]{16}\.tmp\.[0-9]+\.[0-9a-f]{8}#pending/TMP#g; s#pending/[0-9a-f]{16}#pending/REC#g")
  want=$(printf '%s\n' 'fsync file pending/TMP' 'link pending/TMP pending/REC' 'fsync dir pending' 'unlink pending/TMP' 'fsync dir pending' \
    'fsync file names/ord-1' 'fsync dir names' 'unlink pending/REC' 'fsync dir pending')
  need "the pending record is fsynced, linked, its directory fsynced; then the index line is fsynced (and its new directory); then the record is unlinked and its directory fsynced" \
    [ "$got" = "$want" ]
}

# ---- reconcile (R3, R17, B25 recovery): a run that died after vanth start returned does not lose its job -----------
# The records come from `crash` (a run killed at a failpoint), so each check starts from the very state a dead run leaves.
t_reconcile_status() {  # B25 recovery: status <id> finds the job of a run killed after vanth start returned, through Vanth's own record
  local j
  mkjobs
  crash start.returned rc-1
  j=$(dbq "SELECT job_id FROM jobs WHERE name='rc-1'")
  need "premise: Vanth accepted and ran it, and the name index has no line for it" [ -n "$j" -a "$(runs)" = 1 -a ! -e "$E_HOME/names/rc-1" ]
  run VT status rc-1
  need "status of the id recovers the job: its verdict, exit 0" [ "$RC" = 0 -a "$OUT" = "rc-1 ok" ]
  need "...the name index lists it once" [ "$(cat "$E_HOME/names/rc-1")" = "$j" ]
  need "...the pending record is gone" [ "$(pend)" = 0 ]
  need "...the command ran once, and the only start sent is the killed run's" [ "$(runs)" = 1 -a "$(njobs)" = 1 -a "$(starts)" = 1 ]
  run VT status rc-1
  need "a second status finds the same job and changes nothing" [ "$OUT" = "rc-1 ok" -a "$(cat "$E_HOME/names/rc-1")" = "$j" ]
  run VT status --job "$j"
  need "...and the job_id reports it too" [ "$OUT" = "$j ok" ]
}
t_reconcile_run() {  # R3: run settles the id's records before it starts anything, so the last line of the index is the last job started
  local j1 j2
  mkjobs
  crash start.returned ro-1
  j1=$(dbq "SELECT job_id FROM jobs WHERE name='ro-1'")
  rj ro-1 5 --rerun; j2=$OUT
  need "a --rerun after a run that died with its start accepted is a new job: exit 0" [ "$RC" = 0 -a "$j2" != "$j1" -a "$(runs)" = 2 ]
  need "...the index lists the job that died first, then the new one" [ "$(cat "$E_HOME/names/ro-1")" = "$(printf '%s\n%s' "$j1" "$j2")" ]
  need "...nothing is left pending" [ "$(pend)" = 0 ]
  run VT status ro-1; need "the id is the last job started, not the one that was recovered" [ "$OUT" = "ro-1 failed(5)" ]
}
t_reconcile_bulk() {  # B25 recovery: also after 1,100 newer jobs whose names contain the id, which vanth list (capped at 1,000 rows) cannot show
  local j
  mkjobs
  crash start.returned bk-1
  j=$(dbq "SELECT job_id FROM jobs WHERE name='bk-1'")
  fv __bulk 1100 bk-1-n
  need "premise: vanth list, capped at 1,000, no longer shows the job" [ "$(fv list --all --name bk-1 --limit 1000 | grep -c "$j")" = 0 ]
  run VT status bk-1
  need "the job is recovered from Vanth's own record and reports its own verdict" [ "$RC" = 0 -a "$OUT" = "bk-1 ok" ]
  need "...the index lists it once and the record is gone" [ "$(cat "$E_HOME/names/bk-1")" = "$j" -a "$(pend)" = 0 ]
  need "...it ran once, and no second start was sent" [ "$(runs)" = 1 -a "$(starts)" = 1 ]
}
t_reconcile_unsent() {  # R3: a record Vanth has no key for is reported, never replayed; status of the id is exit 3 and says how to settle it
  mkjobs
  crash pending.published us-1
  run VT status us-1
  need "status of an id whose start Vanth never received is exit 3" [ "$RC" = 3 ]
  need "...reporting pending-unsent <id> on its own line" grep -q '^pending-unsent us-1$' <<<"$OUT"
  need "...and saying how to settle it: re-run, which is idempotent" grep -qF 'velo-task run us-1 ...` (idempotent' <<<"$OUT"
  need "...nothing was started, run or created" [ "$(starts)" = 0 -a "$(njobs)" = 0 -a "$(runs)" = 0 ]
  need "...the record stays and the name index has nothing" [ "$(pending_for ${K}_us-1)" = 1 -a ! -e "$E_HOME/names/us-1" ]
  rj us-1 0
  need "running it again starts the job once: exit 0" [ "$RC" = 0 -a "$(runs)" = 1 -a "$(njobs)" = 1 ]
  need "...the run reported the old record rather than replaying it" grep -q '^pending-unsent us-1$' <<<"$OUT"
  run VT status us-1
  need "the next status settles the old record, whose key is Vanth's now: the verdict, exit 0" [ "$RC" = 0 -a "$OUT" = "us-1 ok" ]
  need "...nothing is pending and the index lists the job once" [ "$(pend)" = 0 -a "$(wc -l < "$E_HOME/names/us-1" | tr -d ' ')" = 1 ]
  rj us-2 0
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=pending.published:exit rj us-2 0 --rerun
  run VT status us-2
  need "an unsent --rerun beside an older job: that job's verdict, the report before it, exit 0" [ "$RC" = 0 -a "$OUT" = "$(printf 'pending-unsent us-2\nus-2 ok')" ]
  need "...and nothing new was started" [ "$(njobs)" = 2 -a "$(runs)" = 2 ]
}
t_reconcile_exact() {  # B25 mutants: the key is matched exactly; one that contains it, extends it or only differs in case is not Vanth's record of this start
  local jd
  mkjobs
  crash pending.published ex-1
  jd=$(fv __inject '{"name":"decoy","status":"completed","exit_code":0}')
  dbx "INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES ('${K}_ex-1_nonce', 'h', '$jd', 't'), ('zz_${K}_ex-1', 'h', '$jd', 't'), ('$(printf '%s' "${K}_ex-1" | tr a-z A-Z)', 'h', '$jd', 't')"
  run VT status ex-1
  need "keys that extend, contain or case-fold the record's key do not settle it: still pending-unsent, exit 3" [ "$RC" = 3 ]
  need "...nothing was indexed and the record stays" [ ! -e "$E_HOME/names/ex-1" -a "$(pending_for ${K}_ex-1)" = 1 ]
}
t_reconcile_redo() {  # R17: a reconcile killed between the index line and the unlink is redone from what is on disk, with no second line
  local j
  mkjobs
  crash start.returned rd-1
  j=$(dbq "SELECT job_id FROM jobs WHERE name='rd-1'")
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=reconcile.indexed:exit run VT status rd-1
  need "a reconcile killed after it indexed the job fails (exit 6)" [ "$RC" = 6 ]; need "...naming the helper's exit 137" grep -q 'helper exit 137' <<<"$OUT"
  need "...the index lists the job and the record is still there" [ "$(cat "$E_HOME/names/rd-1")" = "$j" -a "$(pending_for ${K}_rd-1)" = 1 ]
  run VT status rd-1
  need "the next status finishes it: the verdict" [ "$RC" = 0 -a "$OUT" = "rd-1 ok" ]
  need "...the index still lists the job once and the record is gone" [ "$(cat "$E_HOME/names/rd-1")" = "$j" -a "$(pend)" = 0 ]
  crash index.appended rd-2
  j=$(dbq "SELECT job_id FROM jobs WHERE name='rd-2'")
  run VT status rd-2
  need "the state a killed run leaves after its index line is settled the same way" [ "$OUT" = "rd-2 ok" -a "$(cat "$E_HOME/names/rd-2")" = "$j" -a "$(pend)" = 0 ]
}
t_reconcile_scope() {  # R3: status <id> settles that id's records only; another id's accepted record is not indexed, its unsent one is not reported
  mkjobs
  crash start.returned sc-1
  crash pending.published sc-2
  rj sc-3 0
  run VT status sc-3
  need "status of an id with no record of its own reports its verdict and nothing else" [ "$RC" = 0 -a "$OUT" = "sc-3 ok" ]
  need "...the other ids' records are untouched" [ "$(pend)" = 2 -a ! -e "$E_HOME/names/sc-1" -a ! -e "$E_HOME/names/sc-2" ]
}
t_reconcile_epoch() {  # R3: two accepted records for one id settle in the order they were written, whatever order their nonces have
  local jold jnew n1 n2 e1 e2
  mkjobs
  mkdir -m 700 -p "$E_HOME/pending" "$E_HOME/names"
  jold=$(fv __inject '{"name":"ep-1","status":"failed","exit_code":3}')
  jnew=$(fv __inject '{"name":"ep-1","status":"completed","exit_code":0}')
  dbx "INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES ('${K}_ep-1_old', 'h', '$jold', 't')"
  dbx "INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES ('${K}_ep-1_new', 'h', '$jnew', 't')"
  n1=$(ST pending-write "$E_HOME/pending" -- --name ep-1 --timeout 30 --idempotency-key "${K}_ep-1_old" --cwd "$E" --tag velo -- /bin/true)
  n2=$(ST pending-write "$E_HOME/pending" -- --name ep-1 --timeout 30 --idempotency-key "${K}_ep-1_new" --cwd "$E" --tag velo -- /bin/true)
  e1=$(ST json-get "$E_HOME/pending/$n1" epoch); e2=$(ST json-get "$E_HOME/pending/$n2" epoch)
  need "premise: the second record was written later, so it settles later" [ "$e2" -gt "$e1" ]
  mv "$E_HOME/pending/$n1" "$E_HOME/pending/ffffffffffffffff"  # the newer record's nonce sorts FIRST: only the creation order is right
  mv "$E_HOME/pending/$n2" "$E_HOME/pending/0000000000000001"
  run VT status ep-1
  need "the older record's job is the first line and the newer record's the last, whatever the nonces are" \
    [ "$(cat "$E_HOME/names/ep-1")" = "$(printf '%s\n%s' "$jold" "$jnew")" ]
  need "...so status reports the newer job's verdict" [ "$RC" = 0 -a "$OUT" = "ep-1 ok" ]
  need "...and both records are settled" [ "$(pend)" = 0 ]
}
t_reconcile_race() {  # R3, R21: a recovery and a run settle one id at once: one line per job, and the newest job is the last line
  local b b2 jold jA
  mkjobs
  mkdir -m 700 -p "$E_HOME/pending" "$E_HOME/names"
  b="$E/go-race"; b2="$E/go-rec"
  jold=$(fv __inject '{"name":"rc-1","status":"failed","exit_code":3}')
  # An accepted record older than the run's, whose key Vanth has not recorded YET: the run's own reconcile therefore leaves it alone,
  # and the recovery has an older job to settle while the run's job is the newer one. The verdicts differ, so the last line of the
  # index says which job the id ended on.
  printf '{"epoch":1,"key":"%s_rc-1_old","name":"rc-1"}\n' "$K" > "$E_HOME/pending/0000000000000001"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="start.returned:wait=$b" CLAUDE_SESSION_ID="$S0" VT run rc-1 --timeout 30 --rerun -- /bin/sh -c "echo r >> '$E/runs'; exit 0" >"$E/o-race" 2>&1; echo $? > "$E/rc-race" ) & RW=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: the run never reached start.returned"; exit 1; }
  jA=$(dbq "SELECT job_id FROM local_start_requests WHERE idempotency_key LIKE '${K}_rc-1_%' AND job_id != '$jold'")
  need "premise: the run started a job of its own, newer than the record above" [ -n "$jA" -a "$jA" != "$jold" ]
  dbx "INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES ('${K}_rc-1_old', 'h', '$jold', 't')"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="reconcile.locked:wait=$b2" CLAUDE_SESSION_ID="$S0" VT status rc-1 >"$E/o-rec" 2>&1; echo $? > "$E/rc-rec" ) & SW=$!
  waitfor 10 test -e "$b2.reached" || { echo "FAILED: the recovery never reached reconcile.locked"; exit 1; }
  need "premise: the recovery is inside the id's critical section, with the older record still unsettled" [ ! -e "$E_HOME/names/rc-1" ]
  touch "$b"  # the run settles its own record now
  waitfor 5 grep -q "$jA" "$E_HOME/names/rc-1" && echo "note: the run settled inside the recovery's critical section (no lock)"
  touch "$b2"  # the recovery settles
  wait "$RW" 2>/dev/null; wait "$SW" 2>/dev/null
  need "the run is exit 0 and printed its own job last" [ "$(cat "$E/rc-race")" = 0 -a "$(tail -n 1 "$E/o-race")" = "$jA" ]
  need "...reporting the older record as unsent, which it never replayed" grep -q '^pending-unsent rc-1$' "$E/o-race"
  need "the recovery is exit 0 and reports the newer job: the older job was not left last" \
    [ "$(cat "$E/rc-rec")" = 0 -a "$(cat "$E/o-rec")" = "rc-1 ok" ]
  need "...the index lists one line per job, the older first" [ "$(cat "$E_HOME/names/rc-1")" = "$(printf '%s\n%s' "$jold" "$jA")" ]
  need "...and both records are settled" [ "$(pend)" = 0 ]
}
t_sweep_temps() {  # R17: a crash between create and link leaves <dest>.tmp.<pid>.<8 hex>; a reconcile sweeps the ones whose writer is gone
  local dead
  mkjobs
  mkdir -m 700 -p "$E_HOME/pending" "$E_HOME/names"
  ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null  # a pid that is certainly not a process any more
  printf 'x\n' > "$E_HOME/pending/aaaaaaaaaaaaaaaa.tmp.$dead.deadbeef"
  printf 'x\n' > "$E_HOME/pending/aaaaaaaaaaaaaaaa.tmp.$$.deadbeef"
  printf 'x\n' > "$E_HOME/names/sweep-1.tmp.$dead.deadbeef"
  printf 'x\n' > "$E_HOME/pending/README"
  rj sweep-1 0
  need "a temp file a crash left in pending/ is swept" [ ! -e "$E_HOME/pending/aaaaaaaaaaaaaaaa.tmp.$dead.deadbeef" ]
  need "...one in names/ too" [ ! -e "$E_HOME/names/sweep-1.tmp.$dead.deadbeef" ]
  need "...a temp whose writer is alive is that writer's, and stays" [ -e "$E_HOME/pending/aaaaaaaaaaaaaaaa.tmp.$$.deadbeef" ]
  need "...and a file that is not a temp is not touched" [ -e "$E_HOME/pending/README" ]
}
t_reconcile_unsafe() {  # an unsafe or unreadable record, database or index stops status and run (exit 6) before anything is resolved or started: nothing is skipped
  local d before
  d=$(mktemp -d "$T/ru.XXXXXX"); mkdir -m 700 "$d/ext"; printf 'SENTINEL\n' > "$d/ext/target"
  mkjobs
  crash pending.published us-1
  before=$(starts)
  printf 'not json\n' > "$E_HOME/pending/aaaaaaaaaaaaaaaa"
  run VT status us-1; need "a pending record that is not JSON stops status (exit 6)" [ "$RC" = 6 ]
  need "...and it is not reported as an unsent start" not grep -q '^pending-unsent' <<<"$OUT"
  run VT run us-1 --timeout 5 -- /bin/true; need "...and run, before it starts anything" [ "$RC" = 6 -a "$(starts)" = "$before" ]
  printf '{"name":"us-1"}\n' > "$E_HOME/pending/aaaaaaaaaaaaaaaa"
  run VT status us-1; need "a JSON object with no key is not a record (exit 6)" [ "$RC" = 6 ]
  rm "$E_HOME/pending/aaaaaaaaaaaaaaaa"
  crash start.returned us-4
  mv "$E_HOME/pending/$(grep -l "\"key\":\"${K}_us-4\"" "$E_HOME"/pending/* | sed 's#.*/##')" "$d/ext/rec"; ln -s "$d/ext/rec" "$E_HOME/pending/cccccccccccccccc"
  run VT status us-4; need "a valid record that is a symlink is refused, not followed (exit 6)" [ "$RC" = 6 -a ! -e "$E_HOME/names/us-4" ]
  rm "$E_HOME/pending/cccccccccccccccc"
  printf 'x\n' > "$E_HOME/pending/aaaaaaaaaaaaaaaa.tmp.1.deadbeef"; printf 'x\n' > "$E_HOME/pending/README"
  run VT status us-1; need "files beside the records that are not named like one are not records: us-1 is still pending-unsent (exit 3)" [ "$RC" = 3 ]
  mv "$E_VH/jobs.sqlite" "$E/jobs.away"
  run VT status us-1; need "a database that cannot be read is exit 6, not an unsent start" [ "$RC" = 6 ]
  need "...naming the helper's exit" grep -q 'helper exit' <<<"$OUT"; need "...and reporting no pending-unsent" not grep -q '^pending-unsent' <<<"$OUT"
  mv "$E/jobs.away" "$E_VH/jobs.sqlite"
  crash pending.published us-2
  dbx "INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES ('${K}_us-2', 'h', '-x', 't')"
  run VT status us-2; need "a job id that starts with a dash, which vanth would read as an option, is refused (exit 6)" [ "$RC" = 6 -a ! -e "$E_HOME/names/us-2" ]
  crash start.returned us-3
  ln -s "$d/ext" "$E_HOME/names/us-3"
  run VT status us-3; need "a name index that is a symlink is refused (exit 6)" [ "$RC" = 6 ]
  need "...and nothing was written through it" [ "$(ls "$d/ext" | tr '\n' ' ')" = "rec target " -a "$(cat "$d/ext/target")" = SENTINEL ]
  run ST reconcile "$d/p" "$d/n" "$d/db"; need "reconcile with too few arguments is a usage error (exit 2)" [ "$RC" = 2 ]
  run ST reconcile "$d/p" "$d/n" "$d/db" ../x; need "...and so is an id that is a path" [ "$RC" = 2 ]
}
t_reconcile_inflight() {  # R4: a status that settles the record of a run still in flight must not make that run start a second job
  local mode id pid opt
  mkjobs
  for mode in plain rerun; do
    id="fl-$mode"; opt=""; [ "$mode" = rerun ] && opt="--rerun"
    VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="start.returned:wait=$E/go-$mode" VT run "$id" --timeout 30 $opt -- /bin/sh -c "echo r >> '$E/runs'; exit 0" </dev/null >"$E/$id.out" 2>&1 &
    pid=$!
    waitfor 20 test -e "$E/go-$mode.reached" || { kill -9 "$pid" 2>/dev/null; echo "FAILED: the $mode run never reached start.returned"; exit 1; }
    run VT status "$id"
    need "$mode: a status while the run waits after vanth start returned settles its record: the verdict" [ "$RC" = 0 -a "$OUT" = "$id ok" ]
    : > "$E/go-$mode"
    wait "$pid"; RC=$?; OUT=$(cat "$E/$id.out")
    need "$mode: the run then finishes: exit 0" [ "$RC" = 0 ]
    need "...printing the job that status found" [ "$OUT" = "$(cat "$E_HOME/names/$id")" ]
    need "...one job and one execution for the id, and nothing pending" [ "$(dbq "SELECT count(*) FROM jobs WHERE name='$id'")" = 1 -a "$(pend)" = 0 ]
  done
  need "two ids, two executions in all" [ "$(runs)" = 2 ]
}

# ---- status: B1, B18, B26 through the CLI, B25 (read side), R6, R7 ---------------------------------------------
t_status_verdicts() {
  local j jp s
  mkjobs
  rj st-ok 0; run VT status st-ok; need "B1: exit 0 is ok" [ "$RC" = 0 -a "$OUT" = "st-ok ok" ]
  rj st-fail 42; run VT status st-fail; need "B1: exit 42 is failed(42)" [ "$OUT" = "st-fail failed(42)" ]
  need "...and status exits 0: it succeeded in reporting a verdict (R5: wait mirrors the verdict, status does not)" [ "$RC" = 0 ]
  run VT run st-to --timeout 1 -- /bin/sh -c 'exec /bin/sleep 5'; run VT status st-to; need "a job that outlives its timeout is timeout" [ "$OUT" = "st-to timeout" ]
  need "...and status exits 0 for it" [ "$RC" = 0 ]
  run VT status --json st-fail; need "--json is one object with the id, job_id, status, exit_code and verdict" \
    [ "$OUT" = "$(printf '{"exit_code":42,"id":"st-fail","job_id":"%s","status":"failed","verdict":"failed(42)"}' "$(cat "$E_HOME/names/st-fail")")" ]
  j=$(fv __inject '{"name":"inj-a","status":"orphaned"}'); run VT status --job "$j"; need "B18: orphaned is lost, and status exits 0 for a lost verdict" [ "$OUT" = "$j lost" -a "$RC" = 0 ]
  j=$(fv __inject '{"name":"inj-b","status":"mystery"}'); run VT status --job "$j"; need "B18: an unknown status string is lost" [ "$OUT" = "$j lost" ]
  j=$(fv __inject '{"name":"inj-c","status":"failed"}'); run VT status --job "$j"; need "B18: failed with no exit_code is lost" [ "$OUT" = "$j lost" ]
  for s in queued launching running paused retrying stopping; do
    j=$(fv __inject "{\"name\":\"inj-$s\",\"status\":\"$s\"}"); run VT status --job "$j"; need "$s is in-flight" [ "$OUT" = "$j in-flight" ]
  done
  j=$(fv __inject '{"name":"inj-k","status":"cancelled","stop_actor":"user"}'); run VT status --job "$j"; need "B26: cancelled by the user is killed, and status exits 0 for it" [ "$OUT" = "$j killed" -a "$RC" = 0 ]
  jp=$(fv __inject '{"name":"inj-parent","status":"failed","exit_code":1}')
  j=$(fv __inject '{"name":"inj-child","status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":{"job_id":"'"$jp"'","status":"completed"}}')
  run VT status --job "$j"; need "B26: cancelled by a trigger parent that exists is upstream-failed(<parent>)" [ "$OUT" = "$j upstream-failed($jp)" ]
  j=$(fv __inject '{"name":"inj-t","status":"cancelled","stop_actor":"tool","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":{"job_id":"'"$jp"'"}}')
  run VT status --job "$j"; need "B26: the right reason from another stop_actor is lost" [ "$OUT" = "$j lost" ]
  j=$(fv __inject '{"name":"inj-r","status":"cancelled","stop_actor":"daemon","stop_reason":"stopped for another reason","trigger_json":{"job_id":"'"$jp"'"}}')
  run VT status --job "$j"; need "B26: another reason from the daemon is lost" [ "$OUT" = "$j lost" ]
  j=$(fv __inject '{"name":"inj-n","status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":{"job_id":"job_nowhere"}}')
  run VT status --job "$j"; need "B26: a trigger parent that is in neither jobs.sqlite nor the index is lost" [ "$OUT" = "$j lost" ]
  j=$(fv __inject '{"name":"inj-w","status":"cancelled","stop_actor":"watchdog"}'); run VT status --job "$j"; need "B26: any other stop_actor is lost" [ "$OUT" = "$j lost" ]
  j=$(fv __inject '{"name":"inj-p1","status":"failed","exit_code":1,"policy_state_json":{"restart_after":"2099-01-01T00:00:00Z"}}')
  run VT status --job "$j"; need "R1: failed with a restart pending in policy_state_json is in-flight, although vanth status does not show it" [ "$OUT" = "$j in-flight" ]
  j=$(fv __inject '{"name":"inj-p2","status":"orphaned","policy_state_json":{"pending_restart_after":"2099-01-01T00:00:00Z"}}')
  run VT status --job "$j"; need "...orphaned with a restart being claimed too" [ "$OUT" = "$j in-flight" ]
  j=$(fv __inject '{"name":"inj-p3","status":"failed","exit_code":1,"policy_state_json":{}}')
  run VT status --job "$j"; need "...but not when the policy state holds no restart" [ "$OUT" = "$j failed(1)" ]
  rj st-issue 0 --issue 7; run VT status --issue 7 st-issue; need "--issue N with the right tag reports the verdict" [ "$OUT" = "st-issue ok" ]
  run VT status --issue 8 st-issue; need "--issue N for a job without that tag is refused (exit 2)" [ "$RC" = 2 ]
}
t_status_resolution() {  # B25, read side: an id resolves through the name index, however many newer jobs have the name in theirs
  local jo j12 bj
  mkjobs
  rj gate-1 3; jo=$OUT
  fv __bulk 1100 gate-1-n
  rj gate-12 0; j12=$OUT
  need "premise: vanth list, capped at 1,000, no longer shows the older gate-1" [ "$(fv list --all --name gate-1 --limit 1000 | grep -c "$jo")" = 0 ]
  need "premise: a substring match for gate-1 finds more than one name" [ "$(dbq "SELECT count(DISTINCT name) FROM jobs WHERE name LIKE '%gate-1%'")" -gt 2 ]
  run VT status gate-1; need "B25: gate-1 resolves, through the name index, to the older job and reports ITS verdict" [ "$OUT" = "gate-1 failed(3)" ]
  run VT status gate-12; need "...gate-12 reports its own" [ "$OUT" = "gate-12 ok" ]
  printf '%s\n' "$j12" >> "$E_HOME/names/gate-1"
  run VT status gate-1; need "B25: an index that points gate-1 at the job named gate-12 is refused (exit 2)" [ "$RC" = 2 ]
  need "...naming the name it found" grep -q "gate-12" <<<"$OUT"
  printf '%s\n' "$jo" > "$E_HOME/names/gate-1"
  mv "$E_HOME/names" "$E_HOME/names.away"
  run VT status --job "$jo"; need "B25: status --job works without the index" [ "$RC" = 0 -a "$OUT" = "$jo failed(3)" ]
  run VT status gate-1; need "...while an id needs the index: no match is exit 2" [ "$RC" = 2 ]
  mv "$E_HOME/names.away" "$E_HOME/names"
  run VT status gate-99; need "an id nothing was run under: exit 2" [ "$RC" = 2 ]; need "...saying how to address a job" grep -q -- '--job' <<<"$OUT"
  for bj in ../x 'a b' 'a/b' '-x' "$(printf 'j%.0s' $(seq 1 129))"; do run VT status --job "$bj"; need "--job '$bj' is not a job id (exit 2)" [ "$RC" = 2 ]; done
  run VT status --job "${j12:0:9}"; need "a unique prefix of a job id is refused, not resolved (exit 2)" [ "$RC" = 2 ]
  need "...nothing is printed for it but the refusal" not grep -qE ' (ok|lost|failed)' <<<"$OUT"
  run VT status --job job_zzzzzzzzzzzz; need "a job Vanth does not know and the index does not list: unknown-job, exit 3 (R20)" [ "$RC" = 3 -a "$OUT" = "job_zzzzzzzzzzzz unknown-job" ]
  dbx "DELETE FROM jobs WHERE job_id='$jo'"
  run VT status --job "$jo"; need "a job the index lists whose row is gone: lost(pruned)" [ "$RC" = 0 -a "$OUT" = "$jo lost(pruned)" ]
  run VT status gate-1; need "...by id too" [ "$OUT" = "gate-1 lost(pruned)" ]
}
t_status_daemon() {  # R6, R7: ensure-daemon first; a daemon that cannot be reached is exit 6 and the recovery command, never a verdict
  local out
  mkhome; mkvenv; render fake-vanth-jobs.py "$E_VENV/bin/vanth"; : > "$E/fail-launch"
  run VT status --job job_abc; need "the daemon cannot be started: status is exit 6" [ "$RC" = 6 ]
  need "...naming velo-task restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
  out=$(VT status --job job_abc 2>/dev/null); need "...and no verdict on stdout" [ -z "$out" ]
  run VT status abc-1; need "...by id too" [ "$RC" = 6 ]
  run VT run abc-1 --timeout 5 -- /bin/true; need "run is exit 6 as well" [ "$RC" = 6 ]
  need "...it started nothing, and created no pending record" [ "$(starts)" = 0 -a ! -e "$E_HOME/pending" ]
  rm "$E/fail-launch"; run VT ensure-daemon; need "the daemon starts once it can" [ "$RC" = 0 ]
  rj dn-1 0
  : > "$E/status-transport-error"; run VT status --job job_abc; need "vanth status cannot reach the daemon: exit 6" [ "$RC" = 6 ]
  need "...naming velo-task restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
  out=$(VT status --job job_abc 2>/dev/null); need "...and no verdict on stdout" [ -z "$out" ]
  rm "$E/status-transport-error"; : > "$E/status-fail"
  run VT status --job job_abc; need "any other vanth status failure is exit 1" [ "$RC" = 1 ]
  out=$(VT status --job job_abc 2>/dev/null); need "...with no verdict on stdout" [ -z "$out" ]
  rm "$E/status-fail"; : > "$E/status-garbage"
  run VT status dn-1; need "a status that is not JSON is exit 6" [ "$RC" = 6 ]
  out=$(VT status dn-1 2>/dev/null); need "...with no verdict on stdout" [ -z "$out" ]
}

# ---- state: the new paths, the index files, the helper commands -------------------------------------------------
t_state_paths() {  # names/ and pending/ are checked like every other state path
  local p d before
  mkjobs; d=$(mktemp -d "$T/sp.XXXXXX"); mkdir -m 700 "$d/ext"
  rj sp-1 0; need "a run creates names/ and pending/" [ -d "$E_HOME/names" -a -d "$E_HOME/pending" ]
  for p in names pending; do
    mv "$E_HOME/$p" "$d/real-$p"; ln -s "$d/ext" "$E_HOME/$p"
    run ST check-state "$E_HOME"; need "$p as a symlink is refused (exit 9)" [ "$RC" = 9 ]; need "...naming it" grep -q "$p is a symlink" <<<"$OUT"
    run VT status --job job_x; need "status refuses it (exit 6)" [ "$RC" = 6 ]
    before=$(starts); run VT run sp-2 --timeout 5 -- /bin/true
    need "run refuses it (exit 6) before sending anything" [ "$RC" = 6 -a "$(starts)" = "$before" ]
    need "...nothing was written through the link" [ -z "$(ls "$d/ext")" ]
    rm "$E_HOME/$p"; : > "$E_HOME/$p"
    run ST check-state "$E_HOME"; need "$p as a regular file is refused (exit 9)" [ "$RC" = 9 ]; need "...as not a directory" grep -q 'is not a directory' <<<"$OUT"
    rm "$E_HOME/$p"; mv "$d/real-$p" "$E_HOME/$p"
  done
  run ST check-state "$E_HOME"; need "restored, the state is accepted" [ "$RC" = 0 ]
  printf 'job_x\nnot a job id\n' > "$E_HOME/names/bad-9"; printf 'job_x\n-x\n' > "$E_HOME/names/dash-9"; ln -s "$d/ext" "$E_HOME/names/lnk-9"
  for p in bad-9 dash-9 lnk-9; do
    before=$(starts); run VT run "$p" --timeout 5 -- /bin/true
    need "run with an unsafe name index ($p) is exit 6, before anything is started" [ "$RC" = 6 -a "$(starts)" = "$before" ]
    run VT status "$p"; need "...and status is exit 6 too" [ "$RC" = 6 ]
  done
}
t_index_files() {  # index-last and index-has read control files: never through a symlink, never waiting on a FIFO, only your regular files
  local d w; d=$(mktemp -d "$T/ix.XXXXXX"); mkdir -m 700 "$d/names" "$d/ext"; printf 'SENTINEL\n' > "$d/ext/target"
  printf 'job_1\njob_2\njob_3\n' > "$d/names/abc-1"; printf 'job_9\n' > "$d/names/abc-2"
  run ST index-last "$d/names" abc-1; need "index-last prints the LAST line" [ "$RC" = 0 -a "$OUT" = job_3 ]
  run ST index-last "$d/names" nobody; need "...exit 1 for an id without an index" [ "$RC" = 1 ]
  : > "$d/names/empty-1"; run ST index-last "$d/names" empty-1; need "...and for an empty index" [ "$RC" = 1 ]
  run ST index-last "$d/names" ../ext; need "an id with a slash is a usage error (exit 2)" [ "$RC" = 2 ]
  run ST index-has "$d/names" job_9; need "index-has finds a job in any index file" [ "$RC" = 0 ]
  run ST index-has "$d/names" job_1; need "...in the first too" [ "$RC" = 0 ]
  run ST index-has "$d/names" job_8; need "...and says no otherwise (exit 1)" [ "$RC" = 1 ]
  run ST index-has "$d/nowhere" job_1; need "...a missing directory is no (exit 1)" [ "$RC" = 1 ]
  run ST index-has "$d/names" job_9 abc-2; need "index-has with an id reads just that id's index: found" [ "$RC" = 0 ]
  run ST index-has "$d/names" job_9 abc-1; need "...a job listed under another id is not found (exit 1)" [ "$RC" = 1 ]
  run ST index-has "$d/names" job_1 nobody; need "...an id with no index lists nothing (exit 1)" [ "$RC" = 1 ]
  run ST index-has "$d/nowhere" job_1 abc-1; need "...nor a missing directory (exit 1)" [ "$RC" = 1 ]
  for w in ../ext a/b . .. ''; do run ST index-has "$d/names" job_1 "$w"; need "index-has with the id '$w' is a usage error (exit 2)" [ "$RC" = 2 ]; done
  run ST index-has "$d/names"; need "index-has with no job id is a usage error (exit 2)" [ "$RC" = 2 ]
  ln -s "$d/ext/target" "$d/names/lnk-1"
  run ST index-last "$d/names" lnk-1; need "an index that is a symlink is refused (exit 9)" [ "$RC" = 9 ]
  need "...saying so" grep -q 'is a symlink' <<<"$OUT"; need "...without reading what it points at" not grep -q SENTINEL <<<"$OUT"
  run ST index-has "$d/names" job_8; need "...and index-has, which reads them all to find a job in none, refuses the directory that holds one (exit 9)" [ "$RC" = 9 ]
  run ST index-has "$d/names" job_1 abc-1; need "...but with an id it reads only that id's index, so a link beside it does not matter" [ "$RC" = 0 ]
  rm "$d/names/lnk-1"
  mkdir "$d/names/dir-1"; run ST index-last "$d/names" dir-1; need "an index that is a directory is refused (exit 9)" [ "$RC" = 9 ]
  need "...as not a regular file" grep -q 'is not a regular file' <<<"$OUT"; rmdir "$d/names/dir-1"
  /usr/bin/mkfifo "$d/names/fifo-1"; "$PYBIN" "$R/bin/velo-task-state" index-last "$d/names" fifo-1 > "$d/fifo.out" 2>&1 & w=$!
  waitfor 3 not alive "$w" || { kill -9 "$w" 2>/dev/null; echo "FAILED: index-last of a FIFO waits for a writer instead of refusing it"; exit 1; }
  wait "$w"; RC=$?; need "a FIFO is refused at once, never waited on (exit 9)" [ "$RC" = 9 ]; rm "$d/names/fifo-1"
  printf 'job_1\nnot a job id\n' > "$d/names/bad-1"; run ST index-last "$d/names" bad-1
  need "a line that is not a job id is refused (exit 9), not skipped" [ "$RC" = 9 ]; need "...naming it" grep -q 'not a job id' <<<"$OUT"
  printf 'job_1\n-x\n' > "$d/names/dash-1"; run ST index-last "$d/names" dash-1
  need "a line that starts with a dash, which vanth would read as an option, is refused (exit 9)" [ "$RC" = 9 ]; need "...naming it" grep -q 'not a job id' <<<"$OUT"
  run ST index-has "$d/names" job_1 dash-1; need "...by index-has too" [ "$RC" = 9 ]
  run ST index-last /private/etc hosts; need "an index another user owns is refused (exit 9)" [ "$RC" = 9 ]; need "...naming the owner" grep -q 'owned by uid' <<<"$OUT"
}
t_pending_write() {  # R17 step 1: the record is the canonical settings of the request that is sent
  local d f flag
  d=$(mktemp -d "$T/pw.XXXXXX"); mkdir -m 700 "$d/p" "$d/ext"
  run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --cwd /w --tag velo --tag issue:7 -- /bin/echo 'a b' "c'd"
  need "pending-write exits 0" [ "$RC" = 0 ]; need "...and prints a nonce" rx "$OUT" '^[0-9a-f]{16}$'
  f="$d/p/$OUT"
  need "...the record is private (0600)" [ "$(stat -f %Lp "$f")" = 600 ]
  need "...holds the canonical settings: sorted keys, no spaces, one line, and the creation epoch" \
    [ "$(cat "$f")" = '{"argv":["/bin/echo","a b","c'"'"'d"],"cwd":"/w","env":{},"epoch":'"$(ST json-get "$f" epoch)"',"key":"velo_abc-1","name":"abc-1","tags":["velo","issue:7"],"timeout":30,"trigger":null}' ]
  need "...and the epoch is the nanoseconds it was written at (M2a: two records for one id settle in this order)" \
    [ "$(ST json-get "$f" epoch)" -ge 1700000000000000000 ]
  need "...and leaves no temp name beside it" [ "$(ls "$d/p" | wc -l | tr -d ' ')" = 1 ]
  run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --cwd /w --tag velo -- /bin/true
  need "a second call writes a second record under another nonce" [ "$RC" = 0 -a "$(ls "$d/p" | wc -l | tr -d ' ')" = 2 ]
  for flag in --policy --env --secret-env --trigger --wake-me --notes --priority --bogus; do
    run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --cwd /w --tag velo "$flag" x -- /bin/true
    need "a request with $flag, which velo-task never sends, is refused (exit 2)" [ "$RC" = 2 ]
  done
  run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --tag velo -- /bin/true; need "a request with no cwd is refused (exit 2)" [ "$RC" = 2 ]
  run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --cwd /w --tag velo -- /bin/true; need "...no key" [ "$RC" = 2 ]
  run ST pending-write "$d/p" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --cwd /w --tag velo --; need "...no command" [ "$RC" = 2 ]
  need "none of the refusals wrote anything" [ "$(ls "$d/p" | wc -l | tr -d ' ')" = 2 ]
  ln -s "$d/ext" "$d/lnk"; run ST pending-write "$d/lnk" -- --name abc-1 --timeout 30 --idempotency-key velo_abc-1 --cwd /w --tag velo -- /bin/true
  need "a directory that is a symlink is refused (exit 9)" [ "$RC" = 9 ]; need "...nothing was written through it" [ -z "$(ls "$d/ext")" ]
}
t_remove() {  # R17 step 4: unlink a regular file of yours, then fsync its directory; never through a symlink
  local d w; d=$(mktemp -d "$T/rm.XXXXXX"); mkdir -m 700 "$d/p" "$d/ext"; printf 'SENTINEL\n' > "$d/ext/target"; printf 'x\n' > "$d/p/rec1"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" run ST remove "$d/p/rec1"
  need "remove exits 0 and the file is gone" [ "$RC" = 0 -a ! -e "$d/p/rec1" ]
  need "...it unlinks, then fsyncs the directory, in that order" [ "$(cat "$d/trace")" = "$(printf 'unlink %s\nfsync dir %s' "$d/p/rec1" "$d/p")" ]
  run ST remove "$d/p/rec1"; need "a file that is already gone is not an error (a step reconcile may have done)" [ "$RC" = 0 ]
  ln -s "$d/ext/target" "$d/p/lnk"; run ST remove "$d/p/lnk"
  need "a symlink is refused (exit 9)" [ "$RC" = 9 ]; need "...and left where it was, with its target intact" [ -L "$d/p/lnk" -a "$(cat "$d/ext/target")" = SENTINEL ]
  mkdir "$d/p/adir"; run ST remove "$d/p/adir"; need "a directory is refused (exit 9)" [ "$RC" = 9 -a -d "$d/p/adir" ]
  /usr/bin/mkfifo "$d/p/fifo"; "$PYBIN" "$R/bin/velo-task-state" remove "$d/p/fifo" > "$d/fifo.out" 2>&1 & w=$!
  waitfor 3 not alive "$w" || { kill -9 "$w" 2>/dev/null; echo "FAILED: remove of a FIFO waits instead of refusing it"; exit 1; }
  wait "$w"; RC=$?; need "a FIFO is refused at once (exit 9)" [ "$RC" = 9 -a -p "$d/p/fifo" ]
}
t_seam_nonce() {  # R21: VELO_TASK_RERUN_NONCE is honoured only under the test capability, and refused (exit 2) everywhere else
  mkjobs
  VELO_TASK_RERUN_NONCE=n1 run VT run sn-1 --timeout 5 --rerun -- /bin/true
  need "a nonce seam without the test capability is refused (exit 2)" [ "$RC" = 2 ]; need "...saying why" grep -q 'VELO_TASK_RERUN_NONCE is set but refused' <<<"$OUT"
  need "...and nothing was started" [ "$(starts)" = 0 ]
  VELO_TASK_RERUN_NONCE=n1 run VT status --job job_x; need "...status refuses it too" [ "$RC" = 2 ]
  VELO_TASK_TEST=1 VELO_TASK_TEST_ROOT_NONCE=wrong VELO_TASK_RERUN_NONCE=n1 run VT run sn-1 --timeout 5 --rerun -- /bin/true
  need "a root nonce that does not match is refused too (exit 2)" [ "$RC" = 2 ]
  VELO_TASK_TEST=1 VELO_TASK_RERUN_NONCE=n1 run VT run sn-1 --timeout 5 --rerun -- /bin/true
  need "with the capability it is accepted" [ "$RC" = 0 ]; need "...and is the key's suffix" grep -q -- "--idempotency-key ${K}_sn-1_n1 " "$E_CALLS"
}
t_not_subcommands() {  # the new library functions are not reachable by name; run and status are the only new arms
  local s; mkhome; mkvenv
  for s in cmd_run cmd_status need_daemon check_arg session_id rerun_nonce start_refused reconcile_id; do
    run VT "$s"; need "the library function $s is not a subcommand (exit 2)" [ "$RC" = 2 ]
    need "...it is simply not implemented" grep -q 'not implemented yet' <<<"$OUT"
  done
  need "none of them launched anything" [ "$(launches)" = 0 ]
  need "run and status are named in the dispatcher by one arm" [ "$(grep -cE '^  run\|status\) ' "$R/bin/velo-task")" = 1 ]
}
t_b14_new() {  # B14: every bin/velo-task* script, the new code included, parses and runs under /bin/bash 3.2 and holds no bash-4 construct
  local f d n=0; d=$(mktemp -d "$T/b.XXXXXX")
  for f in "$R"/bin/velo-task*; do
    [ "$(head -n 1 "$f")" = '#!/bin/bash' ] || continue
    n=$((n + 1))
    need "$(basename "$f") parses under /bin/bash -n" /bin/bash -n "$f"
    run grep -nE "$SWEEP_RE" "$f"; need "$(basename "$f") has no bash-4 construct" [ "$RC" = 1 ]
  done
  need "at least one script matched bin/velo-task*" [ "$n" -ge 1 ]
  need "/bin/bash is 3.2" [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')" = 3.2 ]
  need "the library holds run, status and what they call" [ "$(grep -cE '^(cmd_run|cmd_status|need_daemon|check_arg|session_id|rerun_nonce|start_refused|reconcile_id)\(\)' "$R/bin/velo-task-lib.sh")" = 8 ]
  printf '#!/bin/bash\nset -e\ndeclare -A seeded\nseeded[a]=1\n' > "$d/seeded.sh"
  need "the seeded declare -A fixture is caught by the sweep" grep -qE "$SWEEP_RE" "$d/seeded.sh"
  need "...and fails when run under /bin/bash" not /bin/bash "$d/seeded.sh"
}

# ---- sessions: B-S1 (the key and the tag), the arguments, the token, the list, the filters ------------------------
t_session_validation() {  # a session id, and the arguments of status that name a session or ask for a list, are checked like every other: exit 2, before anything is started, created or read
  local s long65
  mkfake
  long65=$(printf 'a%.0s' $(seq 1 65))
  for s in 'a b' ../x a/b -abc _abc "$long65" é $'abc\n' 'abc;ls' '*' a:b a.b; do
    CLAUDE_SESSION_ID="$s" run VT run abc-1 --timeout 5 -- /bin/true
    need "run under the session id '$s' is refused (exit 2)" [ "$RC" = 2 ]
    CLAUDE_SESSION_ID="$s" run VT status
    need "...a list under it too (exit 2)" [ "$RC" = 2 ]
    CLAUDE_SESSION_ID="$s" run VT status abc-1
    need "...and a status of an id, whether or not it uses the session (exit 2)" [ "$RC" = 2 ]
    run VT status --session "$s"
    need "...and --session '$s' (exit 2)" [ "$RC" = 2 ]
  done
  run VT status --session ''; need "an empty --session is refused, not read as no filter (exit 2)" [ "$RC" = 2 ]
  run VT status ''; need "an empty id is refused, not read as a request for a list (exit 2)" [ "$RC" = 2 ]
  run VT status --job ''; need "an empty --job is refused too (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc --all; need "--session with --all is exit 2" [ "$RC" = 2 ]
  run VT status --all abc-1; need "--all with an id is exit 2: --all lists" [ "$RC" = 2 ]
  run VT status --all --job job_x; need "--all with --job is exit 2" [ "$RC" = 2 ]
  run VT status abc-1 --job job_x; need "an id and --job together are exit 2" [ "$RC" = 2 ]
  need "none of them started anything, launched a daemon or created any state" \
    [ "$(starts)" = 0 -a "$(launches)" = 0 -a ! -e "$E_HOME/pending" -a ! -e "$E_HOME/names" -a ! -e "$E_HOME/session" ]
}
t_session_key() {  # the key is velo_<first 8 hex digits of sha256(session id)>_<id>, and the job is tagged session:<id>, after velo and before the other tags
  local ja jb
  mkjobs
  rjs abc twin-1 0; ja=$OUT
  need "a run under the session abc exits 0" [ "$RC" = 0 ]
  need "...under the key velo_<first 8 hex digits of sha256(abc)>_<id>: sha256(abc) starts ba7816bf" \
    [ "$(start_line | grep -o -- '--idempotency-key [^ ]*')" = "--idempotency-key velo_ba7816bf_twin-1" ]
  need "...and tagged session:abc, after velo and before the others" [ "$(start_line | sed 's/.* --tag velo //; s/ -- .*//')" = "--tag session:abc" ]
  rjs abc2 twin-1 0; jb=$OUT
  need "the session abc2 has its own key: velo_<first 8 hex digits of sha256(abc2)>_<id>" \
    [ "$(grep -o -- '--idempotency-key [^ ]*' "$E_CALLS" | tail -n 1)" = "--idempotency-key velo_$(s8_of abc2)_twin-1" -a "$(s8_of abc)" != "$(s8_of abc2)" ]
  need "...each job carries its own session tag and not the other's" \
    [ "$(dbq "SELECT count(*) FROM jobs WHERE job_id='$ja' AND tags_json LIKE '%\"session:abc\"%' AND tags_json NOT LIKE '%abc2%'")" = 1 \
      -a "$(dbq "SELECT count(*) FROM jobs WHERE job_id='$jb' AND tags_json LIKE '%\"session:abc2\"%' AND tags_json NOT LIKE '%\"session:abc\"%'")" = 1 ]
}
t_session_separation() {  # B-S1: two sessions that run one id start two jobs; one session that runs it twice starts one
  local ja jb
  mkjobs
  rjs abc twin-1 0; ja=$OUT
  need "a run of twin-1 under the session abc exits 0" [ "$RC" = 0 ]
  rjs abc2 twin-1 0; jb=$OUT
  need "the same id under the session abc2 exits 0, not as a conflict" [ "$RC" = 0 ]
  need "...it is another job, and the command ran again" [ "$jb" != "$ja" -a "$(runs)" = 2 -a "$(njobs)" = 2 ]
  rjs abc twin-1 0
  need "the first session again: the same job, and nothing ran" [ "$RC" = 0 -a "$OUT" = "$ja" -a "$(runs)" = 2 -a "$(njobs)" = 2 ]
  need "...the name index of the id lists both jobs, in order" [ "$(cat "$E_HOME/names/twin-1")" = "$(printf '%s\n%s' "$ja" "$jb")" ]
  rjs abc twin-1 0 --issue 7
  need "...with other settings it is a conflict (exit 5) under a session too" [ "$RC" = 5 ]
}
t_session_token() {  # no CLAUDE_SESSION_ID: the session is the token this state dir keeps, made on first use, private, and never changed
  local f tok j1 j2 j3 j4 d bad before
  mkjobs; f="$E_HOME/session"; d=$(mktemp -d "$T/st.XXXXXX"); mkdir -m 700 "$d/ext"; printf 'SENTINEL\n' > "$d/ext/target"
  need "premise: there is no token before the first use" [ ! -e "$f" ]
  run VTN run tok-1 --timeout 30 -- /bin/sh -c "echo r >> '$E/runs'; exit 0"; j1=$OUT
  need "a run with no CLAUDE_SESSION_ID exits 0" [ "$RC" = 0 ]
  need "...and made the token: a private file of 16 hex digits and a newline" [ -f "$f" -a "$(stat -f %Lp "$f")" = 600 -a "$(wc -c < "$f" | tr -d ' ')" = 17 ]
  tok=$(cat "$f"); need "...the digits are hex" rx "$tok" '^[0-9a-f]{16}$'
  need "...the job is tagged with the token and keyed by its digest" \
    [ "$(start_line | sed 's/ -- .*//')" = "vanth --json start --name tok-1 --timeout 30 --idempotency-key velo_$(s8_of "$tok")_tok-1 --cwd $(pwd -P) --tag velo --tag session:$tok" ]
  run VTN run tok-2 --timeout 30 -- /usr/bin/true; j2=$OUT
  need "a second run uses the same token" [ "$RC" = 0 -a "$(cat "$f")" = "$tok" -a "$(dbq "SELECT count(*) FROM jobs WHERE tags_json LIKE '%\"session:$tok\"%'")" = 2 ]
  run VTN status
  need "a list with no CLAUDE_SESSION_ID is the token's session" [ "$OUT" = "$(printf 'tok-2 %s ok\ntok-1 %s ok' "$j2" "$j1")" ]
  rjs abc tok-3 0; j3=$OUT
  need "CLAUDE_SESSION_ID wins over the token" [ "$RC" = 0 -a "$(dbq "SELECT count(*) FROM jobs WHERE job_id='$j3' AND tags_json LIKE '%\"session:abc\"%'")" = 1 ]
  need "...and the token did not change" [ "$(cat "$f")" = "$tok" ]
  rjs '' tok-4 0; j4=$OUT
  need "an empty CLAUDE_SESSION_ID is as good as none: the token" [ "$RC" = 0 -a "$(dbq "SELECT count(*) FROM jobs WHERE job_id='$j4' AND tags_json LIKE '%\"session:$tok\"%'")" = 1 ]
  printf 'hand-made-1\n' > "$f"; run VTN run tok-5 --timeout 30 -- /bin/true
  need "a token somebody put there is used as it is, never replaced" [ "$RC" = 0 -a "$(cat "$f")" = hand-made-1 -a "$(dbq "SELECT count(*) FROM jobs WHERE tags_json LIKE '%\"session:hand-made-1\"%'")" = 1 ]
  before=$(starts)
  for bad in 'not a token!' '-x' 'a b' ''; do
    printf '%s\n' "$bad" > "$f"
    run VTN run tok-9 --timeout 30 -- /bin/true; need "a token file holding '$bad' is refused (exit 6), not used" [ "$RC" = 6 ]
    run VTN status; need "...also by a list (exit 6)" [ "$RC" = 6 ]
  done
  : > "$f"; run VTN run tok-9 --timeout 30 -- /bin/true; need "an empty token file is refused (exit 6)" [ "$RC" = 6 ]
  printf '%s\n' "$(printf 'a%.0s' $(seq 1 65))" > "$f"; run VTN run tok-9 --timeout 30 -- /bin/true
  need "a token that is not a valid session id (65 characters) is refused (exit 2)" [ "$RC" = 2 ]
  rm "$f"; ln -s "$d/ext/target" "$f"; run VTN run tok-9 --timeout 30 -- /bin/true
  need "a token that is a symlink is refused (exit 6)" [ "$RC" = 6 ]
  run VTN status; need "...by a list too (exit 6)" [ "$RC" = 6 ]
  run ST check-state "$E_HOME"; need "...check-state refuses it (exit 9)" [ "$RC" = 9 ]; need "...naming it" grep -q 'session is a symlink' <<<"$OUT"
  need "...its target was neither read nor written" [ "$(cat "$d/ext/target")" = SENTINEL ]
  rm "$f"; /usr/bin/mkfifo "$f"; run VTN run tok-9 --timeout 30 -- /bin/true
  need "a token that is a FIFO is refused at once (exit 6)" [ "$RC" = 6 ]
  need "none of the refused runs started a job" [ "$(starts)" = "$before" ]
}
t_session_token_file() {  # session-token: made once (O_EXCL, 0600), then read; never through a symlink, never waiting on a FIFO, only a regular file of yours
  local d f tok i w
  d=$(mktemp -d "$T/tf.XXXXXX"); mkdir -m 700 "$d/h" "$d/ext"; printf 'SENTINEL\n' > "$d/ext/target"; f="$d/h/session"
  run ST session-token "$f"; tok=$OUT
  need "session-token exits 0 and prints 16 hex digits" [ "$RC" = 0 ]; need "...(hex)" rx "$tok" '^[0-9a-f]{16}$'
  need "...the file is private (0600) and holds just that and a newline" [ "$(stat -f %Lp "$f")" = 600 -a "$(cat "$f")" = "$tok" -a "$(wc -c < "$f" | tr -d ' ')" = 17 ]
  run ST session-token "$f"; need "a second call prints the same token" [ "$RC" = 0 -a "$OUT" = "$tok" ]
  need "...and leaves no temp name beside it" [ "$(ls "$d/h" | wc -l | tr -d ' ')" = 1 ]
  rm "$f"
  for i in 1 2 3 4 5 6; do ST session-token "$f" > "$d/out.$i" 2>&1 & done; wait
  need "six first calls at once all print one token" [ "$(cat "$d"/out.* | sort -u | wc -l | tr -d ' ')" = 1 -a "$(ls "$d/h" | wc -l | tr -d ' ')" = 1 ]
  rm "$f"; ln -s "$d/ext/target" "$f"; run ST session-token "$f"
  need "a token that is a symlink is refused (exit 9)" [ "$RC" = 9 ]; need "...saying so" grep -q 'is a symlink' <<<"$OUT"
  need "...the target was not read" not grep -q SENTINEL <<<"$OUT"; need "...and not written" [ "$(cat "$d/ext/target")" = SENTINEL ]
  rm "$f"; printf 'not a token!\n' > "$f"; run ST session-token "$f"; need "a line that is not an id is refused (exit 9)" [ "$RC" = 9 ]
  : > "$f"; run ST session-token "$f"; need "an empty file is refused (exit 9)" [ "$RC" = 9 ]; need "...saying it holds no token" grep -q 'holds no token' <<<"$OUT"
  rm "$f"; /usr/bin/mkfifo "$f"; "$PYBIN" "$R/bin/velo-task-state" session-token "$f" > "$d/fifo.out" 2>&1 & w=$!
  waitfor 3 not alive "$w" || { kill -9 "$w" 2>/dev/null; echo "FAILED: session-token of a FIFO waits for a writer instead of refusing it"; exit 1; }
  wait "$w"; RC=$?; need "a FIFO is refused at once, never waited on (exit 9)" [ "$RC" = 9 ]; rm "$f"
  run ST session-token; need "no file is a usage error (exit 2)" [ "$RC" = 2 ]
}
t_status_list() {  # status with no id lists jobs, newest first: the caller's session by default, one session with --session, every session with --all; --issue narrows; --json
  mklist
  CLAUDE_SESSION_ID=abc run VT status
  need "a list with no id shows the caller's session, newest first" [ "$RC" = 0 -a "$OUT" = "$(printf 'ls-a2 %s failed(3)\nls-a1 %s ok' "$JA2" "$JA1")" ]
  CLAUDE_SESSION_ID=abc2 run VT status
  need "...another session sees only its own" [ "$OUT" = "ls-b1 $JB1 ok" ]
  run VT status --session abc2
  need "--session names the session, whatever the caller's" [ "$OUT" = "ls-b1 $JB1 ok" ]
  CLAUDE_SESSION_ID=abc run VT status --session me
  need "--session me is the caller's own" [ "$OUT" = "$(printf 'ls-a2 %s failed(3)\nls-a1 %s ok' "$JA2" "$JA1")" ]
  run VT status --session nobody; need "a session with no jobs lists nothing, and that is exit 0" [ "$RC" = 0 -a -z "$OUT" ]
  run VT status --session ab; need "...a prefix of a session id is not that session" [ "$RC" = 0 -a -z "$OUT" ]
  run VT status --all
  need "--all lists every job, of any session or none, newest first" [ "$OUT" = "$(printf 'ls-out %s ok\nls-a2 %s failed(3)\nls-b1 %s ok\nls-a1 %s ok' "$JO" "$JA2" "$JB1" "$JA1")" ]
  CLAUDE_SESSION_ID=abc run VT status --issue 7
  need "--issue narrows the caller's session" [ "$OUT" = "ls-a2 $JA2 failed(3)" ]
  run VT status --all --issue 7
  need "--all --issue lists the jobs with the issue tag of every session" [ "$OUT" = "$(printf 'ls-a2 %s failed(3)\nls-b1 %s ok' "$JA2" "$JB1")" ]
  run VT status --session abc2 --issue 8; need "an issue nobody has lists nothing (exit 0)" [ "$RC" = 0 -a -z "$OUT" ]
  CLAUDE_SESSION_ID=abc run VT status --json
  need "--json is one object a line, keys sorted, with the verdict" \
    [ "$OUT" = "$(printf '{"exit_code":3,"id":"ls-a2","job_id":"%s","status":"failed","verdict":"failed(3)"}\n{"exit_code":0,"id":"ls-a1","job_id":"%s","status":"completed","verdict":"ok"}' "$JA2" "$JA1")" ]
}
tags_have() {  # <tag>: the JSON on stdin is an object whose top-level "tags" list holds the tag
  "$PYBIN" -I -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) and sys.argv[1] in (d.get("tags") or []) else 1)' "$1"
}
t_vanth_tags_real() {  # R3, R8, VELO_TASK_NETWORK_TESTS=1: the real Vanth emits the tags a session filter reads, and the list order is the one the spec gives
  local sess=netsess ja n rows want
  export VELO_TASK_START_WAIT=60 UV_CACHE_DIR="$T/uv-cache" UV_PYTHON_INSTALL_DIR="$T/uv-python"
  mkhome; run VT install-vanth; need "real install-vanth succeeds" [ "$RC" = 0 ]
  kill "$E_HOLDER"; wait "$E_HOLDER" 2>/dev/null  # the real vanthd does not set SO_REUSEPORT: the reservation goes right before it binds
  run VT ensure-daemon; need "the real daemon starts" [ "$RC" = 0 ]
  for n in net-a net-b net-c net-d; do CLAUDE_SESSION_ID="$sess" run VT run "$n" --timeout 30 -- /usr/bin/true; need "$n starts" [ "$RC" = 0 ]; ja=$OUT; done
  CLAUDE_SESSION_ID=other run VT run net-o --timeout 30 -- /usr/bin/true; need "a job of another session starts" [ "$RC" = 0 ]
  ja=$(cat "$E_HOME/names/net-a")
  waitfor 60 sh -c "[ \"\$(CLAUDE_SESSION_ID=$sess '$R/bin/velo-task' status net-a 2>/dev/null)\" = 'net-a ok' ]" || { echo "FAILED: net-a never reached ok"; exit 1; }
  run env VANTH_HOME="$E_VH" VANTH_DAEMON_PORT="$E_PORT" "$E_VENV/bin/vanth" --json status "$ja"
  need "the real vanth --json status carries the session tag in its tags key (the filter reads it there)" tags_have "session:$sess" <<<"$OUT"
  run VT status --session "$sess" net-a; need "status --session S <id> reports the verdict of a job that carries the tag" [ "$RC" = 0 -a "$OUT" = "net-a ok" ]
  run VT status --session someone-else net-a; need "...and refuses (exit 2) a job that does not" [ "$RC" = 2 ]
  sleep 2  # every job has finished or is about to; the list needs no verdict from the daemon, only the rows
  CLAUDE_SESSION_ID="$sess" run VT status
  need "a list holds the four jobs of the session" [ "$RC" = 0 -a "$(wc -l <<<"$OUT" | tr -d ' ')" = 4 ]
  need "...and not the other session's" not grep -q net-o <<<"$OUT"
  rows=$(awk '{print $2}' <<<"$OUT")
  want=$("$PYBIN" -I -c 'import sqlite3, sys; print("\n".join(r[0] for r in sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("SELECT job_id FROM jobs WHERE tags_json LIKE ? ORDER BY created_at DESC, job_id DESC", ("%session:" + sys.argv[2] + "%",))))' "$E_VH/jobs.sqlite" "$sess")
  need "the list is in the order created_at DESC, job_id DESC" [ "$rows" = "$want" ]
  echo "note: real Vanth stamps created_at to the microsecond, so jobs started back to back are not tied and job_id DESC is the tie-break only; created_at of the four jobs: $("$PYBIN" -I -c 'import sqlite3, sys; print(" ".join(str(r[0]) for r in sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("SELECT created_at FROM jobs WHERE tags_json LIKE ? ORDER BY created_at DESC, job_id DESC", ("%session:" + sys.argv[2] + "%",))))' "$E_VH/jobs.sqlite" "$sess")"
  kill "$(daemon_pid)" 2>/dev/null
}
t_spec_key() {  # R3, R4, B10: the spec gives the idempotency key the code sends, velo_<s8>_<id>, and nowhere the old velo_<id>
  local spec="$R/docs/velo-task-spec.md"
  need "the spec has the key as velo_<s8>_<id>" grep -q 'velo_<s8>_<id>' "$spec"
  need "...R4 gives the rerun key with it" grep -q 'velo_<s8>_<id>_<epoch>_<pid>_<rand8>' "$spec"
  need "...and no line gives the key as velo_<id>" not grep -q 'velo_<id>' "$spec"
}
t_status_list_offline() {  # R8: a list reads jobs.sqlite read-only and needs no daemon; state that is not safe and a schema it cannot read are refused
  local p before calls out
  mklist
  p=$(daemon_pid); kill -9 "$p"; waitfor 5 not alive "$p" || { echo "FAILED: the fake daemon did not die"; exit 1; }
  : > "$E/fail-launch"; before=$(launches); calls=$(grep -c '^vanth ' "$E_CALLS")
  CLAUDE_SESSION_ID=abc run VT status
  need "with the daemon down a list still reads jobs.sqlite" [ "$RC" = 0 -a "$OUT" = "$(printf 'ls-a2 %s failed(3)\nls-a1 %s ok' "$JA2" "$JA1")" ]
  need "...it launched nothing and asked Vanth nothing" [ "$(launches)" = "$before" -a "$(grep -c '^vanth ' "$E_CALLS")" = "$calls" ]
  run VT status ls-a1; need "control: a status by id needs the daemon, which is down (exit 6)" [ "$RC" = 6 ]
  mv "$E_HOME/names" "$E_HOME/names.real"; ln -s "$E_HOME/names.real" "$E_HOME/names"
  CLAUDE_SESSION_ID=abc run VT status; need "a list refuses state that is not safe (names/ a symlink): exit 6" [ "$RC" = 6 ]
  out=$(CLAUDE_SESSION_ID=abc VT status 2>/dev/null); need "...and prints no job" [ -z "$out" ]
  rm "$E_HOME/names"; mv "$E_HOME/names.real" "$E_HOME/names"
  dbx "ALTER TABLE jobs DROP COLUMN tags_json"
  CLAUDE_SESSION_ID=abc run VT status
  need "a database without the tags column is a schema mismatch (exit 5), not a database with no sessions" [ "$RC" = 5 ]; need "...naming the column" grep -q 'jobs.tags_json' <<<"$OUT"
}
t_status_list_empty() {  # nothing run yet: an empty list is exit 0 and starts and makes nothing, not even the token
  mkfake
  run VT status; need "with no jobs.sqlite a list is empty and exit 0" [ "$RC" = 0 -a -z "$OUT" ]
  run VT status --all; need "...--all too" [ "$RC" = 0 -a -z "$OUT" ]
  run VTN status; need "...with no CLAUDE_SESSION_ID too" [ "$RC" = 0 -a -z "$OUT" ]
  need "...none of them launched a daemon or made any state, the token included" [ "$(launches)" = 0 -a ! -e "$E_HOME/names" -a ! -e "$E_HOME/pending" -a ! -e "$E_HOME/session" ]
}
t_status_list_rows() {  # what a list does with the rows it finds: names that could forge a line, tags that are not a list, a restart pending, a trigger parent
  local j1 j2 j3 j4 j5 j6 j7 j8 jp jc jr want
  line3() { printf '%s %s %s\n' "$@"; }
  mkjobs
  j1=$(fv __inject '{"name":"x\ny z","status":"completed","exit_code":0,"tags_json":["velo","session:abc"]}')
  j2=$(fv __inject '{"name":null,"status":"completed","exit_code":0,"tags_json":["velo","session:abc"]}')
  j3=$(fv __inject '{"name":"café","status":"failed","exit_code":2,"tags_json":["velo","session:abc"]}')
  j4=$(fv __inject '{"name":"sp ace","status":"completed","exit_code":0,"tags_json":["velo","session:abc"]}')
  j5=$(fv __inject '{"name":"\"quoted","status":"completed","exit_code":0,"tags_json":["velo","session:abc"]}')
  j6=$(fv __inject '{"name":"bad-tags","status":"completed","exit_code":0,"tags_json":"{not json"}')
  j7=$(fv __inject '{"name":"str-tags","status":"completed","exit_code":0,"tags_json":"\"session:abc\""}')
  j8=$(fv __inject '{"name":"abc2-job","status":"completed","exit_code":0,"tags_json":["velo","session:abc2"]}')
  jp=$(fv __inject '{"name":"parent-1","status":"failed","exit_code":1}')
  jc=$(fv __inject '{"name":"child-1","status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":{"job_id":"'"$jp"'","status":"completed"},"tags_json":["velo","session:abc"]}')
  jr=$(fv __inject '{"name":"rp-1","status":"failed","exit_code":1,"tags_json":["velo","session:abc"],"policy_state_json":{"restart_after":"2099-01-01T00:00:00Z"}}')
  want=$( { line3 rp-1 "$jr" in-flight; line3 child-1 "$jc" "upstream-failed($jp)"; line3 '"\"quoted"' "$j5" ok; line3 '"sp ace"' "$j4" ok
            line3 '"caf\''u00e9"' "$j3" 'failed(2)'; line3 - "$j2" ok; line3 '"x\ny z"' "$j1" ok; } )
  CLAUDE_SESSION_ID=abc run VT status
  need "the session's rows, newest first: a name is as it is when it is one printable word, else JSON, so none can add a line or a field; the rest are the shared verdicts" \
    [ "$RC" = 0 -a "$OUT" = "$want" ]
  run VT status --all
  need "--all lists all eleven, rows whose tags are not a session's too" [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 11 ]
  need "...among them the row whose tags are not JSON" grep -qxF "bad-tags $j6 ok" <<<"$OUT"
  need "...the row whose tags are a JSON string" grep -qxF "str-tags $j7 ok" <<<"$OUT"
  need "...and the other session's" grep -qxF "abc2-job $j8 ok" <<<"$OUT"
  CLAUDE_SESSION_ID=abc run VT status --json
  need "--json carries a name as a JSON string, whatever it holds" grep -qxF '{"exit_code":0,"id":"x\ny z","job_id":"'"$j1"'","status":"completed","verdict":"ok"}' <<<"$OUT"
  need "...and a missing name as null" grep -qxF '{"exit_code":0,"id":null,"job_id":"'"$j2"'","status":"completed","verdict":"ok"}' <<<"$OUT"
}
t_status_session_filter() {  # status <id> and status --job take --session and --issue as filters: a job without the tag is refused (exit 2), never reported
  local jt out
  mklist
  run VT status ls-a1; need "status <id> is any-owner: a session that did not run the job reads it" [ "$RC" = 0 -a "$OUT" = "ls-a1 ok" ]
  run VT status --session abc ls-a1; need "--session with the job's session reports it" [ "$RC" = 0 -a "$OUT" = "ls-a1 ok" ]
  run VT status --session abc2 ls-a1
  need "--session with another session refuses it (exit 2)" [ "$RC" = 2 ]; need "...naming the tag it lacks" grep -q 'session:abc2' <<<"$OUT"
  out=$(VT status --session abc2 ls-a1 2>/dev/null); need "...and no verdict on stdout" [ -z "$out" ]
  run VT status --session ab ls-a1; need "a prefix of the job's session is not the session (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc ls-b1; need "...nor is a session the job's session extends (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc --job "$JA1"; need "--job takes --session too" [ "$RC" = 0 -a "$OUT" = "$JA1 ok" ]
  run VT status --session abc2 --job "$JA1"; need "...refusing another session's job (exit 2)" [ "$RC" = 2 ]
  CLAUDE_SESSION_ID=abc run VT status --session me ls-a1; need "--session me is the caller's own session" [ "$RC" = 0 -a "$OUT" = "ls-a1 ok" ]
  CLAUDE_SESSION_ID=abc2 run VT status --session me ls-a1; need "...so it refuses the job of abc (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc --job "$JO"; need "a job with no session tag belongs to no session (exit 2)" [ "$RC" = 2 ]
  run VT status --job "$JO"; need "...but status --job reads it, as any job" [ "$OUT" = "$JO ok" ]
  run VT status --session abc --issue 7 ls-a2; need "--session and --issue both apply" [ "$RC" = 0 -a "$OUT" = "ls-a2 failed(3)" ]
  run VT status --session abc --issue 8 ls-a2; need "...the issue refuses (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc2 --issue 7 ls-a2; need "...and the session refuses (exit 2)" [ "$RC" = 2 ]
  run VT status --json --session abc ls-a1
  need "--json with --session is the same object" [ "$OUT" = "$(printf '{"exit_code":0,"id":"ls-a1","job_id":"%s","status":"completed","verdict":"ok"}' "$JA1")" ]
  rjs abc2 ls-a1 4; jt=$OUT
  need "premise: another session runs the id ls-a1 too, as a new job" [ "$RC" = 0 -a "$jt" != "$JA1" ]
  run VT status ls-a1; need "status <id> resolves to the last job indexed under the id, whoever ran it" [ "$OUT" = "ls-a1 failed(4)" ]
  run VT status --session abc2 ls-a1; need "--session abc2 finds that job" [ "$OUT" = "ls-a1 failed(4)" ]
  run VT status --session abc ls-a1; need "--session abc is refused, as the id now means abc2's job (exit 2)" [ "$RC" = 2 ]
  run VT status --session abc --job "$JA1"; need "...abc's own job is addressed by --job" [ "$OUT" = "$JA1 ok" ]
}

echo "velo-task M2a: verdict_of, run, status"
check "verdict_of: B1 B18 B26, every status, the restart rule, both input shapes" t_verdict_table
check "verdict-of: refuses another job, name or issue; exit 6 on input that is not JSON; lost(pruned) and unknown-job" t_verdict_cli
check "B3 B11: run refuses a missing timeout, a bad id, issue, timeout, stage or command before it starts or creates anything" t_run_validation
check "B11: the edges of id, issue, timeout and stage are accepted" t_run_limits
check "B10 R3 R6 R11a: one job per id, a conflict is exit 5, --rerun is a new job, a clean environment, no secret, no --env or --policy" t_run_basic
check "B10: a colliding --rerun nonce is detected, retried with a fresh one, and exit 5 after 5 attempts" t_rerun_collision
check "B10: the --rerun key suffix is <epoch>_<pid>_<rand8>, new on every call" t_rerun_nonce
check "vanth start returned no job: a refusal leaves nothing pending, anything else keeps the record" t_run_failures
check "R17 crash windows: killed at each failpoint, the on-disk state is the one reconcile reads" t_run_crash
check "R17: the pending record, the index line and the unlink are fsynced in order" t_run_fsync_order
check "B25 recovery: status <id> finds the job of a run killed after vanth start returned, from Vanth's own record, with one execution" t_reconcile_status
check "R3: run settles the id's records first, so the last line of the index is the last job started" t_reconcile_run
check "B25 recovery: the same after 1,100 newer jobs, which vanth list (capped at 1,000 rows) cannot show" t_reconcile_bulk
check "R3: a record Vanth has no key for is reported pending-unsent and never replayed; status of the id is exit 3" t_reconcile_unsent
check "R3: the key is matched exactly: one that extends, contains or case-folds it does not settle a record" t_reconcile_exact
check "R17: a reconcile killed between the index line and the unlink is redone, with no second line" t_reconcile_redo
check "R3: status <id> settles that id's records only" t_reconcile_scope
check "R3: two accepted records for one id settle in the order they were written, whatever order their nonces have" t_reconcile_epoch
check "R3 R21: a recovery and a run settle one id at once: one line per job, and the newest job is the last line" t_reconcile_race
check "R17: a temp file a crash left between create and link is swept; one whose writer is still running is not" t_sweep_temps
check "R3 R4 B10: the spec gives the idempotency key as velo_<s8>_<id>" t_spec_key
check "an unsafe record, name index or database, or a job id that is not one, stops status and run (exit 6); nothing is skipped" t_reconcile_unsafe
check "R4: a status that settles the record of a run in flight does not make that run start a second job" t_reconcile_inflight
check "B1 B18 B26 through status: every verdict, injected rows, restart pending, --issue" t_status_verdicts
check "B25 read side: an id resolves through the name index; the name is checked; --job needs no index; no match is exit 2" t_status_resolution
check "R6 R7: a daemon that cannot be reached is exit 6 and velo-task restart-daemon, never a verdict" t_status_daemon
check "names/ and pending/ are checked like every state path: a symlink or the wrong kind is refused" t_state_paths
check "index-last, index-has: never through a symlink, never waiting on a FIFO, only your regular files" t_index_files
check "pending-write: the canonical settings, private, only what velo-task sends, never through a symlink" t_pending_write
check "remove: unlink then fsync the directory, never through a symlink, a missing file is fine" t_remove
check "R21: VELO_TASK_RERUN_NONCE is honoured only under the test capability" t_seam_nonce
check "the new library functions are not subcommands" t_not_subcommands
check "B14: bash 3.2, no bash-4 constructs, in every script including the new code" t_b14_new
check "sessions: a bad session id, an empty id or --session, --all with an id or --session: exit 2, before anything is started or read" t_session_validation
check "the key is velo_<8 hex digits of sha256(session id)>_<id> and the job is tagged session:<id>, after velo" t_session_key
check "B-S1: two sessions starting one id start two jobs; one session starting it twice starts one" t_session_separation
check "no CLAUDE_SESSION_ID: the session is the state dir's token, made on first use, private, never changed, and refused when unsafe" t_session_token
check "session-token: made once (O_EXCL, 0600), then read; never through a symlink, never waiting on a FIFO" t_session_token_file
check "status with no id lists jobs, newest first: the caller's session, --session, --all, --issue, --json" t_status_list
check "R8: a list needs no daemon; it refuses unsafe state and a database without the tags column" t_status_list_offline
check "a list with nothing run yet is empty and exit 0, and makes nothing, not even the token" t_status_list_empty
check "list rows: no name can forge a line, tags that are not a session's list belong to none, a restart pending, a trigger parent" t_status_list_rows
check "status <id> and status --job take --session and --issue as filters: a job without the tag is refused, never reported" t_status_session_filter

# ---- every check above goes RED on a mutated copy of the code ------------------------------------------------------
# verdict_of
prove "B1: verdict_of answers ok for every status" t_verdict_table $S $'    status = row["status"]\n    if status in IN_FLIGHT:' $'    status = row["status"]\n    return "ok"\n    if status in IN_FLIGHT:'
prove "B18: the default branch of verdict_of is ok" t_verdict_table $S '    return "lost"  # orphaned, any other cancelled, a status outside both sets' '    return "ok"  # orphaned, any other cancelled, a status outside both sets'
prove "B18: failed with no exit_code is failed(0)" t_verdict_table $S '        return "failed(%d)" % code if isinstance(code, int) and not isinstance(code, bool) else "lost"' '        return "failed(%d)" % (code or 0)'
prove "B18: a boolean exit_code counts as a number" t_verdict_table $S 'isinstance(code, int) and not isinstance(code, bool)' 'isinstance(code, int)'
prove "B26: every cancelled is killed" t_verdict_table $S $'        if actor == "user":\n            return "killed"' $'        if True:\n            return "killed"'
prove "B26: the trigger-parent reason is not checked" t_verdict_table $S '        if (actor == "daemon" and row.get("stop_reason") == TRIGGER_REASON and isinstance(parent, str)' '        if (actor == "daemon" and isinstance(parent, str)'
prove "B26: the stop_actor of a trigger-parent cancel is not checked" t_verdict_table $S '        if (actor == "daemon" and row.get("stop_reason") == TRIGGER_REASON and isinstance(parent, str)' '        if (row.get("stop_reason") == TRIGGER_REASON and isinstance(parent, str)'
prove "B26: the trigger parent need not exist" t_verdict_table $S '                and JOB_ID.fullmatch(parent) and known_job(parent)):' '                and JOB_ID.fullmatch(parent)):'
prove "B26: the trigger parent id is not checked against the job id charset" t_verdict_table $S '                and JOB_ID.fullmatch(parent) and known_job(parent)):' '                and known_job(parent)):'
prove "R1: a restart pending is ignored" t_verdict_table $S '        if status in ("failed", "orphaned") and _restart_pending(row):' '        if False:'
prove "R1: a restart pending on an orphaned row is ignored" t_verdict_table $S '        if status in ("failed", "orphaned") and _restart_pending(row):' '        if status in ("failed",) and _restart_pending(row):'
prove "R1: a policy state that is not an object is read as no restart" t_verdict_table $S '        raise ValueError("policy_state_json is not an object")' '        return False'
prove "R1: launching is not in flight" t_verdict_table $S 'IN_FLIGHT = frozenset(("queued", "launching", "running", "paused", "retrying", "stopping"))' 'IN_FLIGHT = frozenset(("queued", "running", "paused", "retrying", "stopping"))'
prove "B18: input that is not JSON is read as an empty status" t_verdict_cli $S '            die(6, "verdict-of: the status is not JSON: %s" % exc)' '            row = {}'
prove "verdict-of does not check the job id of the status" t_verdict_cli $S '        for key, want in (("job_id", job), ("name", opts.get("name"))):' '        for key, want in (("name", opts.get("name")),):'
prove "verdict-of does not check the name of the status" t_verdict_cli $S '        for key, want in (("job_id", job), ("name", opts.get("name"))):' '        for key, want in (("job_id", job),):'
prove "verdict-of does not check the issue tag" t_verdict_cli $S '        for key in ("issue", "session"):' '        for key in ("session",):'
prove "verdict-of does not check the session tag" t_verdict_cli $S '        for key in ("issue", "session"):' '        for key in ("issue",):'
prove "verdict-of reads tags that are a string as a list" t_verdict_cli $S '(row["tags"] if isinstance(row.get("tags"), list) else [])' 'row.get("tags", [])'
prove "an absent row is always unknown-job" t_verdict_cli $S '        verdict = "lost(pruned)" if job and names and index_has(names, job) else "unknown-job"' '        verdict = "unknown-job"'
prove "an absent row is always lost(pruned)" t_verdict_cli $S '        verdict = "lost(pruned)" if job and names and index_has(names, job) else "unknown-job"' '        verdict = "lost(pruned)"'
prove "unknown-job exits 0" t_verdict_cli $S '    return 3 if verdict == "unknown-job" else 0' '    return 0'
prove "input that is not JSON is exit 1" t_verdict_cli $S 'die(6, "verdict-of: the status is not JSON: %s" % exc)' 'die(1, "verdict-of: the status is not JSON: %s" % exc)'
prove "verdict-of --json keys are not sorted" t_verdict_cli $S '"verdict": verdict}, sort_keys=True, separators=(",", ":"))' '"verdict": verdict}, separators=(",", ":"))'
prove "verdict-of prints no label" t_verdict_cli $S '    label = opts.get("label") or job or "-"' '    label = "-"'

# run: what is refused before anything happens (B3, B11)
prove "B3: run has a default timeout" t_run_validation $L '  [ -n "$timeout" ] || die 2 "--timeout S is required: every job is started with a deadline (R2)"' '  timeout="${timeout:-60}"'
prove "B11: nothing run is given is validated" t_run_validation $L $'  [[ "$2" =~ $re ]] || die 2 "invalid $1 \'$2\': must match $re"' '  [[ "$2" =~ $re ]] || true'
prove "B11: ids may have uppercase letters" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$'
prove "B11: ids may have dots and colons" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9][a-z0-9_.:-]{2,63}$'
prove "B11: ids may be 2 characters" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9][a-z0-9_-]{1,63}$'
prove "B11: ids may be 65 characters" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9][a-z0-9_-]{2,64}$'
prove "B11: ids may start with a dash or an underscore" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9_-][a-z0-9_-]{2,63}$'
prove "B11: the id pattern is anchored at the start only" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9][a-z0-9_-]{2,63}'
prove "B11: the id pattern is anchored at the end only" t_run_validation $L '^[a-z0-9][a-z0-9_-]{2,63}$' '[a-z0-9][a-z0-9_-]{2,63}$'
prove "B11: ids are at most 63 characters" t_run_limits $L '^[a-z0-9][a-z0-9_-]{2,63}$' '^[a-z0-9][a-z0-9_-]{2,62}$'
prove "B11: issue numbers may have 10 digits" t_run_validation $L '^[0-9]{1,9}$' '^[0-9]{1,10}$'
prove "B11: issue numbers may be empty" t_run_validation $L '^[0-9]{1,9}$' '^[0-9]{0,9}$'
prove "B11: issue numbers are at most 8 digits" t_run_limits $L '^[0-9]{1,9}$' '^[0-9]{1,8}$'
prove "B11: a timeout may be 0" t_run_validation $L '^[1-9][0-9]{0,8}$' '^[0-9]{1,9}$'
prove "B11: a timeout may have 10 digits" t_run_validation $L '^[1-9][0-9]{0,8}$' '^[1-9][0-9]{0,9}$'
prove "B11: a timeout is at most 8 digits" t_run_limits $L '^[1-9][0-9]{0,8}$' '^[1-9][0-9]{0,7}$'
prove "B11: a stage may have 33 characters" t_run_validation $L '^[a-z0-9][a-z0-9_-]{0,31}$' '^[a-z0-9][a-z0-9_-]{0,32}$'
prove "B11: a stage may have uppercase letters" t_run_validation $L '^[a-z0-9][a-z0-9_-]{0,31}$' '^[A-Za-z0-9][a-z0-9_-]{0,31}$'
prove "B11: a stage may have spaces" t_run_validation $L '^[a-z0-9][a-z0-9_-]{0,31}$' '^[a-z0-9][a-z0-9_ -]{0,31}$'
prove "B11: a stage is at most 31 characters" t_run_limits $L '^[a-z0-9][a-z0-9_-]{0,31}$' '^[a-z0-9][a-z0-9_-]{0,30}$'
prove "B11: a job id may have a slash" t_status_resolution $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' '^[A-Za-z0-9][A-Za-z0-9_/-]{0,127}$'
prove "B11: a job id may have 129 characters" t_status_resolution $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' '^[A-Za-z0-9][A-Za-z0-9_-]{0,128}$'
prove "B11: a job id may start with a dash" t_status_resolution $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' '^[A-Za-z0-9_-][A-Za-z0-9_-]{0,127}$'

# run: what is sent and what is kept (B10, R3, R11a)
prove "B10: vanth start is sent without the idempotency key" t_run_basic $L 'out=$(vanth_env "$VANTH" --json start "${args[@]}" -- "${cmdline[@]}" 2>&1) || rc=$?' 'out=$(vanth_env "$VANTH" --json start --name "$id" --timeout "$timeout" --cwd "$cwd" --tag velo -- "${cmdline[@]}" 2>&1) || rc=$?'
prove "B10: the idempotency key contains a colon" t_run_basic $L '    key="velo_${s8}_$id"' '    key="velo:${s8}_$id"'
prove "R11a: --policy is sent" t_run_basic $L 'out=$(vanth_env "$VANTH" --json start "${args[@]}" -- ' 'out=$(vanth_env "$VANTH" --json start "${args[@]}" --policy "{}" -- '
prove "R11a: the caller's secret is sent as --env" t_run_basic $L 'out=$(vanth_env "$VANTH" --json start "${args[@]}" -- ' 'out=$(vanth_env "$VANTH" --json start "${args[@]}" --env "OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}" -- '
prove "R11a: vanth_env passes the caller's secret on" t_run_basic $L 'VANTH_DAEMON_PORT="$PORT" "$@"; }' 'VANTH_DAEMON_PORT="$PORT" OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" "$@"; }'
prove "R17: the pending record is never unlinked" t_run_basic $S $'    cmd_remove([path])\n    failpoint("pending.unlinked")\n    return 0' $'    failpoint("pending.unlinked")\n    return 0'
prove "R3: the job id is never appended to the name index" t_run_basic $S '    if not index_has(names, job, ident):  # M2a: under the lock' '    if False:  # M2a: under the lock'
prove "R3: the job id is appended on every run" t_run_basic $S '    if not index_has(names, job, ident):  # M2a: under the lock' '    if True:  # M2a: under the lock'
prove "R3: --tag velo is not sent" t_run_basic $L '--cwd "$cwd" --tag velo --tag "session:$session")' '--cwd "$cwd" --tag "session:$session")'
prove "R3: --issue is not sent as a tag" t_run_basic $L 'if [ "$have_issue" = 1 ]; then args=("${args[@]}" --tag "issue:$issue"); fi' ':'
prove "R3: --stage is not sent as a tag" t_run_basic $L 'if [ "$have_stage" = 1 ]; then args=("${args[@]}" --tag "stage:$stage"); fi' ':'
prove "R3: the cwd is not resolved" t_run_basic $L '  cwd=$(pwd -P)' '  cwd=$(pwd)'
prove "R3: run reads every name index, not the id's" t_run_basic $L 'st index-has "$NAMES" "$job" "$id" ||' 'st index-has "$NAMES" "$job" ||'
prove "B10: a conflict is exit 0" t_run_basic $L 'die 5 "IDEMPOTENCY_CONFLICT: ${2#vanth start: }; this id' 'die 0 "IDEMPOTENCY_CONFLICT: ${2#vanth start: }; this id'
prove "B10: a conflict is not recognised" t_run_basic $L '*"idempotency_key was already used"*|' ''
prove "R6: vanth start decides by its exit code, not by its JSON" t_run_basic $L '    [ -n "$job" ] || start_refused "$rc" "$out" "$pending"' '    [ "$rc" -eq 0 ] || start_refused "$rc" "$out" "$pending"'
prove "B10: a conflict leaves its pending record" t_run_failures $L $'      st remove "$PENDING/$3"\n      die 5 "IDEMPOTENCY_CONFLICT' $'      die 5 "IDEMPOTENCY_CONFLICT'
prove "B10: a cleaned job is not a conflict" t_run_failures $L '|*"idempotency_key refers to cleaned job"*)' ')'
prove "R17: a transport error from vanth start deletes the pending record" t_run_failures $L '    *"failed to reach daemon"*) die 6 "daemon-down: $2;' '    *"failed to reach daemon"*) st remove "$PENDING/$3"; die 6 "daemon-down: $2;'
prove "R17: any other start failure deletes the pending record" t_run_failures $L '    *) die 1 "vanth start failed (exit $1)' '    *) st remove "$PENDING/$3"; die 1 "vanth start failed (exit $1)'
prove "R7: a transport error from vanth start is exit 1" t_run_failures $L '    *"failed to reach daemon"*) die 6 "daemon-down: $2;' '    *"failed to reach daemon"*) die 1 "daemon-down: $2;'
prove "R7: a start failure does not name restart-daemon" t_run_failures $L 'is kept; recover with: velo-task restart-daemon" ;;' 'is kept" ;;'

# run --rerun (B10, R4)
prove "B10: --rerun does not look for a colliding key" t_rerun_collision $L 'if [ "$known" = 0 ] && [ "$rerun" = 1 ] && [ -e' 'if [ "$known" = 99 ] && [ "$rerun" = 1 ] && [ -e'
prove "B10: a --rerun retry reuses the nonce" t_rerun_collision $L 'key="${key}_$(rerun_nonce "$n")"' 'key="${key}_$(rerun_nonce 1)"'
prove "B10: --rerun gives up after 3 attempts" t_rerun_collision $L 'if [ "$n" -ge 5 ]; then die 5' 'if [ "$n" -ge 3 ]; then die 5'
prove "B10: --rerun tries 9 times" t_rerun_collision $L 'if [ "$n" -ge 5 ]; then die 5' 'if [ "$n" -ge 9 ]; then die 5'
prove "B10: a colliding --rerun attempt keeps its pending record" t_rerun_collision $L $'      st remove "$PENDING/$pending"\n      if [ "$n" -ge 5 ]' $'      if [ "$n" -ge 5 ]'
prove "B10: a nonce list is read by position without the last one repeating" t_rerun_collision $L '  n=$(( $1 < ${#parts[@]} ? $1 : ${#parts[@]} ))' '  n=$1'
prove "B10: --rerun adds no nonce to the key" t_run_basic $L '    if [ "$rerun" = 1 ]; then key="${key}_$(rerun_nonce "$n")"; fi' ':'
prove "B10: the --rerun nonce has no epoch" t_rerun_nonce $L '"$(/bin/date +%s)" "$$" ' ''
prove "B10: the --rerun nonce has no pid" t_rerun_nonce $L '"$$" "$(/usr/bin/od' '"$(/usr/bin/od'
prove "B10: the --rerun nonce has a constant random part" t_rerun_nonce $L '/dev/urandom' '/dev/zero'

# run: the crash windows and their order (R17, R21)
prove "R17: the pending record is written after vanth start" t_run_crash \
  $L $'    pending=$(st pending-write "$PENDING" -- "${args[@]}" -- "${cmdline[@]}")  # R17 (1): the settings are durable before anything is sent\n    stl failpoint pending.published\n    rc=0\n' $'    rc=0\n' \
  $L $'    job=$(printf \'%s\\n\' "$out"' $'    pending=$(st pending-write "$PENDING" -- "${args[@]}" -- "${cmdline[@]}")\n    stl failpoint pending.published\n    job=$(printf \'%s\\n\' "$out"'
prove "R17: the pending record is unlinked before the job id is indexed" t_run_crash \
  $S $'    if not index_has(names, job, ident):  # M2a: under the lock, so a concurrent settle cannot slip between the check and the append\n        cmd_append_index([os.path.join(names, ident), job])\n        failpoint("index.appended")\n    cmd_remove([path])\n' \
     $'    cmd_remove([path])\n    if not index_has(names, job, ident):  # M2a: under the lock, so a concurrent settle cannot slip between the check and the append\n        cmd_append_index([os.path.join(names, ident), job])\n        failpoint("index.appended")\n'
prove "R21: the pending.published failpoint is gone" t_run_crash $L '    stl failpoint pending.published' '    :'
prove "R21: the start.returned failpoint is gone" t_run_crash $L '    stl failpoint start.returned' '    :'
prove "R21: the index.appended failpoint is gone" t_run_crash $S '        failpoint("index.appended")' '        pass'
prove "R21: the pending.unlinked failpoint is gone" t_run_crash $S '    failpoint("pending.unlinked")' '    pass'
prove "R17: remove does not fsync the directory" t_run_fsync_order $S $'    os.unlink(path)\n    _sync_path(os.path.dirname(path), "dir")\n    return 0' $'    os.unlink(path)\n    return 0'
prove "R17: the pending record is not fsynced before it is published" t_run_fsync_order $S $'    _sync_path(src, "file")\n    trace("link", src, dest)' $'    trace("link", src, dest)'
prove "R17: the pending directory is not fsynced after the link" t_run_fsync_order $S $'    failpoint("publish.linked", dest)\n    _sync_path(os.path.dirname(dest), "dir")' $'    failpoint("publish.linked", dest)'
prove "R17: the name index's new directory entry is not fsynced" t_run_fsync_order $S $'    if created:\n        _sync_path(os.path.dirname(path), "dir")\n    return 0' $'    return 0'
prove "R17: the name index line is not fsynced" t_run_fsync_order $S $'        _sync_fd(fd, "file", path)\n    finally:' $'        pass\n    finally:'
prove "R17: an unsafe name index is found after the job was started" t_state_paths $L $'  rc=0; st index-last "$NAMES" "$id" >/dev/null || rc=$?  # an unsafe name index is found now, not after the job was started\n  [ "$rc" -le 1 ] ||' $'  [ 0 -le 1 ] ||'

# reconcile (R3, R17, B25 recovery): the mutants the brief names (replays vanth start, uses vanth list, appends twice, matches the key by substring) and the rest
RCI='        if not index_has(names, job, ident):'
RCA='            cmd_append_index([os.path.join(names, ident), job])'
RCQ='"SELECT job_id FROM local_start_requests WHERE idempotency_key = ?", (record["key"],))'
RCV='[home + "/venv/bin/vanth", "--json", '    # a mutant reaches the fake Vanth CLI by the layout of the home: <home>/vanth/jobs.sqlite is db, <home>/venv/bin/vanth the CLI
RCE='env={"VANTH_HOME": os.path.dirname(os.path.abspath(db)), "PATH": "/usr/bin:/bin"}'
RCH='home = os.path.dirname(os.path.dirname(os.path.abspath(db)))'
prove "R3: status does not reconcile before it reads the index" t_reconcile_status $L '    reconcile_id "$id" || unsent=$?' '    :'
prove "R3: a record whose key is present is not indexed" t_reconcile_status $S "$RCI"$'\n'"$RCA" $'        if False:\n'"$RCA"
prove "R3: a settled record is not unlinked" t_reconcile_status $S $'        failpoint("reconcile.indexed")\n        cmd_remove([path])' $'        failpoint("reconcile.indexed")'
prove "R3: reconcile appends the job id twice" t_reconcile_status $S "$RCA"$'\n' "$RCA"$'\n'"$RCA"$'\n'
prove "R3: run does not reconcile before it starts anything" t_reconcile_run $L '  rc=0; reconcile_id "$id" || rc=$?' '  rc=0; :'
prove "R3: run does not reconcile before it starts anything (a killed run's record piles up)" t_run_crash $L '  rc=0; reconcile_id "$id" || rc=$?' '  rc=0; :'
prove "B25: reconcile reads vanth list instead of local_start_requests" t_reconcile_bulk \
  $S "        found = query_ro(db, $RCQ" \
     "        $RCH"$'\n'"        listed = json.loads(subprocess.run($RCV\"list\", \"--all\", \"--name\", ident, \"--limit\", \"1000\"], $RCE, capture_output=True, text=True).stdout)"$'\n''        found = [{"job_id": row["job_id"]} for row in listed if row["name"] == ident][:1]'
prove "B25: reconcile replays vanth start for a key Vanth has not seen" t_reconcile_unsent \
  $S $'        if not found:\n            unsent = True\n            continue' \
     $'        if not found:\n'"            $RCH"$'\n'"            subprocess.run($RCV\"start\", \"--name\", record[\"name\"], \"--timeout\", str(record[\"timeout\"]), \"--idempotency-key\", record[\"key\"], \"--cwd\", record[\"cwd\"], \"--tag\", \"velo\", \"--\"] + record[\"argv\"], $RCE, check=False, capture_output=True)"$'\n            unsent = True\n            continue'
prove "R3: reconcile unlinks a record Vanth has no key for" t_reconcile_unsent $S $'        if not found:\n            unsent = True\n            continue' $'        if not found:\n            unsent = True\n            cmd_remove([path])\n            continue'
prove "R3: an unsent record is exit 0" t_reconcile_unsent $S '    return 3 if unsent else 0' '    return 0'
prove "R3: an unsent record is not reported on stderr" t_reconcile_unsent $S '        sys.stderr.write("pending-unsent %s\n" % ident)' '        pass'
prove "R3: an unsent record is a failure of reconcile" t_reconcile_unsent $L '  case "$rc" in 0|3) return "$rc" ;; esac' '  case "$rc" in 0) return "$rc" ;; esac'
prove "R3: status of an unsent id is exit 2" t_reconcile_unsent $L '[ "$unsent" = 3 ]; then die 3 ' '[ "$unsent" = 3 ]; then die 2 '
prove "R3: status of an unsent id does not say how to settle it" t_reconcile_unsent $L '; re-run \`velo-task run $id ...\` (idempotent: the same key returns the existing job)"' '"'
prove "R3: reconcile matches the key as a substring" t_reconcile_exact $S "$RCQ" '"SELECT job_id FROM local_start_requests WHERE instr(idempotency_key, ?) > 0", (record["key"],))'
prove "R3: reconcile matches the key as a prefix" t_reconcile_exact $S "$RCQ" '"SELECT job_id FROM local_start_requests WHERE idempotency_key LIKE ?", (record["key"] + "%",))'
prove "R3: reconcile matches the key without regard to case" t_reconcile_exact $S "$RCQ" '"SELECT job_id FROM local_start_requests WHERE idempotency_key LIKE ?", (record["key"],))'
prove "R17: reconcile appends the job id without checking that it is listed" t_reconcile_redo $S "$RCI" '        if True:'
prove "R17: reconcile unlinks the record before it indexes the job" t_reconcile_redo $S "$RCI"$'\n'"$RCA"$'\n        failpoint("reconcile.indexed")\n        cmd_remove([path])' $'        cmd_remove([path])\n        failpoint("reconcile.indexed")\n'"$RCI"$'\n'"$RCA"
prove "R21: the reconcile.indexed failpoint is gone" t_reconcile_redo $S $'        failpoint("reconcile.indexed")\n' $'        pass\n'
prove "R3: reconcile settles the records of every id" t_reconcile_scope $S '        if record is None or record["name"] != ident:' '        if record is None:'
prove "R3: the records of one id settle in nonce order, not in the order they were written" t_reconcile_epoch $S '    records.sort(key=lambda item: record_order(item[1], item[0]))' '    records.sort(key=lambda item: item[0])'
prove "M2a: the id lock is not taken, so a settle can land inside another's critical section" t_reconcile_race $S $'    return lock_file(os.path.join(os.path.dirname(os.path.abspath(names)), "lock", "id-" + ident))' $'    return None'
prove "R17: a temp file a crash left is never swept" t_sweep_temps $S '        pid = temp_writer(name)' '        pid = None'
prove "R17: a temp file of a writer that is still running is swept too" t_sweep_temps $S '        if pid is None or not writer_gone(pid):' '        if pid is None:'
prove "R4: the spec gives the plain key without the session part" t_spec_key docs/velo-task-spec.md '`velo_<s8>_<id>` for a plain `run`' '`velo_<id>` for a plain `run`'
prove "R5: status exits non-zero for a verdict that is not ok (it mirrors the verdict like wait)" t_status_verdicts $S $'    return 3 if verdict == "unknown-job" else 0' $'    return 3 if verdict == "unknown-job" else (0 if verdict in ("ok", "in-flight") else 1)'
if [ "${VELO_TASK_NETWORK_TESTS:-}" = 1 ]; then
  prove "R3: the session tag is not sent to Vanth (real Vanth: the tag never returns)" t_vanth_tags_real $L '--cwd "$cwd" --tag velo --tag "session:$session")' '--cwd "$cwd" --tag velo)'
  prove "R8: the list is oldest first (real Vanth)" t_vanth_tags_real $S 'ORDER BY created_at DESC, job_id DESC"):' 'ORDER BY created_at ASC, job_id DESC"):'
fi
prove "R3: a pending record that is not a record is skipped" t_reconcile_unsafe $S '        die(9, "%s is not a pending record" % path)' '        return None'
prove "R3: a database that cannot be read is read as an unsent start" t_reconcile_unsafe \
  $S "        found = query_ro(db, $RCQ" \
     $'        try:\n'"            found = query_ro(db, $RCQ"$'\n        except SystemExit:\n            found = []'
prove "R3: a job id that starts with a dash is indexed" t_reconcile_unsafe $S 'or not JOB_ID.fullmatch(job) or job.startswith("-"):' 'or not JOB_ID.fullmatch(job):'
prove "R3: files beside the records are read as records" t_reconcile_unsafe $S 'if PENDING_NONCE.fullmatch(name))' 'if True)'
prove "R3: reconcile reads a record through a symlink" t_reconcile_unsafe $S $'        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)\n    except FileNotFoundError:' $'        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)\n    except FileNotFoundError:'
prove "R3: a failure to reconcile is ignored" t_reconcile_unsafe $L $'  die 6 "reconcile of \'$1\' failed (helper exit $rc, see above); nothing was resolved"' '  return 0'
prove "R3: reconcile takes a path for an id" t_reconcile_unsafe $S '    if len(args) != 4 or args[3] in ("", ".", "..") or "/" in args[3]:' '    if False:'
prove "R4: run takes the job a status settled for a colliding key" t_reconcile_inflight $L '[ "$rerun" = 1 ] && [ -e "$PENDING/$pending" ]; then' '[ "$rerun" = 1 ]; then'

# status (B1, B18, B25, B26, R1, R5, R20)
prove "B1: status prints ok whatever the row says" t_status_verdicts $L $'  if [ "$absent" = 1 ]; then st verdict-of --absent "${vargs[@]}"; else printf \'%s\\n\' "$out" | st verdict-of "${vargs[@]}"; fi' $'  printf \'%s ok\\n\' "${id:-$job}"'
prove "R1: status does not look for a pending restart" t_status_verdicts $S '        if db and job and "policy_state_json" not in row and row.get("status") in ("failed", "orphaned"):' '        if False:'
prove "R1: status looks for a pending restart of failed rows only" t_status_verdicts $S 'row.get("status") in ("failed", "orphaned"):' 'row.get("status") in ("failed",):'
prove "B26: a trigger parent is looked up in jobs.sqlite only" t_verdict_table $S 'lambda parent: bool(names and index_has(names, parent)) or bool(db and job_row_exists(db, parent))' 'lambda parent: bool(db and job_row_exists(db, parent))'
prove "B26: a trigger parent is looked up in the name index only" t_verdict_table $S 'lambda parent: bool(names and index_has(names, parent)) or bool(db and job_row_exists(db, parent))' 'lambda parent: bool(names and index_has(names, parent))'
prove "B26: status does not look a trigger parent up in jobs.sqlite" t_status_verdicts $S 'lambda parent: bool(names and index_has(names, parent)) or bool(db and job_row_exists(db, parent))' 'lambda parent: bool(names and index_has(names, parent))'
prove "R5: status --issue is not applied" t_status_verdicts $L $'\n  if [ "$have_issue" = 1 ]; then vargs=("${vargs[@]}" --issue "$issue"); fi' $'\n  :'
prove "B25: an id is resolved with vanth list" t_status_resolution $L '    job=$(st index-last "$NAMES" "$id") || rc=$?' $'    job=$(vanth_env "$VANTH" --json list --all --name "$id" --limit 1000 2>&1 | /usr/bin/awk -F\'"\' \'/"job_id"/ && !s {print $4; s=1}\') || rc=$?'
prove "B25: the name of the job found need only contain the id" t_status_resolution $S '            if want is not None and row.get(key) != want:' '            if want is not None and want not in str(row.get(key)):'
prove "B25: status does not verify the name of the job found" t_status_resolution $L '--name "$id" --label "$id"' '--label "$id"'
prove "B25: status does not verify the job id it asked for" t_status_resolution $L 'vargs=(--names "$NAMES" --db "$VH/jobs.sqlite" --job "$job")' 'vargs=(--names "$NAMES" --db "$VH/jobs.sqlite")'
prove "B25: status --job needs the name index" t_status_resolution $L '  out=$(vanth_env "$VANTH" --json status "$job" 2>&1) || rc=$?' $'  st index-has "$NAMES" "$job" || die 2 "the job is not in the name index"\n  out=$(vanth_env "$VANTH" --json status "$job" 2>&1) || rc=$?'
prove "B25: an id with no match is exit 3" t_status_resolution $L '      1) die 2 "no job named' '      1) die 3 "no job named'
prove "R20: a job vanth does not know is an error" t_status_resolution $L '      *"unknown job"*) absent=1 ;;' '      *"unknown job"*) die 1 "vanth does not know that job" ;;'

# the daemon (R6, R7)
prove "R6: run and status go on when ensure-daemon fails" t_status_daemon $L '|| die 6 "daemon-down: ensure-daemon failed' '|| echo "daemon-down: ensure-daemon failed'
prove "R6: ensure-daemon failing is exit 1" t_status_daemon $L '|| die 6 "daemon-down: ensure-daemon failed' '|| die 1 "daemon-down: ensure-daemon failed'
prove "R7: a daemon that is down does not name restart-daemon" t_status_daemon $L '(exit $rc); recover with: velo-task restart-daemon"' '(exit $rc)"'
prove "R7: a status transport error does not name restart-daemon" t_status_daemon $L 'no verdict was read; recover with: velo-task restart-daemon"' 'no verdict was read"'
prove "R7: a status transport error is read as an unknown job" t_status_daemon $L '      *"failed to reach daemon"*) die 6 "daemon-down: $out;' '      *"failed to reach daemon"*) absent=1; : "daemon-down: $out;'
prove "R7: a status transport error is exit 1" t_status_daemon $L '      *"failed to reach daemon"*) die 6 "daemon-down: $out;' '      *"failed to reach daemon"*) die 1 "daemon-down: $out;'
prove "R7: any other status failure is read as an unknown job" t_status_daemon $L '      *) die 1 "vanth status failed (exit $rc): $out" ;;' '      *) absent=1 ;;'
prove "R7: a status that is not JSON is exit 1" t_status_daemon $S 'die(6, "verdict-of: the status is not JSON: %s" % exc)' 'die(1, "verdict-of: the status is not JSON: %s" % exc)'
prove "R6: run does not ensure the daemon first" t_status_daemon $L $'  need_daemon\n  /bin/mkdir -p -m 700 "$NAMES" "$PENDING"' $'  /bin/mkdir -p -m 700 "$NAMES" "$PENDING"'
prove "R6: status does not ensure the daemon first" t_status_daemon $L $'  need_daemon\n  if [ -n "$id" ]; then  # R3:' $'  if [ -n "$id" ]; then  # R3:'

# state and the helper commands
prove "names/ is not a state path" t_state_paths $S ', ("names", "dir"), ("pending", "dir"), ("session", "file"))' ', ("pending", "dir"), ("session", "file"))'
prove "pending/ is not a state path" t_state_paths $S ', ("names", "dir"), ("pending", "dir"), ("session", "file"))' ', ("names", "dir"), ("session", "file"))'
prove "the session token is not a state path" t_session_token $S ', ("names", "dir"), ("pending", "dir"), ("session", "file"))' ', ("names", "dir"), ("pending", "dir"))'
prove "R3: an index is opened through a symlink" t_index_files $S $'        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)\n    except FileNotFoundError:' $'        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)\n    except FileNotFoundError:'
prove "R3: an index FIFO is waited on" t_index_files $S $'        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)\n    except FileNotFoundError:' $'        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)\n    except FileNotFoundError:'
prove "R3: an index's node type and owner are not checked" t_index_files $S $'    problem = node_problem(path, os.fstat(fd), "file")\n    if problem:\n        os.close(fd)\n        die(9, problem)' $'    problem = node_problem(path, os.fstat(fd), "file")\n    if False:\n        os.close(fd)\n        die(9, problem)'
prove "R3: index-last prints the first job id" t_index_files $S '    print(ids[-1])' '    print(ids[0])'
prove "R3: a line that is not a job id is skipped" t_index_files $S '            die(9, "%s holds a line that is not a job id: %r" % (path, line))' '            continue'
prove "R3: an index line that starts with a dash is read" t_index_files $S 'if not JOB_ID.fullmatch(line) or line.startswith("-"):' 'if not JOB_ID.fullmatch(line):'
prove "R3: run and status read an index whose last line starts with a dash" t_state_paths $S 'if not JOB_ID.fullmatch(line) or line.startswith("-"):' 'if not JOB_ID.fullmatch(line):'
prove "R1: a failed row whose database cannot be read is taken as having no restart pending" t_verdict_cli $S 'found = query_ro(db, "SELECT policy_state_json FROM jobs WHERE job_id = ?", (job,))' $'found = []\n            try:\n                found = query_ro(db, "SELECT policy_state_json FROM jobs WHERE job_id = ?", (job,))\n            except SystemExit:\n                pass'
prove "R3: index-has reads one file only" t_index_files $S '        names = [only] if only else sorted(os.listdir(directory))' '        names = [only] if only else sorted(os.listdir(directory))[:1]'
prove "R3: index-has ignores the id" t_index_files $S '        names = [only] if only else sorted(os.listdir(directory))' '        names = sorted(os.listdir(directory))'
prove "R3: index-last takes a path for an id" t_index_files $S '    if args[1] in ("", ".", "..") or "/" in args[1]:' '    if False:'
prove "R3: index-has takes a path for an id" t_index_files $S ' or (len(args) == 3 and (args[2] in ("", ".", "..") or "/" in args[2])):' ':'
prove "R11a: pending-write accepts --policy and the other flags velo-task never sends" t_pending_write $S 'START_FLAGS = {"--name": "name", "--timeout": "timeout", "--idempotency-key": "key", "--cwd": "cwd"}' 'START_FLAGS = {"--name": "name", "--timeout": "timeout", "--idempotency-key": "key", "--cwd": "cwd", "--policy": "policy", "--env": "env", "--secret-env": "secret", "--trigger": "trigger", "--wake-me": "wake", "--notes": "notes", "--priority": "priority"}'
prove "R3: the pending record is not compact" t_pending_write $S 'sort_keys=True, separators=(",", ":")) + "\n").encode()' 'sort_keys=True) + "\n").encode()'
prove "R17: pending-write writes through a symlinked directory" t_pending_write $S '    os.close(open_dir_nofollow(directory))  # a symlink in place of the directory, or one that is not yours, is refused (exit 9)' '    pass'
prove "R17: the pending record is world-readable" t_pending_write $S 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)' 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666)'
prove "R17: every pending record has the same nonce" t_pending_write $S '    nonce = os.urandom(8).hex()' '    nonce = "0000000000000000"'
prove "R3: a pending record needs no cwd" t_pending_write $S '("argv", "cwd", "key", "name", "timeout") if not settings[name]]' '("argv", "key", "name", "timeout") if not settings[name]]'
prove "R3: a pending record needs no key" t_pending_write $S '("argv", "cwd", "key", "name", "timeout") if not settings[name]]' '("argv", "cwd", "name", "timeout") if not settings[name]]'
prove "R3: a pending record needs no command" t_pending_write $S '("argv", "cwd", "key", "name", "timeout") if not settings[name]]' '("cwd", "key", "name", "timeout") if not settings[name]]'
prove "R17: remove does not fsync the directory" t_remove $S $'    os.unlink(path)\n    _sync_path(os.path.dirname(path), "dir")\n    return 0' $'    os.unlink(path)\n    return 0'
prove "R17: remove follows a symlink" t_remove $S $'        problem = node_problem(path, os.lstat(path), "file")\n    except FileNotFoundError:\n        return 0  # a step of run' $'        problem = node_problem(path, os.stat(path), "file")\n    except FileNotFoundError:\n        return 0  # a step of run'
prove "R17: remove of a file that is gone is an error" t_remove $S '        return 0  # a step of run that reconcile may already have done' '        return 1  # a step of run that reconcile may already have done'
prove "R21: VELO_TASK_RERUN_NONCE alone does not count as a seam" t_seam_nonce $L 'for v in VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_FSYNC_TRACE VELO_TASK_UV VELO_TASK_RERUN_NONCE; do' 'for v in VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_FSYNC_TRACE VELO_TASK_UV; do'
prove "R21: VELO_TASK_RERUN_NONCE is not refused without the capability" t_seam_nonce $L '    if [ -n "${VELO_TASK_RERUN_NONCE:-}" ]; then die 2 "VELO_TASK_RERUN_NONCE is set but refused: it is honoured only for tests ($why)"; fi' '    :'
prove "the dispatcher runs a library function by name" t_not_subcommands $V $'  _*) die 2 "unknown subcommand \'$sub\'" ;;' $'  _*) die 2 "unknown subcommand \'$sub\'" ;;\n  cmd_*|need_daemon|check_arg|rerun_nonce|start_refused|reconcile_id) "$sub" "$@" ;;'

# sessions: what an id may be, and the status arguments that name one (B11)
prove "B11: a session id may have 65 characters" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_-]{0,64}$'
prove "B11: a session id is at most 63 characters" t_run_limits $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$'
prove "B11: a session id may start with a dash or an underscore" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9_-][A-Za-z0-9_-]{0,63}$'
prove "B11: a session id may have dots and colons" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$'
prove "B11: a session id may have a slash" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_/-]{0,63}$'
prove "B11: a session id may have a space" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_ -]{0,63}$'
prove "B11: the session id pattern is anchored at the start only" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}'
prove "B11: the session id pattern is anchored at the end only" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
prove "B11: a session id may be empty" t_session_validation $L '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' '^([A-Za-z0-9][A-Za-z0-9_-]{0,63})?$'
prove "sessions: run checks CLAUDE_SESSION_ID only after it has touched the daemon" t_session_validation $L '  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"  # refused now, before the daemon is touched' '  :'
prove "sessions: status does not check CLAUDE_SESSION_ID" t_session_validation $L '  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"  # as in run: refused whether or not this status uses it' '  :'
prove "sessions: status does not check --session" t_session_validation $L '  [ "$have_session" = 0 ] || [ "$session" = me ] || check_arg session "$session"' '  :'
prove "sessions: an empty --session is no filter" t_session_validation $L '  [ "$have_session" = 0 ] || [ "$session" = me ] || check_arg session "$session"' '  [ -z "$session" ] || [ "$session" = me ] || check_arg session "$session"'
prove "sessions: an empty id or --job is no argument at all" t_session_validation $L $'  elif [ "$have_id" = 1 ]; then check_arg id "$id"\n  elif [ "$have_job" = 1 ]; then check_arg job "$job"; fi' $'  elif [ -n "$id" ]; then check_arg id "$id"\n  elif [ -n "$job" ]; then check_arg job "$job"; fi'
prove "sessions: --session and --all are taken together" t_session_validation $L '  [ "$all$have_session" != 11 ] || die 2 "--session and --all exclude each other"' '  :'
prove "sessions: --all is taken with an id" t_session_validation $L '  [ "$all" = 0 ] || [ "$have_id$have_job" = 00 ] || die 2 "--all lists the jobs of every session: it takes no id and no --job"' '  :'
prove "sessions: an id and --job are taken together" t_session_validation $L '  if [ "$have_id$have_job" = 11 ]; then die 2 "usage:' '  if false; then die 2 "usage:'

# sessions: where the session comes from, and the token (B-S1)
prove "sessions: CLAUDE_SESSION_ID is ignored" t_session_key $L '  [ "$s" != me ] || s="${CLAUDE_SESSION_ID:-}"' '  [ "$s" != me ] || s=""'
prove "sessions: me is a session id like any other" t_status_list $L '  [ "$s" != me ] || s="${CLAUDE_SESSION_ID:-}"' '  [ "$s" != never ] || s="${CLAUDE_SESSION_ID:-}"'
prove "sessions: the token is used even when CLAUDE_SESSION_ID is set" t_session_token $L '  [ -n "$s" ] || s=$(st session-token "$SESSION_FILE") ||' '  s=$(st session-token "$SESSION_FILE") ||'
prove "sessions: a token that cannot be read becomes a constant session" t_session_token $L ' || die 6 "the session token is unsafe or unreadable (see above)"' ' || s=constant'
prove "sessions: a token that cannot be read is exit 1" t_session_token $L 'die 6 "the session token is unsafe or unreadable (see above)"' 'die 1 "the session token is unsafe or unreadable (see above)"'
prove "sessions: the id of the token is not checked" t_session_token $L $'  check_arg session "$s"; printf \'%s\' "$s"' $'  printf \'%s\' "$s"'
prove "sessions: the token file is elsewhere" t_session_token $L 'SESSION_FILE="$VELO_TASK_HOME/session"' 'SESSION_FILE="$VELO_TASK_HOME/session.tok"'
prove "sessions: a failure to get the session is swallowed" t_session_token $L '  session=$(session_id) || exit "$?"' '  session=$(session_id) || true'
prove "sessions: the token is rewritten on every call" t_session_token_file $S '    write_new(path, (os.urandom(8).hex() + "\n").encode())  # False when the token exists already, the normal case' '    open(path, "wb").write((os.urandom(8).hex() + "\n").encode())'
prove "sessions: the token is read through a symlink" t_session_token_file $S '    ids = read_index(path)  # the safe reader of a one-line control file: not a symlink, not a FIFO, yours' '    ids = open(path).read().split()'
prove "sessions: an empty token file is accepted" t_session_token_file $S $'    if not ids:\n        die(9, "%s holds no token" % path)' $'    if not ids:\n        ids = ["empty"]'
prove "sessions: the token is world-readable" t_session_token_file $S '    write_new(path, (os.urandom(8).hex() + "\n").encode())  # False when the token exists already, the normal case' $'    write_new(path, (os.urandom(8).hex() + "\\n").encode())\n    os.chmod(path, 0o644)'
prove "sessions: session-token is not a helper command" t_session_token_file $S ' "session-token": cmd_session_token,' ''
prove "sessions: session-token takes no file" t_session_token_file $S $'    if len(args) != 1:\n        usage("session-token: expected <file>")' $'    if False:\n        usage("session-token: expected <file>")'

# sessions: run (B-S1)
prove "B-S1: the idempotency key has no session component" t_session_separation $L '    key="velo_${s8}_$id"' '    key="velo_$id"'
prove "B-S1: the idempotency key has no session component, and it shows in the key" t_session_key $L '    key="velo_${s8}_$id"' '    key="velo_$id"'
prove "B-S1: the idempotency key carries the session id, not its digest" t_session_key $L '    key="velo_${s8}_$id"' '    key="velo_${session}_$id"'
prove "B-S1: the digest of the session id is taken with a newline" t_session_key $L $'s8=$(printf \'%s\' "$session" | st sha256)' $'s8=$(printf \'%s\\n\' "$session" | st sha256)'
prove "B-S1: the key has the last 8 digits of the digest" t_session_key $L 's8="${s8:0:8}"' 's8="${s8: -8}"'
prove "B-S1: the key has 7 digits of the digest" t_session_key $L 's8="${s8:0:8}"' 's8="${s8:0:7}"'
prove "B-S1: the key has 9 digits of the digest" t_session_key $L 's8="${s8:0:8}"' 's8="${s8:0:9}"'
prove "B-S1: the key has the whole digest, and the longest key is more than Vanth accepts" t_run_limits $L 's8="${s8:0:8}"' 's8="${s8:0:64}"'
prove "B-S1: sessions are not told apart" t_session_separation $L '  session=$(session_id) || exit "$?"' '  session=constant'
prove "B-S1: the session tag is not sent" t_session_key $L '--tag velo --tag "session:$session")' '--tag velo)'
prove "B-S1: the session tag is the digest, not the id" t_session_key $L '--tag velo --tag "session:$session")' '--tag velo --tag "session:$s8")'

# sessions: status, one job (B-S1) and a list
prove "B-S1: status <id> ignores the session filter" t_status_session_filter $L '  if [ "$have_session" = 1 ]; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi  # any owner unless asked' '  :'
prove "B-S1: a list ignores the session" t_status_list $L '    if [ "$all" = 0 ]; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi' '    :'
prove "sessions: --all lists the caller's session only" t_status_list $L '    if [ "$all" = 0 ]; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi' '    if true; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi'
prove "sessions: a list ignores --issue" t_status_list $L '    if [ "$have_issue" = 1 ]; then vargs=("${vargs[@]}" --issue "$issue"); fi' '    :'
prove "sessions: a list ignores --json" t_status_list $L '    if [ "$json" = 1 ]; then vargs=("${vargs[@]}" --json); fi' '    :'
prove "R8: a list needs the daemon" t_status_list_offline $L '    [ -e "$VH/jobs.sqlite" ] || return 0  # nothing has ever run here' '    need_daemon; [ -e "$VH/jobs.sqlite" ] || return 0'
prove "R8: a list needs the daemon, also when nothing has run" t_status_list_empty $L '    [ -e "$VH/jobs.sqlite" ] || return 0  # nothing has ever run here' '    need_daemon; [ -e "$VH/jobs.sqlite" ] || return 0'
prove "sessions: a list with no database is an error" t_status_list_empty $L '    [ -e "$VH/jobs.sqlite" ] || return 0  # nothing has ever run here' '    [ -e "$VH/jobs.sqlite" ] || die 1 "no database"'
prove "sessions: a list makes the token before it knows there is anything to list" t_status_list_empty $L $'    [ -e "$VH/jobs.sqlite" ] || return 0  # nothing has ever run here\n' $'    session=$(session_id "$session") || exit "$?"\n    [ -e "$VH/jobs.sqlite" ] || return 0\n'
prove "R8: a list does not check the state it reads" t_status_list_offline $L '    why=$(stl check-state --owner-only "$VELO_TASK_HOME") || die 6 "state: ${why:-the state check failed}; nothing was read"' '    :'
prove "sessions: verdict-of --session does not check the tag of a job" t_status_session_filter $S '        for key in ("issue", "session"):' '        for key in ("issue",):'
prove "B-S1: a list ignores the session tag" t_status_list $S 'for key in ("session", "issue") if key in opts]' 'for key in ("issue",) if key in opts]'
prove "sessions: a list ignores the issue tag" t_status_list $S 'for key in ("session", "issue") if key in opts]' 'for key in ("session",) if key in opts]'
prove "sessions: a list is oldest first" t_status_list $S 'FROM jobs ORDER BY created_at DESC, job_id DESC"' 'FROM jobs ORDER BY created_at ASC, job_id DESC"'
prove "sessions: a list matches a tag by prefix" t_status_list $S 'if all(tag in (tags if isinstance(tags, list) else ()) for tag in want):' 'if all(any(str(t).startswith(tag) for t in (tags if isinstance(tags, list) else ())) for tag in want):'
prove "sessions: tags that are a JSON string are read as a list" t_status_list_rows $S 'if all(tag in (tags if isinstance(tags, list) else ()) for tag in want):' 'if all(tag in (tags or ()) for tag in want):'
prove "sessions: tags that are not JSON fail the list" t_status_list_rows $S $'        except ValueError:  # tags that are not JSON: the job belongs to no session\n            tags = None' $'        except ValueError:\n            raise'
prove "sessions: a list leaves out the policy state, so a restart pending is not seen" t_status_list_rows $S 'stop_reason, trigger_json, policy_state_json, tags_json "' 'stop_reason, trigger_json, tags_json "'
prove "sessions: a list leaves out the trigger, so a trigger parent is not seen" t_status_list_rows $S 'stop_reason, trigger_json, policy_state_json, tags_json "' 'stop_reason, policy_state_json, tags_json "'
prove "sessions: a list never knows a trigger parent" t_status_list_rows $S 'return list_jobs(db, known, opts, "--json" in flags)' 'return list_jobs(db, lambda parent: False, opts, "--json" in flags)'
prove "sessions: a name is never quoted" t_status_list_rows $S 'return text if re.fullmatch(r"[\x21\x23-\x7e]+", text) else json.dumps(text)' 'return text'
prove "sessions: a name may hold a space" t_status_list_rows $S 'return text if re.fullmatch(r"[\x21\x23-\x7e]+", text) else json.dumps(text)' 'return text if re.fullmatch(r"[\x20-\x7e]+", text) else json.dumps(text)'
prove "sessions: a name may start with a double quote" t_status_list_rows $S 'return text if re.fullmatch(r"[\x21\x23-\x7e]+", text) else json.dumps(text)' 'return text if re.fullmatch(r"[\x21-\x7e]+", text) else json.dumps(text)'
prove "sessions: a missing name is an empty string" t_status_list_rows $S '_tok(row["name"] or "-")' '_tok(row["name"] or "")'
prove "sessions: a list prints text for --json" t_status_list $S 'print(job_json(row["name"], row, verdict) if as_json else' 'print(job_json(row["name"], row, verdict) if False else'
prove "sessions: --list is not an option of verdict-of" t_status_list $S 'if args[i] in ("--json", "--absent", "--list"):' 'if args[i] in ("--json", "--absent"):'
prove "sessions: verdict-of --list prints nothing" t_status_list $S 'return list_jobs(db, known, opts, "--json" in flags)' 'return 0'
prove "R8: the tags column is not part of the schema Vanth must have" t_status_list_offline $S '"trigger_json", "created_at", "ended_at", "policy_state_json", "tags_json"),' '"trigger_json", "created_at", "ended_at", "policy_state_json"),'

# B14: every new function is swept
prove "the dispatcher runs session_id by name" t_not_subcommands $V $'  _*) die 2 "unknown subcommand \'$sub\'" ;;' $'  _*) die 2 "unknown subcommand \'$sub\'" ;;\n  session_id) "$sub" "$@" ;;'
prove "B14: bash 4 in session_id" t_b14_new $L $'  [ "$s" != me ] || s="${CLAUDE_SESSION_ID:-}"' $'  declare -A seeded\n  [ "$s" != me ] || s="${CLAUDE_SESSION_ID:-}"'
prove "B14: bash 4 in the dispatcher's run and status arm" t_b14_new $V '  run|status) "cmd_$sub" "$@" ;;' '  run|status) mapfile -t seeded < /dev/null; "cmd_$sub" "$@" ;;'
prove "B14: bash 4 in need_daemon" t_b14_new $L $'  (cmd_ensure_daemon >/dev/null) || rc=$?' $'  declare -A seeded\n  (cmd_ensure_daemon >/dev/null) || rc=$?'
prove "B14: bash 4 in check_arg" t_b14_new $L $'  [[ "$2" =~ $re ]] || die 2' $'  declare -A seeded\n  [[ "$2" =~ $re ]] || die 2'
prove "B14: bash 4 in rerun_nonce" t_b14_new $L '  IFS=, read -r -a parts <<<"$VELO_TASK_RERUN_NONCE"' $'  declare -A seeded\n  IFS=, read -r -a parts <<<"$VELO_TASK_RERUN_NONCE"'
prove "B14: bash 4 in start_refused" t_b14_new $L $'  case "$2" in\n' $'  declare -A seeded\n  case "$2" in\n'
prove "B14: bash 4 in reconcile_id" t_b14_new $L $'  local rc=0\n  st reconcile' $'  declare -A seeded\n  local rc=0\n  st reconcile'
prove "B14: bash 4 in cmd_run" t_b14_new $L $'cmd_run() {\n' $'cmd_run() {\n  declare -A seeded\n'
prove "B14: bash 4 in cmd_status" t_b14_new $L $'cmd_status() {\n' $'cmd_status() {\n  declare -A seeded\n'

# isolation: the same comparison against a stand-in home that is then disturbed (M1's stray_* functions)
prove_env "a velo-task directory appears under the real home" stray_velo_task_dir
prove_env "a vanth directory appears under the real home" stray_vanth_dir
prove_env "~/.agents/state is modified" stray_state_touch
prove_env "~/.config is modified" stray_config_touch
prove_env "~/.claude.json gains a vanth entry" stray_mcp_entry
prove_env "the suite runs with the real HOME" stray_real_home_env
prove_env "the suite runs with Homebrew on PATH" stray_homebrew_path
proof_drain   # every proof reported before anything else runs: the checks below reap the whole suite tree

if [ "${VELO_TASK_NETWORK_TESTS:-}" = 1 ]; then
  echo "velo-task M2a: network (the real Vanth from PyPI: its tags and the list order)"
  check "R3 R8: the real vanth emits the session tag in --json status, the filter accepts and refuses on it, and a list is created_at DESC, job_id DESC" t_vanth_tags_real
else
  echo "  (real-Vanth tags test skipped: set VELO_TASK_NETWORK_TESTS=1)"
fi
echo "velo-task M2a: isolation"
check "the real home is untouched: HOME was a temp dir and PATH the system directories throughout" t_real_home_untouched
check "control: the same comparison passes against an undisturbed stand-in home" t_stand_in_untouched
echo
[ $FAILED -eq 0 ] && echo "all velo-task M2a checks passed" || echo "FAILURES"
exit $FAILED

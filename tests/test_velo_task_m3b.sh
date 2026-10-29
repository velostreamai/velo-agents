#!/bin/bash
# velo-task M3b (docs/velo-task-spec.md R8, R9; scope decision on velo-agents#7): the session-scoped Stop guard,
# `velo-task ack`, `velo-task stop-override` and the SessionStart hook.
# Bars: B16 (every case of the guard, the fail-closed ones included, and no release after N blocks), B24, B32 (a running job
# blocks; an acked row that runs again blocks again), B33 (each of the six in-flight statuses blocks), B-S2 (two sessions:
# A's guard blocks on A's job only and allows once A is done although B runs; A cannot ack B's lost job without
# --any-session), and the ack/override cases the brief names (in flight refused, idempotent, audited, one shot).
#
# The harness, the fake Vanth and the mutation-proof machinery are M1's (test_velo_task_foundation.sh is sourced with
# VELO_TASK_HARNESS_ONLY=1). The rows are tests/fixtures/velo-task/fake-vanth-jobs.py's, injected through `__inject`: no
# daemon and no venv, because nothing here asks one -- ack, stop-override and both hooks read the database with the system
# python, which is the point of R8's "never the daemon".
#
# Hooks run as Claude Code runs them: the Stop payload on stdin, exit 2 = block, exit 0 = allow.
#
# Every check is also proved RED on a mutated COPY of the code under test (`prove`, as in M1): a mutation whose anchor is not
# found exactly once is a failed proof, never a skip. VELO_TASK_ONLY="t_a t_b" runs just those checks and their proofs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELO_TASK_HARNESS_ONLY=1 . "$HERE/test_velo_task_foundation.sh"
V=bin/velo-task; L=bin/velo-task-lib.sh; S=bin/velo-task-state; HD=hooks/velo-task-stop-guard.sh; HS=hooks/velo-task-session-start.sh
. "$HERE/bash32-sweep.sh"   # the sweep t_hook_files applies to the two hooks, as test_velo_task_hooks.sh does

# ---- fixtures ----------------------------------------------------------------------------------------
mkstate() {  # an isolated state dir, a HOME of its own and the SQLite fake Vanth; no daemon, no venv: rows are injected
  mkhome
  export HOME="$E/home-home"; mkdir -p -m 700 "$HOME"   # a hook that fell back to the default state dir must not reach the real one
  mkdir -p "$E/bin" "$E_VH"
  render fake-vanth-jobs.py "$E/bin/vanth"
}
fv() { VANTH_HOME="$E_VH" "$E/bin/vanth" "$@"; }   # the fake CLI itself, to inject a row: its stdout is the job_id
inj() {  # <json row>: one row as given; sets JOB
  JOB=$(fv __inject "$1") || { echo "FAILED: could not inject a row"; return 1; }
}
srow() {  # <session> <name> <status> [extra JSON fields, with the leading comma]: a row tagged velo + session:<session>; sets JOB
  inj "{\"name\":\"$2\",\"status\":\"$3\",\"command\":\"x\",\"tags_json\":[\"velo\",\"session:$1\"]${4:-}}"
}
dbx() { "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit()' "$E_VH/jobs.sqlite" "$1"; }
vt() {  # <session> <velo-task args...>: velo-task under that session; sets OUT and RC
  local s="$1"; shift
  OUT=$(CLAUDE_SESSION_ID="$s" "$R/bin/velo-task" "$@" </dev/null 2>&1); RC=$?
}
hook() {  # <hook path> <session> [payload]: the hook as Claude Code runs it; sets OUT and RC
  local h="$1" s="$2" p="${3:-{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false\}}"
  OUT=$(printf '%s\n' "$p" | CLAUDE_SESSION_ID="$s" "$h" 2>&1); RC=$?
}
guard() { hook "$R/$HD" "$@"; }
sstart() { hook "$R/$HS" "$@"; }

# ---- ack (R9) ----------------------------------------------------------------------------------------
t_ack_marker() {  # ack publishes <state>/acks/<job_id>, and a second ack changes nothing
  mkstate
  srow A j-gate orphaned; local j="$JOB"
  vt A ack "$j"
  need "a lost job of this session is acked (exit 0)" [ "$RC" = 0 ]
  need "the marker is published at acks/<job_id>" [ -f "$E_HOME/acks/$j" ]
  need "it records the session and what it closed" grep -q -e '^session=A$' -e '^verdict=lost$' "$E_HOME/acks/$j"
  need "no temporary file is left beside it" [ "$(/bin/ls -A "$E_HOME/acks" | /usr/bin/grep -v -x "$j")" = "" ]
  local before after
  before=$(/usr/bin/stat -f '%m %z' "$E_HOME/acks/$j")
  vt A ack "$j"
  after=$(/usr/bin/stat -f '%m %z' "$E_HOME/acks/$j")
  need "a second ack exits 0" [ "$RC" = 0 ]
  need "...saying it was already acked" grep -q 'acked (already' <<<"$OUT"
  need "...and does not rewrite the marker" [ "$before" = "$after" ]
  dbx "DELETE FROM jobs WHERE job_id = '$j'"
  vt A ack "$j"
  need "an ack whose row has since gone is still a no-op: the marker is the record (R9)" [ "$RC" = 0 ]
}
t_ack_refuse() {  # a job in flight, and another session's job, are refused with exit 2 (B-S2's ack half)
  mkstate
  srow A j-run running; local jr="$JOB"
  srow B j-lost orphaned; local jb="$JOB"
  inj '{"name":"j-out","status":"orphaned","command":"x"}'; local jo="$JOB"
  vt A ack "$jr"
  need "a job in flight is refused (exit 2)" [ "$RC" = 2 ]
  need "...and nothing is published" [ ! -e "$E_HOME/acks/$jr" ]
  need "...saying ack closes a stopped job" grep -q 'ack closes a stopped job' <<<"$OUT"
  vt A ack "$jb"
  need "another session's job is refused (exit 2)" [ "$RC" = 2 ]
  need "...and nothing is published" [ ! -e "$E_HOME/acks/$jb" ]
  need "...naming the session that owns it" grep -q 'belongs to another session (B)' <<<"$OUT"
  vt A ack "$jb" --any-session
  need "with --any-session it is published" [ "$RC" = 0 -a -f "$E_HOME/acks/$jb" ]
  vt A ack "$jo"
  need "a job no session tags is nobody's, so it needs no --any-session" [ "$RC" = 0 ]
  need "...and is published" [ -f "$E_HOME/acks/$jo" ]
}
t_ack_edge() {  # a job that is not a row, a bad id, tags that are not JSON, and a marker path that is a symlink
  mkstate
  srow A j-seed orphaned   # the database is there, so "no such row" is the answer, not "no database"
  vt A ack job_nope
  need "a job that is not a row of the database is an error (exit 1), never a marker" [ "$RC" = 1 ]
  need "...and says so" grep -q 'is not a row of' <<<"$OUT"
  vt A ack 'job/bad'
  need "a job_id that is not one is refused (exit 2)" [ "$RC" = 2 ]
  vt A ack
  need "ack with no job_id is usage (exit 2)" [ "$RC" = 2 ]
  srow A j-one orphaned; local j="$JOB"
  vt A ack "$j" job_other
  need "ack takes one job_id (exit 2)" [ "$RC" = 2 ]
  srow A j-bad orphaned; local jbad="$JOB"
  dbx "UPDATE jobs SET tags_json = '{not json' WHERE job_id = '$jbad'"
  vt A ack "$jbad"
  need "tags that are not JSON are not read as 'belongs to no session' (exit 6)" [ "$RC" = 6 ]
  need "...and nothing is published for it" [ ! -e "$E_HOME/acks/$jbad" ]
  srow A j-sym orphaned; local js="$JOB"
  mkdir -p "$E_HOME/acks"; printf 'untouched\n' > "$E/victim"
  /bin/ln -s "$E/victim" "$E_HOME/acks/$js"
  vt A ack "$js"
  need "a marker path that is a symlink is an ack that writes nothing (exit 0)" [ "$RC" = 0 ]
  need "...and the file it points at is untouched" [ "$(/bin/cat "$E/victim")" = untouched ]
}
# ---- stop-override (R8) ------------------------------------------------------------------------------
t_override() {  # the audited line, the one-shot marker, and the reasons it refuses
  mkstate
  vt A stop-override --reason "wrapping up the review"
  need "an override is logged (exit 0)" [ "$RC" = 0 ]
  need "one line in overrides.log" [ "$(/usr/bin/wc -l < "$E_HOME/overrides.log" | tr -d ' ')" = 1 ]
  need "it carries the time, the session, the uid and the reason" \
    /usr/bin/grep -q -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z session=A uid=[0-9]+ reason=wrapping up the review$' "$E_HOME/overrides.log"
  need "the one-shot marker is published for the session" [ -f "$E_HOME/override/A" ]
  vt A stop-override --reason "a second reason"
  need "a second override leaves two log lines" [ "$(/usr/bin/wc -l < "$E_HOME/overrides.log" | tr -d ' ')" = 2 ]
  need "...and one marker only: a session cannot bank two (R8)" [ "$(/bin/ls -A "$E_HOME/override" | /usr/bin/wc -l | tr -d ' ')" = 1 ]
  vt A stop-override
  need "an override with no reason is usage (exit 2)" [ "$RC" = 2 ]
  vt A stop-override --reason "$(/usr/bin/printf 'two\nlines')"
  need "a reason that is two lines is refused (exit 2)" [ "$RC" = 2 ]
  need "...and is not logged" [ "$(/usr/bin/wc -l < "$E_HOME/overrides.log" | tr -d ' ')" = 2 ]
}
# ---- the Stop guard (R8, B16, B32, B33, B-S2) ---------------------------------------------------------
t_guard_blocks() {  # B32: a running job blocks though nothing went wrong; a lost row blocks until acked; the rest never
  mkstate
  srow A j-run running; local jr="$JOB"
  guard A
  need "a running job of this session blocks the stop (B32)" [ "$RC" = 2 ]
  need "it prints the wait command for it" grep -q 'velo-task wait j-run' <<<"$OUT"
  need "it never asks for an ack of a row ack refuses" not grep -q "velo-task ack $jr" <<<"$OUT"
  need "it prints the way out" grep -q 'velo-task stop-override --reason' <<<"$OUT"
  dbx "UPDATE jobs SET status = 'completed', exit_code = 0 WHERE job_id = '$jr'"
  guard A
  need "once the running job is done the session may stop" [ "$RC" = 0 ]
  need "...and the guard says nothing" [ "$OUT" = "" ]
  srow A j-lost orphaned; local jl="$JOB"
  guard A
  need "a lost row blocks too" [ "$RC" = 2 ]
  need "with the ack command, by job_id" grep -q "velo-task ack $jl" <<<"$OUT"
  need "...and not a wait for a row that will never finish" not grep -q 'velo-task wait j-lost' <<<"$OUT"
  vt A ack "$jl"
  need "the ack is published" [ "$RC" = 0 ]
  guard A
  need "a lost row that is acked no longer blocks" [ "$RC" = 0 ]
  need "...and the guard says nothing again" [ "$OUT" = "" ]
  # every finished verdict, one at a time: none of them blocks (upstream-failed needs a trigger parent the name index knows)
  mkdir -p "$E_HOME/names"; printf 'j-parent\n' > "$E_HOME/names/j-parent"
  srow A j-failed failed ',"exit_code":2'
  srow A j-timeout timeout
  srow A j-killed cancelled ',"stop_actor":"user","stop_reason":"stop requested"'
  srow A j-upstream cancelled ',"stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger_json":{"job_id":"j-parent","status":"completed"}'
  guard A
  need "failed, timeout, killed and upstream-failed never block" [ "$RC" = 0 ]
  need "...and the guard still says nothing" [ "$OUT" = "" ]
}
t_guard_six() {  # B33: each of the six in-flight statuses blocks, and each is reported as in flight
  mkstate
  local st
  for st in queued launching running paused retrying stopping; do
    srow A "j-$st" "$st"
    guard A
    need "a job $st is in flight, so it blocks (B33)" [ "$RC" = 2 ]
    need "...and is reported as in flight" grep -q -E "^  j-$st [^ ]+: in-flight" <<<"$OUT"
  done
}
t_guard_again() {  # B32: an acked row that runs again blocks again
  mkstate
  srow A j-back orphaned; local j="$JOB"
  vt A ack "$j"
  need "the lost row is acked" [ "$RC" = 0 ]
  guard A
  need "an acked lost row does not block" [ "$RC" = 0 ]
  dbx "UPDATE jobs SET status = 'running', ended_at = NULL WHERE job_id = '$j'"
  guard A
  need "the same row running again blocks again, whatever its marker says (B32)" [ "$RC" = 2 ]
}
t_guard_two() {  # B-S2: two sessions, and the payload never names the session
  mkstate
  srow A j-a running; local ja="$JOB"
  srow B j-b running
  inj '{"name":"j-out","status":"running","command":"x"}'
  guard A '{"hook_event_name":"Stop","session_id":"B"}'
  need "A's guard blocks on A's own job (B-S2)" [ "$RC" = 2 ]
  need "...and never on B's, whatever the payload calls the session" not grep -q 'j-b' <<<"$OUT"
  need "...and never on a job no session tags" not grep -q 'j-out' <<<"$OUT"
  guard B
  need "B's guard blocks on B's own job" [ "$RC" = 2 ]
  need "...and never on A's" not grep -q 'j-a' <<<"$OUT"
  dbx "UPDATE jobs SET status = 'completed', exit_code = 0 WHERE job_id = '$ja'"
  guard A
  need "A's guard allows once A has nothing left, although B still runs (B-S2)" [ "$RC" = 0 ]
  need "...and says nothing about B" [ "$OUT" = "" ]
}
t_guard_failclosed() {  # B16: every unreadable state blocks and prints the way out; no state at all allows
  mkstate
  local keep="$VELO_TASK_HOME" holder
  export VELO_TASK_HOME="$E/nowhere"
  guard A
  need "no state directory at all allows the stop (R8)" [ "$RC" = 0 ]
  need "...silently" [ "$OUT" = "" ]
  export VELO_TASK_HOME="$keep"
  mkdir -p "$E_HOME/names"; printf 'j-gate\n' > "$E_HOME/names/gate-1"
  guard A
  need "a database missing while the name index has a job blocks (R8)" [ "$RC" = 2 ]
  need "...saying what is missing" grep -q 'jobs.sqlite is missing' <<<"$OUT"
  need "...and printing the way out" grep -q 'velo-task stop-override --reason' <<<"$OUT"
  /bin/rm -rf "$E_HOME/names"
  guard A
  need "a state directory with nothing in it has nothing to block" [ "$RC" = 0 ]
  /bin/rm -f "$E_VH/jobs.sqlite"
  mkdb "$E_VH/jobs.sqlite" tags_json   # a schema missing a column this state helper pins
  guard A
  need "a schema that is not this one blocks (R8)" [ "$RC" = 2 ]
  need "...and the message names the mismatch" grep -q 'schema mismatch' <<<"$OUT"
  /bin/rm -f "$E_VH/jobs.sqlite"
  mkdb "$E_VH/jobs.sqlite"   # the real schema, rows of no session: nothing blocks again
  guard A
  need "back to a readable state, nothing blocks" [ "$RC" = 0 ]
  "$PYBIN" -I -c 'import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); c.execute("BEGIN EXCLUSIVE"); open(sys.argv[2], "w").write("locked"); time.sleep(8)' "$E_VH/jobs.sqlite" "$E/locked" &
  holder=$!
  waitfor 5 test -s "$E/locked"
  guard A
  need "a database locked past its 2000 ms busy timeout blocks (R8)" [ "$RC" = 2 ]
  need "...saying it waited" grep -q 'waited 2000 ms' <<<"$OUT"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; /bin/rm -f "$E/locked"
  guard A
  need "the same database, unlocked, blocks on nothing" [ "$RC" = 0 ]
}
t_guard_noauto() {  # B16: nothing releases a block after N runs
  mkstate
  srow A j-stuck running
  local n
  for n in 1 2 3; do
    guard A
    need "run $n of the guard blocks (no release after N blocks, R8)" [ "$RC" = 2 ]
    need "...and still prints the job" grep -q 'j-stuck' <<<"$OUT"
  done
}
t_guard_override() {  # R8: stop-override lets this session end once, then the block is back
  mkstate
  srow A j-stuck running
  vt A stop-override --reason "handing this over to the next session"
  need "the override is logged" [ "$RC" = 0 ]
  guard A
  need "the run after an override allows the stop (R8)" [ "$RC" = 0 ]
  need "...and says the marker was spent" grep -q 'one-shot marker of this session is spent' <<<"$OUT"
  guard A
  need "the next run blocks again: the override is one shot" [ "$RC" = 2 ]
  mkdir -p "$E_HOME/names"; printf 'j-gate\n' > "$E_HOME/names/gate-1"
  /bin/rm -f "$E_HOME/override/A"
  guard A
  need "an unreadable state blocks" [ "$RC" = 2 ]
  vt A stop-override --reason "the database is gone and I need to end"
  guard A
  need "an override lets the session end through an unreadable state as well (R8)" [ "$RC" = 0 ]
}
t_hookupen() {  # the hooks fail open when their library is not installed beside them, as the registration line does
  mkstate
  srow A j-run running
  OUT=$(printf '{"hook_event_name":"Stop"}\n' | CLAUDE_SESSION_ID=A VELO_TASK_LIB="$E/no-such-lib.sh" "$R/$HD" 2>&1); RC=$?
  need "the Stop hook with no library lets the session stop (exit 0)" [ "$RC" = 0 ]
  OUT=$(printf '{"hook_event_name":"SessionStart"}\n' | CLAUDE_SESSION_ID=A VELO_TASK_LIB="$E/no-such-lib.sh" "$R/$HS" 2>&1); RC=$?
  need "the SessionStart hook with no library says nothing and exits 0" [ "$RC" = 0 ]
  need "...printing nothing" [ "$OUT" = "" ]
}
# ---- SessionStart (B24) ------------------------------------------------------------------------------
t_sstart() {  # B24: this session's work first, with the command that clears each, then one line on the others
  mkstate
  srow A j-run running
  srow A j-lost orphaned; local jl="$JOB"
  srow B j-b running
  sstart A
  need "SessionStart exits 0: it never blocks" [ "$RC" = 0 ]
  need "it lists the running job with its wait command (B24)" grep -q 'velo-task wait j-run' <<<"$OUT"
  need "it lists the unacked lost job with its ack command (B24)" grep -q "velo-task ack $jl" <<<"$OUT"
  need "the other sessions' line is the last line" [ "$(/usr/bin/printf '%s\n' "$OUT" | /usr/bin/tail -n 1)" = 'other sessions: 1 in flight' ]
  need "...and there is exactly one of them" [ "$(/usr/bin/printf '%s\n' "$OUT" | /usr/bin/grep -c '^other sessions:')" = 1 ]
  need "another session's job is never listed as this session's work" not grep -q 'j-b' <<<"$OUT"
  sstart B
  need "B's listing counts A's one in-flight job, not A's lost one" grep -q '^other sessions: 1 in flight$' <<<"$OUT"
  need "...and lists no job of A's" not grep -q 'j-run' <<<"$OUT"
}
t_sstart_quiet() {  # a session with nothing to do, and a state that cannot be read: both print, neither blocks
  mkstate
  sstart A
  need "a session with no jobs exits 0" [ "$RC" = 0 ]
  need "...saying it has nothing in flight or unacked" grep -q 'is in flight or lost unacked' <<<"$OUT"
  need "...and still gives the one line on the others" grep -q '^other sessions: 0 in flight$' <<<"$OUT"
  mkdir -p "$E_HOME/names"; printf 'j-gate\n' > "$E_HOME/names/gate-1"
  sstart A
  need "a state that cannot be read still exits 0 (SessionStart never blocks)" [ "$RC" = 0 ]
  need "...and says what it could not read" grep -q 'the job state cannot be read' <<<"$OUT"
  need "...and does not claim to know the others' count" grep -q '^other sessions: unknown in flight' <<<"$OUT"
}
t_hook_files() {  # both hooks are bash 3.2 scripts, executable, run only tools that are there, and are documented where the registration reads them from
  local f first p
  for f in "$R/$HD" "$R/$HS"; do
    [ -f "$f" ] || { echo "FAILED: $f is missing"; return 1; }
    first=$(/usr/bin/head -n 1 "$f")
    need "${f##*/} starts with #!/bin/bash" [ "$first" = '#!/bin/bash' ]
    need "${f##*/} is executable: a registered hook that is not is skipped without a word" [ -x "$f" ]
    need "${f##*/} parses under /bin/bash" /bin/bash -n "$f"
    bash4_hits "$f" >/dev/null
    need "${f##*/} uses no bash-4 construct" [ $? = 1 ]
    # every absolute tool the hook names must be there: a hook that calls /usr/bin/ls is silent, and a silent guard reads as "allow"
    for p in $(/usr/bin/grep -oE '/(usr/)?bin/[A-Za-z0-9._-]+' "$f" | /usr/bin/grep -v '\.sh$' | /usr/bin/sort -u); do
      need "${f##*/} runs $p, which is there and executable" [ -x "$p" ]
    done
  done
  need "the README documents the guarded Stop registration" /usr/bin/grep -q -F 'velo-task-stop-guard.sh\" ] || exit 0' "$R/README.md"
  need "the README documents the guarded SessionStart registration" /usr/bin/grep -q -F 'velo-task-session-start.sh\" ] || exit 0' "$R/README.md"
  need "install.sh needs no rule per hook: it ships every file in hooks/" /usr/bin/grep -q -F 'tooling_files "$SRC/hooks"' "$R/install.sh"
}

# ---- the checks --------------------------------------------------------------------------------------
echo "velo-task M3b: ack (R9)"
check "ack publishes the marker once, and a second ack changes nothing" t_ack_marker
check "ack refuses a job in flight, and another session's job without --any-session" t_ack_refuse
check "ack edges: not a row, a bad id, tags that are not JSON, a marker path that is a symlink" t_ack_edge
echo "velo-task M3b: stop-override (R8)"
check "stop-override audits the line, publishes one marker, refuses a missing or two-line reason" t_override
echo "velo-task M3b: the Stop guard (R8, R9)"
check "B32: a running job blocks, a lost row blocks until acked, the finished verdicts never block" t_guard_blocks
check "B33: each of the six in-flight statuses blocks" t_guard_six
check "B32: an acked row that runs again blocks again" t_guard_again
check "B-S2: A blocks on A's job only, allows once A is done, and the payload never names the session" t_guard_two
check "B16: every unreadable state blocks, no state at all allows" t_guard_failclosed
check "B16: no release after N blocks" t_guard_noauto
check "R8: stop-override lets the session end once" t_guard_override
check "the hooks fail open when their library is missing" t_hookupen
echo "velo-task M3b: SessionStart (R8, R9)"
check "B24: this session's work first with its commands, then one line on the others" t_sstart
check "SessionStart on a quiet session and an unreadable state: it prints, and never blocks" t_sstart_quiet
check "both hooks are executable bash 3.2 scripts, registered in the README, shipped by install.sh" t_hook_files
echo "velo-task M3b: mutation proofs (each check must go red on a mutated copy)"

# ack (R9)
prove "R9: an ack is not idempotent (it reads the row again and can fail)" t_ack_marker $L \
  '[ -e "$ACKS/$job" ] || [ -L "$ACKS/$job" ]; then printf' 'false; then printf'
prove "R9: an ack is published for a job in flight" t_ack_refuse $L \
  '[ "$verdict" != in-flight ] || die 2' 'true || die 2'
prove "B-S2: ack ignores the session tag" t_ack_refuse $L \
  'if [ "$any" = 0 ] && [ -n "$owners" ]; then' 'if false; then'
prove "R9: an ack is published for a job the database does not have" t_ack_edge $L \
  '3) die 1' '3) true'
prove "R9: tags that are not JSON are read as no session" t_ack_edge $S \
  '    except ValueError:  # surfaced, never read as "this job belongs to no session": that would let any session speak for it
        die(1, "job-info: the tags_json of %s is not JSON" % job_id)' \
  '    except ValueError:
        tags = None'
prove "R9: an ack writes the marker in place, through whatever is at the path" t_ack_edge $L \
  '[ -e "$ACKS/$job" ] || [ -L "$ACKS/$job" ]; then printf' 'false; then printf' $L \
  'stl publish "$ACKS/$job" "$tmp" || rc=$?' '/bin/cp "$tmp" "$ACKS/$job" || rc=$?'
# stop-override (R8)
prove "R8: an override is not audited" t_override $L \
  'stl append-line "$OVERRIDES" "$line" || die 1' 'true || die 1'
prove "R8: an override writes no marker" t_override $L \
  'stl publish "$OVERRIDE_DIR/$me" "$tmp" || rc=$?' 'true || rc=$?'
prove "R8: an override with no reason is accepted" t_override $L \
  '[ -n "$reason" ] || die 2' '[ -n "$reason" ] || true'
# the guard (R8, B16, B32, B33, B-S2)
prove "B32: a job in flight does not block" t_guard_blocks $L \
  '      in-flight) printf' '      in-flight) false && printf'
prove "B33: paused is not in flight" t_guard_six $S \
  'IN_FLIGHT = frozenset(("queued", "launching", "running", "paused", "retrying", "stopping"))' \
  'IN_FLIGHT = frozenset(("queued", "launching", "running", "retrying", "stopping"))'
prove "B32: the ack marker closes a running row too" t_guard_again $L \
  '      in-flight) printf' '      in-flight) [ -e "$ACKS/$job" ] || printf'
prove "B-S2: the guard ignores the session tag" t_guard_two $L \
  '--db "$VH/jobs.sqlite" --session "$1" 2>&1' '--db "$VH/jobs.sqlite" 2>&1'
prove "B16: a guard that cannot read the state allows" t_guard_failclosed $L \
  '    return 2
  fi
  return 0
}' '    return 0
  fi
  return 0
}'
prove "B16: no state directory blocks" t_guard_failclosed $L \
  '[ -d "$VELO_TASK_HOME" ] || return 0' '[ -d "$VELO_TASK_HOME" ] || return 2'
prove "B16: the guard releases after one block" t_guard_noauto $L \
  '    return 2
  fi
  return 0
}' '    [ -e "$VELO_TASK_HOME/.blocks" ] && return 0
    : > "$VELO_TASK_HOME/.blocks"
    return 2
  fi
  return 0
}'
prove "R8: an override is never spent" t_guard_override $L \
  '/bin/mv -f "$f" "$claimed" 2>/dev/null || return 1' 'return 0'
prove "R8: a hook with no library fails closed" t_hookupen $HD \
  '|| exit 90' '|| exit 2'
# SessionStart (B24)
prove "B24: SessionStart lists nothing" t_sstart $L \
  '    blocking_commands <<<"$blocking"' '    :'
prove "B24: SessionStart always counts no other session" t_sstart $L \
  'others=$(( $(count_inflight <<<"$all") - $(count_inflight <<<"$rows") ))' 'others=0'
prove "a SessionStart hook that exits non-zero" t_sstart_quiet $HS \
  '
exit 0' '
exit 2'
# the hook files themselves
prove "a hook that is not a bash script" t_hook_files $HD \
  '#!/bin/bash' '#!/bin/sh'
prove "a hook names a tool that is not on this machine" t_hook_files $HS \
  '/bin/cat >/dev/null' '/usr/bin/cat >/dev/null'
prove "the README drops the guarded Stop registration" t_hook_files 'README.md' \
  'velo-task-stop-guard.sh\" ] || exit 0; exec' 'velo-task-stop-guard.sh\"; exec'

# isolation: the same comparison against a stand-in home that is then disturbed (M1's stray_* functions)
prove_env "a velo-task directory appears under the real home" stray_velo_task_dir
prove_env "the suite runs with the real HOME" stray_real_home_env
proof_drain   # every proof reported before anything else runs: the checks below reap the whole suite tree

echo "velo-task M3b: isolation"
check "the real home is untouched: HOME was a temp dir throughout" t_real_home_untouched
echo
[ $FAILED -eq 0 ] && echo "all velo-task M3b checks passed" || echo "FAILURES"
exit $FAILED
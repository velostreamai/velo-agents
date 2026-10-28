#!/bin/bash
# velo-task M1 foundation (docs/velo-task-spec.md): install-vanth, the velo-task-state helper, the daemon
# lifecycle. Bars: B14 (bash 3.2 for the M1 scripts), B21 (secrets), B22 (privacy, provenance), B23
# (supply chain), and from B33 the allowlist rejections, two concurrent ensure-daemon and a reused pid
# that is never signalled; plus a unit test per helper subcommand (failpoint gating R21, redaction B34(iv)).
#
# No real Vanth is needed: fake vanthd/vanth/uv stand in (tests/fixtures/velo-task/, rendered by mkvenv and mkuv). The fake
# vanthd really listens, so the loopback check sees a socket. The real install and daemon run only with
# VELO_TASK_NETWORK_TESTS=1 (downloads about 30 wheels).
#
# Isolation: the suite runs everything under a temp HOME and a PATH of system directories (plus a shims directory in the
# tests that plant shims); the real home is snapshotted first and compared at the end. The test-seam capability (R21) is a
# marker file with a per-run nonce in the suite's temp root; VELO_TASK_TEST=1 is set only by the tests that need a seam.
#
# Every check is also proved RED on a mutated COPY of the code under test (`prove`): the repo's files are
# never edited, and a mutation whose anchor is not found exactly once is a failed proof, never a skip. The proofs run
# VELO_TASK_PROOF_JOBS (default 4) at a time, each in a sub-root of its own, so the suite stays within about 4 minutes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
FIX="$HERE/fixtures/velo-task"
umask 022   # the launch's own `umask 077` must be what makes the daemon's files private
unset VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_FAILPOINT_WAIT_MAX VELO_TASK_HOME VELO_TASK_PORT VELO_TASK_UV VELO_TASK_FSYNC_TRACE VELO_TASK_TEST_ROOT_NONCE
# Test-mode timeouts (stubs answer at once; a broken run is bounded): see test-timeouts.sh.
. "$HERE/test-timeouts.sh"
PYBIN="$(command -v python3)"   # resolved before PATH is constrained below
REAL_HOME="$HOME"
snap_home() {  # what velo-task or Vanth could write under the real home, as mtime and size; the real state dir must not gain a velo-task dir
  local p
  for p in "$REAL_HOME/.agents/state" "$REAL_HOME/.agents/state/velo-task" "$REAL_HOME/.agents/state/vanth" "$REAL_HOME/.config"; do
    if [ -e "$p" ]; then /usr/bin/stat -f '%N %m %z' "$p"; else echo "$p absent"; fi
  done
}
# ~/.claude.json is compared by what matters, not by mtime: a live Claude session rewrites it all the time, so an mtime
# comparison would fail on activity that is not ours. What velo-task or Vanth would add is a vanth or velo-task entry.
claude_json_marks() { /usr/bin/grep -c -i -e vanth -e velo-task "$REAL_HOME/.claude.json" 2>/dev/null; true; }
HOME_BEFORE=$(snap_home); MARKS_BEFORE=$(claude_json_marks)
# macOS mktemp given no template ignores TMPDIR (run.sh points it into the worktree): build the template from TMPDIR.
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(mktemp -d "$TMP_ROOT/velo-task-foundation.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }   # an empty $T would make reap's pattern match everything
NONCE=$(/usr/bin/uuidgen)
printf '%s\n' "$NONCE" > "$T/.velo-task-test-root"; export VELO_TASK_TEST_ROOT_NONCE="$NONCE"   # the test-seam capability: root marker + nonce
export HOME="$T/home"; mkdir -m 700 "$HOME"
SUITE_T="$T"; SUITE_HOME="$HOME"   # a mutation proof runs with T pointed at a sub-root of its own; these stay the suite's
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PIDS="$T/pids"; : > "$PIDS"
reap() {  # stop what this suite started: fake daemons run in their own process groups, and a mutant can start two
  local p tree
  tree=$(printf '%s/' "$T" | sed 's/[^A-Za-z0-9_/-]/\\&/g')   # the temp tree as a literal pattern
  /usr/bin/pkill -9 -f -- "$tree" 2>/dev/null   # everything whose command line runs from this suite's temp tree
  for p in $(cat "$PIDS"); do
    if /bin/ps -o command= -p "$p" 2>/dev/null | grep -q -e '-decoy'; then kill -9 "$p" 2>/dev/null; fi
  done
}
cleanup() { reap; chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT; trap 'exit 130' INT TERM
FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
flunk() { printf '  FAIL %s\n' "$1"; FAILED=1; }

# ---- harness ---------------------------------------------------------------------------------------
VT() { "$R/bin/velo-task" "$@"; }
ST() { "$PYBIN" "$R/bin/velo-task-state" "$@"; }
run() { OUT=$("$@" 2>&1); RC=$?; }
need() { local d="$1"; shift; "$@" || { echo "FAILED: $d"; [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | tail -n 6 | sed 's/^/    | /'; exit 1; }; }
not() { ! "$@"; }
waitfor() { local n=$(( $1 * 20 )); shift; while ! "$@" 2>/dev/null; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; sleep 0.05; done; }
now() { "$PYBIN" -c 'import time; print(time.monotonic())'; }
between() { "$PYBIN" -c "import sys; sys.exit(0 if $1 <= $3 - $2 <= $4 else 1)"; }  # <lo> <t0> <t1> <hi>
alive() { kill -0 "$1" 2>/dev/null; }
check() {  # <label> <check fn>: the real code must pass; `note:` lines the check prints are shown
  local out line
  if out=$(trap reap EXIT; "$2" 2>&1); then
    pass "$1"
    while IFS= read -r line; do case "$line" in note:*) printf '        %s\n' "$line" ;; esac; done <<<"$out"
    return
  fi
  flunk "$1"; printf '%s\n' "$out" | sed 's/^/        /'
}
MUT_N=0
# Mutation proofs run PROOF_JOBS at a time in the background. Each one lives in a sub-root of its own ($T/pj<N>, which is $T
# for everything it runs): its copy of the code, its fixtures and every process it starts, so its `reap` stops only its own
# processes. The parent reports the results in submission order and counts a proof with no result as a failure.
PROOF_JOBS="${VELO_TASK_PROOF_JOBS:-4}"
PROOF_RES="$T/proof-results"; mkdir -p "$PROOF_RES"
proof_queue=""; proof_running=0
proof_job() {  # <n> <check fn> <label> [<code root>]: the check must go RED; the verdict is written to a file for the parent
  local n="$1" fn="$2" label="$3" root="${4:-}" out rc
  T="$T/pj$n"; PIDS="$T/pids"; : > "$PIDS"
  if [ -n "$root" ]; then out=$(trap reap EXIT; R="$root" "$fn" 2>&1); else out=$(trap reap EXIT; "$fn" 2>&1); fi; rc=$?
  if [ "$rc" = 0 ]; then printf 'FAIL\nMUTATION-PROOF %s: %s stayed GREEN with the mutation\n' "$label" "$fn"
  else printf 'ok\nMUTATION-PROOF | test=%s | mutation=%s | red="%s"\n' "$fn" "$label" "$(red_text "$out")"; fi > "$PROOF_RES/$n.res"
}
proof_report() {  # <n>: print job n's verdict as a pass or a failure, then remove its sub-root
  local res="$PROOF_RES/$1.res"
  if [ ! -s "$res" ]; then flunk "MUTATION-PROOF #$1: the proof produced no verdict"
  elif [ "$(head -n 1 "$res")" = ok ]; then pass "$(tail -n +2 "$res")"
  else flunk "$(tail -n +2 "$res")"; fi
  chmod -R u+rwx "$T/pj$1" 2>/dev/null; rm -rf "$T/pj$1"
}
proof_wait_oldest() {
  local first="${proof_queue%% *}"
  proof_queue="${proof_queue#"$first"}"; proof_queue="${proof_queue# }"
  wait "${first%%,*}" 2>/dev/null; proof_report "${first##*,}"; proof_running=$((proof_running - 1))
}
proof_drain() { while [ "$proof_running" -gt 0 ]; do proof_wait_oldest; done; }
proof_start() {  # <check fn> <label> [<code root>]: start proof MUT_N in the background once a slot is free
  while [ "$proof_running" -ge "$PROOF_JOBS" ]; do proof_wait_oldest; done
  mkdir -p "$T/pj$MUT_N"
  proof_job "$MUT_N" "$@" &
  proof_queue="$proof_queue${proof_queue:+ }$!,$MUT_N"; proof_running=$((proof_running + 1))
}
prove() {  # <label> <check fn> <file> <anchor> <replacement> [<file> <anchor> <replacement>]...: the check must go RED on the mutated copy
  local label="$1" fn="$2" m; shift 2
  MUT_N=$((MUT_N + 1))
  m="$T/pj$MUT_N/code"   # numbered, never named for the label: a label's words must not satisfy a grep on the path
  rm -rf "$m"; mkdir -p "$m"; cp -R "$REPO/bin" "$REPO/requirements" "$m/"; cp "$REPO/install.sh" "$m/"
  if ! "$PYBIN" -I - "$m" "$@" <<'PY'
import sys
root, args = sys.argv[1], sys.argv[2:]
assert args and len(args) % 3 == 0, "prove: expected <file> <anchor> <replacement> triples"
for i in range(0, len(args), 3):
    name, old, new = args[i:i + 3]
    text = open(root + "/" + name).read()
    assert text.count(old) == 1, "mutation anchor must occur exactly once in %s, found %d: %r" % (name, text.count(old), old)
    open(root + "/" + name, "w").write(text.replace(old, new))
PY
  then flunk "MUTATION-PROOF $label: anchor problem (see above)"; return; fi
  proof_start "$fn" "$label" "$m"
}
prove_env() {  # <label> <check fn>: the check, on UNCHANGED code and with the environment the caller set (a fixture mutant), must go RED
  MUT_N=$((MUT_N + 1))
  proof_start "$2" "$1"
}
red_text() {  # what a red check printed: its first FAILED line, then the first line of the output `need` showed beneath it (the detail that tells one red from another)
  local line detail
  line=$(printf '%s\n' "$1" | grep -m 1 '^FAILED:') || line="${1%%$'\n'*}"
  detail=$(printf '%s\n' "$1" | grep -m 1 -A 1 '^FAILED:' | sed -n '2s/^    | //p')
  printf '%s' "$line${detail:+ -- $detail}"
}

# ---- fixtures --------------------------------------------------------------------------------------
mkhome() {  # isolated VELO_TASK_HOME and a reserved port: sets E E_HOME E_VENV E_VH E_CALLS E_PORT
  E=$(mktemp -d "$T/e.XXXXXX"); E_HOME="$E/home"; E_VENV="$E_HOME/venv"; E_VH="$E_HOME/vanth"; E_CALLS="$E/calls"
  mkdir -m 700 "$E_HOME"; : > "$E_CALLS"
  # A listener holds the port for the test's whole life (SO_REUSEPORT, so the fake vanthd can bind it as well): the port is
  # never picked by bind-and-close, where another process could take it before the daemon does.
  "$PYBIN" "$FIX/port-holder.py" reserve "$E/port" </dev/null >/dev/null 2>&1 &
  E_HOLDER=$!
  waitfor 5 test -s "$E/port" || { echo "no port reserved" >&2; exit 1; }
  E_PORT=$(cat "$E/port")
  export VELO_TASK_HOME="$E_HOME" VELO_TASK_PORT="$E_PORT"
}
render() { sed "s#@E@#$E#g; s#@PY3@#$PYBIN#g" "$FIX/$1" > "$2"; chmod +x "$2"; }   # <fixture template> <dest>: fill in the placeholders
mkdb() {  # <path> [drop column]: a SQLite file with the tables and columns the spec reads
  "$PYBIN" -I - "$1" "${2:-}" <<'PY'
import sqlite3, sys
path, drop = sys.argv[1:3]
jobs = "job_id name status exit_code stop_actor stop_reason trigger_json created_at ended_at policy_state_json command".split()
con = sqlite3.connect(path)
con.execute("CREATE TABLE jobs (%s)" % ", ".join(c for c in jobs if c != drop))
con.execute("CREATE TABLE local_start_requests (idempotency_key, request_hash, job_id, created_at)")
if not drop:
    con.executemany("INSERT INTO jobs (job_id, name, status, command) VALUES (?, ?, ?, 'x')",
                    [("a", "one", "running"), ("b", "two", "failed")])
con.commit()
PY
}
mkvenv() {  # a fake installed Vanth: stub vanthd (listens) and vanth (both record to $E_CALLS), install marker
  # bin/python is a wrapper SCRIPT we own, never a symlink to the real interpreter: a stub (or a mutant) that
  # writes to a venv path must not be able to write through to a system binary.
  mkdir -p "$E_VENV/bin"; rm -f "$E_VENV/bin/python"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$PYBIN" > "$E_VENV/bin/python"; chmod +x "$E_VENV/bin/python"
  render fake-vanthd.py "$E_VENV/bin/vanthd"; render fake-vanth.sh "$E_VENV/bin/vanth"
  ST sha256 "$R/requirements/vanth.lock" > "$E_VENV/.velo-task-installed"
}
mkuv() {  # <variant: ok|noreason|nocolumn|extra|missing>: a fake uv + fake Vanth package for install-vanth
  local v="$1" py3="$PYBIN"   # FAKE_UV_MUTANT (noguard|fromlock) is set only by the fixture's own mutation proofs
  mkdir -p "$E/uvbin" "$E/site/vanth"; : > "$E/site/vanth/__init__.py"
  { [ "$v" = noreason ] && echo 'REASON = "something else"' || echo 'REASON = "trigger parent reached an incompatible terminal status"'; } > "$E/site/vanth/server.py"
  cat > "$E/site/vanth/migrations.py" <<EOF
def migrate(db, home):
    cols = "job_id name status exit_code stop_actor stop_reason trigger_json created_at ended_at policy_state_json".split()
    db.execute("CREATE TABLE jobs (%s)" % ", ".join(c for c in cols if c != "$([ "$v" = nocolumn ] && echo ended_at)"))
    db.execute("CREATE TABLE local_start_requests (idempotency_key, request_hash, job_id, created_at)")
    db.commit()
EOF
  # The fake uv prints the checked-in closure fixture as the installed set; it is NOT derived from the lock (finding 21).
  sed "s#@E@#$E#g; s#@PY3@#$py3#g; s#@FIX@#$FIX#g; s#@CLOSURE@#$HERE/fixtures/vanth-closure.txt#g; s#@VARIANT@#$v#g; s#@MUTANT@#${FAKE_UV_MUTANT:-}#g" \
    "$FIX/fake-uv.py" > "$E/uvbin/uv"
  chmod +x "$E/uvbin/uv"
}
installv() { VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run VT install-vanth; }   # install through the fake uv (the override is test-capability only)
daemon_pid() { ST json-get "$E_VH/daemon.json" pid 2>/dev/null; }
launches() { grep -c '^launch ' "$E_CALLS" || true; }
prov() { sed -n "s/^$1=//p" "$E_HOME/daemon.provenance"; }
intent() { sed -n "s/^$1=//p" "$E_HOME/daemon.intent"; }
retired() { ls "$E_HOME" | grep -c "^$1\.retired\." || true; }   # how many records of that name were retired
prestart() {  # <umask> [env args...]: start the fake vanthd by hand, as someone else would: no provenance
  local um="$1"; shift
  ( umask "$um"; exec /usr/bin/env -i PATH=/usr/bin:/bin VANTH_HOME="$E_VH" AGENT_BG_HOME="$E_VH" VANTH_DAEMON_PORT="$E_PORT" "$@" "$E_VENV/bin/vanthd" </dev/null >/dev/null 2>&1 ) &
  waitfor 5 test -s "$E_VH/daemon.json"
}
decoy_ready() { /bin/ps -o command= -p "$1" | grep -q "^$2-decoy"; }
decoy() {  # <argv0 label> -> pid of an unrelated live process whose command line starts with <label>-decoy
  ( exec -a "$1-decoy" /bin/sleep 300 ) </dev/null >/dev/null 2>&1 &
  local p=$!
  echo "$p" >> "$PIDS"
  waitfor 5 decoy_ready "$p" "$1" || { echo "decoy $1 never started" >&2; return 1; }
  echo "$p"
}
lstart_of() { LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1" | sed -e 's/  */ /g; s/^ //; s/ $//'; }   # ps's UTC rendering, squeezed
shift_lstart() {  # <lstart> <seconds>: the same clock moved by seconds, in the same rendering
  local e; e=$(LC_ALL=C date -j -u -f '%a %b %d %H:%M:%S %Y' "$1" +%s) || return 1
  LC_ALL=C TZ=UTC date -j -u -r "$(( e + $2 ))" '+%a %b %e %H:%M:%S %Y' | sed -e 's/  */ /g'
}
iso_start() { LC_ALL=C date -j -u -f '%a %b %d %H:%M:%S %Y' "$(lstart_of "$1")" +%Y-%m-%dT%H:%M:%SZ; }
write_json() {  # <pid> <started_at>: a daemon.json as Vanth writes it, private like Vanth's own (a loose one would be refused for its mode, not for what the test means)
  mkdir -p -m 700 "$E_VH"
  ( umask 077; printf '{"url":"http://127.0.0.1:%s","pid":%s,"started_at":"%s"}\n' "$E_PORT" "$1" "$2" > "$E_VH/daemon.json" )
}
D64=$(printf '%064d' 7); UUID0=00000000-0000-4000-8000-000000000001
write_rec() {  # <file> <pid> <lstart> [digest] [incarnation]: a record in the format velo-task writes (defaults are well formed)
  printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=%s\n' "$2" "$3" "${4-$D64}" "${5-$UUID0}" > "$1"
}
write_prov() { write_rec "$E_HOME/daemon.provenance" "$@"; }   # <pid> <lstart> [digest] [incarnation]
write_intent() { write_rec "$E_HOME/daemon.intent" "$@"; }
snap_state() {  # <dir>: names, sizes, mtimes and modes of everything under it, for a before/after comparison
  ( cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 /usr/bin/stat -f '%N %z %Fm %Lp' )   # %Fm: modification time to the nanosecond
}

# ---- helper: fp, sha256, publish, append-index ------------------------------------------------------
t_fp() {
  run ST fp orphaned "" "" "" ""; need "SHA-256 prefix of 'orphaned||||' (vector from shasum)" [ "$OUT" = 7eec38f52733f3e3 ]
  run ST fp failed 7 user done 2026-01-01T00:00:00Z; need "vector for a full row" [ "$OUT" = 9d1144dcbba2ce7d ]
  need "the end-time column is part of the fingerprint" [ "$(ST fp failed 7 user done e1)" != "$(ST fp failed 7 user done e2)" ]
  run ST fp a b c; need "wrong arity exits 2" [ "$RC" = 2 ]
}
t_sha256() {
  need "stdin" [ "$(printf abc | ST sha256)" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
  printf abc > "$T/abc"; need "file argument" [ "$(ST sha256 "$T/abc")" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
}
t_publish() {
  local d; d=$(mktemp -d "$T/p.XXXXXX")
  printf one > "$d/t1"; run ST publish "$d/dest" "$d/t1"
  need "publish exits 0" [ "$RC" = 0 ]; need "dest has the content" [ "$(cat "$d/dest")" = one ]; need "temp is removed" [ ! -e "$d/t1" ]
  printf two > "$d/t2"; run ST publish "$d/dest" "$d/t2"
  need "publishing onto an existing name exits 3" [ "$RC" = 3 ]
  need "the existing name is not replaced" [ "$(cat "$d/dest")" = one ]; need "temp removed on refusal" [ ! -e "$d/t2" ]
  printf three > "$d/t3"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=publish.linked:exit ST publish "$d/d3" "$d/t3" 2>/dev/null; RC=$?
  need "a crash between link and unlink exits 137" [ "$RC" = 137 ]
  need "a crash leaves the published name" [ -e "$d/d3" ]; need "...and the temp, never neither" [ -e "$d/t3" ]
  need "the published name is a hard link of the temp" [ "$(stat -f %i "$d/d3")" = "$(stat -f %i "$d/t3")" ]
  printf six > "$d/t6"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=publish.linked@daemon.provenance:exit ST publish "$d/daemon.intent" "$d/t6" 2>/dev/null; RC=$?
  need "publish.linked@daemon.provenance does not fire for another destination" [ "$RC" = 0 ]
  printf seven > "$d/t7"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=publish.linked@daemon.provenance:exit ST publish "$d/daemon.provenance" "$d/t7" 2>/dev/null; RC=$?
  need "...and fires for the named destination (exit 137)" [ "$RC" = 137 ]
  need "...between link and unlink: the named destination exists" [ -e "$d/daemon.provenance" ]; need "...and so does the temp, never neither" [ -e "$d/t7" ]
  # R17 order, observed through the fsync trace (finding 9, 14): fsync the temp, link, fsync the DESTINATION directory, unlink the
  # temp, fsync the temp's directory. Destination and temp live in different directories so each directory fsync is distinguishable.
  mkdir "$d/dd" "$d/sd"; printf four > "$d/sd/t4"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" ST publish "$d/dd/dest4" "$d/sd/t4"
  need "publish fsyncs the temp, links, fsyncs the destination directory, unlinks the temp, fsyncs the temp's directory, in that order" \
    [ "$(cat "$d/trace")" = "$(printf 'fsync file %s\nlink %s %s\nfsync dir %s\nunlink %s\nfsync dir %s' "$d/sd/t4" "$d/sd/t4" "$d/dd/dest4" "$d/dd" "$d/sd/t4" "$d/sd")" ]
  printf five > "$d/sd/t5"; : > "$d/trace"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" ST publish "$d/dd/dest4" "$d/sd/t5"; RC=$?
  need "a refused publish exits 3" [ "$RC" = 3 ]
  need "...after fsyncing the temp, and it removes the temp durably (unlink, then the temp's directory)" \
    [ "$(cat "$d/trace")" = "$(printf 'fsync file %s\nlink %s %s\nunlink %s\nfsync dir %s' "$d/sd/t5" "$d/sd/t5" "$d/dd/dest4" "$d/sd/t5" "$d/sd")" ]
}
t_retire() {  # finding 10: the durable retirement the provenance and intent records go through
  local d c e now; d=$(mktemp -d "$T/r.XXXXXX"); printf 'rec\n' > "$d/daemon.provenance"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" run ST retire "$d/daemon.provenance"
  need "retire exits 0" [ "$RC" = 0 ]
  need "the record is gone under its own name" [ ! -e "$d/daemon.provenance" ]
  need "...and kept under <name>.retired.<epoch> with its content" [ "$(cat "$d"/daemon.provenance.retired.[0-9]*)" = rec ]
  need "retire renames, then fsyncs the directory, in that order" \
    [ "$(cat "$d/trace")" = "$(printf 'rename %s %s\nfsync dir %s' "$d/daemon.provenance" "$(ls "$d"/daemon.provenance.retired.[0-9]*)" "$d")" ]
  # Every second the retirement could land in already holds a retired record, so the name for "now" is always taken, whatever the clock does.
  c=$(mktemp -d "$T/r.XXXXXX"); now=$(/bin/date +%s)
  for e in $((now - 1)) "$now" $((now + 1)) $((now + 2)); do printf 'held-%s\n' "$e" > "$c/daemon.provenance.retired.$e"; done
  printf 'again\n' > "$c/daemon.provenance"; run ST retire "$c/daemon.provenance"
  need "retiring when the name for this second is taken exits 0" [ "$RC" = 0 ]
  for e in $((now - 1)) "$now" $((now + 1)) $((now + 2)); do
    need "...the record already retired as .$e is intact" [ "$(cat "$c/daemon.provenance.retired.$e")" = "held-$e" ]
  done
  need "...and the new record is kept under a numbered name" [ "$(cat "$c"/daemon.provenance.retired.[0-9]*.[0-9]*)" = again ]
  need "...leaving nothing under its own name" [ ! -e "$c/daemon.provenance" ]
  run ST retire "$d/nothing-here"; need "retiring a path that does not exist is an error, not a pass" [ "$RC" = 1 ]
}
t_append_index() {
  local d f i; d=$(mktemp -d "$T/a.XXXXXX"); f="$d/names-x"
  ST append-index "$f" job_1; ST append-index "$f" job-2
  need "two calls leave two lines, nothing overwritten" [ "$(cat "$f")" = "$(printf 'job_1\njob-2')" ]
  need "file is created 0600" [ "$(stat -f %Lp "$f")" = 600 ]
  run ST append-index "$f" 'bad id'; need "an id outside [A-Za-z0-9_-] exits 2" [ "$RC" = 2 ]
  run ST append-index "$f" $'job_3\n'; need "an id with a trailing newline exits 2 (it would write an empty line)" [ "$RC" = 2 ]
  need "...and neither refusal wrote anything" [ "$(wc -l < "$f" | tr -d ' ')" = 2 ]
  for i in $(seq 1 30); do ST append-index "$f" "con$i" & done; wait
  need "30 concurrent appends all land as whole lines" [ "$(grep -cE '^con[0-9]+$' "$f")" = 30 ]
  # The index is durable (R17 step 3, finding 14): fsync the file after the write, and the directory when the file was created.
  f="$d/names-traced"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" ST append-index "$f" job_a
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace" ST append-index "$f" job_b
  need "creating the index fsyncs the file then the directory; appending to it fsyncs only the file" \
    [ "$(cat "$d/trace")" = "$(printf 'fsync file %s\nfsync dir %s\nfsync file %s' "$f" "$d" "$f")" ]
}
t_lock() {
  local d hp after; d=$(mktemp -d "$T/l.XXXXXX")
  run ST lock "$d/l" -- /bin/sh -c 'exit 7'; need "the command's exit code is returned" [ "$RC" = 7 ]
  # The holder is the helper process itself (not a shell function around it): killing hp kills the lock owner.
  "$PYBIN" "$R/bin/velo-task-state" lock "$d/l" -- /bin/sh -c "echo \$\$ > '$d/held'; exec /bin/sleep 20" >/dev/null 2>&1 & hp=$!
  waitfor 5 test -s "$d/held" || { echo "FAILED: holder never took the lock"; exit 1; }
  run ST lock --timeout 0.3 "$d/l" -- /usr/bin/true; need "a second locker gives up with 75 while the first holds" [ "$RC" = 75 ]
  kill -9 "$hp"; wait "$hp" 2>/dev/null
  run ST lock --timeout 3 "$d/l" -- /usr/bin/true; after=$RC
  kill "$(cat "$d/held")" 2>/dev/null
  need "the lock is released by process death; the orphaned command does not keep it" [ "$after" = 0 ]
}
t_lock_held() {  # what a locked body asks before it runs (finding 2): is somebody holding the lock on this path?
  local d hp; d=$(mktemp -d "$T/lh.XXXXXX")
  run ST lock-held "$d/l"; need "no lock file: not held (exit 1)" [ "$RC" = 1 ]
  need "...and asking does not create the file" [ ! -e "$d/l" ]
  : > "$d/l"; run ST lock-held "$d/l"; need "a lock file nobody holds: not held (exit 1)" [ "$RC" = 1 ]
  "$PYBIN" "$R/bin/velo-task-state" lock "$d/l" -- /bin/sh -c "echo \$\$ > '$d/held'; exec /bin/sleep 20" >/dev/null 2>&1 & hp=$!
  waitfor 5 test -s "$d/held" || { kill "$hp" 2>/dev/null; echo "FAILED: holder never took the lock"; exit 1; }
  run ST lock-held "$d/l"; need "a held lock: exit 0" [ "$RC" = 0 ]
  run ST lock-held "$d/l"; need "...again: asking does not release or steal it" [ "$RC" = 0 ]
  run ST lock --timeout 0.3 "$d/l" -- /usr/bin/true; need "...and the holder still excludes others" [ "$RC" = 75 ]
  kill -9 "$hp"; wait "$hp" 2>/dev/null; kill "$(cat "$d/held")" 2>/dev/null
  run ST lock-held "$d/l"; need "after the holder died: not held again" [ "$RC" = 1 ]
  run ST lock-held; need "no path: usage error (exit 2)" [ "$RC" = 2 ]
}
t_json_get() {  # the helper replaces jq: process identity and provenance are read through it, never through a PATH tool
  local d; d=$(mktemp -d "$T/jg.XXXXXX")
  printf '%s\n' '{"pid":4242,"url":"http://127.0.0.1:48217","up":true,"down":false,"nothing":null,"ratio":1.5,"nested":{"a":[1,2]},"name":"a b","accent":"café"}' > "$d/j"
  need "a number is printed as written" [ "$(ST json-get "$d/j" pid)" = 4242 ]
  need "a float" [ "$(ST json-get "$d/j" ratio)" = 1.5 ]
  need "a string is printed raw, without quotes" [ "$(ST json-get "$d/j" url)" = http://127.0.0.1:48217 ]
  need "a string with a space" [ "$(ST json-get "$d/j" name)" = "a b" ]
  need "booleans are printed as the words jq prints" [ "$(ST json-get "$d/j" up)/$(ST json-get "$d/j" down)" = true/false ]
  need "a nested value is compact JSON" [ "$(ST json-get "$d/j" nested)" = '{"a":[1,2]}' ]
  need "non-ASCII comes out as UTF-8" [ "$(ST json-get "$d/j" accent)" = "$(printf 'caf\xc3\xa9')" ]
  need "...whatever the caller's locale (a Latin-1 locale must not change the bytes)" [ "$(LC_ALL=en_US.ISO8859-1 ST json-get "$d/j" accent)" = "$(printf 'caf\xc3\xa9')" ]
  run ST json-get "$d/j" absent; need "a missing key: exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  run ST json-get "$d/j" nothing; need "a null value: exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  run ST json-get "$d/none.json" pid; need "a missing file (a daemon that has not started): exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  printf '%s' '{"pid":' > "$d/bad"; run ST json-get "$d/bad" pid; need "malformed JSON is an error, not an empty value (exit 1)" [ "$RC" = 1 ]
  printf '[1,2]\n' > "$d/arr"; run ST json-get "$d/arr" pid; need "a JSON array is an error (exit 1)" [ "$RC" = 1 ]
  need "...saying it does not hold a JSON object (not an accident of the lookup)" grep -q 'does not hold a JSON object' <<<"$OUT"
  need "- reads standard input" [ "$(printf '{"up": true}' | ST json-get - up)" = true ]
  run ST json-get "$d/j"; need "a missing key argument is a usage error (exit 2)" [ "$RC" = 2 ]
}
t_modes_check() {  # finding 8: everything Vanth leaves behind must be private, the whole of logs/ and events/ included
  local d h f p; d=$(mktemp -d "$T/mc.XXXXXX"); h="$d/vanth"
  mkdir -m 700 "$h" "$h/logs" "$h/logs/jobs" "$h/events"
  for f in jobs.sqlite jobs.sqlite-wal jobs.sqlite-shm token daemon.json logs/daemon.log logs/jobs/j1.log events/e.jsonl; do : > "$h/$f"; chmod 600 "$h/$f"; done
  : > "$d/daemon.launch.log"; chmod 600 "$d/daemon.launch.log"
  run ST modes-check "$h" "$d/daemon.launch.log"; need "an all-private home passes (exit 0)" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  run ST modes-check "$d/absent"; need "a home that does not exist yet passes: there is nothing to protect" [ "$RC" = 0 ]
  for f in "" jobs.sqlite jobs.sqlite-wal jobs.sqlite-shm token daemon.json logs logs/jobs logs/daemon.log logs/jobs/j1.log events events/e.jsonl; do
    p="$h${f:+/$f}"
    if [ -d "$p" ]; then chmod 755 "$p"; else chmod 644 "$p"; fi
    run ST modes-check "$h" "$d/daemon.launch.log"
    need "${f:-the home} at 0644/0755 is refused (exit 8)" [ "$RC" = 8 ]; need "...naming it" grep -qF "$p" <<<"$OUT"
    if [ -d "$p" ]; then chmod 700 "$p"; else chmod 600 "$p"; fi
  done
  chmod 644 "$d/daemon.launch.log"; run ST modes-check "$h" "$d/daemon.launch.log"
  need "a loose launch log (an extra file) is refused (exit 8)" [ "$RC" = 8 ]; need "...naming it" grep -qF "$d/daemon.launch.log" <<<"$OUT"
  chmod 600 "$d/daemon.launch.log"
  for f in 640 604 660 606 620 602; do   # group-only and other-only bits count too
    chmod "$f" "$h/token"; run ST modes-check "$h"; need "token at 0$f is refused" [ "$RC" = 8 ]
  done
  chmod 600 "$h/token"
  for f in 750 705 770; do chmod "$f" "$h/events"; run ST modes-check "$h"; need "events/ at 0$f is refused" [ "$RC" = 8 ]; done
  chmod 700 "$h/events"
  ln -s "$d/daemon.launch.log" "$h/logs/link"; run ST modes-check "$h"
  need "a symlink under logs/ is refused: its own mode says nothing about its target" [ "$RC" = 8 ]; need "...saying so" grep -q symlink <<<"$OUT"
  rm "$h/logs/link"
  mkdir -m 000 "$h/events/locked"; run ST modes-check "$h"
  need "a directory that cannot be read is an error (exit 1), never a pass" [ "$RC" = 1 ]
  chmod 700 "$h/events/locked"; rmdir "$h/events/locked"
  run ST modes-check "$h" "$d/daemon.launch.log"; need "control: private again passes" [ "$RC" = 0 ]
  run ST modes-check; need "no home argument is a usage error (exit 2)" [ "$RC" = 2 ]
}

# ---- helper: redact, jobs-ro, failpoints ------------------------------------------------------------
redact_as() {  # <stdin text> [NAME=value...]: run redact under exactly the environment given (fake secret values only)
  local text="$1"; shift
  printf '%s\n' "$text" | /usr/bin/env -i PATH=/usr/bin:/bin "$@" "$PYBIN" "$R/bin/velo-task-state" redact
}
t_redact() {  # fixtures are token-SHAPED but shorter than real tokens, so repository secret scanners do not flag them
  mkhome; printf '# names only\nMY_PASSPHRASE\n\n' > "$E_HOME/vanth.env.allow"
  local log; log=$(printf '%s\n' \
    'GITHUB_TOKEN=ghp_AbCdEf0123456789' \
    'fine-grained github_pat_11ABCDEFG0123456789_abcdefghijklmnop' \
    'passphrase correct-horse-battery-staple' \
    'api key v4lu3-from-env-key end' \
    '> Authorization: Bearer abc.def.ghi-ZZ9' \
    'openrouter sk-or-v1-0123456789ab' \
    'aws AKIAABCDEFGH12' \
    'build ok: 12 tests, task-management-board')
  OUT=$(redact_as "$log" VELO_TASK_HOME="$E_HOME" DEPLOY_API_KEY=v4lu3-from-env-key MY_PASSPHRASE=correct-horse-battery-staple 2>"$E/err"); RC=$?
  need "redact exits 0" [ "$RC" = 0 ]
  need "ghp_ token shape is redacted" not grep -q 'ghp_AbCd' <<<"$OUT"
  need "github_pat_ token shape is redacted" not grep -q 'github_pat_11' <<<"$OUT"
  need "sk- token shape is redacted" not grep -q 'sk-or-v1' <<<"$OUT"
  need "AKIA token shape is redacted" not grep -q 'AKIAABCD' <<<"$OUT"
  need "the Authorization header value is redacted" not grep -q 'Bearer' <<<"$OUT"
  need "the Authorization header name stays" grep -q 'Authorization: \*\*\*' <<<"$OUT"
  need "the value of an allowlisted name is redacted although the name matches no pattern" not grep -q 'correct-horse' <<<"$OUT"
  need "the value of an env var whose name matches key|token|... is redacted" not grep -q 'v4lu3' <<<"$OUT"
  need "ordinary text is untouched (sk- inside a word is not a key)" grep -q 'build ok: 12 tests, task-management-board' <<<"$OUT"
  OUT=$(redact_as 'x ghp_AbCdEf0123456789 y' VELO_TASK_HOME="$E/no-allowlist-here" 2>"$E/err"); RC=$?
  need "a missing allowlist file is an empty allowlist, not an error" [ "$RC" = 0 ]
  need "...and the shapes are still redacted" [ "$OUT" = 'x *** y' ]
  rm "$E_HOME/vanth.env.allow"; mkdir "$E_HOME/vanth.env.allow"   # exists but cannot be read as a file
  OUT=$(redact_as 'secret text ghp_AbCdEf0123456789' VELO_TASK_HOME="$E_HOME" 2>"$E/err"); RC=$?
  need "an allowlist that exists but cannot be read is an error: non-zero exit" [ "$RC" != 0 ]
  need "...and nothing at all reaches stdout" [ -z "$OUT" ]
  OUT=$(redact_as 'secret text' 2>"$E/err"); RC=$?
  need "without VELO_TASK_HOME the allowlist cannot be found: non-zero exit" [ "$RC" != 0 ]
  need "...nothing reaches stdout" [ -z "$OUT" ]
  need "...and the reason is on stderr" grep -q 'VELO_TASK_HOME is not set' "$E/err"
}
t_jobs_ro() {
  local d db t0 t1 lp; d=$(mktemp -d "$T/j.XXXXXX"); db="$d/jobs.sqlite"; mkdb "$db"
  run ST jobs-ro "$db" "SELECT job_id, status FROM jobs ORDER BY job_id"
  need "rows come out as one JSON array" [ "$OUT" = '[{"job_id":"a","status":"running"},{"job_id":"b","status":"failed"}]' ]
  run ST jobs-ro "$db" "DELETE FROM jobs"; need "a write is refused" [ "$RC" != 0 ]
  need "...and the data is unchanged" [ "$(ST jobs-ro "$db" 'SELECT count(*) AS n FROM jobs')" = '[{"n":2}]' ]
  mkdb "$d/old.sqlite" ended_at; run ST jobs-ro "$d/old.sqlite" "SELECT 1 AS x"
  need "a missing pinned column exits 5" [ "$RC" = 5 ]; need "...naming the column" grep -q 'jobs.ended_at' <<<"$OUT"
  run ST jobs-ro "$d/nope.sqlite" "SELECT 1"; need "a missing database exits 1" [ "$RC" = 1 ]
  need "...and reading it creates no file" [ ! -e "$d/nope.sqlite" ]
  # finding 5: read-only is enforced by the connection, not by trust in the SQL. mode=ro alone still lets ATTACH create a file.
  run ST jobs-ro "$db" "ATTACH DATABASE '$d/attached.db' AS x"
  need "ATTACH is refused (exit 1, not authorized)" [ "$RC" = 1 ]; need "...saying so" grep -q 'not authorized' <<<"$OUT"
  need "...and creates no file" [ ! -e "$d/attached.db" ]
  run ST jobs-ro "$db" "ATTACH DATABASE 'file:$d/attached-uri.db?mode=rwc' AS x"
  need "ATTACH of a URI that would create a database is refused" [ "$RC" = 1 ]; need "...and creates no file" [ ! -e "$d/attached-uri.db" ]
  run ST jobs-ro "$db" "INSERT INTO jobs (job_id) VALUES ('zz')"; need "INSERT is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "DROP TABLE jobs"; need "DROP TABLE is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "CREATE TABLE extra (a)"; need "CREATE TABLE is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "PRAGMA writable_schema=ON"; need "PRAGMA writable_schema is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "PRAGMA journal_mode=WAL"; need "PRAGMA journal_mode is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "SELECT load_extension('nothing')"; need "load_extension is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$db" "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r"
  need "a recursive query is refused: only SELECT, READ and FUNCTION are allowed (exit 1)" [ "$RC" = 1 ]
  need "a CTE that is not recursive still works" [ "$(ST jobs-ro "$db" 'WITH c AS (SELECT count(*) AS n FROM jobs) SELECT n FROM c')" = '[{"n":2}]' ]
  need "none of the refused statements changed the database" [ "$(ST jobs-ro "$db" 'SELECT count(*) AS n FROM jobs')" = '[{"n":2}]' ]
  need "a plain SELECT, with a function and a join, still works" \
    [ "$(ST jobs-ro "$db" 'SELECT upper(a.status) AS s FROM jobs a JOIN local_start_requests b ON b.job_id = a.job_id UNION SELECT count(*) FROM jobs')" = '[{"s":2}]' ]
  "$PYBIN" -I - "$db" "$d/locked" >/dev/null 2>&1 <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("PRAGMA journal_mode=DELETE"); con.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close(); time.sleep(8)
PY
  lp=$!
  waitfor 5 test -e "$d/locked" || { kill "$lp" 2>/dev/null; echo "FAILED: could not lock the fixture database"; exit 1; }
  t0=$(now); run ST jobs-ro "$db" "SELECT 1 AS x"; t1=$(now)
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  need "a database locked past the timeout exits 4" [ "$RC" = 4 ]
  need "...after about 2000 ms" between 1.8 "$t0" "$t1" 5
}
t_failpoint_gating() {  # R21: each gate condition is isolated, so each is individually provable (finding 11: a root marker + nonce, not TMPDIR)
  local d wp bad; d=$(mktemp -d "$T/f.XXXXXX"); mkdir "$d/inside" "$d/nest" "$d/nest-empty" "$d/sibling"
  bad=$(/usr/bin/dirname "$SUITE_T")   # the broad temp directory the suite root lives in: it is NOT under the marker, and nothing is written there
  # (a) VELO_TASK_TEST missing; the marker and nonce are fine and the state dir is under them
  VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "without VELO_TASK_TEST=1 a set failpoint is refused (exit 2), not fired" [ "$RC" = 2 ]
  need "...with a log line" grep -q 'refused' <<<"$OUT"
  VELO_TASK_FAILPOINT=daemon.lock.held run ST sha256 </dev/null
  need "a stray VELO_TASK_FAILPOINT is refused by an unrelated subcommand too" [ "$RC" = 2 ]
  VELO_TASK_HOME="$d/home" VELO_TASK_FSYNC_TRACE="$d/trace-refused" run ST sha256 </dev/null
  need "VELO_TASK_FSYNC_TRACE without VELO_TASK_TEST=1 is refused (exit 2)" [ "$RC" = 2 ]
  need "...saying it is only honoured for tests" grep -q 'VELO_TASK_FSYNC_TRACE is set but refused' <<<"$OUT"
  need "...and no trace was written" [ ! -e "$d/trace-refused" ]
  # (b) VELO_TASK_TEST=1 but no state dir; the working directory is under the marker
  OUT=$(cd "$d/inside" && VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=daemon.lock.held:exit "$PYBIN" "$R/bin/velo-task-state" failpoint daemon.lock.held 2>&1); RC=$?
  need "VELO_TASK_TEST=1 with no VELO_TASK_HOME is refused" [ "$RC" = 2 ]
  # (c) VELO_TASK_TEST=1 but a state dir with no marker above it
  VELO_TASK_TEST=1 VELO_TASK_HOME=/opt/velo-task-outside-temp VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "VELO_TASK_TEST=1 with a state dir outside any test root is refused" [ "$RC" = 2 ]
  # (d) a hostile TMPDIR naming a broad directory must not authorize anything: only a marker holding the nonce does
  TMPDIR="$bad" VELO_TASK_TEST=1 VELO_TASK_HOME="$bad/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "TMPDIR set to a broad temp directory does not authorize a state dir under it" [ "$RC" = 2 ]
  need "...the refusal says why" grep -q 'no .velo-task-test-root above VELO_TASK_HOME' <<<"$OUT"
  printf '%s\n' "$NONCE" > "$d/sibling/.velo-task-test-root"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$bad/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "a marker holding the right nonce somewhere else (not above the state dir) does not authorize it" [ "$RC" = 2 ]
  # (e) the nonce: missing from the environment, wrong, or both empty
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run /usr/bin/env -u VELO_TASK_TEST_ROOT_NONCE "$PYBIN" "$R/bin/velo-task-state" failpoint daemon.lock.held
  need "a missing VELO_TASK_TEST_ROOT_NONCE refuses" [ "$RC" = 2 ]; need "...naming it" grep -q 'VELO_TASK_TEST_ROOT_NONCE is not set' <<<"$OUT"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home" VELO_TASK_TEST_ROOT_NONCE=not-the-nonce VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "a VELO_TASK_TEST_ROOT_NONCE that differs from the marker refuses" [ "$RC" = 2 ]
  : > "$d/nest-empty/.velo-task-test-root"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/nest-empty/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run /usr/bin/env -u VELO_TASK_TEST_ROOT_NONCE "$PYBIN" "$R/bin/velo-task-state" failpoint daemon.lock.held
  need "an empty marker does not match an unset nonce" [ "$RC" = 2 ]
  # (f) the nearest marker decides: a nested marker with another nonce refuses although a matching one sits further up
  printf '%s\n' "another-run" > "$d/nest/.velo-task-test-root"
  VELO_TASK_TEST=1 VELO_TASK_HOME="$d/nest/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "the nearest marker above the state dir decides, not a farther one" [ "$RC" = 2 ]
  export VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home"
  VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held; need "name:exit exits 137" [ "$RC" = 137 ]
  VELO_TASK_FAILPOINT=publish.linked:exit run ST failpoint daemon.lock.held; need "another failpoint's name does not fire" [ "$RC" = 0 ]
  VELO_TASK_FAILPOINT=nonsense run ST failpoint daemon.lock.held; need "an unregistered failpoint name is refused" [ "$RC" = 2 ]
  VELO_TASK_FAILPOINT=daemon.lock.held:sleep run ST failpoint daemon.lock.held; need "an unknown action is refused" [ "$RC" = 2 ]
  VELO_TASK_FAILPOINT=daemon.lock.held@daemon.provenance:exit run ST failpoint daemon.lock.held
  need "a destination on a failpoint that has none is refused (exit 2)" [ "$RC" = 2 ]; need "...saying so" grep -q 'only publish.linked takes' <<<"$OUT"
  VELO_TASK_FAILPOINT=publish.linked@:exit run ST failpoint daemon.lock.held; need "an empty destination is refused (exit 2)" [ "$RC" = 2 ]
  run ST failpoint daemon.lock.held; need "unset: a no-op" [ "$RC" = 0 ]
  VELO_TASK_FAILPOINT="daemon.lock.held:wait=$d/barrier" "$PYBIN" "$R/bin/velo-task-state" failpoint daemon.lock.held >/dev/null 2>&1 & wp=$!
  waitfor 5 test -e "$d/barrier.reached" || { kill "$wp" 2>/dev/null; echo "FAILED: wait never reported .reached"; exit 1; }
  sleep 0.3
  need "wait blocks until the barrier file exists" alive "$wp"
  : > "$d/barrier"; waitfor 5 not alive "$wp" || { kill "$wp" 2>/dev/null; echo "FAILED: still blocked after the barrier appeared"; exit 1; }
  wait "$wp"; RC=$?; need "...then exits 0" [ "$RC" = 0 ]
}

# ---- front end: B14, not-implemented, allowlist, secrets, modes, provenance, concurrency, restart ----
SWEEP_RE='declare[[:space:]]+-[a-zA-Z]*[Agn]|local[[:space:]]+-[a-zA-Z]*[An]|(^|[^A-Za-z_])(mapfile|readarray|coproc)([^A-Za-z_]|$)|\$\{[A-Za-z_][A-Za-z_0-9]*(,,?|\^\^?|@[QEPAaKk])[^}]*\}|\|&|&>>|;;&|;&|\[\[[[:space:]]+-v[[:space:]]|globstar|wait[[:space:]]+-n|EPOCHREALTIME|EPOCHSECONDS|\[-[0-9]+\]'
t_b14() {
  local f d n=0; d=$(mktemp -d "$T/b.XXXXXX")
  for f in "$R"/bin/velo-task*; do
    [ "$(head -n 1 "$f")" = '#!/bin/bash' ] || continue
    n=$((n + 1))
    need "$(basename "$f") parses under /bin/bash -n" /bin/bash -n "$f"
    run grep -nE "$SWEEP_RE" "$f"; need "$(basename "$f") has no bash-4 construct" [ "$RC" = 1 ]
  done
  need "at least one bash script matched bin/velo-task*" [ "$n" -ge 1 ]
  run /bin/bash "$R/bin/velo-task" --help; need "one real invocation under /bin/bash" [ "$RC" = 0 ]
  printf '#!/bin/bash\nset -e\ndeclare -A seeded\nseeded[a]=1\n' > "$d/seeded.sh"
  need "the seeded declare -A fixture is caught by the sweep" grep -qE "$SWEEP_RE" "$d/seeded.sh"
  need "...and fails when run under /bin/bash" not /bin/bash "$d/seeded.sh"
}
t_unimplemented() {
  local s; mkhome
  for s in run wait status ack cancel project reconcile; do
    run VT $s; need "$s exits 2" [ "$RC" = 2 ]; need "$s says not implemented in M1" grep -q 'not implemented in M1' <<<"$OUT"
  done
  run VT install-vanth extra; need "an argument to install-vanth exits 2" [ "$RC" = 2 ]
}
t_private_subcommands() {  # finding 2: no locked body is a subcommand, and every _-prefixed name is an unknown subcommand
  local s; mkhome; mkvenv
  for s in _locked-ensure _locked-restart _locked-install _locked_ensure _ensure-daemon _doctor _ __ _x; do
    run VT "$s"; need "$s exits 2" [ "$RC" = 2 ]
    need "...as an unknown subcommand" grep -q "unknown subcommand '$s'" <<<"$OUT"
  done
  need "none of them launched anything" [ "$(launches)" = 0 ]
  for s in locked_ensure locked-ensure locked_restart locked_install cmd_doctor cmd_ensure_daemon run_locked assert_lock_held launch_daemon; do
    run VT "$s"; need "the library function $s is not a subcommand (exit 2)" [ "$RC" = 2 ]
    need "...it is simply not implemented" grep -q 'not implemented in M1' <<<"$OUT"
  done
  need "none of them launched anything either" [ "$(launches)" = 0 ]
  need "the dispatcher has no case arm that names an underscore subcommand" [ -z "$(grep -nE '^[[:space:]]*_[A-Za-z0-9_-]+[|)]' "$R/bin/velo-task")" ]
  need "the front end does not mention a locked entry point" not grep -q '_locked' "$R/bin/velo-task"
}
t_lock_bypass() {  # finding 2: a locked body that is run without the daemon lock refuses before it does anything
  local f hp; mkhome; mkvenv; mkuv ok
  # A body whose guard a mutant removed must still be harmless here: it would run the fake uv, never the Homebrew one.
  export VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv"
  for f in locked_ensure locked_restart locked_install; do
    run /bin/bash -c '. "$1"; "$2" "$3"' x "$R/bin/velo-task-lib.sh" "$f" "$E_HOME/lock/daemon"
    need "$f without the lock refuses (exit 2)" [ "$RC" = 2 ]; need "...saying so" grep -q 'refusing to run without the lock' <<<"$OUT"
    run /bin/bash -c '. "$1"; "$2"' x "$R/bin/velo-task-lib.sh" "$f"
    need "$f without even a lock path refuses (exit 2)" [ "$RC" = 2 ]
    run /bin/bash -c '. "$1"; "$2" "$3"' x "$R/bin/velo-task-lib.sh" "$f" "$E/not-the-lock"
    need "$f with some other path refuses (exit 2)" [ "$RC" = 2 ]
  done
  "$PYBIN" "$R/bin/velo-task-state" lock "$E/other-lock" -- /bin/sh -c "echo \$\$ > '$E/other-held'; exec /bin/sleep 20" >/dev/null 2>&1 & hp=$!
  waitfor 5 test -s "$E/other-held" || { kill "$hp" 2>/dev/null; echo "FAILED: holder never took its lock"; exit 1; }
  run /bin/bash -c '. "$1"; locked_ensure "$2"' x "$R/bin/velo-task-lib.sh" "$E/other-lock"
  need "a lock held on some other file does not satisfy the check (exit 2)" [ "$RC" = 2 ]
  kill -9 "$hp"; wait "$hp" 2>/dev/null; kill "$(cat "$E/other-held")" 2>/dev/null
  need "nothing was launched" [ "$(launches)" = 0 ]
  need "...and no uv ran" [ ! -e "$E/uv.log" ]
}
# One row per rule of R11, as rule|expect|name. Prefix rules get a longer name too, and the accept rows sit just outside
# each rule's boundary, so a rule that is dropped, or widened, fails on its own rows.
ALLOW_ROWS='PATH|reject|PATH
PATH|reject|PATHX
PATH|accept|PAT
HOME|reject|HOME
HOME|reject|HOMEBREW_TOKEN
HOME|accept|HOM
IFS|reject|IFS
IFS|reject|IFSX
IFS|accept|IF
ENV|reject|ENV
ENV|reject|ENVIRONMENT
ENV|accept|EN
BASH_ENV|reject|BASH_ENV
BASH_ENV|reject|BASH_ENVX
BASH_ENV|accept|BASH
SHELLOPTS|reject|SHELLOPTS
SHELLOPTS|accept|SHELL
PYTHON|reject|PYTHONPATH
PYTHON|reject|PYTHONHOME
PYTHON|reject|PYTHON
PYTHON|accept|PYTHO
DYLD_|reject|DYLD_INSERT_LIBRARIES
DYLD_|accept|DYLDX
LD_|reject|LD_PRELOAD
LD_|accept|LDX
VANTH_|reject|VANTH_DAEMON_PORT
VANTH_|reject|VANTH_HOME
VANTH_|accept|VANTH
VELO_TASK_|reject|VELO_TASK_HOME
VELO_TASK_|reject|VELO_TASK_UV
VELO_TASK_|accept|VELO_TASK
AGENT_BG_|reject|AGENT_BG_HOME
AGENT_BG_|accept|AGENT_BG
TMPDIR|reject|TMPDIR
TMPDIR|reject|TMPDIRX
TMPDIR|accept|TMP
charset|reject|lowercase
charset|reject|1ABC
charset|reject|A-B
charset|reject|A.B
charset|reject|A B
charset|reject|FOO=supersecretvalue
charset|accept|OPENROUTER_API_KEY
charset|accept|MY_OTHER_NAME'
t_allowlist_rejects() {  # B33, finding 18: ROW=<rule> runs only that rule's rows (the mutation proofs use it)
  local row rule expect name n=0; mkhome; mkvenv
  while IFS='|' read -r rule expect name; do
    [ -z "${ROW:-}" ] || [ "$ROW" = "$rule" ] || continue
    n=$((n + 1)); printf '%s\n' "$name" > "$E_HOME/vanth.env.allow"
    if [ "$expect" = reject ]; then
      run VT ensure-daemon </dev/null
      need "[$rule] $name is rejected with exit 6" [ "$RC" = 6 ]
      if [ "$rule" = charset ]; then
        need "[$rule] ...as not a valid variable name" grep -q 'not a valid variable name' <<<"$OUT"
        need "[$rule] ...without echoing a value" not grep -q supersecretvalue <<<"$OUT"
      else
        need "[$rule] ...naming it and the rule" grep -q "$name is not allowed (reserved: $rule)" <<<"$OUT"
      fi
      need "[$rule] ...and nothing was launched" [ "$(launches)" = 0 ]
    else
      run VT doctor </dev/null
      need "[$rule] $name is accepted by the allowlist check" grep -q 'ok   allowlist: 1 key(s)' <<<"$OUT"
    fi
  done <<<"$ALLOW_ROWS"
  need "the table ran at least one row" [ "$n" -ge 1 ]
}
t_allowlist_lists() {  # B33: whole lists, and restart-daemon, which applies the same rules
  mkhome; mkvenv
  printf 'PATH\n' > "$E_HOME/vanth.env.allow"; run VT restart-daemon
  need "restart-daemon applies the same allowlist rules (exit 6)" [ "$RC" = 6 ]; need "...naming the rule" grep -q 'PATH is not allowed (reserved: PATH)' <<<"$OUT"
  need "...and nothing was launched" [ "$(launches)" = 0 ]
  printf '# comment\n\n  OPENROUTER_API_KEY  \nMY_OTHER_NAME\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "a valid list (comments, blanks, padding) is accepted" [ "$RC" = 0 ]
  printf 'lowercase\nPATH\nFOO=supersecretvalue\n1ABC\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "every bad line is reported, not just the first (exit 6)" [ "$RC" = 6 ]
  need "...each of the four bad lines by number" [ "$(grep -c ' line [1-4]: ' <<<"$OUT")" = 4 ]
  need "...the reserved name by name" grep -q 'PATH is not allowed (reserved: PATH)' <<<"$OUT"
  need "...and no value is shown" not grep -q supersecretvalue <<<"$OUT"
}
t_secrets() {  # B21
  local want; mkhome; mkvenv; printf 'OPENROUTER_API_KEY\n' > "$E_HOME/vanth.env.allow"
  OPENROUTER_API_KEY=sk-live-AAAA1111BBBB2222 UNLISTED_SECRET=hunter2-unlisted-ZZZ9 run VT ensure-daemon
  need "ensure-daemon succeeds" [ "$RC" = 0 ]
  want=$(printf %s sk-live-AAAA1111BBBB2222 | /usr/bin/shasum -a 256 | cut -c1-64)
  need "the allowlisted key is delivered with its correct value" grep -qx "keyhash=$want" "$E_CALLS"
  need "the daemon sees only the clean set plus the allowlisted key" \
    grep -qx 'names=AGENT_BG_HOME HOME OPENROUTER_API_KEY PATH VANTH_DAEMON_PORT VANTH_HOME VANTH_RETENTION_SECONDS ' "$E_CALLS"
  need "no secret value in the daemon's argv" not grep -qE 'sk-live|hunter2' <<<"$(/bin/ps -ww -o command= -p "$(daemon_pid)")"
  need "no secret value anywhere under the test directory (provenance, logs, state, stubs)" \
    not grep -rqF -e sk-live-AAAA1111BBBB2222 -e hunter2-unlisted-ZZZ9 "$E"
}
t_modes_env() {  # B22
  local f; mkhome; mkvenv; run VT ensure-daemon; need "clean launch succeeds" [ "$RC" = 0 ]
  need "VANTH_HOME is 0700" [ "$(stat -f %Lp "$E_VH")" = 700 ]
  for f in jobs.sqlite daemon.json token logs/daemon.log events/e.jsonl; do need "$f is 0600" [ "$(stat -f %Lp "$E_VH/$f")" = 600 ]; done
  need "VANTH_HOME, the port and retention=0 reach the daemon through env -i" \
    grep -qx "launch pid=$(daemon_pid) umask=0077 home=$E_VH port=$E_PORT retention=0" "$E_CALLS"
  need "the provenance records the daemon's pid" [ "$(prov pid)" = "$(daemon_pid)" ]
  need "...and a fresh incarnation id" [ -n "$(prov incarnation)" ]
  need "the launch's intent was retired once the daemon was proved ready" [ ! -e "$E_HOME/daemon.intent" ]
  need "...and kept as a retired record" [ "$(retired daemon.intent)" = 1 ]
}
t_provenance_refusals() {  # B22: one scenario per validity condition, the others held true so each is individually provable
  local p dp um good
  for um in 077 022; do
    mkhome; mkvenv; prestart $um || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid)
    run VT ensure-daemon; need "daemon pre-started by hand under umask $um is refused (exit 6)" [ "$RC" = 6 ]
    need "...with the restart-daemon hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
    if [ "$um" = 077 ]; then need "...because nothing proves velo-task launched it" grep -q 'not provably the one velo-task launched' <<<"$OUT"
    else need "...because its files are readable by others" grep -q 'has mode' <<<"$OUT"; fi
    need "...and left alone" alive "$p"; need "...and nothing new launched" [ "$(launches)" = 1 ]; kill "$p"
  done
  mkhome; mkvenv; prestart 077 OPENROUTER_API_KEY=inherited-secret; p=$(daemon_pid)
  run VT ensure-daemon; need "a daemon holding inherited secrets (even under umask 077) is refused" [ "$RC" = 6 ]; kill "$p"
  mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid); good="$E/prov.good"
  cp "$E_HOME/daemon.provenance" "$good"; cp "$E_VH/daemon.json" "$E/dj.good"
  dp=$(decoy veloa)   # a live process that is not the daemon
  write_prov "$dp" "$(lstart_of "$dp")" "$(sed -n 's/^digest=//p' "$good")"
  sed -i '' "s/\"started_at\":\"[^\"]*\"/\"started_at\":\"$(iso_start "$dp")\"/" "$E_VH/daemon.json"
  run VT ensure-daemon; need "provenance naming another live pid than daemon.json is rejected" [ "$RC" = 6 ]
  need "...saying so" grep -q 'daemon.json pid' <<<"$OUT"
  cp "$E/dj.good" "$E_VH/daemon.json"
  sed "s/^lstart=.*/lstart=$(shift_lstart "$(lstart_of "$p")" -2)/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a recorded start time 2 s off the live process is rejected" [ "$RC" = 6 ]
  need "...as stale provenance or a reused pid" grep -q 'reused pid' <<<"$OUT"
  sed "s/^lstart=.*/lstart=Mon Jan 1 00:00:00 2001/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "provenance left from another boot is rejected" [ "$RC" = 6 ]
  sed "s/^digest=.*/digest=$(printf '%064d' 0)/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a different launch digest (e.g. retention > 0) is rejected" [ "$RC" = 6 ]
  need "...saying digest" grep -q 'digest' <<<"$OUT"
  cp "$good" "$E_HOME/daemon.provenance"; sed -i '' 's/"started_at":"[^"]*"/"started_at":"2001-01-01T00:00:00Z"/' "$E_VH/daemon.json"
  run VT ensure-daemon; need "daemon.json started_at far from the provenance start is rejected" [ "$RC" = 6 ]
  need "...saying so" grep -q 'started_at' <<<"$OUT"
  sed 's/^incarnation=.*/incarnation=not-a-uuid/' "$good" > "$E_HOME/daemon.provenance"; cp "$E/dj.good" "$E_VH/daemon.json"
  run VT ensure-daemon; need "a provenance with a malformed incarnation is rejected (exit 6)" [ "$RC" = 6 ]
  need "...naming the incarnation" grep -q 'no valid incarnation' <<<"$OUT"
  cp "$good" "$E_HOME/daemon.provenance"; cp "$E/dj.good" "$E_VH/daemon.json"
  run VT ensure-daemon; need "control: the untouched provenance and daemon.json are adopted" [ "$RC" = 0 ]
  need "...as adopted" grep -q adopted <<<"$OUT"
  need "...and the control never launched anything" [ "$(launches)" = 1 ]
  kill "$p"
}
rec_ok() {  # <file>: a record in the format velo-task writes: pid, start time, 64-hex digest, incarnation UUID
  [ -f "$1" ] && grep -Eq '^pid=[0-9]+$' "$1" && grep -Eq '^lstart=.+$' "$1" && grep -Eq '^digest=[0-9a-f]{64}$' "$1" \
    && grep -Eq '^incarnation=[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' "$1"
}
t_crash_after_launch() {  # finding 10: killed right after vanthd was started, before anything was recorded about it
  local p; mkhome; mkvenv
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=launch.started:exit run VT ensure-daemon
  need "ensure-daemon killed after the launch exits 137" [ "$RC" = 137 ]
  waitfor 10 test -s "$E_VH/daemon.json" || { echo "FAILED: the launched daemon never came up"; exit 1; }
  p=$(daemon_pid)
  need "the daemon it launched keeps running" alive "$p"
  need "...with no intent recorded for it" [ ! -e "$E_HOME/daemon.intent" ]; need "...and no provenance" [ ! -e "$E_HOME/daemon.provenance" ]
  run VT ensure-daemon; need "the next ensure-daemon refuses to adopt it (exit 6)" [ "$RC" = 6 ]
  need "...because nothing proves velo-task launched it" grep -q 'not provably the one velo-task launched' <<<"$OUT"
  need "...and leaves it alone" alive "$p"; need "...launching nothing" [ "$(launches)" = 1 ]
  run VT restart-daemon; need "restart-daemon cannot prove it either (exit 6)" [ "$RC" = 6 ]
  need "...signals nothing" alive "$p"; need "...launches nothing" [ "$(launches)" = 1 ]
}
t_crash_after_intent() {  # finding 10: killed after the intent (launch.intent) or after readiness (launch.ready): an intent, no provenance
  local fp p p2 i1
  for fp in launch.intent launch.ready; do
    mkhome; mkvenv
    VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="$fp:exit" run VT ensure-daemon
    need "[$fp] ensure-daemon killed there exits 137" [ "$RC" = 137 ]
    waitfor 10 test -s "$E_VH/daemon.json" || { echo "FAILED: [$fp] the launched daemon never came up"; exit 1; }
    p=$(daemon_pid)
    need "[$fp] the daemon keeps running" alive "$p"
    need "[$fp] the intent is published and complete" rec_ok "$E_HOME/daemon.intent"
    need "[$fp] ...it names the daemon" [ "$(intent pid)" = "$p" ]
    need "[$fp] ...and the start time ps shows for it" [ "$(intent lstart)" = "$(lstart_of "$p")" ]
    need "[$fp] no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]
    run VT ensure-daemon
    need "[$fp] ensure-daemon refuses a daemon whose launch never completed (exit 6)" [ "$RC" = 6 ]
    need "[$fp] ...saying the launch was interrupted" grep -q 'interrupted' <<<"$OUT"
    need "[$fp] ...leaving it alone" alive "$p"; need "[$fp] ...and launching nothing" [ "$(launches)" = 1 ]
    i1=$(intent incarnation)
    run VT restart-daemon
    need "[$fp] restart-daemon may signal it: exit 0" [ "$RC" = 0 ]
    need "[$fp] ...the interrupted daemon is gone" not alive "$p"
    p2=$(daemon_pid)
    need "[$fp] ...a new daemon runs" alive "$p2"; need "[$fp] ...under a new pid" [ "$p2" != "$p" ]
    need "[$fp] ...its provenance names it" [ "$(prov pid)" = "$p2" ]; need "[$fp] ...with a fresh incarnation" [ "$(prov incarnation)" != "$i1" ]
    need "[$fp] ...the interrupted intent was retired, and so was the new launch's own" [ "$(retired daemon.intent)" = 2 ]
    need "[$fp] ...no intent is left active" [ ! -e "$E_HOME/daemon.intent" ]
    run VT ensure-daemon; need "[$fp] the new daemon is adopted" grep -q adopted <<<"$OUT"
  done
}
t_crash_in_publish() {  # R17 through a launch: killed between link and unlink inside the intent's publish
  local p; mkhome; mkvenv
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=publish.linked:exit run VT ensure-daemon
  need "a crash inside the intent's publish exits 137 (the helper's code)" [ "$RC" = 137 ]
  need "the intent name exists and is complete" rec_ok "$E_HOME/daemon.intent"
  need "...and the temp name still exists: never neither" [ -n "$(ls "$E_HOME"/daemon.intent.tmp.* 2>/dev/null)" ]
  waitfor 10 test -s "$E_VH/daemon.json" || { echo "FAILED: the launched daemon never came up"; exit 1; }
  p=$(daemon_pid)
  need "the intent names the daemon that was launched" [ "$(intent pid)" = "$p" ]
  run VT ensure-daemon; need "ensure-daemon refuses it as an interrupted launch (exit 6)" [ "$RC" = 6 ]
  need "...leaving it alone" alive "$p"
  run VT restart-daemon; need "restart-daemon recovers it (exit 0)" [ "$RC" = 0 ]
  need "...the old daemon is gone" not alive "$p"; need "...and the new one is recorded" [ "$(prov pid)" = "$(daemon_pid)" ]
}
t_crash_in_provenance_publish() {  # R17 for the provenance: killed between link and unlink inside ITS publish, after readiness
  local p; mkhome; mkvenv
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=publish.linked@daemon.provenance:exit run VT ensure-daemon
  need "a crash inside the provenance publish ends ensure-daemon with the helper's exit 137" [ "$RC" = 137 ]
  p=$(daemon_pid)
  need "the daemon it had launched keeps running" alive "$p"
  need "the published provenance is complete" rec_ok "$E_HOME/daemon.provenance"
  need "...names that daemon" [ "$(prov pid)" = "$p" ]; need "...and carries an incarnation" [ -n "$(prov incarnation)" ]
  need "...the temp name still exists: never neither" [ -n "$(ls "$E_HOME"/daemon.provenance.tmp.* 2>/dev/null)" ]
  need "the intent is still in place: it is retired only after the provenance" rec_ok "$E_HOME/daemon.intent"
  run VT ensure-daemon
  need "the next call adopts that daemon" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  need "...launching nothing" [ "$(launches)" = 1 ]; need "...and retired the leftover intent" [ ! -e "$E_HOME/daemon.intent" ]
}
t_hung_start() {  # a daemon that is alive and recorded but not listening yet: ensure-daemon never launches a second one over it
  local p; mkhome; mkvenv; echo 60 > "$E/start-delay"
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=launch.intent:exit run VT ensure-daemon
  need "killed after the intent: exit 137" [ "$RC" = 137 ]
  waitfor 10 grep -q '^launch ' "$E_CALLS" || { echo "FAILED: the starting daemon never recorded its launch"; exit 1; }
  p=$(intent pid)
  need "the starting daemon is alive" alive "$p"; need "...and does not listen yet (no daemon.json)" [ ! -e "$E_VH/daemon.json" ]
  run VT ensure-daemon
  need "ensure-daemon does not launch over a live recorded process (exit 6)" [ "$RC" = 6 ]
  need "...saying it does not answer" grep -q 'does not answer' <<<"$OUT"
  need "...no second daemon was launched" [ "$(launches)" = 1 ]; need "...and the first is untouched" alive "$p"
  rm "$E/start-delay"
  run VT restart-daemon
  need "restart-daemon stops it (no daemon.json contradicts the intent) and relaunches: exit 0" [ "$RC" = 0 ]
  need "...the hung daemon is gone" not alive "$p"
  need "...a fresh daemon is up and recorded" [ "$(prov pid)" = "$(daemon_pid)" ]
}
t_stale_intent() {  # finding 10: records of a daemon that is gone are retired and a daemon is launched
  local dead; mkhome; mkvenv
  ( exec /bin/sleep 0 ) </dev/null >/dev/null 2>&1 & dead=$!; wait "$dead" 2>/dev/null
  write_intent "$dead" 'Mon Jan 1 00:00:00 2001'; write_prov "$dead" 'Mon Jan 1 00:00:00 2001'
  run VT doctor; need "doctor reports the stale intent as such" grep -q 'intent: stale' <<<"$OUT"
  run VT ensure-daemon
  need "ensure-daemon launches over records of a dead daemon: exit 0" [ "$RC" = 0 ]; need "...as started" grep -q '(started)' <<<"$OUT"
  need "the stale intent was retired (and so was the new launch's own)" [ "$(retired daemon.intent)" = 2 ]
  need "the stale provenance was retired" [ "$(retired daemon.provenance)" = 1 ]
  need "the new provenance names the new daemon" [ "$(prov pid)" = "$(daemon_pid)" ]
}
t_adopt_retires_intent() {  # killed after the provenance was published but before the intent was retired
  local before; mkhome; mkvenv; VT ensure-daemon >/dev/null
  cp "$E_HOME/daemon.provenance" "$E_HOME/daemon.intent"; before=$(retired daemon.intent)
  run VT ensure-daemon
  need "the daemon is adopted" grep -q adopted <<<"$OUT"
  need "...and the leftover intent for it was retired" [ ! -e "$E_HOME/daemon.intent" ]; need "...exactly once" [ "$(retired daemon.intent)" = "$((before + 1))" ]
}
t_locale_fresh_shell() {  # B22: the start time is compared as rendered under LC_ALL=C TZ=UTC, whatever the caller's locale or zone
  local p; mkhome; mkvenv
  run VT ensure-daemon; need "launch" [ "$RC" = 0 ]; p=$(daemon_pid)
  need "precondition: ps renders lstart differently in another time zone" \
    [ "$(TZ=Pacific/Kiritimati /bin/ps -o lstart= -p "$p")" != "$(TZ=UTC /bin/ps -o lstart= -p "$p")" ]
  TZ=Pacific/Kiritimati run VT ensure-daemon
  need "a valid clean daemon is accepted under another time zone" [ "$RC" = 0 ]
  need "...as adopted, not relaunched" grep -q adopted <<<"$OUT"
  if [ "$(LC_ALL=fr_FR.UTF-8 TZ=UTC /bin/ps -o lstart= -p "$p")" != "$(LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$p")" ]; then
    LC_ALL=fr_FR.UTF-8 LC_TIME=fr_FR.UTF-8 LANG=de_DE.UTF-8 run VT ensure-daemon
    need "...and under another locale" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  else
    echo "note: fr_FR.UTF-8 does not change ps's rendering on this host; only the time-zone variation ran"
  fi
  OUT=$(/usr/bin/env -i HOME="$HOME" PATH="$PATH" VELO_TASK_HOME="$E_HOME" VELO_TASK_PORT="$E_PORT" /bin/bash "$R/bin/velo-task" ensure-daemon 2>&1); RC=$?
  need "...and from a fresh shell session" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  need "the same daemon throughout" [ "$(daemon_pid)" = "$p" ]; need "nothing was relaunched" [ "$(launches)" = 1 ]
}
t_modes_refuse() {  # finding 8: loose state is refused on every lifecycle call, restart included, before anything else happens
  local f p item
  mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid)
  mkdir -p -m 700 "$E_VH/logs/deep"
  for f in logs/deep/x.log jobs.sqlite-wal; do : > "$E_VH/$f"; chmod 600 "$E_VH/$f"; done
  for item in "" jobs.sqlite jobs.sqlite-wal token daemon.json logs logs/deep logs/daemon.log logs/deep/x.log events events/e.jsonl; do
    f="$E_VH${item:+/$item}"
    if [ -d "$f" ]; then chmod 755 "$f"; else chmod 644 "$f"; fi
    run VT ensure-daemon
    need "${item:-the home} loose: ensure-daemon refuses (exit 6)" [ "$RC" = 6 ]; need "...naming it" grep -qF "$f" <<<"$OUT"
    run VT restart-daemon
    need "${item:-the home} loose: restart-daemon refuses too (exit 6)" [ "$RC" = 6 ]
    need "...before signalling anything" alive "$p"; need "...or launching anything" [ "$(launches)" = 1 ]
    if [ -d "$f" ]; then chmod 700 "$f"; else chmod 600 "$f"; fi
  done
  chmod 644 "$E_HOME/daemon.launch.log"; run VT ensure-daemon
  need "a loose launch log is refused (exit 6)" [ "$RC" = 6 ]; need "...naming it" grep -q daemon.launch.log <<<"$OUT"
  run VT restart-daemon; need "...by restart-daemon too" [ "$RC" = 6 ]; need "...with the daemon left alone" alive "$p"
  chmod 600 "$E_HOME/daemon.launch.log"
  mkdir -m 000 "$E_VH/events/locked"; run VT ensure-daemon
  need "a directory the mode check cannot read is an error, never a pass (exit 6)" [ "$RC" = 6 ]; need "...saying the check itself failed" grep -q 'the mode check failed' <<<"$OUT"
  run VT restart-daemon; need "...by restart-daemon too" [ "$RC" = 6 ]; need "...with the daemon left alone" alive "$p"
  chmod 700 "$E_VH/events/locked"; rmdir "$E_VH/events/locked"
  run VT ensure-daemon; need "control: private again, the daemon is adopted" grep -q adopted <<<"$OUT"
}
t_modes_after_launch() {  # finding 8: a daemon that leaves a file readable by others despite umask 077 is caught right after the launch
  local p; mkhome; mkvenv; : > "$E/loose-file"
  run VT ensure-daemon
  need "a launch whose daemon leaves a file readable by others is refused (exit 6)" [ "$RC" = 6 ]
  need "...naming the file" grep -q 'logs/daemon.log' <<<"$OUT"
  p=$(daemon_pid)
  need "...the daemon it started is running and recorded as ours" alive "$p"; need "...in the provenance" [ "$(prov pid)" = "$p" ]
  run VT ensure-daemon; need "the next call refuses before doing anything (exit 6)" [ "$RC" = 6 ]; need "...launching nothing" [ "$(launches)" = 1 ]
}
t_concurrent_ensure() {  # B33
  local b o1 o2 n w1 w2
  mkhome; mkvenv; b="$E/barrier"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="daemon.lock.held:wait=$b" VT ensure-daemon > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: first caller never reached the barrier"; exit 1; }
  ( VT ensure-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  sleep 1; : > "$b"; wait "$w1" "$w2"   # not a bare wait: mkhome's port holder is also a child of this shell
  need "the first caller succeeds" [ "$(cat "$E/rc1")" = 0 ]
  need "the second caller succeeds" [ "$(cat "$E/rc2")" = 0 ]
  need "exactly one daemon was launched" [ "$(launches)" = 1 ]
  o1=$(cat "$E/o1"); o2=$(cat "$E/o2"); n=$(printf '%s\n%s\n' "$o1" "$o2" | grep -c started || true)
  need "one caller started the daemon" [ "$n" = 1 ]
  need "the other adopted it" grep -q adopted <<<"$o1$o2"
}
t_restart() {
  local p1 p2 i1; mkhome; mkvenv; VT ensure-daemon >/dev/null; p1=$(daemon_pid); i1=$(prov incarnation)
  OPENROUTER_API_KEY=caller-secret-9 run VT restart-daemon; need "restart-daemon exits 0" [ "$RC" = 0 ]
  p2=$(daemon_pid)
  need "the old daemon is gone" not alive "$p1"
  need "a new daemon runs" alive "$p2"; need "...under a new pid" [ "$p2" != "$p1" ]
  need "the provenance has an incarnation" [ -n "$(prov incarnation)" ]; need "...a fresh one" [ "$(prov incarnation)" != "$i1" ]
  need "the old daemon's provenance was retired, not overwritten" [ "$(retired daemon.provenance)" = 1 ]
  need "the caller's secret did not reach the new daemon" [ "$(grep -c '^keyhash=unset' "$E_CALLS")" = 2 ]
  need "restart-daemon never calls vanth restart" not grep -q '^vanth restart' "$E_CALLS"
  run VT ensure-daemon; need "the new daemon is adopted" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
}
t_restart_digest_change() {  # a daemon launched with an older configuration is replaced by restart-daemon, the recovery ensure-daemon names
  local p1 p2; mkhome; mkvenv; VT ensure-daemon >/dev/null; p1=$(daemon_pid)
  printf 'MY_NEW_KEY\n' > "$E_HOME/vanth.env.allow"
  run VT ensure-daemon
  need "the allowlist changed, so the running daemon no longer matches: ensure-daemon refuses (exit 6)" [ "$RC" = 6 ]
  need "...naming the launch digest" grep -q 'launch digest' <<<"$OUT"; need "...and restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
  need "...the old daemon is untouched" alive "$p1"
  MY_NEW_KEY=fresh-value run VT restart-daemon
  need "restart-daemon accepts a record whose digest is an older configuration's and replaces the daemon (exit 0)" [ "$RC" = 0 ]
  p2=$(daemon_pid); need "...the old daemon is gone" not alive "$p1"; need "...a new one runs" alive "$p2"
  need "...which received the newly allowlisted key" grep -q '^names=.*MY_NEW_KEY' "$E_CALLS"
  run VT ensure-daemon; need "...and is adopted by ensure-daemon" grep -q adopted <<<"$OUT"
}
t_restart_refuses_unproven() {  # findings 1, 17: restart-daemon signals only a process that a complete, matching record proves is ours
  local p dp other v ls want; mkhome; mkvenv
  prestart 077 || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid); ls=$(lstart_of "$p")
  run VT restart-daemon
  need "a real daemon with no record at all: restart-daemon refuses (exit 6)" [ "$RC" = 6 ]
  need "...saying no record proves velo-task launched it" grep -q 'no velo-task record proves' <<<"$OUT"
  need "...it was not signalled" alive "$p"; need "...nothing was launched" [ "$(launches)" = 1 ]
  for v in badstart offby2 nostart baddigest shortdigest badinc noinc nopid; do  # each record fails ONE check; $want is the reason that check gives
    case "$v" in
      badstart)    want='reused pid'; printf 'pid=%s\nlstart=Mon Jan 1 00:00:00 2001\ndigest=%s\nincarnation=%s\n' "$p" "$D64" "$UUID0" ;;
      offby2)      want='reused pid'; printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=%s\n' "$p" "$(shift_lstart "$ls" -2)" "$D64" "$UUID0" ;;
      nostart)     want='no start time'; printf 'pid=%s\ndigest=%s\nincarnation=%s\n' "$p" "$D64" "$UUID0" ;;
      baddigest)   want='no valid launch digest'; printf 'pid=%s\nlstart=%s\ndigest=abc\nincarnation=%s\n' "$p" "$ls" "$UUID0" ;;
      shortdigest) want='no valid launch digest'; printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=%s\n' "$p" "$ls" "$(printf '%063d' 7)" "$UUID0" ;;
      badinc)      want='no valid incarnation'; printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=not-a-uuid\n' "$p" "$ls" "$D64" ;;
      noinc)       want='no valid incarnation'; printf 'pid=%s\nlstart=%s\ndigest=%s\n' "$p" "$ls" "$D64" ;;
      nopid)       want='no valid pid'; printf 'lstart=%s\ndigest=%s\nincarnation=%s\n' "$ls" "$D64" "$UUID0" ;;
    esac > "$E_HOME/daemon.provenance"
    run VT restart-daemon
    need "[$v] a provenance that does not match: restart-daemon refuses (exit 6)" [ "$RC" = 6 ]
    need "[$v] ...saying which check the record failed ($want)" grep -q "$want" <<<"$OUT"
    need "[$v] ...the daemon was not signalled" alive "$p"; need "[$v] ...nothing was launched" [ "$(launches)" = 1 ]
  done
  rm "$E_HOME/daemon.provenance"; write_intent "$p" 'Mon Jan 1 00:00:00 2001'
  run VT restart-daemon; need "an intent with another start time is refused like a provenance (exit 6)" [ "$RC" = 6 ]
  need "...saying the start time is not the recorded one" grep -q 'reused pid' <<<"$OUT"
  need "...the daemon was not signalled" alive "$p"
  rm "$E_HOME/daemon.intent"
  dp=$(decoy vanthd); write_prov "$dp" "$(lstart_of "$dp")"
  run VT restart-daemon
  need "a valid record for another live process while daemon.json names this one: refused (exit 6)" [ "$RC" = 6 ]
  need "...saying daemon.json disagrees" grep -q 'daemon.json disagrees' <<<"$OUT"
  need "...neither process was signalled" alive "$p"; need "...the other process either" alive "$dp"; kill "$dp"
  rm "$E_HOME/daemon.provenance"; ( exec /bin/sleep 0 ) </dev/null >/dev/null 2>&1 & other=$!; wait "$other" 2>/dev/null
  write_prov "$other" 'Mon Jan 1 00:00:00 2001'
  run VT restart-daemon; need "a record naming a dead process while an unrelated daemon answers: refused (exit 6)" [ "$RC" = 6 ]
  need "...the daemon was not signalled" alive "$p"; need "...nothing was launched" [ "$(launches)" = 1 ]
  rm "$E_HOME/daemon.provenance"
  write_prov "$p" "$ls" "$D64" "$UUID0"
  run VT restart-daemon
  need "control: a complete record whose pid and start time match is acted on, whatever its digest (exit 0)" [ "$RC" = 0 ]
  need "...the daemon was signalled and replaced" not alive "$p"; need "...by one that is recorded" [ "$(prov pid)" = "$(daemon_pid)" ]
  mkhome; mkvenv; dp=$(decoy vanthd); write_json "$dp" 2001-01-01T00:00:00Z
  run VT restart-daemon; need "a process daemon.json names but nothing records: exit 6" [ "$RC" = 6 ]
  need "...because no record proves velo-task launched it" grep -q 'no velo-task record proves' <<<"$OUT"
  need "...not signalled" alive "$dp"; need "...nothing launched" [ "$(launches)" = 0 ]
  mkhome; mkvenv; dp=$(decoy other); write_json "$dp" "$(iso_start "$dp")"
  run VT restart-daemon; need "a process that is not a vanthd, with a plausible daemon.json: exit 6" [ "$RC" = 6 ]
  need "...because no record proves velo-task launched it" grep -q 'no velo-task record proves' <<<"$OUT"
  need "...not signalled" alive "$dp"
}
t_restart_pid_replaced() {  # finding 17: the pid the validation saw is gone by the time of the signal; whatever runs now is not signalled
  local p b by w; mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid); b="$E/barrier"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="restart.validated:wait=$b" VT restart-daemon > "$E/o" 2>&1; echo $? > "$E/rc" ) & w=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: restart never reached the barrier"; exit 1; }
  kill -9 "$p"; waitfor 5 not alive "$p" || { echo "FAILED: could not remove the validated daemon"; exit 1; }
  by=$(decoy bystander)
  : > "$b"; wait "$w"
  need "restart-daemon refuses (exit 6)" [ "$(cat "$E/rc")" = 6 ]
  need "...because the pid it validated no longer has the validated start time" grep -q "refusing to signal pid $p" "$E/o"
  need "...the process started in the meantime was not signalled" alive "$by"
  need "...and nothing was launched over the gap" [ "$(launches)" = 1 ]
}
t_signal_revalidation() {  # finding 17: signal_validated given a LIVE pid whose start time is not the validated one
  local dp; mkhome; mkvenv; dp=$(decoy vanthd)
  run /bin/bash -c '. "$1"; signal_validated TERM "$2" "$3"' x "$R/bin/velo-task-lib.sh" "$dp" 'Mon Jan 1 00:00:00 2001'
  need "a live pid with another start time than the validated one is refused (exit 6)" [ "$RC" = 6 ]
  need "...saying so" grep -q "refusing to signal pid $dp" <<<"$OUT"
  need "...and it was not signalled" alive "$dp"
  run /bin/bash -c '. "$1"; signal_validated TERM "$2" "$3"' x "$R/bin/velo-task-lib.sh" "$dp" "$(lstart_of "$dp")"
  need "control: with the right start time the signal is sent" [ "$RC" = 0 ]
  waitfor 5 not alive "$dp" || { echo "FAILED: the process did not receive SIGTERM"; exit 1; }
}
t_stop_failure() {  # R7: a bounded wait, no SIGKILL escalation, no second daemon launched over a live one
  local p; mkhome; mkvenv; : > "$E/ignore-term"; VT ensure-daemon >/dev/null; p=$(daemon_pid)
  VELO_TASK_STOP_WAIT=1 run VT restart-daemon
  need "a daemon that ignores SIGTERM: restart-daemon gives up with exit 6" [ "$RC" = 6 ]
  need "...saying it is still running" grep -q 'still running' <<<"$OUT"
  need "...leaving that daemon alone" alive "$p"
  need "...and starting no second daemon" [ "$(launches)" = 1 ]
  kill -9 "$p"
}
t_launch_failure() {
  local t0 t1; mkhome; mkvenv; : > "$E/fail-launch"
  t0=$(now); VELO_TASK_START_WAIT=5 run VT ensure-daemon; t1=$(now)
  need "a daemon that dies at start: exit 6" [ "$RC" = 6 ]; need "...saying so" grep -q 'did not become ready' <<<"$OUT"
  need "...with the launch log" grep -q 'refusing to start' <<<"$OUT"
  need "...without waiting out the whole start window" between 0 "$t0" "$t1" 3.5
  need "no provenance is written" [ ! -e "$E_HOME/daemon.provenance" ]
  need "...and no intent is left active for the daemon that died" [ ! -e "$E_HOME/daemon.intent" ]
}
t_port_collision() {  # finding 16: the daemon cannot bind because a foreign process holds the port
  local fp; mkhome; mkvenv
  kill "$E_HOLDER"; wait "$E_HOLDER" 2>/dev/null   # release the reservation, then hold the very same port as a foreign process
  "$PYBIN" "$FIX/port-holder.py" foreign "$E_PORT" "$E/fready" "$E/signals" </dev/null >/dev/null 2>&1 &
  fp=$!
  waitfor 5 test -s "$E/fready" || { echo "FAILED: the foreign listener never came up"; exit 1; }
  run VT ensure-daemon
  need "ensure-daemon fails (exit 6)" [ "$RC" = 6 ]; need "...saying the daemon did not become ready" grep -q 'did not become ready' <<<"$OUT"
  need "...with the daemon's own reason from the launch log" grep -q 'cannot bind' <<<"$OUT"
  need "no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]
  need "the intent published for the launch was retired" [ "$(retired daemon.intent)" = 1 ]; need "...and none is left active" [ ! -e "$E_HOME/daemon.intent" ]
  need "the foreign process is still alive" alive "$fp"; need "...and was never signalled" [ ! -s "$E/signals" ]
  run VT restart-daemon
  need "restart-daemon fails the same way and signals nobody (exit 6)" [ "$RC" = 6 ]
  need "...the foreign process is alive and unsignalled" alive "$fp"; need "...still no signal" [ ! -s "$E/signals" ]
}
t_launch_requires_own_pid() {  # finding 16: the daemon that answers must be the one that was launched; another one answering is not a ready launch
  local other; mkhome; mkvenv
  other=$(decoy vanthd); printf '%s\n' "$other" > "$E/forge-json"   # the fake writes a daemon.json naming this process and never listens
  VELO_TASK_START_WAIT=2 run VT ensure-daemon
  need "a launch while daemon.json names another live process never counts as ready (exit 6)" [ "$RC" = 6 ]
  need "...saying the daemon did not become ready" grep -q 'did not become ready' <<<"$OUT"
  need "no provenance was published for the launched pid" [ ! -e "$E_HOME/daemon.provenance" ]
  need "...its intent was retired" [ ! -e "$E_HOME/daemon.intent" ]; need "...kept as a retired record" [ "$(retired daemon.intent)" = 1 ]
  need "the process daemon.json names was not signalled" alive "$other"
}
t_loopback() {  # finding 7: the daemon's real listener decides, not what daemon.json says
  local p p2 digest
  mkhome; mkvenv; : > "$E/bind-all"
  run VT ensure-daemon
  need "a launch whose daemon listens on every interface is refused (exit 6)" [ "$RC" = 6 ]
  need "...naming the rule" grep -q "only 127.0.0.1:$E_PORT is allowed" <<<"$OUT"
  p=$(sed -n 's/^launch pid=\([0-9]*\) .*/\1/p' "$E_CALLS")
  need "...the daemon it launched was stopped" not alive "$p"
  need "...no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]; need "...and its intent was retired" [ ! -e "$E_HOME/daemon.intent" ]
  rm "$E/bind-all"
  run VT ensure-daemon; need "control: the same launch listening on 127.0.0.1 only is accepted (exit 0)" [ "$RC" = 0 ]
  p=$(daemon_pid); digest=$(prov digest); kill "$p"; waitfor 5 not alive "$p" || { echo "FAILED: daemon did not stop"; exit 1; }
  : > "$E/bind-all"; prestart 077 || { echo "FAILED: pre-start"; exit 1; }; p2=$(daemon_pid)
  rm -f "$E_HOME/daemon.provenance"; write_prov "$p2" "$(lstart_of "$p2")" "$digest" "$UUID0"
  run VT doctor
  need "doctor flags a daemon whose listener is not loopback" grep -q "FAIL bind: pid $p2 listens on" <<<"$OUT"
  run VT ensure-daemon
  need "a daemon with valid provenance that listens wide is not adopted (exit 6)" [ "$RC" = 6 ]
  need "...naming the rule" grep -q "only 127.0.0.1:$E_PORT is allowed" <<<"$OUT"; need "...and it was not signalled" alive "$p2"
}
t_before_install() {
  mkhome; run VT ensure-daemon; need "ensure-daemon before install-vanth exits 6" [ "$RC" = 6 ]
  need "...and says which command to run" grep -q 'velo-task install-vanth' <<<"$OUT"
}
t_doctor() {
  local p; mkhome; run VT doctor
  need "doctor without an install fails" [ "$RC" = 1 ]; need "...naming the install" grep -q 'FAIL install' <<<"$OUT"
  mkvenv; mkdb "$E/seed.sqlite"; run VT doctor
  need "doctor with an install and no daemon passes" [ "$RC" = 0 ]; need "...reporting the daemon down" grep -q 'daemon: never started' <<<"$OUT"
  VT ensure-daemon >/dev/null; run VT doctor; need "doctor with a clean daemon passes" [ "$RC" = 0 ]
  need "...checking provenance" grep -q 'provenance: valid' <<<"$OUT"
  need "...the real listener, loopback only" grep -q "bind: 127.0.0.1:$E_PORT only (listener of pid $(daemon_pid))" <<<"$OUT"
  need "...the modes" grep -q 'modes: private' <<<"$OUT"
  need "...and the schema" grep -q 'schema: matches' <<<"$OUT"
  p=$(daemon_pid); rm "$E_HOME/daemon.provenance"; run VT doctor
  need "doctor flags a daemon without provenance (exit 1)" [ "$RC" = 1 ]; need "...naming the provenance" grep -q 'FAIL provenance' <<<"$OUT"
  need "doctor is read-only: the same daemon is still running" [ "$(daemon_pid)" = "$p" ]; need "...alive" alive "$p"
  need "...and nothing was launched" [ "$(launches)" = 1 ]
  rm "$E_VH/jobs.sqlite"; mkdb "$E_VH/jobs.sqlite" ended_at; chmod 600 "$E_VH/jobs.sqlite"; run VT doctor
  need "doctor flags a database lacking a pinned column" grep -q 'FAIL schema' <<<"$OUT"
  chmod 644 "$E_VH/token"; run VT doctor; need "doctor flags a loose mode" grep -q 'FAIL modes' <<<"$OUT"; chmod 600 "$E_VH/token"
  chmod 644 "$E_VH/logs/daemon.log"; run VT doctor; need "doctor flags a loose file under logs/" grep -q 'FAIL modes' <<<"$OUT"; chmod 600 "$E_VH/logs/daemon.log"
  sed -i '' 's#http://127.0.0.1#http://0.0.0.0#' "$E_VH/daemon.json"; run VT doctor
  need "the real listener decides: a daemon.json that says 0.0.0.0 over a loopback socket is still loopback" grep -q "bind: 127.0.0.1:$E_PORT only" <<<"$OUT"
  write_intent "$p" "$(lstart_of "$p")"; run VT doctor
  need "doctor flags a live interrupted launch (exit 1)" [ "$RC" = 1 ]; need "...naming the intent" grep -q 'FAIL intent' <<<"$OUT"
}
t_doctor_readonly() {  # finding 20: doctor changes nothing, and does not need to be able to
  local before after p s; mkhome; mkvenv; mkdb "$E/seed.sqlite"; VT ensure-daemon >/dev/null; p=$(daemon_pid)
  doctor_unchanged() {  # <state label>: run doctor, compare the state dir (names, sizes, mtimes, modes) before and after
    before=$(snap_state "$E_HOME"); run VT doctor; after=$(snap_state "$E_HOME")
    need "doctor ran in the state '$1'" grep -q '^ok   install' <<<"$OUT"
    need "...and changed nothing under the state dir" [ "$before" = "$after" ]
  }
  doctor_unchanged "clean daemon"; need "...and it passed" [ "$RC" = 0 ]
  rm "$E_HOME/daemon.provenance"; doctor_unchanged "daemon without provenance"; need "...and it failed" [ "$RC" = 1 ]
  write_prov "$p" "$(lstart_of "$p")" "$D64" "$UUID0"; write_intent "$p" "$(lstart_of "$p")"; doctor_unchanged "live intent and a provenance of another configuration"
  ( exec /bin/sleep 0 ) </dev/null >/dev/null 2>&1 & s=$!; wait "$s" 2>/dev/null
  write_intent "$s" 'Mon Jan 1 00:00:00 2001'; doctor_unchanged "stale intent"
  chmod 644 "$E_VH/token"; doctor_unchanged "loose mode"; chmod 600 "$E_VH/token"
  printf 'PATH\n' > "$E_HOME/vanth.env.allow"; doctor_unchanged "rejected allowlist"; rm "$E_HOME/vanth.env.allow"
  kill "$p"; waitfor 5 not alive "$p" || { echo "FAILED: daemon did not stop"; exit 1; }
  doctor_unchanged "daemon down, records left behind"
  VT ensure-daemon >/dev/null
  chmod -R a-w "$E_HOME"; run VT doctor; s=$RC; chmod -R u+w "$E_HOME"
  need "doctor still runs on a state dir nobody can write to (exit 0)" [ "$s" = 0 ]; need "...and reports" grep -q 'provenance: valid' <<<"$OUT"
}
t_no_path_tools() {  # finding 4: no tool is looked up on the caller's PATH, so a shim in front of the system directories never runs
  local sh n; mkhome; mkuv ok; sh="$E/shims"; mkdir "$sh"
  printf '#!/bin/sh\necho "$0 $*" >> "%s/sentinel"\nexit 97\n' "$E" > "$sh/shim"; chmod +x "$sh/shim"
  for n in jq sed awk grep egrep date env ps lsof uv uuidgen shasum sort uniq tr head tail cat mktemp diff dirname basename rm mkdir chmod mv cp ln touch ls stat id uname wc cut python python3 sleep pkill pgrep find xargs tee readlink realpath bash sh; do
    ln "$sh/shim" "$sh/$n"
  done
  # PATH is only the shims directory: a tool looked up by its bare name finds a shim (which records itself) or nothing
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" PATH="$sh" run VT install-vanth
  need "install-vanth builds the venv with only shims on PATH" [ "$RC" = 0 ]
  PATH="$sh" run VT ensure-daemon; need "ensure-daemon launches with only shims on PATH" [ "$RC" = 0 ]
  PATH="$sh" run VT ensure-daemon; need "...adopts the daemon on the next call" grep -q adopted <<<"$OUT"
  PATH="$sh" run VT doctor; need "doctor runs" grep -q 'ok   provenance: valid' <<<"$OUT"
  PATH="$sh" run VT restart-daemon; need "restart-daemon replaces the daemon" [ "$RC" = 0 ]
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" PATH="$sh" run VT install-vanth; need "install-vanth on an installed venv verifies it" grep -q 'already installed' <<<"$OUT"
  OUT=$(cat "$E/sentinel" 2>/dev/null || true); need "no shim ran (the sentinel is absent)" [ ! -e "$E/sentinel" ]
  need "uv was given the fixed system PATH, not the caller's" grep -qx 'path=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$E/uv.log"
  run /usr/bin/env -i PATH="$sh" HOME="$HOME" VELO_TASK_HOME="$E_HOME" /bin/bash -c '. "$1"; resolve_uv; echo "$UV"' x "$R/bin/velo-task-lib.sh"
  need "the pinned uv is the Homebrew one even with a uv shim first on PATH" [ "$OUT" = /opt/homebrew/bin/uv ]
  need "...and the shim did not run to find out" [ ! -e "$E/sentinel" ]
}
t_uv_capability() {  # finding 4: VELO_TASK_UV is honoured only under the test capability
  local other; mkhome; mkuv ok; other="$E/other-root"; mkdir -p "$other"; printf 'another-run\n' > "$other/.velo-task-test-root"
  VELO_TASK_UV="$E/uvbin/uv" run VT install-vanth
  need "VELO_TASK_UV without VELO_TASK_TEST=1 is refused (exit 2)" [ "$RC" = 2 ]; need "...saying so" grep -q 'VELO_TASK_UV is set but refused' <<<"$OUT"
  need "...and the override never ran" [ ! -e "$E/uv.log" ]
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run /usr/bin/env -u VELO_TASK_TEST_ROOT_NONCE "$R/bin/velo-task" install-vanth
  need "VELO_TASK_TEST=1 without a nonce is refused (exit 2)" [ "$RC" = 2 ]; need "...and the override never ran" [ ! -e "$E/uv.log" ]
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" VELO_TASK_HOME="$other/home" run VT install-vanth
  need "a state dir under a marker with another nonce is refused (exit 2)" [ "$RC" = 2 ]; need "...and the override never ran" [ ! -e "$E/uv.log" ]
  installv; need "control: with the capability the override is used (exit 0)" [ "$RC" = 0 ]; need "...and it ran" [ -s "$E/uv.log" ]
}
t_fake_uv_guard() {  # finding 6: the fake uv only ever writes below its fixture root and never through a symlink
  local ext m; mkhome; mkuv ok; ext=$(mktemp -d "$T/ext.XXXXXX"); mkdir "$ext/bin"
  printf 'SENTINEL\n' > "$ext/bin/python"; chmod 755 "$ext/bin/python"
  # (a) the unmodified frontend, with a symlink where the venv goes
  ln -s "$ext" "$E_VENV"; installv
  need "install-vanth over a symlinked venv path fails (exit 1)" [ "$RC" = 1 ]; need "...the fake uv refused the symlink" grep -q 'is a symlink' <<<"$OUT"
  need "...the external file is untouched" [ "$(cat "$ext/bin/python")" = SENTINEL ]; need "...nothing was added beside it" [ "$(ls "$ext/bin")" = python ]
  need "...and the failed install removed only the symlink" [ ! -L "$E_VENV" ]; need "...not the directory it pointed at" [ -d "$ext" ]
  # (b) a mutated frontend that keeps its venv somewhere else, behind a symlink
  ln -s "$ext" "$E/linkvenv"; m="$E/mutated"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  "$PYBIN" -I - "$m/bin/velo-task-lib.sh" "$E/linkvenv" <<'PY'
import sys
path, link = sys.argv[1:3]
text = open(path).read()
old = 'VENV="$VELO_TASK_HOME/venv"'
assert text.count(old) == 1
open(path, "w").write(text.replace(old, 'VENV="%s"' % link))
PY
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run "$m/bin/velo-task" install-vanth
  need "a frontend that passes a symlinked external venv path fails (exit 1)" [ "$RC" = 1 ]; need "...the fake uv refused it" grep -q 'is a symlink' <<<"$OUT"
  need "...the external file is untouched" [ "$(cat "$ext/bin/python")" = SENTINEL ]; need "...nothing was added beside it" [ "$(ls "$ext/bin")" = python ]
  # (c) the fixture on its own: outside the root, through a symlink, onto a symlinked file
  run "$E/uvbin/uv" venv --python 3.12 "$ext/direct"
  need "a venv path outside the fixture root is refused (exit 1)" [ "$RC" = 1 ]; need "...saying so" grep -q 'outside the fixture root' <<<"$OUT"; need "...nothing was created" [ ! -e "$ext/direct" ]
  ln -s "$ext" "$E/via"; run "$E/uvbin/uv" venv --python 3.12 "$E/via/sub"
  need "a path through a symlinked directory is refused (exit 1)" [ "$RC" = 1 ]; need "...nothing was created through it" [ ! -e "$ext/sub" ]
  mkdir -p "$E/own/bin"; ln -s "$ext/bin/python" "$E/own/bin/python"; run "$E/uvbin/uv" venv --python 3.12 "$E/own"
  need "a venv whose python is a symlink is refused (exit 1)" [ "$RC" = 1 ]; need "...the file it points at is untouched" [ "$(cat "$ext/bin/python")" = SENTINEL ]
}

# ---- lifecycle interleavings (findings 3, 19): the barrier holds one caller inside the lock, the other must wait ----
t_install_concurrent() {  # two install-vanth at once build once
  local b w1 w2; mkhome; mkuv ok; b="$E/barrier"
  ( VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" VELO_TASK_FAILPOINT="install.lock.held:wait=$b" VT install-vanth > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: the first install never reached the barrier"; exit 1; }
  ( VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" VT install-vanth > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  sleep 1
  need "the second install waits for the lock while the first holds it" alive "$w2"
  need "...and nothing has been built yet" [ ! -e "$E/uv.log" ]
  : > "$b"; wait "$w1" "$w2"
  need "the first install succeeds" [ "$(cat "$E/rc1")" = 0 ]; need "the second install succeeds" [ "$(cat "$E/rc2")" = 0 ]
  need "the venv was built exactly once" [ "$(grep -c '^uv venv' "$E/uv.log")" = 1 ]
  need "the second install found it already installed" grep -q 'already installed' "$E/o2"
}
t_install_vs_ensure() {  # ensure-daemon waits while install-vanth rebuilds the venv, then starts the daemon from the rebuilt one
  local b w1 w2; mkhome; mkuv ok; installv; b="$E/barrier"
  echo stale > "$E_VENV/.velo-task-installed"   # the next install rebuilds
  ( VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" VELO_TASK_FAILPOINT="install.lock.held:wait=$b" VT install-vanth > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: the install never reached the barrier"; exit 1; }
  ( VT ensure-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  sleep 1
  need "ensure-daemon waits for the lock while the install holds it" alive "$w2"; need "...and launched nothing" [ "$(launches)" = 0 ]
  : > "$b"; wait "$w1" "$w2"
  need "the install succeeded" [ "$(cat "$E/rc1")" = 0 ]; need "...and rebuilt the venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 2 ]
  need "ensure-daemon succeeded after it" [ "$(cat "$E/rc2")" = 0 ]; need "...starting one daemon" [ "$(launches)" = 1 ]
}
t_install_vs_restart() {  # restart-daemon waits while install-vanth rebuilds the venv, then launches from the rebuilt one
  local b w1 w2; mkhome; mkuv ok; installv; b="$E/barrier"
  echo stale > "$E_VENV/.velo-task-installed"   # the next install rebuilds
  ( VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" VELO_TASK_FAILPOINT="install.lock.held:wait=$b" VT install-vanth > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: the install never reached the barrier"; exit 1; }
  ( VT restart-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  sleep 1
  need "restart-daemon waits for the lock while the install holds it" alive "$w2"; need "...and launched nothing" [ "$(launches)" = 0 ]
  : > "$b"; wait "$w1" "$w2"
  need "the install succeeded" [ "$(cat "$E/rc1")" = 0 ]; need "...and rebuilt the venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 2 ]
  need "restart-daemon succeeded after it" [ "$(cat "$E/rc2")" = 0 ]; need "...launching one daemon from the rebuilt venv" [ "$(launches)" = 1 ]
  need "...and the provenance names it" [ "$(prov pid)" = "$(daemon_pid)" ]
}
t_restart_vs_ensure() {  # ensure-daemon waits while restart-daemon replaces the daemon, then adopts the new one
  local p1 b w1 w2; mkhome; mkvenv; VT ensure-daemon >/dev/null; p1=$(daemon_pid); b="$E/barrier"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="daemon.lock.held:wait=$b" VT restart-daemon > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  waitfor 10 test -e "$b.reached" || { echo "FAILED: restart never reached the barrier"; exit 1; }
  ( VT ensure-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  sleep 1
  need "ensure-daemon waits for the lock while restart-daemon holds it" alive "$w2"
  need "...the old daemon is untouched meanwhile" alive "$p1"; need "...and nothing new was launched" [ "$(launches)" = 1 ]
  : > "$b"; wait "$w1" "$w2"
  need "restart-daemon succeeded" [ "$(cat "$E/rc1")" = 0 ]; need "...replacing the daemon" not alive "$p1"
  need "ensure-daemon succeeded" [ "$(cat "$E/rc2")" = 0 ]; need "...by adopting the restarted daemon" grep -q adopted "$E/o2"
  need "...so there were exactly two launches in all" [ "$(launches)" = 2 ]; need "...and the provenance names the daemon that runs" [ "$(prov pid)" = "$(daemon_pid)" ]
}

# ---- install-vanth (offline, fake uv) and the lock --------------------------------------------------
t_install_flags() {  # B23
  mkhome; mkuv ok; installv
  need "install-vanth succeeds" [ "$RC" = 0 ]
  need "the venv is built with CPython 3.12 under VELO_TASK_HOME/venv" grep -qE "^uv venv .*--python 3\.12 .*$E_VENV\$" "$E/uv.log"
  need "install passes --require-hashes" grep -qE '^uv pip install .*--require-hashes' "$E/uv.log"
  need "install passes --only-binary :all:" grep -qE '^uv pip install .*--only-binary :all:' "$E/uv.log"
  need "install reads the lock file" grep -qE '^uv pip install .* -r .*requirements/vanth\.lock$' "$E/uv.log"
  need "install uses PyPI only" grep -q -- '--default-index https://pypi.org/simple' "$E/uv.log"
  need "the marker is the lock's SHA-256 (checked with shasum)" [ "$(cat "$E_VENV/.velo-task-installed")" = "$(/usr/bin/shasum -a 256 "$R/requirements/vanth.lock" | cut -d' ' -f1)" ]
  need "Vanth's setup command is never run" not grep -q '^vanth setup' "$E_CALLS"
  need "uv runs with the fixed system PATH, whatever the caller's" grep -qx 'path=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$E/uv.log"
}
t_install_asserts() {  # R8, R12
  local v
  for v in noreason nocolumn extra missing; do
    mkhome; mkuv $v; installv
    need "variant $v: install-vanth fails" [ "$RC" = 1 ]; need "...and removes the venv" [ ! -e "$E_VENV" ]
    need "...and leaves no install marker" [ ! -e "$E_VENV/.velo-task-installed" ]
  done
  mkhome; mkuv noreason; installv; need "a missing trigger-parent reason is named" grep -q 'trigger-parent stop reason' <<<"$OUT"
  mkhome; mkuv nocolumn; installv; need "a missing column is named" grep -q 'schema lacks columns' <<<"$OUT"
  mkhome; mkuv extra; installv; need "an extra distribution is reported as a difference from the lock" grep -q 'differ from the lock' <<<"$OUT"
}
t_install_idempotent() {
  local m; mkhome; mkuv ok; installv; installv
  need "a second run succeeds" [ "$RC" = 0 ]; need "...reporting already installed" grep -q 'already installed' <<<"$OUT"
  need "...without building another venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 1 ]
  m="$T/lockchange"; rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"; echo '# reviewed upgrade' >> "$m/requirements/vanth.lock"
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run "$m/bin/velo-task" install-vanth
  need "a changed lock installs again" [ "$RC" = 0 ]; need "...by building a new venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 2 ]
}
t_install_refuses_under_daemon() {
  mkhome; mkuv ok; installv; mkvenv; VT ensure-daemon >/dev/null; echo 'stale' > "$E_VENV/.velo-task-installed"
  : > "$E/uv.log"; installv
  need "reinstalling over a running daemon exits 6" [ "$RC" = 6 ]; need "...saying so" grep -q 'daemon is running' <<<"$OUT"
  need "...and builds nothing" [ ! -s "$E/uv.log" ]
}
t_install_failure_under_daemon() {  # a failed verification must not delete the venv a live daemon is running from
  mkhome; mkuv ok; installv; mkvenv; VT ensure-daemon >/dev/null
  mkuv extra; installv   # the next verification finds a distribution the lock does not have
  need "a failed verification under a running daemon exits 6" [ "$RC" = 6 ]
  need "...saying the venv was left in place" grep -q 'left in place' <<<"$OUT"
  need "...keeping the venv" [ -x "$E_VENV/bin/vanthd" ]
  need "...and the daemon" alive "$(daemon_pid)"
}
t_venv_in_use() {  # finding 3: install-vanth never replaces a venv a daemon runs from, however that daemon came to run
  local p
  # (a) started by hand: no record names it; daemon.json's pid runs a command from the venv
  mkhome; mkuv ok; installv; echo stale > "$E_VENV/.velo-task-installed"
  prestart 077 || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid); : > "$E/uv.log"
  installv
  need "a hand-started daemon running from the venv keeps install-vanth from replacing it (exit 6)" [ "$RC" = 6 ]
  need "...saying a daemon is running" grep -q 'daemon is running' <<<"$OUT"
  need "...nothing was built" [ ! -s "$E/uv.log" ]; need "...and the daemon runs on" alive "$p"; kill "$p"
  # (b) launched by velo-task and not listening yet: no daemon.json, only its intent says it exists
  mkhome; mkuv ok; installv; echo 60 > "$E/start-delay"
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=launch.intent:exit run VT ensure-daemon
  need "(setup) ensure-daemon killed right after recording its intent" [ "$RC" = 137 ]
  p=$(intent pid); echo stale > "$E_VENV/.velo-task-installed"; : > "$E/uv.log"
  installv
  need "a recorded daemon that does not answer yet keeps install-vanth from replacing the venv (exit 6)" [ "$RC" = 6 ]
  need "...nothing was built" [ ! -s "$E/uv.log" ]; need "...and the daemon runs on" alive "$p"; kill "$p"
}
norm_freeze() { awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' | LC_ALL=C sort -u; }
lock_problems() {  # <lock>: what is wrong with it as a hash-locked requirements file of WHEELS for CPython 3.12 on macOS arm64, read offline
  "$PYBIN" -I - "$1" <<'PY'
import re
import sys

REQ = re.compile(r"^([A-Za-z0-9._-]+)==([0-9A-Za-z.+!_-]+) \\$")
HASH = re.compile(r"^    --hash=sha256:[0-9a-f]{64}  # wheel: (\S+)$")
WHEEL = re.compile(r"^(?P<dist>[A-Za-z0-9_.]+)-(?P<ver>[A-Za-z0-9_.!+]+)(-[0-9][A-Za-z0-9_.]*)?-(?P<py>[A-Za-z0-9_.]+)-(?P<abi>[A-Za-z0-9_.]+)-(?P<plat>[A-Za-z0-9_.]+)\.whl$")
MAC = re.compile(r"^macosx_(\d+)_(\d+)_(arm64|universal2)$")


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def interpreter_ok(py, abi):  # CPython 3.12: pure-Python tags, abi3 wheels of 3.2..3.12, and the cp312 wheel itself
    m = re.match(r"^(py|cp)3(\d*)$", py)
    if not m:
        return False
    minor = int(m.group(2)) if m.group(2) else 0
    if py.startswith("py"):
        return abi == "none" and minor <= 12
    return minor <= 12 and (abi == "abi3" or (abi == "cp3%d" % minor and minor == 12) or abi == "none")


def platform_ok(plat):
    if plat == "any":
        return True
    m = MAC.match(plat)
    return bool(m) and 10 <= int(m.group(1)) <= 26


def wheel_problem(req, ver, wheel):
    m = WHEEL.match(wheel)
    if not m:
        return "%s: %r is not a wheel file name" % (req, wheel)
    if norm(m.group("dist")) != norm(req) or m.group("ver") != ver:
        return "%s: wheel %s is for another distribution or version" % (req, wheel)
    if not any(interpreter_ok(p, a) for p in m.group("py").split(".") for a in m.group("abi").split(".")):
        return "%s: wheel %s does not install on CPython 3.12" % (req, wheel)
    if not any(platform_ok(p) for p in m.group("plat").split(".")):
        return "%s: wheel %s does not install on macOS arm64" % (req, wheel)
    return None


problems, cur, hashes = [], None, 0


def close():
    if cur and hashes != 1:
        problems.append("%s: %d hash lines, want exactly 1" % (cur[0], hashes))


for line in open(sys.argv[1]).read().split("\n"):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    req = REQ.match(line)
    if req:
        close()
        cur, hashes = (req.group(1), req.group(2)), 0
        continue
    h = HASH.match(line)
    if h and cur:
        hashes += 1
        p = wheel_problem(cur[0], cur[1], h.group(1))
        if p:
            problems.append(p)
        continue
    problems.append("unexpected line (a hash line must end with '# wheel: <file>.whl'): %s" % line)
close()
print("\n".join(problems))
PY
}
t_lock_file() {  # B23, findings 12, 13: pinned, hashed, WHEELS ONLY; the artifact types are checked offline from the `# wheel:` comments
  local lock="$R/requirements/vanth.lock" bad n f d w
  bad=$(lock_problems "$lock")
  OUT=$bad; need "every requirement is pinned (==) with exactly one sha256 hash, and each hash names a wheel that installs on CPython 3.12 / macOS arm64" [ -z "$bad" ]
  need "...every hash line carries its wheel comment" [ "$(grep -c -- '--hash=sha256:' "$lock")" = "$(grep -c -- '  # wheel: .*\.whl$' "$lock")" ]
  d=$(mktemp -d "$T/lk.XXXXXX")
  seed() { printf 'foo==1.0 \\\n    --hash=sha256:%s  # wheel: %s\n' "$(printf '%064d' 1)" "$1" > "$d/seed.lock"; lock_problems "$d/seed.lock"; }
  for w in foo-1.0-py3-none-any.whl foo-1.0-cp312-cp312-macosx_11_0_arm64.whl foo-1.0-cp311-abi3-macosx_11_0_arm64.whl foo-1.0-py3-none-macosx_11_0_arm64.whl \
      foo-1.0-py2.py3-none-any.whl foo-1.0-cp39-abi3-macosx_10_9_universal2.whl foo-1.0-py3-none-macosx_10_9_x86_64.macosx_11_0_arm64.whl Foo-1.0-py3-none-any.whl; do
    OUT=$(seed "$w"); need "the validator accepts $w" [ -z "$OUT" ]
  done
  for w in foo-1.0.tar.gz foo-1.0.zip foo-1.0-py3-none-manylinux_2_17_aarch64.whl foo-1.0-cp312-cp312-macosx_10_9_x86_64.whl foo-1.0-cp313-cp313-macosx_11_0_arm64.whl \
      foo-1.0-cp310-cp310-macosx_11_0_arm64.whl foo-1.0-cp313-abi3-macosx_11_0_arm64.whl foo-1.0-py3-none-win_amd64.whl foo-1.0-py3-none-musllinux_1_2_aarch64.whl \
      foo-1.0-py2-none-any.whl bar-1.0-py3-none-any.whl foo-2.0-py3-none-any.whl foo-1.0-pp310-pypy310_pp73-macosx_11_0_arm64.whl; do
    OUT=$(seed "$w"); need "the validator flags $w" [ -n "$OUT" ]
  done
  printf 'foo==1.0 \\\n    --hash=sha256:%s\n' "$(printf '%064d' 1)" > "$d/nocomment.lock"
  OUT=$(lock_problems "$d/nocomment.lock"); need "the validator flags a hash line without a wheel comment (an sdist hash looks like this)" [ -n "$OUT" ]
  printf 'foo==1.0 \\\n    --hash=sha256:%s  # wheel: foo-1.0-py3-none-any.whl\n    --hash=sha256:%s  # wheel: foo-1.0-py3-none-any.whl\n' "$(printf '%064d' 1)" "$(printf '%064d' 2)" > "$d/two.lock"
  OUT=$(lock_problems "$d/two.lock"); need "the validator flags two hashes for one requirement" [ -n "$OUT" ]
  printf 'foo==1.0 \\\nbar==2.0 \\\n    --hash=sha256:%s  # wheel: bar-2.0-py3-none-any.whl\n' "$(printf '%064d' 1)" > "$d/none.lock"
  OUT=$(lock_problems "$d/none.lock"); need "the validator flags a requirement with no hash" [ -n "$OUT" ]
  n=$(grep -cE '^[A-Za-z0-9._-]+==' "$lock"); need "the full tree is locked (at least 25 distributions)" [ "$n" -ge 25 ]
  need "vanth 1.14.0 is the pinned version" grep -q '^vanth==1\.14\.0 ' "$lock"
  need "no index, URL, VCS or editable directive" not grep -qE '(^|[[:space:]])(-e|--index-url|--extra-index-url|-f|--find-links|--no-binary)|://|git\+' <(grep -v '^[[:space:]]*#' "$lock")
  for f in '--generate-hashes' '--only-binary :all:' '--python-version 3.12' '--python-platform aarch64-apple-darwin'; do
    need "the lock header records how it was compiled: $f" grep -qF -e "$f" <(sed -n 2p "$lock")
  done
  need "no script runs Vanth's setup command" [ "$(grep -cE '(vanth|VANTH)"?[[:space:]]+setup' "$R"/bin/velo-task* | awk -F: '{s += $NF} END {print s}')" = 0 ]
  need "no script writes ~/.claude.json or registers an MCP server" [ "$(grep -ciE 'claude\.json|claude mcp|mcp add' "$R"/bin/velo-task* | awk -F: '{s += $NF} END {print s}')" = 0 ]
}
t_lock_closure() {  # finding 21: the fake install's expected distributions come from a checked-in list, never from the lock
  local closure="$HERE/fixtures/vanth-closure.txt" m
  need "the lock pins exactly the distributions of the checked-in closure list (name==version, normalized)" \
    [ "$(sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$R/requirements/vanth.lock" | norm_freeze)" = "$(norm_freeze < "$closure")" ]
  need "the closure list has the full tree (at least 25 distributions)" [ "$(grep -c '==' "$closure")" -ge 25 ]
  mkhome; mkuv ok; m="$E/gainlock"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  printf 'zzz-extra==1.0 \\\n    --hash=sha256:%s  # wheel: zzz_extra-1.0-py3-none-any.whl\n' "$(printf '%064d' 3)" >> "$m/requirements/vanth.lock"
  VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run "$m/bin/velo-task" install-vanth
  need "a lock that gains a distribution the closure list lacks fails the install: the fake does not follow the lock (exit 1)" [ "$RC" = 1 ]
  need "...as a difference from the lock" grep -q 'differ from the lock' <<<"$OUT"
}
t_install_ships_lock() {  # production wiring: the installed bin/velo-task resolves ../requirements/vanth.lock, so install.sh must ship it
  local s="$T/inst-src" dest="$T/inst-dest" skills="$T/inst-skills"; rm -rf "$s" "$dest" "$skills"; mkdir -p "$s/bin" "$s/requirements"
  cp "$R/install.sh" "$s/install.sh"; cp "$R/bin/velo-task" "$R/bin/velo-task-lib.sh" "$R/bin/velo-task-state" "$s/bin/"; cp "$R/requirements/vanth.lock" "$s/requirements/"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh"
  need "install.sh succeeds" [ "$RC" = 0 ]
  need "the library velo-task sources is installed beside it" [ -f "$dest/bin/velo-task-lib.sh" ]
  mkhome; mkuv ok; VELO_TASK_TEST=1 VELO_TASK_UV="$E/uvbin/uv" run "$dest/bin/velo-task" install-vanth
  need "the installed velo-task finds its library and its lock and installs from it" [ "$RC" = 0 ]
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check sees no drift right after an install" [ "$RC" = 0 ]
  echo '# edited in place' >> "$dest/requirements/vanth.lock"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check reports a hand-edited installed lock as drift" [ "$RC" != 0 ]
}

# ---- the real thing, once: VELO_TASK_NETWORK_TESTS=1 ------------------------------------------------
t_network() {  # the real Vanth from PyPI and a real vanthd on a random port in a temp home: never the live state, never 48217
  local p pid2 m f l envs
  # HOME is the suite's temp home and PATH the system directories, so nothing below can read or write the user's real
  # configuration; uv's cache and its CPython download live in the temp tree too.
  export VELO_TASK_START_WAIT=60 UV_CACHE_DIR="$T/uv-cache" UV_PYTHON_INSTALL_DIR="$T/uv-python"
  mkhome; run VT install-vanth
  need "real install-vanth succeeds" [ "$RC" = 0 ]; echo "note: $(tail -n 1 <<<"$OUT")"
  need "the installed set equals the lock set (uv pip freeze vs the lock: none extra, none missing)" \
    [ "$(/opt/homebrew/bin/uv pip freeze --no-config --python "$E_VENV/bin/python" | norm_freeze)" = "$(sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$R/requirements/vanth.lock" | norm_freeze)" ]
  need "...and equals the checked-in closure list" \
    [ "$(/opt/homebrew/bin/uv pip freeze --no-config --python "$E_VENV/bin/python" | norm_freeze)" = "$(norm_freeze < "$HERE/fixtures/vanth-closure.txt")" ]
  m="$T/net-tamper"; rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  sed -i '' -E "s/--hash=sha256:[0-9a-f]+/--hash=sha256:$(printf '%064d' 0)/" "$m/requirements/vanth.lock"
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a lock whose hashes do not match the wheels fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: tampered hashes: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  sed -i '' 's/^vanth==1\.14\.0 /vanth==1.13.0 /' "$m/requirements/vanth.lock"
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a different Vanth version than the locked hashes fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: wrong version: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  awk '/^starlette==/ { skip = 1; next } /^[A-Za-z0-9._-]+==/ { skip = 0 } !skip' "$R/requirements/vanth.lock" > "$m/requirements/vanth.lock"
  need "precondition: the doctored lock really lost starlette" [ "$(grep -c '^starlette==' "$m/requirements/vanth.lock")" = 0 ]
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a lock missing one transitive dependency fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: lock without starlette: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  mkhome; run VT install-vanth; need "install-vanth in a fresh home works again" [ "$RC" = 0 ]
  # The port reservation lets the fake vanthd bind beside it (SO_REUSEPORT); the real vanthd does not set that, so the
  # reservation is released right before it binds. A foreign process that took the port meanwhile fails the start, loudly.
  kill "$E_HOLDER"; wait "$E_HOLDER" 2>/dev/null
  run VT ensure-daemon; need "the real daemon starts" [ "$RC" = 0 ]; need "...as started" grep -q started <<<"$OUT"; echo "note: $OUT"
  p=$(daemon_pid)
  need "VANTH_HOME is 0700" [ "$(stat -f %Lp "$E_VH")" = 700 ]
  for f in daemon.json token jobs.sqlite; do need "$f is 0600" [ "$(stat -f %Lp "$E_VH/$f")" = 600 ]; done
  need "no file under logs/ or events/ is group- or world-accessible" [ -z "$(find "$E_VH/logs" "$E_VH/events" -type f -perm +077)" ]
  need "the daemon listens on 127.0.0.1 only (lsof)" \
    [ "$(/usr/sbin/lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN -Fn | grep '^n' | sort -u)" = "n127.0.0.1:$E_PORT" ]
  run VT ensure-daemon; need "the running daemon is adopted" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  run VT doctor; need "doctor is green against the real daemon" [ "$RC" = 0 ]
  while IFS= read -r l; do echo "note: doctor: $l"; done <<<"$OUT"
  OPENROUTER_API_KEY=caller-secret run VT restart-daemon; need "restart-daemon replaces the real daemon" [ "$RC" = 0 ]
  pid2=$(daemon_pid); need "...under a new pid" [ "$pid2" != "$p" ]; need "...the old one is gone" not alive "$p"
  envs=$(/bin/ps -ww -E -o command= -p "$pid2" 2>/dev/null)
  need "control: ps -E shows the new daemon's environment" grep -q 'VANTH_RETENTION_SECONDS=0' <<<"$envs"
  need "...which lacks the caller's secret" not grep -q caller-secret <<<"$envs"
  kill "$pid2"; waitfor 10 not alive "$pid2"
}

t_real_home_untouched() {  # finding 15: nothing this suite ran touched the real home (snapshotted before HOME was switched)
  need "the real ~/.agents/state and ~/.config are as they were (mtime, size), and no velo-task or vanth dir appeared" [ "$(snap_home)" = "$HOME_BEFORE" ]
  need "...and ~/.claude.json gained no vanth or velo-task entry" [ "$(claude_json_marks)" -le "$MARKS_BEFORE" ]
  need "...and the suite's HOME was the temp one throughout" [ "$HOME" = "$SUITE_HOME" ]
  need "...and its PATH was the system directories only (no Homebrew, no user bin, no shims left behind)" [ "$PATH" = /usr/bin:/bin:/usr/sbin:/sbin ]
}
# The check above compares the real home. A production write to the real home cannot be provoked from a proof, so the same
# check runs against a stand-in home (REAL_HOME, HOME_BEFORE and MARKS_BEFORE re-pointed in a subshell) that is then disturbed.
stand_in_home() {
  REAL_HOME="$T/stand-in-home"; rm -rf "$REAL_HOME"; mkdir -p "$REAL_HOME/.agents/state" "$REAL_HOME/.config"; printf '{}\n' > "$REAL_HOME/.claude.json"
  HOME_BEFORE=$(snap_home); MARKS_BEFORE=$(claude_json_marks)
}
t_stand_in_untouched() { stand_in_home; t_real_home_untouched; }
stray_velo_task_dir() { stand_in_home; mkdir "$REAL_HOME/.agents/state/velo-task"; t_real_home_untouched; }
stray_vanth_dir() { stand_in_home; mkdir "$REAL_HOME/.agents/state/vanth"; t_real_home_untouched; }
stray_state_touch() { stand_in_home; touch -t 200001010000 "$REAL_HOME/.agents/state"; t_real_home_untouched; }
stray_config_touch() { stand_in_home; touch -t 200001010000 "$REAL_HOME/.config"; t_real_home_untouched; }
stray_mcp_entry() { stand_in_home; printf '{"mcpServers":{"vanth":{}}}\n' > "$REAL_HOME/.claude.json"; t_real_home_untouched; }
stray_real_home_env() { stand_in_home; HOME="$REAL_HOME"; t_real_home_untouched; }
stray_homebrew_path() { stand_in_home; PATH="/opt/homebrew/bin:$PATH"; t_real_home_untouched; }

# ---- run -------------------------------------------------------------------------------------------
echo "velo-task M1: state helper"
check "fp: row fingerprint vectors" t_fp
check "sha256: stdin and file" t_sha256
check "publish: no-clobber, crash leaves both names, fsync order file/link/dest dir/unlink/temp dir" t_publish
check "retire: durable rename to <name>.retired.<epoch>, never replaces" t_retire
check "append-index: O_APPEND whole lines, 0600, id charset, fsync order" t_append_index
check "lock: exclusive, bounded wait, released by process death" t_lock
check "lock-held: sees a holder, never creates or steals the lock" t_lock_held
check "json-get: jq-style values, missing is empty, malformed is an error" t_json_get
check "modes-check: home, jobs.sqlite*, token, daemon.json, launch log, logs/ and events/ recursively" t_modes_check
check "redact: R23(d) fixtures, error prints nothing" t_redact
check "jobs-ro: read-only by authorizer (no ATTACH, DDL, DML, PRAGMA writes), 2000 ms lock wait, schema exit 5" t_jobs_ro
check "failpoints and seams: root marker + nonce capability, hostile TMPDIR refused (R21)" t_failpoint_gating
echo "velo-task M1: front end"
check "B14: bash 3.2, no bash-4 constructs, seeded declare -A fails both" t_b14
check "other subcommands exit 2 (not implemented in M1)" t_unimplemented
check "every _-prefixed name and every library function is rejected by the public parser" t_private_subcommands
check "a locked body run without the lock refuses" t_lock_bypass
check "B33: allowlist table, one row per rule of R11, never echoes values" t_allowlist_rejects
check "B33: whole allowlists, every bad line reported, restart-daemon applies the same rules" t_allowlist_lists
check "B21: allowlisted key delivered, nothing else inherited, no secret at rest" t_secrets
check "B22: modes 0700/0600, env -i keeps VANTH_HOME and port, intent retired" t_modes_env
check "B22: daemons without valid provenance are refused" t_provenance_refusals
check "B22: accepted under another locale, TZ and a fresh shell" t_locale_fresh_shell
check "loose state is refused before any other action, restart-daemon included" t_modes_refuse
check "a daemon that leaves a readable file is caught right after the launch" t_modes_after_launch
check "B33: two concurrent ensure-daemon start one daemon" t_concurrent_ensure
check "restart-daemon: SIGTERM, clean env, fresh incarnation, no vanth restart" t_restart
check "restart-daemon replaces a daemon launched with an older configuration" t_restart_digest_change
check "restart-daemon: stop is bounded, no SIGKILL, no second daemon" t_stop_failure
check "restart-daemon signals only a process a complete, matching record proves is ours" t_restart_refuses_unproven
check "restart-daemon: a pid that is gone before the signal is not replaced by a signal to whatever runs now" t_restart_pid_replaced
check "signal_validated refuses a live pid whose start time is not the validated one" t_signal_revalidation
check "a daemon that dies at start is reported fast with its log" t_launch_failure
check "a foreign process on the port: no provenance, intent retired, nothing signalled" t_port_collision
check "another process answering is not a ready launch" t_launch_requires_own_pid
check "the daemon's real listener must be 127.0.0.1 only, at launch, at adoption and in doctor" t_loopback
check "crash after launch: nothing recorded, never adopted, never signalled" t_crash_after_launch
check "crash after the intent or after readiness: restart-daemon recovers, ensure-daemon refuses" t_crash_after_intent
check "crash inside the intent's publish leaves both names" t_crash_in_publish
check "crash inside the provenance's publish leaves both names and the next call adopts" t_crash_in_provenance_publish
check "a recorded daemon that is not listening is never launched over" t_hung_start
check "records of a dead daemon are retired and the daemon is launched" t_stale_intent
check "a leftover intent for an adopted daemon is retired" t_adopt_retires_intent
check "ensure-daemon before install-vanth says what to run" t_before_install
check "doctor: report on install, allowlist, provenance, real listener, modes, intent, schema" t_doctor
check "doctor is read-only: state dir identical before and after, and runs on a write-denied state dir" t_doctor_readonly
check "no caller-PATH tool is ever executed: shims first on PATH stay unrun" t_no_path_tools
check "VELO_TASK_UV is refused without the test capability" t_uv_capability
check "the fake uv never writes outside its root or through a symlink" t_fake_uv_guard
check "two install-vanth at once build once" t_install_concurrent
check "ensure-daemon waits for an install-vanth that holds the lock" t_install_vs_ensure
check "restart-daemon waits for an install-vanth that holds the lock" t_install_vs_restart
check "ensure-daemon waits for a restart-daemon that holds the lock" t_restart_vs_ensure
echo "velo-task M1: install and lock"
check "B23: install passes --require-hashes --only-binary :all: -r lock, PyPI only, fixed PATH" t_install_flags
check "install-vanth asserts reason string, columns, installed set == lock" t_install_asserts
check "install-vanth is idempotent and rebuilds on a changed lock" t_install_idempotent
check "install-vanth never replaces a venv under a running daemon" t_install_refuses_under_daemon
check "install-vanth keeps the venv under a running daemon even when verification fails" t_install_failure_under_daemon
check "install-vanth sees a daemon that runs from the venv: hand-started, or recorded and not yet listening" t_venv_in_use
check "B23: the lock is hashed, pinned and WHEELS ONLY (offline artifact-type check)" t_lock_file
check "the lock's pinned set equals the checked-in closure list, and the fake install does not follow the lock" t_lock_closure
check "install.sh ships requirements/ and the library beside bin/" t_install_ships_lock

echo "velo-task M1: mutation proofs (each check must go red on a mutated copy)"
V=bin/velo-task; L=bin/velo-task-lib.sh; S=bin/velo-task-state
# The lock, taken away: run_locked starts the body without the helper's lock, and assert_lock_held no longer asks whether it is held.
NOLOCK_RUN=$'  stl lock --timeout "${VELO_TASK_LOCK_WAIT:-60}" "$LOCK_FILE" -- \\\n    /bin/bash -c'
NOLOCK_ASSERT='  [ "${1:-}" = "$LOCK_FILE" ] && stl lock-held "$LOCK_FILE" \'

# ---- the state helper ----
prove "fp ignores the last field" t_fp $S 'row = "|".join(args).encode(' 'row = "|".join(args[:4]).encode('
prove "sha256 truncated" t_sha256 $S 'print(hashlib.sha256(data).hexdigest())' 'print(hashlib.sha256(data).hexdigest()[:16])'
prove "publish replaces an existing name" t_publish $S '        os.link(src, dest)' '        os.replace(src, dest); os.link(dest, src)'
prove "publish does not fsync the temp before linking" t_publish $S $'    _sync_path(src, "file")\n    trace("link", src, dest)' '    trace("link", src, dest)'
prove "publish does not fsync the destination directory" t_publish $S $'    _sync_path(os.path.dirname(dest), "dir")\n    trace("unlink", src)' '    trace("unlink", src)'
prove "publish unlinks the temp before fsyncing the destination directory" t_publish $S \
  $'    _sync_path(os.path.dirname(dest), "dir")\n    trace("unlink", src)\n    os.unlink(src)\n' \
  $'    trace("unlink", src)\n    os.unlink(src)\n    _sync_path(os.path.dirname(dest), "dir")\n'
prove "publish does not fsync the temp's directory" t_publish $S $'    os.unlink(src)\n    _sync_path(os.path.dirname(src), "dir")\n    return True' $'    os.unlink(src)\n    return True'
prove "a refused publish does not remove its temp durably" t_publish $S \
  $'        trace("unlink", src)\n        os.unlink(src)\n        _sync_path(os.path.dirname(src), "dir")\n        return False' '        return False'
prove "publish unlinks the temp before the crash point" t_publish $S \
  $'    failpoint("publish.linked", dest)\n    _sync_path(os.path.dirname(dest), "dir")\n    trace("unlink", src)\n    os.unlink(src)\n' \
  $'    _sync_path(os.path.dirname(dest), "dir")\n    trace("unlink", src)\n    os.unlink(src)\n    failpoint("publish.linked", dest)\n'
prove "retire replaces a record already retired under that name" t_retire $S $'    while os.path.lexists(target):\n        n += 1\n        target = "%s.%d" % (base, n)\n' ''
prove "retire does not fsync the directory" t_retire $S $'    os.rename(path, target)\n    _sync_path(os.path.dirname(path), "dir")\n' $'    os.rename(path, target)\n'
prove "retire of a path that does not exist succeeds" t_retire $S '        die(1, "retire: %s does not exist" % path)' '        return 0'
prove "retire links instead of renaming" t_retire $S '    os.rename(path, target)' '    os.link(path, target)'
prove "append-index without O_APPEND on the existing-file path" t_append_index $S 'fd = os.open(path, os.O_WRONLY | os.O_APPEND)' 'fd = os.open(path, os.O_WRONLY)'
prove "append-index accepts a trailing newline (the anchored regex used with match)" t_append_index $S '    if not JOB_ID.fullmatch(job_id):' '    if not re.match(r"^[A-Za-z0-9_-]+$", job_id):'
prove "append-index does not fsync the file" t_append_index $S $'        _sync_fd(fd, "file", path)\n' ''
prove "append-index does not fsync the directory of a file it created" t_append_index $S '    if created:' '    if False:'
prove "append-index fsyncs the directory on every append" t_append_index $S '    if created:' '    if True:'
prove "lock never takes the flock" t_lock $S $'            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n            break' '            break'
prove "the lock fd leaks into the command" t_lock $S 'proc = subprocess.Popen(cmd)' 'proc = subprocess.Popen(cmd, pass_fds=(fd,))'
prove "lock returns 0 whatever the command returned" t_lock $S 'return rc if rc >= 0 else 128 - rc' 'return 0'
prove "a lock wait that times out does not exit 75" t_lock $S 'die(75, "lock %s: not acquired within %ss" % (path, timeout))' 'die(1, "lock %s: not acquired within %ss" % (path, timeout))'
prove "lock-held creates the lock file" t_lock_held $S 'fd = os.open(args[0], os.O_RDWR)  # never creates the lock file' 'fd = os.open(args[0], os.O_RDWR | os.O_CREAT, 0o600)'
prove "lock-held reports a held lock as free" t_lock_held $S $'            if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):\n                return 0' $'            if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):\n                return 1'
prove "json-get prints Python booleans" t_json_get $S 'print("true" if value else "false")' 'print(value)'
prove "json-get prints a missing key as null" t_json_get $S $'    if value is None:\n        return 0\n' ''
prove "json-get reads a malformed file as empty" t_json_get $S '    doc = json.loads(raw)' $'    try:\n        doc = json.loads(raw)\n    except ValueError:\n        return 0'
prove "json-get lets a non-object through" t_json_get $S '    if not isinstance(doc, dict):' '    if False:'
prove "json-get fails on a missing file" t_json_get $S $'        except FileNotFoundError:\n            return 0' $'        except FileNotFoundError:\n            raise'
prove "json-get writes in the caller's locale encoding" t_json_get $S '    sys.stdout.reconfigure(encoding="utf-8")' '    pass'
prove "modes-check does not walk logs/ and events/" t_modes_check $S '                paths += list(_walk_modes(os.path.join(home, sub)))' '                paths.append(os.path.join(home, sub))'
prove "modes-check skips jobs.sqlite-wal and -shm" t_modes_check $S 'if n.startswith("jobs.sqlite") or n in ("token", "daemon.json")]' 'if n == "jobs.sqlite" or n in ("token", "daemon.json")]'
prove "modes-check skips the token" t_modes_check $S 'or n in ("token", "daemon.json")]' 'or n in ("daemon.json",)]'
prove "modes-check skips daemon.json" t_modes_check $S 'or n in ("token", "daemon.json")]' 'or n in ("token",)]'
prove "modes-check skips the extra files (the launch log)" t_modes_check $S '    paths += [os.path.abspath(p) for p in extras]' '    pass'
prove "modes-check ignores group-only access" t_modes_check $S '    if mode & 0o077:' '    if mode & 0o007:'
prove "modes-check ignores other-only access" t_modes_check $S '    if mode & 0o077:' '    if mode & 0o070:'
prove "modes-check does not treat symlinks as symlinks" t_modes_check $S '    if stat.S_ISLNK(info.st_mode):' '    if False:'
prove "modes-check treats an unreadable directory as private" t_modes_check $S $'    def fail(exc):\n        raise exc' $'    def fail(exc):\n        return'
prove "modes-check exits 0 on a loose file" t_modes_check $S $'            print(problem)\n            return 8' $'            print(problem)\n            return 0'
prove "modes-check skips the home itself" t_modes_check $S '    paths = [home]' '    paths = []'
prove "modes-check reports a missing path as a problem" t_modes_check $S $'    except FileNotFoundError:\n        return None' $'    except FileNotFoundError:\n        return "%s does not exist" % path'
VALUES='values = {v for k, v in os.environ.items() if v and (k in allowed or SECRET_NAME.search(k))}'
prove "redact ignores env names matching key|token" t_redact $S "$VALUES" 'values = {v for k, v in os.environ.items() if v and (k in allowed)}'
prove "redact ignores the allowlist" t_redact $S "$VALUES" 'values = {v for k, v in os.environ.items() if v and (SECRET_NAME.search(k))}'
prove "redact skips Authorization" t_redact $S 'text = AUTH_HEADER.sub(r"\1 ***", text)' 'text = text'
prove "redact skips ghp_" t_redact $S 'r"ghp_[A-Za-z0-9]{6,}"' 'r"ghp_NEVER"'
prove "redact skips github_pat_" t_redact $S 'r"github_pat_[A-Za-z0-9_]{6,}"' 'r"github_pat_NEVER"'
prove "redact skips sk-" t_redact $S 'r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{6,}"' 'r"sk-NEVER"'
prove "redact sk- without its word-boundary guard" t_redact $S 'r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{6,}"' 'r"sk-[A-Za-z0-9_-]{6,}"'
prove "redact skips AKIA" t_redact $S 'r"AKIA[0-9A-Z]{8,}"' 'r"AKIA_NEVER"'
prove "an unreadable allowlist is treated as empty" t_redact $S $'    if not os.path.lexists(path):\n        return set()' $'    if not os.path.isfile(path):\n        return set()'
prove "redact fails without saying why" t_redact $S 'die(1, "redact: VELO_TASK_HOME is not set, so the allowlist cannot be located")' 'die(1, "redact: failed")'
prove "jobs-ro opens the database with create rights" t_jobs_ro $S '?mode=ro' '?mode=rwc'
prove "jobs-ro waits 0 ms" t_jobs_ro $S 'uri=True, timeout=2.0' 'uri=True, timeout=0.0'
prove "jobs-ro skips the schema check" t_jobs_ro $S '        if missing:' '        if False:'
prove "jobs-ro reports a refused statement as success" t_jobs_ro $S $'    except sqlite3.DatabaseError as exc:  # not authorized, malformed database\n        die(1,' $'    except sqlite3.DatabaseError as exc:  # not authorized, malformed database\n        die(0,'
prove "jobs-ro installs no authorizer" t_jobs_ro $S '        con.set_authorizer(read_only_authorizer)' '        pass'
prove "the jobs-ro authorizer allows everything" t_jobs_ro $S $'        return sqlite3.SQLITE_OK\n    return sqlite3.SQLITE_DENY' $'        return sqlite3.SQLITE_OK\n    return sqlite3.SQLITE_OK'
prove "the jobs-ro authorizer allows ATTACH" t_jobs_ro $S 'SQLITE_SELECT, SQLITE_FUNCTION):' 'SQLITE_SELECT, SQLITE_FUNCTION, 24):'
prove "the jobs-ro authorizer allows PRAGMA" t_jobs_ro $S 'SQLITE_SELECT, SQLITE_FUNCTION):' 'SQLITE_SELECT, SQLITE_FUNCTION, 19):'
prove "the jobs-ro authorizer allows recursive queries" t_jobs_ro $S 'SQLITE_SELECT, SQLITE_FUNCTION):' 'SQLITE_SELECT, SQLITE_FUNCTION, 33):'
prove "the jobs-ro authorizer denies a plain function call" t_jobs_ro $S 'SQLITE_SELECT, SQLITE_FUNCTION):' 'SQLITE_SELECT):'
prove "the jobs-ro authorizer denies column reads" t_jobs_ro $S 'if action in (SQLITE_READ, SQLITE_SELECT, SQLITE_FUNCTION):' 'if action in (SQLITE_SELECT, SQLITE_FUNCTION):'
prove "the jobs-ro authorizer denies SELECT" t_jobs_ro $S 'if action in (SQLITE_READ, SQLITE_SELECT, SQLITE_FUNCTION):' 'if action in (SQLITE_READ, SQLITE_FUNCTION):'
prove "failpoints honoured without VELO_TASK_TEST=1" t_failpoint_gating $S $'    if os.environ.get("VELO_TASK_TEST") != "1":\n        return "VELO_TASK_TEST is not 1"\n' ''
prove "failpoints honoured without a nonce in the environment" t_failpoint_gating $S $'    if not nonce:\n        return "VELO_TASK_TEST_ROOT_NONCE is not set"\n' ''
prove "failpoints honoured whatever the marker holds" t_failpoint_gating $S '            return None if held == nonce else "%s does not hold VELO_TASK_TEST_ROOT_NONCE" % marker' '            return None'
prove "failpoints honoured with a matching marker farther up" t_failpoint_gating $S '            return None if held == nonce else "%s does not hold VELO_TASK_TEST_ROOT_NONCE" % marker' $'            if held == nonce:\n                return None'
prove "failpoints honoured with no marker at all" t_failpoint_gating $S '            return "no %s above VELO_TASK_HOME (%s)" % (TEST_MARKER, home)' '            return None'
prove "failpoints honoured with no state dir" t_failpoint_gating $S $'    if not home:\n        return "VELO_TASK_HOME is not set"\n' ''
prove "a stray failpoint is accepted by subcommands that do not use it" t_failpoint_gating $S \
  $'    failpoint_spec()  # a stray VELO_TASK_FAILPOINT or VELO_TASK_FSYNC_TRACE is refused by every subcommand, not just the ones that use it\n' ''
prove "a stray fsync trace is accepted without the capability" t_failpoint_gating $S $'        require_test_capability("VELO_TASK_FSYNC_TRACE")\n' ''
prove "failpoint exit exits 0" t_failpoint_gating $S 'os._exit(137)' 'os._exit(0)'
prove "failpoint wait does not wait" t_failpoint_gating $S 'while not os.path.exists(spec[2]):' 'while False:'
prove "unknown failpoint names pass" t_failpoint_gating $S $'    if name not in FAILPOINTS:\n        die(2, "unknown failpoint %r" % name)' '    pass'
prove "unknown failpoint actions run as exit" t_failpoint_gating $S 'die(2, "unknown failpoint action %r" % action)' 'return name, "exit", None, target'
prove "VELO_TASK_UV is honoured without the capability" t_uv_capability $L \
  '    stl test-capability || die 2 "VELO_TASK_UV is set but refused: it is honoured only under the test capability (VELO_TASK_TEST=1 and a test root)"' '    :'
prove "the test-capability subcommand grants everything" t_uv_capability $S $'    if problem:\n        die(2, "the test capability is not granted: %s" % problem)\n' ''

# ---- the front end: B14, the public parser, the lock ----
prove "a bash-4 construct is added to the front end" t_b14 $V 'set -euo pipefail' $'set -euo pipefail\ndeclare -A seeded'
prove "a bash-4 construct is added to the library" t_b14 $L 'LIB_SRC="${BASH_SOURCE[0]}"' $'LIB_SRC="${BASH_SOURCE[0]}"\ndeclare -A seeded'
SWEEP_RE='NEVER_MATCHES' prove_env "sweep blind to declare -A" t_b14
prove "unknown subcommands exit 1" t_unimplemented $V $'  *) die 2 "\'$sub\' is not implemented' $'  *) die 1 "\'$sub\' is not implemented'
prove "underscore names reach the not-implemented arm" t_private_subcommands $V $'  _*) die 2 "unknown subcommand \'$sub\'" ;;\n' ''
prove "the parser routes _locked-* to the locked bodies" t_private_subcommands $V \
  $'  _*) die 2 "unknown subcommand \'$sub\'" ;;' \
  $'  _locked-ensure|_locked-restart|_locked-install) "locked_${sub#_locked-}" "$LOCK_FILE" ;;\n  _*) die 2 "unknown subcommand \'$sub\'" ;;'
prove "the parser routes library function names" t_private_subcommands $V \
  $'    "cmd_${sub//-/_}" ;;' $'    "cmd_${sub//-/_}" ;;\n  locked_ensure|locked-ensure|locked_restart|locked_install) "${sub//-/_}" "$LOCK_FILE" ;;'
prove "locked_ensure does not assert the lock" t_lock_bypass $L $'  assert_lock_held "${1:-}"\n  need_install; need_allowlist; need_modes\n  local pid' $'  need_install; need_allowlist; need_modes\n  local pid'
prove "locked_restart does not assert the lock" t_lock_bypass $L \
  $'  assert_lock_held "${1:-}"\n  need_install; need_allowlist; need_modes\n  stl failpoint daemon.lock.held\n  local deadline' \
  $'  need_install; need_allowlist; need_modes\n  stl failpoint daemon.lock.held\n  local deadline'
prove "locked_install does not assert the lock" t_lock_bypass $L $'  assert_lock_held "${1:-}"\n  stl failpoint install.lock.held' '  stl failpoint install.lock.held'
prove "assert_lock_held does not ask whether the lock is held" t_lock_bypass $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "assert_lock_held accepts a lock held on some other file" t_lock_bypass $L "$NOLOCK_ASSERT" '  [ -n "${1:-}" ] && stl lock-held "${1:-}" \'

# ---- the allowlist: one proof per rule, and for the shape of a name ----
RULES="PATH HOME IFS ENV BASH_ENV SHELLOPTS PYTHON DYLD_ LD_ VANTH_ VELO_TASK_ AGENT_BG_ TMPDIR"
for rule in $RULES; do
  rest=" $RULES "; rest=${rest/ $rule / }; rest=${rest# }; rest=${rest% }
  ROW=$rule prove "the allowlist no longer rejects the $rule rule" t_allowlist_rejects $L "    for p in $RULES; do" "    for p in $rest; do"
done
ROW=charset prove "the allowlist accepts any name" t_allowlist_rejects $L '/usr/bin/grep -Eq "$NAME_RE"' '/usr/bin/grep -Eq "."'
ROW=charset prove "the allowlist accepts lowercase names" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Za-z][A-Za-z0-9_]*\$'"
ROW=charset prove "the allowlist accepts a leading digit" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Z0-9][A-Z0-9_]*\$'"
ROW=charset prove "the allowlist accepts a dash in a name" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Z][A-Z0-9_-]*\$'"
ROW=charset prove "the allowlist prints the offending line" t_allowlist_rejects $L '(value not shown)" >&2; bad=1; continue' '$key" >&2; bad=1; continue'
prove "an allowlist rule matches by first letter only" t_allowlist_rejects $L 'case "$key" in "$p"*)' 'case "$key" in "${p:0:1}"*)'
prove "restart-daemon skips the allowlist check" t_allowlist_lists \
  $L 'cmd_restart_daemon() { need_install; need_allowlist; run_locked locked_restart; }' 'cmd_restart_daemon() { need_install; run_locked locked_restart; }' \
  $L $'  need_install; need_allowlist; need_modes\n  stl failpoint daemon.lock.held\n  local deadline' $'  need_install; need_modes\n  stl failpoint daemon.lock.held\n  local deadline'
prove "the allowlist check stops at the first bad line" t_allowlist_lists $L '(value not shown)" >&2; bad=1; continue' '(value not shown)" >&2; return 1'

# ---- the launch: environment, modes, records ----
prove "the daemon inherits the caller's environment" t_secrets $L 'exec /usr/bin/env -i "${args[@]}"' 'exec /usr/bin/env "${args[@]}"'
prove "allowlisted values are never delivered" t_secrets $L '    if [ "${!k+set}" = set ]; then args[${#args[@]}]="$k=${!k}"; fi' '    :'
prove "a secret value reaches the daemon argv" t_secrets $L '"$VANTHD" </dev/null >"$LAUNCH_LOG" 2>&1 ) &' '"$VANTHD" "--ignored=${OPENROUTER_API_KEY-}" </dev/null >"$LAUNCH_LOG" 2>&1 ) &'
prove "a secret value is written into a record" t_secrets $L '"$2" "$3" "$4" "$5" > "$tmp" )' '"$2" "$3" "$4" "$5" > "$tmp"; printf "k=%s\n" "${OPENROUTER_API_KEY-}" >> "$tmp" )'
prove "launch without umask 077" t_modes_env $L '( umask 077; exec /usr/bin/env -i' '( exec /usr/bin/env -i'
prove "launch without VANTH_HOME" t_modes_env $L 'args=(PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME' 'args=(PATH="$JOB_PATH" HOME="$HOME" AGENT_BG_HOME'
prove "launch without the port" t_modes_env $L 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)' 'VANTH_RETENTION_SECONDS=0)'
prove "launch without VANTH_RETENTION_SECONDS=0" t_modes_env $L 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)' 'VANTH_DAEMON_PORT="$PORT")'
prove "the provenance records the wrong pid" t_modes_env $L 'write_record "$PROV" "$pid" "$started" "$digest" "$inc"' 'write_record "$PROV" "$$" "$started" "$digest" "$inc"'
prove "the intent is not retired once the daemon is proved ready" t_modes_env $L \
  $'  write_record "$PROV" "$pid" "$started" "$digest" "$inc"\n  retire_record "$INTENT"' '  write_record "$PROV" "$pid" "$started" "$digest" "$inc"'
prove "the provenance incarnation is constant" t_restart $L 'inc=$(/usr/bin/uuidgen)' 'inc=00000000-0000-4000-8000-000000000001'
prove "records are written without the helper's durable publish" t_crash_in_publish $L '  st publish "$1" "$tmp"' '  /bin/mv -f "$tmp" "$1"'
prove "the provenance is written without the helper's durable publish" t_crash_in_provenance_publish $L '  st publish "$1" "$tmp"' '  /bin/mv -f "$tmp" "$1"'
prove "the publish failpoint ignores which destination it was armed for" t_crash_in_provenance_publish $S \
  'if not spec or spec[0] != name or (spec[3] and spec[3] != os.path.basename(dest or "")):' 'if not spec or spec[0] != name:'
prove "the publish failpoint ignores which destination it was armed for (helper)" t_publish $S \
  'if not spec or spec[0] != name or (spec[3] and spec[3] != os.path.basename(dest or "")):' 'if not spec or spec[0] != name:'
prove "a failpoint other than publish.linked takes a destination" t_failpoint_gating $S \
  $'    if "@" in point and (name != "publish.linked" or not target):\n        die(2, "failpoint %r: only publish.linked takes a non-empty @<dest-name>" % point)\n' ''
prove "a failpoint takes an empty destination" t_failpoint_gating $S '(name != "publish.linked" or not target)' '(name != "publish.linked")'

# ---- adoption: provenance, intent, listener ----
prove "prov_valid accepts everything" t_provenance_refusals $L $'  local dj live\n  PROV_WHY=""\n' $'  local dj live\n  PROV_WHY=""\n  return 0\n'
prove "the provenance pid is not compared with daemon.json" t_provenance_refusals $L '[ "$dj" = "$REC_PID" ] || {' 'true || {'
prove "the provenance start time is not compared" t_provenance_refusals $L '  [ "$live" = "$REC_LSTART" ] || { PROV_WHY=' '  true || { PROV_WHY='
prove "the provenance digest is not compared" t_provenance_refusals $L '  [ "$REC_DIGEST" = "$(launch_digest)" ] \' '  true \'
prove "daemon.json started_at is not compared" t_provenance_refusals $L '  within_5s "$(epoch_of_lstart "$REC_LSTART")" "$(epoch_of_iso "$(djson started_at)")" \' '  true \'
prove "rec_load accepts any incarnation (adoption)" t_provenance_refusals $L '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' '.*$'
prove "start time rendered in the caller's locale and zone" t_locale_fresh_shell $L 'LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' '/bin/ps -o lstart= -p "$1"'
prove "a launch is not checked for its listener" t_loopback $L '  check_loopback "$pid" || abandon_launch "$pid" "$started" "$LOOPBACK_WHY"' '  :'
prove "adoption does not check the listener" t_loopback $L '    check_loopback "$pid" || die 6 "$LOOPBACK_WHY; refusing to adopt it. Run: velo-task restart-daemon"' '    :'
prove "the loopback check always passes" t_loopback $L '  [ "$got" = "n127.0.0.1:$PORT " ] && return 0' '  return 0'
prove "the loopback check looks at the port only" t_loopback $L '  [ "$got" = "n127.0.0.1:$PORT " ] && return 0' $'  case "$got" in *":$PORT "*) return 0 ;; esac'
prove "doctor does not check the listener" t_loopback $L \
  '    if check_loopback "$pid"; then ok "bind: 127.0.0.1:$PORT only (listener of pid $pid)"; else bad "bind: $LOOPBACK_WHY"; fi' '    ok "bind: 127.0.0.1:$PORT only (listener of pid $pid)"'

# ---- state modes ----
prove "ensure-daemon does not check the modes" t_modes_refuse $L $'  need_install; need_allowlist; need_modes\n  local pid' $'  need_install; need_allowlist\n  local pid'
prove "restart-daemon does not check the modes" t_modes_refuse $L \
  $'  need_install; need_allowlist; need_modes\n  stl failpoint daemon.lock.held\n  local deadline' $'  need_install; need_allowlist\n  stl failpoint daemon.lock.held\n  local deadline'
prove "the launch log is not part of the mode check" t_modes_refuse $L 'out=$(st modes-check "$VH" "$LAUNCH_LOG") || rc=$?' 'out=$(st modes-check "$VH") || rc=$?'
prove "a failed mode check is treated as private" t_modes_refuse $L '    *) die 6 "the mode check failed (helper exit $rc): $out" ;;' '    *) return 1 ;;'
prove "the mode check is skipped after a launch" t_modes_after_launch $L $'  retire_record "$INTENT"\n  need_modes\n' $'  retire_record "$INTENT"\n'

# ---- the lock: no mutual exclusion without it ----
prove "no lock serialises the lifecycle (two ensure-daemon)" t_concurrent_ensure $L "$NOLOCK_RUN" '  /bin/bash -c' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "no lock serialises the lifecycle (restart-daemon, ensure-daemon)" t_restart_vs_ensure $L "$NOLOCK_RUN" '  /bin/bash -c' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "no lock serialises the lifecycle (two install-vanth)" t_install_concurrent $L "$NOLOCK_RUN" '  /bin/bash -c' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "install-vanth does not take the daemon lock (two install-vanth)" t_install_concurrent $L '  run_locked locked_install' '  locked_install "$LOCK_FILE"' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "install-vanth does not take the daemon lock (install-vanth, ensure-daemon)" t_install_vs_ensure $L '  run_locked locked_install' '  locked_install "$LOCK_FILE"' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "install-vanth does not take the daemon lock (install-vanth, restart-daemon)" t_install_vs_restart $L '  run_locked locked_install' '  locked_install "$LOCK_FILE"' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'
prove "no lock serialises the lifecycle (install-vanth, restart-daemon)" t_install_vs_restart $L "$NOLOCK_RUN" '  /bin/bash -c' $L "$NOLOCK_ASSERT" '  [ "${1:-}" = "$LOCK_FILE" ] \'

# ---- restart-daemon: only a process a record proves is ours, re-validated, bounded ----
prove "restart-daemon does not signal the old daemon" t_restart $L '    signal_validated TERM "$OURS_PID" "$OURS_LSTART"' '    :'
prove "restart-daemon delegates to vanth restart" t_restart $L '    signal_validated TERM "$OURS_PID" "$OURS_LSTART"' '    vanth_env "$VANTH" restart || true'
prove "restart-daemon does not bound the wait for the old daemon" t_stop_failure $L \
  '    ! kill -0 "$OURS_PID" 2>/dev/null || die 6 "vanthd pid $OURS_PID still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM; not escalating"' '    :'
prove "a launch keeps the previous provenance in place" t_restart $L $'  retire_record "$PROV"; retire_record "$INTENT"\n' $'  retire_record "$INTENT"\n'
prove "restart-daemon demands the current launch digest" t_restart_digest_change $L '    if rec_live "$f"; then' '    if rec_live "$f" && [ "$REC_DIGEST" = "$(launch_digest)" ]; then'
prove "restart-daemon signals the pid daemon.json names when no record exists" t_restart_refuses_unproven $L \
  $'  elif probe_up; then\n    die 6 "a daemon answers on port $PORT but no velo-task record proves' \
  $'  elif probe_up; then\n    signal_validated TERM "$(djson pid)" "$(ps_lstart "$(djson pid)")"; /bin/sleep 1\n    die 6 "a daemon answers on port $PORT but no velo-task record proves'
prove "restart-daemon ignores the recorded start time" t_restart_refuses_unproven $L '  [ "$live" = "$REC_LSTART" ] || { REC_WHY=' '  true || { REC_WHY='
prove "rec_load accepts a record without a pid" t_restart_refuses_unproven $L \
  $'  case "$REC_PID" in \'\'|*[!0-9]*) REC_WHY="$1 has no valid pid"; return 1 ;; esac\n' ''
prove "rec_load accepts a record without a start time" t_restart_refuses_unproven $L \
  $'  [ -n "$REC_LSTART" ] || { REC_WHY="$1 has no start time"; return 1; }\n' ''
prove "rec_load accepts any digest" t_restart_refuses_unproven $L '[0-9a-f]{64}$' '.*$'
prove "rec_load accepts any incarnation (restart-daemon)" t_restart_refuses_unproven $L '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' '.*$'
prove "restart-daemon signals a record that daemon.json contradicts" t_restart_refuses_unproven $L \
  '      if [ "${1:-}" != any ] && [ -n "$dj" ] && [ "$dj" != "$REC_PID" ]; then' '      if false; then'
prove "restart-daemon ignores the intent" t_crash_after_intent $L '  for f in "$PROV" "$INTENT"; do' '  for f in "$PROV"; do'
prove "signal_validated does not re-check the start time (the pid is replaced under restart-daemon)" t_restart_pid_replaced $L \
  '  [ -n "$now" ] && [ "$now" = "$3" ] || die 6 "refusing to signal pid $2: start time is' '  true || die 6 "refusing to signal pid $2: start time is'
prove "signal_validated does not re-check the start time (a live pid with another start time)" t_signal_revalidation $L \
  '  [ -n "$now" ] && [ "$now" = "$3" ] || die 6 "refusing to signal pid $2: start time is' '  true || die 6 "refusing to signal pid $2: start time is'

# ---- launch, crash points, recovery ----
prove "a daemon that dies at start is waited out" t_launch_failure $L $'    kill -0 "$pid" 2>/dev/null || break\n' ''
prove "an abandoned launch keeps its intent" t_launch_failure $L $'  retire_record "$INTENT"\n  die 6 "$why"' '  die 6 "$why"'
prove "a provenance is written before the daemon is ready" t_launch_failure $L \
  $'  fi\n  deadline=$((SECONDS + ${VELO_TASK_START_WAIT:-20}))' $'  fi\n  write_record "$PROV" "$pid" "$started" "$digest" "$inc"\n  deadline=$((SECONDS + ${VELO_TASK_START_WAIT:-20}))'
prove "an abandoned launch exits 0" t_port_collision $L $'  retire_record "$INTENT"\n  die 6 "$why"' $'  retire_record "$INTENT"\n  exit 0'
prove "another daemon answering counts as this launch being ready" t_launch_requires_own_pid \
  $L '    if probe_up && [ "$(djson pid)" = "$pid" ]; then break; fi' '    if probe_up; then break; fi' \
  $L '  if ! { kill -0 "$pid" 2>/dev/null && probe_up && [ "$(djson pid)" = "$pid" ]; }; then' '  if ! { kill -0 "$pid" 2>/dev/null && probe_up; }; then'
prove "no crash point after the launch" t_crash_after_launch $L '  stl failpoint launch.started' '  :'
prove "no crash point after the intent" t_crash_after_intent $L '    stl failpoint launch.intent' '    :'
prove "no crash point after readiness" t_crash_after_intent $L '  stl failpoint launch.ready' '  :'
prove "the intent is not published" t_crash_after_intent $L '  if [ -n "$started" ]; then' '  if false; then'
prove "an interrupted launch is reported as an unproven daemon" t_crash_after_intent $L '      if rec_live "$INTENT"; then' '      if false; then'
prove "a leftover intent is kept when its daemon is adopted" t_adopt_retires_intent $L \
  '{ ! rec_live "$INTENT" || [ "$REC_PID" = "$pid" ]; }; then retire_record "$INTENT"; fi' '{ ! rec_live "$INTENT" || [ "$REC_PID" = "$pid" ]; }; then :; fi'
VELO_TASK_START_WAIT=3 prove "ensure-daemon launches over a live recorded process" t_hung_start $L '    if find_ours_live any; then' '    if false; then'   # the mutant waits out the start window: 3 s, not 10
prove "a launch leaves a stale intent in place" t_stale_intent $L $'  retire_record "$PROV"; retire_record "$INTENT"\n' $'  retire_record "$PROV"\n'
prove "a launch leaves a stale provenance in place" t_stale_intent $L $'  retire_record "$PROV"; retire_record "$INTENT"\n' $'  retire_record "$INTENT"\n'
prove "doctor calls a stale intent fine" t_stale_intent $L 'else ok "intent: stale ($REC_WHY); ensure-daemon retires it"; fi' 'else ok "intent: fine ($REC_WHY)"; fi'

# ---- doctor, and what runs before the lifecycle ----
prove "ensure-daemon before install-vanth does not say what to run" t_before_install \
  $L 'cmd_ensure_daemon() { need_install; need_allowlist; run_locked locked_ensure; }' 'cmd_ensure_daemon() { need_allowlist; run_locked locked_ensure; }' \
  $L $'  need_install; need_allowlist; need_modes\n  local pid' $'  need_allowlist; need_modes\n  local pid'
prove "doctor reports an unproven daemon as fine" t_doctor $L \
  '    if prov_valid; then ok "provenance: valid"; else bad "provenance: $PROV_WHY (run: velo-task restart-daemon)"; fi' '    ok "provenance: valid"'
prove "doctor ignores a schema mismatch" t_doctor $L '    else bad "schema: jobs-ro exit $? (4 locked, 5 mismatch)"; fi' '    else ok "schema: ignored"; fi'
prove "doctor ignores loose modes" t_doctor $L '    if modes_problem; then bad "modes: $MODES_WHY"; else ok "modes: private"; fi' '    ok "modes: private"'
prove "doctor ignores a live interrupted launch" t_doctor $L '    if rec_live "$INTENT"; then bad "intent:' '    if false; then bad "intent:'
prove "doctor retires a stale intent" t_doctor_readonly $L \
  'else ok "intent: stale ($REC_WHY); ensure-daemon retires it"; fi' 'else retire_record "$INTENT"; ok "intent: stale ($REC_WHY); ensure-daemon retires it"; fi'
prove "doctor touches the lock file" t_doctor_readonly $L $'cmd_doctor() {\n  local rc=0 pid' $'cmd_doctor() {\n  /usr/bin/touch "$LOCK_FILE"\n  local rc=0 pid'

# ---- no caller-PATH tool ----
prove "ps is looked up on the caller's PATH" t_no_path_tools $L 'LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' 'LC_ALL=C TZ=UTC ps -o lstart= -p "$1"'
prove "lsof is looked up on the caller's PATH" t_no_path_tools $L '/usr/sbin/lsof -nP' 'lsof -nP'
VELO_TASK_START_WAIT=3 prove "env is looked up on the caller's PATH" t_no_path_tools $L 'vanth_env() { /usr/bin/env -i' 'vanth_env() { env -i'   # a shim env never answers the probe: the mutant waits out the start window, 3 s
prove "awk is looked up on the caller's PATH" t_no_path_tools $L 'norm_names() { /usr/bin/awk' 'norm_names() { awk'
prove "uuidgen is looked up on the caller's PATH" t_no_path_tools $L 'inc=$(/usr/bin/uuidgen)' 'inc=$(uuidgen)'
prove "date is looked up on the caller's PATH" t_no_path_tools $L 'epoch_of_iso() { /bin/date' 'epoch_of_iso() { date'
prove "uv is looked up on the caller's PATH" t_no_path_tools $L 'UV_PINNED=/opt/homebrew/bin/uv' 'UV_PINNED=uv'

# ---- install-vanth ----
prove "install without --require-hashes" t_install_flags $L '    --require-hashes --only-binary :all: -r "$LOCKFILE"' '    --only-binary :all: -r "$LOCKFILE"'
prove "install allows sdists" t_install_flags $L '    --require-hashes --only-binary :all: -r "$LOCKFILE"' '    --require-hashes -r "$LOCKFILE"'
prove "install from the wrong file" t_install_flags $L '-r "$LOCKFILE" ||' '-r "$LIB_DIR/../requirements/vanth.in" ||'
prove "install without the PyPI pin" t_install_flags $L '--default-index https://pypi.org/simple' '--no-config'
prove "install runs Vanth's setup command" t_install_flags $L $'  verify_install\n  st sha256 "$LOCKFILE" > "$MARKER"' $'  verify_install; "$VENV/bin/vanth" setup\n  st sha256 "$LOCKFILE" > "$MARKER"'
prove "uv runs with the caller's PATH" t_install_flags $L 'run_uv() { PATH="$INSTALL_PATH" "$UV" "$@"; }' 'run_uv() { "$UV" "$@"; }'
prove "the trigger-parent reason is not asserted" t_install_asserts $L \
  '|| fail_install "the pinned trigger-parent stop reason is absent from the installed Vanth (R1)"' '|| true'
prove "the schema is not asserted" t_install_asserts $L '|| fail_install "the installed Vanth schema lacks columns the spec reads (R8)"' '|| true'
prove "the installed set is not compared with the lock" t_install_asserts $L '  [ "$locked" = "$installed" ] \' '  true \'
prove "a failed install keeps the broken venv" t_install_asserts $L '  /bin/rm -rf "$VENV"; die 1 "install-vanth failed' '  die 1 "install-vanth failed'
prove "install ignores the marker" t_install_idempotent $L '    if [ "$(/bin/cat "$MARKER")" = "$want" ]; then' '    if false; then'
prove "a changed lock does not rebuild" t_install_idempotent $L '    if [ "$(/bin/cat "$MARKER")" = "$want" ]; then' '    if true; then'
prove "install replaces a venv under a running daemon" t_install_refuses_under_daemon $L '  if venv_in_use; then' '  if false; then'
prove "a failed install removes the venv under a running daemon" t_install_failure_under_daemon $L '  ! venv_in_use || die 6 "install-vanth: $*;' '  true || die 6 "install-vanth: $*;'
prove "venv_in_use ignores a daemon.json pid that runs from the venv" t_venv_in_use $L $'  pid=$(djson pid)\n  if [ -n "$pid" ]; then' $'  pid=\n  if [ -n "$pid" ]; then'
prove "venv_in_use ignores a recorded process that does not answer" t_venv_in_use $L '  if find_ours_live any; then return 0; fi' '  :'

# ---- the lock, the closure list, the fixtures ----
H0=$(printf '%064d' 0)
prove "a lock entry without a hash" t_lock_file requirements/vanth.lock \
  '--hash=sha256:f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0  # wheel: annotated_types-0.8.0-py3-none-any.whl' ''
prove "a lock entry with two hashes" t_lock_file requirements/vanth.lock '  # wheel: annotated_types-0.8.0-py3-none-any.whl' \
  $'  # wheel: annotated_types-0.8.0-py3-none-any.whl\n    --hash=sha256:'"$H0"$'  # wheel: annotated_types-0.8.0-py3-none-any.whl'
prove "a hash with no wheel named beside it (an sdist's looks like this)" t_lock_file requirements/vanth.lock '  # wheel: annotated_types-0.8.0-py3-none-any.whl' ''
prove "the lock gains an extra index" t_lock_file requirements/vanth.lock 'annotated-types==0.8.0 \' $'--extra-index-url https://example.invalid/simple\nannotated-types==0.8.0 \\'
prove "a lock entry is not pinned" t_lock_file requirements/vanth.lock 'anyio==4.15.1 \' 'anyio>=4.15.1 \'
prove "a lock hash of the wrong length" t_lock_file requirements/vanth.lock \
  'sha256:6152fdbbf9a77fdec97731721bebf7c4c44f7c29b424b0065826173efc7ed101' 'sha256:6152fdbbf9a77fdec97731721bebf7c4c44f7c29b424b0065826173efc7ed10'
prove "the lock names an sdist" t_lock_file requirements/vanth.lock '# wheel: anyio-4.15.1-py3-none-any.whl' '# wheel: anyio-4.15.1.tar.gz'
prove "the lock names a wheel for another platform" t_lock_file requirements/vanth.lock \
  '# wheel: vanth-1.14.0-py3-none-macosx_11_0_arm64.whl' '# wheel: vanth-1.14.0-py3-none-manylinux_2_17_aarch64.whl'
prove "the lock names a wheel for another interpreter" t_lock_file requirements/vanth.lock \
  '# wheel: starlette-1.10.0-py3-none-any.whl' '# wheel: starlette-1.10.0-cp313-cp313-macosx_11_0_arm64.whl'
prove "a script runs Vanth's setup command" t_lock_file $L 'LIB_SRC="${BASH_SOURCE[0]}"' $'LIB_SRC="${BASH_SOURCE[0]}"\nvanth setup'
prove "a script writes ~/.claude.json" t_lock_file $V 'set -euo pipefail' $'set -euo pipefail\necho {} > "$HOME/.claude.json"'
prove "the lock pins another starlette than the closure list" t_lock_closure requirements/vanth.lock 'starlette==1.10.0 \' 'starlette==1.10.1 \'
FAKE_UV_MUTANT=fromlock prove_env "the fake uv derives the installed set from the lock" t_lock_closure
FAKE_UV_MUTANT=noguard prove_env "the fake uv has no path guard" t_fake_uv_guard
prove "install.sh does not ship requirements" t_install_ships_lock install.sh '  [[ -d "$SRC/$d" ]] || continue
  mkdir -p "$DEST/$d"' '  [[ -d "$SRC/$d" ]] || continue
  [[ $d == requirements ]] && continue
  mkdir -p "$DEST/$d"'
prove "install.sh drift check ignores requirements" t_install_ships_lock install.sh 'for d in bin rules skills hooks launchd requirements; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__' 'for d in bin rules skills hooks launchd; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__'

# ---- isolation: the same comparison against a stand-in home that is then disturbed ----
prove_env "a velo-task directory appears under the real home" stray_velo_task_dir
prove_env "a vanth directory appears under the real home" stray_vanth_dir
prove_env "~/.agents/state is modified" stray_state_touch
prove_env "~/.config is modified" stray_config_touch
prove_env "~/.claude.json gains a vanth entry" stray_mcp_entry
prove_env "the suite runs with the real HOME" stray_real_home_env
prove_env "the suite runs with Homebrew on PATH" stray_homebrew_path
proof_drain   # every proof reported before anything else runs: the checks below reap the whole suite tree

if [ "${VELO_TASK_NETWORK_TESTS:-}" = 1 ]; then
  echo "velo-task M1: network (real uv, PyPI, real vanthd on a random port in a temp home)"
  check "real install, tamper/version failures, real daemon: modes, lsof, adopt, doctor, restart" t_network
else
  echo "  (network install skipped: set VELO_TASK_NETWORK_TESTS=1)"
fi
echo "velo-task M1: isolation"
check "the real home is untouched: HOME was a temp dir and PATH the system directories throughout" t_real_home_untouched
check "control: the same comparison passes against an undisturbed stand-in home" t_stand_in_untouched
echo
[ $FAILED -eq 0 ] && echo "all velo-task M1 foundation checks passed" || echo "FAILURES"
exit $FAILED

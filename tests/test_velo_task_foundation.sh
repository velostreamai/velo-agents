#!/bin/bash
# velo-task M1 foundation (docs/velo-task-spec.md): install-vanth, the velo-task-state helper, the daemon
# lifecycle. Bars: B14 (bash 3.2 for the M1 scripts), B21 (secrets), B22 (privacy, provenance), B23
# (supply chain), and from B33 the allowlist rejections, two concurrent ensure-daemon and a reused pid
# that is never signalled; plus a unit test per helper subcommand (failpoint gating R21, redaction B34(iv)).
#
# No real Vanth is needed: fake vanthd/vanth/uv stubs stand in (mkvenv, mkuv). The real install and daemon
# run only with VELO_TASK_NETWORK_TESTS=1 (downloads about 30 wheels).
#
# Every check is also proved RED on a mutated COPY of the code under test (`prove`): the repo's files are
# never edited, and a mutation whose anchor is not found exactly once is a failed proof, never a skip.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
umask 022   # the launch's own `umask 077` must be what makes the daemon's files private
unset VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_FAILPOINT_WAIT_MAX VELO_TASK_HOME VELO_TASK_PORT
# Test-mode timeouts (stubs answer at once; a broken run is bounded): see test-timeouts.sh.
. "$HERE/test-timeouts.sh"
PYBIN="$(command -v python3)"
# macOS mktemp given no template ignores TMPDIR (run.sh points it into the worktree), while python's tempfile, which
# sets the failpoint gate's temp root (R21), honours it: build the template from TMPDIR so both name the same tree.
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(mktemp -d "$TMP_ROOT/velo-task-foundation.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }   # an empty $T would make reap's pattern match everything
PIDS="$T/pids"; : > "$PIDS"
reap() {  # stop what this suite started: fake daemons run in their own process groups, and a mutant can start two
  local p tree
  tree=$(printf '%s/' "$T" | sed 's/[^A-Za-z0-9_/-]/\\&/g')   # the temp tree as a literal pattern
  /usr/bin/pkill -9 -f -- "$tree" 2>/dev/null   # everything whose command line runs from this suite's temp tree
  for p in $(cat "$PIDS"); do
    if /bin/ps -o command= -p "$p" 2>/dev/null | grep -q -e '-decoy'; then kill -9 "$p" 2>/dev/null; fi
  done
}
cleanup() { reap; rm -rf "$T"; }
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
prove() {  # <label> <check fn> <file> <anchor> <replacement>: the check must go RED on the mutated copy
  MUT_N=$((MUT_N + 1))
  local m="$T/mut-$MUT_N" out   # numbered, never named for the label: a label's words must not satisfy a grep on the path
  rm -rf "$m"; mkdir -p "$m"; cp -R "$REPO/bin" "$REPO/requirements" "$m/"; cp "$REPO/install.sh" "$m/"
  if ! "$PYBIN" -I - "$m/$3" "$4" "$5" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
assert text.count(old) == 1, "mutation anchor must occur exactly once, found %d: %r" % (text.count(old), old)
open(path, "w").write(text.replace(old, new))
PY
  then flunk "MUTATION-PROOF $1: anchor problem (see above)"; return; fi
  if out=$(trap reap EXIT; R="$m" "$2" 2>&1); then flunk "MUTATION-PROOF $1: $2 stayed GREEN with the mutation"
  else pass "MUTATION-PROOF | test=$2 | mutation=$1 | red=\"${out%%$'\n'*}\""; fi
}

# ---- fixtures --------------------------------------------------------------------------------------
mkhome() {  # isolated VELO_TASK_HOME and port: sets E E_HOME E_VENV E_VH E_CALLS E_PORT
  E=$(mktemp -d "$T/e.XXXXXX"); E_HOME="$E/home"; E_VENV="$E_HOME/venv"; E_VH="$E_HOME/vanth"; E_CALLS="$E/calls"
  mkdir -m 700 "$E_HOME"; : > "$E_CALLS"
  E_PORT=$("$PYBIN" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  export VELO_TASK_HOME="$E_HOME" VELO_TASK_PORT="$E_PORT"
}
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
mkvenv() {  # a fake installed Vanth: real python, stub vanthd and vanth (record to $E_CALLS), install marker
  # bin/python is a wrapper SCRIPT we own, never a symlink to the real interpreter: a stub (or a mutant) that
  # writes to a venv path must not be able to write through to a system binary.
  mkdir -p "$E_VENV/bin"; rm -f "$E_VENV/bin/python"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$PYBIN" > "$E_VENV/bin/python"; chmod +x "$E_VENV/bin/python"
  sed "s#@CALLS@#$E_CALLS#g; s#@E@#$E#g" > "$E_VENV/bin/vanthd" <<'EOS'
#!/bin/bash
# Fake vanthd: only what velo-task relies on. Records its launch, environment NAMES and a hash of
# OPENROUTER_API_KEY (never a value), secures its home like Vanth, writes daemon.json, exits on SIGTERM.
H="$VANTH_HOME"
[ -n "$H" ] || { echo "fake vanthd: no VANTH_HOME" >&2; exit 1; }
[ ! -e @E@/fail-launch ] || { echo "fake vanthd: refusing to start" >&2; exit 1; }
/bin/mkdir -p "$H/logs" "$H/events"; /bin/chmod 700 "$H"
: > "$H/token"; : > "$H/logs/daemon.log"; : > "$H/events/e.jsonl"
if [ -f @E@/seed.sqlite ]; then /bin/cp @E@/seed.sqlite "$H/jobs.sqlite"; /bin/chmod 600 "$H/jobs.sqlite"; else : > "$H/jobs.sqlite"; fi
{
  printf 'launch pid=%s umask=%s home=%s port=%s retention=%s\n' "$$" "$(umask)" "$VANTH_HOME" "$VANTH_DAEMON_PORT" "${VANTH_RETENTION_SECONDS-unset}"
  printf 'names=%s\n' "$(/usr/bin/env | /usr/bin/sed 's/=.*//' | /usr/bin/grep -vxE 'PWD|SHLVL|_' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
  printf 'keyhash=%s\n' "$([ -n "${OPENROUTER_API_KEY+x}" ] && printf %s "$OPENROUTER_API_KEY" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64 || echo unset)"
} >> @CALLS@
printf '{"url":"http://127.0.0.1:%s","home":"%s","pid":%s,"started_at":"%s"}\n' "$VANTH_DAEMON_PORT" "$H" "$$" "$(/bin/date -u +%FT%TZ)" > "$H/daemon.json"
trap '/bin/rm -f "$H/daemon.json"; exit 0' TERM
[ ! -e @E@/ignore-term ] || trap '' TERM
while [ "$SECONDS" -lt 300 ]; do /bin/sleep 0.1; done   # safety net: a stub never outlives a broken run
EOS
  sed "s#@CALLS@#$E_CALLS#g" > "$E_VENV/bin/vanth" <<'EOS'
#!/bin/bash
echo "vanth $*" >> @CALLS@
[ "$1 $2" = "--json status" ] || { echo "fake vanth: unsupported: $*" >&2; exit 2; }
pid=$(/usr/bin/sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$VANTH_HOME/daemon.json" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo '{"up": true}'; else echo '{"up": false}'; exit 1; fi
EOS
  chmod +x "$E_VENV/bin/vanthd" "$E_VENV/bin/vanth"
  ST sha256 "$R/requirements/vanth.lock" > "$E_VENV/.velo-task-installed"
}
mkuv() {  # <variant: ok|noreason|nocolumn|extra|missing>: a fake uv + fake Vanth package for install-vanth
  local v="$1" py3="$PYBIN"
  mkdir -p "$E/uvbin" "$E/site/vanth"; : > "$E/site/vanth/__init__.py"
  { [ "$v" = noreason ] && echo 'REASON = "something else"' || echo 'REASON = "trigger parent reached an incompatible terminal status"'; } > "$E/site/vanth/server.py"
  cat > "$E/site/vanth/migrations.py" <<EOF
def migrate(db, home):
    cols = "job_id name status exit_code stop_actor stop_reason trigger_json created_at ended_at policy_state_json".split()
    db.execute("CREATE TABLE jobs (%s)" % ", ".join(c for c in cols if c != "$([ "$v" = nocolumn ] && echo ended_at)"))
    db.execute("CREATE TABLE local_start_requests (idempotency_key, request_hash, job_id, created_at)")
    db.commit()
EOF
  sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$R/requirements/vanth.lock" > "$E/freeze.txt"
  [ "$v" != extra ] || echo 'rogue-extra==1.0' >> "$E/freeze.txt"
  [ "$v" != missing ] || sed -i '' '/^starlette==/d' "$E/freeze.txt"
  sed "s#@E@#$E#g; s#@PY3@#$py3#g" > "$E/uvbin/uv" <<'EOS'
#!/bin/bash
echo "uv $*" >> @E@/uv.log
case "$1 $2" in
  "venv "*) d="${!#}"; mkdir -p "$d/bin"; rm -f "$d/bin/python" "$d/bin/vanth"   # never write through an existing path
    printf '#!/bin/sh\nPYTHONPATH=@E@/site exec @PY3@ "$@"\n' > "$d/bin/python"; chmod +x "$d/bin/python"
    printf '#!/bin/sh\necho "vanth $*" >> @E@/vanth.log\n' > "$d/bin/vanth"; chmod +x "$d/bin/vanth" ;;
  "pip freeze") cat @E@/freeze.txt ;;
  "pip install") ;;
esac
EOS
  chmod +x "$E/uvbin/uv"
}
daemon_pid() { jq -r '.pid // empty' "$E_VH/daemon.json" 2>/dev/null; }
launches() { grep -c '^launch ' "$E_CALLS" || true; }
prov() { sed -n "s/^$1=//p" "$E_HOME/daemon.provenance"; }
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
write_json() { mkdir -p -m 700 "$E_VH"; printf '{"url":"http://127.0.0.1:%s","pid":%s,"started_at":"%s"}\n' "$E_PORT" "$1" "$2" > "$E_VH/daemon.json"; }
write_prov() { printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=X\n' "$1" "$2" "$3" > "$E_HOME/daemon.provenance"; }

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
t_failpoint_gating() {  # R21: each of the three gate conditions is isolated, so each is individually provable
  local d wp; d=$(mktemp -d "$T/f.XXXXXX"); mkdir "$d/inside"
  # (a) VELO_TASK_TEST missing, state dir inside the temp root
  VELO_TASK_HOME="$d/home" VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "without VELO_TASK_TEST=1 a set failpoint is refused (exit 2), not fired" [ "$RC" = 2 ]
  need "...with a log line" grep -q 'refused' <<<"$OUT"
  VELO_TASK_FAILPOINT=daemon.lock.held run ST sha256 </dev/null
  need "a stray VELO_TASK_FAILPOINT is refused by an unrelated subcommand too" [ "$RC" = 2 ]
  # (b) VELO_TASK_TEST=1 but no state dir; the working directory is inside the temp root
  OUT=$(cd "$d/inside" && VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=daemon.lock.held:exit "$PYBIN" "$R/bin/velo-task-state" failpoint daemon.lock.held 2>&1); RC=$?
  need "VELO_TASK_TEST=1 with no VELO_TASK_HOME is refused" [ "$RC" = 2 ]
  # (c) VELO_TASK_TEST=1 but a state dir outside the temp root
  VELO_TASK_TEST=1 VELO_TASK_HOME=/opt/velo-task-outside-temp VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held
  need "VELO_TASK_TEST=1 with a state dir outside the temp root is refused" [ "$RC" = 2 ]
  export VELO_TASK_TEST=1 VELO_TASK_HOME="$d/home"
  VELO_TASK_FAILPOINT=daemon.lock.held:exit run ST failpoint daemon.lock.held; need "name:exit exits 137" [ "$RC" = 137 ]
  VELO_TASK_FAILPOINT=publish.linked:exit run ST failpoint daemon.lock.held; need "another failpoint's name does not fire" [ "$RC" = 0 ]
  VELO_TASK_FAILPOINT=nonsense run ST failpoint daemon.lock.held; need "an unregistered failpoint name is refused" [ "$RC" = 2 ]
  VELO_TASK_FAILPOINT=daemon.lock.held:sleep run ST failpoint daemon.lock.held; need "an unknown action is refused" [ "$RC" = 2 ]
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
t_allowlist_rejects() {
  local k; mkhome; mkvenv
  for k in PYTHONPATH DYLD_INSERT_LIBRARIES PATH VANTH_DAEMON_PORT HOME LD_PRELOAD VELO_TASK_HOME AGENT_BG_HOME TMPDIR BASH_ENV IFS SHELLOPTS ENV PATHX; do
    printf '%s\n' "$k" > "$E_HOME/vanth.env.allow"
    run VT ensure-daemon
    need "$k is rejected with exit 6" [ "$RC" = 6 ]; need "...and named" grep -q "$k" <<<"$OUT"
    need "...and nothing was launched" [ "$(launches)" = 0 ]
  done
  printf 'lowercase\nFOO=supersecretvalue\n1ABC\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "malformed names are rejected with exit 6" [ "$RC" = 6 ]
  need "...and a value on the line is never echoed" not grep -q supersecretvalue <<<"$OUT"
  printf '# comment\n\n  OPENROUTER_API_KEY  \nMY_OTHER_NAME\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "a valid list (comments, blanks, padding) is accepted" [ "$RC" = 0 ]
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
}
t_provenance_refusals() {  # B22: one scenario per validity condition, the others held true so each is individually provable
  local p dp um good
  for um in 077 022; do
    mkhome; mkvenv; prestart $um || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid)
    run VT ensure-daemon; need "daemon pre-started by hand under umask $um is refused (exit 6)" [ "$RC" = 6 ]
    need "...with the restart-daemon hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
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
  cp "$good" "$E_HOME/daemon.provenance"; cp "$E/dj.good" "$E_VH/daemon.json"
  run VT ensure-daemon; need "control: the untouched provenance and daemon.json are adopted" [ "$RC" = 0 ]
  need "...as adopted" grep -q adopted <<<"$OUT"
  need "...and the control never launched anything" [ "$(launches)" = 1 ]
  kill "$p"
}
t_provenance_crash() {  # R17: the provenance goes through the helper's publish, so a crash inside it leaves a complete record
  local p; mkhome; mkvenv
  VELO_TASK_TEST=1 VELO_TASK_FAILPOINT=publish.linked:exit run VT ensure-daemon
  need "a crash inside the provenance publish ends ensure-daemon with the helper's exit 137" [ "$RC" = 137 ]
  p=$(daemon_pid)
  need "the daemon it had launched keeps running" alive "$p"
  need "the published provenance names that daemon" [ "$(prov pid)" = "$p" ]
  need "...and carries an incarnation" [ -n "$(prov incarnation)" ]
  run VT ensure-daemon
  need "the next call adopts that daemon" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  need "...launching nothing" [ "$(launches)" = 1 ]
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
t_modes_refuse() {
  local f; mkhome; mkvenv; VT ensure-daemon >/dev/null
  for f in jobs.sqlite token daemon.json; do
    chmod 644 "$E_VH/$f"; run VT ensure-daemon
    need "$f at 0644 is refused (exit 6)" [ "$RC" = 6 ]; need "...naming the file" grep -q "$f" <<<"$OUT"; chmod 600 "$E_VH/$f"
  done
  chmod 755 "$E_VH"; run VT ensure-daemon; need "a 0755 home is refused" [ "$RC" = 6 ]
  chmod 644 "$E_VH/jobs.sqlite"; run VT restart-daemon
  need "restart-daemon recovers it" [ "$RC" = 0 ]
  need "...tightening the file an earlier loose daemon left" [ "$(stat -f %Lp "$E_VH/jobs.sqlite")" = 600 ]
  need "...and the home" [ "$(stat -f %Lp "$E_VH")" = 700 ]
}
t_concurrent_ensure() {  # B33
  local b o1 o2 n
  mkhome; mkvenv; b="$E/barrier"
  ( VELO_TASK_TEST=1 VELO_TASK_FAILPOINT="daemon.lock.held:wait=$b" VT ensure-daemon > "$E/o1" 2>&1; echo $? > "$E/rc1" ) &
  waitfor 10 test -e "$b.reached" || { echo "FAILED: first caller never reached the barrier"; exit 1; }
  ( VT ensure-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) &
  sleep 1; : > "$b"; wait
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
  need "the caller's secret did not reach the new daemon" [ "$(grep -c '^keyhash=unset' "$E_CALLS")" = 2 ]
  need "restart-daemon never calls vanth restart" not grep -q '^vanth restart' "$E_CALLS"
  run VT ensure-daemon; need "the new daemon is adopted" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
}
t_reused_pid() {  # B33: a pid that merely looks right is never signalled
  local dp
  mkhome; mkvenv; dp=$(decoy vanthd); write_json "$dp" 2001-01-01T00:00:00Z
  run VT restart-daemon; need "start time far from daemon.json started_at: exit 6" [ "$RC" = 6 ]
  need "...not signalled" alive "$dp"; need "...nothing launched" [ "$(launches)" = 0 ]; kill "$dp"
  mkhome; mkvenv; dp=$(decoy other); write_json "$dp" "$(iso_start "$dp")"
  run VT restart-daemon; need "a process that is not a vanthd: exit 6" [ "$RC" = 6 ]
  need "...not signalled" alive "$dp"; kill "$dp"
  mkhome; mkvenv; dp=$(decoy vanthd); write_json "$dp" "$(iso_start "$dp")"; write_prov "$dp" 'Mon Jan 1 00:00:00 2001' abc
  run VT restart-daemon; need "provenance naming this pid with another start time: exit 6" [ "$RC" = 6 ]
  need "...not signalled" alive "$dp"; kill "$dp"
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
  t0=$(now); VELO_TASK_START_WAIT=8 run VT ensure-daemon; t1=$(now)
  need "a daemon that dies at start: exit 6" [ "$RC" = 6 ]; need "...saying so" grep -q 'did not become ready' <<<"$OUT"
  need "...with the launch log" grep -q 'refusing to start' <<<"$OUT"
  need "...without waiting out the whole start window" between 0 "$t0" "$t1" 5
  need "no provenance is written" [ ! -e "$E_HOME/daemon.provenance" ]
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
  need "...the loopback bind" grep -q 'bind: 127.0.0.1' <<<"$OUT"
  need "...the modes" grep -q 'modes: private' <<<"$OUT"
  need "...and the schema" grep -q 'schema: matches' <<<"$OUT"
  p=$(daemon_pid); rm "$E_HOME/daemon.provenance"; run VT doctor
  need "doctor flags a daemon without provenance (exit 1)" [ "$RC" = 1 ]; need "...naming the provenance" grep -q 'FAIL provenance' <<<"$OUT"
  need "doctor is read-only: the same daemon is still running" [ "$(daemon_pid)" = "$p" ]; need "...alive" alive "$p"
  need "...and nothing was launched" [ "$(launches)" = 1 ]
  rm "$E_VH/jobs.sqlite"; mkdb "$E_VH/jobs.sqlite" ended_at; chmod 600 "$E_VH/jobs.sqlite"; run VT doctor
  need "doctor flags a database lacking a pinned column" grep -q 'FAIL schema' <<<"$OUT"
  chmod 644 "$E_VH/token"; run VT doctor; need "doctor flags a loose mode" grep -q 'FAIL modes' <<<"$OUT"; chmod 600 "$E_VH/token"
  sed -i '' 's#http://127.0.0.1#http://0.0.0.0#' "$E_VH/daemon.json"; run VT doctor
  need "doctor flags a daemon.json url that is not loopback" grep -q 'FAIL bind' <<<"$OUT"
}

# ---- install-vanth (offline, fake uv) and the lock --------------------------------------------------
installv() { PATH="$E/uvbin:$PATH" run VT install-vanth; }
t_install_flags() {  # B23
  mkhome; mkuv ok; installv
  need "install-vanth succeeds" [ "$RC" = 0 ]
  need "the venv is built with CPython 3.12 under VELO_TASK_HOME/venv" grep -qE "^uv venv .*--python 3\.12 .*$E_VENV\$" "$E/uv.log"
  need "install passes --require-hashes" grep -qE '^uv pip install .*--require-hashes' "$E/uv.log"
  need "install passes --only-binary :all:" grep -qE '^uv pip install .*--only-binary :all:' "$E/uv.log"
  need "install reads the lock file" grep -qE '^uv pip install .* -r .*requirements/vanth\.lock$' "$E/uv.log"
  need "install uses PyPI only" grep -q -- '--default-index https://pypi.org/simple' "$E/uv.log"
  need "the marker is the lock's SHA-256 (checked with shasum)" [ "$(cat "$E_VENV/.velo-task-installed")" = "$(/usr/bin/shasum -a 256 "$R/requirements/vanth.lock" | cut -d' ' -f1)" ]
  need "Vanth's setup command is never run" [ ! -e "$E/vanth.log" ]
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
  PATH="$E/uvbin:$PATH" run "$m/bin/velo-task" install-vanth
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
  echo 'rogue-extra==1.0' >> "$E/freeze.txt"; installv
  need "a failed verification under a running daemon exits 6" [ "$RC" = 6 ]
  need "...saying the venv was left in place" grep -q 'left in place' <<<"$OUT"
  need "...keeping the venv" [ -x "$E_VENV/bin/vanthd" ]
  need "...and the daemon" alive "$(daemon_pid)"
}
t_lock_file() {  # B23
  local lock="$R/requirements/vanth.lock" bad n f
  bad=$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[A-Za-z0-9._-]+==[0-9A-Za-z.+!_-]+ \\$/ { if (name != "" && !h) print "no hash: " name; name = $1; h = 0; next }
    /^    --hash=sha256:[0-9a-f]+( \\)?$/ { v = $1; sub(/^--hash=sha256:/, "", v); if (length(v) != 64) print "bad hash length: " name; h = 1; next }
    { print "unexpected line: " $0 }
    END { if (name != "" && !h) print "no hash: " name }' "$lock")
  OUT=$bad; need "every requirement is pinned (==) with full-length sha256 hashes and the file has nothing else" [ -z "$bad" ]
  n=$(grep -cE '^[A-Za-z0-9._-]+==' "$lock"); need "the full tree is locked (at least 25 distributions)" [ "$n" -ge 25 ]
  need "vanth 1.14.0 is the pinned version" grep -q '^vanth==1\.14\.0 ' "$lock"
  need "no index, URL, VCS or editable directive" not grep -qE '(^|[[:space:]])(-e|--index-url|--extra-index-url|-f|--find-links|--no-binary)|://|git\+' <(grep -v '^[[:space:]]*#' "$lock")
  for f in '--generate-hashes' '--only-binary :all:' '--python-version 3.12' '--python-platform aarch64-apple-darwin'; do
    need "the lock header records how it was compiled: $f" grep -qF -e "$f" <(sed -n 2p "$lock")
  done
  need "no script runs Vanth's setup command" [ "$(grep -cE '(vanth|VANTH)"?[[:space:]]+setup' "$R"/bin/velo-task* | awk -F: '{s += $NF} END {print s}')" = 0 ]
  need "no script writes ~/.claude.json or registers an MCP server" [ "$(grep -ciE 'claude\.json|claude mcp|mcp add' "$R"/bin/velo-task* | awk -F: '{s += $NF} END {print s}')" = 0 ]
}
t_install_ships_lock() {  # production wiring: the installed bin/velo-task resolves ../requirements/vanth.lock, so install.sh must ship it
  local s="$T/inst-src" dest="$T/inst-dest" skills="$T/inst-skills"; rm -rf "$s" "$dest" "$skills"; mkdir -p "$s/bin" "$s/requirements"
  cp "$R/install.sh" "$s/install.sh"; cp "$R/bin/velo-task" "$R/bin/velo-task-state" "$s/bin/"; cp "$R/requirements/vanth.lock" "$s/requirements/"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh"
  need "install.sh succeeds" [ "$RC" = 0 ]
  mkhome; mkuv ok; PATH="$E/uvbin:$PATH" run "$dest/bin/velo-task" install-vanth
  need "the installed velo-task finds its lock and installs from it" [ "$RC" = 0 ]
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check sees no drift right after an install" [ "$RC" = 0 ]
  echo '# edited in place' >> "$dest/requirements/vanth.lock"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check reports a hand-edited installed lock as drift" [ "$RC" != 0 ]
}

# ---- the real thing, once: VELO_TASK_NETWORK_TESTS=1 ------------------------------------------------
norm_freeze() { awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' | LC_ALL=C sort -u; }
t_network() {  # the real Vanth from PyPI and a real vanthd on a random port in a temp home: never the live state, never 48217
  local p pid2 m f l envs
  export VELO_TASK_START_WAIT=60 UV_CACHE_DIR="$T/uv-cache"
  mkhome; run VT install-vanth
  need "real install-vanth succeeds" [ "$RC" = 0 ]; echo "note: $(tail -n 1 <<<"$OUT")"
  need "the installed set equals the lock set (uv pip freeze vs the lock: none extra, none missing)" \
    [ "$(uv pip freeze --no-config --python "$E_VENV/bin/python" | norm_freeze)" = "$(sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$R/requirements/vanth.lock" | norm_freeze)" ]
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

# ---- run -------------------------------------------------------------------------------------------
echo "velo-task M1: state helper"
check "fp: row fingerprint vectors" t_fp
check "sha256: stdin and file" t_sha256
check "publish: durable, never replaces, crash leaves both names" t_publish
check "append-index: O_APPEND whole lines, 0600, id charset" t_append_index
check "lock: exclusive, bounded wait, released by process death" t_lock
check "redact: R23(d) fixtures, error prints nothing" t_redact
check "jobs-ro: JSON rows, read-only, 2000 ms lock wait, schema exit 5" t_jobs_ro
check "failpoints: gated on VELO_TASK_TEST and the temp root (R21)" t_failpoint_gating
echo "velo-task M1: front end"
check "B14: bash 3.2, no bash-4 constructs, seeded declare -A fails both" t_b14
check "other subcommands exit 2 (not implemented in M1)" t_unimplemented
check "B33: allowlist rejects reserved names, never echoes values" t_allowlist_rejects
check "B21: allowlisted key delivered, nothing else inherited, no secret at rest" t_secrets
check "B22: modes 0700/0600, env -i keeps VANTH_HOME and port" t_modes_env
check "B22: daemons without valid provenance are refused" t_provenance_refusals
check "R17: the provenance goes through the helper's publish; a crash inside it leaves a complete record" t_provenance_crash
check "B22: accepted under another locale, TZ and a fresh shell" t_locale_fresh_shell
check "looser modes are refused; restart-daemon tightens them" t_modes_refuse
check "B33: two concurrent ensure-daemon start one daemon" t_concurrent_ensure
check "restart-daemon: SIGTERM, clean env, fresh incarnation, no vanth restart" t_restart
check "restart-daemon: bounded wait, no SIGKILL, no second daemon" t_stop_failure
check "B33: a reused pid is never signalled" t_reused_pid
check "a daemon that dies at start is reported fast with its log" t_launch_failure
check "ensure-daemon before install-vanth says what to run" t_before_install
check "doctor: read-only report" t_doctor
echo "velo-task M1: install and lock"
check "B23: install passes --require-hashes --only-binary :all: -r lock, PyPI only" t_install_flags
check "install-vanth asserts reason string, columns, installed set == lock" t_install_asserts
check "install-vanth is idempotent and rebuilds on a changed lock" t_install_idempotent
check "install-vanth never replaces a venv under a running daemon" t_install_refuses_under_daemon
check "install-vanth keeps the venv under a running daemon even when verification fails" t_install_failure_under_daemon
check "B23: the lock hashes every line and carries no sdist/index/URL directive" t_lock_file
check "install.sh ships requirements/ beside bin/" t_install_ships_lock

echo "velo-task M1: mutation proofs (each check must go red on a mutated copy)"
V=bin/velo-task; S=bin/velo-task-state
prove "fp ignores the last field" t_fp $S 'row = "|".join(args).encode' 'row = "|".join(args[:4]).encode'
prove "sha256 truncated" t_sha256 $S 'print(hashlib.sha256(data).hexdigest())' 'print(hashlib.sha256(data).hexdigest()[:16])'
prove "publish replaces an existing name" t_publish $S 'os.link(src, dest)  # fails' 'os.rename(src, dest); os.link(dest, src)  # fails'
prove "append-index without O_APPEND on the existing-file path" t_append_index $S 'fd = os.open(path, os.O_WRONLY | os.O_APPEND)' 'fd = os.open(path, os.O_WRONLY)'
prove "append-index accepts a trailing newline (the anchored regex used with match)" t_append_index $S '    if not JOB_ID.fullmatch(job_id):' '    if not re.match(r"^[A-Za-z0-9_-]+$", job_id):'
prove "lock never takes the flock" t_lock $S 'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' 'pass'
prove "lock fd leaks into the command" t_lock $S 'proc = subprocess.Popen(cmd)' 'proc = subprocess.Popen(cmd, pass_fds=(fd,))'
VALUES='values = {v for k, v in os.environ.items() if v and (k in allowed or SECRET_NAME.search(k))}'
prove "redact ignores env names matching key|token" t_redact $S "$VALUES" 'values = {v for k, v in os.environ.items() if v and (k in allowed)}'
prove "redact ignores the allowlist" t_redact $S "$VALUES" 'values = {v for k, v in os.environ.items() if v and (SECRET_NAME.search(k))}'
prove "redact skips Authorization" t_redact $S 'text = AUTH_HEADER.sub(r"\1 ***", text)' 'text = text'
prove "redact skips ghp_" t_redact $S 'r"ghp_[A-Za-z0-9]{6,}"' 'r"ghp_NEVER"'
prove "redact skips github_pat_" t_redact $S 'r"github_pat_[A-Za-z0-9_]{6,}"' 'r"github_pat_NEVER"'
prove "redact skips sk-" t_redact $S 'r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{6,}"' 'r"sk-NEVER"'
prove "redact sk- without its word-boundary guard" t_redact $S 'r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{6,}"' 'r"sk-[A-Za-z0-9_-]{6,}"'
prove "redact skips AKIA" t_redact $S 'r"AKIA[0-9A-Z]{8,}"' 'r"AKIA_NEVER"'
prove "an unreadable allowlist is treated as empty" t_redact $S 'if not os.path.lexists(path):' 'if not os.path.isfile(path):'
prove "redact fails without saying why" t_redact $S 'die(1, "redact: VELO_TASK_HOME is not set, so the allowlist cannot be located")' 'die(1, "redact: failed")'
prove "jobs-ro opens read-write" t_jobs_ro $S '?mode=ro' '?mode=rw'
prove "jobs-ro waits 0 ms" t_jobs_ro $S 'uri=True, timeout=2.0' 'uri=True, timeout=0.0'
prove "jobs-ro skips the schema check" t_jobs_ro $S '        if missing:' '        if False:'
prove "jobs-ro reports a failed query as success" t_jobs_ro $S 'die(1, "jobs-ro: %s" % exc)' 'die(0, "jobs-ro: %s" % exc)'
prove "failpoints honoured without VELO_TASK_TEST" t_failpoint_gating $S 'os.environ.get("VELO_TASK_TEST") != "1" or ' ''
prove "failpoints honoured with no state dir" t_failpoint_gating $S 'or not home or ' 'or '
prove "failpoints honoured outside the temp root" t_failpoint_gating $S 'not _under(home, tempfile.gettempdir())' 'False'
prove "failpoint exit exits 0" t_failpoint_gating $S 'os._exit(137)' 'os._exit(0)'
prove "failpoint wait does not wait" t_failpoint_gating $S 'while not os.path.exists(spec[2]):' 'while False:'
prove "unknown failpoint names pass" t_failpoint_gating $S '    if name not in FAILPOINTS:
        die(2, "unknown failpoint %r" % name)' '    pass'
prove "unknown failpoint actions run as exit" t_failpoint_gating $S 'die(2, "unknown failpoint action %r" % action)' 'return name, "exit", None'
prove "a bash-4 construct is added" t_b14 $V 'set -euo pipefail' 'set -euo pipefail
declare -A seeded'
SWEEP_SAVE=$SWEEP_RE; SWEEP_RE='NEVER_MATCHES'
if out=$(t_b14 2>&1); then flunk "MUTATION-PROOF sweep blind to declare -A: t_b14 stayed GREEN"; else pass "MUTATION-PROOF | test=t_b14 | mutation=sweep blind to declare -A | red=\"${out%%$'\n'*}\""; fi
SWEEP_RE=$SWEEP_SAVE
prove "unknown subcommands exit 1" t_unimplemented $V "*) die 2 \"'\$sub' is not implemented" "*) die 1 \"'\$sub' is not implemented"
prove "allowlist accepts reserved names" t_allowlist_rejects $V '    for p in PATH HOME IFS ENV BASH_ENV SHELLOPTS PYTHON DYLD_ LD_ VANTH_ VELO_TASK_ AGENT_BG_ TMPDIR; do' '    for p in NONE_OF_THEM; do'
prove "allowlist accepts any name" t_allowlist_rejects $V '    if ! printf '"'%s\\n'"' "$key" | LC_ALL=C grep -Eq "$NAME_RE"; then' '    if false; then'
prove "bad allowlist exits 1" t_allowlist_rejects $V 'need_allowlist() { validate_allowlist || die 6' 'need_allowlist() { validate_allowlist || die 1'
prove "daemon inherits the caller environment" t_secrets $V 'exec /usr/bin/env -i "${args[@]}"' 'exec /usr/bin/env "${args[@]}"'
prove "allowlist never delivered" t_secrets $V '    if [ "${!k+set}" = set ]; then args[${#args[@]}]="$k=${!k}"; fi' '    :'
prove "a secret value reaches the daemon argv" t_secrets $V '"$VANTHD" </dev/null >"$LAUNCH_LOG" 2>&1 ) &' '"$VANTHD" "--ignored=${OPENROUTER_API_KEY-}" </dev/null >"$LAUNCH_LOG" 2>&1 ) &'
prove "a secret value is written to the provenance" t_secrets $V '    "$(/usr/bin/uuidgen)" > "$PROV.tmp.$$" )' '    "$(/usr/bin/uuidgen)" > "$PROV.tmp.$$"; printf "k=%s\n" "${OPENROUTER_API_KEY-}" >> "$PROV.tmp.$$" )'
prove "launch without umask 077" t_modes_env $V '( umask 077; exec /usr/bin/env -i' '( exec /usr/bin/env -i'
prove "launch without VANTH_HOME" t_modes_env $V 'args=(PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME' 'args=(PATH="$JOB_PATH" HOME="$HOME" AGENT_BG_HOME'
prove "launch without the port" t_modes_env $V 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)' 'VANTH_RETENTION_SECONDS=0)'
prove "launch without VANTH_RETENTION_SECONDS=0" t_modes_env $V 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)' 'VANTH_DAEMON_PORT="$PORT")'
prove "provenance records the wrong pid" t_modes_env $V "incarnation=%s\\n' \"\$pid\" \"\$started\"" "incarnation=%s\\n' \"\$\$\" \"\$started\""
prove "provenance incarnation is constant" t_restart $V '    "$(/usr/bin/uuidgen)" > "$PROV.tmp.$$" )' '    "fixed-incarnation" > "$PROV.tmp.$$" )'
prove "unproven daemons are adopted" t_provenance_refusals $V '    prov_valid || refuse_unproven' '    :'
prove "provenance pid vs daemon.json not compared" t_provenance_refusals $V '  [ "$dj" = "$pid" ] ||' '  true ||'
prove "provenance written without the helper's publish" t_provenance_crash $V '  st publish "$PROV" "$PROV.tmp.$$"' '  /bin/mv -f "$PROV.tmp.$$" "$PROV"'
prove "provenance start time not compared" t_provenance_refusals $V '  [ "$live" = "$recorded" ] ||' '  true ||'
prove "provenance digest not compared" t_provenance_refusals $V '  [ "$(prov_get digest)" = "$(launch_digest)" ] \' '  true \'
prove "daemon.json started_at not compared" t_provenance_refusals $V '  within_5s "$(epoch_of_lstart "$recorded")" "$(epoch_of_iso "$(djson started_at)")" \' '  true \'
prove "start time rendered in the caller's locale and zone" t_locale_fresh_shell $V '  LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' '  /bin/ps -o lstart= -p "$1"'
prove "modes not checked" t_modes_refuse $V '  [ -z "$p" ] || die 6 "$p; refusing. A clean launch tightens it: velo-task restart-daemon"' '  :'
prove "launch does not tighten old files" t_modes_refuse $V '  /bin/chmod -R go-rwx "$VH"' '  :'
prove "no daemon lock" t_concurrent_ensure $V '  st lock --timeout "${VELO_TASK_LOCK_WAIT:-60}" "$VELO_TASK_HOME/lock/daemon" -- "$SELF" "$1" || rc=$?' '  "$SELF" "$1" || rc=$?'
prove "restart does not signal the old daemon" t_restart $V '      signal_validated TERM "$pid" "$live"' '      :'
prove "restart delegates to vanth restart" t_restart $V '      signal_validated TERM "$pid" "$live"' '      vanth_env "$VANTH" restart || true'
prove "restart does not bound the wait for the old daemon" t_stop_failure $V '      ! kill -0 "$pid" 2>/dev/null || die 6 "vanthd pid $pid still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM; not escalating"' '      :'
prove "reused pid: start time not checked" t_reused_pid $V '      within_5s "$(epoch_of_lstart "$live")" "$(epoch_of_iso "$(djson started_at)")" \' '      true \'
prove "reused pid: command line not checked" t_reused_pid $V '      case "$cmd" in *vanthd*|*vanth.daemon*) ;; *) die 6 "pid $pid is not a vanthd ($cmd): not signalled" ;; esac' '      :'
prove "reused pid: provenance contradiction ignored" t_reused_pid $V '      if [ "$(prov_get pid)" = "$pid" ] && [ "$recorded" != "$live" ]; then' '      if false; then'
prove "a daemon that dies at start is waited out" t_launch_failure $V '    kill -0 "$pid" 2>/dev/null || break' '    :'
prove "no install check before ensure-daemon" t_before_install $V '  need_install; need_allowlist
  if probe_up && prov_valid; then' '  if probe_up && prov_valid; then'
prove "doctor reports unproven daemons as ok" t_doctor $V '    if prov_valid; then ok "provenance: valid"; else bad "provenance: $PROV_WHY (run: velo-task restart-daemon)"; fi' '    ok "provenance: valid"'
prove "doctor ignores a schema mismatch" t_doctor $V '    else bad "schema: jobs-ro exit $? (4 locked, 5 mismatch)"; fi' '    else ok "schema: ignored"; fi'
prove "doctor ignores loose modes" t_doctor $V '    p=$(modes_problem); if [ -z "$p" ]; then ok "modes: private"; else bad "modes: $p"; fi' '    ok "modes: private"'
prove "doctor ignores a non-loopback bind" t_doctor $V '    case "$(djson url)" in http://127.0.0.1:*) ok "bind: 127.0.0.1" ;; *) bad "bind: daemon.json url is '"'"'$(djson url)'"'"', expected 127.0.0.1" ;; esac' '    ok "bind: 127.0.0.1"'
prove "install without --require-hashes" t_install_flags $V '    --require-hashes --only-binary :all: -r "$LOCKFILE"' '    --only-binary :all: -r "$LOCKFILE"'
prove "install allows sdists" t_install_flags $V '    --require-hashes --only-binary :all: -r "$LOCKFILE"' '    --require-hashes -r "$LOCKFILE"'
prove "install from the wrong lock" t_install_flags $V '-r "$LOCKFILE" ||' '-r "$HERE/../requirements/vanth.in" ||'
prove "install without the PyPI pin" t_install_flags $V '--default-index https://pypi.org/simple' '--no-config'
prove "install runs Vanth's setup command" t_install_flags $V '  verify_install
  st sha256 "$LOCKFILE" > "$MARKER"' '  verify_install; "$VENV/bin/vanth" setup
  st sha256 "$LOCKFILE" > "$MARKER"'
prove "trigger-parent reason not asserted" t_install_asserts $V "  grep -rqF --include='*.py' 'trigger parent reached an incompatible terminal status' \"\$site\" \\" '  true \'
prove "schema not asserted" t_install_asserts $V "  st jobs-ro \"\$tmp/jobs.sqlite\" 'SELECT 1 AS ok' >/dev/null ||" '  true ||'
prove "installed set not compared with the lock" t_install_asserts $V '  [ "$locked" = "$installed" ] \' '  true \'
prove "failed install keeps the venv" t_install_asserts $V '  rm -rf "$VENV"; die 1 "install-vanth failed' '  die 1 "install-vanth failed'
prove "install ignores the marker" t_install_idempotent $V '    if [ "$(cat "$MARKER")" = "$want" ]; then' '    if false; then'
prove "a changed lock does not rebuild" t_install_idempotent $V '    if [ "$(cat "$MARKER")" = "$want" ]; then' '    if true; then'
prove "install replaces a venv under a running daemon" t_install_refuses_under_daemon $V '  if venv_in_use; then' '  if false; then'
prove "a failed install removes the venv under a running daemon" t_install_failure_under_daemon $V '  ! venv_in_use || die 6' '  true || die 6'
prove "lock entry without hashes" t_lock_file requirements/vanth.lock 'annotated-types==0.8.0 \
    --hash=sha256:13b2beaad985e05e2d6407ee4c4f35590b11f8d693a258a561055cac8f64cab7 \
    --hash=sha256:f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0
' 'annotated-types==0.8.0 \
'
prove "lock gains an extra index" t_lock_file requirements/vanth.lock 'annotated-types==0.8.0 \' '--extra-index-url https://example.invalid/simple
annotated-types==0.8.0 \'
prove "lock entry unpinned" t_lock_file requirements/vanth.lock 'anyio==4.15.1 \' 'anyio>=4.15.1 \'
prove "lock hash of the wrong length" t_lock_file requirements/vanth.lock 'sha256:13b2beaad985e05e2d6407ee4c4f35590b11f8d693a258a561055cac8f64cab7 \' 'sha256:13b2beaad985e05e2d6407ee4c4f35590b11f8d693a258a561055cac8f64cab \'
prove "setup call added to a script" t_lock_file $V 'set -euo pipefail' 'set -euo pipefail
vanth setup'
prove "a script writes ~/.claude.json" t_lock_file $V 'set -euo pipefail' 'set -euo pipefail
echo {} > "$HOME/.claude.json"'
prove "install.sh does not ship requirements" t_install_ships_lock install.sh '  [[ -d "$SRC/$d" ]] || continue
  mkdir -p "$DEST/$d"' '  [[ -d "$SRC/$d" ]] || continue
  [[ $d == requirements ]] && continue
  mkdir -p "$DEST/$d"'
prove "install.sh drift check ignores requirements" t_install_ships_lock install.sh 'for d in bin rules skills hooks launchd requirements; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__' 'for d in bin rules skills hooks launchd; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__'

if [ "${VELO_TASK_NETWORK_TESTS:-}" = 1 ]; then
  echo "velo-task M1: network (real uv, PyPI, real vanthd on a random port in a temp home)"
  check "real install, tamper/version failures, real daemon: modes, lsof, adopt, doctor, restart" t_network
else
  echo "  (network install skipped: set VELO_TASK_NETWORK_TESTS=1)"
fi
echo
[ $FAILED -eq 0 ] && echo "all velo-task M1 foundation checks passed" || echo "FAILURES"
exit $FAILED

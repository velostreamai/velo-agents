#!/bin/bash
# velo-task-lib.sh - the functions behind bin/velo-task (docs/velo-task-spec.md). Sourced, never run: by bin/velo-task for the
# public subcommands, and by the child shell the lock helper starts for the bodies that must run under the per-home lock.
# Nothing in here is reachable as a subcommand, so there is no way to run a locked body without taking the lock.
#
# Tools: every external program is invoked by absolute path (/bin/ps, /usr/bin/sed, ...), never through the caller's PATH, and
# JSON is read by the state helper (json-get), not jq, so a PATH shim cannot forge process identity, provenance or the install
# (R11, R12). uv is /opt/homebrew/bin/uv; VELO_TASK_UV replaces it only under the test capability (R21). The helper runs from the
# pinned venv (st) except for the lock, the failpoints and the capability check (stl): install-vanth replaces the venv while it
# holds the lock, so the lock holder must not live in it.
#
# Environment: nothing velo-task starts inherits the caller's. The helper (st, stl) runs `env -i` with PATH=system dirs, HOME,
# VELO_TASK_HOME, TMPDIR and LANG when set, under `python -I` (no PYTHONPATH, no sitecustomize, no user site, and no current
# directory on sys.path, which a `-c` run would otherwise import from; the venv python that checks the install is run so too). The locked body
# is a `bash -c` under `env -i` with those plus the VELO_TASK_* tunables and the allowlisted secret names it launches the daemon
# with, so BASH_ENV, ENV, SHELLOPTS and the rest never reach it. uv runs under `env -i` with its own fixed PATH. The test seams
# (VELO_TASK_TEST, the nonce, VELO_TASK_FAILPOINT, VELO_TASK_FSYNC_TRACE, VELO_TASK_UV) are forwarded only when the test
# capability holds (R21), and a seam that is set without it is refused (exit 2), never ignored.
#
# State safety: the state root, lock/, lock/daemon, venv/, vanth/, vanth.env.allow, both records and the launch log are checked
# before use (check-state: not a symlink, the right kind of node, yours; and the root itself exactly mode 0700, or for doctor,
# which only reads, free of group and other access) and a locked body checks again once it holds the lock. Records are
# read through rec-read and written through write-record (O_NOFOLLOW, O_EXCL). The lock is a descriptor (LOCK_FD) the body was
# handed, checked against the path before every action that cannot be undone.
#
# Layout (VELO_TASK_HOME defaults to ${VELO_STATE:-~/.agents/state}/velo-task; tests override it):
#   venv/               pinned Vanth install      vanth/              VANTH_HOME = AGENT_BG_HOME
#   vanth.env.allow     secret NAMES the daemon may inherit (one per line)
#   daemon.intent       pid, start time, launch digest, incarnation of a daemon being launched (before it is known good)
#   daemon.provenance   the same for the daemon velo-task launched and proved ready
#   *.retired.<epoch>   records retired for good      lock/daemon         per-home lock for install, ensure, restart
#   daemon.launch.log   vanthd stdout/stderr
#   names/<id>          the name index (R3): the job_ids run started under <id>, one per line, append-only
#   pending/<nonce>     a start about to be sent to Vanth (R17): its canonical settings, deleted once its job_id is indexed
#   session             the owner token run tags jobs with (session:<id>) when $CLAUDE_SESSION_ID is unset: made on first use, one per state dir
# VELO_TASK_PORT (default 48217) sets the daemon port. Tunables: VELO_TASK_START_WAIT, VELO_TASK_STOP_WAIT, VELO_TASK_LOCK_WAIT
# (seconds) and VELO_TASK_POLL (the poll interval while a daemon starts or stops, default 0.2 s). Exit codes: 0 ok, 1 error,
# 2 usage, 6 daemon refused/down/misconfigured.

LIB_SRC="${BASH_SOURCE[0]}"
LIB_SRC_DIR="${LIB_SRC%/*}"; [ "$LIB_SRC_DIR" != "$LIB_SRC" ] || LIB_SRC_DIR=.
LIB_DIR="$(cd "$LIB_SRC_DIR" && pwd)"
LIB_FILE="$LIB_DIR/${LIB_SRC##*/}"
STATE_SCRIPT="$LIB_DIR/velo-task-state"
LOCKFILE="$LIB_DIR/../requirements/vanth.lock"
VELO_TASK_HOME="${VELO_TASK_HOME:-${VELO_STATE:-$HOME/.agents/state}/velo-task}"
export VELO_TASK_HOME
VENV="$VELO_TASK_HOME/venv"
PY="$VENV/bin/python"
VANTHD="$VENV/bin/vanthd"
VANTH="$VENV/bin/vanth"
MARKER="$VENV/.velo-task-installed"
VH="$VELO_TASK_HOME/vanth"
PORT="${VELO_TASK_PORT:-48217}"
ALLOW="$VELO_TASK_HOME/vanth.env.allow"
PROV="$VELO_TASK_HOME/daemon.provenance"
INTENT="$VELO_TASK_HOME/daemon.intent"
LAUNCH_LOG="$VELO_TASK_HOME/daemon.launch.log"
LOCK_FILE="$VELO_TASK_HOME/lock/daemon"
NAMES="$VELO_TASK_HOME/names"
PENDING="$VELO_TASK_HOME/pending"
SESSION_FILE="$VELO_TASK_HOME/session"
UV_PINNED=/opt/homebrew/bin/uv
INSTALL_PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOCK_FD=9  # the descriptor the lock helper hands the locked body (lock --child-fd); launch_daemon closes it in the daemon's subshell
LOCK_PY_CANDIDATES="/opt/homebrew/bin/python3 /usr/bin/python3"
LOCK_PY=""
UV=""
HELPER_ENV=()  # NAME=value for `env -i` in front of every helper run (set by prep_env)
SEAM_ENV=()    # the test seams among them, when the test capability holds
# Jobs inherit the daemon's environment: a fixed PATH, HOME, Vanth's own variables, allowlisted names.
JOB_PATH="$HOME/.agents/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NAME_RE='^[A-Z][A-Z0-9_]*$'
ALLOW_NAMES=""
PROV_WHY=""
REC_PID=""; REC_LSTART=""; REC_DIGEST=""; REC_INC=""; REC_WHY=""
OURS_PID=""; OURS_LSTART=""; OURS_SRC=""; OURS_WHY=""
MODES_WHY=""
LOOPBACK_WHY=""

die() { local code="$1"; shift; printf 'velo-task: %s\n' "$*" >&2; exit "$code"; }
need_lock_py() {
  if [ -z "$LOCK_PY" ]; then
    local p
    for p in $LOCK_PY_CANDIDATES; do
      if [ -x "$p" ]; then LOCK_PY="$p"; break; fi
    done
    [ -n "$LOCK_PY" ] || die 6 "no Python 3 for the state helper's lock (looked for: $LOCK_PY_CANDIDATES)"
  fi
}
test_capability() {  # R21: succeeds when the test capability holds; says why not otherwise. Run with nothing of the caller's but the capability's own variables
  need_lock_py
  /usr/bin/env -i PATH="$SYS_PATH" HOME="$HOME" VELO_TASK_HOME="$VELO_TASK_HOME" VELO_TASK_TEST="${VELO_TASK_TEST:-}" \
    VELO_TASK_TEST_ROOT_NONCE="${VELO_TASK_TEST_ROOT_NONCE:-}" "$LOCK_PY" -I "$STATE_SCRIPT" test-capability 2>&1
}
prep_env() {  # once per entry point, in the main shell: what the helper and the locked body inherit (see the header)
  local v why seam=0
  HELPER_ENV=(PATH="$SYS_PATH" HOME="$HOME" VELO_TASK_HOME="$VELO_TASK_HOME")
  SEAM_ENV=()
  if [ -n "${TMPDIR:-}" ]; then HELPER_ENV[${#HELPER_ENV[@]}]="TMPDIR=$TMPDIR"; fi
  if [ -n "${LANG:-}" ]; then HELPER_ENV[${#HELPER_ENV[@]}]="LANG=$LANG"; fi
  for v in VELO_TASK_TEST VELO_TASK_FAILPOINT VELO_TASK_FSYNC_TRACE VELO_TASK_UV VELO_TASK_RERUN_NONCE; do
    if [ -n "${!v:-}" ]; then seam=1; fi
  done
  [ "$seam" = 1 ] || return 0
  if why=$(test_capability); then
    for v in VELO_TASK_TEST VELO_TASK_TEST_ROOT_NONCE VELO_TASK_FAILPOINT VELO_TASK_FAILPOINT_WAIT_MAX VELO_TASK_FSYNC_TRACE VELO_TASK_UV; do
      if [ -n "${!v:-}" ]; then SEAM_ENV[${#SEAM_ENV[@]}]="$v=${!v}"; fi
    done
    HELPER_ENV=("${HELPER_ENV[@]}" ${SEAM_ENV[@]+"${SEAM_ENV[@]}"})
  else
    for v in VELO_TASK_FAILPOINT VELO_TASK_FSYNC_TRACE VELO_TASK_UV; do
      if [ -n "${!v:-}" ]; then die 2 "$v is set but refused: it is honoured only for tests ($why)"; fi
    done
    if [ -n "${VELO_TASK_RERUN_NONCE:-}" ]; then die 2 "VELO_TASK_RERUN_NONCE is set but refused: it is honoured only for tests ($why)"; fi
  fi
}
py_run() {  # <python> <helper args...>: the state helper, isolated (-I) and under the minimal environment, never the caller's
  if [ "${#HELPER_ENV[@]}" -eq 0 ]; then prep_env; fi
  local py="$1"; shift
  /usr/bin/env -i "${HELPER_ENV[@]}" "$py" -I "$STATE_SCRIPT" "$@"
}
st() { py_run "$PY" "$@"; }
stl() { need_lock_py; py_run "$LOCK_PY" "$@"; }

case "$VELO_TASK_HOME" in /*) ;; *) die 2 "VELO_TASK_HOME must be an absolute path: $VELO_TASK_HOME" ;; esac
case "$PORT" in ''|*[!0-9]*) die 2 "VELO_TASK_PORT must be a number: $PORT" ;; esac
# The waits are evaluated by bash arithmetic, which runs command substitutions inside a subscript: a value is a number or it is refused.
for v in VELO_TASK_START_WAIT VELO_TASK_STOP_WAIT VELO_TASK_LOCK_WAIT; do
  case "${!v:-0}" in *[!0-9]*) die 2 "$v must be a whole number of seconds: ${!v}" ;; esac
done
case "${VELO_TASK_POLL:-0}" in *[!0-9.]*) die 2 "VELO_TASK_POLL must be a number of seconds: $VELO_TASK_POLL" ;; esac
unset v

# ---- process identity (R11(d), R18): the start time is always rendered LC_ALL=C TZ=UTC ----------
ps_lstart() {  # <pid> -> start time, empty when no such process
  LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1" 2>/dev/null | /usr/bin/sed -e 's/  */ /g; s/^ //; s/ $//' || true
}
epoch_of_lstart() { LC_ALL=C /bin/date -j -u -f '%a %b %d %H:%M:%S %Y' "$1" +%s 2>/dev/null || true; }
epoch_of_iso() { /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true; }
djson() { st json-get "$VH/daemon.json" "$1" || true; }  # a missing daemon.json is empty; a malformed one is reported on stderr
within_5s() {  # <epoch> <epoch>
  [ -n "$1" ] && [ -n "$2" ] && [ $(( $1 > $2 ? $1 - $2 : $2 - $1 )) -le 5 ]
}
signal_validated() {  # <signal> <pid> <expected lstart>: re-checks pid AND start time right before signalling
  local now
  now=$(ps_lstart "$2")
  [ -n "$now" ] && [ "$now" = "$3" ] || die 6 "refusing to signal pid $2: start time is '${now:-gone}', expected '$3'"
  kill "-$1" "$2"
}

# ---- records: daemon.intent and daemon.provenance share one format ---------------------------------
rec_present() { [ -e "$1" ] || [ -L "$1" ]; }  # a record exists under this name, a dangling symlink included: rec_load refuses that, it never counts as absent
rec_get() { printf '%s\n' "$1" | /usr/bin/sed -n "s/^$2=//p" | /usr/bin/head -n 1 || true; }  # <record text> <key>
rec_load() {  # <file>: sets REC_PID REC_LSTART REC_DIGEST REC_INC; fails, saying why in REC_WHY, unless the record is complete
  local text rc=0
  REC_WHY=""
  text=$(st rec-read "$1") || rc=$?  # O_NOFOLLOW and an owner check in the helper: a record that is a symlink or someone else's is refused, never read
  case "$rc" in
    0) ;;
    1) REC_WHY="$1 does not exist"; return 1 ;;
    9) die 6 "unsafe state: $text; refusing. Remove or fix it by hand, then re-run" ;;
    *) die 6 "reading $1 failed (helper exit $rc)" ;;
  esac
  REC_PID=$(rec_get "$text" pid); REC_LSTART=$(rec_get "$text" lstart); REC_DIGEST=$(rec_get "$text" digest); REC_INC=$(rec_get "$text" incarnation)
  case "$REC_PID" in ''|*[!0-9]*) REC_WHY="$1 has no valid pid"; return 1 ;; esac
  [ -n "$REC_LSTART" ] || { REC_WHY="$1 has no start time"; return 1; }
  printf '%s\n' "$REC_DIGEST" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || { REC_WHY="$1 has no valid launch digest"; return 1; }
  printf '%s\n' "$REC_INC" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' \
    || { REC_WHY="$1 has no valid incarnation"; return 1; }
}
rec_live() {  # <file>: the record is complete and its pid runs with the recorded start time (re-rendered now)
  local live
  rec_load "$1" || return 1
  live=$(ps_lstart "$REC_PID")
  [ -n "$live" ] || { REC_WHY="${1##*/}: pid $REC_PID is not running"; return 1; }
  [ "$live" = "$REC_LSTART" ] || { REC_WHY="${1##*/}: pid $REC_PID started '$live', the record says '$REC_LSTART' (reused pid)"; return 1; }
}
write_record() { st write-record "$@"; }  # <dest> <pid> <lstart> <digest> <incarnation>: the dest must be free (launch retires the old record first). The helper writes the temp O_EXCL|O_NOFOLLOW and publishes it (R17): fsync, no-clobber link, fsync the directory, unlink the temp, fsync its directory
retire_record() { if rec_present "$1"; then st retire "$1" || die 6 "refusing to retire $1 (see above)"; fi; }  # durable rename to <file>.retired.<epoch>; a symlink or someone else's file is refused

# A live process is ours only when a record names it: pid, start time, launch digest and incarnation. The start time is
# re-rendered now and must equal the recorded one, so a reused pid never qualifies. The digest is compared by ensure-daemon
# (adoption needs the current configuration); restart-daemon accepts any complete record, because replacing a daemon that
# runs an older configuration is exactly what it is for. daemon.json, when present, must agree on the pid (R7) unless
# the caller passes "any": then every live record counts, which is what a caller asks who must not launch over a live daemon.
find_ours_live() {  # [any]: sets OURS_PID OURS_LSTART OURS_SRC; OURS_WHY says why each record did not match
  local f dj
  OURS_PID=""; OURS_LSTART=""; OURS_SRC=""; OURS_WHY=""
  for f in "$PROV" "$INTENT"; do
    rec_present "$f" || continue
    if rec_live "$f"; then
      dj=$(djson pid)
      if [ "${1:-}" != any ] && [ -n "$dj" ] && [ "$dj" != "$REC_PID" ]; then
        OURS_WHY="$OURS_WHY${OURS_WHY:+; }daemon.json names pid $dj but ${f##*/} names pid $REC_PID"
        continue
      fi
      OURS_PID="$REC_PID"; OURS_LSTART="$REC_LSTART"; OURS_SRC="${f##*/}"
      return 0
    fi
    OURS_WHY="$OURS_WHY${OURS_WHY:+; }$REC_WHY"
  done
  return 1
}

# ---- allowlist (R11): names only, validated; reserved prefixes can never be passed on -------------
validate_allowlist() {
  ALLOW_NAMES=""
  [ -e "$ALLOW" ] || return 0
  [ -f "$ALLOW" ] || { echo "velo-task: $ALLOW is not a regular file" >&2; return 1; }
  local line key n=0 bad=0 p
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    key="${line#"${line%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in ''|'#'*) continue ;; esac
    if ! printf '%s\n' "$key" | LC_ALL=C /usr/bin/grep -Eq "$NAME_RE"; then
      echo "velo-task: $ALLOW line $n: not a valid variable name (value not shown)" >&2; bad=1; continue
    fi
    for p in PATH HOME IFS ENV BASH_ENV SHELLOPTS PYTHON DYLD_ LD_ VANTH_ VELO_TASK_ AGENT_BG_ TMPDIR; do
      case "$key" in "$p"*) echo "velo-task: $ALLOW line $n: $key is not allowed (reserved: $p)" >&2; bad=1; continue 2 ;; esac
    done
    ALLOW_NAMES="$ALLOW_NAMES$key"$'\n'
  done < "$ALLOW"
  ALLOW_NAMES=$(printf '%s' "$ALLOW_NAMES" | LC_ALL=C /usr/bin/sort -u)
  [ "$bad" -eq 0 ]
}
need_allowlist() { validate_allowlist || die 6 "allowlist rejected, nothing was started; fix $ALLOW"; }

need_install() {
  [ -f "$MARKER" ] && [ -x "$PY" ] && [ -x "$VANTHD" ] && [ -x "$VANTH" ] \
    || die 6 "Vanth is not installed in $VENV; run: velo-task install-vanth"
}

# ---- probe, launch digest, provenance, modes, listener ----------------------------------------------
vanth_env() { /usr/bin/env -i PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME="$VH" VANTH_DAEMON_PORT="$PORT" "$@"; }
probe_up() {  # bare `vanth --json status` is the health probe: it never autostarts a daemon (R6)
  local out
  out=$(vanth_env "$VANTH" --json status 2>/dev/null) || true
  [ -n "$out" ] && [ "$(printf '%s' "$out" | st json-get - up)" = true ]
}
launch_spec() {  # the launch command with allowlisted NAMES only: values are never recorded
  printf 'velo-task-launch-v1\numask=077\nvanthd=%s\nPATH=%s\nHOME=%s\nVANTH_HOME=%s\nAGENT_BG_HOME=%s\n' \
    "$VANTHD" "$JOB_PATH" "$HOME" "$VH" "$VH"
  printf 'VANTH_DAEMON_PORT=%s\nVANTH_RETENTION_SECONDS=0\n' "$PORT"
  [ -z "$ALLOW_NAMES" ] || printf 'allow=%s\n' $ALLOW_NAMES
}
launch_digest() { launch_spec | st sha256; }
prov_valid() {  # adoption: sets PROV_WHY when the running daemon is not provably the one we launched with this configuration
  local dj live
  PROV_WHY=""
  rec_present "$PROV" || { PROV_WHY="no $PROV: this daemon was not launched by velo-task"; return 1; }
  rec_load "$PROV" || { PROV_WHY="$REC_WHY; the record is incomplete"; return 1; }
  dj=$(djson pid)
  [ "$dj" = "$REC_PID" ] || { PROV_WHY="daemon.json pid '$dj' differs from provenance pid '$REC_PID'"; return 1; }
  live=$(ps_lstart "$REC_PID")
  [ -n "$live" ] || { PROV_WHY="provenance pid $REC_PID is not running"; return 1; }
  [ "$live" = "$REC_LSTART" ] || { PROV_WHY="pid $REC_PID started '$live', provenance says '$REC_LSTART' (stale provenance or reused pid)"; return 1; }
  within_5s "$(epoch_of_lstart "$REC_LSTART")" "$(epoch_of_iso "$(djson started_at)")" \
    || { PROV_WHY="daemon.json started_at is not within 5 s of the provenance start time"; return 1; }
  [ "$REC_DIGEST" = "$(launch_digest)" ] \
    || { PROV_WHY="launch digest differs from the current configuration (port, retention, allowlist or paths)"; return 1; }
}
modes_problem() {  # returns 0 and sets MODES_WHY when anything is looser than 0700 (directories) / 0600 (files); the helper does the walk
  local out rc=0
  MODES_WHY=""
  out=$(st modes-check "$VH" "$LAUNCH_LOG") || rc=$?
  case "$rc" in
    0) return 1 ;;
    8) MODES_WHY="$out"; return 0 ;;
    *) die 6 "the mode check failed (helper exit $rc): $out" ;;
  esac
}
need_modes() {  # on every lifecycle call, before any other action (R11(c)): jobs.sqlite*, token, daemon.json, the launch log, logs/, events/
  if modes_problem; then
    die 6 "$MODES_WHY; refusing. Tighten it (chmod -R go-rwx '$VH' '$LAUNCH_LOG') and run: velo-task restart-daemon"
  fi
}
check_loopback() {  # <pid>: the daemon's listening sockets are 127.0.0.1:$PORT and nothing else (R12, B23); sets LOOPBACK_WHY
  local out got
  LOOPBACK_WHY=""
  out=$(/usr/sbin/lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null) || true  # lsof exits 1 when it lists nothing
  got=$(printf '%s\n' "$out" | /usr/bin/grep '^n' | LC_ALL=C /usr/bin/sort -u | /usr/bin/tr '\n' ' ') || true
  [ "$got" = "n127.0.0.1:$PORT " ] && return 0
  LOOPBACK_WHY="pid $1 listens on '${got:-nothing}' but only 127.0.0.1:$PORT is allowed"
  return 1
}
refuse_unproven() {
  die 6 "a daemon answers on port $PORT but is not provably the one velo-task launched ($PROV_WHY); refusing to adopt it. If velo-task launched it, run: velo-task restart-daemon. Otherwise stop it by hand (the pid is in $VH/daemon.json), then run: velo-task ensure-daemon"
}

# ---- launch (caller holds the daemon lock and has passed need_modes) -------------------------------
abandon_launch() {  # <pid> <started> <why>: a launch that cannot be proven good; stops our own child, then refuses
  local pid="$1" started="$2" why="$3" deadline=$((SECONDS + ${VELO_TASK_STOP_WAIT:-20}))
  if [ -n "$started" ] && kill -0 "$pid" 2>/dev/null; then
    signal_validated TERM "$pid" "$started"
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep "${VELO_TASK_POLL:-0.2}"; done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    die 6 "$why; vanthd pid $pid is still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM and stays recorded in $INTENT (velo-task restart-daemon stops it)"
  fi
  retire_record "$INTENT"
  die 6 "$why"
}
launch_daemon() {
  local args names k pid started digest inc deadline
  still_locked
  /bin/mkdir -p -m 700 "$VH"
  args=(PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME="$VH" VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)
  names="PATH HOME VANTH_HOME AGENT_BG_HOME VANTH_DAEMON_PORT VANTH_RETENTION_SECONDS"
  for k in $ALLOW_NAMES; do
    if [ "${!k+set}" = set ]; then args[${#args[@]}]="$k=${!k}"; names="$names $k"; fi
  done
  retire_record "$PROV"; retire_record "$INTENT"
  digest=$(launch_digest); inc=$(/usr/bin/uuidgen)
  need_lock_py
  # The process started here IS the daemon, pid for pid: env -i hands the helper's launch-exec the lines above (R11(b): jobs see
  # exactly those and nothing else from the caller; the values sit in env's argv only until it execs the helper), launch-exec
  # publishes daemon.intent for its OWN pid and start time and only then execs vanthd, which keeps both. No kill of this shell,
  # at any point, can leave a running daemon without its intent; a kill before the exec leaves no daemon. launch-exec passes on
  # the NAMES listed and nothing else it holds, so the test seams that reach it never reach vanthd. umask 077 makes
  # jobs.sqlite, logs/, events/ and daemon.json private (R11(c)). Own process group, stdio detached from the caller, and the lock
  # descriptor (9 = LOCK_FD) closed: the daemon outlives this body.
  set -m
  ( umask 077; exec 9>&-; exec /usr/bin/env -i "${args[@]}" VELO_TASK_HOME="$VELO_TASK_HOME" ${SEAM_ENV[@]+"${SEAM_ENV[@]}"} \
      "$LOCK_PY" -I "$STATE_SCRIPT" launch-exec "$INTENT" "$digest" "$inc" "$VANTHD" $names </dev/null >"$LAUNCH_LOG" 2>&1 ) &
  pid=$!
  set +m
  started=$(ps_lstart "$pid")
  stl failpoint launch.started
  deadline=$((SECONDS + ${VELO_TASK_START_WAIT:-20}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || break
    if probe_up && [ "$(djson pid)" = "$pid" ]; then break; fi
    /bin/sleep "${VELO_TASK_POLL:-0.2}"
  done
  if ! { kill -0 "$pid" 2>/dev/null && probe_up && [ "$(djson pid)" = "$pid" ]; }; then
    abandon_launch "$pid" "$started" "vanthd did not become ready on port $PORT; see $LAUNCH_LOG: $(/usr/bin/tail -n 3 "$LAUNCH_LOG" 2>/dev/null | /usr/bin/tr '\n' ' ')"
  fi
  [ "$(ps_lstart "$pid")" = "$started" ] || abandon_launch "$pid" "$started" "vanthd pid $pid changed identity during launch"
  check_loopback "$pid" || abandon_launch "$pid" "$started" "$LOOPBACK_WHY"
  stl failpoint launch.ready
  write_record "$PROV" "$pid" "$started" "$digest" "$inc"
  retire_record "$INTENT"
  need_modes
  printf 'daemon up pid=%s port=%s (started)\n' "$pid" "$PORT"
}

# ---- the per-home lock (R17, R18): install, ensure and restart all run under it ----------------------
run_locked() {  # <function in this file>: run it in a child shell that holds the lock; the child is told the lock path
  local rc=0 v body
  if [ "${#HELPER_ENV[@]}" -eq 0 ]; then prep_env; fi
  body=("${HELPER_ENV[@]}")  # the body is the helper's child, so it inherits exactly this: the minimal environment, the tunables, the allowlisted names
  for v in VELO_TASK_PORT VELO_TASK_START_WAIT VELO_TASK_STOP_WAIT VELO_TASK_LOCK_WAIT VELO_TASK_POLL $ALLOW_NAMES; do
    if [ "${!v+set}" = set ]; then body[${#body[@]}]="$v=${!v}"; fi
  done
  need_lock_py
  /usr/bin/env -i "${body[@]}" "$LOCK_PY" -I "$STATE_SCRIPT" lock --timeout "${VELO_TASK_LOCK_WAIT:-60}" --child-fd "$LOCK_FD" "$LOCK_FILE" -- \
    /bin/bash -c 'set -euo pipefail; . "$1"; shift; "$@"' velo-task "$LIB_FILE" "$1" "$LOCK_FILE" || rc=$?
  case "$rc" in 0) ;; 75) die 6 "timed out waiting for the lock $LOCK_FILE" ;; 9) die 6 "the lock state is unsafe (see above); nothing was done" ;; *) exit "$rc" ;; esac
}
assert_lock_held() {  # <lock path>: a locked body runs only inside run_locked, holding the descriptor it was handed (LOCK_FD) on the file LOCK_FILE still names
  [ "${1:-}" = "$LOCK_FILE" ] && stl lock-held --fd "$LOCK_FD" "$LOCK_FILE" \
    || die 2 "refusing to run without the lock on $LOCK_FILE: this body is not a subcommand"
}
still_locked() { assert_lock_held "$LOCK_FILE"; }  # right before an action that cannot be undone (a launch, a signal, replacing the venv)
need_state() {  # nothing under the state root is a symlink, the wrong kind of node or someone else's (check-state lists them); nothing is followed
  local why rc=0
  why=$(stl check-state "$VELO_TASK_HOME") || rc=$?
  case "$rc" in
    0) ;;
    9) die 6 "unsafe state: $why; refusing. Remove or fix it by hand, then re-run" ;;
    *) die 6 "the state check failed (helper exit $rc): $why" ;;
  esac
}

cmd_ensure_daemon() { prep_env; need_state; need_install; need_allowlist; run_locked locked_ensure; }
locked_ensure() {  # R18: probe only once the lock is held; another caller may have started the daemon
  prep_env; assert_lock_held "${1:-}"; need_state
  need_install; need_allowlist; need_modes
  local pid
  if probe_up; then
    if ! prov_valid; then
      if rec_live "$INTENT"; then
        die 6 "a launch of vanthd pid $REC_PID was interrupted before it was recorded as good; it answers on port $PORT but is not adopted. Run: velo-task restart-daemon"
      fi
      refuse_unproven
    fi
    pid="$REC_PID"
    check_loopback "$pid" || die 6 "$LOOPBACK_WHY; refusing to adopt it. Run: velo-task restart-daemon"
    if rec_present "$INTENT" && { ! rec_live "$INTENT" || [ "$REC_PID" = "$pid" ]; }; then retire_record "$INTENT"; fi  # the launch it recorded is done
    printf 'daemon up pid=%s port=%s (adopted)\n' "$pid" "$PORT"
  else
    # Nothing answers. A live process a record names is a daemon velo-task launched (starting, hung, or a launch that was
    # interrupted): launching over it would retire the only proof it is ours, so refuse. Records of dead processes are
    # retired by the launch.
    if find_ours_live any; then
      die 6 "vanthd pid $OURS_PID (${OURS_SRC}) is running but does not answer on port $PORT; not launching a second daemon over it. Run: velo-task restart-daemon"
    fi
    stl failpoint daemon.lock.held  # between the probe and the launch: where a missing lock would race
    launch_daemon
  fi
}

cmd_restart_daemon() { prep_env; need_state; need_install; need_allowlist; run_locked locked_restart; }
locked_restart() {  # R7, R18: signal only a process a record proves is ours, re-validated right before the signal
  prep_env; assert_lock_held "${1:-}"; need_state
  need_install; need_allowlist; need_modes
  stl failpoint daemon.lock.held
  local deadline
  if find_ours_live; then
    stl failpoint restart.validated  # nothing after this point re-reads the records: the pid and start time validated above are what is signalled
    still_locked
    signal_validated TERM "$OURS_PID" "$OURS_LSTART"
    deadline=$((SECONDS + ${VELO_TASK_STOP_WAIT:-20}))
    while kill -0 "$OURS_PID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep "${VELO_TASK_POLL:-0.2}"; done
    ! kill -0 "$OURS_PID" 2>/dev/null || die 6 "vanthd pid $OURS_PID still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM; not escalating"
  elif find_ours_live any; then  # a record names a live process but daemon.json disagrees: not provably the daemon on this port
    die 6 "vanthd pid $OURS_PID (${OURS_SRC}) is recorded as launched by velo-task but ${OURS_WHY:-daemon.json disagrees}; not signalled. Stop it by hand, then run: velo-task ensure-daemon"
  elif probe_up; then
    die 6 "a daemon answers on port $PORT but no velo-task record proves velo-task launched it (${OURS_WHY:-no $PROV or $INTENT}); not signalled. Stop it by hand (the pid is in $VH/daemon.json), then run: velo-task ensure-daemon"
  fi
  launch_daemon
}

# ---- install-vanth (R11, R12, B23): lock + --require-hashes + wheels only, then assert ---------------
resolve_uv() {  # the pinned Homebrew uv; VELO_TASK_UV (in this body's environment only when the test capability held: prep_env) replaces it
  UV="${VELO_TASK_UV:-$UV_PINNED}"
  [ -x "$UV" ] || die 6 "uv not found at $UV; velo-task installs through the Homebrew uv (brew install uv)"
}
run_uv() {  # uv sees nothing of the caller's: fixed system dirs for PATH (where it looks for an interpreter), HOME for its cache, TMPDIR and LANG when set
  local uvenv
  uvenv=(PATH="$INSTALL_PATH" HOME="$HOME")
  if [ -n "${TMPDIR:-}" ]; then uvenv[${#uvenv[@]}]="TMPDIR=$TMPDIR"; fi
  if [ -n "${LANG:-}" ]; then uvenv[${#uvenv[@]}]="LANG=$LANG"; fi
  /usr/bin/env -i "${uvenv[@]}" "$UV" "$@"
}
norm_names() { /usr/bin/awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }'; }
venv_in_use() {  # a daemon runs from this venv: a record names a live process, or daemon.json's pid runs a command from the venv
  local pid cmd
  [ -x "$PY" ] || return 1
  if find_ours_live any; then return 0; fi
  pid=$(djson pid)
  if [ -n "$pid" ]; then
    cmd=$(/bin/ps -ww -o command= -p "$pid" 2>/dev/null || true)
    case "$cmd" in *"$VENV/"*) return 0 ;; esac
  fi
  return 1
}
fail_install() {
  ! venv_in_use || die 6 "install-vanth: $*; a daemon is running from $VENV, so the venv was left in place. Stop the daemon first (SIGTERM the pid in $VH/daemon.json), then re-run install-vanth"
  /bin/rm -rf "$VENV"; die 1 "install-vanth failed, $VENV removed: $*"
}
verify_install() {
  local site tmp locked installed
  locked=$(/usr/bin/sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$LOCKFILE" | norm_names | LC_ALL=C /usr/bin/sort -u)
  installed=$(run_uv pip freeze --no-config --python "$PY" | norm_names | LC_ALL=C /usr/bin/sort -u) || fail_install "uv pip freeze"
  [ "$locked" = "$installed" ] \
    || fail_install "installed distributions differ from the lock: $(/usr/bin/diff <(echo "$locked") <(echo "$installed") | /usr/bin/tr '\n' ' ')"
  site=$("$PY" -I -c 'import os, vanth; print(os.path.dirname(vanth.__file__))') || fail_install "vanth is not importable"
  /usr/bin/grep -rqF --include='*.py' 'trigger parent reached an incompatible terminal status' "$site" \
    || fail_install "the pinned trigger-parent stop reason is absent from the installed Vanth (R1)"
  tmp=$(/usr/bin/mktemp -d "$VENV/schema.XXXXXX")  # inside the venv: fail_install removes it with the venv
  "$PY" -I -c 'import sqlite3, sys; from vanth.migrations import migrate; db = sqlite3.connect(sys.argv[1] + "/jobs.sqlite"); migrate(db, sys.argv[1]); db.close()' "$tmp" \
    || fail_install "the installed Vanth could not create its schema"
  st jobs-ro "$tmp/jobs.sqlite" 'SELECT 1 AS ok' >/dev/null || fail_install "the installed Vanth schema lacks columns the spec reads (R8)"
  /bin/rm -rf "$tmp"
}
cmd_install_vanth() {
  [ -f "$LOCKFILE" ] || die 1 "lock file not found: $LOCKFILE"
  prep_env; need_state
  /bin/mkdir -p -m 700 "$VELO_TASK_HOME"
  run_locked locked_install
}
locked_install() {  # the same lock as ensure and restart: nothing can launch or signal while the venv is rebuilt
  prep_env; assert_lock_held "${1:-}"; need_state
  stl failpoint install.lock.held
  local want
  resolve_uv
  if [ -x "$PY" ] && [ -f "$MARKER" ]; then
    want=$(st sha256 "$LOCKFILE")
    if [ "$(/bin/cat "$MARKER")" = "$want" ]; then
      verify_install
      echo "install-vanth: already installed from the current lock"
      return 0
    fi
  fi
  if venv_in_use; then
    die 6 "a daemon is running from $VENV; stop it before replacing the venv (SIGTERM the pid in $VH/daemon.json)"
  fi
  still_locked
  /bin/rm -f "$MARKER"
  run_uv venv --no-config --python 3.12 --clear "$VENV" || fail_install "uv venv"
  run_uv pip install --no-config --python "$PY" --default-index https://pypi.org/simple \
    --require-hashes --only-binary :all: -r "$LOCKFILE" || fail_install "uv pip install"
  verify_install
  st sha256 "$LOCKFILE" > "$MARKER"
  echo "install-vanth: installed $(/usr/bin/sed -n 's/^vanth==\([^ ]*\).*/\1/p' "$LOCKFILE") into $VENV"
}

# ---- doctor: read-only; never starts, signals, locks or modifies anything ---------------------------
cmd_doctor() {
  local rc=0 pid why
  ok() { printf 'ok   %s\n' "$*"; }
  bad() { printf 'FAIL %s\n' "$*"; rc=1; }
  prep_env
  if ! why=$(stl check-state --owner-only "$VELO_TASK_HOME"); then bad "state: ${why:-the state check failed}; nothing else was read"; return "$rc"; fi
  if [ -f "$MARKER" ] && [ -x "$PY" ] && [ -x "$VANTHD" ] && [ -x "$VANTH" ]; then
    if [ "$(/bin/cat "$MARKER")" = "$(st sha256 "$LOCKFILE")" ]; then ok "install: $VENV matches the lock"
    else bad "install: $VENV was built from a different lock; run velo-task install-vanth, then restart-daemon"; fi
  else
    bad "install: no complete venv at $VENV; run velo-task install-vanth"; return "$rc"
  fi
  if validate_allowlist 2>/dev/null; then ok "allowlist: $(printf '%s' "$ALLOW_NAMES" | /usr/bin/grep -c . || true) key(s)"
  else bad "allowlist: rejected (see: velo-task ensure-daemon)"; fi
  if [ ! -d "$VH" ]; then ok "daemon: never started (home $VH absent)"
  elif probe_up; then
    pid=$(djson pid)
    ok "daemon: up on port $PORT (pid $pid)"
    if prov_valid; then ok "provenance: valid"; else bad "provenance: $PROV_WHY (run: velo-task restart-daemon)"; fi
    if check_loopback "$pid"; then ok "bind: 127.0.0.1:$PORT only (listener of pid $pid)"; else bad "bind: $LOOPBACK_WHY"; fi
  else
    ok "daemon: down (ensure-daemon starts it)"
  fi
  if [ -d "$VH" ]; then
    if modes_problem; then bad "modes: $MODES_WHY"; else ok "modes: private"; fi
  fi
  if rec_present "$INTENT"; then
    if rec_live "$INTENT"; then bad "intent: a launch of vanthd pid $REC_PID was interrupted before it was recorded as good (run: velo-task restart-daemon)"
    else ok "intent: stale ($REC_WHY); ensure-daemon retires it"; fi
  fi
  if [ -f "$VH/jobs.sqlite" ]; then
    if st jobs-ro "$VH/jobs.sqlite" 'SELECT 1 AS ok' >/dev/null; then ok "schema: matches the spec's columns"
    else bad "schema: jobs-ro exit $? (4 locked, 5 mismatch)"; fi
  fi
  return "$rc"
}

# ---- run and status (R1-R5, R17): the verdict is computed by the helper alone, never here ------------
need_daemon() {  # R6, R7: ensure-daemon first (its stdout is not ours); a daemon that cannot be reached or started is exit 6 and the recovery command, never a verdict
  local rc=0
  (cmd_ensure_daemon >/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || die 6 "daemon-down: ensure-daemon failed (exit $rc); recover with: velo-task restart-daemon"
}
check_arg() {  # <kind> <value>: the R3 charsets, matched against the whole value
  local re
  case "$1" in
    id) re='^[a-z0-9][a-z0-9_-]{2,63}$' ;;
    job) re='^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' ;;
    issue) re='^[0-9]{1,9}$' ;;
    timeout) re='^[1-9][0-9]{0,8}$' ;;
    stage) re='^[a-z0-9][a-z0-9_-]{0,31}$' ;;
    session) re='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' ;;
  esac
  [[ "$2" =~ $re ]] || die 2 "invalid $1 '$2': must match $re"
}
session_id() {  # [<id>|me]: <id> as given, else $CLAUDE_SESSION_ID, else the token this state dir keeps (made on first use; a script cannot tell shells apart, so every shell without an id shares it)
  local s="${1:-me}"
  [ "$s" != me ] || s="${CLAUDE_SESSION_ID:-}"
  [ -n "$s" ] || s=$(st session-token "$SESSION_FILE") || die 6 "the session token is unsafe or unreadable (see above)"
  check_arg session "$s"; printf '%s' "$s"
}
rerun_nonce() {  # <attempt>: the R4 key suffix <epoch>_<pid>_<rand8>; VELO_TASK_RERUN_NONCE (tests only, see prep_env) is that suffix, or a comma list of them, one per attempt, the last repeating
  local parts n
  if [ -z "${VELO_TASK_RERUN_NONCE:-}" ]; then
    printf '%s_%s_%s' "$(/bin/date +%s)" "$$" "$(/usr/bin/od -An -N4 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    return 0
  fi
  IFS=, read -r -a parts <<<"$VELO_TASK_RERUN_NONCE"
  n=$(( $1 < ${#parts[@]} ? $1 : ${#parts[@]} ))
  printf '%s' "${parts[$((n - 1))]}"
}
start_refused() {  # <exit> <vanth output> <pending nonce>: vanth start returned no job
  case "$2" in
    *"idempotency_key was already used"*|*"idempotency_key refers to cleaned job"*)  # Vanth refused this request outright: nothing was started, so nothing is pending
      st remove "$PENDING/$3"
      die 5 "IDEMPOTENCY_CONFLICT: ${2#vanth start: }; this id was already started (with other settings, or its job was cleaned): use --rerun for a new execution" ;;
    *"failed to reach daemon"*) die 6 "daemon-down: $2; whether the start was accepted is unknown, so $PENDING/$3 is kept; recover with: velo-task restart-daemon" ;;
    *) die 1 "vanth start failed (exit $1): $2; whether it was accepted is unknown, so $PENDING/$3 is kept" ;;
  esac
}
reconcile_id() {  # <id>: settle the id's pending records against Vanth's own acceptance record before its name index is read (R3, R17). Returns 3, after `pending-unsent <id>` on stderr, when a record is left that Vanth has no key for; anything else that goes wrong stops the caller
  local rc=0
  st reconcile "$PENDING" "$NAMES" "$VH/jobs.sqlite" "$1" || rc=$?
  case "$rc" in 0|3) return "$rc" ;; esac
  die 6 "reconcile of '$1' failed (helper exit $rc, see above); nothing was resolved"
}
cmd_run() {
  local id timeout="" issue="" stage="" have_issue=0 have_stage=0 rerun=0 cmdline=() args=() n=0 key out rc pending job cwd known session s8
  [ "$#" -gt 0 ] || die 2 "usage: velo-task run <id> --timeout S [--issue N] [--stage ST] [--rerun] -- cmd..."
  id="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout|--issue|--stage)
        [ "$#" -ge 2 ] || die 2 "$1 needs a value"
        case "$1" in --timeout) timeout="$2" ;; --issue) issue="$2"; have_issue=1 ;; *) stage="$2"; have_stage=1 ;; esac
        shift 2 ;;
      --rerun) rerun=1; shift ;;
      --) shift; cmdline=("$@"); break ;;
      *) die 2 "unknown option '$1' (the command goes after --)" ;;
    esac
  done
  check_arg id "$id"
  [ -n "$timeout" ] || die 2 "--timeout S is required: every job is started with a deadline (R2)"
  check_arg timeout "$timeout"
  [ "$have_issue" = 0 ] || check_arg issue "$issue"
  [ "$have_stage" = 0 ] || check_arg stage "$stage"
  [ "${#cmdline[@]}" -gt 0 ] || die 2 "no command: expected -- cmd..."
  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"  # refused now, before the daemon is touched
  prep_env
  need_daemon
  /bin/mkdir -p -m 700 "$NAMES" "$PENDING"
  session=$(session_id) || exit "$?"
  s8=$(printf '%s' "$session" | st sha256) || exit "$?"; s8="${s8:0:8}"  # two sessions starting the same id get different keys, so different jobs
  cwd=$(pwd -P)
  rc=0; st index-last "$NAMES" "$id" >/dev/null || rc=$?  # an unsafe name index is found now, not after the job was started
  [ "$rc" -le 1 ] || die 6 "the name index of '$id' is unsafe or unreadable (see above); nothing was started"
  rc=0; reconcile_id "$id" || rc=$?  # a run that died after its start was accepted is indexed first, so the last line stays the last job started; 3 is reported on stderr, never replayed here
  while :; do
    n=$((n + 1))
    key="velo_${s8}_$id"
    if [ "$rerun" = 1 ]; then key="${key}_$(rerun_nonce "$n")"; fi
    args=(--name "$id" --timeout "$timeout" --idempotency-key "$key" --cwd "$cwd" --tag velo --tag "session:$session")
    if [ "$have_issue" = 1 ]; then args=("${args[@]}" --tag "issue:$issue"); fi
    if [ "$have_stage" = 1 ]; then args=("${args[@]}" --tag "stage:$stage"); fi
    pending=$(st pending-write "$PENDING" -- "${args[@]}" -- "${cmdline[@]}")  # R17 (1): the settings are durable before anything is sent
    stl failpoint pending.published
    rc=0
    out=$(vanth_env "$VANTH" --json start "${args[@]}" -- "${cmdline[@]}" 2>&1) || rc=$?  # R17 (2); exit 1 also comes with the JSON of a job that failed to start
    job=$(printf '%s\n' "$out" | /usr/bin/grep -v '^vanth start:' | st json-get - job_id 2>/dev/null) || job=""
    [ -n "$job" ] || start_refused "$rc" "$out" "$pending"
    stl failpoint start.returned
    known=0; st index-has "$NAMES" "$job" "$id" || known=$?  # 0 listed under this id, 1 not listed, else unreadable
    [ "$known" -le 1 ] || die 6 "the name index is unsafe or unreadable (see above)"
    if [ "$known" = 0 ] && [ "$rerun" = 1 ] && [ -e "$PENDING/$pending" ]; then  # R4: Vanth returned a job we already know, so the key collided with an earlier run; unless a reconcile settled this run's own record and indexed its job
      st remove "$PENDING/$pending"
      if [ "$n" -ge 5 ]; then die 5 "--rerun: Vanth returned an already indexed job for $n keys in a row; nothing new was started"; fi
      continue
    fi
    if [ "$known" = 1 ]; then st append-index "$NAMES/$id" "$job"; stl failpoint index.appended; fi  # R17 (3)
    st remove "$PENDING/$pending"  # R17 (4)
    stl failpoint pending.unlinked
    printf '%s\n' "$job"
    return 0
  done
}
cmd_status() {
  local id="" job="" issue="" session="" have_id=0 have_job=0 have_issue=0 have_session=0 all=0 json=0 absent=0 unsent=0 out rc=0 vargs why
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --all) all=1; shift ;;
      --issue|--job|--session)
        [ "$#" -ge 2 ] || die 2 "$1 needs a value"
        case "$1" in --job) job="$2"; have_job=1 ;; --session) session="$2"; have_session=1 ;; *) issue="$2"; have_issue=1 ;; esac
        shift 2 ;;
      -*) die 2 "unknown option '$1'" ;;
      *) [ "$have_id" = 0 ] || die 2 "status takes one id"; id="$1"; have_id=1; shift ;;
    esac
  done
  [ "$all$have_session" != 11 ] || die 2 "--session and --all exclude each other"
  [ "$all" = 0 ] || [ "$have_id$have_job" = 00 ] || die 2 "--all lists the jobs of every session: it takes no id and no --job"
  if [ "$have_id$have_job" = 11 ]; then die 2 "usage: velo-task status [--json] [--issue N] [--session S] <id> | --job <job_id>  or, to list: [--session S | --all] [--issue N] [--json]"
  elif [ "$have_id" = 1 ]; then check_arg id "$id"
  elif [ "$have_job" = 1 ]; then check_arg job "$job"; fi
  [ "$have_issue" = 0 ] || check_arg issue "$issue"
  [ "$have_session" = 0 ] || [ "$session" = me ] || check_arg session "$session"
  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"  # as in run: refused whether or not this status uses it
  prep_env
  if [ "$have_id$have_job" = 00 ]; then  # no id: list the jobs of one session (default: this caller's) or of all; jobs.sqlite is read read-only (R8), so no daemon is needed
    why=$(stl check-state --owner-only "$VELO_TASK_HOME") || die 6 "state: ${why:-the state check failed}; nothing was read"
    [ -e "$VH/jobs.sqlite" ] || return 0  # nothing has ever run here
    vargs=(--list --names "$NAMES" --db "$VH/jobs.sqlite")
    if [ "$all" = 0 ]; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi
    if [ "$have_issue" = 1 ]; then vargs=("${vargs[@]}" --issue "$issue"); fi
    if [ "$json" = 1 ]; then vargs=("${vargs[@]}" --json); fi
    st verdict-of "${vargs[@]}"; return
  fi
  need_daemon
  if [ -n "$id" ]; then  # R3: the last job run indexed under the id; never vanth list, which caps at 1,000 rows and matches names by substring
    reconcile_id "$id" || unsent=$?  # a run that died after its start was accepted has its job indexed now
    job=$(st index-last "$NAMES" "$id") || rc=$?
    if [ "$rc" = 1 ] && [ "$unsent" = 3 ]; then die 3 "pending-unsent $id: Vanth has no record of this start, so it may never have been sent; re-run \`velo-task run $id ...\` (idempotent: the same key returns the existing job)"; fi
    case "$rc" in
      0) ;;
      1) die 2 "no job named '$id' in the name index; address a job by its id with --job <job_id>" ;;
      *) die 6 "the name index of '$id' is unsafe or unreadable (see above)" ;;
    esac
  fi
  out=$(vanth_env "$VANTH" --json status "$job" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"unknown job"*) absent=1 ;;
      *"failed to reach daemon"*) die 6 "daemon-down: $out; no verdict was read; recover with: velo-task restart-daemon" ;;
      *) die 1 "vanth status failed (exit $rc): $out" ;;
    esac
  fi
  vargs=(--names "$NAMES" --db "$VH/jobs.sqlite" --job "$job")
  if [ -n "$id" ]; then vargs=("${vargs[@]}" --name "$id" --label "$id"); fi  # the row's name must equal the id exactly, whatever the index said
  if [ "$have_issue" = 1 ]; then vargs=("${vargs[@]}" --issue "$issue"); fi
  if [ "$have_session" = 1 ]; then session=$(session_id "$session") || exit "$?"; vargs=("${vargs[@]}" --session "$session"); fi  # any owner unless asked
  if [ "$json" = 1 ]; then vargs=("${vargs[@]}" --json); fi
  if [ "$absent" = 1 ]; then st verdict-of --absent "${vargs[@]}"; else printf '%s\n' "$out" | st verdict-of "${vargs[@]}"; fi
}

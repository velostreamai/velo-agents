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
# Layout (VELO_TASK_HOME defaults to ${VELO_STATE:-~/.agents/state}/velo-task; tests override it):
#   venv/               pinned Vanth install      vanth/              VANTH_HOME = AGENT_BG_HOME
#   vanth.env.allow     secret NAMES the daemon may inherit (one per line)
#   daemon.intent       pid, start time, launch digest, incarnation of a daemon being launched (before it is known good)
#   daemon.provenance   the same for the daemon velo-task launched and proved ready
#   *.retired.<epoch>   records retired for good      lock/daemon         per-home lock for install, ensure, restart
#   daemon.launch.log   vanthd stdout/stderr
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
UV_PINNED=/opt/homebrew/bin/uv
INSTALL_PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
LOCK_PY_CANDIDATES="/opt/homebrew/bin/python3 /usr/bin/python3"
LOCK_PY=""
UV=""
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
st() { "$PY" "$STATE_SCRIPT" "$@"; }
stl() {
  if [ -z "$LOCK_PY" ]; then
    local p
    for p in $LOCK_PY_CANDIDATES; do
      if [ -x "$p" ]; then LOCK_PY="$p"; break; fi
    done
    [ -n "$LOCK_PY" ] || die 6 "no Python 3 for the state helper's lock (looked for: $LOCK_PY_CANDIDATES)"
  fi
  "$LOCK_PY" "$STATE_SCRIPT" "$@"
}

case "$VELO_TASK_HOME" in /*) ;; *) die 2 "VELO_TASK_HOME must be an absolute path: $VELO_TASK_HOME" ;; esac
case "$PORT" in ''|*[!0-9]*) die 2 "VELO_TASK_PORT must be a number: $PORT" ;; esac

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
rec_get() { /usr/bin/sed -n "s/^$2=//p" "$1" 2>/dev/null | /usr/bin/head -n 1 || true; }  # <file> <key>
rec_load() {  # <file>: sets REC_PID REC_LSTART REC_DIGEST REC_INC; fails, saying why in REC_WHY, unless the record is complete
  REC_WHY=""
  REC_PID=$(rec_get "$1" pid); REC_LSTART=$(rec_get "$1" lstart); REC_DIGEST=$(rec_get "$1" digest); REC_INC=$(rec_get "$1" incarnation)
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
write_record() {  # <dest> <pid> <lstart> <digest> <incarnation>: the dest must be free (launch retires the old record first)
  local tmp="$1.tmp.$$"
  ( umask 077; printf 'pid=%s\nlstart=%s\ndigest=%s\nincarnation=%s\n' "$2" "$3" "$4" "$5" > "$tmp" )
  st publish "$1" "$tmp"  # R17: fsync, no-clobber link, fsync the directory, unlink the temp, fsync its directory
}
retire_record() { if [ -e "$1" ]; then st retire "$1"; fi; }  # durable rename to <file>.retired.<epoch>

# A live process is ours only when a record names it: pid, start time, launch digest and incarnation. The start time is
# re-rendered now and must equal the recorded one, so a reused pid never qualifies. The digest is compared by ensure-daemon
# (adoption needs the current configuration); restart-daemon accepts any complete record, because replacing a daemon that
# runs an older configuration is exactly what it is for. daemon.json, when present, must agree on the pid (R7) unless
# the caller passes "any": then every live record counts, which is what a caller asks who must not launch over a live daemon.
find_ours_live() {  # [any]: sets OURS_PID OURS_LSTART OURS_SRC; OURS_WHY says why each record did not match
  local f dj
  OURS_PID=""; OURS_LSTART=""; OURS_SRC=""; OURS_WHY=""
  for f in "$PROV" "$INTENT"; do
    [ -e "$f" ] || continue
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
  [ -f "$PROV" ] || { PROV_WHY="no $PROV: this daemon was not launched by velo-task"; return 1; }
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
  local args k pid started digest inc deadline
  /bin/mkdir -p -m 700 "$VH"
  args=(PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME="$VH" VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0)
  for k in $ALLOW_NAMES; do
    if [ "${!k+set}" = set ]; then args[${#args[@]}]="$k=${!k}"; fi
  done
  retire_record "$PROV"; retire_record "$INTENT"
  digest=$(launch_digest); inc=$(/usr/bin/uuidgen)
  # env -i: jobs see exactly the lines above and nothing else from the caller (R11(b)). The values sit in env's argv only until
  # it execs vanthd. umask 077 makes jobs.sqlite, logs/, events/ and daemon.json private (R11(c)). Own process group, stdio
  # detached from the caller.
  set -m
  ( umask 077; exec /usr/bin/env -i "${args[@]}" "$VANTHD" </dev/null >"$LAUNCH_LOG" 2>&1 ) &
  pid=$!
  set +m
  started=$(ps_lstart "$pid")
  stl failpoint launch.started
  if [ -n "$started" ]; then  # the intent is what lets restart-daemon prove a daemon that crashed before it was known good is ours
    write_record "$INTENT" "$pid" "$started" "$digest" "$inc"
    stl failpoint launch.intent
  fi
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
  local rc=0
  stl lock --timeout "${VELO_TASK_LOCK_WAIT:-60}" "$LOCK_FILE" -- \
    /bin/bash -c 'set -euo pipefail; . "$1"; shift; "$@"' velo-task "$LIB_FILE" "$1" "$LOCK_FILE" || rc=$?
  case "$rc" in 0) ;; 75) die 6 "timed out waiting for the lock $LOCK_FILE" ;; *) exit "$rc" ;; esac
}
assert_lock_held() {  # <lock path>: a locked body runs only inside run_locked
  [ "${1:-}" = "$LOCK_FILE" ] && stl lock-held "$LOCK_FILE" \
    || die 2 "refusing to run without the lock on $LOCK_FILE: this body is not a subcommand"
}

cmd_ensure_daemon() { need_install; need_allowlist; run_locked locked_ensure; }
locked_ensure() {  # R18: probe only once the lock is held; another caller may have started the daemon
  assert_lock_held "${1:-}"
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
    if [ -e "$INTENT" ] && { ! rec_live "$INTENT" || [ "$REC_PID" = "$pid" ]; }; then retire_record "$INTENT"; fi  # the launch it recorded is done
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

cmd_restart_daemon() { need_install; need_allowlist; run_locked locked_restart; }
locked_restart() {  # R7, R18: signal only a process a record proves is ours, re-validated right before the signal
  assert_lock_held "${1:-}"
  need_install; need_allowlist; need_modes
  stl failpoint daemon.lock.held
  local deadline
  if find_ours_live; then
    stl failpoint restart.validated  # nothing after this point re-reads the records: the pid and start time validated above are what is signalled
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
resolve_uv() {  # the pinned Homebrew uv; VELO_TASK_UV replaces it only under the test capability
  UV="$UV_PINNED"
  if [ -n "${VELO_TASK_UV:-}" ]; then
    stl test-capability || die 2 "VELO_TASK_UV is set but refused: it is honoured only under the test capability (VELO_TASK_TEST=1 and a test root)"
    UV="$VELO_TASK_UV"
  fi
  [ -x "$UV" ] || die 6 "uv not found at $UV; velo-task installs through the Homebrew uv (brew install uv)"
}
run_uv() { PATH="$INSTALL_PATH" "$UV" "$@"; }  # uv sees fixed system dirs, never the caller's PATH, when it looks for an interpreter
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
  site=$("$PY" -c 'import os, vanth; print(os.path.dirname(vanth.__file__))') || fail_install "vanth is not importable"
  /usr/bin/grep -rqF --include='*.py' 'trigger parent reached an incompatible terminal status' "$site" \
    || fail_install "the pinned trigger-parent stop reason is absent from the installed Vanth (R1)"
  tmp=$(/usr/bin/mktemp -d "$VENV/schema.XXXXXX")  # inside the venv: fail_install removes it with the venv
  "$PY" -c 'import sqlite3, sys; from vanth.migrations import migrate; db = sqlite3.connect(sys.argv[1] + "/jobs.sqlite"); migrate(db, sys.argv[1]); db.close()' "$tmp" \
    || fail_install "the installed Vanth could not create its schema"
  st jobs-ro "$tmp/jobs.sqlite" 'SELECT 1 AS ok' >/dev/null || fail_install "the installed Vanth schema lacks columns the spec reads (R8)"
  /bin/rm -rf "$tmp"
}
cmd_install_vanth() {
  [ -f "$LOCKFILE" ] || die 1 "lock file not found: $LOCKFILE"
  /bin/mkdir -p -m 700 "$VELO_TASK_HOME"
  run_locked locked_install
}
locked_install() {  # the same lock as ensure and restart: nothing can launch or signal while the venv is rebuilt
  assert_lock_held "${1:-}"
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
  local rc=0 pid
  ok() { printf 'ok   %s\n' "$*"; }
  bad() { printf 'FAIL %s\n' "$*"; rc=1; }
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
  if [ -e "$INTENT" ]; then
    if rec_live "$INTENT"; then bad "intent: a launch of vanthd pid $REC_PID was interrupted before it was recorded as good (run: velo-task restart-daemon)"
    else ok "intent: stale ($REC_WHY); ensure-daemon retires it"; fi
  fi
  if [ -f "$VH/jobs.sqlite" ]; then
    if st jobs-ro "$VH/jobs.sqlite" 'SELECT 1 AS ok' >/dev/null; then ok "schema: matches the spec's columns"
    else bad "schema: jobs-ro exit $? (4 locked, 5 mismatch)"; fi
  fi
  return "$rc"
}

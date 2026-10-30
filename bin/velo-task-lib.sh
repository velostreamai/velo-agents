#!/bin/bash
# velo-task-lib.sh - the functions behind bin/velo-task (docs/velo-task-spec.md). Sourced, never run: by bin/velo-task and by the hooks.
#
# Vanth (jobs.sqlite and `vanth --json ...`) is the only state: no index, no pending records, no locks of ours. What is here is what Vanth
# does not do: the pinned install, a daemon launched private (umask 077) and with only the allowlisted secrets (Vanth autostarts its
# daemon with the caller's environment and leaves jobs.sqlite world-readable), the closed verdict set, the required --timeout, tags.
# Every external program is run by absolute path; JSON is read by the state helper, not jq. State, under VELO_TASK_HOME (default
# ${VELO_STATE:-~/.agents/state}/velo-task; tests override it):
#   venv/ pinned Vanth        vanth/ VANTH_HOME        vanth.env.allow secret NAMES the daemon may inherit (one per line)
#   daemon.provenance pid, start time, launch digest of the daemon velo-task launched     daemon.launch.log vanthd stdout/stderr
#   session the owner token run tags jobs with when $CLAUDE_SESSION_ID is unset      stop-override, overrides.log the Stop guard's one-shot escape
# VELO_TASK_PORT (default 48217) sets the daemon port. Tunables: VELO_TASK_START_WAIT, VELO_TASK_STOP_WAIT (seconds), VELO_TASK_POLL
# (poll interval). Exit codes: 0 ok, 1 error, 2 usage, 3 wait timeout, 4 cancel: already finished, 5 idempotency conflict, 6 daemon refused/down/misconfigured.

LIB_SRC="${BASH_SOURCE[0]}"
LIB_SRC_DIR="${LIB_SRC%/*}"; [ "$LIB_SRC_DIR" != "$LIB_SRC" ] || LIB_SRC_DIR=.
LIB_DIR="$(cd "$LIB_SRC_DIR" && pwd)"
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
LAUNCH_LOG="$VELO_TASK_HOME/daemon.launch.log"
SESSION_FILE="$VELO_TASK_HOME/session"
UV_PINNED=/opt/homebrew/bin/uv
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
PYSYS=""
for p in /opt/homebrew/bin/python3 /usr/bin/python3; do [ -x "$p" ] && { PYSYS="$p"; break; }; done
# Jobs inherit the daemon's environment: a fixed PATH, HOME, Vanth's own variables, allowlisted names.
JOB_PATH="$HOME/.agents/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NAME_RE='^[A-Z][A-Z0-9_]*$'
ALLOW_NAMES=""
PROV_WHY=""
HELPER_ENV=(PATH="$SYS_PATH" HOME="$HOME" VELO_TASK_HOME="$VELO_TASK_HOME")
[ -z "${TMPDIR:-}" ] || HELPER_ENV[${#HELPER_ENV[@]}]="TMPDIR=$TMPDIR"
[ -z "${LANG:-}" ] || HELPER_ENV[${#HELPER_ENV[@]}]="LANG=$LANG"

die() { local code="$1"; shift; printf 'velo-task: %s\n' "$*" >&2; exit "$code"; }
[ -n "$PYSYS" ] || die 6 "no Python 3 for the state helper (looked for /opt/homebrew/bin/python3 /usr/bin/python3)"
st() { /usr/bin/env -i "${HELPER_ENV[@]}" "$PYSYS" -I "$STATE_SCRIPT" "$@"; }  # the helper sees nothing of the caller's environment (python -I: no PYTHON*, no user site)

case "$VELO_TASK_HOME" in /*) ;; *) die 2 "VELO_TASK_HOME must be an absolute path: $VELO_TASK_HOME" ;; esac
case "$PORT" in ''|*[!0-9]*) die 2 "VELO_TASK_PORT must be a number: $PORT" ;; esac
for v in VELO_TASK_START_WAIT VELO_TASK_STOP_WAIT; do  # evaluated by bash arithmetic, which runs command substitutions: a number or refused
  case "${!v:-0}" in *[!0-9]*) die 2 "$v must be a whole number of seconds: ${!v}" ;; esac
done
case "${VELO_TASK_POLL:-0}" in *[!0-9.]*) die 2 "VELO_TASK_POLL must be a number of seconds: $VELO_TASK_POLL" ;; esac
unset v p

ps_lstart() {  # <pid> -> start time (LC_ALL=C TZ=UTC, whatever the caller's locale), empty when no such process
  LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1" 2>/dev/null | /usr/bin/sed -e 's/  */ /g; s/^ //; s/ $//' || true
}
djson() { st json-get "$VH/daemon.json" "$1" || die 6 "$VH/daemon.json cannot be read as JSON (see above), so the pid in it proves nothing; remove or fix it by hand"; }  # Vanth writes daemon.json (pid, url, started_at)
sha_of() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }  # stdin -> hex SHA-256
poll() { /bin/sleep "${VELO_TASK_POLL:-0.2}"; }

# ---- allowlist: secret names only, validated; reserved prefixes can never be passed on ----------------
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
inherited_names() {  # the allowlisted names this environment sets, one a line: what the daemon is told to pass on
  local k
  for k in $ALLOW_NAMES; do
    if [ "${!k+set}" = set ]; then printf '%s\n' "$k"; fi
  done
}

need_home() {  # the state root is private (0700) before anything is kept in it
  [ ! -L "$VELO_TASK_HOME" ] || die 6 "$VELO_TASK_HOME is a symlink; refusing"
  /bin/mkdir -p -m 700 "$VELO_TASK_HOME"
  [ "$(/usr/bin/stat -f %Lp "$VELO_TASK_HOME")" = 700 ] || die 6 "$VELO_TASK_HOME must have mode 700; refusing"
}
need_install() {
  [ -f "$MARKER" ] && [ -x "$PY" ] && [ -x "$VANTHD" ] && [ -x "$VANTH" ] || die 6 "Vanth is not installed in $VENV; run: velo-task install-vanth"
}

# ---- the daemon: probe, launch digest, provenance, modes, listener -----------------------------------
vanth_env() { /usr/bin/env -i PATH="$JOB_PATH" HOME="$HOME" VANTH_HOME="$VH" AGENT_BG_HOME="$VH" VANTH_DAEMON_PORT="$PORT" "$@"; }
probe_up() {  # bare `vanth --json status` is the health probe: it never autostarts a daemon
  local out
  out=$(vanth_env "$VANTH" --json status 2>/dev/null) || true
  [ -n "$out" ] && [ "$(printf '%s' "$out" | st json-get - up)" = true ]
}
launch_spec() {  # the launch command with the NAMES of the allowlisted variables this environment sets: values are never recorded
  local names
  printf 'velo-task-launch-v1\numask=077\nvanthd=%s\nPATH=%s\nHOME=%s\nVANTH_HOME=%s\nAGENT_BG_HOME=%s\n' "$VANTHD" "$JOB_PATH" "$HOME" "$VH" "$VH"
  printf 'VANTH_DAEMON_PORT=%s\nVANTH_RETENTION_SECONDS=0\n' "$PORT"
  names=$(inherited_names)
  [ -z "$names" ] || printf 'allow=%s\n' $names
}
prov_get() { /usr/bin/sed -n "s/^$1=//p" "$PROV" 2>/dev/null | /usr/bin/head -n 1 || true; }
prov_valid() {  # sets PROV_WHY when the running daemon is not provably the one velo-task launched with this configuration
  local pid live
  PROV_WHY=""
  [ -f "$PROV" ] && [ ! -L "$PROV" ] || { PROV_WHY="no $PROV: this daemon was not launched by velo-task"; return 1; }
  pid=$(prov_get pid)
  case "$pid" in ''|*[!0-9]*) PROV_WHY="$PROV has no valid pid"; return 1 ;; esac
  [ "$(djson pid)" = "$pid" ] || { PROV_WHY="daemon.json pid '$(djson pid)' differs from provenance pid '$pid'"; return 1; }
  live=$(ps_lstart "$pid")
  [ -n "$live" ] && [ "$live" = "$(prov_get lstart)" ] || { PROV_WHY="pid $pid started '${live:-never}', provenance says '$(prov_get lstart)' (stale provenance or reused pid)"; return 1; }
  [ "$(prov_get digest)" = "$(launch_spec | sha_of)" ] \
    || { PROV_WHY="launch digest differs from the current configuration (port, retention, paths, or the allowlisted variables this environment sets)"; return 1; }
}
prov_live() {  # the provenance names a process that runs with the recorded start time: a daemon velo-task launched, answering or not
  local pid; pid=$(prov_get pid)
  [ -n "$pid" ] && [ -n "$(ps_lstart "$pid")" ] && [ "$(ps_lstart "$pid")" = "$(prov_get lstart)" ]
}
modes_problem() {  # succeeds, saying what, when anything under Vanth's home or the launch log is open to group or other (they must be 0700/0600)
  local bad
  [ -e "$VH" ] || [ -L "$VH" ] || return 1
  [ ! -L "$VH" ] || { MODES_WHY="$VH is a symlink"; return 0; }
  [ ! -e "$LAUNCH_LOG" ] || set -- "$LAUNCH_LOG"
  bad=$(/usr/bin/find "$VH" "$@" -perm +077 -print 2>&1 | /usr/bin/head -n 1) || true  # a directory find cannot read is reported on stderr: an error, never a pass
  [ -n "$bad" ] || return 1
  MODES_WHY="$bad (open to group or other, or unreadable)"
}
need_modes() {
  if modes_problem; then die 6 "$MODES_WHY; refusing. Tighten it (chmod -R go-rwx '$VH' '$LAUNCH_LOG') and run: velo-task restart-daemon"; fi
}
check_loopback() {  # <pid>: the daemon's listening sockets are 127.0.0.1:$PORT and nothing else
  local got
  got=$(/usr/sbin/lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | /usr/bin/grep '^n' | LC_ALL=C /usr/bin/sort -u | /usr/bin/tr '\n' ' ') || true
  [ "$got" = "n127.0.0.1:$PORT " ] && return 0
  LOOPBACK_WHY="pid $1 listens on '${got:-nothing}' but only 127.0.0.1:$PORT is allowed"
  return 1
}
refuse_unproven() {
  die 6 "a daemon answers on port $PORT but is not provably the one velo-task launched ($PROV_WHY); refusing to adopt it. If velo-task launched it, run: velo-task restart-daemon. Otherwise stop it by hand (the pid is in $VH/daemon.json), then run: velo-task ensure-daemon"
}
abandon_launch() {  # <pid> <why>: a launch that cannot be proven good: stop our own child, remove its record, refuse
  local pid="$1" deadline=$((SECONDS + ${VELO_TASK_STOP_WAIT:-20}))
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do poll; done
  /bin/rm -f "$PROV"
  if kill -0 "$pid" 2>/dev/null; then die 6 "$2; vanthd pid $pid is still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM (velo-task restart-daemon stops it)"; fi
  die 6 "$2"
}
launch_daemon() {
  local pid started digest deadline names n
  /bin/mkdir -p -m 700 "$VH"
  names="PATH HOME VANTH_HOME AGENT_BG_HOME VANTH_DAEMON_PORT VANTH_RETENTION_SECONDS $(inherited_names)"
  digest=$(launch_spec | sha_of)
  /bin/rm -f "$PROV"
  # The process started here IS the daemon, pid for pid: umask 077 makes jobs.sqlite, logs/, events/ and daemon.json private, the helper
  # execs vanthd with only the named variables (the allowlisted values come from this environment by name, never through an argv), and
  # its own process group and detached stdio let it outlive this shell. Vanth's own home lock keeps a second launch from running beside it.
  set -m
  ( umask 077; export PATH="$JOB_PATH" VANTH_HOME="$VH" AGENT_BG_HOME="$VH" VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0
    exec "$PYSYS" -I "$STATE_SCRIPT" launch "$VANTHD" $names </dev/null >"$LAUNCH_LOG" 2>&1 ) &
  pid=$!
  set +m
  started=$(ps_lstart "$pid")
  deadline=$((SECONDS + ${VELO_TASK_START_WAIT:-20}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if probe_up; then
      if [ "$(djson pid)" = "$pid" ]; then break; fi
      if ! kill -0 "$pid" 2>/dev/null && prov_valid; then  # lost the race to a concurrent ensure-daemon: its daemon is up and recorded
        printf 'daemon up pid=%s port=%s (adopted)\n' "$(prov_get pid)" "$PORT"; return 0
      fi
    fi
    poll
  done
  { kill -0 "$pid" 2>/dev/null && probe_up && [ "$(djson pid)" = "$pid" ]; } \
    || abandon_launch "$pid" "vanthd did not become ready on port $PORT; see $LAUNCH_LOG"
  [ "$(ps_lstart "$pid")" = "$started" ] || abandon_launch "$pid" "vanthd pid $pid changed identity during launch"
  check_loopback "$pid" || abandon_launch "$pid" "$LOOPBACK_WHY"
  ( umask 077; printf 'pid=%s\nlstart=%s\ndigest=%s\n' "$pid" "$started" "$digest" > "$PROV.$$" ) && /bin/mv -f "$PROV.$$" "$PROV"
  need_modes
  printf 'daemon up pid=%s port=%s (started)\n' "$pid" "$PORT"
}

cmd_ensure_daemon() {
  local n pid
  need_home; need_install; need_allowlist; need_modes
  if probe_up; then
    # A concurrent ensure-daemon records its provenance a moment after its daemon answers: give it that moment before refusing.
    for n in 1 2 3 4 5 6 7 8 9 10; do prov_valid && break; poll; done
    prov_valid || refuse_unproven
    pid=$(prov_get pid)
    check_loopback "$pid" || die 6 "$LOOPBACK_WHY; refusing to adopt it. Run: velo-task restart-daemon"
    printf 'daemon up pid=%s port=%s (adopted)\n' "$pid" "$PORT"
  else
    if prov_live; then
      die 6 "vanthd pid $(prov_get pid) is running but does not answer on port $PORT; not launching a second daemon over it. Run: velo-task restart-daemon"
    fi
    launch_daemon
  fi
}
cmd_restart_daemon() {  # signal only a process the provenance proves is ours, re-validated right before the signal; never `vanth restart` (it relaunches with the caller's environment)
  local pid dj deadline
  need_home; need_install; need_allowlist; need_modes
  pid=$(prov_get pid)
  if prov_live; then
    dj=$(djson pid)  # none: the daemon was launched and never answered, which is what restart is for
    [ -z "$dj" ] || [ "$dj" = "$pid" ] || die 6 "vanthd pid $pid is recorded as launched by velo-task but daemon.json names pid '$dj'; not signalled. Stop it by hand, then run: velo-task ensure-daemon"
    kill -TERM "$pid"
    deadline=$((SECONDS + ${VELO_TASK_STOP_WAIT:-20}))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do poll; done
    ! kill -0 "$pid" 2>/dev/null || die 6 "vanthd pid $pid still running ${VELO_TASK_STOP_WAIT:-20}s after SIGTERM; not escalating"
  elif probe_up; then
    die 6 "a daemon answers on port $PORT but no velo-task record proves velo-task launched it; not signalled. Stop it by hand (the pid is in $VH/daemon.json), then run: velo-task ensure-daemon"
  fi
  launch_daemon
}

# ---- install-vanth: lock + --require-hashes + wheels only, then assert ----------------------------------
norm_names() { /usr/bin/awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }'; }
fail_install() {
  ! { probe_up || prov_live; } || die 6 "install-vanth: $*; a daemon is running from $VENV, so the venv was left in place. Stop it first, then re-run install-vanth"
  /bin/rm -rf "$VENV"; die 1 "install-vanth failed, $VENV removed: $*"
}
run_uv() {  # uv sees nothing of the caller's: fixed system dirs for PATH, HOME for its cache
  /usr/bin/env -i PATH="/opt/homebrew/bin:$SYS_PATH" HOME="$HOME" "$UV_PINNED" "$@"
}
verify_install() {
  local tmp locked installed
  locked=$(/usr/bin/sed -n 's/^\([A-Za-z0-9._-]*==[^ ]*\).*/\1/p' "$LOCKFILE" | norm_names | LC_ALL=C /usr/bin/sort -u)
  installed=$(run_uv pip freeze --no-config --python "$PY" | norm_names | LC_ALL=C /usr/bin/sort -u) || fail_install "uv pip freeze"
  [ "$locked" = "$installed" ] || fail_install "installed distributions differ from the lock: $(/usr/bin/diff <(echo "$locked") <(echo "$installed") | /usr/bin/tr '\n' ' ')"
  "$PY" -I -c 'import vanth' || fail_install "vanth is not importable"
  tmp=$(/usr/bin/mktemp -d "$VENV/schema.XXXXXX")  # inside the venv: fail_install removes it with the venv
  ( umask 077; "$PY" -I -c 'import sqlite3, sys; from vanth.migrations import migrate; db = sqlite3.connect(sys.argv[1] + "/jobs.sqlite"); migrate(db, sys.argv[1]); db.close()' "$tmp" ) \
    || fail_install "the installed Vanth could not create its schema"
  st jobs-ro "$tmp/jobs.sqlite" 'SELECT 1 AS ok' >/dev/null || fail_install "the installed Vanth schema lacks columns velo-task reads"
  /bin/rm -rf "$tmp"
}
cmd_install_vanth() {  # run by hand, once; not concurrent with a running daemon
  local want
  [ -f "$LOCKFILE" ] || die 1 "lock file not found: $LOCKFILE"
  need_home
  [ -x "$UV_PINNED" ] || die 6 "uv not found at $UV_PINNED; velo-task installs through the Homebrew uv (brew install uv)"
  want=$(sha_of < "$LOCKFILE")
  if [ -x "$PY" ] && [ -f "$MARKER" ] && [ "$(/bin/cat "$MARKER")" = "$want" ]; then
    verify_install; echo "install-vanth: already installed from the current lock"; return 0
  fi
  ! { probe_up || prov_live; } || die 6 "a daemon is running from $VENV; stop it before replacing the venv"
  /bin/rm -f "$MARKER"
  run_uv venv --no-config --python 3.12 --clear "$VENV" </dev/null || fail_install "uv venv"
  run_uv pip install --no-config --python "$PY" --default-index https://pypi.org/simple --require-hashes --only-binary :all: -r "$LOCKFILE" </dev/null \
    || fail_install "uv pip install"
  verify_install
  printf '%s\n' "$want" > "$MARKER"
  echo "install-vanth: installed $(/usr/bin/sed -n 's/^vanth==\([^ ]*\).*/\1/p' "$LOCKFILE") into $VENV"
}

# ---- run, status, wait, cancel: Vanth is the index; the verdict is computed by the helper alone -------------
need_daemon() {  # ensure-daemon first (its stdout is not ours); a daemon that cannot be reached or started is exit 6 and the recovery command, never a verdict
  local rc=0
  (cmd_ensure_daemon >/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || die 6 "daemon-down: ensure-daemon failed (exit $rc); recover with: velo-task restart-daemon"
}
check_arg() {  # <kind> <value>: matched against the whole value
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
session_id() {  # $CLAUDE_SESSION_ID, else the token this state dir keeps (made on first use; a script cannot tell shells apart, so every shell without an id shares it)
  local s="${CLAUDE_SESSION_ID:-}"
  if [ -z "$s" ]; then
    if [ ! -f "$SESSION_FILE" ]; then
      ( umask 077; /bin/mkdir -p -m 700 "$VELO_TASK_HOME"; /usr/bin/od -An -N8 -tx1 /dev/urandom | /usr/bin/tr -d ' \n' > "$SESSION_FILE.$$"
        /bin/mv -n "$SESSION_FILE.$$" "$SESSION_FILE"; /bin/rm -f "$SESSION_FILE.$$" )
    fi
    s=$(st session-read "$VELO_TASK_HOME") || die 6 "$SESSION_FILE is not a private, generated session token of yours; refusing to use it (see above)"
  fi
  check_arg session "$s"; printf '%s' "$s"
}
start_refused() {  # <exit> <vanth output>: vanth start returned no job
  case "$2" in
    *"idempotency_key was already used"*|*"idempotency_key refers to cleaned job"*)
      die 5 "IDEMPOTENCY_CONFLICT: ${2#vanth start: }; this id was already started (with other settings, or its job was cleaned): use --rerun for a new execution" ;;
    *"failed to reach daemon"*) die 6 "daemon-down: $2; whether the start was accepted is unknown (re-running is idempotent); recover with: velo-task restart-daemon" ;;
    *) die 1 "vanth start failed (exit $1): $2; re-running is idempotent: the same key returns the job if it was accepted" ;;
  esac
}
cmd_run() {
  local id timeout="" issue="" stage="" have_issue=0 have_stage=0 rerun=0 cmdline=() args key out rc=0 job session
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
  [ -n "$timeout" ] || die 2 "--timeout S is required: every job is started with a deadline"
  check_arg timeout "$timeout"
  [ "$have_issue" = 0 ] || check_arg issue "$issue"
  [ "$have_stage" = 0 ] || check_arg stage "$stage"
  [ "${#cmdline[@]}" -gt 0 ] || die 2 "no command: expected -- cmd..."
  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"  # refused now, before the daemon is touched
  need_daemon
  session=$(session_id)
  key="velo_$(printf '%s' "$session" | sha_of | /usr/bin/cut -c1-8)_$id"  # two sessions starting one id get different jobs; one session starting it twice gets one
  if [ "$rerun" = 1 ]; then key="${key}_$(/bin/date +%s)_$$_$(/usr/bin/od -An -N4 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"; fi
  args=(--name "$id" --timeout "$timeout" --idempotency-key "$key" --cwd "$(pwd -P)" --tag velo --tag "session:$session")
  if [ "$have_issue" = 1 ]; then args=("${args[@]}" --tag "issue:$issue"); fi
  if [ "$have_stage" = 1 ]; then args=("${args[@]}" --tag "stage:$stage"); fi
  out=$(vanth_env "$VANTH" --json start "${args[@]}" -- "${cmdline[@]}" 2>&1) || rc=$?  # exit 1 also comes with the JSON of a job that failed to start
  job=$(printf '%s\n' "$out" | /usr/bin/grep -v '^vanth start:' | st json-get - job_id 2>/dev/null) || job=""
  [ -n "$job" ] || start_refused "$rc" "$out"
  printf '%s\n' "$job"
}

resolve() {  # <id> | --job <job_id>: sets JOB (and LABEL) from Vanth's own database, read-only; an unknown one exits 2
  local db="$VH/jobs.sqlite" rc=0 found=""
  if [ "$1" = --job ]; then
    check_arg job "$2"; LABEL="$2"
    [ ! -e "$db" ] && [ ! -L "$db" ] || found=$(st jobs-ro --cols job_id "$db" 'SELECT job_id FROM jobs WHERE job_id = ?' "$2") || rc=$?
  else
    check_arg id "$1"; LABEL="$1"
    # The exact name, newest first: a read of the database, so there is no 1,000-row `vanth list` cap and no substring match.
    [ ! -e "$db" ] && [ ! -L "$db" ] || found=$(st jobs-ro --cols job_id "$db" 'SELECT job_id FROM jobs WHERE name = ? ORDER BY created_at DESC, job_id DESC LIMIT 1' "$1") || rc=$?
  fi
  [ "$rc" -eq 0 ] || die 6 "jobs.sqlite cannot be read (helper exit $rc, see above); nothing was resolved"
  [ -n "$found" ] || die 2 "unknown id '${2:-$1}': Vanth has no job by that name; address a job by its id with --job <job_id>"
  JOB="$found"
}
read_verdict() {  # <job> <label> [extra verdict-of args]: sets VERDICT_LINE and VERDICT; the daemon is asked, never a log or a process list
  local job="$1" label="$2" out rc=0 vrc=0
  shift 2
  out=$(vanth_env "$VANTH" --json status "$job" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"unknown job"*) die 2 "job $job is unknown to Vanth (cleaned up after it was resolved?); no verdict" ;;
      *"failed to reach daemon"*) die 6 "daemon-down: $out; no verdict was read; recover with: velo-task restart-daemon" ;;
      *) die 1 "vanth status failed (exit $rc): $out" ;;
    esac
  fi
  VERDICT_LINE=$(printf '%s\n' "$out" | st verdict-of --db "$VH/jobs.sqlite" --job "$job" --label "$label" "$@") || vrc=$?
  [ "$vrc" -eq 0 ] || die "$vrc" "${VERDICT_LINE:-the status of $job could not be read as a verdict}"
  VERDICT="${VERDICT_LINE#* }"
}
target_args() {  # parses `<id>` or `--job <job_id>` into TARGET
  TARGET=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job) [ "$#" -ge 2 ] && [ "${#TARGET[@]}" -eq 0 ] || die 2 "--job needs a value, and replaces the id"; TARGET=(--job "$2"); shift 2 ;;
      -*) die 2 "unknown option '$1'" ;;
      *) [ "${#TARGET[@]}" -eq 0 ] || die 2 "takes one id"; TARGET=("$1"); shift ;;
    esac
  done
  [ "${#TARGET[@]}" -gt 0 ] || die 2 "usage: velo-task <status|cancel> <id> | --job <job_id>"
}
cmd_status() {  # prints `<id> <verdict>`; exit 0 whenever it printed one, 2 unknown id or a job Vanth no longer knows, 6 daemon down
  target_args "$@"
  [ -z "${CLAUDE_SESSION_ID:-}" ] || check_arg session "$CLAUDE_SESSION_ID"
  resolve "${TARGET[@]}"; need_daemon
  if [ "${TARGET[0]}" = --job ]; then read_verdict "$JOB" "$LABEL"; else read_verdict "$JOB" "$LABEL" --name "$LABEL"; fi  # an id's row must carry exactly that name
  printf '%s\n' "$VERDICT_LINE"
}
cmd_wait() {  # one call, one verdict per id: --all (default) waits for every id, --any returns the first; exit 0 iff every printed verdict is ok
  local mode=all tmo=3600 ids=() jobs=() done_=() i n out deadline pending all_done=1 first=-1 worst=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --any) mode=any; shift ;;
      --all) mode=all; shift ;;
      --timeout) [ "$#" -ge 2 ] || die 2 "--timeout needs a value"; check_arg timeout "$2"; tmo="$2"; shift 2 ;;
      -*) die 2 "unknown option '$1'" ;;
      *) ids[${#ids[@]}]="$1"; shift ;;
    esac
  done
  [ "${#ids[@]}" -gt 0 ] || die 2 "usage: velo-task wait <id>... [--any|--all] [--timeout S]"
  for i in "${!ids[@]}"; do resolve "${ids[$i]}"; jobs[$i]="$JOB"; done  # every id is known before anything is polled
  need_daemon
  deadline=$((SECONDS + tmo))
  while :; do
    all_done=1; first=-1
    for i in "${!ids[@]}"; do
      if [ -z "${done_[$i]:-}" ]; then
        read_verdict "${jobs[$i]}" "${ids[$i]}" --name "${ids[$i]}"
        [ "$VERDICT" != in-flight ] || { all_done=0; continue; }
        done_[$i]="$VERDICT_LINE"
      fi
      [ "$first" -ge 0 ] || first="$i"
    done
    if [ "$mode" = any ] && [ "$first" -ge 0 ]; then
      for i in "${!ids[@]}"; do [ "$i" = "$first" ] || [ -n "${done_[$i]:-}" ] || echo "velo-task: ${ids[$i]} is still in flight" >&2; done
      printf '%s\n' "${done_[$first]}"
      [ "${done_[$first]#* }" = ok ]; return
    fi
    if [ "$all_done" = 1 ]; then
      for i in "${!ids[@]}"; do printf '%s\n' "${done_[$i]}"; [ "${done_[$i]#* }" = ok ] || worst=1; done
      return "$worst"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      pending=""; for i in "${!ids[@]}"; do [ -n "${done_[$i]:-}" ] || pending="$pending ${ids[$i]}"; done
      die 3 "wait timed out after ${tmo}s; still in flight:$pending"
    fi
    /bin/sleep "${VELO_TASK_POLL:-0.5}"
  done
}
cmd_cancel() {  # `vanth stop` a job in flight, then print the verdict once it is killed; a job that already finished prints its real verdict on stderr, exit 4
  local out rc=0
  target_args "$@"
  resolve "${TARGET[@]}"; need_daemon
  read_verdict "$JOB" "$LABEL"
  if [ "$VERDICT" = in-flight ]; then
    out=$(vanth_env "$VANTH" --json stop "$JOB" --signal terminate --kill-after 5 2>&1) || rc=$?
    read_verdict "$JOB" "$LABEL"
    [ "$VERDICT" != in-flight ] || die 1 "the job is still in flight after vanth stop (exit $rc): $out"
  fi
  if [ "$VERDICT" = killed ]; then printf '%s\n' "$VERDICT_LINE"; return 0; fi
  printf '%s\n' "$VERDICT_LINE" >&2
  die 4 "already-terminal: $LABEL finished as ${VERDICT} before it could be cancelled"
}
cmd_stop_override() {  # the Stop guard's one-shot escape: lets the current session end once, audited in overrides.log
  [ "${1:-}" = --reason ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || die 2 "usage: velo-task stop-override --reason <text>"
  need_home
  st override-write "$VELO_TASK_HOME" "$2" || die 1 "the override was not written (see above)"
  echo "stop-override recorded: the next Stop is allowed once"
}

# ---- what the Stop guard and SessionStart read: Vanth's own database, read-only, no daemon needed ----------
inflight_of() {  # <session>: this session's in-flight jobs, one `name job_id status` a line. A missing or unreadable database is a failure, never "no jobs"
  st inflight "$VH/jobs.sqlite" "$1"
}
inflight_elsewhere() {  # <session>: how many in-flight jobs belong to other sessions
  st inflight "$VH/jobs.sqlite" "$1" --others
}
wait_hint() {  # <name> <job_id>: the command that clears one in-flight job
  if [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{2,63}$ ]]; then echo "velo-task wait $1"; else echo "velo-task status --job $2"; fi
}

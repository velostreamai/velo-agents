#!/bin/bash
# velo-task v2 (docs/velo-task-spec.md): Vanth is the only state. Every check runs against fakes in a temp tree; every check has a mutation proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
FIX="$HERE/fixtures/velo-task"
umask 022   # the launch's own `umask 077` must be what makes the daemon's files private
unset VELO_TASK_HOME VELO_TASK_PORT CLAUDE_SESSION_ID
# Test-mode timeouts (stubs answer at once; a broken run is bounded): see test-timeouts.sh.
. "$HERE/test-timeouts.sh"
REAL_HOME="$HOME"
# stat spells its format with -f on BSD and -c on GNU, and GNU stat accepts -f too (as "filesystem status") and answers with a
# report that is not what was asked for. So GNU is tried first: BSD stat rejects -c cleanly and falls through to its own spelling.
mode_of() { /usr/bin/stat -c %a "$1" 2>/dev/null || /usr/bin/stat -f %Lp "$1"; }   # <path>: its permission bits in octal, as 600
# sed -i takes its backup suffix as a separate argument on BSD (-i '') and attached on GNU (-i.bak); only the attached form means the
# same on both, and the copy it leaves is removed.
sedi() {  # <sed arguments...> <file>: edit the file in place
  local f="${!#}"
  sed -i.sedi-bak "$@" && rm -f "$f.sedi-bak"
}
snap_home() {  # what velo-task or Vanth could write under the real home, as mtime and size; the real state dir must not gain a velo-task dir
  local p
  for p in "$REAL_HOME/.agents/state" "$REAL_HOME/.agents/state/velo-task" "$REAL_HOME/.agents/state/vanth" "$REAL_HOME/.config"; do
    if [ -e "$p" ]; then /usr/bin/stat -c '%n %Y %s' "$p" 2>/dev/null || /usr/bin/stat -f '%N %m %z' "$p"; else echo "$p absent"; fi
  done
}
# ~/.claude.json is compared by what matters, not by mtime: a live Claude session rewrites it all the time, so an mtime
# comparison would fail on activity that is not ours. What velo-task or Vanth would add is a vanth or velo-task entry.
# A host with no ~/.claude.json (a CI runner, a fresh account) has no entries: 0, never an empty string the -le below cannot read.
claude_json_marks() {
  [ -f "$REAL_HOME/.claude.json" ] || { echo 0; return 0; }
  /usr/bin/grep -c -i -e vanth -e velo-task "$REAL_HOME/.claude.json" 2>/dev/null; true
}
HOME_BEFORE=$(snap_home); MARKS_BEFORE=$(claude_json_marks)
# macOS mktemp given no template ignores TMPDIR (run.sh points it into the worktree): build the template from TMPDIR.
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(mktemp -d "$TMP_ROOT/velo-task.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }   # an empty $T would make reap's pattern match everything
# The suite's interpreter: an absolute path chosen once, here, never found through PATH (a python3 shim first on the caller's PATH, or
# one the suite puts there, must not run), executable, and not resolving into the temp tree the suite fills. The candidates are not
# read from the caller's environment; the suite's own mutation proofs of this choice (t_suite_python) set PYTHON_CANDIDATES and
# PYTHON_UNCHECKED for one proof at a time.
PYTHON_CANDIDATES="/opt/homebrew/bin/python3 /usr/bin/python3"; unset PYTHON_UNCHECKED
# realpath_of resolves a candidate. BSD readlink -f is missing on older macOS, so the resolution is os.path.realpath in a python of its
# own. That python is not a candidate (a candidate must not run before it has been checked) but the first of a fixed pair of absolute
# paths, never found through PATH, and it runs isolated (-I: no PYTHON* variable, no user site, nothing from the current directory).
# Like PYTHON_CANDIDATES, the RESOLVER_ values are fixed here, not read from the caller's environment; the mutation proofs of the helper
# (t_suite_python) set one of them for one proof at a time.
RESOLVER_PYTHONS="/opt/homebrew/bin/python3 /usr/bin/python3"; RESOLVER_FLAGS="-I"; RESOLVER_CODE='import os, sys; print(os.path.realpath(sys.argv[1]))'
realpath_of() {  # <path>: its canonical absolute path, every symlink followed
  local r py
  for r in $RESOLVER_PYTHONS; do
    py=$(command -v "$r") || continue   # command -v fails for a resolver that is not an executable file
    "$py" $RESOLVER_FLAGS -c "$RESOLVER_CODE" "$1"; return
  done
  echo "realpath_of: none of the resolver pythons is an executable file (looked for: $RESOLVER_PYTHONS)" >&2; return 1
}
# The guard compares a resolved candidate with resolved roots: TMPDIR may be spelled through a symlink (on macOS /var/folders/... is
# /private/var/folders/...), and a resolved path never starts with the unresolved spelling of its own root. TEMP_ROOT_CANON names
# the function that resolves the roots; the proof of the guard (t_suite_python) sets it to echo, which compares them as spelled.
TEMP_ROOT_CANON=realpath_of
pick_python() {  # prints the first candidate that is executable and resolves outside the temp root
  local p real root_t root_tmp
  root_t=$("$TEMP_ROOT_CANON" "$T") && root_tmp=$("$TEMP_ROOT_CANON" "$TMP_ROOT") || return 1   # a root that cannot be resolved is a failure, never a pass
  for p in $PYTHON_CANDIDATES; do
    real=$(command -v "$p") && real=$(realpath_of "$real") || continue   # command -v fails for a candidate that is not an executable file
    if [ -z "${PYTHON_UNCHECKED:-}" ]; then
      case "$real/" in "$root_t"/*|"$root_tmp"/*) echo "pick_python: $p resolves to $real, inside the temp root $root_tmp" >&2; continue ;; esac
    fi
    printf '%s\n' "$p"; return 0
  done
  return 1
}
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
PYBIN=$(pick_python) || { echo "no usable python3 outside the temp root (looked for: $PYTHON_CANDIDATES)" >&2; exit 1; }
# lsof is in /usr/sbin on macOS and /usr/bin on Linux, where it is not installed by default. Found by absolute path, as the library does.
LSOF=""; for p in /usr/sbin/lsof /usr/bin/lsof; do [ -x "$p" ] && { LSOF="$p"; break; }; done
[ -n "$LSOF" ] || { echo "no lsof (looked for /usr/sbin/lsof /usr/bin/lsof): the loopback checks cannot run without it" >&2; exit 1; }
loose_files() {  # <dir>...: the regular files under them that are open to group or other. find spells "any of these bits" -perm +077 on BSD
  # and -perm /077 on GNU, and each rejects the other's; six single-bit tests joined by -o mean the same on both.
  find "$@" -type f \( -perm -040 -o -perm -020 -o -perm -010 -o -perm -004 -o -perm -002 -o -perm -001 \)
}
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
only() { [ -z "${VELO_TASK_ONLY:-}" ] || [[ " $VELO_TASK_ONLY " == *" $1 "* ]]; }   # <check fn>: VELO_TASK_ONLY="t_a t_b" runs just those checks and their proofs; VELO_TASK_NO_PROOFS=1 skips the proofs
check() {  # <label> <check fn>: the real code must pass; `note:` lines the check prints are shown
  local out line
  only "$2" || return 0
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
  IN_PROOF=1   # a check may allow a mutant more time than the real code needs (t_launch_requires_own_pid); this job is a background subshell, so the parent never sees it
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
  only "$fn" && [ "${VELO_TASK_NO_PROOFS:-}" != 1 ] || return 0
  MUT_N=$((MUT_N + 1))
  m="$T/pj$MUT_N/code"   # numbered, never named for the label: a label's words must not satisfy a grep on the path
  rm -rf "$m"; mkdir -p "$m"; cp -R "$REPO/bin" "$REPO/requirements" "$REPO/hooks" "$m/"; cp "$REPO/install.sh" "$m/"
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
  only "$2" && [ "${VELO_TASK_NO_PROOFS:-}" != 1 ] || return 0
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
mkhome() {  # [wild|foreign]: isolated VELO_TASK_HOME and a reserved port: sets E E_HOME E_VENV E_VH E_CALLS E_PORT E_HOLDER
  E=$(mktemp -d "$T/e.XXXXXX"); E_HOME="$E/home"; E_VENV="$E_HOME/venv"; E_VH="$E_HOME/vanth"; E_CALLS="$E/calls"
  mkdir -m 700 "$E_HOME"; : > "$E_CALLS"
  # A listener holds the port for the test's whole life (SO_REUSEPORT, so the fake vanthd can bind it as well): the port is
  # never picked by bind-and-close, where another process could take it before the daemon does. `wild`, for the test whose
  # daemon listens on every interface, holds the wildcard address too: beside the loopback listener alone, a foreign server
  # that binds the same number there is not refused, and the daemon's wildcard bind then fails with EADDRINUSE. `foreign`, for
  # the test of a port that is taken: the holder is a foreign process from the start (no SO_REUSEPORT, so the daemon cannot bind;
  # it logs the signals it gets to $E/signals), not a reservation released and bound again by another process.
  if [ "${1:-}" = foreign ]; then "$PYBIN" "$FIX/port-holder.py" foreign 0 "$E/port" "$E/signals" </dev/null >/dev/null 2>&1 &
  else "$PYBIN" "$FIX/port-holder.py" reserve "$E/port" ${1:+"$1"} </dev/null >/dev/null 2>&1 &
  fi
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
jobs = "job_id name status exit_code stop_actor stop_reason trigger_json created_at ended_at policy_state_json tags_json command".split()
con = sqlite3.connect(path)
con.execute("CREATE TABLE jobs (%s)" % ", ".join(c for c in jobs if c != drop))
con.execute("CREATE TABLE local_start_requests (idempotency_key, request_hash, job_id, created_at)")
if not drop:
    con.executemany("INSERT INTO jobs (job_id, name, status, command) VALUES (?, ?, ?, 'x')",
                    [("a", "one", "running"), ("b", "two", "failed")])
con.commit()
PY
  chmod 600 "$1"
}
mkvenv() {  # a fake installed Vanth: stub vanthd (listens) and vanth (both record to $E_CALLS), install marker
  # bin/python is a wrapper SCRIPT we own, never a symlink to the real interpreter: a stub (or a mutant) that
  # writes to a venv path must not be able to write through to a system binary.
  mkdir -p "$E_VENV/bin"; rm -f "$E_VENV/bin/python"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$PYBIN" > "$E_VENV/bin/python"; chmod +x "$E_VENV/bin/python"
  render fake-vanthd.py "$E_VENV/bin/vanthd"; render fake-vanth.sh "$E_VENV/bin/vanth"
  /usr/bin/shasum -a 256 "$R/requirements/vanth.lock" | cut -d' ' -f1 > "$E_VENV/.velo-task-installed"
}
mkuv() {  # <variant: ok|noreason|nocolumn|extra|missing>: a fake uv + fake Vanth package for install-vanth
  local v="$1" py3="$PYBIN"   # FAKE_UV_MUTANT (noguard|fromlock) is set only by the fixture's own mutation proofs
  mkdir -p "$E/uvbin" "$E/site/vanth"
  cat > "$E/site/vanth/__init__.py" <<EOF
import os
with open("$E/pyenv.log", "a") as fh:  # the NAMES in the environment of a python the installing shell starts (install's checks import vanth)
    fh.write("env=%s\n" % " ".join(sorted(os.environ)))
EOF
  cat > "$E/site/vanth/migrations.py" <<EOF
def migrate(db, home):
    cols = "job_id name status exit_code stop_actor stop_reason created_at policy_state_json tags_json".split()
    db.execute("CREATE TABLE jobs (%s)" % ", ".join(c for c in cols if c != "$([ "$v" = nocolumn ] && echo created_at)"))
    db.execute("CREATE TABLE local_start_requests (idempotency_key, request_hash, job_id, created_at)")
    db.commit()
EOF
  # The fake uv prints the checked-in closure fixture as the installed set; it is NOT derived from the lock (finding 21).
  sed "s#@E@#$E#g; s#@PY3@#$py3#g; s#@FIX@#$FIX#g; s#@CLOSURE@#$HERE/fixtures/vanth-closure.txt#g; s#@VARIANT@#$v#g; s#@MUTANT@#${FAKE_UV_MUTANT:-}#g" \
    "$FIX/fake-uv.py" > "$E/uvbin/uv"
  chmod +x "$E/uvbin/uv"
}
mkcode() {  # <dest>: a copy of the code under test whose pinned uv is the fake one: the real path is a constant of the library, there is no override to set
  rm -rf "$1"; mkdir -p "$1"; cp -R "$R/bin" "$R/requirements" "$1/"
  sedi "s#^UV_PINNED=.*#UV_PINNED=$E/uvbin/uv#" "$1/bin/velo-task-lib.sh"
}
installv() { mkcode "$E/code"; run "$E/code/bin/velo-task" install-vanth; }   # install through the fake uv
daemon_pid() { ST json-get "$E_VH/daemon.json" pid 2>/dev/null; }
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
# The two functions below turn ps's rendering of a start time into a number and back. BSD date reads and writes it with -j -f / -r, GNU date
# with -d / @: neither spelling is accepted by the other, so python (the suite's own, by absolute path) does it, in UTC, in English.
shift_lstart() {  # <lstart> <seconds>: the same clock moved by seconds, in the same rendering
  "$PYBIN" -I -c 'import calendar, sys, time
t = time.gmtime(calendar.timegm(time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y")) + int(sys.argv[2]))
print(time.strftime("%a %b ", t) + str(t.tm_mday) + time.strftime(" %H:%M:%S %Y", t))' "$1" "$2"
}
iso_start() {
  "$PYBIN" -I -c 'import sys, time
print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y")))' "$(lstart_of "$1")"
}
write_json() {  # <pid> <started_at>: a daemon.json as Vanth writes it, private like Vanth's own (a loose one would be refused for its mode, not for what the test means)
  mkdir -p -m 700 "$E_VH"
  ( umask 077; printf '{"url":"http://127.0.0.1:%s","pid":%s,"started_at":"%s"}\n' "$E_PORT" "$1" "$2" > "$E_VH/daemon.json" )
}
D64=$(printf '%064d' 7)
write_prov() {  # <pid> <lstart> [digest]: a provenance record in the format velo-task writes
  printf 'pid=%s\nlstart=%s\ndigest=%s\n' "$1" "$2" "${3-$D64}" > "$E_HOME/daemon.provenance"
}
snap_state() {  # <dir>: names, sizes, mtimes and modes of everything under it, for a before/after comparison
  # %Fm / %.9Y: modification time to the nanosecond (BSD / GNU spelling; the GNU one is probed once, on a path that always exists)
  if /usr/bin/stat -c %a . >/dev/null 2>&1; then
    ( cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 /usr/bin/stat -c '%n %s %.9Y %a' )
  else
    ( cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 /usr/bin/stat -f '%N %z %Fm %Lp' )
  fi
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


# ---- extracted from the previous suite, unchanged in meaning ----

norm_freeze() { awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' | LC_ALL=C sort -u; }

lock_problems() {  # <lock> [<manifest>]: what is wrong with it as a hash-locked requirements file of WHEELS for CPython 3.12 on macOS arm64, read offline; with a manifest, whether each hash is the one it records for that pin's wheel
  "$PYBIN" -I - "$@" <<'PY'
import re
import sys

REQ = re.compile(r"^([A-Za-z0-9._-]+)==([0-9A-Za-z.+!_-]+) \\$")
HASH = re.compile(r"^    --hash=sha256:([0-9a-f]{64})  # wheel: (\S+)$")
MROW = re.compile(r"^([A-Za-z0-9._-]+)\t([0-9A-Za-z.+!_-]+)\t(\S+\.whl)\t([A-Za-z0-9_.]+)\t([0-9a-f]{64})$")
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


problems, cur, hashes, pins = [], None, 0, []


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
        pins.append((cur[0], cur[1], h.group(1), h.group(2)))
        p = wheel_problem(cur[0], cur[1], h.group(2))
        if p:
            problems.append(p)
        continue
    problems.append("unexpected line (a hash line must end with '# wheel: <file>.whl'): %s" % line)
close()
if len(sys.argv) > 2:  # the reviewed manifest: one row per pin, and the lock's hash is the manifest's sha256 for the same wheel
    rows = {}
    for n, line in enumerate(open(sys.argv[2]).read().split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        m = MROW.match(line)
        if not m:
            problems.append("manifest line %d is not name<TAB>version<TAB>wheel<TAB>platform<TAB>sha256: %r" % (n, line))
            continue
        name, ver, wheel, plat, sha = m.groups()
        w = WHEEL.match(wheel)
        if not w or w.group("plat") != plat:
            problems.append("manifest: %s==%s: the platform tag %s is not the one in %s" % (name, ver, plat, wheel))
        if (norm(name), ver) in rows:
            problems.append("manifest: %s==%s has two rows" % (name, ver))
        rows[(norm(name), ver)] = (wheel, sha)
    for name, ver, sha, wheel in pins:
        row = rows.pop((norm(name), ver), None)
        if row is None:
            problems.append("%s==%s: no row in the manifest" % (name, ver))
        elif row[0] != wheel:
            problems.append("%s==%s: the lock names wheel %s, the manifest %s" % (name, ver, wheel, row[0]))
        elif row[1] != sha:
            problems.append("%s==%s: the lock's hash %s is not the manifest's sha256 %s for %s" % (name, ver, sha, row[1], wheel))
    for name, ver in sorted(rows):
        problems.append("manifest: %s==%s has no pin in the lock" % (name, ver))
print("\n".join(problems))
PY
}

t_lock_file() {  # B23, findings 12, 13: pinned, hashed, WHEELS ONLY; the artifact types are checked offline from the `# wheel:` comments
  local lock="$R/requirements/vanth.lock" manifest="$R/requirements/vanth.wheels.tsv" bad n f d w h1 h2
  bad=$(lock_problems "$lock" "$manifest")
  OUT=$bad; need "every requirement is pinned (==) with exactly one sha256 hash, each hash names a wheel that installs on CPython 3.12 / macOS arm64, and is the sha256 the reviewed manifest records for that wheel" [ -z "$bad" ]
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
  # the reviewed manifest (finding: the adjacent `# wheel:` comment is not evidence that the hash is of that wheel): every hash must be the manifest's sha256 for its pin
  h1=$(printf '%064d' 1); h2=$(printf '%064d' 2)
  printf 'foo==1.0 \\\n    --hash=sha256:%s  # wheel: foo-1.0-py3-none-any.whl\n' "$h1" > "$d/m.lock"
  mrow() { printf 'foo\t1.0\t%s\t%s\t%s\n' "$1" "$2" "$3"; }   # <wheel> <platform tag> <sha256>
  { echo '# a comment'; echo; mrow foo-1.0-py3-none-any.whl any "$h1"; } > "$d/m.tsv"
  OUT=$(lock_problems "$d/m.lock" "$d/m.tsv"); need "a lock hash equal to the manifest's sha256 for its pin passes (comments and blank lines are skipped)" [ -z "$OUT" ]
  mrow foo-1.0-py3-none-any.whl any "$h2" > "$d/m.tsv"; OUT=$(lock_problems "$d/m.lock" "$d/m.tsv")
  need "a lock hash that is not the manifest's sha256 for its pin is flagged (an sdist's hash under a wheel's comment looks like this)" [ -n "$OUT" ]
  need "...naming the pin" grep -q 'foo==1.0' <<<"$OUT"
  : > "$d/m.tsv"; OUT=$(lock_problems "$d/m.lock" "$d/m.tsv"); need "a pin with no manifest row is flagged" [ -n "$OUT" ]
  { mrow foo-1.0-py3-none-any.whl any "$h1"; printf 'bar\t2.0\tbar-2.0-py3-none-any.whl\tany\t%s\n' "$h1"; } > "$d/m.tsv"
  OUT=$(lock_problems "$d/m.lock" "$d/m.tsv"); need "a manifest row for a distribution the lock does not pin is flagged" [ -n "$OUT" ]
  { mrow foo-1.0-py3-none-any.whl any "$h1"; mrow foo-1.0-py3-none-any.whl any "$h1"; } > "$d/m.tsv"
  OUT=$(lock_problems "$d/m.lock" "$d/m.tsv"); need "two rows for one pin are flagged" [ -n "$OUT" ]
  mrow foo-1.0-py3-none-macosx_11_0_arm64.whl macosx_11_0_arm64 "$h1" > "$d/m.tsv"; OUT=$(lock_problems "$d/m.lock" "$d/m.tsv")
  need "a manifest that names another wheel than the lock's is flagged" [ -n "$OUT" ]
  mrow foo-1.0-py3-none-any.whl macosx_11_0_arm64 "$h1" > "$d/m.tsv"; OUT=$(lock_problems "$d/m.lock" "$d/m.tsv")
  need "a platform tag that is not the wheel file's is flagged" [ -n "$OUT" ]
  printf 'foo 1.0 foo-1.0-py3-none-any.whl any %s\n' "$h1" > "$d/m.tsv"; OUT=$(lock_problems "$d/m.lock" "$d/m.tsv")
  need "a row separated by spaces instead of tabs is flagged" [ -n "$OUT" ]
  n=$(grep -cE '^[A-Za-z0-9._-]+==' "$lock"); need "the full tree is locked (at least 25 distributions)" [ "$n" -ge 25 ]
  need "the manifest has exactly one row per pin" [ "$(grep -vc -e '^#' -e '^$' "$manifest")" = "$n" ]
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
  mkhome; mkuv ok; m="$E/gainlock"; mkcode "$m"
  printf 'zzz-extra==1.0 \\\n    --hash=sha256:%s  # wheel: zzz_extra-1.0-py3-none-any.whl\n' "$(printf '%064d' 3)" >> "$m/requirements/vanth.lock"
  run "$m/bin/velo-task" install-vanth
  need "a lock that gains a distribution the closure list lacks fails the install: the fake does not follow the lock (exit 1)" [ "$RC" = 1 ]
  need "...as a difference from the lock" grep -q 'differ from the lock' <<<"$OUT"
}

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


# ---- helper: json-get, jobs-ro, verdict-of, launch, override -----------------------------------------
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
  # PYTHONIOENCODING makes the Latin-1 caller explicit: whether LC_ALL alone changes Python's stdout depends on the host (the locale
  # may not be installed; Python 3.15 defaults to UTF-8 whatever the locale says), and a mutant that left the locale in charge
  # would then print the right bytes by luck.
  need "...whatever the caller's locale (a Latin-1 locale must not change the bytes)" [ "$(LC_ALL=en_US.ISO8859-1 PYTHONIOENCODING=latin-1 ST json-get "$d/j" accent)" = "$(printf 'caf\xc3\xa9')" ]
  run ST json-get "$d/j" absent; need "a missing key: exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  run ST json-get "$d/j" nothing; need "a null value: exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  run ST json-get "$d/none.json" pid; need "a missing file (a daemon that has not started): exit 0" [ "$RC" = 0 ]; need "...printing nothing" [ -z "$OUT" ]
  printf '%s' '{"pid":' > "$d/bad"; run ST json-get "$d/bad" pid; need "malformed JSON is an error, not an empty value (exit 1)" [ "$RC" = 1 ]
  printf '[1,2]\n' > "$d/arr"; run ST json-get "$d/arr" pid; need "a JSON array is an error (exit 1)" [ "$RC" = 1 ]
  need "...saying it does not hold a JSON object (not an accident of the lookup)" grep -q 'does not hold a JSON object' <<<"$OUT"
  need "- reads standard input" [ "$(printf '{"up": true}' | ST json-get - up)" = true ]
  run ST json-get "$d/j"; need "a missing key argument is a usage error (exit 2)" [ "$RC" = 2 ]
}
t_jobs_ro() {
  local d t0 t1; d=$(mktemp -d "$T/jr.XXXXXX"); mkdb "$d/jobs.sqlite"
  run ST jobs-ro "$d/jobs.sqlite" 'SELECT job_id, status FROM jobs ORDER BY job_id'
  need "rows come back as a compact JSON array" [ "$OUT" = '[{"job_id":"a","status":"running"},{"job_id":"b","status":"failed"}]' ]
  run ST jobs-ro --cols name,status "$d/jobs.sqlite" 'SELECT name, status FROM jobs WHERE name = ?' two
  need "--cols prints one line a row, and the parameter is bound" [ "$OUT" = "two failed" ]
  run ST jobs-ro --cols name "$d/jobs.sqlite" 'SELECT name FROM jobs WHERE name = ?' "two' OR '1'='1"
  need "a parameter is data: an injection matches nothing" [ -z "$OUT" ]
  "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO jobs (job_id, name, status) VALUES (?, ?, ?)", ("c", "x\ny z", "completed")); c.commit()' "$d/jobs.sqlite"
  run ST jobs-ro --cols name,status "$d/jobs.sqlite" "SELECT name, status FROM jobs WHERE job_id = 'c'"
  need "a name that could forge a line or a field is JSON-quoted" [ "$OUT" = '"x\ny z" completed' ]
  run ST jobs-ro "$d/jobs.sqlite" 'DELETE FROM jobs'; need "a write is refused (exit 1)" [ "$RC" = 1 ]
  need "...and changed nothing" [ "$(ST jobs-ro --cols job_id "$d/jobs.sqlite" 'SELECT job_id FROM jobs' | wc -l | tr -d ' ')" = 3 ]
  run ST jobs-ro "$d/jobs.sqlite" "ATTACH DATABASE '$d/new.sqlite' AS x"; need "ATTACH is refused" [ "$RC" = 1 ]; need "...and created no file" [ ! -e "$d/new.sqlite" ]
  run ST jobs-ro "$d/jobs.sqlite" 'PRAGMA query_only=OFF'; need "a PRAGMA is refused" [ "$RC" = 1 ]
  mkdb "$d/bad.sqlite" created_at; run ST jobs-ro "$d/bad.sqlite" 'SELECT 1'
  need "a database without a column velo-task reads is exit 5" [ "$RC" = 5 ]; need "...naming it" grep -q 'jobs.created_at' <<<"$OUT"
  printf 'not a database, just text\n' > "$d/junk.sqlite"; chmod 600 "$d/junk.sqlite"; run ST jobs-ro "$d/junk.sqlite" 'SELECT 1'; need "a file that is not a database is exit 1" [ "$RC" = 1 ]
  ln -s "$d/jobs.sqlite" "$d/link.sqlite"; run ST jobs-ro "$d/link.sqlite" 'SELECT 1'
  need "a symlink to a good database is refused (exit 1)" [ "$RC" = 1 ]; need "...saying why" grep -q 'not a private regular file' <<<"$OUT"
  cp "$d/jobs.sqlite" "$d/open.sqlite"; chmod 644 "$d/open.sqlite"; run ST jobs-ro "$d/open.sqlite" 'SELECT 1'; need "a database open to group or other is refused" [ "$RC" = 1 ]
  mkdir -m 755 "$d/loose"; cp "$d/jobs.sqlite" "$d/loose/jobs.sqlite"; run ST jobs-ro "$d/loose/jobs.sqlite" 'SELECT 1'; need "a database in a directory open to group or other is refused" [ "$RC" = 1 ]
  mkdir -m 700 "$d/real"; cp "$d/jobs.sqlite" "$d/real/jobs.sqlite"; ln -s "$d/real" "$d/dirlink"; run ST jobs-ro "$d/dirlink/jobs.sqlite" 'SELECT 1'
  need "a database reached through a symlinked directory is refused" [ "$RC" = 1 ]
  run ST jobs-ro "$d/real/jobs.sqlite" 'SELECT 1'; need "control: the same file, private in a private directory, is read" [ "$RC" = 0 ]
  run ST jobs-ro "$d/none.sqlite" 'SELECT 1'; need "a missing database is exit 1 and is not created" [ "$RC" = 1 -a ! -e "$d/none.sqlite" ]
  "$PYBIN" -I -c 'import sqlite3, sys, time; c = sqlite3.connect(sys.argv[1], isolation_level=None); c.execute("BEGIN EXCLUSIVE"); open(sys.argv[2], "w").close(); time.sleep(6)' "$d/jobs.sqlite" "$d/held" &
  waitfor 5 test -e "$d/held" || { echo "FAILED: the lock was never taken"; exit 1; }
  t0=$(now); run ST jobs-ro "$d/jobs.sqlite" 'SELECT 1'; t1=$(now)
  need "a database locked for more than 2 s is exit 4" [ "$RC" = 4 ]; need "...after waiting about 2 s for it" between 1.5 "$t0" "$t1" 5
  wait $! 2>/dev/null; true
}
t_verdict_table() {  # every row is `expected|input`; `x` is the label the helper prints
  local d want json; d=$(mktemp -d "$T/vo.XXXXXX")
  while IFS='|' read -r want json; do
    [ -n "$want" ] || continue
    run ST verdict-of --label x <<<"$json"
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
lost|{"status":"cancelled","stop_actor":"daemon","stop_reason":"trigger parent reached an incompatible terminal status","trigger":{"job_id":"a"}}
TABLE
  run ST verdict-of --label x < <("$PYBIN" -c 'import sys; sys.stdout.write("{\"status\":\"failed\",\"exit_code\":1,\"policy_state_json\":\"" + "[" * 2000000 + "\"}")')
  need "B18: a policy column nested deeper than json can read (2,000,000 levels) is lost, never a traceback" [ "$RC" = 0 -a "$OUT" = "x lost" ]
}
t_verdict_cli() {  # what verdict-of does around the mapping: identity checks, unreadable input, a restart pending that vanth status does not show
  local d j; d=$(mktemp -d "$T/vc.XXXXXX"); mkdb "$d/jobs.sqlite"
  j='{"job_id":"job_1","name":"gate-1","status":"completed","exit_code":0}'
  run ST verdict-of --job job_1 --name gate-1 --label gate-1 <<<"$j"
  need "the job asked about, under its name: its verdict" [ "$RC" = 0 -a "$OUT" = "gate-1 ok" ]
  run ST verdict-of --job job_ <<<"$j"; need "a status for another job id (a prefix Vanth resolved) is refused (exit 2)" [ "$RC" = 2 ]
  need "...saying so" grep -q 'refusing to report it for the job asked about' <<<"$OUT"
  run ST verdict-of --name gate-12 <<<"$j"; need "a status under another name is refused (exit 2)" [ "$RC" = 2 ]
  run ST verdict-of --job job_1 <<<"not json"; need "input that is not JSON: exit 6" [ "$RC" = 6 ]
  need "...printing no verdict" not grep -qE ' (ok|lost|failed)' <<<"$OUT"
  run ST verdict-of --job job_1 </dev/null; need "empty input: exit 6" [ "$RC" = 6 ]
  run ST verdict-of --job job_1 < <(printf '\377\376'); need "input that is not UTF-8: exit 6" [ "$RC" = 6 ]
  for j in '[1]' 'null' '"completed"'; do run ST verdict-of --job job_1 <<<"$j"; need "B18: $j is not a status object: exit 6, never a verdict" [ "$RC" = 6 ]; done
  run ST verdict-of < <("$PYBIN" -c 'import sys; sys.stdout.write("[" * 2000000)'); need "B18: JSON nested 2,000,000 levels deep is exit 6, not a traceback" [ "$RC" = 6 ]
  "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO jobs (job_id, name, status, policy_state_json) VALUES (?, ?, ?, ?)", ("job_r", "r", "failed", "{\"restart_after\":\"2099-01-01T00:00:00Z\"}")); c.commit()' "$d/jobs.sqlite"
  run ST verdict-of --db "$d/jobs.sqlite" --job job_r <<<'{"job_id":"job_r","status":"failed","exit_code":1}'
  need "vanth status omits policy_state_json: the row is read, and a restart pending makes the job in-flight" [ "$OUT" = "job_r in-flight" ]
  run ST verdict-of --db "$d/nowhere.sqlite" --job job_1 <<<'{"job_id":"job_1","status":"failed","exit_code":1}'
  need "a failed row whose database cannot be read is exit 1" [ "$RC" = 1 ]; need "...printing no verdict" not grep -qE ' (ok|lost|failed)' <<<"$OUT"
  run ST verdict-of --bogus <<<"$j"; need "an unknown option is a usage error (exit 2)" [ "$RC" = 2 ]
}
t_launch() {  # the process that becomes vanthd gets exactly the named variables of the environment it was started in
  run /usr/bin/env -i PATH=/usr/bin KEEP=1 DROP=2 SECRET=3 "$PYBIN" -I "$R/bin/velo-task-state" launch /usr/bin/env KEEP
  need "only the named variable reaches the program" [ "$OUT" = "KEEP=1" ]
  run /usr/bin/env -i PATH=/usr/bin KEEP=1 "$PYBIN" -I "$R/bin/velo-task-state" launch /usr/bin/env
  need "no name, no environment" [ -z "$OUT" ]
  run /usr/bin/env -i PATH=/usr/bin KEEP=1 "$PYBIN" -I "$R/bin/velo-task-state" launch /usr/bin/env KEEP ABSENT
  need "a named variable the environment does not hold is exit 1, and nothing is started" [ "$RC" = 1 ]; need "...naming it" grep -q 'not set in the environment: ABSENT' <<<"$OUT"
}
t_override() {  # the one-shot Stop override: a valid private file of yours, published atomically, consumed once, audited
  local h; mkhome; h=$E_HOME
  run ST override-take "$h"; need "nothing pending: take is exit 3" [ "$RC" = 3 ]
  run ST override-write "$h" 'closing the laptop'; need "write succeeds" [ "$RC" = 0 ]
  need "...a private regular file" [ -f "$h/stop-override" -a "$(mode_of "$h/stop-override")" = 600 ]
  need "...holding one time, uid and reason line" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z uid=[0-9]+ reason=closing the laptop$' "$h/stop-override"
  need "...and no temp file is left" [ "$(ls -A "$h" | grep -c 'stop-override\.')" = 0 ]
  run ST override-write "$h" again; need "a second write while a valid one is pending is refused (exit 1)" [ "$RC" = 1 ]
  run ST override-take "$h"; need "take consumes it (exit 0)" [ "$RC" = 0 ]; need "...it is gone" [ ! -e "$h/stop-override" ]
  run ST override-take "$h"; need "...and a second take finds none (exit 3)" [ "$RC" = 3 ]
  need "the log has the write, with the reason, and the use" [ "$(grep -c -e '^set .*reason=closing the laptop' -e '^used ' "$h/overrides.log")" = 2 ]
  : > "$h/stop-override"; chmod 600 "$h/stop-override"; run ST override-take "$h"
  need "an empty file is no override: not consumed (exit 3)" [ "$RC" = 3 -a -e "$h/stop-override" ]
  printf 'garbage\n' > "$h/stop-override"; run ST override-take "$h"; need "a corrupt file is no override (exit 3)" [ "$RC" = 3 -a -e "$h/stop-override" ]
  printf '2026-01-01T00:00:00Z uid=%s reason=x\n' "$(id -u)" > "$h/stop-override"; chmod 644 "$h/stop-override"; run ST override-take "$h"
  need "a well-formed file open to group or other is no override (exit 3)" [ "$RC" = 3 -a -e "$h/stop-override" ]
  printf '2026-01-01T00:00:00Z uid=0 reason=x\n' > "$h/stop-override"; chmod 600 "$h/stop-override"; run ST override-take "$h"
  need "a line naming another uid is no override (exit 3)" [ "$RC" = 3 ]
  run ST override-write "$h" 'replaces the corrupt one'; need "write replaces an invalid entry (exit 0)" [ "$RC" = 0 ]
  run ST override-take "$h"; need "...which is then valid and consumed" [ "$RC" = 0 ]
  printf 'SENTINEL\n' > "$E/target"; ln -s "$E/target" "$h/stop-override"
  run ST override-take "$h"; need "a symlink is no override (exit 3)" [ "$RC" = 3 ]; need "...its target is untouched" [ "$(cat "$E/target")" = SENTINEL ]
  run ST override-write "$h" 'over a stale link'; need "write replaces a stale symlink (exit 0)" [ "$RC" = 0 -a ! -L "$h/stop-override" ]
  need "...never writing through it" [ "$(cat "$E/target")" = SENTINEL ]
  run ST override-take "$h"; need "...and the new file is consumed" [ "$RC" = 0 ]
  ln -s "$E/dangling-nowhere" "$h/stop-override"; run ST override-write "$h" 'over a dangling link'; need "write replaces a dangling symlink" [ "$RC" = 0 ]; rm -f "$h/stop-override"
  printf '2026-01-01T00:00:00Z uid=%s reason=x\n' "$(id -u)" > "$E/valid-target"; chmod 600 "$E/valid-target"; ln -s "$E/valid-target" "$h/stop-override"
  run ST override-take "$h"; need "a symlink to a well-formed override is still no override (exit 3)" [ "$RC" = 3 -a -e "$E/valid-target" ]; rm -f "$h/stop-override"
  mkdir -m 700 "$h/stop-override"; run ST override-take "$h"; need "a directory is no override (exit 3)" [ "$RC" = 3 ]
  mkdir -m 700 "$h/stop-override"; : > "$h/stop-override/inside"; run ST override-write "$h" 'over a full directory'
  need "write over a directory that is not empty fails loudly (exit 1)" [ "$RC" = 1 ]; need "...leaving no temp file" [ "$(ls -A "$h" | grep -c 'stop-override\.')" = 0 ]
  rm -rf "$h/stop-override"; mkdir "$h/stop-override"
  run ST override-write "$h" 'over an empty directory'; need "write replaces an empty directory" [ "$RC" = 0 -a -f "$h/stop-override" ]; rm -f "$h/stop-override"
  ln -s "$h" "$E/homelink"; run ST override-write "$E/homelink" 'through a linked home'; need "write into a symlinked state dir is refused (exit 1)" [ "$RC" = 1 ]
  run ST override-write "$h" 'for take'; run ST override-take "$E/homelink"; need "take through a symlinked state dir is refused (exit 3)" [ "$RC" = 3 ]; rm -f "$h/stop-override"
  run ST override-write "$h" ''; need "an empty reason is a usage error (exit 2)" [ "$RC" = 2 ]
  run ST override-write "$h" $'two\nlines'; need "a reason with a newline is a usage error (exit 2)" [ "$RC" = 2 ]
}

# ---- front end ---------------------------------------------------------------------------------------
t_private_subcommands() {  # the library's functions are not subcommands, and every unknown name is exit 2
  local s; mkhome; mkvenv
  for s in _x __ cmd_run launch_daemon resolve read_verdict st die doctor reconcile ack gc project; do
    run VT "$s"; need "$s exits 2" [ "$RC" = 2 ]; need "...as an unknown subcommand" grep -q "unknown subcommand '$s'" <<<"$OUT"
  done
  need "none of them launched anything" [ "$(launches)" = 0 ]
  run VT install-vanth extra; need "an argument to install-vanth exits 2" [ "$RC" = 2 ]
  run VT; need "no subcommand prints the usage" grep -q 'velo-task run <id>' <<<"$OUT"
}
t_state_home() {  # the state root is private before anything is kept in it
  mkhome; mkvenv; chmod 755 "$E_HOME"
  run VT ensure-daemon; need "a state root that is not 0700 is refused (exit 6)" [ "$RC" = 6 ]; need "...naming the mode" grep -q 'mode 700' <<<"$OUT"
  run VT restart-daemon; need "...by restart-daemon too" [ "$RC" = 6 ]
  run VT install-vanth; need "...and by install-vanth" [ "$RC" = 6 ]
  need "nothing was launched" [ "$(launches)" = 0 ]
  chmod 700 "$E_HOME"; run VT ensure-daemon; need "control: at 0700 the daemon starts" [ "$RC" = 0 ]
}

# ---- allowlist, secrets, modes, provenance (B21, B22) -----------------------------------------------
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
t_allowlist_rejects() {  # ROW=<rule> runs only that rule's rows (the mutation proofs use it)
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
      run /bin/bash -c '. "$1"; validate_allowlist' x "$R/bin/velo-task-lib.sh"
      need "[$rule] $name is accepted by the allowlist check" [ "$RC" = 0 ]
    fi
  done <<<"$ALLOW_ROWS"
  need "the table ran at least one row" [ "$n" -ge 1 ]
}
t_allowlist_lists() {  # whole lists, and restart-daemon, which applies the same rules
  mkhome; mkvenv
  printf 'PATH\n' > "$E_HOME/vanth.env.allow"; run VT restart-daemon
  need "restart-daemon applies the same allowlist rules (exit 6)" [ "$RC" = 6 ]; need "...naming the rule" grep -q 'PATH is not allowed (reserved: PATH)' <<<"$OUT"
  need "...and nothing was launched" [ "$(launches)" = 0 ]
  printf '# comment\n\n  OPENROUTER_API_KEY  \nMY_OTHER_NAME\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "a valid list (comments, blanks, padding) is accepted" [ "$RC" = 0 ]
  printf 'lowercase\nPATH\nFOO=supersecretvalue\n1ABC\n' > "$E_HOME/vanth.env.allow"; run VT ensure-daemon
  need "every bad line is reported, not just the first (exit 6)" [ "$RC" = 6 ]
  need "...each of the four bad lines by number" [ "$(grep -c ' line [1-4]: ' <<<"$OUT")" = 4 ]
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
t_secret_argv() {  # the allowlisted value goes by name, never through an argv of a program velo-task runs through env (ps -ww shows an argv to every user)
  local k=sk-live-AAAA1111BBBB2222 s want
  mkhome; mkvenv; printf 'OPENROUTER_API_KEY\n' > "$E_HOME/vanth.env.allow"
  s="$E/spy"; mkdir -p "$s"; cp -R "$R/bin" "$R/requirements" "$s/"; render env-spy.sh "$E/env-spy"
  sedi "s#/usr/bin/env#$E/env-spy#g" "$s/bin/velo-task-lib.sh"   # a copy of the library whose every env is the spy, which logs the argv it is given and runs the real env with it
  need "precondition: the copied library runs its envs through the spy" [ "$(grep -c "$E/env-spy" "$s/bin/velo-task-lib.sh")" -ge 3 ]
  OPENROUTER_API_KEY=$k run "$s/bin/velo-task" ensure-daemon
  need "ensure-daemon through the spy succeeds (exit 0)" [ "$RC" = 0 ]
  want=$(printf %s "$k" | /usr/bin/shasum -a 256 | cut -c1-64)
  need "control: the daemon got the value all the same" grep -qx "keyhash=$want" "$E_CALLS"
  need "control: the spy saw velo-task's calls" [ "$(grep -c . "$E/env-argv.log")" -ge 2 ]
  need "the value is in no argv env was given" not grep -qF "$k" "$E/env-argv.log"
}
t_launch_log_not_shown() {  # the launch log can hold what a daemon echoes, so the error names it and shows none of it
  local k=plain-allowlisted-value-77
  mkhome; mkvenv; printf 'MY_PASSPHRASE\n' > "$E_HOME/vanth.env.allow"; printf 'MY_PASSPHRASE\n' > "$E/echo-key"
  MY_PASSPHRASE=$k run VT ensure-daemon
  need "a daemon that dies at start, quoting an allowlisted value in its message: exit 6" [ "$RC" = 6 ]
  need "...the message names the launch log" grep -qF "see $E_HOME/daemon.launch.log" <<<"$OUT"
  need "control: the log holds the daemon's words, value included (it is private, 0600)" grep -qF "MY_PASSPHRASE=$k" "$E_HOME/daemon.launch.log"
  need "the value is nowhere in the message" not grep -qF "$k" <<<"$OUT"
  need "the launch log is private" [ "$(mode_of "$E_HOME/daemon.launch.log")" = 600 ]
}
t_digest_inherited() {  # the launch digest covers the allowlisted names this environment SETS, which are what the daemon gets: it is adopted only by an environment that would launch it the same
  local pa want
  mkhome; mkvenv; printf 'OPENROUTER_API_KEY\n' > "$E_HOME/vanth.env.allow"
  run /usr/bin/env -u OPENROUTER_API_KEY "$R/bin/velo-task" ensure-daemon   # -u: the caller's own environment may hold the key; A must not
  need "environment A (the name listed, not set) starts a daemon (exit 0)" [ "$RC" = 0 ]
  need "...which got no key" grep -qx 'keyhash=unset' "$E_CALLS"; pa=$(daemon_pid)
  OPENROUTER_API_KEY=value-of-B run VT ensure-daemon
  need "environment B (the name set) does not adopt it (exit 6)" [ "$RC" = 6 ]
  need "...because the launch digest differs" grep -q 'launch digest differs' <<<"$OUT"
  need "...pointing at restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
  need "...the daemon is untouched" alive "$pa"; need "...and nothing new was launched" [ "$(launches)" = 1 ]
  OPENROUTER_API_KEY=value-of-B run VT restart-daemon; need "restart-daemon from B replaces it (exit 0)" [ "$RC" = 0 ]
  want=$(printf %s value-of-B | /usr/bin/shasum -a 256 | cut -c1-64)
  need "...with B's key" grep -qx "keyhash=$want" "$E_CALLS"
  OPENROUTER_API_KEY=value-of-B run VT ensure-daemon; need "B adopts the daemon it launched" grep -q adopted <<<"$OUT"
  OPENROUTER_API_KEY=another-value run VT ensure-daemon; need "...so does an environment with another value of the key: the digest holds names, never values" grep -q adopted <<<"$OUT"
  run /usr/bin/env -u OPENROUTER_API_KEY "$R/bin/velo-task" ensure-daemon
  need "A, which would launch it without the key, does not adopt it (exit 6)" [ "$RC" = 6 ]; need "...pointing at restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
}
t_modes_env() {  # B22
  local f; mkhome; mkvenv; run VT ensure-daemon; need "clean launch succeeds" [ "$RC" = 0 ]
  need "VANTH_HOME is 0700" [ "$(mode_of "$E_VH")" = 700 ]
  for f in jobs.sqlite daemon.json token logs/daemon.log events/e.jsonl; do need "$f is 0600" [ "$(mode_of "$E_VH/$f")" = 600 ]; done
  need "VANTH_HOME, the port and retention=0 reach the daemon through the launch" \
    grep -qx "launch pid=$(daemon_pid) umask=0077 home=$E_VH port=$E_PORT retention=0" "$E_CALLS"
  need "the provenance records the daemon's pid" [ "$(prov pid)" = "$(daemon_pid)" ]
  need "...its start time" [ -n "$(prov lstart)" ]; need "...and the launch digest" grep -Eq '^digest=[0-9a-f]{64}$' "$E_HOME/daemon.provenance"
  need "...and is private" [ "$(mode_of "$E_HOME/daemon.provenance")" = 600 ]
}
t_provenance_refusals() {  # B22: one scenario per validity condition, the others held true so each is individually provable
  local p dp um good
  for um in 077 022; do
    mkhome; mkvenv; prestart $um || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid)
    run VT ensure-daemon; need "daemon pre-started by hand under umask $um is refused (exit 6)" [ "$RC" = 6 ]
    need "...with the restart-daemon hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
    if [ "$um" = 077 ]; then need "...because nothing proves velo-task launched it" grep -q 'not provably the one velo-task launched' <<<"$OUT"
    else need "...because its files are readable by others" grep -q 'open to group or other' <<<"$OUT"; fi
    need "...and left alone" alive "$p"; need "...and nothing new launched" [ "$(launches)" = 1 ]; kill "$p"
  done
  mkhome; mkvenv; prestart 077 OPENROUTER_API_KEY=inherited-secret; p=$(daemon_pid)
  run VT ensure-daemon; need "a daemon holding inherited secrets (even under umask 077) is refused" [ "$RC" = 6 ]; kill "$p"
  mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid); good="$E/prov.good"; cp "$E_HOME/daemon.provenance" "$good"
  dp=$(decoy veloa)   # a live process that is not the daemon
  write_prov "$dp" "$(lstart_of "$dp")" "$(sed -n 's/^digest=//p' "$good")"
  run VT ensure-daemon; need "provenance naming another live pid than daemon.json is rejected" [ "$RC" = 6 ]
  need "...saying so" grep -q 'daemon.json pid' <<<"$OUT"
  sed "s/^lstart=.*/lstart=$(shift_lstart "$(lstart_of "$p")" -2)/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a recorded start time 2 s off the live process is rejected" [ "$RC" = 6 ]
  need "...as stale provenance or a reused pid" grep -q 'reused pid' <<<"$OUT"
  sed "s/^lstart=.*/lstart=Mon Jan 1 00:00:00 2001/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "provenance left from another boot is rejected" [ "$RC" = 6 ]
  sed "s/^digest=.*/digest=$(printf '%064d' 0)/" "$good" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a different launch digest (e.g. retention > 0) is rejected" [ "$RC" = 6 ]
  need "...saying digest" grep -q 'digest' <<<"$OUT"
  printf 'pid=%s\n' "$p" > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a provenance with no start time or digest is rejected" [ "$RC" = 6 ]
  printf 'pid=notapid\nlstart=x\ndigest=y\n' > "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a provenance with a malformed pid is rejected" [ "$RC" = 6 ]; need "...naming the pid" grep -q 'no valid pid' <<<"$OUT"
  rm "$E_HOME/daemon.provenance"; ln -s "$good" "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "a provenance that is a symlink is rejected" [ "$RC" = 6 ]
  rm "$E_HOME/daemon.provenance"; cp "$good" "$E_HOME/daemon.provenance"
  run VT ensure-daemon; need "control: the untouched provenance is adopted" [ "$RC" = 0 ]
  need "...as adopted" grep -q adopted <<<"$OUT"
  need "...and the control never launched anything" [ "$(launches)" = 1 ]
  kill "$p"
}
t_daemon_json_malformed() {  # a daemon.json that cannot be parsed is an error that stops the command, never an empty answer that skips the pid cross-check (no daemon.json at all stays an empty one)
  local p
  mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid); cp "$E_VH/daemon.json" "$E/dj.good"
  printf '{"pid": %s, "started_at": ' "$p" > "$E_VH/daemon.json"   # cut short; the fake vanth reads the pid from it with sed, so the daemon still answers
  run VT restart-daemon
  need "restart-daemon with a daemon.json it cannot parse refuses (exit 6)" [ "$RC" = 6 ]; need "...naming daemon.json" grep -q 'daemon.json cannot be read as JSON' <<<"$OUT"
  need "...the daemon was not signalled" alive "$p"; need "...and nothing was launched" [ "$(launches)" = 1 ]
  run VT ensure-daemon
  need "ensure-daemon refuses it too (exit 6)" [ "$RC" = 6 ]; need "...naming daemon.json, not a pid mismatch" grep -q 'daemon.json cannot be read as JSON' <<<"$OUT"
  need "...and launched nothing" [ "$(launches)" = 1 ]
  cp "$E/dj.good" "$E_VH/daemon.json"; run VT restart-daemon
  need "control: with daemon.json whole again restart-daemon replaces the daemon (exit 0)" [ "$RC" = 0 ]; need "...the old one is gone" not alive "$p"
  mkhome; mkvenv; VT ensure-daemon >/dev/null; p=$(daemon_pid); rm "$E_VH/daemon.json"
  run VT ensure-daemon
  need "without a daemon.json the record of the live daemon is what refuses the launch (exit 6)" [ "$RC" = 6 ]; need "...saying it does not answer" grep -q 'does not answer' <<<"$OUT"
  need "...the daemon was not signalled" alive "$p"; need "...and nothing was launched" [ "$(launches)" = 1 ]
  run VT restart-daemon
  need "restart-daemon stops a recorded daemon that never answered and relaunches (exit 0)" [ "$RC" = 0 ]; need "...the hung one is gone" not alive "$p"
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
t_modes_refuse() {  # loose state is refused on every lifecycle call, restart included, before anything else happens
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
  need "a directory the mode check cannot read is an error, never a pass (exit 6)" [ "$RC" = 6 ]
  run VT restart-daemon; need "...by restart-daemon too" [ "$RC" = 6 ]; need "...with the daemon left alone" alive "$p"
  chmod 700 "$E_VH/events/locked"; rmdir "$E_VH/events/locked"
  run VT ensure-daemon; need "control: private again, the daemon is adopted" grep -q adopted <<<"$OUT"
}
t_modes_after_launch() {  # a daemon that leaves a file readable by others despite umask 077 is caught right after the launch
  local p; mkhome; mkvenv; : > "$E/loose-file"
  run VT ensure-daemon
  need "a launch whose daemon leaves a file readable by others is refused (exit 6)" [ "$RC" = 6 ]
  need "...naming the file" grep -q 'logs/daemon.log' <<<"$OUT"
  p=$(daemon_pid)
  need "...the daemon it started is running and recorded as ours" alive "$p"; need "...in the provenance" [ "$(prov pid)" = "$p" ]
  run VT ensure-daemon; need "the next call refuses before doing anything (exit 6)" [ "$RC" = 6 ]; need "...launching nothing" [ "$(launches)" = 1 ]
}
t_concurrent_ensure() {  # two ensure-daemon at once, nothing running: Vanth's own home lock keeps one daemon; the loser adopts it
  local w1 w2
  mkhome; mkvenv
  ( VT ensure-daemon > "$E/o1" 2>&1; echo $? > "$E/rc1" ) & w1=$!
  ( VT ensure-daemon > "$E/o2" 2>&1; echo $? > "$E/rc2" ) & w2=$!
  wait "$w1" "$w2"   # not a bare wait: mkhome's port holder is also a child of this shell
  need "the first caller succeeds" [ "$(cat "$E/rc1")" = 0 ]
  need "the second caller succeeds" [ "$(cat "$E/rc2")" = 0 ]
  need "exactly one daemon was launched" [ "$(launches)" = 1 ]
  need "one caller started the daemon" [ "$(cat "$E/o1" "$E/o2" | grep -c '(started)')" = 1 ]
  need "the other adopted it" [ "$(cat "$E/o1" "$E/o2" | grep -c '(adopted)')" = 1 ]
  need "the provenance names the daemon that is up" [ "$(prov pid)" = "$(daemon_pid)" ]
}
t_restart() {
  local p1 p2; mkhome; mkvenv; VT ensure-daemon >/dev/null; p1=$(daemon_pid)
  OPENROUTER_API_KEY=caller-secret-9 run VT restart-daemon; need "restart-daemon exits 0" [ "$RC" = 0 ]
  p2=$(daemon_pid)
  need "the old daemon is gone" not alive "$p1"
  need "a new daemon runs" alive "$p2"; need "...under a new pid" [ "$p2" != "$p1" ]
  need "the provenance names the new daemon" [ "$(prov pid)" = "$p2" ]
  need "the caller's secret did not reach the new daemon" [ "$(grep -c '^keyhash=unset' "$E_CALLS")" = 2 ]
  need "restart-daemon never calls vanth restart" not grep -q '^vanth restart' "$E_CALLS"
  run VT ensure-daemon; need "the new daemon is adopted" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
}
t_restart_digest_change() {  # a daemon launched with an older configuration is replaced by restart-daemon, the recovery ensure-daemon names
  local p1 p2; mkhome; mkvenv; VT ensure-daemon >/dev/null; p1=$(daemon_pid)
  printf 'MY_NEW_KEY\n' > "$E_HOME/vanth.env.allow"
  run VT ensure-daemon
  need "an allowlisted name this environment does not set changes nothing the daemon would get, so the digest is the same: adopted" grep -q adopted <<<"$OUT"
  MY_NEW_KEY=fresh-value run VT ensure-daemon
  need "the allowlist changed and the name is set, so the running daemon no longer matches: ensure-daemon refuses (exit 6)" [ "$RC" = 6 ]
  need "...naming the launch digest" grep -q 'launch digest' <<<"$OUT"; need "...and restart-daemon" grep -q 'velo-task restart-daemon' <<<"$OUT"
  need "...the old daemon is untouched" alive "$p1"
  MY_NEW_KEY=fresh-value run VT restart-daemon
  need "restart-daemon accepts a record whose digest is an older configuration's and replaces the daemon (exit 0)" [ "$RC" = 0 ]
  p2=$(daemon_pid); need "...the old daemon is gone" not alive "$p1"; need "...a new one runs" alive "$p2"
  need "...which received the newly allowlisted key" grep -q '^names=.*MY_NEW_KEY' "$E_CALLS"
  MY_NEW_KEY=fresh-value run VT ensure-daemon; need "...and is adopted by ensure-daemon, from an environment that sets the key as the launch did" grep -q adopted <<<"$OUT"
}
t_restart_refuses_unproven() {  # restart-daemon signals only a process that a matching record proves is ours
  local p dp other v ls; mkhome; mkvenv
  prestart 077 || { echo "FAILED: pre-start"; exit 1; }; p=$(daemon_pid); ls=$(lstart_of "$p")
  run VT restart-daemon
  need "a real daemon with no record at all: restart-daemon refuses (exit 6)" [ "$RC" = 6 ]
  need "...saying no record proves velo-task launched it" grep -q 'no velo-task record proves' <<<"$OUT"
  need "...it was not signalled" alive "$p"; need "...nothing was launched" [ "$(launches)" = 1 ]
  for v in badstart offby2 nostart nopid; do  # each record fails ONE check
    case "$v" in
      badstart) printf 'pid=%s\nlstart=Mon Jan 1 00:00:00 2001\ndigest=%s\n' "$p" "$D64" ;;
      offby2)   printf 'pid=%s\nlstart=%s\ndigest=%s\n' "$p" "$(shift_lstart "$ls" -2)" "$D64" ;;
      nostart)  printf 'pid=%s\ndigest=%s\n' "$p" "$D64" ;;
      nopid)    printf 'lstart=%s\ndigest=%s\n' "$ls" "$D64" ;;
    esac > "$E_HOME/daemon.provenance"
    run VT restart-daemon
    need "[$v] a provenance that does not match: restart-daemon refuses (exit 6)" [ "$RC" = 6 ]
    need "[$v] ...the daemon was not signalled" alive "$p"; need "[$v] ...nothing was launched" [ "$(launches)" = 1 ]
  done
  dp=$(decoy vanthd); write_prov "$dp" "$(lstart_of "$dp")"
  run VT restart-daemon
  need "a valid record for another live process while daemon.json names this one: refused (exit 6)" [ "$RC" = 6 ]
  need "...saying daemon.json names another pid" grep -q 'daemon.json names pid' <<<"$OUT"
  need "...neither process was signalled" alive "$p"; need "...the other process either" alive "$dp"; kill "$dp"
  ( exec /bin/sleep 0 ) </dev/null >/dev/null 2>&1 & other=$!; wait "$other" 2>/dev/null
  write_prov "$other" 'Mon Jan 1 00:00:00 2001'
  run VT restart-daemon; need "a record naming a dead process while an unrelated daemon answers: refused (exit 6)" [ "$RC" = 6 ]
  need "...the daemon was not signalled" alive "$p"; need "...nothing was launched" [ "$(launches)" = 1 ]
  write_prov "$p" "$ls" "$D64"
  run VT restart-daemon
  need "control: a record whose pid and start time match is acted on, whatever its digest (exit 0)" [ "$RC" = 0 ]
  need "...the daemon was signalled and replaced" not alive "$p"; need "...by one that is recorded" [ "$(prov pid)" = "$(daemon_pid)" ]
  mkhome; mkvenv; dp=$(decoy vanthd); write_json "$dp" 2001-01-01T00:00:00Z
  run VT restart-daemon; need "a process daemon.json names but nothing records: exit 6" [ "$RC" = 6 ]
  need "...because no record proves velo-task launched it" grep -q 'no velo-task record proves' <<<"$OUT"
  need "...not signalled" alive "$dp"; need "...nothing launched" [ "$(launches)" = 0 ]
}
t_stop_failure() {  # a bounded wait, no SIGKILL escalation, no second daemon launched over a live one
  local p; mkhome; mkvenv; : > "$E/ignore-term"; VT ensure-daemon >/dev/null; p=$(daemon_pid)
  VELO_TASK_STOP_WAIT=1 run VT restart-daemon
  need "a daemon that ignores SIGTERM: restart-daemon gives up with exit 6" [ "$RC" = 6 ]
  need "...saying it is still running" grep -q 'still running' <<<"$OUT"
  need "...leaving that daemon alone" alive "$p"
  need "...and starting no second daemon" [ "$(launches)" = 1 ]
  need "...its provenance still names the daemon" [ "$(prov pid)" = "$p" ]
  kill -9 "$p"
}
t_launch_failure() {
  local t0 t1; mkhome; mkvenv; : > "$E/fail-launch"
  t0=$(now); VELO_TASK_START_WAIT=5 run VT ensure-daemon; t1=$(now)
  need "a daemon that dies at start: exit 6" [ "$RC" = 6 ]; need "...saying so" grep -q 'did not become ready' <<<"$OUT"
  need "...naming the launch log" grep -q 'daemon.launch.log' <<<"$OUT"
  need "...the log holds the daemon's reason" grep -q 'refusing to start' "$E_HOME/daemon.launch.log"
  need "no provenance is written" [ ! -e "$E_HOME/daemon.provenance" ]
}
t_port_collision() {  # the daemon cannot bind because a foreign process holds the port
  local fp; mkhome foreign; mkvenv; fp=$E_HOLDER   # a foreign process holds the port from the start, never released and bound again
  run VT ensure-daemon
  need "ensure-daemon fails (exit 6)" [ "$RC" = 6 ]; need "...saying the daemon did not become ready" grep -q 'did not become ready' <<<"$OUT"
  need "...the launch log holds the daemon's own reason" grep -q 'cannot bind' "$E_HOME/daemon.launch.log"
  need "no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]
  need "the foreign process is still alive" alive "$fp"; need "...and was never signalled" [ ! -s "$E/signals" ]
  run VT restart-daemon
  need "restart-daemon fails the same way and signals nobody (exit 6)" [ "$RC" = 6 ]
  need "...the foreign process is alive and unsignalled" alive "$fp"; need "...still no signal" [ ! -s "$E/signals" ]
}
t_launch_requires_own_pid() {  # the daemon that answers must be the one that was launched; another one answering is not a ready launch
  local other; mkhome; mkvenv
  other=$(decoy vanthd); printf '%s\n' "$other" > "$E/forge-json"   # the fake writes a daemon.json naming this process and never listens
  # The real code waits out its whole allowance (2 s), because the daemon that answers is never the one it launched. The mutant is ready at the first answer,
  # so a proof gives the launch 20 s to produce one: on a slow host the mutant would otherwise run out the clock like the real code and look correct.
  VELO_TASK_START_WAIT=$([ -z "${IN_PROOF:-}" ] && echo 2 || echo 20) run VT ensure-daemon
  need "a launch while daemon.json names another live process never counts as ready (exit 6)" [ "$RC" = 6 ]
  need "...saying the daemon did not become ready" grep -q 'did not become ready' <<<"$OUT"
  need "no provenance was published for the launched pid" [ ! -e "$E_HOME/daemon.provenance" ]
  need "the process daemon.json names was not signalled" alive "$other"
}
t_loopback() {  # the daemon's real listener decides, not what daemon.json says
  local p p2 digest
  mkhome wild; mkvenv; : > "$E/bind-all"   # its daemons listen on 0.0.0.0, so the port is held there too
  run can_bind 0.0.0.0 "$E_PORT" server; need "(setup) the reserved port is held on 0.0.0.0, where this test's daemon binds: a foreign server is refused" [ "$RC" = 1 ]
  run VT ensure-daemon
  need "a launch whose daemon listens on every interface is refused (exit 6)" [ "$RC" = 6 ]
  need "...naming the rule" grep -q "only 127.0.0.1:$E_PORT is allowed" <<<"$OUT"
  p=$(sed -n 's/^launch pid=\([0-9]*\) .*/\1/p' "$E_CALLS")
  need "...the daemon it launched was stopped" not alive "$p"
  need "...no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]
  rm "$E/bind-all"
  run VT ensure-daemon; need "control: the same launch listening on 127.0.0.1 only is accepted (exit 0)" [ "$RC" = 0 ]
  p=$(daemon_pid); digest=$(prov digest); kill "$p"; waitfor 5 not alive "$p" || { echo "FAILED: daemon did not stop"; exit 1; }
  : > "$E/bind-all"; prestart 077 || { echo "FAILED: pre-start"; exit 1; }; p2=$(daemon_pid)
  rm -f "$E_HOME/daemon.provenance"; write_prov "$p2" "$(lstart_of "$p2")" "$digest"
  run VT ensure-daemon
  need "a daemon with valid provenance that listens wide is not adopted (exit 6)" [ "$RC" = 6 ]
  need "...naming the rule" grep -q "only 127.0.0.1:$E_PORT is allowed" <<<"$OUT"; need "...and it was not signalled" alive "$p2"
  # Where lsof is not installed (a Linux host without it) the listener cannot be seen, and a daemon nobody can check is refused, not
  # trusted: this daemon listens on 127.0.0.1 only, and is refused all the same, by the tool's absence.
  mkhome; mkvenv; mkcode "$E/nolsof"
  sedi 's#^for p in /usr/sbin/lsof /usr/bin/lsof; do#for p in /no/such/dir/lsof; do#' "$E/nolsof/bin/velo-task-lib.sh"
  run "$E/nolsof/bin/velo-task" ensure-daemon
  need "with no lsof a launch is refused (exit 6)" [ "$RC" = 6 ]
  need "...saying there is no lsof" grep -q 'there is no lsof' <<<"$OUT"
  p=$(sed -n 's/^launch pid=\([0-9]*\) .*/\1/p' "$E_CALLS")
  need "...the daemon it launched was stopped" not alive "$p"
  need "...no provenance was published" [ ! -e "$E_HOME/daemon.provenance" ]
}
can_bind() {  # <host> <port> <server|daemon>: whether a process can bind host:port as an ordinary server (SO_REUSEADDR) or as the fake vanthd (SO_REUSEADDR and SO_REUSEPORT); on stderr, why not
  "$PYBIN" -I -c 'import socket, sys
host, port, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if kind == "daemon":
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
try:
    s.bind((host, port))
except OSError as exc:
    sys.exit(exc.strerror)' "$@"
}
t_port_reservation() {  # the port reserved for a daemon that listens on every interface is held on that address too: the fixture of t_loopback
  local held
  mkhome wild
  run can_bind 0.0.0.0 "$E_PORT" server
  need "a foreign server cannot bind the reserved port on 0.0.0.0 (exit 1)" [ "$RC" = 1 ]; need "...because the port is in use" grep -q 'Address already in use' <<<"$OUT"
  run can_bind 127.0.0.1 "$E_PORT" server
  need "...nor on 127.0.0.1 (exit 1)" [ "$RC" = 1 ]; need "...because the port is in use" grep -q 'Address already in use' <<<"$OUT"
  run can_bind 0.0.0.0 "$E_PORT" daemon; need "control: the fake vanthd, which sets SO_REUSEPORT, binds 0.0.0.0 beside the reservation (exit 0)" [ "$RC" = 0 ]
  run can_bind 127.0.0.1 "$E_PORT" daemon; need "...and 127.0.0.1 (exit 0)" [ "$RC" = 0 ]
  held=$("$LSOF" -nP -a -p "$E_HOLDER" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | tr '\n' ' ')
  # BSD: the reservation listens on loopback, which is what makes a foreign SO_REUSEADDR server refuse the port, and nowhere else.
  # Linux: it holds the port without listening at all, because a listener there would take its share of the daemon's connections.
  if [ "$(uname)" = Linux ]; then want=""; else want="127.0.0.1:$E_PORT "; fi
  OUT="the reservation listens on: ${held:-nothing}"
  need "the reservation listens on 127.0.0.1 only (on Linux: it holds the port and listens nowhere)" [ "$held" = "$want" ]
}
t_before_install() {
  mkhome; run VT ensure-daemon; need "ensure-daemon before install-vanth exits 6" [ "$RC" = 6 ]
  need "...and says which command to run" grep -q 'velo-task install-vanth' <<<"$OUT"
}
t_no_path_tools() {  # no tool is looked up on the caller's PATH, so a shim in front of the system directories never runs
  local sh n; mkhome; mkuv ok; sh="$E/shims"; mkdir "$sh"
  printf '#!/bin/sh\necho "$0 $*" >> "%s/sentinel"\nexit 97\n' "$E" > "$sh/shim"; chmod +x "$sh/shim"
  for n in sed awk grep date env ps lsof uv shasum sort tr head cat mktemp diff dirname rm mkdir chmod mv cp stat od cut python python3 sleep pkill pgrep find bash sh; do
    ln "$sh/shim" "$sh/$n"
  done
  mkcode "$E/code"
  PATH="$sh" run "$E/code/bin/velo-task" install-vanth; need "install-vanth builds the venv with only shims on PATH" [ "$RC" = 0 ]
  PATH="$sh" run "$E/code/bin/velo-task" ensure-daemon; need "ensure-daemon launches with only shims on PATH" [ "$RC" = 0 ]
  PATH="$sh" run "$E/code/bin/velo-task" ensure-daemon; need "...adopts the daemon on the next call" grep -q adopted <<<"$OUT"
  PATH="$sh" run "$E/code/bin/velo-task" restart-daemon; need "restart-daemon replaces the daemon" [ "$RC" = 0 ]
  PATH="$sh" run "$E/code/bin/velo-task" install-vanth; need "install-vanth on an installed venv verifies it" grep -q 'already installed' <<<"$OUT"
  need "no shim ran (the sentinel is absent)" [ ! -e "$E/sentinel" ]
  need "uv was given the fixed system PATH, not the caller's" grep -qx 'path=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$E/uv.log"
}
t_hostile_env() {  # nothing velo-task starts reads the caller's PYTHONPATH, BASH_ENV, ENV or the user's site: hostile ones that write a sentinel never fire
  local d s hh us; mkhome; mkuv ok; d="$E/hostile"; s="$d/sentinel"; hh="$d/home"; mkdir -p "$d/py"; mkdir -m 700 "$hh"
  printf 'open("%s", "a").write("sitecustomize\\n")\n' "$s" > "$d/py/sitecustomize.py"
  printf 'echo bash_env >> "%s"\n' "$s" > "$d/bash_env.sh"
  us=$(HOME="$hh" "$PYBIN" -c 'import site; print(site.getusersitepackages())'); mkdir -p "$us"
  printf 'open("%s", "a").write("usercustomize\\n")\n' "$s" > "$us/usercustomize.py"
  PYTHONPATH="$d/py" "$PYBIN" -c pass; need "control: a python started with that PYTHONPATH runs its sitecustomize" grep -q sitecustomize "$s"; rm -f "$s"
  HOME="$hh" "$PYBIN" -c pass; need "control: a python started with that HOME runs the usercustomize in its user site" grep -q usercustomize "$s"; rm -f "$s"
  BASH_ENV="$d/bash_env.sh" /bin/bash -c ':'; need "control: a bash started with that BASH_ENV runs it" grep -q bash_env "$s"; rm -f "$s"
  quiet() { OUT="fired: $(cat "$s" 2>/dev/null | tr '\n' ' ')"; [ ! -e "$s" ]; }
  mkcode "$E/code"
  hostile() {  # <entry point>: run from a clean shell that has loaded the library, the hostile variables set only AFTER that shell started
    HOME="$hh" HOSTILE="$d" run /bin/bash -c '. "$1"; shift; export PYTHONPATH="$HOSTILE/py" BASH_ENV="$HOSTILE/bash_env.sh" ENV="$HOSTILE/bash_env.sh"; "$@"' x "$E/code/bin/velo-task-lib.sh" "$@"
  }
  hostile cmd_install_vanth; need "install-vanth runs with the hostile variables set (exit 0)" [ "$RC" = 0 ]; need "...and none of them fired" quiet
  VELO_TASK_START_WAIT="x[\$(echo arith >> '$s')]" hostile cmd_ensure_daemon
  need "a wait that is not a plain number is refused when the library loads (exit 2)" [ "$RC" = 2 ]
  need "...naming it" grep -q 'VELO_TASK_START_WAIT must be a whole number' <<<"$OUT"; need "...and the command substitution inside it never ran" [ ! -e "$s" ]
  VELO_TASK_POLL='0.1 -x' hostile cmd_ensure_daemon; need "a poll interval that is not a number is refused (exit 2)" [ "$RC" = 2 ]
  need "...nothing was launched by either" [ "$(launches)" = 0 ]
  VELO_TASK_RETRY_SLEEP='0.1 -x' hostile cmd_ensure_daemon; need "a re-try pause that is not a number is refused (exit 2)" [ "$RC" = 2 ]
  hostile cmd_ensure_daemon; need "ensure-daemon starts the daemon with the hostile variables set (exit 0)" [ "$RC" = 0 ]; need "...as started" grep -q '(started)' <<<"$OUT"
  need "...and none of them fired" quiet
  hostile cmd_ensure_daemon; need "ensure-daemon adopts it (exit 0)" [ "$RC" = 0 ]; need "...as adopted" grep -q '(adopted)' <<<"$OUT"; need "...and none of them fired" quiet
  hostile cmd_restart_daemon; need "restart-daemon replaces it (exit 0)" [ "$RC" = 0 ]; need "...and none of them fired" quiet
}


# ---- install-vanth (B23) -----------------------------------------------------------------------------
t_install_asserts() {  # a Vanth whose schema or closure differs from the pin is not installed
  local v
  for v in nocolumn extra missing; do
    mkhome; mkuv $v; installv
    need "variant $v: install-vanth fails" [ "$RC" = 1 ]; need "...and removes the venv" [ ! -e "$E_VENV" ]
    need "...and leaves no install marker" [ ! -e "$E_VENV/.velo-task-installed" ]
  done
  mkhome; mkuv nocolumn; installv; need "a missing column is named" grep -q 'schema lacks columns' <<<"$OUT"
  mkhome; mkuv extra; installv; need "an extra distribution is reported as a difference from the lock" grep -q 'differ from the lock' <<<"$OUT"
}
t_install_idempotent() {
  local m; mkhome; mkuv ok; installv; installv
  need "a second run succeeds" [ "$RC" = 0 ]; need "...reporting already installed" grep -q 'already installed' <<<"$OUT"
  need "...without building another venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 1 ]
  echo '# reviewed upgrade' >> "$E/code/requirements/vanth.lock"; run "$E/code/bin/velo-task" install-vanth
  need "a changed lock installs again" [ "$RC" = 0 ]; need "...by building a new venv" [ "$(grep -c '^uv venv' "$E/uv.log")" = 2 ]
}
t_install_refuses_under_daemon() {
  mkhome; mkuv ok; installv; mkvenv; VT ensure-daemon >/dev/null; echo 'stale' > "$E_VENV/.velo-task-installed"
  : > "$E/uv.log"; run "$E/code/bin/velo-task" install-vanth
  need "reinstalling over a running daemon exits 6" [ "$RC" = 6 ]; need "...saying so" grep -q 'is running from' <<<"$OUT"
  need "...and builds nothing" [ ! -s "$E/uv.log" ]
}
t_install_failure_under_daemon() {  # a failed verification must not delete the venv a live daemon is running from
  mkhome; mkuv ok; installv; mkvenv; VT ensure-daemon >/dev/null
  mkuv extra; mkcode "$E/code"; run "$E/code/bin/velo-task" install-vanth   # the marker is current, so this verifies; the verification fails
  need "a failed verification under a running daemon exits 6" [ "$RC" = 6 ]
  need "...saying the venv was left in place" grep -q 'left in place' <<<"$OUT"
  need "...keeping the venv" [ -x "$E_VENV/bin/vanthd" ]
  need "...and the daemon" alive "$(daemon_pid)"
}
t_install_broken_venv() {  # a venv whose python does not run (a build that died half way) is rebuilt
  mkhome; mkuv ok; installv
  rm "$E_VENV/.velo-task-installed"; printf 'SENTINEL\n' > "$E_VENV/bin/python"; chmod 755 "$E_VENV/bin/python"
  : > "$E/uv.log"; run "$E/code/bin/velo-task" install-vanth
  need "install-vanth over a venv whose python does not run rebuilds it (exit 0)" [ "$RC" = 0 ]
  need "...by running uv venv" grep -q '^uv venv' "$E/uv.log"
  need "...and marks the install" [ -s "$E_VENV/.velo-task-installed" ]
}
t_install_hash_tamper() {  # B23, offline: the fake uv refuses, as uv does under --require-hashes, a lock with a hash that is not the wheel's
  mkhome; mkuv ok; mkcode "$E/code"
  sedi 's/--hash=sha256:f072f4d8/--hash=sha256:e072f4d8/' "$E/code/requirements/vanth.lock"
  need "precondition: one hash in the copied lock is changed, in that copy only" [ "$(grep -c 'sha256:e072f4d8' "$E/code/requirements/vanth.lock")/$(grep -c 'sha256:f072f4d8' "$R/requirements/vanth.lock")" = 1/1 ]
  run "$E/code/bin/velo-task" install-vanth
  need "a lock with one hash that is not its wheel's fails install-vanth (exit 1)" [ "$RC" = 1 ]
  need "...because uv refused that hash" grep -q 'Hash mismatch for annotated-types==0.8.0' <<<"$OUT"
  need "...no install marker was written" [ ! -e "$E_VENV/.velo-task-installed" ]; need "...and no venv is left" [ ! -e "$E_VENV" ]
  installv; need "control: the untampered lock installs (exit 0)" [ "$RC" = 0 ]; need "...and leaves the marker" [ -s "$E_VENV/.velo-task-installed" ]
}
t_install_ships_lock() {  # the installed bin/velo-task resolves ../requirements/vanth.lock and its hooks sit beside bin/: install.sh must ship all of it
  local s="$T/inst-src" dest="$T/inst-dest" skills="$T/inst-skills"; rm -rf "$s" "$dest" "$skills"; mkdir -p "$s/bin" "$s/requirements" "$s/hooks"
  cp "$R/install.sh" "$s/install.sh"; cp "$R/bin/velo-task" "$R/bin/velo-task-lib.sh" "$R/bin/velo-task-state" "$s/bin/"; cp "$R/requirements/vanth.lock" "$R/requirements/vanth.wheels.tsv" "$s/requirements/"
  cp "$R/hooks/velo-task-stop-guard.sh" "$R/hooks/velo-task-session-start.sh" "$s/hooks/"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh"
  need "install.sh succeeds" [ "$RC" = 0 ]
  need "the library velo-task sources is installed beside it" [ -f "$dest/bin/velo-task-lib.sh" ]
  need "the Stop guard and the SessionStart hook are installed, executable" [ -x "$dest/hooks/velo-task-stop-guard.sh" -a -x "$dest/hooks/velo-task-session-start.sh" ]
  need "the reviewed wheel manifest is installed beside the lock" cmp -s "$R/requirements/vanth.wheels.tsv" "$dest/requirements/vanth.wheels.tsv"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check sees no drift right after an install" [ "$RC" = 0 ]
  echo '# edited in place' >> "$dest/requirements/vanth.lock"
  VELO_AGENTS_HOME="$dest" VELO_CLAUDE_SKILLS="$skills" run bash "$s/install.sh" --check
  need "install.sh --check reports a hand-edited installed lock as drift" [ "$RC" != 0 ]
}

# ---- run, status, wait, cancel against a fake Vanth that keeps real state -----------------------------
mkjobs() {  # a fake installed Vanth whose CLI keeps jobs in $E_VH/jobs.sqlite, and a daemon that is up
  mkhome; mkvenv; render fake-vanth-jobs.py "$E_VENV/bin/vanth"
  VT ensure-daemon >/dev/null || { echo "FAILED: setup ensure-daemon"; exit 1; }
  VANTH_HOME="$E_VH" "$E_VENV/bin/vanth" status nothing >/dev/null 2>&1; true   # makes the tables in the file the daemon created empty
  SID=sess-abc123; export CLAUDE_SESSION_ID=$SID
}
inject() { VANTH_HOME="$E_VH" "$E_VENV/bin/vanth" __inject "$1"; }   # <json row> -> its job_id
sql() { "$PYBIN" -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); [print(*r) for r in c.execute(sys.argv[2], sys.argv[3:])]; c.commit()' "$E_VH/jobs.sqlite" "$@"; }
s8() { printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-8; }
t_run_validation() {  # B3, B11: refused before the daemon is touched
  local a
  mkhome; mkvenv; export CLAUDE_SESSION_ID=sess-abc123
  run VT run gate-1 -- /usr/bin/true; need "no --timeout: exit 2" [ "$RC" = 2 ]; need "...saying it is required" grep -q -- '--timeout S is required' <<<"$OUT"
  for a in Gate-1 ab -x '../x' 'a b' 'gate.1'; do run VT run "$a" --timeout 5 -- /usr/bin/true; need "id '$a' is refused (exit 2)" [ "$RC" = 2 ]; done
  for a in 0 abc -5 5s 1.5 0123 9999999999; do run VT run gate-1 --timeout "$a" -- /usr/bin/true; need "timeout '$a' is refused (exit 2)" [ "$RC" = 2 ]; done
  run VT run gate-1 --timeout 5 --issue x -- /usr/bin/true; need "a non-numeric issue is refused" [ "$RC" = 2 ]
  run VT run gate-1 --timeout 5 --stage 'A B' -- /usr/bin/true; need "a stage with a space is refused" [ "$RC" = 2 ]
  run VT run gate-1 --timeout 5; need "no command: exit 2" [ "$RC" = 2 ]
  run VT run gate-1 --timeout 5 -- ; need "an empty command: exit 2" [ "$RC" = 2 ]
  run VT run gate-1 --timeout 5 /usr/bin/true; need "a command without -- is refused" [ "$RC" = 2 ]
  run VT run gate-1 --timeout; need "an option without its value: exit 2" [ "$RC" = 2 ]
  run VT run; need "no arguments: exit 2" [ "$RC" = 2 ]
  CLAUDE_SESSION_ID='a b' run VT run gate-1 --timeout 5 -- /usr/bin/true; need "a session id that is not a plain token is refused" [ "$RC" = 2 ]
  need "none of them reached the daemon" [ "$(launches)" = 0 ]
}
t_run_basic() {
  local j key
  mkjobs
  OPENROUTER_API_KEY=sk-live-RUNLEAK-1234 run VT run gate-1 --timeout 30 --issue 7 --stage review -- /bin/sh -c "echo ran >> '$E/runs'"
  need "run exits 0" [ "$RC" = 0 ]; j=$OUT
  need "...printing the job id and nothing else" grep -qE '^job_[0-9a-f]+$' <<<"$j"
  key="velo_$(s8 "$SID")_gate-1"
  need "the start carries the name, the deadline and the idempotency key" grep -qF -e "--name gate-1 --timeout 30 --idempotency-key $key " "$E_CALLS"
  need "...the tags velo, session, issue and stage" grep -qF -e '--tag velo --tag session:sess-abc123 --tag issue:7 --tag stage:review' "$E_CALLS"
  need "...the working directory" grep -qF -e "--cwd $(pwd -P) " "$E_CALLS"
  need "the job ran once" [ "$(wc -l < "$E/runs" | tr -d ' ')" = 1 ]
  need "the row Vanth keeps carries the name and the tags" [ "$(sql 'SELECT name, tags_json FROM jobs WHERE job_id = ?' "$j")" = 'gate-1 ["velo", "session:sess-abc123", "issue:7", "stage:review"]' ]
  need "the start call saw only Vanth's own environment, not the caller's secret" \
    grep -qx 'env=AGENT_BG_HOME HOME PATH VANTH_DAEMON_PORT VANTH_HOME' <(grep -A1 '^vanth --json start' "$E_CALLS")
  run VT run gate-2 --timeout 30 -- /usr/bin/true; need "without --issue and --stage, no such tags" not grep -qE 'tag (issue|stage):' <(grep -A0 'gate-2' "$E_CALLS")
  run VT run gate-fail --timeout 30 -- /bin/sh -c 'exit 3'
  need "a job that fails at once still prints its id and exits 0: it was started" [ "$RC" = 0 -a "${OUT#job_}" != "$OUT" ]
}
t_run_dedup() {  # B10, B-R3: the same id from the same session is one job
  local j1 j2 k
  mkjobs
  run VT run gate-1 --timeout 30 -- /bin/sh -c "echo ran >> '$E/runs'"; j1=$OUT
  run VT run gate-1 --timeout 30 -- /bin/sh -c "echo ran >> '$E/runs'"; j2=$OUT
  need "the second run exits 0" [ "$RC" = 0 ]
  need "...and returns the same job id" [ "$j1" = "$j2" ]
  need "...without a second execution" [ "$(wc -l < "$E/runs" | tr -d ' ')" = 1 ]
  need "...and there is one job row" [ "$(sql 'SELECT count(*) FROM jobs WHERE name = ?' gate-1)" = 1 ]
  k=$(sql 'SELECT idempotency_key FROM local_start_requests'); need "the key Vanth recorded is velo_<session hash>_<id>" [ "$k" = "velo_$(s8 "$SID")_gate-1" ]
  run VT run gate-1 --timeout 30 -- /usr/bin/true; need "the same id with other settings: exit 5" [ "$RC" = 5 ]; need "...naming the conflict and --rerun" grep -q 'IDEMPOTENCY_CONFLICT.*--rerun' <<<"$OUT"
  CLAUDE_SESSION_ID=other-session run VT run gate-1 --timeout 30 -- /bin/sh -c "echo ran >> '$E/runs'"
  need "another session starting the same id gets its own job" [ "$RC" = 0 -a "$OUT" != "$j1" ]
  sql 'DELETE FROM jobs WHERE job_id = ?' "$j1" >/dev/null
  run VT run gate-1 --timeout 30 -- /bin/sh -c "echo ran >> '$E/runs'"; need "the key of a cleaned job: exit 5" [ "$RC" = 5 ]
}
t_run_rerun() {  # B-R2: --rerun is a second job, and the id means the newest
  local j1 j2
  mkjobs
  run VT run gate-1 --timeout 30 -- /bin/sh -c 'exit 3'; j1=$OUT
  run VT run gate-1 --timeout 30 --rerun -- /usr/bin/true; j2=$OUT
  need "--rerun starts a second job" [ "$RC" = 0 -a "$j1" != "$j2" ]
  need "...whose key is the first's plus epoch, pid and a random suffix" grep -qE "idempotency-key velo_$(s8 "$SID")_gate-1_[0-9]+_[0-9]+_[0-9a-f]{8} " "$E_CALLS"
  need "...and both rows are there" [ "$(sql 'SELECT count(*) FROM jobs WHERE name = ?' gate-1)" = 2 ]
  run VT status gate-1; need "the id resolves to the newest job (the passing rerun, not the failed first)" [ "$OUT" = "gate-1 ok" ]
  run VT status --job "$j1"; need "the first job is still addressable by its id" [ "$OUT" = "$j1 failed(3)" ]
}
t_run_failures() {
  mkjobs
  : > "$E/start-transport-error"; run VT run gate-1 --timeout 30 -- /usr/bin/true
  need "a daemon that cannot be reached: exit 6" [ "$RC" = 6 ]; need "...with the restart hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
  rm "$E/start-transport-error"; : > "$E/start-fail"; run VT run gate-1 --timeout 30 -- /usr/bin/true
  need "a start Vanth refuses: exit 1" [ "$RC" = 1 ]; need "...saying that re-running is idempotent" grep -q 'idempotent' <<<"$OUT"
  rm "$E/start-fail"
}
t_resolve_exact() {  # B-R1: the id is an exact name; 1,100 newer jobs whose names merely contain it do not hide it
  local j
  mkjobs
  run VT run gate-1 --timeout 30 -- /usr/bin/true; j=$OUT
  VANTH_HOME="$E_VH" "$E_VENV/bin/vanth" __bulk 1100 gate-1x >/dev/null
  need "precondition: 1,100 newer jobs, all with names that contain the id" [ "$(sql "SELECT count(*) FROM jobs WHERE name LIKE 'gate-1%' AND name != 'gate-1'")" = 1100 ]
  run VT status gate-1; need "the exact name resolves although 1,100 newer jobs contain it" [ "$RC" = 0 -a "$OUT" = "gate-1 ok" ]
  run VT status --job "$j"; need "--job addresses the job directly" [ "$OUT" = "$j ok" ]
  run VT status gate-; need "a prefix of a name is no id (exit 2)" [ "$RC" = 2 ]; need "...saying the id is unknown" grep -q "unknown id 'gate-'" <<<"$OUT"
  run VT status nobody-here; need "an unknown id exits 2" [ "$RC" = 2 ]
  run VT status --job job_nope; need "an unknown job id exits 2" [ "$RC" = 2 ]
  run VT status; need "no id: exit 2" [ "$RC" = 2 ]
  run VT status gate-1 extra; need "two ids: exit 2" [ "$RC" = 2 ]
  run VT status gate-1 --job "$j"; need "an id and --job: exit 2" [ "$RC" = 2 ]
  run VT status Bad_Id; need "an invalid id: exit 2" [ "$RC" = 2 ]
}
VERDICT_ROWS='in-flight|{"status":"queued"}
in-flight|{"status":"launching"}
in-flight|{"status":"running"}
in-flight|{"status":"paused"}
in-flight|{"status":"retrying"}
in-flight|{"status":"stopping"}
ok|{"status":"completed","exit_code":0}
failed(7)|{"status":"failed","exit_code":7}
timeout|{"status":"timeout"}
killed|{"status":"cancelled","stop_actor":"user","stop_reason":"stop requested"}
lost|{"status":"cancelled","stop_actor":"timeout"}
lost|{"status":"orphaned"}
lost|{"status":"mystery"}
lost|{"status":"failed"}
in-flight|{"status":"failed","exit_code":1,"policy_state_json":{"restart_after":"2099-01-01T00:00:00Z"}}'
t_status_verdicts() {  # B1, B18, B26: the closed set, through the whole path: a row in Vanth's database, `vanth status`, the mapping
  local n=0 want json j
  mkjobs
  while IFS='|' read -r want json; do
    n=$((n + 1)); json="${json%\}}"; json="$json,\"name\":\"v-$n\"}"; j=$(inject "$json")
    run VT status "v-$n"; need "$json is $want (exit 0)" [ "$RC" = 0 -a "$OUT" = "v-$n $want" ]
  done <<<"$VERDICT_ROWS"
}
t_status_daemon() {
  mkjobs; inject '{"name":"gate-1","status":"completed","exit_code":0}' >/dev/null
  : > "$E/status-transport-error"; run VT status gate-1
  need "a daemon that cannot be reached: exit 6" [ "$RC" = 6 ]; need "...no verdict printed" not grep -qE 'gate-1 (ok|lost)' <<<"$OUT"; need "...the restart hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
  rm "$E/status-transport-error"; : > "$E/status-fail"; run VT status gate-1; need "a status call that fails: exit 1" [ "$RC" = 1 ]; rm "$E/status-fail"
  : > "$E/status-garbage"; run VT status gate-1; need "a status that is not JSON: exit 6, never a verdict" [ "$RC" = 6 ]; rm "$E/status-garbage"
  kill "$(daemon_pid)"; waitfor 5 not alive "$(daemon_pid)"; : > "$E/fail-launch"
  run VT status gate-1; need "a daemon that is down and cannot start: exit 6" [ "$RC" = 6 ]; need "...the restart hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
  rm "$E/fail-launch"; run VT status gate-1; need "control: a daemon that can start is started, and the verdict read" [ "$OUT" = "gate-1 ok" ]
}
t_status_transient_retry() {  # B-RT1..B-RT4: the daemon loses ~1% of concurrent status calls to `failed to reach daemon`; that answer, and only that one, is re-tried, at most 10 times
  local before t0 t1 calls='^vanth --json status job'
  mkjobs; inject '{"name":"r-ok","status":"completed","exit_code":0}' >/dev/null
  printf '3\n' > "$E/status-transient-error"
  before=$(grep -c "$calls" "$E_CALLS")
  run VT status r-ok
  need "B-RT1: three transient refusals then the answer: exit 0 with the verdict" [ "$RC" = 0 -a "$OUT" = "r-ok ok" ]
  need "...after exactly 4 calls" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 4 ]
  rm "$E/status-transient-error"
  : > "$E/status-transport-error"; before=$(grep -c "$calls" "$E_CALLS")
  run VT status r-ok
  need "B-RT2: a daemon that never answers: exit 6, as today" [ "$RC" = 6 ]
  need "...after exactly 11 calls (one, then ten re-runs)" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 11 ]
  need "...saying after 11 attempts" grep -q 'after 11 attempts' <<<"$OUT"
  need "...and keeping the restart hint" grep -q 'velo-task restart-daemon' <<<"$OUT"
  rm "$E/status-transport-error"
  : > "$E/status-unknown"; before=$(grep -c "$calls" "$E_CALLS")
  run VT status r-ok
  need "B-RT3: another error (unknown job): exit 2" [ "$RC" = 2 ]
  need "...and no re-try: one call" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 1 ]
  rm "$E/status-unknown"
  : > "$E/status-fail"; before=$(grep -c "$calls" "$E_CALLS")
  run VT status r-ok
  need "B-RT3: a plain daemon error: exit 1" [ "$RC" = 1 ]
  need "...and no re-try: one call" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 1 ]
  rm "$E/status-fail"
  printf '3\n' > "$E/status-transient-error"; t0=$(now)   # VELO_TASK_RETRY_SLEEP unset: the default pause is the one that runs
  run /usr/bin/env -u VELO_TASK_RETRY_SLEEP "$R/bin/velo-task" status r-ok
  t1=$(now)
  need "B-RT1: with no VELO_TASK_RETRY_SLEEP the default pause re-tries to the answer" [ "$RC" = 0 -a "$OUT" = "r-ok ok" ]
  need "...and the default is 0.2s: three re-runs take at least 0.6s" between 0.6 "$t0" "$t1" 30
  rm "$E/status-transient-error"
  before=$(grep -c "$calls" "$E_CALLS"); t0=$(now)   # a 5s pause in the environment: one that is never taken proves the first call is not delayed
  VELO_TASK_RETRY_SLEEP=5 run VT status r-ok
  t1=$(now)
  need "B-RT4: a first call that answers: exit 0 with the verdict" [ "$RC" = 0 -a "$OUT" = "r-ok ok" ]
  need "...exactly one call" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 1 ]
  need "...and no pause at all" between 0 "$t0" "$t1" 3
}
t_status_success_not_retried() {  # B-RT5: a status that exits 0 is the answer, whatever its output says: its command field can hold the transient text, and it is answered at once, by one call
  local before calls='^vanth --json status job'
  mkjobs; inject '{"name":"r-cmd","status":"completed","exit_code":0,"command":"echo vanth: failed to reach daemon"}' >/dev/null
  before=$(grep -c "$calls" "$E_CALLS")
  run VT status r-cmd
  need "B-RT5: a status that exits 0 whose command field holds the transient text: exit 0 with the verdict" [ "$RC" = 0 -a "$OUT" = "r-cmd ok" ]
  need "...after exactly 1 call" [ "$(( $(grep -c "$calls" "$E_CALLS") - before ))" = 1 ]
}
t_retry_sleep_validation() {  # B-RT6: VELO_TASK_RETRY_SLEEP is a whole number of seconds, or digits, one dot, digits; any other value is refused when the library loads (exit 2)
  local v
  mkjobs; inject '{"name":"r-ok","status":"completed","exit_code":0}' >/dev/null
  for v in '1.2.3' '.' '1..2' '..' '.5' '5.'; do
    VELO_TASK_RETRY_SLEEP="$v" run VT status r-ok
    need "B-RT6: a re-try pause of '$v' is refused (exit 2)" [ "$RC" = 2 ]
    need "...naming the setting" grep -q 'VELO_TASK_RETRY_SLEEP must be a number of seconds' <<<"$OUT"
  done
  for v in '0' '0.2' '1'; do
    VELO_TASK_RETRY_SLEEP="$v" run VT status r-ok
    need "B-RT6: a re-try pause of '$v' is accepted: exit 0 with the verdict" [ "$RC" = 0 -a "$OUT" = "r-ok ok" ]
  done
}
t_poll_validation() {  # B-RT7: VELO_TASK_POLL is a whole number of seconds, or digits, one dot, digits; any other value is refused when the library loads (exit 2). The accepted values reach /bin/sleep: the wait runs to its own timeout
  local v
  mkjobs; inject '{"name":"r-run","status":"running"}' >/dev/null
  for v in '1.2.3' '.' '1..2' '..' '.5' '5.'; do
    VELO_TASK_POLL="$v" run VT wait r-run --timeout 1
    need "B-RT7: a poll interval of '$v' is refused (exit 2)" [ "$RC" = 2 ]
    need "...naming the setting" grep -q 'VELO_TASK_POLL must be a number of seconds' <<<"$OUT"
  done
  for v in '0.5' '1' '0'; do
    VELO_TASK_POLL="$v" run VT wait r-run --timeout 1
    need "B-RT7: a poll interval of '$v' is accepted: the wait runs to its timeout (exit 3)" [ "$RC" = 3 ]
    need "...with no refusal and no sleep usage error" not grep -qE 'must be a number|usage: sleep' <<<"$OUT"
  done
}
t_wait() {  # B4, B5, B15, B6
  local j n
  mkjobs
  inject '{"name":"w-ok","status":"completed","exit_code":0}' >/dev/null; inject '{"name":"w-bad","status":"failed","exit_code":2}' >/dev/null
  inject '{"name":"w-run","status":"running"}' >/dev/null; inject '{"name":"w-lost","status":"orphaned"}' >/dev/null
  run VT wait w-ok; need "wait on an ok job: exit 0" [ "$RC" = 0 -a "$OUT" = "w-ok ok" ]
  run VT wait w-bad; need "a failed job: its verdict, exit 1" [ "$RC" = 1 -a "$OUT" = "w-bad failed(2)" ]
  run VT wait w-lost; need "a lost job: exit 1" [ "$RC" = 1 -a "$OUT" = "w-lost lost" ]
  run VT wait w-ok w-bad; need "--all (the default) prints one line per id, in the order given, and exits 1 if any is not ok" [ "$RC" = 1 -a "$OUT" = "$(printf 'w-ok ok\nw-bad failed(2)')" ]
  run VT wait w-ok w-ok; need "...two ok ids: exit 0" [ "$RC" = 0 ]
  run VT wait --any --timeout 20 w-run w-ok; need "--any returns the first finished one" [ "$RC" = 0 ]; need "...printing only it" grep -qx 'w-ok ok' <<<"$OUT"
  need "...and names the other as still in flight" grep -q 'w-run is still in flight' <<<"$OUT"
  run VT wait --any --timeout 20 w-bad w-ok; need "--any with a failed winner: exit 1" [ "$RC" = 1 ]
  run VT wait --timeout 1 w-run; need "a job that stays in flight: exit 3 at the deadline" [ "$RC" = 3 ]; need "...naming it" grep -q 'still in flight: w-run' <<<"$OUT"
  run VT wait --timeout 1 w-ok w-run; need "--all with one in flight: exit 3, and the finished verdict is not printed alone" [ "$RC" = 3 ]; need "...naming only the one in flight" grep -q 'still in flight: w-run$' <<<"$OUT"
  n=$(grep -c '^vanth --json status job' "$E_CALLS")
  run VT wait w-ok nobody-here; need "an unknown id among known ones: exit 2" [ "$RC" = 2 ]
  need "...before anything was polled" [ "$(grep -c '^vanth --json status job' "$E_CALLS")" = "$n" ]
  run VT wait; need "no id: exit 2" [ "$RC" = 2 ]
  run VT wait --bogus w-ok; need "an unknown option: exit 2" [ "$RC" = 2 ]
  run VT wait --timeout 0 w-ok; need "a bad timeout: exit 2" [ "$RC" = 2 ]
  j=$(sql 'SELECT job_id FROM jobs WHERE name = ?' w-run)
  ( sleep 0.6; sql "UPDATE jobs SET status = 'completed', exit_code = 0 WHERE job_id = ?" "$j" >/dev/null ) &
  run VT wait --timeout 20 w-run; need "wait returns once the job finishes" [ "$RC" = 0 -a "$OUT" = "w-run ok" ]
  wait $! 2>/dev/null; true
}
t_cancel() {
  local j n
  mkjobs; j=$(inject '{"name":"c-run","status":"running"}')
  run VT cancel c-run; need "cancel of a running job: killed, exit 0" [ "$RC" = 0 -a "$OUT" = "c-run killed" ]
  need "...through vanth stop" grep -q "^vanth --json stop $j" "$E_CALLS"
  need "...and the row says cancelled by the user" [ "$(sql 'SELECT status, stop_actor FROM jobs WHERE job_id = ?' "$j")" = "cancelled user" ]
  run VT cancel c-run; need "cancel again: still killed, exit 0" [ "$RC" = 0 -a "$OUT" = "c-run killed" ]
  inject '{"name":"c-done","status":"completed","exit_code":0}' >/dev/null
  n=$(grep -c '^vanth --json stop' "$E_CALLS")
  run VT cancel c-done; need "cancel of a finished job exits 4" [ "$RC" = 4 ]
  need "...printing no 'ok' on stdout, as if it had been cancelled" not grep -qx 'c-done ok' <(VT cancel c-done 2>/dev/null)
  need "...its real verdict on stderr" grep -q 'c-done ok' <<<"$OUT"; need "...naming already-terminal" grep -q 'already-terminal' <<<"$OUT"
  need "...and never calling vanth stop" [ "$(grep -c '^vanth --json stop' "$E_CALLS")" = "$n" ]
  inject '{"name":"c-bad","status":"failed","exit_code":3}' >/dev/null; run VT cancel c-bad; need "a failed job: exit 4" [ "$RC" = 4 ]; need "...its verdict named" grep -q 'failed(3)' <<<"$OUT"
  j=$(inject '{"name":"c-two","status":"queued"}'); run VT cancel --job "$j"; need "cancel --job works" [ "$OUT" = "$j killed" ]
  run VT cancel nobody-here; need "cancel of an unknown id: exit 2" [ "$RC" = 2 ]
  run VT cancel; need "no id: exit 2" [ "$RC" = 2 ]
}
t_vanished_job() {  # a job that is gone from Vanth after the id resolved: exit 2, no verdict line, in status, wait and cancel
  local c
  mkjobs; inject '{"name":"v-gone","status":"completed","exit_code":0}' >/dev/null
  : > "$E/status-unknown"
  for c in status wait cancel; do
    run VT $c v-gone; need "$c: exit 2" [ "$RC" = 2 ]; need "$c: no verdict line" not grep -qE 'v-gone (ok|lost|unknown-job)' <<<"$OUT"
    need "$c: says the job is unknown to Vanth" grep -q 'unknown to Vanth' <<<"$OUT"
  done
}
t_session() {
  local t
  mkjobs; unset CLAUDE_SESSION_ID
  run VT run gate-1 --timeout 30 -- /usr/bin/true; need "without CLAUDE_SESSION_ID run still works" [ "$RC" = 0 ]
  t=$(cat "$E_HOME/session"); need "...with a token the state dir keeps" grep -qE '^[0-9a-f]{16}$' <<<"$t"
  need "...private" [ "$(mode_of "$E_HOME/session")" = 600 ]
  need "...and the jobs are tagged with it" [ "$(sql 'SELECT tags_json FROM jobs WHERE name = ?' gate-1)" = "[\"velo\", \"session:$t\"]" ]
  run VT run gate-1 --timeout 30 -- /usr/bin/true; need "the same token again is the same job" [ "$RC" = 0 ]
  rm "$E_HOME/session"; ln -s "$E/target" "$E_HOME/session"; printf 'abcdef\n' > "$E/target"
  run VT run gate-9 --timeout 30 -- /usr/bin/true; need "a token file that is a symlink is refused (exit 6)" [ "$RC" = 6 ]
}

# ---- the Stop guard and SessionStart ------------------------------------------------------------------
guard() { run /bin/bash "$R/hooks/velo-task-stop-guard.sh" </dev/null; }
sstart() { run /bin/bash "$R/hooks/velo-task-session-start.sh" </dev/null; }
tag_row() {  # <name> <status> <session>
  inject "{\"name\":\"$1\",\"status\":\"$2\",\"tags_json\":[\"velo\",\"session:$3\"]}"
}
t_stop_guard() {  # B-S: this session's in-flight jobs block; nothing else does
  local s p
  mkjobs
  guard; need "no job at all: allow" [ "$RC" = 0 ]
  for s in queued launching running paused retrying stopping; do
    tag_row "g-$s" "$s" "$SID" >/dev/null; guard
    need "a job of this session in '$s' blocks (exit 2)" [ "$RC" = 2 ]
    need "...naming it and the command that clears it" grep -q "g-$s .*velo-task wait g-$s" <<<"$OUT"
    sql 'DELETE FROM jobs' >/dev/null
  done
  tag_row g-other running other-session >/dev/null; guard; need "another session's job never blocks" [ "$RC" = 0 ]
  tag_row g-done completed "$SID" >/dev/null; tag_row g-lost orphaned "$SID" >/dev/null; tag_row g-failed failed "$SID" >/dev/null
  guard; need "a finished, failed or lost job of this session does not block" [ "$RC" = 0 ]
  tag_row g-run running "$SID" >/dev/null; kill "$(daemon_pid)"; waitfor 5 not alive "$(daemon_pid)"
  guard; need "with the daemon down the guard still reads Vanth's file and blocks" [ "$RC" = 2 ]
  sql 'DELETE FROM jobs' >/dev/null; tag_row g-sup running "${SID}-2" >/dev/null; guard
  need "a job of session '$SID-2' does not block session '$SID'" [ "$RC" = 0 ]
  p="$E_VH/jobs.sqlite"; cp "$p" "$E/jobs.good"
  printf 'not a database, just text\n' > "$p"; guard; need "an unreadable database blocks (fails closed)" [ "$RC" = 2 ]
  need "...naming the way out" grep -q 'velo-task stop-override --reason' <<<"$OUT"
  mkdb "$E/other.sqlite" created_at; cp "$E/other.sqlite" "$p"; guard; need "a database of another schema blocks" [ "$RC" = 2 ]
  cp "$E/jobs.good" "$p"
  "$PYBIN" -I -c 'import sqlite3, sys, time; c = sqlite3.connect(sys.argv[1], isolation_level=None); c.execute("BEGIN EXCLUSIVE"); open(sys.argv[2], "w").close(); time.sleep(7)' "$p" "$E/held" &
  waitfor 5 test -e "$E/held" || { echo "FAILED: the lock was never taken"; exit 1; }
  guard; need "a database locked for more than 2 s blocks" [ "$RC" = 2 ]; wait $! 2>/dev/null; true
  cp "$E/jobs.good" "$p"
  rm -f "$p"; guard; need "a missing database under an existing Vanth home blocks" [ "$RC" = 2 ]; need "...naming the way out" grep -q 'stop-override --reason' <<<"$OUT"
  ln -s "$E/nowhere.sqlite" "$p"; guard; need "a dangling jobs.sqlite blocks" [ "$RC" = 2 ]; rm -f "$p"; cp "$E/jobs.good" "$p"
  inject "{\"name\":\"g-restart\",\"status\":\"failed\",\"exit_code\":1,\"policy_state_json\":{\"restart_after\":\"2099-01-01T00:00:00Z\"},\"tags_json\":[\"velo\",\"session:$SID\"]}" >/dev/null
  guard; need "a failed job of this session with a restart pending blocks, as status calls it in-flight" [ "$RC" = 2 ]
  need "...naming it" grep -q 'g-restart' <<<"$OUT"
  sql 'DELETE FROM jobs' >/dev/null
  tag_row g-run2 running "$SID" >/dev/null
  PATH=/nonexistent run /bin/bash "$R/hooks/velo-task-stop-guard.sh" </dev/null; need "a broken PATH does not turn the guard off: still blocks" [ "$RC" = 2 ]
  need "...for the job, not for a missing tool" grep -q 'g-run2' <<<"$OUT"
  run /usr/bin/env -i /bin/bash "$R/hooks/velo-task-stop-guard.sh" </dev/null; need "no HOME and no state variables: blocks, cannot locate the state dir" [ "$RC" = 2 ]
  mkdir -p "$E/corrupt/hooks" "$E/corrupt/bin"; cp "$R/hooks/velo-task-stop-guard.sh" "$E/corrupt/hooks/"
  printf 'exit 0\n' > "$E/corrupt/bin/velo-task-lib.sh"
  run /bin/bash "$E/corrupt/hooks/velo-task-stop-guard.sh" </dev/null; need "a readable library that calls exit 0 does not release the guard" [ "$RC" = 2 ]
  printf ':\n' > "$E/corrupt/bin/velo-task-lib.sh"
  run /bin/bash "$E/corrupt/hooks/velo-task-stop-guard.sh" </dev/null; need "a library that loads but defines nothing blocks" [ "$RC" = 2 ]
  sql 'DELETE FROM jobs' >/dev/null
  mkdir -p "$E/hookonly/hooks"; cp "$R/hooks/velo-task-stop-guard.sh" "$E/hookonly/hooks/"
  run /bin/bash "$E/hookonly/hooks/velo-task-stop-guard.sh" </dev/null; need "a missing library blocks while a Vanth home exists" [ "$RC" = 2 ]
  need "...naming the way out" grep -q 'stop-override' <<<"$OUT"
  VELO_TASK_HOME="$E/no-such-home" run /bin/bash "$E/hookonly/hooks/velo-task-stop-guard.sh" </dev/null; need "...and allows when there is no Vanth home at all" [ "$RC" = 0 ]
  VELO_TASK_HOME="$E/no-such-home" guard; need "no Vanth home: allow" [ "$RC" = 0 ]
}
t_stop_override() {  # one Stop, audited, and the block is back
  mkjobs; tag_row o-run running "$SID" >/dev/null
  guard; need "(setup) blocked" [ "$RC" = 2 ]
  run VT stop-override --reason 'closing the laptop'; need "stop-override is recorded" [ "$RC" = 0 ]
  guard; need "the next Stop is allowed" [ "$RC" = 0 ]; need "...saying the override was used" grep -q 'stop-override used' <<<"$OUT"
  guard; need "...once: the one after is blocked again" [ "$RC" = 2 ]
  need "the audit log has the reason and the use" [ "$(grep -c -e 'closing the laptop' -e '^used' "$E_HOME/overrides.log")" = 2 ]
  run VT stop-override; need "no reason: exit 2" [ "$RC" = 2 ]
  run VT stop-override --reason; need "an empty reason: exit 2" [ "$RC" = 2 ]
  ln -s "$E/target" "$E_HOME/stop-override"; guard; need "a symlink in the override's place does not release the block" [ "$RC" = 2 ]
  rm "$E_HOME/stop-override"; : > "$E_HOME/stop-override"; chmod 600 "$E_HOME/stop-override"; guard
  need "an empty override file does not release the block" [ "$RC" = 2 ]; need "...and is not consumed" [ -e "$E_HOME/stop-override" ]
  printf 'half a line' > "$E_HOME/stop-override"; guard; need "a partial override does not release it" [ "$RC" = 2 -a -e "$E_HOME/stop-override" ]
  run VT stop-override --reason 'after a corrupt one'; need "stop-override replaces the corrupt file (exit 0)" [ "$RC" = 0 ]
  guard; need "...and then the Stop is allowed once" [ "$RC" = 0 ]
  ln -s "$E/target" "$E_HOME/stop-override"; run VT stop-override --reason 'over a stale link'; need "stop-override works over a stale symlink" [ "$RC" = 0 ]
  guard; need "...and releases once" [ "$RC" = 0 ]
}
t_tags_json() {  # the guard reads tags_json as JSON: an array of strings, exact membership; anything else fails and so blocks
  local t
  mkjobs
  inject "{\"name\":\"t-esc\",\"status\":\"running\",\"tags_json\":\"[\\\"velo\\\",\\\"session\\\\u003a$SID\\\"]\"}" >/dev/null
  need "(setup) the tag is the JSON escape of session:$SID" [ "$(sql 'SELECT count(*) FROM jobs WHERE tags_json LIKE ?' '%u003a%')" = 1 ]
  guard; need "a tag written with a JSON escape still tags the session: blocks" [ "$RC" = 2 ]; need "...naming the job" grep -q 't-esc' <<<"$OUT"
  sql 'DELETE FROM jobs' >/dev/null
  for t in 'not json' '{"a":"session:'"$SID"'"}' '["velo",3]' '"session:'"$SID"'"' '' 'null'; do
    inject "{\"name\":\"t-bad\",\"status\":\"running\",\"tags_json\":$("$PYBIN" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$t")}" >/dev/null
    guard; need "tags_json '$t' on an in-flight job: the helper fails, the guard blocks" [ "$RC" = 2 ]
    sql 'DELETE FROM jobs' >/dev/null
  done
  inject '{"name":"t-fin","status":"completed","exit_code":0,"tags_json":"not json"}' >/dev/null
  guard; need "malformed tags on a job that is not in flight do not matter" [ "$RC" = 0 ]
  inject '{"name":"t-note","status":"running","tags_json":["velo","note: \"session:'"$SID"'\""]}' >/dev/null
  guard; need "a tag that merely contains the session text is not the session's tag" [ "$RC" = 0 ]
  sstart; need "SessionStart counts it as another session's" grep -qx 'other sessions: 1 in flight' <<<"$OUT"
}
t_session_file() {  # the fallback session token is read only if it is exactly what velo-task made
  local h f tok=0123456789abcdef
  mkjobs; unset CLAUDE_SESSION_ID; h=$E_HOME; f=$h/session
  run VT run gate-1 --timeout 30 -- /usr/bin/true; need "(setup) a token is made on first use" [ "$RC" = 0 ]
  run ST session-read "$h"; need "the generated token is read" [ "$RC" = 0 ] && [ "${#OUT}" = 16 ]
  need "...as the file holds it" [ "$OUT" = "$(cat "$f")" ]
  tag_row s-mine running "$(cat "$f")" >/dev/null; guard; need "the guard blocks on the job of that token" [ "$RC" = 2 ]; sql 'DELETE FROM jobs' >/dev/null
  cp "$f" "$E/good-token"
  chmod 644 "$f"; run ST session-read "$h"; need "a token file open to group or other is refused" [ "$RC" = 1 ]; guard; need "...and the guard blocks" [ "$RC" = 2 ]
  run VT run gate-2 --timeout 30 -- /usr/bin/true; need "...and velo-task refuses to use it (exit 6)" [ "$RC" = 6 ]; chmod 600 "$f"
  printf '%s\n' "$tok" > "$f"; run ST session-read "$h"; need "a token with a trailing newline is not the generated format" [ "$RC" = 1 ]
  printf 'ABCDEF0123456789' > "$f"; run ST session-read "$h"; need "an upper-case token is refused" [ "$RC" = 1 ]
  printf '%s' "$tok" > "$f"; run ST session-read "$h"; need "control: another well-formed private token is read" [ "$RC" = 0 -a "$OUT" = "$tok" ]
  rm "$f"; ln -s "$E/good-token" "$f"; run ST session-read "$h"; need "a symlink to a well-formed token is refused" [ "$RC" = 1 ]; guard; need "...and the guard blocks" [ "$RC" = 2 ]
  rm "$f"; cp "$E/good-token" "$f"; chmod 600 "$f"; chmod 755 "$h"; run ST session-read "$h"; need "a state dir open to group or other is refused" [ "$RC" = 1 ]; chmod 700 "$h"
  run ST session-read "$h"; need "control: restored, the token is read again" [ "$RC" = 0 ]
  mkdir "$h/session.d"; rm "$f"; mkdir "$f"; run ST session-read "$h"; need "a directory is refused" [ "$RC" = 1 ]; rmdir "$f"
  run ST session-read "$E/no-such-dir"; need "a missing state dir is refused" [ "$RC" = 1 ]
  printf '%s' "$tok" > "$f"; chmod 600 "$f"; ln -s "$h" "$E/homelink"; run ST session-read "$E/homelink"; need "a symlinked state dir is refused" [ "$RC" = 1 ]
}
t_vanth_paths() {  # every path the guard and the hooks trust: absent allows, anything else that is not a private real object blocks
  local d p
  mkjobs; tag_row p-run running "$SID" >/dev/null; p=$E_VH/jobs.sqlite
  cp "$p" "$E/decoy.sqlite"; chmod 600 "$E/decoy.sqlite"
  sql 'DELETE FROM jobs' >/dev/null; cp "$p" "$E/empty.sqlite"; chmod 600 "$E/empty.sqlite"   # a decoy with no rows
  tag_row p-run running "$SID" >/dev/null
  guard; need "(setup) the real database holds an in-flight job: blocks" [ "$RC" = 2 ]
  rm "$p"; ln -s "$E/empty.sqlite" "$p"; guard; need "jobs.sqlite as a symlink to a decoy with no rows blocks, it does not allow" [ "$RC" = 2 ]
  sstart; need "SessionStart says the database cannot be read" grep -q 'cannot be read' <<<"$OUT"
  run VT status p-run; need "status resolves nothing through it (exit 6)" [ "$RC" = 6 ]
  rm "$p"; ln -s "$E/nowhere.sqlite" "$p"; run VT status p-run; need "a dangling jobs.sqlite is an error for status (exit 6), not 'unknown id'" [ "$RC" = 6 ]
  rm "$p"; cp "$E/empty.sqlite" "$p"; chmod 644 "$p"; guard; need "a jobs.sqlite open to group or other blocks" [ "$RC" = 2 ]; run VT status p-run; need "...and status will not read it (exit 6)" [ "$RC" = 6 ]; rm "$p"; cp "$E/decoy.sqlite" "$p"; chmod 600 "$p"
  guard; need "control: private again, the in-flight job blocks by name" [ "$RC" = 2 ]
  mv "$E_VH" "$E/vh.real"; ln -s /nonexistent/vanth-home "$E_VH"
  guard; need "a dangling symlink where the Vanth home should be blocks" [ "$RC" = 2 ]
  sstart; need "SessionStart is not silent about it" [ -n "$OUT" ]
  rm "$E_VH"; : > "$E_VH"; guard; need "a regular file where the Vanth home should be blocks" [ "$RC" = 2 ]
  sstart; need "SessionStart is not silent about a file either" [ -n "$OUT" ]
  rm "$E_VH"; ln -s "$E/vh.real" "$E_VH"; guard; need "a symlink to the real Vanth home blocks" [ "$RC" = 2 ]
  run VT ensure-daemon; need "ensure-daemon refuses a symlinked Vanth home (exit 6)" [ "$RC" = 6 ]; need "...saying the home is a symlink" grep -q 'is a symlink' <<<"$OUT"
  rm "$E_VH"; mv "$E/vh.real" "$E_VH"; guard; need "control: restored, the guard blocks on the job" [ "$RC" = 2 ]; need "...naming it" grep -q p-run <<<"$OUT"
  d=$E/state-link; ln -s /nonexistent/state "$d"; VELO_TASK_HOME=$d guard; need "a dangling symlink as the state dir blocks" [ "$RC" = 2 ]
  mkdir "$E/emptystate"; rm "$d"; ln -s "$E/emptystate" "$d"; VELO_TASK_HOME=$d guard; need "a symlink to a directory with no Vanth home blocks too" [ "$RC" = 2 ]
  sstart_at() { VELO_TASK_HOME=$d run /bin/bash "$R/hooks/velo-task-session-start.sh" </dev/null; }
  sstart_at; need "SessionStart is not silent about a symlinked state dir" [ -n "$OUT" ]
  : > "$E/statefile"; VELO_TASK_HOME=$E/statefile guard; need "a regular file as the state dir blocks" [ "$RC" = 2 ]
  VELO_TASK_HOME=$E/absent-state guard; need "control: a state dir that is genuinely absent allows" [ "$RC" = 0 ]
  ln -s "$E_HOME" "$E/homelink"; VELO_TASK_HOME=$E/homelink run VT ensure-daemon; need "need_home refuses a symlinked state root (exit 6)" [ "$RC" = 6 ]; need "...saying the root is a symlink" grep -q 'is a symlink' <<<"$OUT"
}
t_session_start() {
  mkjobs; tag_row s-run running "$SID" >/dev/null; tag_row s-oth running other-1 >/dev/null; tag_row s-oth2 queued other-2 >/dev/null; tag_row s-done completed "$SID" >/dev/null
  sstart; need "SessionStart exits 0" [ "$RC" = 0 ]
  need "it lists this session's job with its wait command" grep -q 's-run .* running: velo-task wait s-run' <<<"$OUT"
  need "...and not a finished one" not grep -q 's-done' <<<"$OUT"
  need "...and not another session's" not grep -q 's-oth ' <<<"$OUT"
  need "...and counts the other sessions' jobs" grep -qx 'other sessions: 2 in flight' <<<"$OUT"
  sql 'DELETE FROM jobs' >/dev/null; sstart; need "with nothing in flight: only the count" [ "$OUT" = 'other sessions: 0 in flight' ]
  rm -f "$E_VH/jobs.sqlite"; sstart; need "a missing database is said so, not 'nothing in flight'" grep -q 'cannot be read' <<<"$OUT"
  printf 'garbage\n' > "$E_VH/jobs.sqlite"; sstart; need "an unreadable database is said so, still exit 0" [ "$RC" = 0 ]; need "...in words" grep -q 'cannot be read' <<<"$OUT"
  VELO_TASK_HOME="$E/no-such-home" sstart; need "no Vanth home: silent, exit 0" [ "$RC" = 0 -a -z "$OUT" ]
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
  sedi -E "s/--hash=sha256:[0-9a-f]+/--hash=sha256:$(printf '%064d' 0)/" "$m/requirements/vanth.lock"
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a lock whose hashes do not match the wheels fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: tampered hashes: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  sedi 's/^vanth==1\.14\.0 /vanth==1.13.0 /' "$m/requirements/vanth.lock"
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a different Vanth version than the locked hashes fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: wrong version: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  rm -rf "$m"; mkdir -p "$m"; cp -R "$R/bin" "$R/requirements" "$m/"
  awk '/^starlette==/ { skip = 1; next } /^[A-Za-z0-9._-]+==/ { skip = 0 } !skip' "$R/requirements/vanth.lock" > "$m/requirements/vanth.lock"
  mkhome; run "$m/bin/velo-task" install-vanth
  need "a lock missing one transitive dependency fails the install" [ "$RC" != 0 ]; need "...and leaves no venv" [ ! -e "$E_VENV" ]
  echo "note: lock without starlette: exit $RC; $(tail -n 1 <<<"$OUT" | cut -c1-150)"
  mkhome; run VT install-vanth; need "install-vanth in a fresh home works again" [ "$RC" = 0 ]
  # The port reservation lets the fake vanthd bind beside it (SO_REUSEPORT); the real vanthd does not set that, so the
  # reservation is released right before it binds. A foreign process that took the port meanwhile fails the start, loudly.
  kill "$E_HOLDER"; wait "$E_HOLDER" 2>/dev/null
  run VT ensure-daemon; need "the real daemon starts" [ "$RC" = 0 ]; need "...as started" grep -q started <<<"$OUT"; echo "note: $OUT"
  p=$(daemon_pid)
  need "VANTH_HOME is 0700" [ "$(mode_of "$E_VH")" = 700 ]
  for f in daemon.json token jobs.sqlite; do need "$f is 0600" [ "$(mode_of "$E_VH/$f")" = 600 ]; done
  need "no file under logs/ or events/ is group- or world-accessible" [ -z "$(loose_files "$E_VH/logs" "$E_VH/events")" ]
  need "the daemon listens on 127.0.0.1 only (lsof)" \
    [ "$("$LSOF" -nP -a -p "$p" -iTCP -sTCP:LISTEN -Fn | grep '^n' | sort -u)" = "n127.0.0.1:$E_PORT" ]
  run VT ensure-daemon; need "the running daemon is adopted" [ "$RC" = 0 ]; need "...as adopted" grep -q adopted <<<"$OUT"
  export CLAUDE_SESSION_ID=net-sess
  run VT run net-ok --timeout 30 -- /bin/sh -c 'exit 0'; need "a real run prints a job id" [ "$RC" = 0 -a "${OUT#job_}" != "$OUT" ]
  run VT wait --timeout 60 net-ok; need "...and wait reports it ok" [ "$RC" = 0 -a "$OUT" = "net-ok ok" ]
  need "...and Vanth tagged it with the session" grep -q 'session:net-sess' <<<"$(VANTH_HOME="$E_VH" "$E_VENV/bin/vanth" --json status "$(VT run net-ok --timeout 30 -- /bin/sh -c 'exit 0')")"
  run VT run net-bad --timeout 30 -- /bin/sh -c 'exit 4'; run VT wait --timeout 60 net-bad; need "a real failing job: failed(4)" [ "$RC" = 1 -a "$OUT" = "net-bad failed(4)" ]
  run VT run net-to --timeout 2 -- /bin/sleep 60; run VT wait --timeout 60 net-to; need "a real job past its deadline: timeout" [ "$OUT" = "net-to timeout" ]
  run VT run net-slow --timeout 120 -- /bin/sleep 100
  run /bin/bash "$R/hooks/velo-task-stop-guard.sh" </dev/null; need "the Stop guard blocks on the real database while it runs" [ "$RC" = 2 ]
  run VT cancel net-slow; need "a real cancel: killed" [ "$RC" = 0 -a "$OUT" = "net-slow killed" ]
  run /bin/bash "$R/hooks/velo-task-stop-guard.sh" </dev/null; need "...and the guard lets go" [ "$RC" = 0 ]
  OPENROUTER_API_KEY=caller-secret run VT restart-daemon; need "restart-daemon replaces the real daemon" [ "$RC" = 0 ]
  pid2=$(daemon_pid); need "...under a new pid" [ "$pid2" != "$p" ]; need "...the old one is gone" not alive "$p"
  envs=$(/bin/ps -ww -E -o command= -p "$pid2" 2>/dev/null)
  need "control: ps -E shows the new daemon's environment" grep -q 'VANTH_RETENTION_SECONDS=0' <<<"$envs"
  need "...which lacks the caller's secret" not grep -q caller-secret <<<"$envs"
  kill "$pid2"; waitfor 10 not alive "$pid2"
}


# ---- run -------------------------------------------------------------------------------------------
echo "velo-task: the state helper"
check "json-get reads values as jq would, and fails loudly on a bad file" t_json_get
check "jobs-ro: read-only, bound parameters, quoted fields, schema and lock refusals" t_jobs_ro
check "B1/B18: the verdict table is closed, and a hostile status is lost, never a traceback" t_verdict_table
check "verdict-of: identity checks, unreadable input, the restart a status object omits" t_verdict_cli
check "launch passes exactly the named variables" t_launch
check "the one-shot override is a regular file of yours, written and consumed once" t_override
echo "velo-task: front end and daemon"
check "no private name is a subcommand; every unknown name exits 2" t_private_subcommands
check "the state root must be 0700" t_state_home
check "B21: the allowlist rejects reserved names, row by row" t_allowlist_rejects
check "B21: whole allowlists, restart-daemon included" t_allowlist_lists
check "B21: only the allowlisted secret reaches the daemon, nowhere else" t_secrets
check "B21: no secret value in an argv of a program velo-task runs through env" t_secret_argv
check "B21: the launch log's contents are never shown" t_launch_log_not_shown
check "B22: a daemon is adopted only by an environment that would launch it the same" t_digest_inherited
check "B22: files are private and the launch is recorded" t_modes_env
check "B22: a daemon velo-task did not provably launch is refused" t_provenance_refusals
check "a daemon.json that cannot be parsed stops the command" t_daemon_json_malformed
check "B22: the start time is compared under another locale and zone" t_locale_fresh_shell
check "B22: loose state is refused, restart included" t_modes_refuse
check "B22: a file left readable by the daemon is caught after the launch" t_modes_after_launch
check "two ensure-daemon at once: one daemon, the other adopts" t_concurrent_ensure
check "restart-daemon replaces the daemon with a clean launch" t_restart
check "restart-daemon replaces a daemon of an older configuration" t_restart_digest_change
check "restart-daemon signals only a process a matching record proves is ours" t_restart_refuses_unproven
check "a daemon that ignores SIGTERM is left alone, no second one started" t_stop_failure
check "a daemon that dies at start: exit 6 and its reason in the log" t_launch_failure
check "a port a foreign process holds fails the launch, signals nobody" t_port_collision
check "the daemon that answers must be the one launched" t_launch_requires_own_pid
check "a daemon that listens beyond loopback is refused" t_loopback
check "the wide-port fixture really holds the port" t_port_reservation
check "ensure-daemon before install-vanth says what to run" t_before_install
check "no tool is looked up on the caller's PATH" t_no_path_tools
check "hostile PYTHONPATH, BASH_ENV, ENV and user site never fire" t_hostile_env
echo "velo-task: install (B23)"
check "B23: install passes --require-hashes --only-binary :all: -r lock, PyPI only, fixed PATH" t_install_flags
check "install-vanth asserts the schema and installed set == lock" t_install_asserts
check "install-vanth is idempotent and rebuilds on a changed lock" t_install_idempotent
check "install-vanth never replaces a venv under a running daemon" t_install_refuses_under_daemon
check "install-vanth keeps the venv under a running daemon" t_install_failure_under_daemon
check "install-vanth rebuilds a venv whose python does not run" t_install_broken_venv
check "B23: a lock with a hash that is not its wheel's fails install-vanth" t_install_hash_tamper
check "B23: the lock is hashed, pinned and WHEELS ONLY (offline artifact-type check)" t_lock_file
check "the lock's pinned set equals the checked-in closure list" t_lock_closure
check "install.sh ships requirements/, the library and the hooks" t_install_ships_lock
echo "velo-task: run, status, wait, cancel"
check "B3/B11: run refuses without --timeout and on a bad id or argument, before the daemon" t_run_validation
check "run: flags, tags, key, one execution, the caller's secrets stay out" t_run_basic
check "B10/B-R3: the same id twice is one job, one execution" t_run_dedup
check "B-R2: --rerun is a second job and the id means the newest" t_run_rerun
check "run: a daemon down is exit 6, a refused start exit 1" t_run_failures
check "B-R1: an id is an exact name, whatever 1,100 newer jobs contain" t_resolve_exact
check "B1/B18/B26: verdicts through the whole path" t_status_verdicts
check "status with the daemon down, broken or garbled" t_status_daemon
check "B-RT1/B-RT2/B-RT3/B-RT4: one transient daemon-down is re-tried, at most 10 times, and nothing else is" t_status_transient_retry
check "B-RT5: a status that exits 0 is answered at once, even when its output names the transient diagnostic" t_status_success_not_retried
check "B-RT6: VELO_TASK_RETRY_SLEEP is a whole number or digits, one dot, digits; any other value is refused (exit 2)" t_retry_sleep_validation
check "B-RT7: VELO_TASK_POLL is a whole number or digits, one dot, digits; any other value is refused (exit 2)" t_poll_validation
check "B4/B5/B6/B15: wait --all, --any, timeout, unknown ids" t_wait
check "cancel is vanth stop, then the verdict killed; a finished job is exit 4" t_cancel
check "a job that vanished after the id resolved is exit 2 with no verdict" t_vanished_job
check "the session: id from the environment, else a token the state dir keeps" t_session
echo "velo-task: hooks"
check "B-S: the Stop guard blocks this session's in-flight jobs and fails closed" t_stop_guard
check "the stop-override is one Stop, audited" t_stop_override
check "the guard reads tags_json as JSON and fails closed on anything else" t_tags_json
check "the fallback session token is read only if private, ours, not a link and token-shaped" t_session_file
check "every path the guard and hooks trust: absent allows, a link, a file or a loose mode blocks" t_vanth_paths
check "SessionStart lists this session's jobs and counts the others" t_session_start
echo "velo-task: mutation proofs (each check must go red on a mutated copy)"
V=bin/velo-task; L=bin/velo-task-lib.sh; S=bin/velo-task-state; H=hooks/velo-task-stop-guard.sh; HS=hooks/velo-task-session-start.sh
H0=$(printf '%064d' 0)
prove "json-get prints Python booleans" t_json_get $S 'print("true" if value else "false")' 'print(value)'
prove "json-get prints a missing key as null" t_json_get $S $'    if value is None:\n        return 0\n' ''
prove "json-get reads a malformed file as empty" t_json_get $S '    doc = json.loads(raw)' $'    try:\n        doc = json.loads(raw)\n    except ValueError:\n        return 0'
prove "json-get lets a non-object through" t_json_get $S '    if not isinstance(doc, dict):' '    if False:'
prove "json-get fails on a missing file" t_json_get $S $'        except FileNotFoundError:\n            return 0' $'        except FileNotFoundError:\n            raise'
prove "json-get writes in the caller's locale encoding" t_json_get $S '    sys.stdout.reconfigure(encoding="utf-8")' '    pass'
prove "jobs-ro waits 0 ms" t_jobs_ro $S 'uri=True, timeout=2.0' 'uri=True, timeout=0.0'
prove "jobs-ro skips the schema check" t_jobs_ro $S '        if missing:' '        if False:'
prove "jobs-ro installs no authorizer" t_jobs_ro $S '        con.set_authorizer(read_only_authorizer)' '        pass'
prove "a wait that is not a number is evaluated by bash arithmetic" t_hostile_env $L \
  '  case "${!v:-0}" in *[!0-9]*) die 2 "$v must be a whole number of seconds: ${!v}" ;; esac' '  :'
prove "a poll interval that is not a number is passed to sleep" t_hostile_env $L \
  '[[ "${VELO_TASK_POLL:-0}" =~ $SECS_RE ]] || die 2 "VELO_TASK_POLL must be a number of seconds: $VELO_TASK_POLL"' ':'
ROW=charset prove "the allowlist accepts any name" t_allowlist_rejects $L '/usr/bin/grep -Eq "$NAME_RE"' '/usr/bin/grep -Eq "."'
ROW=charset prove "the allowlist accepts lowercase names" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Za-z][A-Za-z0-9_]*\$'"
ROW=charset prove "the allowlist accepts a leading digit" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Z0-9][A-Z0-9_]*\$'"
ROW=charset prove "the allowlist accepts a dash in a name" t_allowlist_rejects $L "NAME_RE='^[A-Z][A-Z0-9_]*\$'" "NAME_RE='^[A-Z][A-Z0-9_-]*\$'"
ROW=charset prove "the allowlist prints the offending line" t_allowlist_rejects $L '(value not shown)" >&2; bad=1; continue' '$key" >&2; bad=1; continue'
prove "an allowlist rule matches by first letter only" t_allowlist_rejects $L 'case "$key" in "$p"*)' 'case "$key" in "${p:0:1}"*)'
prove "the allowlist check stops at the first bad line" t_allowlist_lists $L '(value not shown)" >&2; bad=1; continue' '(value not shown)" >&2; return 1'
prove "the launch digest covers the allowlist, not the names this environment sets" t_digest_inherited $L '  names=$(inherited_names)' '  names=$ALLOW_NAMES'
prove "start time rendered in the caller's locale and zone" t_locale_fresh_shell $L 'LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' '/bin/ps -o lstart= -p "$1"'
prove "adoption does not check the listener" t_loopback $L '    check_loopback "$pid" || die 6 "$LOOPBACK_WHY; refusing to adopt it. Run: velo-task restart-daemon"' '    :'
prove "the loopback check always passes" t_loopback $L '  [ "$got" = "n127.0.0.1:$PORT " ] && return 0' '  return 0'
prove "the loopback check looks at the port only" t_loopback $L '  [ "$got" = "n127.0.0.1:$PORT " ] && return 0' $'  case "$got" in *":$PORT "*) return 0 ;; esac'
PORT_HOLDER_MUTANT=release prove_env "the port reservation is given back, so a foreign server can take the port" t_port_reservation
PORT_HOLDER_MUTANT=release prove_env "the loopback test's port reservation is given back" t_loopback
PORT_HOLDER_MUTANT=listen-wild prove_env "the wildcard side of the port reservation listens too" t_port_reservation
# loopback-only is a failure of the BSD port rules: there a wildcard bind is allowed beside a loopback holder. Linux counts overlapping
# addresses as one, so a loopback holder alone refuses the wildcard bind and this mutant changes nothing (checked: the foreign wildcard
# bind is refused with the wildcard half of the reservation left out). The `release` proofs above are the ones that bite on both.
if [ "$(uname)" != Linux ]; then
  PORT_HOLDER_MUTANT=loopback-only prove_env "the port reservation holds loopback only, so a foreign server can take the wildcard address" t_port_reservation
  PORT_HOLDER_MUTANT=loopback-only prove_env "the loopback test reserves its port on loopback only" t_loopback
fi
prove "restart-daemon signals the pid daemon.json names when no record exists" t_restart_refuses_unproven $L \
  $'  elif probe_up; then\n    die 6 "a daemon answers on port $PORT but no velo-task record proves' \
  $'  elif probe_up; then\n    signal_validated TERM "$(djson pid)" "$(ps_lstart "$(djson pid)")"; /bin/sleep 1\n    die 6 "a daemon answers on port $PORT but no velo-task record proves'
prove "ps is looked up on the caller's PATH" t_no_path_tools $L 'LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' 'LC_ALL=C TZ=UTC ps -o lstart= -p "$1"'
prove "lsof is looked up on the caller's PATH" t_no_path_tools $L '"$LSOF" -nP' 'lsof -nP'
VELO_TASK_START_WAIT=3 prove "env is looked up on the caller's PATH" t_no_path_tools $L 'vanth_env() { /usr/bin/env -i' 'vanth_env() { env -i'   # a shim env never answers the probe: the mutant waits out the start window, 3 s
prove "awk is looked up on the caller's PATH" t_no_path_tools $L 'norm_names() { /usr/bin/awk' 'norm_names() { awk' $L 'SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin' 'SYS_PATH="$PATH"'
prove "install without the PyPI pin" t_install_flags $L '--default-index https://pypi.org/simple' '--no-config'
prove "a failed install keeps the broken venv" t_install_asserts $L '  /bin/rm -rf "$VENV"; die 1 "install-vanth failed' '  die 1 "install-vanth failed'
FAKE_UV_MUTANT=nohash prove_env "the fake uv does not enforce --require-hashes" t_install_hash_tamper
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
prove "a hash is swapped for the sdist's, the wheel comment beside it left as it was" t_lock_file requirements/vanth.lock \
  'sha256:f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0  # wheel: annotated_types-0.8.0-py3-none-any.whl' \
  'sha256:13b2beaad985e05e2d6407ee4c4f35590b11f8d693a258a561055cac8f64cab7  # wheel: annotated_types-0.8.0-py3-none-any.whl'
prove "the manifest records another hash for a pin" t_lock_file requirements/vanth.wheels.tsv \
  $'annotated_types-0.8.0-py3-none-any.whl\tany\tf072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0' \
  $'annotated_types-0.8.0-py3-none-any.whl\tany\t13b2beaad985e05e2d6407ee4c4f35590b11f8d693a258a561055cac8f64cab7'
prove "the manifest lacks the row of a pin" t_lock_file requirements/vanth.wheels.tsv \
  $'annotated-types\t0.8.0\tannotated_types-0.8.0-py3-none-any.whl\tany\tf072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0\n' ''
prove "the manifest names another wheel for a pin" t_lock_file requirements/vanth.wheels.tsv \
  $'anyio\t4.15.1\tanyio-4.15.1-py3-none-any.whl\tany' $'anyio\t4.15.1\tanyio-4.15.1-py2.py3-none-any.whl\tany'
prove "the manifest has a row for a distribution the lock does not pin" t_lock_file requirements/vanth.wheels.tsv \
  $'annotated-types\t0.8.0\t' $'zzz-extra\t1.0\tzzz_extra-1.0-py3-none-any.whl\tany\t0000000000000000000000000000000000000000000000000000000000000000\nannotated-types\t0.8.0\t'
prove "the lock names a wheel for another platform" t_lock_file requirements/vanth.lock \
  '# wheel: vanth-1.14.0-py3-none-macosx_11_0_arm64.whl' '# wheel: vanth-1.14.0-py3-none-manylinux_2_17_aarch64.whl'
prove "the lock names a wheel for another interpreter" t_lock_file requirements/vanth.lock \
  '# wheel: starlette-1.10.0-py3-none-any.whl' '# wheel: starlette-1.10.0-cp313-cp313-macosx_11_0_arm64.whl'
prove "a script runs Vanth's setup command" t_lock_file $L 'LIB_SRC="${BASH_SOURCE[0]}"' $'LIB_SRC="${BASH_SOURCE[0]}"\nvanth setup'
prove "a script writes ~/.claude.json" t_lock_file $V 'set -euo pipefail' $'set -euo pipefail\necho {} > "$HOME/.claude.json"'
prove "the lock pins another starlette than the closure list" t_lock_closure requirements/vanth.lock 'starlette==1.10.0 \' 'starlette==1.10.1 \'
FAKE_UV_MUTANT=fromlock prove_env "the fake uv derives the installed set from the lock" t_lock_closure
prove "install.sh does not ship requirements" t_install_ships_lock install.sh '  [[ -d "$SRC/$d" ]] || continue
  mkdir -p "$DEST/$d"' '  [[ -d "$SRC/$d" ]] || continue
  [[ $d == requirements ]] && continue
  mkdir -p "$DEST/$d"'
prove "install.sh drift check ignores requirements" t_install_ships_lock install.sh 'for d in bin rules skills hooks launchd requirements; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__' 'for d in bin rules skills hooks launchd; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__'
# ---- the state helper: new checks ----
prove "jobs-ro: the authorizer allows everything" t_jobs_ro $S 'return sqlite3.SQLITE_OK if action in (SQLITE_READ, SQLITE_SELECT, SQLITE_FUNCTION) else sqlite3.SQLITE_DENY' 'return sqlite3.SQLITE_OK'
prove "jobs-ro: parameters are dropped" t_jobs_ro $S 'rows = query_ro(args[0], args[1], tuple(args[2:]))' 'rows = query_ro(args[0], args[1], ())'
prove "jobs-ro: fields are not quoted" t_jobs_ro $S '    return text if re.fullmatch(r"[\x21\x23-\x7e]+", text) else json.dumps(text)' '    return text'
prove "jobs-ro: no schema check" t_jobs_ro $S '        if missing:' '        if False:'
prove "jobs-ro: a locked database is exit 1" t_jobs_ro $S 'die(4 if "locked" in str(exc) else 1,' 'die(1,'
prove "verdict: anything unknown is ok" t_verdict_table $S 'return "lost"  # orphaned, any other cancelled, a status outside both sets' 'return "ok"'
prove "verdict: stopping is not in flight" t_verdict_table $S '"retrying", "stopping"))' '"retrying"))'
prove "verdict: any cancel is killed" t_verdict_table $S 'row.get("stop_actor") == "user"' 'True'
prove "verdict: a pending restart is ignored" t_verdict_table $S 'if status in ("failed", "orphaned") and restart_pending(row):' 'if False:'
prove "verdict: a failed job with no exit code is failed(0)" t_verdict_table $S 'if isinstance(code, int) and not isinstance(code, bool) else "lost"' 'if True else "lost"' 
prove "verdict: a deeply nested policy column is a traceback" t_verdict_table $S 'except (ValueError, RecursionError):  # a policy column' 'except ValueError:  # a policy column'
prove "verdict: a deeply nested status is a traceback" t_verdict_cli $S 'except (ValueError, RecursionError) as exc:  # not JSON' 'except ValueError as exc:  # not JSON'
prove "verdict: a status for another job is reported" t_verdict_cli $S 'if key in opts and row.get(field) != opts[key]:' 'if False:'
prove "verdict: a non-object status gets a verdict" t_verdict_cli $S $'    if not isinstance(row, dict):\n        die(6,' $'    if False:\n        die(6,'
prove "verdict: the database is not consulted for a restart" t_verdict_cli $S 'if opts.get("db") and job and' 'if False and job and'
prove "launch: the whole environment is passed" t_launch $S '{n: os.environ[n] for n in names}' 'dict(os.environ)'
prove "launch: a name that is not set is ignored" t_launch $S 'missing = [n for n in names if n not in os.environ]' 'missing = []'
prove "override: take follows a symlink" t_override $S 'os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK' 'os.O_RDONLY | os.O_NONBLOCK'
prove "override: take does not consume it" t_override $S '    os.unlink(path)' '    pass'
prove "override: a reason with a newline" t_override $S ' or "\n" in args[1]' ''
# ---- run, status, wait, cancel ----
prove "run: no --timeout needed" t_run_validation $L '  [ -n "$timeout" ] || die 2 "--timeout S is required: every job is started with a deadline"' '  [ -n "$timeout" ] || timeout=3600'
prove "run: any id" t_run_validation $L "    id) re='^[a-z0-9][a-z0-9_-]{2,63}\$' ;;" "    id) re='.*' ;;"
prove "run: any timeout" t_run_validation $L "    timeout) re='^[1-9][0-9]{0,8}\$' ;;" "    timeout) re='.*' ;;"
prove "run: any issue" t_run_validation $L "    issue) re='^[0-9]{1,9}\$' ;;" "    issue) re='.*' ;;"
prove "run: any stage" t_run_validation $L "    stage) re='^[a-z0-9][a-z0-9_-]{0,31}\$' ;;" "    stage) re='.*' ;;"
prove "run: any session" t_run_validation $L "    session) re='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\$' ;;" "    session) re='.*' ;;"
prove "run: the key ignores the session" t_run_dedup $L "key=\"velo_\$(printf '%s' \"\$session\" | sha_of | /usr/bin/cut -c1-8)_\$id\"" 'key="velo_00000000_$id"'
prove "run: the session tag is not sent" t_run_basic $L '--tag velo --tag "session:$session")' '--tag velo)'
prove "run: the issue tag is wrong" t_run_basic $L '--tag "issue:$issue"' '--tag "issue:0"'
prove "run: the stage tag is wrong" t_run_basic $L '--tag "stage:$stage"' '--tag "stage:none"'
prove "run: the name is not the id" t_run_basic $L '--name "$id" --timeout "$timeout"' '--name "$id-x" --timeout "$timeout"'
prove "run: the deadline is not the one asked" t_run_basic $L '--timeout "$timeout" --idempotency-key' '--timeout 3600 --idempotency-key'
prove "run: vanth runs with the caller's environment" t_run_basic $L 'vanth_env() { /usr/bin/env -i PATH=' 'vanth_env() { /usr/bin/env PATH='
prove "run: --rerun reuses the key" t_run_rerun $L 'if [ "$rerun" = 1 ]; then key=' 'if false; then key='
prove "run: a conflict is exit 1" t_run_dedup $L '      die 5 "IDEMPOTENCY_CONFLICT' '      die 1 "IDEMPOTENCY_CONFLICT'
prove "run: a daemon that cannot be reached is exit 1" t_run_failures $L 'die 6 "daemon-down: $2; whether the start was accepted' 'die 1 "daemon-down: $2; whether the start was accepted'
prove "resolve: LIKE" t_resolve_exact $L $'WHERE name = ? ORDER BY created_at DESC, job_id DESC LIMIT 1\' "$1")' $'WHERE name LIKE ? ORDER BY created_at DESC, job_id DESC LIMIT 1\' "%$1%")'
prove "resolve: the oldest job" t_run_rerun $L 'ORDER BY created_at DESC, job_id DESC LIMIT 1' 'ORDER BY created_at ASC, job_id ASC LIMIT 1'
prove "resolve: an unknown id goes on" t_resolve_exact $L '  [ -n "$found" ] || die 2 "unknown id' '  [ -n "$found" ] || JOB=job_nope; [ -n "$found" ] || die 0 "unknown id'
prove "status: a daemon that cannot be reached is exit 1" t_status_daemon $L '*"failed to reach daemon"*) die 6 "daemon-down: $out; no verdict' '*"failed to reach daemon"*) die 1 "daemon-down: $out; no verdict'
prove "B-RT1: no re-try at all" t_status_transient_retry $L '[ "$RETRY_ATTEMPTS" -lt 11 ] || break' '[ "$RETRY_ATTEMPTS" -lt 1 ] || break'
prove "B-RT1: the default pause is nothing" t_status_transient_retry $L '/bin/sleep "${VELO_TASK_RETRY_SLEEP:-0.2}"' '/bin/sleep "${VELO_TASK_RETRY_SLEEP:-0}"'
prove "B-RT2: five calls instead of eleven" t_status_transient_retry $L '[ "$RETRY_ATTEMPTS" -lt 11 ] || break' '[ "$RETRY_ATTEMPTS" -lt 5 ] || break'
prove "B-RT3: every error is re-tried, not just the daemon-down" t_status_transient_retry $L 'case "$RETRY_OUT" in *"failed to reach daemon"*) ;; *) break ;; esac' 'case "$RETRY_OUT" in *"vanth status"*) ;; *) break ;; esac'
prove "B-RT4: a pause even when the first call answers" t_status_transient_retry $L 'RETRY_OUT=""; RETRY_ATTEMPTS=0' 'RETRY_OUT=""; RETRY_ATTEMPTS=0; /bin/sleep "${VELO_TASK_RETRY_SLEEP:-0.2}"'
prove "B-RT5: the non-zero exit is not required, so a zero status is re-tried when its output names the daemon" t_status_success_not_retried $L '[ "$rc" -ne 0 ] || break' ':'
prove "B-RT6: the old character-class check, which passes 1.2.3, ., 1..2, .., .5 and 5." t_retry_sleep_validation $L '[[ "${VELO_TASK_RETRY_SLEEP:-0}" =~ $SECS_RE ]] || die 2 "VELO_TASK_RETRY_SLEEP must be a number of seconds: $VELO_TASK_RETRY_SLEEP"' 'case "${VELO_TASK_RETRY_SLEEP:-0}" in *[!0-9.]*) die 2 "VELO_TASK_RETRY_SLEEP must be a number of seconds: $VELO_TASK_RETRY_SLEEP" ;; esac'
prove "B-RT7: the old character-class check, which passes 1.2.3, ., 1..2, .., .5 and 5." t_poll_validation $L '[[ "${VELO_TASK_POLL:-0}" =~ $SECS_RE ]] || die 2 "VELO_TASK_POLL must be a number of seconds: $VELO_TASK_POLL"' 'case "${VELO_TASK_POLL:-0}" in *[!0-9.]*) die 2 "VELO_TASK_POLL must be a number of seconds: $VELO_TASK_POLL" ;; esac'
prove "wait: a failed winner of --any is exit 0" t_wait $L '[ "${done_[$first]#* }" = ok ]; return' 'true; return'
prove "wait: --all with a failed job is exit 0" t_wait $L '[ "${done_[$i]#* }" = ok ] || worst=1;' 'true || worst=1;'
prove "wait: a timeout is exit 1" t_wait $L 'die 3 "wait timed out' 'die 1 "wait timed out'
prove "wait: --any waits for all" t_wait $L 'if [ "$mode" = any ] && [ "$first" -ge 0 ]; then' 'if false; then'
prove "cancel: the job is not stopped" t_cancel $L 'out=$(vanth_env "$VANTH" --json stop "$JOB" --signal terminate --kill-after 5 2>&1) || rc=$?' 'out=""'
# ---- hooks ----
prove "Stop guard: the override is not consumed" t_stop_override $S '    os.unlink(path)' '    pass'
prove "SessionStart: lists nothing" t_session_start $HS 'if [ -n "$rows" ]; then' 'if false; then'
prove "SessionStart: an unreadable database is silent" t_session_start $HS $'rows=$(inflight_of "$session" 2>&1) || { echo "velo-task: Vanth\'s database cannot be read, so in-flight jobs are unknown: $rows"; exit 0; }' $'rows=$(inflight_of "$session" 2>/dev/null) || rows=""'
# ---- install, daemon: new anchors ----
prove "install without --require-hashes" t_install_flags $L '--require-hashes --only-binary :all: -r "$LOCKFILE" </dev/null' '--only-binary :all: -r "$LOCKFILE" </dev/null'
prove "install allows sdists" t_install_flags $L '--require-hashes --only-binary :all: -r "$LOCKFILE" </dev/null' '--require-hashes -r "$LOCKFILE" </dev/null'
prove "install from the wrong file" t_install_flags $L '-r "$LOCKFILE" </dev/null \' '-r "$LIB_DIR/../requirements/vanth.in" </dev/null \'
prove "install without --require-hashes accepts a lock whose hash is not its wheel's" t_install_hash_tamper $L '--require-hashes --only-binary :all: -r "$LOCKFILE" </dev/null' '--only-binary :all: -r "$LOCKFILE" </dev/null'
prove "install runs Vanth's setup command" t_lock_file $L '  printf '\''%s\n'\'' "$want" > "$MARKER"' '  "$VANTH" setup; printf '\''%s\n'\'' "$want" > "$MARKER"'
prove "install ignores the marker" t_install_idempotent $L '  if [ -x "$PY" ] && [ -f "$MARKER" ] && [ "$(/bin/cat "$MARKER")" = "$want" ]; then' '  if false; then'
prove "a changed lock does not rebuild" t_install_idempotent $L '  if [ -x "$PY" ] && [ -f "$MARKER" ] && [ "$(/bin/cat "$MARKER")" = "$want" ]; then' '  if true; then'
prove "install replaces a venv under a running daemon" t_install_refuses_under_daemon $L '  ! { probe_up || prov_live; } || die 6 "a daemon is running from' '  true || die 6 "a daemon is running from'
prove "a failed install removes the venv under a running daemon" t_install_failure_under_daemon $L '  ! { probe_up || prov_live; } || die 6 "install-vanth: $*;' '  true || die 6 "install-vanth: $*;'
prove "the installed set is not compared with the lock" t_install_asserts $L '  [ "$locked" = "$installed" ] || fail_install' '  true || fail_install'
prove "the schema is not asserted" t_install_asserts $L $'  st jobs-ro "$tmp/jobs.sqlite" \'SELECT 1 AS ok\' >/dev/null || fail_install' $'  true || fail_install'
prove "ensure-daemon before install-vanth does not say what to run" t_before_install $L 'die 6 "Vanth is not installed in $VENV; run: velo-task install-vanth"' 'die 6 "Vanth is not installed"'
prove "ensure-daemon does not check the modes" t_modes_refuse $L $'need_home; need_install; need_allowlist; need_modes\n  if probe_up; then' $'need_home; need_install; need_allowlist\n  if probe_up; then'
prove "restart-daemon does not check the modes" t_modes_refuse $L $'need_home; need_install; need_allowlist; need_modes\n  pid=$(prov_get pid)' $'need_home; need_install; need_allowlist\n  pid=$(prov_get pid)'
prove "restart-daemon skips the allowlist check" t_allowlist_lists $L $'need_home; need_install; need_allowlist; need_modes\n  pid=$(prov_get pid)' $'need_home; need_install; need_modes\n  pid=$(prov_get pid)'
prove "the mode check is skipped after a launch" t_modes_after_launch $L $'  need_modes\n  printf \'daemon up pid=%s port=%s (started)' $'  printf \'daemon up pid=%s port=%s (started)'
prove "the launch log is not part of the mode check" t_modes_refuse $L '  [ ! -e "$LAUNCH_LOG" ] || set -- "$LAUNCH_LOG"' '  :'
prove "a failed mode check is treated as private" t_modes_refuse $L '-print 2>&1 |' '-print 2>/dev/null |'
prove "a launch is not checked for its listener" t_loopback $L '  check_loopback "$pid" || abandon_launch "$pid" "$LOOPBACK_WHY"' '  true'
prove "adoption does not check the listener" t_loopback $L '    check_loopback "$pid" || die 6 "$LOOPBACK_WHY; refusing to adopt it' '    true || die 6 "$LOOPBACK_WHY; refusing to adopt it'
prove "a host with no lsof is not told so" t_loopback $L '[ -n "$LSOF" ] || { LOOPBACK_WHY="there is no lsof (looked for /usr/sbin/lsof /usr/bin/lsof), so what pid $1 listens on cannot be checked"; return 1; }' ':'
prove "the provenance pid is not compared with daemon.json" t_provenance_refusals $L '  [ "$(djson pid)" = "$pid" ] || { PROV_WHY="daemon.json pid' '  true || { PROV_WHY="daemon.json pid'
prove "the provenance start time is not compared" t_provenance_refusals $L '  [ -n "$live" ] && [ "$live" = "$(prov_get lstart)" ] ||' '  [ -n "$live" ] ||'
prove "the provenance digest is not compared" t_provenance_refusals $L '  [ "$(prov_get digest)" = "$(launch_spec | sha_of)" ] \' '  true \'
prove "the provenance may be a symlink" t_provenance_refusals $L '  [ -f "$PROV" ] && [ ! -L "$PROV" ] ||' '  [ -f "$PROV" ] ||'
prove "a provenance without a valid pid" t_provenance_refusals $L "  case \"\$pid\" in ''|*[!0-9]*) PROV_WHY=" '  case "$pid" in ZZZ) PROV_WHY='
prove "the provenance records the wrong pid" t_modes_env $L '"$pid" "$started" "$digest" > "$PROV.$$"' '"$$" "$started" "$digest" > "$PROV.$$"'
prove "launch without umask 077" t_modes_env $L '  ( umask 077; export PATH="$JOB_PATH" VANTH_HOME=' '  ( export PATH="$JOB_PATH" VANTH_HOME='
prove "launch with a retention" t_modes_env $L 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=0' 'VANTH_DAEMON_PORT="$PORT" VANTH_RETENTION_SECONDS=1'
prove "allowlisted values are never delivered" t_secrets $L '  names="PATH HOME VANTH_HOME AGENT_BG_HOME VANTH_DAEMON_PORT VANTH_RETENTION_SECONDS $(inherited_names)"' '  names="PATH HOME VANTH_HOME AGENT_BG_HOME VANTH_DAEMON_PORT VANTH_RETENTION_SECONDS"'
prove "a secret value reaches an argv" t_secret_argv $L 'vanth_env() { /usr/bin/env -i PATH=' 'vanth_env() { /usr/bin/env -i OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" PATH='
prove "the launch log is shown" t_launch_log_not_shown $L '"vanthd did not become ready on port $PORT; see $LAUNCH_LOG"' '"vanthd did not become ready on port $PORT; see $LAUNCH_LOG: $(/usr/bin/tail -n 3 "$LAUNCH_LOG")"'
prove "another daemon answering counts as this launch being ready" t_launch_requires_own_pid $L $'      if [ "$(djson pid)" = "$pid" ]; then break; fi' '      break' $L 'probe_up && [ "$(djson pid)" = "$pid" ]; } \' 'probe_up; } \'
prove "a concurrent launch does not adopt the daemon that won" t_concurrent_ensure $L '      if ! kill -0 "$pid" 2>/dev/null && prov_valid; then' '      if false; then'
prove "restart-daemon does not signal the old daemon" t_restart $L '    kill -TERM "$pid"' '    :'
prove "restart-daemon delegates to vanth restart" t_restart $L $'  fi\n  launch_daemon\n}\n' $'  fi\n  "$VANTH" restart; launch_daemon\n}\n'
prove "restart-daemon does not bound the wait for the old daemon" t_stop_failure $L '    ! kill -0 "$pid" 2>/dev/null || die 6 "vanthd pid $pid still running' '    ! kill -0 "$pid" 2>/dev/null || echo "vanthd pid $pid still running'
prove "restart-daemon ignores the recorded start time" t_restart_refuses_unproven $L '  [ -n "$pid" ] && [ -n "$(ps_lstart "$pid")" ] && [ "$(ps_lstart "$pid")" = "$(prov_get lstart)" ]' '  [ -n "$pid" ] && [ -n "$(ps_lstart "$pid")" ]'
prove "restart-daemon signals a record that daemon.json contradicts" t_restart_refuses_unproven $L '    [ -z "$dj" ] || [ "$dj" = "$pid" ] || die 6 "vanthd pid $pid is recorded' '    true || die 6 "vanthd pid $pid is recorded'
prove "restart-daemon signals a daemon no record proves" t_restart_refuses_unproven $L '  elif probe_up; then' '  elif false; then'
prove "restart-daemon demands the current launch digest" t_restart_digest_change $L '  if prov_live; then
    dj=' '  if prov_valid; then
    dj='
prove "ensure-daemon launches over a live recorded process" t_daemon_json_malformed $L '    if prov_live; then
      die 6 "vanthd pid $(prov_get pid) is running but' '    if false; then
      die 6 "vanthd pid $(prov_get pid) is running but'
prove "djson takes a daemon.json it cannot parse for an absent one" t_daemon_json_malformed $L '|| die 6 "$VH/daemon.json cannot be read as JSON (see above), so the pid in it proves nothing; remove or fix it by hand"; }' '|| true; }'
prove "env is looked up on the caller's PATH (state helper)" t_no_path_tools $L 'st() { /usr/bin/env -i' 'st() { env -i'
prove "ps is looked up on the caller's PATH" t_no_path_tools $L 'LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$1"' 'LC_ALL=C TZ=UTC ps -o lstart= -p "$1"'
prove "shasum is looked up on the caller's PATH" t_no_path_tools $L 'sha_of() { /usr/bin/shasum' 'sha_of() { shasum'
prove "uv runs with the caller's PATH" t_no_path_tools $L 'run_uv() {  # uv sees nothing of the caller'"'"'s: fixed system dirs for PATH, HOME for its cache
  /usr/bin/env -i PATH="/opt/homebrew/bin:$SYS_PATH"' 'run_uv() {
  /usr/bin/env -i PATH="$PATH"'
prove "the parser routes library function names" t_private_subcommands $V '  *) die 2 "unknown subcommand' '  *) "$sub" "$@"; exit $?; die 2 "unknown subcommand'
prove "the helper is not isolated from the caller's user site" t_hostile_env $L 'st() { /usr/bin/env -i "${HELPER_ENV[@]}" "$PYSYS" -I "$STATE_SCRIPT" "$@"; }' 'st() { /usr/bin/env -i "${HELPER_ENV[@]}" "$PYSYS" "$STATE_SCRIPT" "$@"; }'

# ---- review round: Stop guard class, override, vanished job, cancel ----
prove "Stop guard: always allows" t_stop_guard $H 'deny "this session still has jobs in flight' 'exit 0; deny "this session still has jobs in flight'
prove "Stop guard: fails open when the query fails" t_stop_guard $H $'|| deny "Vanth\'s database cannot be read, or the check did not complete: $out"' '|| true' $H $'[ "${out##*$\'\\n\'}" = "$OK" ] || deny "the check did not complete (no success marker): $out"' 'true'
prove "Stop guard: no success marker required" t_stop_guard $H $'[ "${out##*$\'\\n\'}" = "$OK" ] || deny "the check did not complete (no success marker): $out"' 'true'
prove "Stop guard: stopping does not block" t_stop_guard $S '"retrying", "stopping"))' '"retrying"))'
prove "Stop guard: a lost job blocks" t_stop_guard $S 'return "lost"  # orphaned, any other cancelled, a status outside both sets' 'return "in-flight"'
prove "Stop guard: a restart pending does not block" t_stop_guard $S 'if status in ("failed", "orphaned") and restart_pending(row):' 'if False:'
prove "Stop guard: no Vanth home allows, a home does not" t_stop_guard $H '[ ! -e "$STATE/vanth" ] && {' 'true && {'
prove "Stop guard: a missing database is no jobs" t_stop_guard $L $'  st inflight "$VH/jobs.sqlite" "$1"\n}' $'  [ -e "$VH/jobs.sqlite" ] || return 0; st inflight "$VH/jobs.sqlite" "$1"\n}'
prove "Stop guard: no HOME allows" t_stop_guard $H '[ -n "${VELO_TASK_HOME:-}${VELO_STATE:-}${HOME:-}" ] || block' 'true || block'
prove "Stop guard: a tool is looked up on PATH" t_stop_guard $H "/usr/bin/grep '^ROW '" "grep '^ROW '"
prove "Stop guard: the override is always on" t_stop_override $H '. "$1" && st override-take "$VELO_TASK_HOME" && echo' '. "$1" && true && echo'
prove "SessionStart: counts this session's jobs as others" t_session_start $S 'others += 1' 'others += 2'
prove "override: write replaces a valid pending one" t_override $S $'    if valid_override(path):\n        die(1,' $'    if False:\n        die(1,'
prove "override: write cannot replace a stale entry" t_override $S 'os.rename(tmp, path)  # replaces' 'os.link(tmp, path)  # replaces'
prove "override: take accepts any file" t_override $S 'or info.st_mode & 0o077 or info.st_size > limit:' 'or False:'
prove "override: take accepts an open mode" t_override $S ' or info.st_mode & 0o077 or info.st_size > limit' ' or info.st_size > limit'
prove "override: take accepts any content" t_override $S 'return bool(match) and int(match.group(1)) == os.getuid()' 'return True'
prove "override: take accepts another uid" t_override $S ' and int(match.group(1)) == os.getuid()' ''
prove "override: take accepts a non-regular entry" t_override $S 'if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or' 'if info.st_uid != os.getuid() or'
prove "override: the temp file is left behind" t_override $S $'    except BaseException:\n        if os.path.lexists(tmp):\n            os.unlink(tmp)\n        raise' $'    except BaseException:\n        raise'
prove "vanished job: exit 3" t_vanished_job $L '*"unknown job"*) die 2 "job $job is unknown' '*"unknown job"*) die 3 "job $job is unknown'
prove "cancel: a finished job is stopped anyway" t_cancel $L $'  if [ "$VERDICT" = in-flight ]; then\n    out=$(vanth_env' $'  if true; then\n    out=$(vanth_env'
prove "cancel: a finished job is exit 0" t_cancel $L 'die 4 "already-terminal' 'die 0 "already-terminal'
prove "cancel: a finished job prints its verdict as a result" t_cancel $L $'  printf \'%s\\n\' "$VERDICT_LINE" >&2\n  die 4' $'  printf \'%s\\n\' "$VERDICT_LINE"\n  die 4'
prove "cancel: a finished job is reported killed" t_cancel $L 'if [ "$VERDICT" = killed ]; then printf' 'if true; then printf'

# ---- review round 2: tags as JSON, session token provenance ----
prove "tags: matched as raw text" t_tags_json $S 'if "session:" + args[1] in job_tags(row):' $'if \'"session:%s"\' % args[1] in (row.get("tags_json") or ""):'
prove "tags: a parse failure is no tags" t_tags_json $S $'    except (ValueError, RecursionError, TypeError) as exc:\n        raise ValueError("job %s: tags_json is not JSON (%s)" % (row.get("job_id"), exc))' $'    except (ValueError, RecursionError, TypeError):\n        return []'
prove "tags: a non-array is no tags" t_tags_json $S $'    if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):\n        raise' $'    if not isinstance(tags, list):\n        return []\n    if False:\n        raise'
prove "tags: non-string elements are ignored" t_tags_json $S 'or not all(isinstance(t, str) for t in tags):' 'or False:'
prove "session file: read as plain text" t_session_file $L '    s=$(st session-read "$VELO_TASK_HOME") ||' '    s=$(/bin/cat "$SESSION_FILE") ||'
prove "session file: the state dir may be open" t_session_file $S $'if not private_dir(args[0]):\n        die(1, "session-read' $'if False:\n        die(1, "session-read'

prove "tags: any session tag matches" t_stop_guard $S 'if "session:" + args[1] in job_tags(row):' 'if any(t.startswith("session:") for t in job_tags(row)):'
prove "tags: a session id that is a prefix matches" t_stop_guard $S 'if "session:" + args[1] in job_tags(row):' 'if any(t.startswith("session:" + args[1]) for t in job_tags(row)):'

prove "session file: a link is followed" t_session_file $S 'os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK' 'os.O_RDONLY | os.O_NONBLOCK'
prove "session file: any mode" t_session_file $S ' or info.st_mode & 0o077 or info.st_size > limit' ' or info.st_size > limit'
prove "session file: any content" t_session_file $S 'if token is None or not re.fullmatch(r"[0-9a-f]{16}", token):' 'if token is None:'
prove "session file: a trailing newline is accepted" t_session_file $S 'not re.fullmatch(r"[0-9a-f]{16}", token):' 'not re.fullmatch(r"[0-9a-f]{16}\n?", token):'


# ---- review round 3: every Vanth path ----
prove "jobs-ro follows a symlink" t_jobs_ro $S 'info = os.lstat(path)  # lstat' 'info = os.stat(path)  # lstat'
prove "jobs-ro: the directory may be open" t_jobs_ro $S 'if not private_dir(os.path.dirname(path)) or not stat.S_ISREG' 'if not stat.S_ISREG'
prove "jobs-ro: the file may be open" t_jobs_ro $S $'info.st_uid != os.getuid() or info.st_mode & 0o077:\n        die(1, "jobs-ro' $'info.st_uid != os.getuid():\n        die(1, "jobs-ro'
prove "jobs-ro: a symlink is no object" t_vanth_paths $S 'info = os.lstat(path)  # lstat' 'info = os.stat(path)  # lstat'
prove "jobs-ro: any mode (guard)" t_vanth_paths $S $'info.st_uid != os.getuid() or info.st_mode & 0o077:\n        die(1, "jobs-ro' $'info.st_uid != os.getuid():\n        die(1, "jobs-ro'
prove "private_dir follows a link" t_override $S $'        info = os.lstat(path)\n    except OSError:\n        return False\n    return stat.S_ISDIR' $'        info = os.stat(path)\n    except OSError:\n        return False\n    return stat.S_ISDIR'
prove "private_dir follows a link (session)" t_session_file $S $'        info = os.lstat(path)\n    except OSError:\n        return False\n    return stat.S_ISDIR' $'        info = os.stat(path)\n    except OSError:\n        return False\n    return stat.S_ISDIR'
prove "Stop guard: a dangling Vanth home is no home" t_vanth_paths $H '&& [ ! -L "$STATE/vanth" ]' ''
prove "Stop guard: a non-directory Vanth home is no home" t_vanth_paths $H '[ ! -e "$STATE/vanth" ] && {' '[ ! -d "$STATE/vanth" ] && {'
prove "Stop guard: a symlinked state dir is no problem" t_vanth_paths $H 'if [ ! -L "$STATE" ] && ' 'if '
prove "Stop guard: a state dir that is a file is no problem" t_vanth_paths $H '{ [ ! -e "$STATE" ] || [ -d "$STATE" ]; }; then exit 0' 'true; then exit 0'
prove "SessionStart: a dangling Vanth home is silent" t_vanth_paths $HS '&& [ ! -L "$STATE/vanth" ]' ''
prove "SessionStart: a symlinked state dir is silent" t_vanth_paths $HS 'if [ ! -L "$STATE" ] && ' 'if '
prove "resolve: a dangling jobs.sqlite is an unknown id" t_vanth_paths $L $'[ ! -e "$db" ] && [ ! -L "$db" ] || found=$(st jobs-ro --cols job_id "$db" \'SELECT job_id FROM jobs WHERE name' $'[ ! -e "$db" ] || found=$(st jobs-ro --cols job_id "$db" \'SELECT job_id FROM jobs WHERE name'
prove "modes: a symlinked Vanth home is fine" t_vanth_paths $L '  [ ! -L "$VH" ] || { MODES_WHY="$VH is a symlink"; return 0; }' ''
prove "need_home: a symlinked state root is fine" t_vanth_paths $L '  [ ! -L "$VELO_TASK_HOME" ] || die 6 "$VELO_TASK_HOME is a symlink; refusing"' ''
prove "install: the schema probe database is open to others" t_install_flags $L '  ( umask 077; "$PY" -I -c' '  ( "$PY" -I -c'
proof_drain   # every proof reported before anything else runs: the checks below reap the whole suite tree
if [ "${VELO_TASK_NETWORK_TESTS:-}" = 1 ]; then
  echo "velo-task: the real Vanth (VELO_TASK_NETWORK_TESTS=1)"
  check "the real Vanth from PyPI: install, daemon, run, wait, cancel, timeout, tags" t_network
else
  echo "  (network install skipped: set VELO_TASK_NETWORK_TESTS=1)"
fi
echo "velo-task: isolation"
check "the real home is untouched: HOME was a temp dir and PATH the system directories throughout" t_real_home_untouched
check "control: the same comparison passes against an undisturbed stand-in home" t_stand_in_untouched
echo
exit $FAILED

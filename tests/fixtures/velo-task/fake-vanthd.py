#!@PY3@ -I
"""Fake vanthd for the velo-task tests (rendered by the test harness: @E@ and @PY3@ are filled in).
Run isolated (-I): a user site in the HOME it is given must not load into it, or the hostile-environment test could not tell
velo-task's own python from this fixture's.

Only what velo-task relies on, but with real behaviour where velo-task now checks it: it LISTENS (127.0.0.1, or
0.0.0.0 when @E@/bind-all exists), so the loopback check sees a real socket; it exits when it cannot bind. It records its
launch (pid, umask, home, port, retention), the NAMES of its environment, a hash of OPENROUTER_API_KEY (never a value) and whether
descriptor 9 (the one velo-task's locked body holds on its lock) reached it, to @E@/calls, secures its home like Vanth, writes
daemon.json once it is listening, and exits on SIGTERM.

Switches (files under @E@): fail-launch (exit 1 at once), ignore-term (ignore SIGTERM), bind-all (listen on 0.0.0.0),
seed.sqlite (copied to jobs.sqlite), bind-fail-delay (seconds to linger after a failed bind, default 1), start-delay (seconds
to stay alive, recorded but not yet listening and without a daemon.json, before binding: a daemon that is starting or hung),
loose-file (leave logs/daemon.log group- and world-readable although the launch set umask 077: Vanth creating a file with its
own mode), forge-json (the file holds a pid: write a daemon.json naming THAT process and stay alive without ever listening, as
if another daemon answered on the port while this one could not).
"""
import hashlib
import json
import os
import shutil
import signal
import socket
import sys
import time

E = "@E@"
try:  # the lock descriptor velo-task hands its locked body (9) must not reach the daemon: asked first, before this process opens anything
    os.fstat(9)
    FD9 = "open"
except OSError:
    FD9 = "closed"
HOME_DIR = os.environ.get("VANTH_HOME", "")
if not HOME_DIR:
    sys.stderr.write("fake vanthd: no VANTH_HOME\n")
    sys.exit(1)
if os.path.exists(E + "/fail-launch"):
    sys.stderr.write("fake vanthd: refusing to start\n")
    sys.exit(1)
port = int(os.environ.get("VANTH_DAEMON_PORT", "0"))

os.makedirs(HOME_DIR + "/logs", exist_ok=True)
os.makedirs(HOME_DIR + "/events", exist_ok=True)
os.chmod(HOME_DIR, 0o700)
for name in ("token", "logs/daemon.log", "events/e.jsonl"):
    open(os.path.join(HOME_DIR, name), "w").close()
seed = E + "/seed.sqlite"
if os.path.exists(seed):
    shutil.copyfile(seed, HOME_DIR + "/jobs.sqlite")
    os.chmod(HOME_DIR + "/jobs.sqlite", 0o600)
else:
    open(HOME_DIR + "/jobs.sqlite", "w").close()
if os.path.exists(E + "/loose-file"):
    os.chmod(HOME_DIR + "/logs/daemon.log", 0o644)

umask = os.umask(0)
os.umask(umask)
env = os.environ
hidden = {"PWD", "SHLVL", "_", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}  # added by the shell or the Python runtime, not by velo-task
key = env.get("OPENROUTER_API_KEY")
with open(E + "/calls", "a") as calls:
    calls.write("launch pid=%d umask=%04o home=%s port=%s retention=%s\n"
                % (os.getpid(), umask, HOME_DIR, env.get("VANTH_DAEMON_PORT", ""), env.get("VANTH_RETENTION_SECONDS", "unset")))
    calls.write("names=%s \n" % " ".join(sorted(k for k in env if k not in hidden)))
    calls.write("keyhash=%s\n" % (hashlib.sha256(key.encode()).hexdigest() if key is not None else "unset"))
    calls.write("fd9=%s\n" % FD9)

slow = E + "/start-delay"
if os.path.exists(slow):
    time.sleep(float(open(slow).read()))  # the default SIGTERM action still applies here: the handler is installed after the bind

forge = E + "/forge-json"
if os.path.exists(forge):
    with open(HOME_DIR + "/daemon.json", "w") as fh:
        fh.write(json.dumps({"url": "http://127.0.0.1:%d" % port, "home": HOME_DIR, "pid": int(open(forge).read()),
                             "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, separators=(",", ":")) + "\n")
    time.sleep(300)  # a stub never outlives a broken run; the default SIGTERM action still applies

host = "0.0.0.0" if os.path.exists(E + "/bind-all") else "127.0.0.1"
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)  # lets the test's port reservation (also REUSEPORT) coexist; a foreign listener without it still blocks us
try:
    sock.bind((host, port))
except OSError as exc:
    sys.stderr.write("fake vanthd: cannot bind %s:%d: %s\n" % (host, port, exc))
    sys.stderr.flush()
    delay = E + "/bind-fail-delay"
    time.sleep(float(open(delay).read()) if os.path.exists(delay) else 1.0)  # long enough for velo-task to record the launch
    sys.exit(1)
sock.listen(16)

with open(HOME_DIR + "/daemon.json", "w") as fh:
    fh.write(json.dumps({"url": "http://127.0.0.1:%d" % port, "home": HOME_DIR, "pid": os.getpid(),
                         "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, separators=(",", ":")) + "\n")


def on_term(_signum, _frame):
    try:
        os.unlink(HOME_DIR + "/daemon.json")
    finally:
        os._exit(0)


signal.signal(signal.SIGTERM, signal.SIG_IGN if os.path.exists(E + "/ignore-term") else on_term)
sock.settimeout(0.1)
end = time.monotonic() + 300  # a stub never outlives a broken run
while time.monotonic() < end:
    try:
        conn, _addr = sock.accept()
        conn.close()
    except socket.timeout:
        pass

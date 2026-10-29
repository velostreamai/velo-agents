#!@PY3@ -I
"""Fake `vanth` CLI for the velo-task M2a tests (rendered by the test harness: @E@ and @PY3@ are filled in).

It keeps real state: jobs and idempotency keys live in $VANTH_HOME/jobs.sqlite, with the columns the spec reads, and a started
command really runs (to completion, before `start` returns) so a test counts executions in a file the command appends to.
The behaviour velo-task depends on follows Vanth 1.14.0 as probed against the real package:
  --json status                health probe: {"up": true} while the pid in daemon.json lives, else {"up": false} and exit 1
  --json status <job>          the job's status object; an unknown job is a unique PREFIX of an id, as in Vanth (_resolve_job_id)
  --json start ... -- cmd...   idempotency_key 8..128 of [A-Za-z0-9_-]; the same key and request returns the existing job
                               (idempotent_replay), the same key and another request is an error; exit 1 with the JSON for a
                               job that did not complete (as Vanth does)
  --json list [--all] [--name N] [--limit N]   newest first, capped at 1000, --name a substring match
  __inject <json>              (test only) a row as given; __bulk <n> <name-prefix> (test only) n completed rows
Every call is appended to @E@/calls as `vanth <args>`, followed by `env=<the names in its environment>`. Switches (files under @E@):
start-transport-error, start-fail, status-transport-error, status-fail, status-garbage.
"""
import hashlib
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import time

E = "@E@"
HOME = os.environ.get("VANTH_HOME", "")
FAILED = {"failed", "lost", "timeout", "cancelled", "orphaned"}
os.umask(0o077)
HIDDEN = {"PWD", "SHLVL", "_", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "OLDPWD"}  # added by the shell or the Python runtime
with open(E + "/calls", "a") as calls:
    calls.write("vanth %s\nenv=%s\n" % (" ".join(sys.argv[1:]), " ".join(sorted(k for k in os.environ if k not in HIDDEN))))


def fail(text, code=1):
    sys.stderr.write(text + "\n")
    sys.exit(code)


def db():
    con = sqlite3.connect(HOME + "/jobs.sqlite")
    con.row_factory = sqlite3.Row
    con.execute("CREATE TABLE IF NOT EXISTS jobs (job_id TEXT PRIMARY KEY, name TEXT, status TEXT, exit_code INTEGER, stop_actor TEXT,"
                " stop_reason TEXT, trigger_json TEXT, created_at TEXT, ended_at TEXT, policy_state_json TEXT, command TEXT, cwd TEXT,"
                " timeout_seconds INTEGER, tags TEXT, seq INTEGER)")
    con.execute("CREATE TABLE IF NOT EXISTS local_start_requests (idempotency_key TEXT PRIMARY KEY, request_hash TEXT, job_id TEXT,"
                " created_at TEXT)")
    return con


def insert(con, row):
    row = dict(row)
    row.setdefault("seq", (con.execute("SELECT COALESCE(MAX(seq), 0) FROM jobs").fetchone()[0]) + 1)
    row.setdefault("created_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    row.setdefault("tags", "[]")
    con.execute("INSERT INTO jobs (%s) VALUES (%s)" % (", ".join(row), ", ".join("?" * len(row))), list(row.values()))


def status_object(row):
    trigger = json.loads(row["trigger_json"]) if row["trigger_json"] else None
    return {"job_id": row["job_id"], "status": row["status"], "command": row["command"], "cwd": row["cwd"],
            "timeout_seconds": row["timeout_seconds"], "name": row["name"], "tags": json.loads(row["tags"] or "[]"), "env": {},
            "trigger": trigger, "policy": None, "stop_actor": row["stop_actor"], "stop_reason": row["stop_reason"],
            "exit_code": row["exit_code"], "created_at": row["created_at"]}


def cmd_status(args):
    if not args:  # the health probe
        pid = None
        try:
            pid = json.load(open(HOME + "/daemon.json")).get("pid")
            os.kill(int(pid), 0)
            print(json.dumps({"up": True}))
            return 0
        except (OSError, ValueError, TypeError):
            print(json.dumps({"up": False}))
            return 1
    if os.path.exists(E + "/status-transport-error"):
        fail("vanth status: failed to reach daemon: connection refused")
    if os.path.exists(E + "/status-fail"):
        fail("vanth status: daemon error: boom")
    if os.path.exists(E + "/status-garbage"):
        print("{not json")
        return 0
    raw, con = args[0], db()
    rows = con.execute("SELECT * FROM jobs ORDER BY seq DESC LIMIT 1000").fetchall()
    exact = con.execute("SELECT * FROM jobs WHERE job_id = ?", (raw,)).fetchone()
    if exact is None:
        matches = [r for r in rows if r["job_id"].startswith(raw)] if "/" not in raw and len(raw) < 40 else []
        if len(matches) > 1:
            fail("vanth status: %r is ambiguous: %s" % (raw, ", ".join(sorted(r["job_id"] for r in matches)[:5])))
        if not matches:
            fail("vanth status: unknown job %s" % raw)
        exact = matches[0]
    print(json.dumps(status_object(exact), indent=2))
    return 0


def run_job(command, cwd, timeout):
    try:
        done = subprocess.run(["/bin/sh", "-c", command], cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", None
    return ("completed" if done.returncode == 0 else "failed"), done.returncode


def cmd_start(args):
    opts, tags, i, argv = {}, [], 0, []
    while i < len(args):
        if args[i] == "--":
            argv = args[i + 1:]
            break
        if args[i] == "--tag":
            tags.append(args[i + 1])
        else:
            opts[args[i][2:]] = args[i + 1]
        i += 2
    for switch, text in (("start-transport-error", "vanth start: failed to reach daemon: connection refused"), ("start-fail", "vanth start: boom")):
        if os.path.exists(E + "/" + switch):
            fail(text)
    key = opts.get("idempotency-key")
    if key is not None and not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", key):
        fail("vanth start: idempotency_key must be 8..128 letters, digits, underscores or hyphens")
    command = argv[0] if len(argv) == 1 else shlex.join(argv)
    cwd, timeout = opts.get("cwd", os.getcwd()), int(opts["timeout"]) if "timeout" in opts else None
    request = {k: opts.get(k) for k in ("env", "policy", "trigger", "secret-env")}
    request.update(command=command, cwd=cwd, name=opts.get("name"), tags=tags, timeout=timeout)
    digest = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
    con = db()
    if key is not None:
        seen = con.execute("SELECT * FROM local_start_requests WHERE idempotency_key = ?", (key,)).fetchone()
        if seen is not None:
            if seen["request_hash"] != digest:
                fail("vanth start: idempotency_key was already used for a different job request")
            row = con.execute("SELECT * FROM jobs WHERE job_id = ?", (seen["job_id"],)).fetchone()
            if row is None:
                fail("vanth start: idempotency_key refers to cleaned job %s; use a new key for new work" % seen["job_id"])
            print(json.dumps({"job_id": row["job_id"], "status": row["status"], "idempotent_replay": True,
                              "message": "Existing job returned; no new workload launched"}, indent=2))
            return 1 if row["status"] in FAILED else 0
    job_id = "job_" + os.urandom(6).hex()
    status, code = run_job(command, cwd, timeout)
    with con:
        insert(con, {"job_id": job_id, "name": opts.get("name"), "status": status, "exit_code": code, "command": command, "cwd": cwd,
                     "timeout_seconds": timeout, "tags": json.dumps(tags),
                     "trigger_json": opts.get("trigger") if opts.get("trigger") else None})
        if key is not None:
            con.execute("INSERT INTO local_start_requests (idempotency_key, request_hash, job_id, created_at) VALUES (?, ?, ?, ?)",
                        (key, digest, job_id, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    print(json.dumps({"job_id": job_id, "status": status, "message": "Job started", "startup_confirmed": True}, indent=2))
    return 1 if status in FAILED else 0


def cmd_list(args):
    name, limit, show_all, i = None, 50, False, 0
    while i < len(args):
        if args[i] == "--all":
            show_all = True
        elif args[i] == "--name":
            i += 1
            name = args[i]
        elif args[i] == "--limit":
            i += 1
            limit = int(args[i])
        i += 1
    rows = [r for r in db().execute("SELECT * FROM jobs ORDER BY seq DESC").fetchall()
            if (name is None or name in (r["name"] or "")) and (show_all or r["status"] in ("queued", "launching", "running"))]
    print(json.dumps([status_object(r) for r in rows[:min(limit, 1000)]], indent=2))
    return 0


def main(argv):
    if argv[:1] == ["--json"]:
        argv = argv[1:]
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    con = None
    if cmd == "status":
        return cmd_status(args)
    if cmd == "start":
        return cmd_start(args)
    if cmd == "list":
        return cmd_list(args)
    if cmd == "__inject":
        row = json.loads(args[0])
        con = db()
        row.setdefault("job_id", "job_inj" + os.urandom(5).hex())
        row.setdefault("status", "running")
        for column in ("trigger_json", "policy_state_json", "tags"):
            if column in row and not isinstance(row[column], str):
                row[column] = json.dumps(row[column])
        with con:
            insert(con, row)
        print(row["job_id"])
        return 0
    if cmd == "__bulk":
        con = db()
        with con:
            for n in range(int(args[0])):
                insert(con, {"job_id": "job_bulk%06d" % n, "name": "%s%d" % (args[1], n), "status": "completed", "exit_code": 0,
                             "command": "true", "cwd": "/"})
        return 0
    fail("fake vanth: unsupported: %s" % " ".join(argv), 2)


sys.exit(main(sys.argv[1:]))

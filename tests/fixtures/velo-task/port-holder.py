#!/usr/bin/env python3
"""A listener the velo-task tests use to hold a TCP port (run by absolute python path, never via PATH).

  port-holder.py reserve <ready-file>             127.0.0.1:0 with SO_REUSEPORT: reserves a free port for a test while the fake
                                                  vanthd (also SO_REUSEPORT) binds the same port; writes the port to <ready-file>
  port-holder.py foreign <port> <ready-file> <signal-log>
                                                  127.0.0.1:<port> WITHOUT SO_REUSEPORT: a foreign process on the daemon's port. It
                                                  appends the name of every catchable signal it receives to <signal-log> and keeps running
"""
import signal
import socket
import sys
import time

mode = sys.argv[1]
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
if mode == "reserve":
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("127.0.0.1", 0))
    ready = sys.argv[2]
elif mode == "foreign":
    sock.bind(("127.0.0.1", int(sys.argv[2])))
    ready, log = sys.argv[3], sys.argv[4]

    def note(signum, _frame):
        with open(log, "a") as fh:
            fh.write(signal.Signals(signum).name + "\n")

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(sig, note)
else:
    sys.exit("port-holder: unknown mode %r" % mode)
sock.listen(16)
with open(ready, "w") as fh:
    fh.write("%d\n" % sock.getsockname()[1])
sock.settimeout(0.2)
end = time.monotonic() + 600  # never outlives a broken run
while time.monotonic() < end:
    try:
        conn, _addr = sock.accept()
        conn.close()
    except socket.timeout:
        pass

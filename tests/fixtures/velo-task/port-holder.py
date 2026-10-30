#!/usr/bin/env python3
"""A listener the velo-task tests use to hold a TCP port (run by absolute python path, never via PATH).

  port-holder.py reserve <ready-file> [wild]      127.0.0.1:0 with SO_REUSEPORT: reserves a free port for a test while the fake
                                                  vanthd (also SO_REUSEPORT) binds the same port; writes the port to <ready-file>.
                                                  With `wild` the port is also held on 0.0.0.0 (bound, never listening), for a test
                                                  whose daemon listens on every interface: the kernel then picks a port that nothing
                                                  holds on any address, and a foreign server that binds that very number on the
                                                  wildcard address (a port finder that bound 0, closed, and came back to the number)
                                                  is refused. Beside the loopback listener alone it is not, and the daemon's own
                                                  wildcard bind then fails with EADDRINUSE.
                                                  PORT_HOLDER_MUTANT (tests only): loopback-only (ignore `wild`), listen-wild (the
                                                  wildcard socket listens too), release (the port is given back once it is
                                                  reported, which is what picking a port by bind-and-close does)
                                                  On Linux the sockets only HOLD the port: they set SO_REUSEPORT and not
                                                  SO_REUSEADDR, and never listen. Linux shares the connections to a port among
                                                  all the listeners of a SO_REUSEPORT group, so a listening holder would take its
                                                  share of the fake vanthd's connections; a bound socket that has no SO_REUSEADDR
                                                  of its own refuses a foreign SO_REUSEADDR server on every address, and one on
                                                  loopback already refuses the wildcard bind (Linux counts overlapping addresses
                                                  as one), so `loopback-only` changes nothing there.
  port-holder.py foreign <port> <ready-file> <signal-log>
                                                  127.0.0.1:<port> (0: the kernel picks one; <ready-file> gets the number) WITHOUT
                                                  SO_REUSEPORT: a foreign process on the daemon's port. It
                                                  appends the name of every catchable signal it receives to <signal-log> and keeps running
"""
import os
import signal
import socket
import sys
import time

LINUX = sys.platform.startswith("linux")  # see the docstring: Linux and BSD answer a second bind of a reserved port differently


def reserved_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if not LINUX:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    return s


mode = sys.argv[1]
if mode == "reserve":
    mutant = os.environ.get("PORT_HOLDER_MUTANT", "")
    sock = reserved_socket()
    wide = None
    ready = sys.argv[2]
    if sys.argv[3:] == ["wild"] and mutant != "loopback-only":
        wide = reserved_socket()  # first: the kernel picks a port nothing holds on any address
        wide.bind(("0.0.0.0", 0))
        if mutant == "listen-wild":
            wide.listen(16)
        sock.bind(("127.0.0.1", wide.getsockname()[1]))  # then the same number on loopback, where the fake daemon normally binds
    else:
        sock.bind(("127.0.0.1", 0))
elif mode == "foreign":
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", int(sys.argv[2])))
    ready, log = sys.argv[3], sys.argv[4]

    def note(signum, _frame):
        with open(log, "a") as fh:
            fh.write(signal.Signals(signum).name + "\n")

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(sig, note)
else:
    sys.exit("port-holder: unknown mode %r" % mode)
holds_only = mode == "reserve" and LINUX  # a reservation on Linux holds the port and never listens (see the docstring)
if not holds_only:
    sock.listen(16)
with open(ready, "w") as fh:
    fh.write("%d\n" % sock.getsockname()[1])
if mode == "reserve" and mutant == "release":  # the port goes back to the kernel; the process stays, so the test sees a live holder that holds nothing
    sock.close()
    if wide is not None:
        wide.close()
    holds_only = True
end = time.monotonic() + 600  # never outlives a broken run
if holds_only:
    time.sleep(600)
else:
    sock.settimeout(0.2)
    while time.monotonic() < end:
        try:
            conn, _addr = sock.accept()
            conn.close()
        except socket.timeout:
            pass

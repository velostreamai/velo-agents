#!@PY3@
"""Fake uv for the velo-task install tests (rendered by the test harness: @E@ @PY3@ @FIX@ @CLOSURE@ @VARIANT@ @MUTANT@ are filled in).

It writes only below the fixture root @E@, and it refuses, before it creates, removes or writes anything, a target that is
outside that root, has a symlink in any component below it, or is itself a symlink. A defective velo-task, or a mutant, that
passes a symlinked or external venv path must not be able to remove or overwrite a real file: a fixture once wrote through a
venv symlink and clobbered the Homebrew python3.

  uv venv ... <dir>             a complete fake Vanth install: bin/python, bin/vanth (fake-vanth.sh), bin/vanthd (fake-vanthd.py)
  uv pip install ...            logged only
  uv pip freeze ...             the checked-in closure fixture (tests/fixtures/vanth-closure.txt), NOT derived from the lock;
                                the variant extra adds a distribution, missing drops starlette
Every call is logged to @E@/uv.log with the PATH it was given.
"""
import os
import sys

E = "@E@"
FIX = "@FIX@"
PY3 = "@PY3@"
CLOSURE = "@CLOSURE@"
VARIANT = "@VARIANT@"
MUTANT = "@MUTANT@"  # empty, except in the fixture's own mutation proofs: noguard (no path guard) or fromlock (installed set = the lock)
UNSAFE = MUTANT == "noguard"


def log(line):
    with open(E + "/uv.log", "a") as fh:
        fh.write(line + "\n")


def refuse(why):
    sys.stderr.write("fake uv: refusing: %s\n" % why)
    sys.exit(1)


def guard(target):
    """Exit 1 unless target is a real (non-symlink) path under E; called before every create, remove and write."""
    if UNSAFE:
        return
    root = os.path.abspath(E)
    path = os.path.abspath(target)
    if not path.startswith(root + os.sep):
        refuse("%s is outside the fixture root %s" % (path, root))
    cur = root
    for part in path[len(root) + 1:].split(os.sep):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            refuse("%s is a symlink" % cur)
    if os.path.realpath(path) != os.path.join(os.path.realpath(root), path[len(root) + 1:]):
        refuse("%s is not canonical" % path)


def render(template, dest, mode):
    guard(dest)
    # The placeholder names are split so the harness's own substitution of this file leaves them alone.
    text = open(os.path.join(FIX, template)).read().replace("@" "E" "@", E).replace("@" "PY3" "@", PY3)
    if os.path.lexists(dest):
        os.unlink(dest)  # never write through an existing path
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


log("uv " + " ".join(sys.argv[1:]))
log("path=" + os.environ.get("PATH", ""))
args = sys.argv[1:]
if args[:1] == ["venv"]:
    d = args[-1]
    guard(d)
    guard(os.path.join(d, "bin"))
    os.makedirs(os.path.join(d, "bin"), exist_ok=True)
    py = os.path.join(d, "bin", "python")
    guard(py)
    if os.path.lexists(py):
        os.unlink(py)
    fd = os.open(py, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755)
    with os.fdopen(fd, "w") as fh:
        fh.write('#!/bin/sh\nPYTHONPATH=%s/site exec %s "$@"\n' % (E, PY3))
    render("fake-vanth.sh", os.path.join(d, "bin", "vanth"), 0o755)
    render("fake-vanthd.py", os.path.join(d, "bin", "vanthd"), 0o755)
elif args[:2] == ["pip", "install"]:
    if MUTANT == "fromlock":
        with open(E + "/lock-used", "w") as fh:
            fh.write(args[args.index("-r") + 1])
elif args[:2] == ["pip", "freeze"]:
    if MUTANT == "fromlock":  # the circular design finding 21 removed: what is "installed" is read off the lock itself
        pins = [ln.split(" ")[0] for ln in open(open(E + "/lock-used").read()) if ln[:1].isalnum() and "==" in ln]
        lines = pins
    else:
        lines = [ln.strip() for ln in open(CLOSURE) if ln.strip()]
    if VARIANT == "extra":
        lines.append("rogue-extra==1.0")
    if VARIANT == "missing":
        lines = [ln for ln in lines if not ln.startswith("starlette==")]
    sys.stdout.write("\n".join(lines) + "\n")
else:
    sys.stderr.write("fake uv: unsupported: %s\n" % " ".join(args))
    sys.exit(2)

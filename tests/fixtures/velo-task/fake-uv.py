#!@PY3@ -I
"""Fake uv for the velo-task install tests (rendered by the test harness: @E@ @PY3@ @FIX@ @CLOSURE@ @VARIANT@ @MUTANT@ are filled in).
Run isolated (-I), like the real uv, which is not a Python program: a user site in the HOME it is given must not load into it, or a
test of what velo-task itself starts could not tell velo-task's python from this fixture's.

It writes only below the fixture root @E@, and it refuses, before it creates, removes or writes anything, a target that is
outside that root, has a symlink in any component below it, or is itself a symlink. A defective velo-task, or a mutant, that
passes a symlinked or external venv path must not be able to remove or overwrite a real file: a fixture once wrote through a
venv symlink and clobbered the Homebrew python3.

  uv venv ... <dir>             a complete fake Vanth install: bin/python, bin/vanth (fake-vanth.sh), bin/vanthd (fake-vanthd.py).
                                hold-venv holds it, before it creates anything, as hold-pip holds the install
  uv pip install ...            logged. With --require-hashes (B23) it refuses, as uv does, a pin whose hash in the lock -r names is not
                                the sha256 that the reviewed manifest beside the lock records for that wheel (the wheel's real hash);
                                a pin the manifest has no row for is not checked. If @E@/hold-pip exists it creates hold-pip.reached
                                and waits for hold-pip.release, so a test can act while the install is running
  uv pip freeze ...             the checked-in closure fixture (tests/fixtures/vanth-closure.txt), NOT derived from the lock;
                                the variant extra adds a distribution, missing drops starlette. hold-freeze holds it, as hold-pip does
Every call is logged to @E@/uv.log with the PATH it was given and the names of its environment.
"""
import os
import re
import sys
import time

E = "@E@"
FIX = "@FIX@"
PY3 = "@PY3@"
CLOSURE = "@CLOSURE@"
VARIANT = "@VARIANT@"
MUTANT = "@MUTANT@"  # empty, except in the fixture's own mutation proofs: noguard (no path guard), fromlock (installed set = the lock) or nohash (--require-hashes not enforced)
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


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def check_hashes(lock):
    """What uv does under --require-hashes, with the manifest standing in for the wheels: each pin it has a row for must carry that
    row's sha256 (a wheel is hashed as downloaded; here the reviewed hash is what the wheel has). A pin it has no row for is not
    checked: the closure tests add pins of their own, and the fake has no wheel to hash for them."""
    rows = {}
    for line in open(os.path.join(os.path.dirname(lock), "vanth.wheels.tsv")).read().split("\n"):
        if line.strip() and not line.startswith("#"):
            name, ver, _wheel, _platform, sha = line.split("\t")
            rows[(norm(name), ver)] = sha
    pin = None
    for line in open(lock).read().split("\n"):
        m = re.match(r"^([A-Za-z0-9._-]+)==(\S+) \\$", line)
        if m:
            pin = (m.group(1), m.group(2))
            continue
        h = re.match(r"^\s+--hash=sha256:([0-9a-f]{64})\s", line)
        if h and pin and rows.get((norm(pin[0]), pin[1]), h.group(1)) != h.group(1):
            refuse("Hash mismatch for %s==%s: the lock expects sha256:%s, the wheel has sha256:%s"
                   % (pin[0], pin[1], h.group(1), rows[(norm(pin[0]), pin[1])]))


def hold(step):
    """If @E@/hold-<step> exists: say that the step is running (hold-<step>.reached) and wait, bounded, for hold-<step>.release."""
    if not os.path.exists(E + "/hold-" + step):
        return
    open(E + "/hold-" + step + ".reached", "w").close()
    deadline = time.monotonic() + 60
    while not os.path.exists(E + "/hold-" + step + ".release"):
        if time.monotonic() > deadline:
            refuse("hold-%s was never released" % step)
        time.sleep(0.02)


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
log("env=" + " ".join(sorted(os.environ)))  # the NAMES of its environment, never a value
args = sys.argv[1:]
if args[:1] == ["venv"]:
    hold("venv")
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
        # The fake package sits beside the fixtures, not in a site-packages, and `-I` (which velo-task passes) ignores PYTHONPATH:
        # this stand-in for the venv's python puts the package on sys.path itself for a `-c` run, then runs the real interpreter.
        # It is itself run isolated (the -I in the shebang), so it does not load the caller's user site on the way.
        fh.write("#!" + PY3 + " -I\n"
                 "import os, sys\n"
                 "args = sys.argv[1:]\n"
                 "if '-c' in args:\n"
                 "    i = args.index('-c') + 1\n"
                 "    args[i] = 'import sys; sys.path.insert(0, ' + repr(" + repr(E + "/site") + ") + ')\\n' + args[i]\n"
                 "os.execv(" + repr(PY3) + ", [" + repr(PY3) + "] + args)\n")
    render("fake-vanth.sh", os.path.join(d, "bin", "vanth"), 0o755)
    render("fake-vanthd.py", os.path.join(d, "bin", "vanthd"), 0o755)
elif args[:2] == ["pip", "install"]:
    if "--require-hashes" in args and MUTANT != "nohash":
        check_hashes(args[args.index("-r") + 1])
    if MUTANT == "fromlock":
        with open(E + "/lock-used", "w") as fh:
            fh.write(args[args.index("-r") + 1])
    hold("pip")
elif args[:2] == ["pip", "freeze"]:
    hold("freeze")
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

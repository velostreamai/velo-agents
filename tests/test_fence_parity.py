#!/usr/bin/env python3
"""The three fence readers in .agents/bin must read ONE grammar (#2380 round 3).

velo-dispatch's brief_prose (awk) masks fenced blocks so a heading quoted inside one is not a
heading; velo-gate-run's extract_attack (python) skips fenced blocks when it looks for `## ATTACK`
and for the heading that ends it; velo-gate's acceptance-bar counter (awk, inside the real script)
skips them when it looks for `## Acceptance` and for the bullets under it. All three claim
CommonMark's rules, written in two languages and three places — and they had already drifted: a
closing fence followed by a non-breaking space closed the block in python (str.strip() counts it
as blank) and did not in awk, and the counter toggled on any line starting with three backticks,
so an indented fence (a fence inside a list item) or a tilde fence was not a fence to it at all.

This drives the SHIPPED code of all three over one table of fence lines — extracted from the
scripts, or the real script itself, never a copy. For each line the question is the same: is the
heading that follows it still visible, or swallowed by a fence the line opened (or failed to
close)? The expected answer is CommonMark's, written in the table, so the readers cannot agree on
a wrong reading.

CommonMark facts the table encodes:
  * an opener / closer is indented up to THREE spaces; a TAB reaches column 4 at once, so a line
    with a tab in its leading whitespace is indented code, never a fence line;
  * a closer is a run of the same character at least as long as the opener, followed only by
    spaces and tabs (a CR is the end of a CRLF line); anything else after it, a non-breaking
    space or a form feed included, makes it ordinary text;
  * a backtick opener cannot carry a backtick in its info string; a tilde opener can.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"
NB = " ".encode()
HEADING = b"## ATTACK\nbody\n"
# What the same rows end with for velo-gate: an Acceptance section with exactly the three bullets
# that make it plan check-spec. Visible heading = three bars counted; swallowed = none.
HEADING_ACCEPTANCE = b"## Acceptance\n- a\n- b\n- c\n"
GH_STUB = """#!/bin/bash
case "$1 $2" in
  "pr view") cat "$STUB_META"; exit 0 ;;
  "issue view") cat "$STUB_BODY"; exit 0 ;;
esac
exit 0
"""

# (what, the line as bytes, is the heading that follows still visible?)
OPENERS = [
    ("three backticks open a fence", b"```", False),
    ("three tildes open a fence", b"~~~", False),
    ("two backticks are not a fence", b"``", True),
    ("two tildes are not a fence", b"~~", True),
    ("three spaces of indent still open one", b"   ```", False),
    ("four spaces are indented code", b"    ```", True),
    ("a tab is indented code", b"\t```", True),
    ("a tab before tildes is indented code", b"\t~~~", True),
    ("a space then a tab is indented code", b" \t```", True),
    ("two spaces then a tab is indented code", b"  \t```", True),
    ("three spaces then a tab is indented code", b"   \t```", True),
    ("trailing tab after the opener is fine", b"```\t", False),
    ("an info string is fine", b"```bash", False),
    ("a backtick opener cannot carry a backtick", b"``` `x`", True),
    ("a tilde opener can carry a backtick", b"~~~ `x`", False),
    ("a non-breaking space is not indentation", NB + b"```", True),
    ("a form feed is not indentation", b"\f```", True),
]
CLOSERS = [
    ("the plain closer closes", b"```", True),
    ("trailing spaces still close", b"```  ", True),
    ("a trailing tab still closes", b"```\t", True),
    ("spaces and tabs mixed still close", b"```  \t ", True),
    ("a trailing CR (CRLF) still closes", b"```\r", True),
    ("a longer closer closes", b"````", True),
    ("one space of indent closes", b" ```", True),
    ("three spaces of indent close", b"   ```", True),
    ("four spaces do not close", b"    ```", False),
    ("a tab does not close", b"\t```", False),
    ("a space then a tab does not close", b" \t```", False),
    ("three spaces then a tab do not close", b"   \t```", False),
    ("a trailing non-breaking space does not close", b"```" + NB, False),
    ("a trailing form feed does not close", b"```\f", False),
    ("a trailing vertical tab does not close", b"```\v", False),
    ("an info string does not close", b"``` x", False),
    ("a tilde line does not close a backtick fence", b"~~~", False),
]
# (what, the opener, the closer, is the heading that follows still visible?): the closer must be
# at least as long as the opener, whatever the opener's length.
LENGTHS = [
    ("a shorter closer does not close a longer backtick fence", b"````", b"```", False),
    ("an equal-length closer closes a four-backtick fence", b"````", b"````", True),
    ("a shorter closer does not close a longer tilde fence", b"~~~~~", b"~~~", False),
    ("a longer closer closes a tilde fence", b"~~~", b"~~~~", True),
    ("a five-tilde closer closes a five-tilde fence", b"~~~~~", b"~~~~~", True),
]


def crlf(b):
    return b.replace(b"\n", b"\r\n")


def rows(heading):
    for what, line, want in OPENERS:
        yield f"opener: {what}", line + b"\n" + heading, want
    for what, line, want in CLOSERS:
        yield f"closer: {what}", b"```\nin the fence\n" + line + b"\n" + heading, want
    for what, opener, closer, want in LENGTHS:
        yield f"length: {what}", opener + b"\nin the fence\n" + closer + b"\n" + heading, want
    # The same readers over a CRLF document: the line ending must not change an answer.
    for what, line, want in OPENERS[:5]:
        yield f"crlf opener: {what}", crlf(line + b"\n" + heading), want
    for what, line, want in CLOSERS[:6]:
        yield f"crlf closer: {what}", crlf(b"```\nin the fence\n" + line + b"\n" + heading), want


def main(tmp):
    failures = 0

    def ok(msg):
        print(f"  ok   {msg}")

    def fail(msg):
        nonlocal failures
        failures += 1
        print(f"  FAIL {msg}")

    gate_run = (BIN / "velo-gate-run").read_text()
    m = re.search(r"extract_attack\(\) \{[^\n]*\n  python3 - \"\$1\" <<'PY'\n(.*?)\nPY\n", gate_run, re.S)
    # brief_prose moved from velo-dispatch to velo-brief-lint.sh (2026-10-11); the masker is read there.
    prose_src = (BIN / "velo-brief-lint.sh").read_text()
    n = re.search(r"^brief_prose\(\) \{\n.*?^\}\n", prose_src, re.S | re.M)
    if not m or not n:
        fail("could not extract extract_attack from velo-gate-run and brief_prose from velo-brief-lint.sh "
             f"(python found: {bool(m)}, awk found: {bool(n)}) — renamed or restructured? "
             "Nothing here would notice if they drifted apart.")
        return 1
    (tmp / "extract.py").write_text(m.group(1))
    (tmp / "prose.sh").write_text("#!/bin/bash\n" + n.group(0) + 'BRIEF="$1"\nbrief_prose\n')
    doc = tmp / "doc.md"

    def python_sees_heading(text):
        doc.write_bytes(text)
        return subprocess.run(["python3", str(tmp / "extract.py"), str(doc)], capture_output=True).returncode == 0

    def awk_sees_heading(text):
        doc.write_bytes(text)
        out = subprocess.run(["bash", str(tmp / "prose.sh"), str(doc)], capture_output=True, check=True).stdout
        # a masked line has four spaces in front; a visible heading is the bare line (CRLF keeps its CR)
        return any(line in (b"## ATTACK", b"## ATTACK\r") for line in out.split(b"\n"))

    # The third reader is the real velo-gate, run as `velo-gate <pr> --plan` over a stub gh: a PR
    # touching src/ that closes issue #777, whose body is the row. The Acceptance heading counts
    # its three bullets only while it is outside a fence, and three bars is what plans check-spec.
    stub_bin = tmp / "bin"
    stub_bin.mkdir()
    (stub_bin / "gh").write_text(GH_STUB)
    (stub_bin / "gh").chmod(0o755)
    meta = tmp / "meta.json"
    meta.write_text(json.dumps({
        "headRefOid": "1" * 40, "labels": [], "files": [{"path": "src/x.rs"}],
        "state": "OPEN", "title": "t", "body": "Closes #777",
    }))
    issue_body = tmp / "issue-body.md"
    gate_env = dict(os.environ, PATH=f"{stub_bin}{os.pathsep}{os.environ['PATH']}", STUB_META=str(meta),
                    STUB_BODY=str(issue_body), VELO_STATE=str(tmp / "state"), TMPDIR=str(tmp))

    def gate_sees_heading(text):
        issue_body.write_bytes(text)
        run = subprocess.run(["bash", str(BIN / "velo-gate"), "4242", "--plan"], env=gate_env, capture_output=True)
        if run.returncode != 0:
            return None  # a run that failed is not an answer
        return b"check-spec" in run.stdout

    word = {True: "visible", False: "hidden", None: "UNREADABLE (the run failed)"}
    for (what, text, want), (_, text_acceptance, _) in zip(rows(HEADING), rows(HEADING_ACCEPTANCE)):
        py, awk, gate = python_sees_heading(text), awk_sees_heading(text), gate_sees_heading(text_acceptance)
        if py == awk == gate == want:
            ok(f"{what}: all three readers say the heading is {word[want]}")
        elif py == awk == gate:
            fail(f"{what}: all three readers say {word[py]}, CommonMark says {word[want]}")
        else:
            fail(f"{what}: THE READERS DISAGREE — extract_attack (python) says {word[py]}, "
                 f"brief_prose (awk) says {word[awk]}, velo-gate (awk) says {word[gate]}; "
                 f"CommonMark says {word[want]}")

    print()
    if failures:
        print(f"FAILED: {failures}")
        return 1
    print("all fence-parity checks passed")
    return 0


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="fence-parity.") as d:
        rc = main(pathlib.Path(d))
    sys.exit(rc)

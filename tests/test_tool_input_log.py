#!/usr/bin/env python3
"""What a worker SEARCHED FOR must reach the log, safely.

The log recorded `tool start names=Grep,Grep` and threw the arguments away, so a
run could grep twelve times and the log would say only that it grepped twelve
times. That is "verify from evidence, not the self-report" failing at the one
layer where a worker actually acts.

The arguments cannot simply be printed, and the three rules below are each a way
that printing them goes wrong. They are pinned here rather than in a live run
because the bad cases — a secret in a Bash command, a whole file in a Write —
are exactly the ones nobody wants to reproduce for real.

Run:  .agents/tests/run.sh     (or: python3 .agents/tests/test_tool_input_log.py)
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"

failures: list[str] = []


def load(name: str):
    path = BIN / name
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else f': {detail}'}")
    if not ok:
        failures.append(label)


class FakeEvent:
    def __init__(self, blocks):
        self.message = {"content": blocks}


def tool_use(name, inp):
    return {"type": "tool_use", "name": name, "input": inp}


def main() -> int:
    r = load("velo_worker_runner.py")
    s = r.summarise_tool_input

    print("\nthe audit trail — identifying params are KEPT")
    # The whole point: which pattern, in which path. Without these the log
    # cannot answer "did the worker look in the right place?"
    out = s({"pattern": "merge_left_with_nulls", "path": "src/"})
    check("grep pattern and path survive",
          "merge_left_with_nulls" in out and "src/" in out, out)

    out = s({"command": "cargo nextest run --no-default-features"})
    check("bash command survives", "cargo nextest run" in out, out)

    print("\nbulk content is ELIDED, never printed")
    # A Write carries an entire file. Printed verbatim it buries the log and
    # copies source into it; the SIZE is the part worth keeping.
    out = s({"file_path": "x.rs", "content": "x" * 4096})
    check("content rendered as a char count", "[4096 chars]" in out, out)
    check("content body absent", "xxxxxxxxxx" not in out, out[:80])
    check("file_path still shown alongside", "x.rs" in out, out)

    out = s({"old_string": "a" * 500, "new_string": "b" * 700})
    check("both sides of an Edit elided",
          "[500 chars]" in out and "[700 chars]" in out, out)

    print("\nsecrets are REDACTED")
    # A worker can read a .env or echo a token. That value must not be copied
    # into a log that is kept, shipped to velo-record, and read later.
    out = s({"api_key": "sk-abcdef1234567890abcdef"})
    check("secret-named key redacted",
          "[redacted]" in out and "abcdef1234567890" not in out, out)

    out = s({"command": "curl -H 'Authorization: Bearer ghp_ABCDEFGHIJKLMNOP1234'"})
    check("token in a command body redacted",
          "ghp_ABCDEFGHIJKLMNOP1234" not in out and "[redacted]" in out, out)
    check("the rest of the command still readable", "curl" in out, out)

    for name, val in (("openai_api_key", "x" * 40), ("AUTH_TOKEN", "y" * 40),
                      ("password", "hunter2"), ("db_credential", "z" * 30)):
        out = s({name: val})
        check(f"{name} redacted", val not in out and "[redacted]" in out, out)

    print("\nthe one-event-per-line contract holds")
    # velo-record and every human reading these logs grep them line-wise; a
    # newline inside a value would split one event into two.
    out = s({"command": "line one\nline two\r\nline three"})
    check("no raw newline", "\n" not in out and "\r" not in out, repr(out))
    check("newline shown as an escape", "\\n" in out, out)

    long = s({"pattern": "q" * 5000})
    check("a huge value is truncated", len(long) <= 420, f"len={len(long)}")
    check("truncation is stated, not silent", "chars]" in long or "…" in long, long[-40:])

    print("\ndegenerate inputs do not raise")
    for bad in (None, {}, [], "string", 42):
        try:
            check(f"input={bad!r} returns a string", isinstance(s(bad), str))
        except Exception as exc:
            check(f"input={bad!r} returns a string", False, f"{type(exc).__name__}: {exc}")

    out = s({"limit": 80, "offset": 1, "recurse": True})
    check("non-string values render", "80" in out and "True" in out, out)

    print("\nextraction from a real event shape")
    ev = FakeEvent([
        {"type": "text", "text": "let me look"},
        tool_use("Grep", {"pattern": "fn merge_left", "path": "src/"}),
        tool_use("Read", {"file_path": "src/lib.rs", "limit": 80}),
    ])
    calls = r.assistant_tool_calls(ev)
    check("both tool_use blocks extracted", len(calls) == 2, str(calls))
    check("text block ignored", all(n in ("Grep", "Read") for n, _ in calls), str(calls))
    check("name and args paired", calls[0][0] == "Grep" and "fn merge_left" in calls[0][1],
          str(calls[0]))

    # The old function must keep behaving — the emitted line still leads with it.
    check("assistant_tool_names unchanged",
          r.assistant_tool_names(ev) == ["Grep", "Read"], str(r.assistant_tool_names(ev)))

    for junk in (FakeEvent("not a list"), FakeEvent([None, 42, {"type": "text"}])):
        check("malformed content yields no calls", r.assistant_tool_calls(junk) == [])

    print("\nthe line the log actually emits")
    emitted: list[str] = []

    class Log:
        def emit(self, m): emitted.append(m)

    class Ev:
        type = r.SDKMessageType.ASSISTANT
        message = {"content": [
            tool_use("Grep", {"pattern": "merge_left_with_nulls", "path": "src/"}),
            tool_use("Write", {"file_path": "o.rs", "content": "z" * 2048}),
        ]}

    r.log_sdk_event(Log(), "worker", Ev())
    line = emitted[0] if emitted else ""
    print(f"    {line}")
    check("names kept for existing parsers", "names=Grep,Write" in line, line)
    check("pattern now visible", "merge_left_with_nulls" in line, line)
    check("written file elided", "[2048 chars]" in line and "zzzz" not in line, line)
    check("still a single line", "\n" not in line, repr(line))

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("all tool-input logging checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

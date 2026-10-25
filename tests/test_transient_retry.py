#!/usr/bin/env python3
"""Transient provider failures are retried at the model call, not fatal to the run.

Seen on the OpenRouter free tier (2026-10-25, #2593 replay): a 504 "Upstream idle
timeout" returned as a 200 with an error payload and no choices killed a run at
turn 86 (ModelBehaviorError); a 429 "temporarily rate-limited upstream" killed
another at turn 6. Both had the whole conversation in hand. The retry wraps the one
completion call, so the conversation is kept; a 403/400 is the caller's mistake and
is NOT retried.

Run:  .agents/tests/run.sh   (or: python3 .agents/tests/test_transient_retry.py)
"""
from __future__ import annotations

import asyncio
import ast
import pathlib
import sys
from types import SimpleNamespace as NS

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))
from velo_runner_lib import call_with_transient_retry, error_payload_status  # noqa: E402

failures: list[str] = []


def check(label, got, want):
    if got == want:
        print(f"  PASS  {label}: {got!r}")
    else:
        print(f"  FAIL  {label}: got {got!r}, want {want!r}")
        failures.append(label)


class FakeStatusError(Exception):
    def __init__(self, status, retry_after=None):
        super().__init__(f"status {status}")
        self.status_code = status
        self.response = NS(headers={"retry-after": str(retry_after)} if retry_after else {})


GOOD = NS(choices=[NS(message="ok")], error=None)


def payload(code):
    return NS(choices=[], error={"message": "Upstream idle timeout exceeded", "code": code})


def drive(script, **kw):
    """Run call_with_transient_retry over a scripted sequence of outcomes."""
    calls, sleeps, logs = [], [], []
    it = iter(script)

    async def call():
        calls.append(1)
        out = next(it)
        if isinstance(out, Exception):
            raise out
        return out

    async def sleep(s):
        sleeps.append(round(s, 3))

    try:
        res = asyncio.run(call_with_transient_retry(call, logs.append, sleep=sleep,
                                                    jitter=lambda: 0.5, **kw))
        err = None
    except Exception as exc:  # the unit under test re-raises what it must
        res, err = None, exc
    return res, err, len(calls), sleeps, logs


print("error payload (200, no choices) is retried until the call succeeds")
res, err, n, sleeps, logs = drive([payload(504), payload(504), GOOD])
check("returns the good response", res is GOOD, True)
check("three calls, two retries", (n, len(sleeps)), (3, 2))
check("backoff doubles from the base", sleeps, [5.0, 10.0])
check("each retry is logged", len(logs), 2)
check("the log names the failure", "error payload 504" in logs[0], True)

print("an exception with a transient status is retried and Retry-After is honoured")
res, err, n, sleeps, _ = drive([FakeStatusError(429, retry_after=7), GOOD])
check("recovered", res is GOOD, True)
check("waited the server's Retry-After", sleeps, [7.0])

print("a non-transient failure is raised at once")
res, err, n, sleeps, _ = drive([FakeStatusError(403), GOOD])
check("raised", isinstance(err, FakeStatusError), True)
check("one call, no sleep", (n, sleeps), (1, []))

print("a normal response, and an empty one with no error, are returned untouched")
res, err, n, sleeps, _ = drive([GOOD])
check("normal response: one call", (res is GOOD, n, sleeps), (True, 1, []))
EMPTY = NS(choices=[], error=None)
res, err, n, sleeps, _ = drive([EMPTY])
check("no choices and no error payload is not retried", (res is EMPTY, n), (True, 1))
check("error_payload_status ignores non-transient codes", error_payload_status(payload(400)), None)

print("retries are bounded and the last failure still surfaces")
res, err, n, sleeps, _ = drive([FakeStatusError(429)] * 20, retries=3)
check("exception raised after retries", isinstance(err, FakeStatusError), True)
check("1 call + 3 retries", (n, len(sleeps)), (4, 3))
res, err, n, sleeps, _ = drive([payload(504)] * 20, retries=2)
check("payload: last response returned for the caller to fail on", (res is not None, n), (True, 3))
res, err, n, sleeps, _ = drive([payload(504)] * 20, retries=6, base_s=5.0, cap_s=20.0)
check("backoff is capped", sleeps, [5.0, 10.0, 20.0, 20.0, 20.0, 20.0])

print("production wiring: the runner's model call goes through the retry")
src = (BIN / "velo-openai-agents-runner.py").read_text()
tree = ast.parse(src)
fn = next(n for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef) and n.name == "_with_cost")
check("_with_cost calls call_with_transient_retry",
      any(isinstance(n, ast.Call) and getattr(n.func, "id", "") == "call_with_transient_retry"
          for n in ast.walk(fn)), True)

if failures:
    print(f"\nFAILED: {len(failures)}: {failures}")
    sys.exit(1)
print("\nall transient-retry checks passed")

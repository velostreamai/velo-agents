#!/usr/bin/env python3
"""Tool-call input normalisation (#2010).

The failure this pins: `open_agent_sdk` types a tool-use block's `input` as
`dict[str, Any] | None`, never enforces it, and hands a `str` downstream on two
paths. The first tool method to call `.get()` on it raises
`AttributeError: 'str' object has no attribute 'get'` and kills the run
mid-flight — one dispatch lost 9.9M input tokens and produced no commits.

Run:  .agents/tests/run.sh
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

from velo_sdk_patches import install_tool_input_normalisation, normalise_tool_input  # noqa: E402

failures: list[str] = []


def check(label, got, want) -> None:
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        failures.append(label)


def normalisation_cases() -> None:
    print("normalise_tool_input")
    payload = {"command": "ls -la"}

    # A dict is already correct and must be returned untouched.
    check("dict passes through", normalise_tool_input(payload), payload)

    # openai_provider.py:243 — the ordinary single-encoded case.
    check("json string decodes", normalise_tool_input(json.dumps(payload)), payload)

    # The SILENT path: the provider encodes the argument string a second time,
    # so json.loads SUCCEEDS and returns a str. Nothing downstream type-checks,
    # which is why "the SDK does not parse arguments" misdescribes the bug.
    check("double-encoded decodes", normalise_tool_input(json.dumps(json.dumps(payload))), payload)

    # openai_provider.py:245 — the except branch assigns the raw string.
    check("unparseable string -> {}", normalise_tool_input("not json at all"), {})

    # Absent / empty inputs are ordinary, not errors.
    check("None -> {}", normalise_tool_input(None), {})
    check("empty string -> {}", normalise_tool_input(""), {})

    # Valid JSON that is not an object must not reach a tool expecting one.
    check("json list -> {}", normalise_tool_input("[1, 2, 3]"), {})
    check("json scalar -> {}", normalise_tool_input("42"), {})


def safety_case() -> None:
    print("safety — coercion must not misroute a destructive command")
    # engine.py:421 batches tools it believes are read-only to run CONCURRENTLY.
    # If coercion made a destructive command parse as read-only, this fix would
    # be worse than the crash it replaces.
    try:
        from open_agent_sdk.tools.bash import BashTool
    except Exception as exc:
        print(f"  SKIP  BashTool unavailable ({exc})")
        return
    dangerous = normalise_tool_input(json.dumps({"command": "rm -rf /"}))
    check("destructive command decodes", dangerous, {"command": "rm -rf /"})
    check("and is NOT classified read-only", BashTool().is_read_only(dangerous), False)
    check("a read-only command still is", BashTool().is_read_only({"command": "ls -la"}), True)


def integration_case() -> None:
    print("integration — the patched provider on a real response shape")
    try:
        from open_agent_sdk.providers.openai_provider import OpenAIProvider
    except Exception as exc:
        print(f"  SKIP  OpenAIProvider unavailable ({exc})")
        return

    check("patch installs", install_tool_input_normalisation(), True)
    check("patch is idempotent", install_tool_input_normalisation(), True)

    # The exact shape deepseek sent: arguments double-encoded, so the SDK's own
    # json.loads returns a str and the block reaches the tools as a string.
    response = {
        "choices": [{
            "finish_reason": "tool_calls",
            "message": {
                "content": None,
                "tool_calls": [{
                    "id": "call_1",
                    "function": {"name": "Bash",
                                 "arguments": json.dumps(json.dumps({"command": "ls"}))},
                }],
            },
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 2},
    }
    provider = OpenAIProvider.__new__(OpenAIProvider)
    converted = OpenAIProvider._convert_response(provider, response)
    blocks = [b for b in converted.content if isinstance(b, dict) and b.get("type") == "tool_use"]
    check("one tool_use block", len(blocks), 1)
    check("input is a dict, not a str", type(blocks[0]["input"]).__name__, "dict")
    check("input decoded correctly", blocks[0]["input"], {"command": "ls"})

    # And the crash itself no longer reproduces.
    try:
        from open_agent_sdk.tools.bash import BashTool
        BashTool().is_read_only(blocks[0]["input"])
        print("  PASS  is_read_only() no longer raises AttributeError")
    except AttributeError as exc:
        print(f"  FAIL  still raises: {exc}")
        failures.append("is_read_only raises")


def main() -> int:
    normalisation_cases()
    safety_case()
    integration_case()
    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("all tool-input checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

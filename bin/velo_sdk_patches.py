"""Runtime corrections to `open_agent_sdk` that must apply before any tool runs.

Kept here rather than edited into `site-packages` so the fix survives a venv
rebuild and is reviewable in this repo. Each patch states the failure it
prevents; that is the bar for adding one.
"""
from __future__ import annotations

import json
import sys
from typing import Any

_MAX_DECODE_DEPTH = 3


def normalise_tool_input(raw: Any, *, on_drop=None) -> dict[str, Any]:
    """Coerce a provider's tool-call `arguments` into the dict the SDK assumes.

    `open_agent_sdk` types a tool-use block's `input` as `dict[str, Any] | None`
    and never enforces it. Two paths in `providers/openai_provider.py` hand a
    `str` downstream instead, and the first tool method to call `.get()` on it
    dies with `AttributeError: 'str' object has no attribute 'get'` — killing the
    run mid-flight, after arbitrary spend, with no commits. One dispatch burned
    9.9M input tokens that way (#2010).

    The two paths differ, and only one is the obvious one:

    1. `openai_provider.py:245` — the `except` branch assigns the raw string
       verbatim when `json.loads` fails. Violates the declared type by design.
    2. **Double-encoded arguments** — the provider JSON-encodes the argument
       string a second time, so `json.loads` *succeeds* and returns a `str`.
       No exception is raised and nothing downstream checks the type. This is
       the silent path, and it is why "the SDK does not parse arguments" is not
       an accurate description of the bug: it parses, then hands back a string.

    So: decode repeatedly while the result is still a string, and fail CLOSED —
    anything that will not resolve to a dict becomes `{}` rather than being
    passed to a tool. A tool receiving `{}` does nothing; a tool receiving a
    half-decoded string is how a command gets misread.
    """
    value = raw
    for _ in range(_MAX_DECODE_DEPTH):
        if isinstance(value, dict):
            return value
        if not isinstance(value, str):
            break
        try:
            value = json.loads(value)
        except (json.JSONDecodeError, TypeError, ValueError):
            break

    if isinstance(value, dict):
        return value
    if raw is None or raw == "" or raw == {}:
        return {}
    if on_drop is not None:
        on_drop(raw)
    return {}


def install_tool_input_normalisation(logger=None) -> bool:
    """Wrap `OpenAIProvider._convert_response` so `input` is always a dict.

    Patched at the DECODE point — one function — rather than at the three
    consumption sites in `engine.py`/`tools/*`. Those three are reached through
    methods that every concrete tool overrides, so covering them means wrapping
    every tool class; normalising once where the provider response is turned
    into content blocks fixes every tool and every future consumer.

    Returns True if the patch was applied. Never raises: a failure here must not
    take down a dispatch that would otherwise have run.
    """
    def _log(msg: str) -> None:
        if logger is not None:
            logger.emit(msg)
        else:
            print(msg, file=sys.stderr, flush=True)

    try:
        from open_agent_sdk.providers.openai_provider import OpenAIProvider
    except Exception as exc:  # pragma: no cover - SDK layout may move
        _log(f"WARNING velo-patch: could not import OpenAIProvider ({exc}); "
             "string tool inputs will crash the run — see #2010")
        return False

    if getattr(OpenAIProvider, "_velo_tool_input_patched", False):
        return True

    original = OpenAIProvider._convert_response

    def patched(self, data: dict[str, Any]):
        response = original(self, data)
        for block in getattr(response, "content", None) or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            raw = block.get("input")
            if isinstance(raw, dict):
                continue
            def _dropped(value, name=block.get("name", "?")):
                _log(f"WARNING velo-patch: tool '{name}' input could not be decoded "
                     f"to an object ({type(value).__name__}); passing {{}} — see #2010")
            block["input"] = normalise_tool_input(raw, on_drop=_dropped)
        return response

    patched._velo_wraps = original
    OpenAIProvider._convert_response = patched
    OpenAIProvider._velo_tool_input_patched = True
    return True

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

# Preferred provider endpoints, cheapest-first, per model (#2007 F1).
#
# OpenRouter load-balances each request across endpoints and a prefix cache is
# per-endpoint. Three single-shot probe calls landed on Morph, Relace and
# OpenInference with cached=0 and a 2.7x cost spread, so bouncing genuinely does
# prevent a cache from warming.
#
# BUT the benefit of pinning is NOT the 4.4x that probe suggested. That figure
# compared a cold call to a warm one and credited the pin. Measured end-to-end
# through the runner, three runs of one task:
#
#   1 pinned   (cold)  cached 65.5%  $0.000743
#   2 unpinned (warm)  cached 98.2%  $0.000460
#   3 pinned   (warm)  cached 98.7%  $0.000353
#
# Warmth dominates; the runner's prefix warms up either way. What pinning
# actually buys at steady state is the CHEAPER ENDPOINT — ~23% here, consistent
# with Relace at $0.045/M against the ~$0.05-0.065 the balancer picks. Worth
# doing on price; not the headline the probe implied.
#
# Ordered preference WITH fallbacks, deliberately — `allow_fallbacks: false`
# trades availability for cache locality, and a failed dispatch costs more than
# an occasional cold miss. Prices are $/M input, from
# GET /api/v1/models/:model/endpoints on 2026-09-06.
PROVIDER_ORDER: dict[str, list[str]] = {
    # 29 endpoints; Relace is both the cheapest ($0.045 vs $0.065 list) and the
    # one the cache probe confirmed.
    "deepseek/deepseek-v4-flash-0731": ["Relace", "Baidu", "OpenInference"],
    # v4.1-flash: 96% of input tokens are cache READS across 368 recorded runs, so the cache-read
    # price decides the bill. Modelled on that mix: Baidu $22, DeepInfra $48, median provider $107
    # (billed $94 unpinned). Ordered with fallbacks, as above.
    "deepseek/deepseek-v4.1-flash": ["Baidu", "DeepInfra"],
    # 23 endpoints, four tied at $0.075. Z.AI is the model's own vendor.
    "z-ai/glm-5.3-flash": ["Z.AI", "DeepInfra", "Novita"],
}


def provider_order_for(model: str) -> list[str]:
    """Preferred endpoints for a model, or [] to let OpenRouter choose.

    `VELO_PROVIDER_ORDER` overrides (comma-separated) so a pin can be changed or
    disabled without a code edit — set it empty to restore load-balancing.
    """
    import os
    override = os.environ.get("VELO_PROVIDER_ORDER")
    if override is not None:
        return [p.strip() for p in override.split(",") if p.strip()]
    return PROVIDER_ORDER.get(model, [])


class UsageLedger:
    """Real billed usage, accumulated out-of-band from the SDK's own accounting.

    The SDK types `CreateMessageResponse.usage` as `dict[str, int]` with four
    fixed keys and computes cost from its own price table, so OpenRouter's real
    `cost` float has nowhere to ride. Rather than change three SDK files, the
    provider patch accumulates it here and the runner reads it at TOTALS time.
    """

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.input_tokens = 0
        self.output_tokens = 0
        self.cached_tokens = 0
        self.cost_usd = 0.0
        self.calls = 0
        self.saw_real_cost = False

    def add(self, *, prompt: int, completion: int, cached: int, cost) -> None:
        self.input_tokens += prompt
        self.output_tokens += completion
        self.cached_tokens += cached
        self.calls += 1
        if cost is not None:
            self.cost_usd += float(cost)
            self.saw_real_cost = True


LEDGER = UsageLedger()


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

        # --- real usage (#2007 F2) -------------------------------------------
        # `_convert_response` reads prompt/completion tokens and then hardcodes
        # both cache fields to 0, so `cached_tokens` was 0 in every record — an
        # observability hole, not an absent cache. Read them properly here.
        try:
            usage_data = (data or {}).get("usage") or {}
            details = usage_data.get("prompt_tokens_details") or {}
            cached = int(details.get("cached_tokens", 0) or 0)
            prompt = int(usage_data.get("prompt_tokens", 0) or 0)
            completion = int(usage_data.get("completion_tokens", 0) or 0)
            LEDGER.add(prompt=prompt, completion=completion, cached=cached,
                       cost=usage_data.get("cost"))
            if isinstance(getattr(response, "usage", None), dict):
                # OpenAI-style `prompt_tokens` INCLUDES cached tokens; the
                # Anthropic-shaped field the SDK fills EXCLUDES them. Subtract,
                # or every cached token is counted twice and charged at 110%.
                response.usage["input_tokens"] = max(prompt - cached, 0)
                response.usage["cache_read_input_tokens"] = cached
        except Exception as exc:  # never let telemetry kill a run
            _log(f"WARNING velo-patch: usage extraction failed ({exc})")

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


def install_provider_pinning(model: str, logger=None) -> list[str]:
    """Pin the provider endpoint and ask OpenRouter for real usage (#2007 F1/F2).

    Two fields on the request body, both absent before:

    - `provider.order` — OpenRouter load-balances each request across endpoints
      and a prefix cache is per-endpoint, so an agent loop that re-sends its
      whole transcript every turn missed the cache on every single turn. Input
      scales quadratically with turns, so this is the dominant cost.
    - `usage.include` — without it the response carries no real `cost` and no
      `prompt_tokens_details`, which is why cache hits were invisible.

    `allow_fallbacks` stays TRUE: a pin that cannot fail over turns a cold cache
    into a failed dispatch, which costs far more than the miss.

    Returns the order applied ([] if none). Never raises.
    """
    def _log(msg: str) -> None:
        if logger is not None:
            logger.emit(msg)
        else:
            print(msg, file=sys.stderr, flush=True)

    try:
        from open_agent_sdk.providers.openai_provider import OpenAIProvider
    except Exception as exc:  # pragma: no cover
        _log(f"WARNING velo-patch: no OpenAIProvider ({exc}); provider not pinned")
        return []

    if getattr(OpenAIProvider, "_velo_provider_patched", False):
        return provider_order_for(model)

    order = provider_order_for(model)

    # The body is built inside create_message, so wrap the POST — the one place
    # every request passes through with the finished body in hand.
    original_post = OpenAIProvider._post_chat_completions

    async def patched_post(self, body: dict[str, Any]):
        try:
            body.setdefault("usage", {"include": True})
            if order:
                body.setdefault("provider", {"order": list(order),
                                             "allow_fallbacks": True})
        except Exception as exc:  # a malformed body must not break the call
            _log(f"WARNING velo-patch: could not set provider/usage ({exc})")
        return await original_post(self, body)

    OpenAIProvider._post_chat_completions = patched_post
    OpenAIProvider._velo_provider_patched = True
    _log(f"velo-patch: provider order={order or 'unpinned'} usage.include=true")
    return order


# Real context windows, from GET /api/v1/models/:model/endpoints (2026-09-06).
# The SDK's table holds only Anthropic/OpenAI names and prefix-matches, so every
# worker model missed and took DEFAULT_CONTEXT_WINDOW = 200_000 — roughly 5x too
# small, tripping the 187k auto-compact threshold with enormous headroom left.
CONTEXT_WINDOWS: dict[str, int] = {
    "deepseek/deepseek-v4-flash-0731": 1_048_576,
    "deepseek/deepseek-v4.1-flash": 1_048_576,
    "deepseek/deepseek-v4.1-flash-1017": 1_048_576,
    "xiaomi/mimo-v2.6-flash": 1_048_576,
    "nvidia/nemotron-3-ultra-550b-a55b:free": 1_000_000,
    "z-ai/glm-5.3-flash": 1_048_576,
}


def install_context_windows(logger=None) -> bool:
    """Teach the SDK our models' real context windows (#2007 F4).

    This is the ONLY half of the compaction problem worth fixing, and the reason
    is worth stating plainly: **the SDK's compactor must not be repaired.**

    Three defects stack in `utils/compact.py`:

    1. the window lookup misses every worker model and defaults to 200_000, so
       the threshold trips ~5x too early;
    2. `compact.py:68` calls `client.messages.create` — an ANTHROPIC client —
       against an OpenAI-compatible base URL, so the call always fails;
    3. `compact.py:113` swallows that with a bare `except` and stops trying after
       three consecutive failures.

    The obvious fix is to route (2) through `config.provider`. Do not. A
    SUCCEEDING compaction (`compact.py:80-99`) discards the entire conversation
    and replaces it with two synthetic messages — every tool result, every file
    the worker read, and the tool_use/tool_result pairing along with it. At a
    threshold 5x too low that is mid-run context destruction, and today's silent
    no-op is strictly safer.

    So: correct the window, which stops the misfiring, the wasted failed
    round-trips and the false `COMPACT_BOUNDARY` event that `engine.py:208`
    yields unconditionally even when nothing was compacted. Leave the call
    broken, deliberately, until there is a compactor worth enabling.
    """
    def _log(msg: str) -> None:
        if logger is not None:
            logger.emit(msg)
        else:
            print(msg, file=sys.stderr, flush=True)

    try:
        from open_agent_sdk.utils import tokens as _tokens
    except Exception as exc:  # pragma: no cover
        _log(f"WARNING velo-patch: no tokens module ({exc}); context windows unset")
        return False

    try:
        _tokens._CONTEXT_WINDOWS.update(CONTEXT_WINDOWS)
        _log(f"velo-patch: registered {len(CONTEXT_WINDOWS)} real context windows")
        return True
    except Exception as exc:
        _log(f"WARNING velo-patch: could not register context windows ({exc})")
        return False


def turn_budget_notice(max_turns: int) -> str:
    """A turn budget the worker can actually see (#2007 F5).

    The runner knows `--max-turns`; the worker was told only by whatever the
    brief author happened to write. A review run once spent 60 of 60 turns
    exploring and returned 332 characters — no report at all — because hitting
    the cap exits through `ERROR_MAX_TURNS` and the result text is just the last
    assistant message.

    Honesty about the evidence: that run was ALSO given a larger cap when the
    budget text was added, so the improvement is not attributable to this text
    alone. The mechanism stands on its own — an agent that does not know its
    budget cannot reserve any of it — but this is a reasoned change, not a
    measured one.
    """
    reserve = 2 if max_turns <= 40 else 4
    deadline = max(1, max_turns - reserve)
    return (
        f"\n\n=== TURN BUDGET ===\n"
        f"You have {max_turns} tool-use turns in this segment and the run is KILLED\n"
        f"at the limit — a run that spends every turn exploring returns nothing,\n"
        f"which is worth nothing to anyone.\n\n"
        f"Deliver your result by turn {deadline}, whatever state your work is in.\n"
        f"Reserve the last {reserve} turns for committing and reporting. A short\n"
        f"report naming what you actually verified beats an exhausted budget and\n"
        f"silence; mark anything you ran out of time to check as UNVERIFIED —\n"
        f"that is a useful result, silence is not.\n"
        f"=== END TURN BUDGET ===\n"
    )

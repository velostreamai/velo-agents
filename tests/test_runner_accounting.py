#!/usr/bin/env python3
"""Accounting invariants for the SDK runners (#1992).

Every case here is a defect that ALREADY SHIPPED once and passed inspection.
They are pinned deterministically against a synthetic event stream rather than
by running a real model, because two attempts to reproduce a mid-flight death by
tuning timeouts both completed inside the window instead of dying in it — timing
tests could not have caught these, and the double-count case has no timing
expression at all.

Run:  .agents/tests/run.sh          (or: python3 .agents/tests/test_runner_accounting.py)
Needs the venv that has open_agent_sdk; run.sh finds it.
"""
from __future__ import annotations

import asyncio
import importlib.util
import pathlib
import sys

from open_agent_sdk.types import SDKMessage, SDKMessageType, TokenUsage

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"

failures: list[str] = []


def load(name: str):
    """Import a runner by path — the filenames are not importable module names."""
    path = BIN / name
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    # dataclass() resolves __module__ through sys.modules, so register first.
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def check(label: str, got, want) -> None:
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        failures.append(label)


class Logger:
    path = pathlib.Path("/dev/null")

    def emit(self, message: str) -> None:  # noqa: D102
        pass


class Agent:
    """Replays a fixed event list, optionally dying part-way through."""

    def __init__(self, events, die_after: int | None = None):
        self.events, self.die_after = events, die_after

    async def query(self, prompt):
        for n, event in enumerate(self.events):
            if self.die_after is not None and n == self.die_after:
                raise RuntimeError("402 Payment Required (simulated mid-flight death)")
            yield event


def assistant(inp=0, out=0, text="") -> SDKMessage:
    return SDKMessage(
        type=SDKMessageType.ASSISTANT,
        text=text,
        usage=TokenUsage(input_tokens=inp, output_tokens=out),
    )


def result(inp=0, out=0, cost=0.0, text="done") -> SDKMessage:
    return SDKMessage(
        type=SDKMessageType.RESULT,
        text=text,
        num_turns=1,
        total_usage=TokenUsage(input_tokens=inp, output_tokens=out),
        total_cost=cost,
    )


LEAK_TEXT = '<invoke name="Bash">'


async def usage_cases(m) -> None:
    print("usage accounting")

    # Tokens spent before a 402 or a timeout were really spent. Recording zero
    # for them biases every cost comparison towards whichever worker fails most.
    out = m.PromptOutcome()
    try:
        await m.collect_prompt_events(Agent([assistant(100, 10)] * 5, die_after=3), "t", Logger(), "A", out)
    except RuntimeError:
        pass
    check("mid-flight death keeps partial tokens", (out.input_tokens, out.output_tokens), (300, 30))
    check("mid-flight death is labelled partial", out.usage_source, "sdk-partial")

    # RESULT.total_usage is CUMULATIVE for the prompt, so it must REPLACE the
    # per-message tally. Adding instead would silently double every complete run.
    out = m.PromptOutcome()
    await m.collect_prompt_events(Agent([assistant(100, 10)] * 3 + [result(300, 30, 0.5)]), "t", Logger(), "B", out)
    check("RESULT replaces rather than adds", out.input_tokens, 300)
    check("complete run is labelled sdk", out.usage_source, "sdk")

    # A provider that reports nothing must stay "unavailable". A fabricated zero
    # is worse than a null: it gets averaged.
    out = m.PromptOutcome()
    await m.collect_prompt_events(Agent([assistant()]), "t", Logger(), "C", out)
    check("no usage reported stays unavailable", out.usage_source, "unavailable")


async def leak_cases(m) -> None:
    print("leaked-tool-call accounting")

    # Was added after prompt 1 AND after the loop. On the single-prompt path the
    # loop breaks before reassigning `result`, so this counted twice.
    state = m.RunState(initial_snapshot="x")
    out = m.PromptOutcome()
    await m.collect_prompt_events(Agent([assistant(text=LEAK_TEXT), result()]), "t", Logger(), "p1", out)
    state.absorb(out)
    check("single prompt counts its leaks once", state.leaked_tool_calls, out.leaked_tool_calls)

    # The mirror defect: only the FINAL result reached the second add, so leaks
    # in any intermediate continuation were dropped entirely.
    state = m.RunState(initial_snapshot="x")
    for events in ([result()], [assistant(text=LEAK_TEXT), result()], [result()]):
        outcome = m.PromptOutcome()
        await m.collect_prompt_events(Agent(events), "t", Logger(), "p", outcome)
        state.absorb(outcome)
    check("a middle continuation's leaks survive", state.leaked_tool_calls, 1)


def pricing_cases(openrouter, lmstudio) -> None:
    print("cost provenance")

    # Prefix matching answered "is there a vendor model named like this", which
    # is not the question. `deepseek-chat-v3-0324-mlx` is an ordinary LM Studio
    # id and was priced off the `deepseek-chat` key; `g` matched `gpt-4o`.
    for spurious in ("deepseek-chat-v3-0324-mlx", "qwen", "g", "gpt-4o-local-copy"):
        check(f"openrouter does not price {spurious!r}", openrouter.model_is_priced(spurious), False)
    check("openrouter still prices an exact key", openrouter.model_is_priced("gpt-4o"), True)

    # Provenance is a property of the PROVIDER. Nobody bills for a locally
    # served model whatever it calls itself, so no name can earn a price here.
    for any_name in ("gpt-4o", "deepseek-chat", "qwen3-coder-next-mlx@6bit"):
        check(f"lmstudio never prices {any_name!r}", lmstudio.model_is_priced(any_name), False)


async def main() -> int:
    # Both shims share one implementation now (#2007 F7); the profile is what
    # differs, so load the body once and swap the profile between assertions.
    runner = load("velo_worker_runner.py")

    class _Profile:
        """A profile-pinned view. Sets the global on EVERY attribute access, so
        correctness does not depend on assertion order — the previous version
        left the module on whichever profile ran last, and moving one check
        would have silently run it under the wrong profile (#2018 F7)."""
        def __init__(self, name): self._name = name
        def __getattr__(self, attr):
            runner.PROVIDER = runner.PROVIDERS[self._name]
            return getattr(runner, attr)

    openrouter = _Profile("openrouter")
    lmstudio = _Profile("lmstudio")

    await usage_cases(openrouter)
    await leak_cases(openrouter)
    pricing_cases(openrouter, lmstudio)

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("all accounting checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

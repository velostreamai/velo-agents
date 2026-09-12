#!/usr/bin/env python3
"""Worker runner on `openai-agents`, CLI- and log-compatible with the incumbent.

WHY A SECOND RUNNER RATHER THAN A REFACTOR

Measured on an 18-turn audit task, 3 rounds each, same model, same gateway, same
provider pin, same tools including zg:

    correctness   3/3 both
    cost/run      ours $0.00502   theirs $0.00291    theirs 1.73x cheaper
    wall clock    ours 228s       theirs 54s         theirs 4.2x faster
    tool calls    ours 14         theirs 17

Our one win, fewer tool calls, converts to nothing. And 94-99% of our wall clock
is model wait, not tool execution, so it is not a tools problem.

The incumbent runner is 1,260 working lines coupled to its SDK at 9 points.
Refactoring it behind an abstraction risks a system that works today, for an
outcome nobody has committed to. A second runner behind the SAME CLI lets the
wrapper pick with one env var, and switching back is unsetting it.

The cost of that choice is two runners while both exist. That is deliberate and
temporary: whichever loses gets deleted, not maintained.

PARITY IS THE POINT. Identical CLI flags, identical log lines, identical TOTALS,
so `velo-record`, the gate scripts and every existing test read both without
changes — and so a comparison between them measures the runtimes rather than two
different reporting conventions.

TOOL LOGGING. `RunHooks.on_tool_start` receives (context, agent, tool) and NOT
the arguments, which is the exact gap velostream#2074 closed on our side. The
arguments are instead taken from `on_llm_end`, whose ModelResponse carries
ResponseFunctionToolCall with `name` and `arguments` — the same place our SDK
reads them. Without that, an audit of where a run went wrong can see only that a
tool ran, never what it was asked, which is how a broken Grep stayed invisible
for months.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from agents import (  # noqa: E402
    Agent, ModelSettings, OpenAIChatCompletionsModel, RunConfig, RunHooks,
    Runner, ToolExecutionConfig, set_tracing_disabled,
)
from agents.exceptions import MaxTurnsExceeded  # noqa: E402
from openai import AsyncOpenAI  # noqa: E402

import velo_oai_tools as T  # noqa: E402
# From the SHARED module, not from velo_worker_runner — importing that pulls in
# `open_agent_sdk`, which is not installed on this runtime's venv, and would
# couple the supported runner to the one being retired.
from velo_skills import apply_skills  # noqa: E402
# Salvage is SDK-agnostic — pure git plus a transcript dump — so both runtimes
# share ONE implementation rather than each growing its own half-working copy.
from velo_runner_lib import salvage_on_failure  # noqa: E402

set_tracing_disabled(True)

# Same pin as the incumbent (velo_sdk_patches.PROVIDER_ORDER). Without it
# OpenRouter load-balances every request and the per-endpoint prefix cache misses
# on EVERY turn — measured 0 cached tokens unpinned vs a full hit pinned.
# Per-model output budget. 8000 is the incumbent's default and is NOT enough for
# a reasoning model: GLM spent its budget on reasoning, emitted 318 visible tokens
# and nothing usable, and openai-agents raised
#
#   ModelBehaviorError: ... finish_reason='length' but produced no assistant text,
#   tool call, or refusal
#
# which KILLS the run. The incumbent survives this: on stop_reason == "max_tokens"
# it appends "Continue from where you left off." and grants another turn, up to 3
# times (engine.py MAX_OUTPUT_RECOVERY_ATTEMPTS). openai-agents has no equivalent
# — the exception escapes Runner.run with the conversation gone, so there is
# nothing to continue FROM and a retry would restart the task.
#
# Headroom is therefore the only defence available here, and it must be set per
# model rather than globally: paying for a 32k output budget on a non-reasoning
# model is waste.
# Reasoning models need SIX FIGURES, not the 8000 the incumbent defaults to.
# GLM burned 8000 producing 318 visible tokens — the rest went to reasoning — and
# 32000 was still not enough. Without recovery, headroom is the only defence, and
# under-budgeting does not degrade a run, it KILLS it after arbitrary spend: the
# first failure cost $0.0072 and produced nothing.
#
# Over-budgeting costs nothing by itself. max_tokens is a CEILING, not a
# reservation — unused output is not billed. So the asymmetry is total: too low
# loses the whole run, too high loses nothing.
MAX_TOKENS_BY_MODEL = {
    "z-ai/glm-5.3-flash": 131072,
    "deepseek/deepseek-v4-flash-0731": 65536,
}
# Applies to any model not named above. Deliberately generous for the same reason.
DEFAULT_MAX_TOKENS = 65536

PROVIDER_ORDER = {
    "deepseek/deepseek-v4-flash-0731": ["Relace", "Baidu", "OpenInference"],
    "z-ai/glm-5.3-flash": ["Z.AI", "DeepInfra", "Novita"],
}


def summarise_tool_input(raw) -> str:
    """One line of arguments, safe to keep. Mirrors velostream#2074 exactly.

    Bulk content elided with its size, identifying params kept, secrets redacted,
    newlines escaped so one event stays one line.
    """
    import re
    ELIDE = {"content", "new_string", "old_string", "text"}
    SECRET_KEY = ("key", "token", "secret", "password", "passwd", "auth", "credential")
    SECRET_VAL = re.compile(r"(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}"
                            r"|AKIA[0-9A-Z]{12,}|xox[abpsr]-[A-Za-z0-9-]{10,})")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except (TypeError, ValueError):
            return ""
    if not isinstance(raw, dict) or not raw:
        return ""
    parts = []
    for k, v in raw.items():
        low = str(k).lower()
        if low in ELIDE and isinstance(v, str):
            parts.append(f"{k}=[{len(v)} chars]"); continue
        if any(s in low for s in SECRET_KEY):
            parts.append(f"{k}=[redacted]"); continue
        r = v if isinstance(v, str) else repr(v)
        r = SECRET_VAL.sub("[redacted]", r).replace("\n", "\\n").replace("\r", "")
        if len(r) > 160:
            r = r[:160] + f"…[+{len(r)-160} chars]"
        parts.append(f'{k}="{r}"' if isinstance(v, str) else f"{k}={r}")
    line = ", ".join(parts)
    return line[:400] + "…" if len(line) > 400 else line


class Logger:
    def __init__(self, path: str | None):
        self.fh = open(path, "a", encoding="utf-8") if path else None

    def emit(self, msg: str) -> None:
        line = f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}.000Z {msg}"
        print(line, flush=True)
        if self.fh:
            self.fh.write(line + "\n"); self.fh.flush()


class BudgetExceeded(Exception):
    """Raised from the usage hook to stop a run that has spent its budget.

    Raised rather than flagged, because there is no cooperative stopping point:
    `Runner.run` owns the loop, and a flag would only be noticed after however
    many further turns it chose to take. The incumbent checks
    `self._total_cost >= config.max_budget_usd` at the top of each of its own
    turns (engine.py:207) and returns ERROR_MAX_BUDGET; this is the equivalent at
    the only point this runtime hands control back.
    """


class Hooks(RunHooks):
    """Emits the incumbent's log lines, and accumulates usage per LLM call.

    Usage comes from the hook rather than the run result because
    `Runner.run` raises on max_turns with NO result — so reading usage off the
    return value loses every token for exactly the runs that burned the most.
    """

    def __init__(self, logger: Logger, label: str, max_budget_usd: float | None = None):
        self.log, self.label = logger, label
        self.max_budget_usd = max_budget_usd
        self.inp = self.out = self.cached = self.turns = 0
        self.cost = 0.0
        # Accumulated here because `Runner.run` RAISES on max_turns and on a
        # model error, and the conversation goes with it — there is no result
        # object to read afterwards. The incumbent could reach
        # `agent._engine.messages` in memory at the moment it was killed; this
        # is the equivalent, and the only chance anyone gets at these turns.
        self.transcript: list[dict] = []

    async def on_llm_end(self, context, agent, response) -> None:
        self.turns += 1
        u = getattr(response, "usage", None)
        if u:
            self.inp += getattr(u, "input_tokens", 0) or 0
            self.out += getattr(u, "output_tokens", 0) or 0
            d = getattr(u, "input_tokens_details", None)
            if d:
                self.cached += getattr(d, "cached_tokens", 0) or 0
        for item in (getattr(response, "output", None) or []):
            self.transcript.append({
                "turn": self.turns,
                "type": getattr(item, "type", "?"),
                "name": getattr(item, "name", None),
                "arguments": getattr(item, "arguments", None),
                "text": getattr(item, "content", None) and str(item.content)[:4000],
            })
        calls = [o for o in (getattr(response, "output", None) or [])
                 if getattr(o, "type", "") == "function_call"]
        if calls:
            names = ",".join(getattr(c, "name", "?") for c in calls)
            detail = "  ".join(
                f"{getattr(c,'name','?')}({summarise_tool_input(getattr(c,'arguments',None))})"
                for c in calls)
            self.log.emit(f"[{self.label}] tool start names={names} | {detail}")
        else:
            self.log.emit(f"[{self.label}] sdk assistant text_len=0")

        # LAST, deliberately. Raising before the usage and transcript are
        # recorded threw away the very turn salvage exists to preserve: the first
        # live test reported `no in-memory transcript to dump` and
        # `input_tokens=0` on a run that had plainly spent money. A stop that
        # discards the evidence of why it stopped is worse than no stop.
        #
        # Checked after a call that is already billed, so the budget is a ceiling
        # on what gets STARTED, not a guarantee of the final total — one turn's
        # spend can cross it. Stated plainly so nobody reads it as a hard cap.
        spent = hooks_ref["cost"]
        if self.max_budget_usd is not None and spent >= self.max_budget_usd:
            self.log.emit(f"[{self.label}] BUDGET EXHAUSTED spent=${spent:.6f} "
                          f"limit=${self.max_budget_usd:.6f} — stopping")
            raise BudgetExceeded(f"spent ${spent:.6f} of ${self.max_budget_usd:.6f}")

    async def on_tool_end(self, context, agent, tool, result) -> None:
        body = result if isinstance(result, str) else str(result)
        self.transcript.append({
            "turn": self.turns, "type": "tool_result",
            "name": getattr(tool, "name", "unknown"),
            "text": body[:4000],
        })
        # Our tools report failure in the RESULT TEXT rather than by raising, so
        # outcome must be derived from it — otherwise every call reads as ok and
        # the error rate, which is what an audit is looking for, is invisible.
        bad = body.startswith(("Error", "Search failed")) or "failed (exit" in body[:60]
        self.log.emit(f"[{self.label}] tool completed name={getattr(tool,'name','unknown')} "
                      f"outcome={'error' if bad else 'ok'} result_len={len(body)}")


def task_is_read_only(task: str) -> bool:
    t = task.lower()
    return "read-only" in t or "read only" in t


hooks_ref: dict = {"cost": 0.0}


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--task", required=True)
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--max-turns", type=int, default=100)
    ap.add_argument("--prompt-timeout", type=float, default=2400)
    ap.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    ap.add_argument("--bash-timeout-ms", type=int, default=2_400_000)
    ap.add_argument("--log-file", default=None)
    ap.add_argument("--max-budget-usd", type=float, default=None,
                    help="Stop the run once billed spend reaches this. Unattended "
                         "runs had NO ceiling on this runtime.")
    ap.add_argument("--base-url", default="https://openrouter.ai/api/v1")
    ap.add_argument("--skill", action="append", default=[],
                    help="Inline a skill definition ahead of the task (repeatable).")
    a = ap.parse_args()

    log = Logger(a.log_file)
    T.set_cwd(a.cwd)
    T.DEFAULT_BASH_TIMEOUT_S = max(1, a.bash_timeout_ms // 1000)
    policy = pathlib.Path(a.policy).read_text(encoding="utf-8")
    task = apply_skills(a.task, a.skill)
    # Classified AFTER inlining: the review skills carry the read-only
    # declaration, and a gate that writes is a gate that has already gone wrong.
    read_only = task_is_read_only(task)

    system = (
        f"You are a full autonomous Velostream implementation worker.\n\n"
        f"MODEL:\n{a.model}\n\nWORKTREE:\n{a.cwd}\n\n"
        "You operate only inside the assigned Velostream worktree.\n\n"
        "The following Velostream implementation policy is authoritative and mandatory:\n\n"
        f"================ VELO-IMPL POLICY ================\n{policy}\n"
        "================ END VELO-IMPL POLICY ============\n"
    )
    budget = (
        f"\n\n=== TURN BUDGET ===\nYou have {a.max_turns} tool-use turns and the run is "
        f"KILLED at the limit — a run that spends every turn exploring returns nothing.\n"
        f"Deliver your result by turn {max(1, a.max_turns - 4)}, whatever state your work is in.\n"
    )

    # An OpenRouter key is required for OpenRouter and meaningless for a local
    # LM Studio endpoint, which accepts any non-empty string. Demanding one there
    # would make the local route unrunnable for the wrong reason.
    is_gateway = "openrouter.ai" in a.base_url
    if is_gateway:
        key = os.environ.get("OPENROUTER_API_KEY") or os.environ.get("CODEANY_API_KEY")
        if not key:
            print("ERROR: OPENROUTER_API_KEY is not set", file=sys.stderr)
            return 1
    else:
        key = os.environ.get("LM_STUDIO_API_KEY") or "lm-studio"

    client = AsyncOpenAI(base_url=a.base_url, api_key=key)

    # OpenRouter's BILLED cost, read off the raw response. NOT computed from token
    # counts: fitting $/token against 53 billed observations gave a median error of
    # 48%, so a linear price model does not describe this endpoint. The incumbent
    # logs the gateway's own figure, and a comparison between the two runners is
    # meaningless unless both read the same field.
    _inner = client.chat.completions.create

    async def _with_cost(*args, **kw):
        resp = await _inner(*args, **kw)
        u = getattr(resp, "usage", None)
        extra = getattr(u, "model_extra", None) or {}
        c = extra.get("cost", getattr(u, "cost", None))
        if c:
            hooks_ref["cost"] += float(c)
        return resp

    client.chat.completions.create = _with_cost
    tools = T.READ_ONLY_TOOLS if read_only else T.ALL_TOOLS
    agent = Agent(
        name="velo-worker",
        instructions=system,
        model=OpenAIChatCompletionsModel(model=a.model, openai_client=client),
        tools=tools,
        model_settings=ModelSettings(
            parallel_tool_calls=True,
            max_tokens=MAX_TOKENS_BY_MODEL.get(a.model, a.max_tokens),
            # provider.order and usage.include are OpenRouter fields. A plain
            # OpenAI-compatible server rejects unknown body keys, so sending them
            # to LM Studio breaks every request (cf. openai-agents#4326, where
            # parallel_tool_calls sent to Azure did exactly that).
            extra_body=({"provider": {"order": PROVIDER_ORDER.get(a.model, []),
                                      "allow_fallbacks": True},
                         "usage": {"include": True}} if is_gateway else {})),
    )

    if a.max_budget_usd is not None and a.max_budget_usd <= 0:
        print("ERROR: --max-budget-usd must be > 0", file=sys.stderr)
        return 1
    hooks = Hooks(log, "prompt 1", max_budget_usd=a.max_budget_usd)
    hooks_ref["obj"] = hooks
    log.emit("[prompt 1] sdk system event=init")
    log.emit(f"[prompt 1] start timeout_seconds={a.prompt_timeout:.0f} "
             f"backend=openai-agents tools={len(tools)} read_only={str(read_only).lower()}")

    t0 = time.time()
    status, text = "success", ""
    try:
        # tool_not_found_behavior: a model that improvises a tool name kills the
        # whole run under the default 'raise_error'. For an unattended worker the
        # error belongs back in the model's lap so it can recover.
        cfg = RunConfig(tool_not_found_behavior="return_error_to_model",
                        tool_execution=ToolExecutionConfig(max_function_tool_concurrency=6))
        res = await asyncio.wait_for(
            Runner.run(agent, task + budget, max_turns=a.max_turns,
                       run_config=cfg, hooks=hooks),
            timeout=a.prompt_timeout)
        text = str(res.final_output or "")
    except MaxTurnsExceeded:
        status = "error_max_turns"
    except BudgetExceeded as exc:
        status, text = "error_max_budget", str(exc)
    except asyncio.TimeoutError:
        status = "error_timeout"
    except Exception as exc:  # surfaced, never swallowed
        status, text = "error_during_execution", f"{type(exc).__name__}: {exc}"
        if "finish_reason='length'" in str(exc):
            # Name the cause and the lever. A bare ModelBehaviorError sends the
            # reader looking for a bug in the task, when the model simply ran out
            # of output budget before producing anything.
            status = "error_output_budget"
            text += (f"\n  The model exhausted its output budget "
                     f"({MAX_TOKENS_BY_MODEL.get(a.model, a.max_tokens)} tokens) before emitting "
                     f"any text or tool call. Raise --max-tokens, or add this model to "
                     f"MAX_TOKENS_BY_MODEL. Reasoning models need far more than the 8000 default.")
        log.emit(f"[prompt 1] ERROR {status}: {text}")

    wall = time.time() - t0

    # Salvage on ANY non-success exit. Two runs have lost all their work to a
    # wall-clock timeout, and the defence until now was velo-dispatch refusing a
    # brief that lacked an incremental-commit instruction — the harness ASKING
    # the model to checkpoint. A property you need should be enforced by the
    # system, not requested of it.
    #
    # Demonstrated on this very runtime: a task that completed but was never told
    # to commit left 223 lines of finished work untracked in a worktree, one
    # `worktree remove` away from gone.
    #
    # The adapter exists because salvage reads `agent._engine.messages` — the
    # incumbent's in-memory conversation. openai-agents has no equivalent to
    # reach for after Runner.run has raised, so the hook's accumulated transcript
    # is presented in the same shape. One salvage implementation, two runtimes.
    if status != "success":
        class _TranscriptAdapter:
            class _Engine:
                def __init__(self, messages): self.messages = messages
            def __init__(self, messages): self._engine = self._Engine(messages)

        salvage_on_failure(
            root=a.cwd,
            agent=_TranscriptAdapter(hooks.transcript),
            log_path=a.log_file or f"/tmp/velo-oai-{os.getpid()}.log",
            reason=status,
            read_only=read_only,
            logger=log,
        )

    if text:
        print(text.strip())
    log.emit(f"[prompt 1] sdk result status={status} turns={hooks.turns} text_len={len(text)}")
    log.emit(f"[prompt 1] completed in_seconds={wall:.1f} status={status} final_result=true")

    # input_tokens EXCLUDES cached, matching the incumbent's convention — the two
    # are compared directly, and mixing conventions made a 229k-token run read as 7k.
    fresh = max(hooks.inp - hooks.cached, 0)
    log.emit(
        f"TOTALS prompts=1 leaked_tool_calls=0 "
        f"input_tokens={fresh} output_tokens={hooks.out} cached_tokens={hooks.cached} "
        # A local endpoint bills nothing and reports no cost. Labelling a
        # $0.000000 local run "openrouter-billed" would put a fabricated zero
        # into the cost record and quietly drag every average down — the same
        # class as the `sdk-unpriced` rows already in the history.
        f"cost_usd={hooks_ref['cost']:.6f} "
        f"usage_source={'openrouter-billed' if is_gateway else 'local-unpriced'} "
        f"read_only={str(read_only).lower()}"
    )
    return 0 if status == "success" else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

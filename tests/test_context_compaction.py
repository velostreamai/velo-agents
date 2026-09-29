#!/usr/bin/env python3
"""Context compaction in velo-openai-agents-runner.py (#2291 follow-up).

Decode speed falls with context: a velo-local run on #2291 grew to 120K tokens,
decoded at 15-17 tok/s against ~30 at 15K, and spent 83% of its wall time
decoding. The runner now stubs old tool outputs through the SDK's
call_model_input_filter. These cases pin the three properties that matter:

1. It bounds context: tool output in the prompt stays under the high-water mark.
2. It is STICKY: once stubbed, an output stays stubbed on every later call, so
   the prompt prefix is stable and llama-server's prompt cache keeps hitting. A
   sliding window would re-read the whole context every turn.
3. It keeps the latest outputs intact — the ones the model is working from.

Part 1 exercises the pure function. Part 2 drives the REAL openai-agents run
loop with a scripted model, so the filter's wiring and the SDK's item shape are
tested, not assumed. Part 2 needs the openai-agents venv and skips without it.

Run:  .agents/tests/run.sh   (or: ~/.venvs/velo-openai-agents/bin/python .agents/tests/test_context_compaction.py)
"""
from __future__ import annotations

import ast
import json
import pathlib
import sys

RUNNER = pathlib.Path(__file__).resolve().parent.parent / "bin" / "velo-openai-agents-runner.py"
SRC = RUNNER.read_text()
failures: list[str] = []


def check(label: str, got, want) -> None:
    if got == want:
        print(f"  PASS  {label}: {got}")
    else:
        print(f"  FAIL  {label}: got {got!r}, want {want!r}")
        failures.append(label)


tree = ast.parse(SRC)
wanted = {"_output_len", "compact_tool_outputs"}
consts = {"COMPACT_HIGH_CHARS", "COMPACT_LOW_CHARS", "COMPACT_KEEP_RECENT"}
body = [n for n in tree.body
        if (isinstance(n, ast.FunctionDef) and n.name in wanted)
        or (isinstance(n, ast.Assign) and any(getattr(t, "id", "") in consts for t in n.targets))]
ns: dict = {"json": json}
exec(compile(ast.Module(body=body, type_ignores=[]), str(RUNNER), "exec"), ns)
compact = ns["compact_tool_outputs"]
HIGH, LOW, KEEP = ns["COMPACT_HIGH_CHARS"], ns["COMPACT_LOW_CHARS"], ns["COMPACT_KEEP_RECENT"]


def conversation(n: int, size: int) -> list:
    items = [{"role": "user", "content": "the brief"}]
    for k in range(n):
        items.append({"type": "function_call", "call_id": f"c{k}", "name": "bash", "arguments": "{}"})
        items.append({"type": "function_call_output", "call_id": f"c{k}", "output": f"{k}:" + "x" * size})
    return items


def live_chars(items: list) -> int:
    return sum(len(i["output"]) for i in items
               if i.get("type") == "function_call_output" and not i["output"].startswith("[output elided"))


print("pure function")
elided: set = set()
small = conversation(5, 1_000)
out, newly = compact(small, elided)
check("under the high-water mark nothing is stubbed", (newly, out == small), (0, True))

big = conversation(30, 7_900)                       # ~237K chars of tool output
out, newly = compact(big, elided)
check("over the mark, output is brought under LOW", live_chars(out) <= LOW, True)
check("the latest KEEP outputs are intact",
      [i["output"].split("x")[0] for i in out if i.get("type") == "function_call_output"][-KEEP:],
      [f"{k}:" for k in range(30 - KEEP, 30)])
check("the input list is not mutated", big[2]["output"].startswith("0:"), True)

prefix = json.dumps(out[:20])
grown = big + conversation(2, 7_900)[1:]            # two more turns, under HIGH again
grown[-1]["call_id"] = grown[-3]["call_id"] = "d1"
grown[-2]["call_id"] = grown[-4]["call_id"] = "d0"
out2, newly2 = compact(grown, elided)
check("a later call re-applies the same stubs (prefix stable)", json.dumps(out2[:20]) == prefix, True)
check("no new stubbing until HIGH is crossed again", newly2, 0)

print("SDK wiring")
try:
    from agents import Agent, RunConfig, Runner, function_tool
    from agents.items import ModelResponse
    from agents.models.interface import Model
    from agents.usage import Usage
    from openai.types.responses import ResponseFunctionToolCall, ResponseOutputMessage, ResponseOutputText
except ModuleNotFoundError as exc:
    print(f"  SKIP  openai-agents not installed ({exc.name})")
else:
    import asyncio
    import importlib.util
    spec = importlib.util.spec_from_file_location("velo_runner_under_test", RUNNER)
    runner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = runner
    spec.loader.exec_module(runner)

    seen: list[list] = []

    class Scripted(Model):
        """Calls `dump` 25 times, then answers. Records every input it is sent."""

        async def get_response(self, system_instructions, input, *a, **k):
            seen.append(json.loads(json.dumps(input, default=str)))
            n = len(seen)
            if n <= 25:
                out = [ResponseFunctionToolCall(type="function_call", call_id=f"call{n}",
                                                name="dump", arguments="{}", id=f"fc{n}")]
            else:
                out = [ResponseOutputMessage(type="message", id="m", role="assistant", status="completed",
                                             content=[ResponseOutputText(type="output_text", text="done",
                                                                         annotations=[])])]
            return ModelResponse(output=out, usage=Usage(), response_id=None)

        def stream_response(self, *a, **k):
            raise NotImplementedError

    @function_tool
    def dump() -> str:
        """Return a large block of output."""
        return "y" * 7_900

    elided_live: set = set()

    def _compact(data):
        items, _ = runner.compact_tool_outputs(list(data.model_data.input), elided_live)
        data.model_data.input = items
        return data.model_data

    agent = Agent(name="t", instructions="x", model=Scripted(), tools=[dump])
    cfg = RunConfig(call_model_input_filter=_compact)
    asyncio.run(Runner.run(agent, "go", max_turns=40, run_config=cfg))

    peak = max(live_chars([i for i in call if isinstance(i, dict)]) for call in seen)
    check("the SDK sends function_call_output items the filter recognises",
          any(i.get("type") == "function_call_output" for i in seen[-1] if isinstance(i, dict)), True)
    check("tool output reaching the model never exceeds HIGH", peak <= HIGH, True)
    check("stubs were applied during the run", len(elided_live) > 0, True)
    stable = all(json.dumps(seen[k + 1][:10]) == json.dumps(seen[k][:10]) for k in range(20, len(seen) - 1))
    check("the prompt prefix is stable between compaction steps", stable, True)

    print("runner wiring")
    check("the runner passes the filter to RunConfig",
          "call_model_input_filter=_compact" in SRC and "compact_tool_outputs(" in SRC, True)

if failures:
    print(f"FAILED: {len(failures)} check(s)")
    sys.exit(1)
print("all context compaction checks passed")

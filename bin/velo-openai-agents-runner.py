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
import re
import subprocess
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
from velo_runner_lib import local_conf, salvage_on_failure  # noqa: E402

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

# Recovery for an empty final turn (no text, no tool call). See the retry loop
# around Runner.run for the failure it answers.
EMPTY_FINAL_RETRIES = 3
EMPTY_FINAL_NUDGE = ("Continue from where you left off. Your last reply contained no "
                     "text and no tool call. If there is more to do, emit the tool call "
                     "you planned now. If the task is complete, give your final report.")

# Recovery for a written final reply that did NOTHING. openai-agents takes any
# reply without a tool call as the final output, so a worker that answers in
# prose mid-task ends the run. On #2291 two velo-local runs of a 7-step apply
# plan ended that way (17 and 23 turns, zero edits) right after the thinking
# budget fired, and were recorded as successes. Only an implementation run whose
# worktree is byte-for-byte unchanged since it started is nudged: a run that
# edited or committed anything, a read-only run, and a declared STOP are all
# legitimate finishes and are accepted as-is.
NO_PROGRESS_RETRIES = 3
NO_PROGRESS_NUDGE = ("Continue: execute the next step of your task now, with a tool call. "
                     "You ended your turn with a written reply, but nothing in the worktree "
                     "has changed since this run started, so the task is not done. If you are "
                     "genuinely blocked, reply with a line starting 'STOP:' and the reason.")

# Old tool outputs are replaced with a stub once the outputs in context grow past
# COMPACT_HIGH_CHARS, oldest first, down to COMPACT_LOW_CHARS; the latest
# COMPACT_KEEP_RECENT are never touched. The stubbing is STICKY and STEPPED, not
# a sliding window: a prefix that changed every turn would miss llama-server's
# prompt cache and re-read the whole context every turn, which costs more than it
# saves. Once stubbed, an output stays stubbed, so the prefix is stable until the
# next step. Sizes are characters (~3.5 per token): 90K is ~26K tokens of tool
# output on top of the ~15K-token brief and policy.
COMPACT_HIGH_CHARS = 90_000
COMPACT_LOW_CHARS = 50_000
COMPACT_KEEP_RECENT = 6

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


# Diagnostic dumps from path-less runs are bounded so they cannot fill the disk:
# nothing older than DUMP_MAX_AGE_DAYS, and the directory stays under DUMP_MAX_BYTES
# (oldest files go first).
DUMP_MAX_AGE_DAYS = 7
DUMP_MAX_BYTES = 500 * 1024 * 1024
# One empty turn's saved thinking is cut here; the run log keeps its own tail.
DUMP_MAX_REASONING_CHARS = 100_000


def prune_dumps(log: "Logger", d: str) -> None:
    now = time.time()
    try:
        files = sorted(((os.path.getmtime(f), os.path.getsize(f), f)
                        for f in (os.path.join(d, n) for n in os.listdir(d))
                        if os.path.isfile(f)))
        removed = 0
        for mt, _size, f in list(files):
            if now - mt > DUMP_MAX_AGE_DAYS * 86400:
                os.remove(f); files.remove((mt, _size, f)); removed += 1
        total = sum(size for _, size, _ in files)
        while files and total > DUMP_MAX_BYTES:
            _mt, size, f = files.pop(0)
            os.remove(f); total -= size; removed += 1
        if removed:
            log.emit(f"runner-dumps pruned {removed} old file(s); {total} bytes kept in {d}")
    except OSError as exc:  # a prune failure must be visible; it must not stop the run
        log.emit(f"runner-dumps prune FAILED: {type(exc).__name__}: {exc}")


class Logger:
    def __init__(self, path: str | None):
        self.path = path
        self.fh = open(path, "a", encoding="utf-8") if path else None
        self.started = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        self.pruned = False

    def sidecar(self, suffix: str) -> str:
        """Where a diagnostic file for this run goes.

        Next to the run log when the runner was given --log-file. Dispatch does
        not pass one (it redirects stdout), so a path-less run writes to
        runner-dumps/ instead; each use logs the path it chose.
        """
        if self.path:
            return self.path + suffix
        d = os.path.expanduser("~/.agents/state/runner-dumps")
        os.makedirs(d, exist_ok=True)
        if not self.pruned:
            self.pruned = True
            prune_dumps(self, d)
        return f"{d}/run-{self.started}-{os.getpid()}{suffix}"

    def emit(self, msg: str) -> None:
        line = f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}.000Z {msg}"
        print(line, flush=True)
        if self.fh:
            self.fh.write(line + "\n"); self.fh.flush()


def dump_final_input(log: "Logger", result) -> None:
    """Write the whole conversation of a run that failed on empty turns.

    error_empty_final fails after ~100 turns of context, and the log keeps only a
    600-char tail of the last thinking, so the failure could not be replayed. The
    file lands next to the run log as `<log>.final-input.json`.
    """
    try:
        out = log.sidecar(".final-input.json")
        items = result.to_input_list()
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(items, fh, default=str)
        log.emit(f"final-input dump: {len(items)} items, {os.path.getsize(out)} bytes -> {out}")
    except Exception as exc:  # a failed diagnostic must be visible, not abort the verdict
        log.emit(f"final-input dump FAILED: {type(exc).__name__}: {exc}")


class AgentLog:
    """The reasoning trail the policy mandates — written by the RUNNER.

    velo-impl.md requires `agent.log` in the worktree root with real timestamps,
    a WHY line before each material change, a heartbeat, and an
    AST-GREP-DECISION line for every structural edit. Its absence is declared a
    brief violation and a STOP trigger.

    No delegated dispatch has ever produced one. Checked 2026-09-20: the #1940
    worktree has no agent.log at all, and the only file of that name on the
    machine is in the main checkout, last written 2026-08-26 — its 13
    AST-GREP-DECISION lines all came from native Claude agents. So the whole
    section has been dead letter for every worker this tooling dispatches.

    Asking the worker to self-report compliance is the wrong fix, and the
    emptiness above is the evidence: a worker that skips ast-grep is exactly the
    worker that will skip logging that it skipped. The runner already SEES every
    tool call, so it writes the trail from ground truth instead. A worker cannot
    forget to, and cannot overstate it.

    Appended, never truncated: a resumed dispatch continues one history.
    """

    def __init__(self, cwd: str):
        self.path = pathlib.Path(cwd) / "agent.log"
        self.ast_grep_calls = 0
        self.ast_grep_applied = 0
        self.fh = None
        try:
            self.fh = open(self.path, "a", encoding="utf-8")
        except OSError as exc:
            # Surfaced, not swallowed. A missing trail is a policy violation and
            # the operator needs to know the runner could not write it.
            print(f"WARN: cannot open {self.path}: {exc}", file=sys.stderr)

    def emit(self, msg: str) -> None:
        if not self.fh:
            return
        self.fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}.000Z {msg}\n")
        self.fh.flush()

    def tool(self, name: str, args_summary: str) -> None:
        if name == "ast_grep":
            self.ast_grep_calls += 1
            # `apply=False` is a DRY RUN — it changes nothing. Recording it as
            # "applied" would put a false compliance claim in the very file
            # that exists to evidence compliance, and the policy's own recipe
            # makes the dry run a distinct, required step.
            result = "dry-run" if "apply=False" in args_summary else "applied"
            if result == "applied":
                self.ast_grep_applied += 1
            self.emit(f"AST-GREP-DECISION | op=structural | pattern={args_summary} "
                      f"| result={result}")
        else:
            self.emit(f"TOOL {name} | {args_summary}")

    def why(self, text: str) -> None:
        """The model's own reasoning for the step — the policy's WHY line."""
        first = " ".join(text.strip().split())[:300]
        if first:
            self.emit(f"WHY: {first}")

    def close(self, status: str, files_changed: int, read_only: bool = False) -> None:
        # The check the policy describes but nothing has ever run. Computed from
        # the tool log, so it needs nothing from the worker.
        counts = (f"files_changed={files_changed} | ast_grep_calls={self.ast_grep_calls} "
                  f"(applied={self.ast_grep_applied}, "
                  f"dry_run={self.ast_grep_calls - self.ast_grep_applied})")

        if files_changed >= 2 and self.ast_grep_calls == 0:
            verdict = ("review — a change spanning 2+ files with no ast_grep is the "
                       "trigger-list violation velo-impl.md §AST-grep defines")
        elif (not read_only and files_changed == 0 and self.ast_grep_calls > 0
              and self.ast_grep_applied == 0):
            # Caught by this check's own first end-to-end run: the worker
            # dry-ran ast_grep three times, never passed apply=True, changed
            # nothing, and reported status=success. An earlier version scored
            # that VERDICT=ok purely because ast_grep_calls > 0 — counting
            # SEARCHES as evidence of WORK. Searching is not doing.
            verdict = ("review — ast_grep ran but every call was a dry run and "
                       "nothing changed on a write task; the search happened, the "
                       "edit did not")
        else:
            verdict = "ok"

        self.emit(f"STRUCTURAL-EDIT-CHECK | {counts} | VERDICT={verdict}")
        self.emit(f"FINAL STATE — status={status} files_changed={files_changed}")
        self.fh and self.fh.close()


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

    def __init__(self, logger: Logger, label: str, max_budget_usd: float | None = None,
                 agent_log: "AgentLog | None" = None):
        self.log, self.label = logger, label
        self.agent_log = agent_log
        self.max_budget_usd = max_budget_usd
        self.inp = self.out = self.cached = self.turns = 0
        self.leaked = 0
        # Tool calls requested so far: the retry loop reads it to tell an empty
        # turn that follows real work from one that follows another empty turn.
        self.tool_calls = 0
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
                "text": item_text(item)[:4000],
            })
        calls = [o for o in (getattr(response, "output", None) or [])
                 if getattr(o, "type", "") == "function_call"]
        self.tool_calls += len(calls)
        if calls:
            names = ",".join(getattr(c, "name", "?") for c in calls)
            detail = "  ".join(
                f"{getattr(c,'name','?')}({summarise_tool_input(getattr(c,'arguments',None))})"
                for c in calls)
            self.log.emit(f"[{self.label}] tool start names={names} | {detail}")
            if self.agent_log:
                for c in calls:
                    self.agent_log.tool(
                        getattr(c, "name", "?"),
                        summarise_tool_input(getattr(c, "arguments", None)))
        else:
            # A reply with no tool call. When it is also empty the run is about to
            # be nudged or failed, and what the model DID write — its reasoning —
            # is the only evidence of why: a tool call inside the thinking block,
            # a stop mid-thought, or nothing at all.
            texts = [(getattr(o, "type", "?"), item_text(o)) for o in
                     (getattr(response, "output", None) or [])]
            reasoning = "\n".join(t for kind, t in texts if kind == "reasoning")
            visible = "".join(t for kind, t in texts if kind != "reasoning")
            self.log.emit(f"[{self.label}] sdk assistant text_len={len(visible)} "
                          f"reasoning_len={len(reasoning)}")
            if not visible.strip():
                tail = " ".join(reasoning.split())[-600:]
                self.log.emit(f"[{self.label}] empty turn reasoning tail: {tail!r}")
                self.log.emit(f"[{self.label}] empty turn context: turn={self.turns} "
                              f"tool_calls_so_far={self.tool_calls} tokens_in={self.inp} "
                              f"tokens_out={self.out} cached={self.cached} "
                              f"output_item_types={[k for k, _ in texts]}")
                # The tail above is 600 chars; the whole thinking is what a later
                # replay needs. One JSON line per empty turn.
                sidecar = self.log.sidecar(".empty-turns.jsonl")
                with open(sidecar, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"turn": self.turns, "tool_calls": self.tool_calls,
                                         "reasoning": reasoning[-DUMP_MAX_REASONING_CHARS:],
                                         "types": [k for k, _ in texts]}) + "\n")
                self.log.emit(f"[{self.label}] empty turn thinking saved: {sidecar}")
                for kind in scan_for_leaked_tool_calls(reasoning):
                    self.log.emit(f"[{self.label}] TOOL CALL INSIDE REASONING kind={kind} "
                                  f"turn={self.turns} — the server filed it as thinking, "
                                  f"so it never ran")

        # The model's own text is the WHY the policy asks for, captured where it
        # is actually produced rather than requested of the worker afterwards.
        if self.agent_log:
            for blob in (getattr(o, "text", "") or "" for o in
                         (getattr(response, "output", None) or [])):
                self.agent_log.why(blob)

        # Leaked tool calls — ported from the incumbent, which detected these and
        # this runtime did not. The failure is SILENT: the model emits its NATIVE
        # tool-call syntax as plain assistant TEXT, the SDK's parser does not
        # recognise it, so the call never runs while the turn still reports
        # success. The intended edit simply does not happen and the worker says
        # it is done.
        #
        # Observed on DeepSeek (fullwidth-pipe DSML markers) when the task string
        # carried nested quotes, and it is not model-specific — Qwen leaks
        # <tool_call>, and <function_calls>/<invoke name= appear across providers.
        for blob in (getattr(o, "text", "") or "" for o in
                     (getattr(response, "output", None) or [])):
            for kind in scan_for_leaked_tool_calls(blob):
                self.leaked += 1
                self.log.emit(f"[{self.label}] LEAKED TOOL CALL kind={kind} "
                              f"turn={self.turns} — emitted as text, never executed")

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


def worktree_state(cwd: str) -> str | None:
    """HEAD plus the full uncommitted diff and untracked list, as one string.

    Compared before and after a run to decide whether it changed anything. The
    diff text, not `git status`, because a tree that was already dirty at start
    shows the same status line however much more the worker edits a file.
    None when git cannot answer — the caller then does not guess "no progress".
    """
    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True,
                              text=True, check=True, timeout=60).stdout
    try:
        return "\0".join((git("rev-parse", "HEAD"), git("diff", "HEAD", "--binary"),
                          git("ls-files", "--others", "--exclude-standard")))
    except (subprocess.SubprocessError, OSError):
        return None


def ended_without_progress(read_only: bool, text: str,
                           before: str | None, after: str | None) -> bool:
    """A written final reply from an implementation run that changed nothing."""
    if read_only or before is None or after is None:
        return False
    if re.search(r"^\s*\**STOP\b", text, re.MULTILINE):
        return False
    return before == after


def _output_len(item) -> int:
    out = item.get("output")
    return len(out) if isinstance(out, str) else len(json.dumps(out, default=str))


def compact_tool_outputs(items: list, elided: set, high: int = COMPACT_HIGH_CHARS,
                         low: int = COMPACT_LOW_CHARS,
                         keep_recent: int = COMPACT_KEEP_RECENT) -> tuple[list, int]:
    """Stub old tool outputs so context stays small; returns (items, newly stubbed).

    `elided` is the run's sticky set of stubbed call_ids and is updated in place.
    Items are never mutated — the SDK keeps the originals — so the same stubs are
    re-applied from `elided` on every call and the prefix does not change.
    """
    outputs = [i for i, it in enumerate(items)
               if isinstance(it, dict) and it.get("type") == "function_call_output"]
    live = [i for i in outputs if items[i].get("call_id") not in elided]
    size = sum(_output_len(items[i]) for i in live)
    newly = 0
    if size > high:
        for i in live[:max(0, len(live) - keep_recent)]:
            if size <= low:
                break
            size -= _output_len(items[i])
            elided.add(items[i].get("call_id"))
            newly += 1
    if not elided:
        return items, 0
    out = []
    for it in items:
        if (isinstance(it, dict) and it.get("type") == "function_call_output"
                and it.get("call_id") in elided):
            it = {**it, "output": f"[output elided to save context ({_output_len(it)} "
                                  f"characters). Re-run the tool if you need it again.]"}
        out.append(it)
    return out, newly


def task_is_read_only(task: str) -> bool:
    # Only the explicit declaration the review skills inline. A substring match on
    # "read only" stripped write tools from implementation briefs that merely said
    # "Read ONLY the issue body" (#2235).
    return "=== THIS IS A READ-ONLY REVIEW TASK ===" in task


hooks_ref: dict = {"cost": 0.0}


# Ported verbatim in intent from velo_worker_runner.py, which had this and the
# openai-agents runtime did not — a capability lost in the #2088 switch and not
# noticed until #2075, because the field was hardcoded to 0 and so always looked
# clean.
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")

LEAKED_TOOL_CALL_PATTERNS = (
    ("DSML", re.compile(r"<[|｜]\s*DSML")),
    ("tool_call", re.compile(r"</?tool_calls?>")),
    ("function_calls", re.compile(r"</?function_calls>")),
    ("invoke", re.compile(r"<invoke\s+name=")),
)


def scan_for_leaked_tool_calls(text: str) -> list:
    """Names of leak shapes present in `text`, ignoring quoted syntax.

    Two guards keep this from firing on a worker that legitimately QUOTES
    tool-call syntax in its report — e.g. one writing up this very failure mode:

      1. fenced and inline code spans are stripped first, since a report puts
         the syntax in backticks while a real leak is bare;
      2. each pattern requires the real structural delimiters, so prose that
         merely says "DSML" or "invoke" does not match.
    """
    if not text:
        return []
    scannable = INLINE_CODE_RE.sub("", CODE_FENCE_RE.sub("", text))
    return [name for name, pat in LEAKED_TOOL_CALL_PATTERNS if pat.search(scannable)]


def item_text(item) -> str:
    """Every text an output item carries: `text`, `content` parts, `summary` parts.

    openai-agents puts a chat-completions `reasoning_content` (llama-server,
    Sushi) in a reasoning item's SUMMARY, not its content. Reading `content`
    alone recorded every reasoning turn as empty, so the empty final turns that
    killed four Sushi runs left nothing to say what the model had written.
    """
    parts = []
    direct = getattr(item, "text", None)
    if isinstance(direct, str):
        parts.append(direct)
    for field in ("content", "summary"):
        value = getattr(item, field, None)
        if isinstance(value, str):
            parts.append(value)
        elif isinstance(value, (list, tuple)):
            parts.extend(t for t in (getattr(v, "text", None) for v in value) if isinstance(t, str))
    return "\n".join(p for p in parts if p)


def tool_contract(tools) -> str:
    """The registered-tool contract, emitted BEFORE the policy.

    Measured across the two dispatch paths, same policy, same repo (#2075):

                        ast-grep     zg
        codex   15 runs      894    179
        SDK     14 runs        0      2

    Codex reads velo-impl.md and runs `ast-grep` and `zg query`, because the
    shell is its only interface. The SDK worker has registered tools that LOOK
    like they cover the same ground — grep, glob_files, read_file, edit_file —
    reaches for those, and never gets to the commands the policy mandates.

    POSITION IS THE DEFECT, and it took two failed attempts to see it.

    Attempt 1 told the worker to prefer its tools over bash; wrong direction.
    Attempt 2 (#2166) registered `ast_grep` as a real tool and appended this
    text after the policy. A live deepseek dispatch on #1940 then ran 45 tool
    calls, ALL bash, with ast_grep and zg_query at zero — and zero `ast-grep`
    even THROUGH bash, so it was not tool-vs-shell preference at all. The
    mandated tooling simply never entered the run.

    The reason is measurable: velo-impl.md is ~45KB and teaches every mandated
    tool as a SHELL COMMAND LINE (`zg query "..."`, `ast-grep run --pattern`).
    Appended after it, this block was 3.27% of the system prompt, last. The
    bulk of the prompt demonstrates bash; the correction was a footnote, and
    the worker was consistent with the bulk.

    Do NOT cite #2088's runtime benchmark as evidence for this shape. It
    measured correctness, cost, wall clock and tool-call COUNT — never which
    tools — and #2075 records that 0 of its 15 runs used zg at all, because no
    index existed in those worktrees. An earlier version of this docstring
    claimed it showed tool-first prompting working. It does not.

    The evidence is a re-dispatch of #1940 on this prompt: at 14 turns, 20
    read_file + 10 grep + 14 bash, where the same worker on the same class of
    brief had run 45 bash and nothing else. bash stopped being the search-and-
    read instrument from turn 2 on.

    So this block leads, carries an explicit count, and translates the policy's
    shell idioms to tool calls before the worker ever reads them.

    KNOWN UNFIXED: zg_query stayed at zero through that run, on a task whose
    first step was a call-chain trace — the exact question the index answers.
    Position moved the worker off bash but not onto the semantic index.

    Built from `tools` so a read-only run is not told it can edit_file.
    """
    have = {t if isinstance(t, str) else getattr(t, "name", getattr(t, "__name__", ""))
            for t in tools}

    # Each line names the tool, then what it must NOT be used to avoid.
    limits = [
        ("ast_grep",   "REQUIRED for any rename, signature change, match-arm change or "
                       "trait change touching 2+ files. Matches SYNTAX, so it cannot hit a "
                       "comment or a partial identifier. Dry-run first: a pattern matching "
                       "0 is wrong, and applying it silently changes nothing."),
        ("grep",       "finding a literal string. It does NOT replace ast_grep for a "
                       "structural search (a rename, a signature, a match arm, a trait impl)."),
        ("glob_files", "finding files by name."),
        ("read_file",  "reading a file or a range."),
        ("edit_file",  "a targeted edit in ONE file. If the same change lands in two or "
                       "more files, the policy REQUIRES ast-grep — using edit_file twice "
                       "instead is a brief violation, not a shortcut."),
        ("write_file", "creating a NEW file."),
        ("zg_query",   "the same thing as `zg query` in bash; either is fine."),
    ]
    lines = [f"- {n}: {why}" for n, why in limits if n in have]

    # The policy teaches each mandated tool as a shell command line. Those exact
    # spellings are what the worker will meet below, so translate them here,
    # before it reads them, rather than correcting the impression afterwards.
    shell_to_tool = [
        ("zg query \"...\"",              "zg_query"),
        ("zg query --fts \"...\"",        "zg_query"),
        ("ast-grep run --pattern '...'",  "ast_grep"),
        ("grep -n / rg",                  "grep"),
        ("cat / sed -n '1,80p'",          "read_file"),
    ]
    xlate = "\n".join(
        f"    {sh:<32} -> {tool}" for sh, tool in shell_to_tool
        if tool in have
    )

    return (
        "=== YOUR TOOLS (read this before the policy) ===\n"
        f"You have EXACTLY {len(lines)} tools:\n\n"
        + "\n".join(lines)
        + "\n\nStart with zg_query, in plain English, whenever you do not already know the\n"
          "symbol name. It is a semantic index of this worktree and it is already built.\n\n"
          "The policy below is written for a shell-only worker, so it spells every one of\n"
          "these out as a COMMAND LINE. When you read those commands, they mean the tool:\n\n"
        + xlate
        + "\n\nRunning them through bash instead is not wrong, but it is slower and loses the\n"
          "structured result — and in practice a worker that starts in bash stays in bash\n"
          "and never reaches ast_grep at all. Prefer the tool every time.\n\n"
          "MANDATORY: before any rename, signature change, match-arm change or trait change\n"
          "that touches two or more files, use ast_grep and log the AST-GREP-DECISION line\n"
          "the policy requires. grep plus a per-file edit is a brief violation, not a\n"
          "shortcut — grep matches comments and partial identifiers; ast_grep matches syntax.\n\n"
          "IGNORE tool names in the repo CLAUDE.md and AGENTS.md. Those are written\n"
          "for a Claude Code session and name tools you do NOT have: LSP, Grep,\n"
          "Read, Edit. There is no LSP on this runtime. Their RULES still apply;\n"
          "only the tool names do not.\n"
    )


def tool_contract_reminder(tools) -> str:
    """One-line recency anchor after the policy's 45KB of shell examples."""
    have = {t if isinstance(t, str) else getattr(t, "name", getattr(t, "__name__", ""))
            for t in tools}
    mandated = [n for n in ("zg_query", "ast_grep") if n in have]
    if not mandated:
        return ""
    return (
        "\n=== REMINDER ===\n"
        "The commands the policy just showed you are registered tools here: "
        + ", ".join(mandated)
        + ". Use them directly.\n"
    )


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
    ap.add_argument("--no-force-first-tool", action="store_true",
                    help="Do not force the opening tool call to zg_query. For "
                         "measuring what the prompt alone achieves, and as an "
                         "escape hatch if a provider mishandles tool_choice.")
    a = ap.parse_args()

    log = Logger(a.log_file)
    T.set_cwd(a.cwd)
    T.DEFAULT_BASH_TIMEOUT_S = max(1, a.bash_timeout_ms // 1000)
    policy = pathlib.Path(a.policy).read_text(encoding="utf-8")
    task = apply_skills(a.task, a.skill)
    # Classified AFTER inlining: the review skills carry the read-only
    # declaration, and a gate that writes is a gate that has already gone wrong.
    read_only = task_is_read_only(task)

    # Selected BEFORE the system prompt: the preamble is built from the actual
    # registered tools, so a read-only run is not told it can edit_file.
    _tools = T.READ_ONLY_TOOLS if read_only else T.ALL_TOOLS

    # Tool contract FIRST, policy second, one-line anchor last. Appending the
    # contract after the policy put it at 3.27% of the prompt, behind 45KB that
    # teaches every mandated tool as a bash command — and the #1940 dispatch ran
    # 45/45 bash with zero ast_grep. Order is the fix, not wording (#2075).
    system = (
        f"You are a full autonomous Velostream implementation worker.\n\n"
        f"MODEL:\n{a.model}\n\nWORKTREE:\n{a.cwd}\n\n"
        "You operate only inside the assigned Velostream worktree.\n\n"
        + tool_contract(_tools)
        + "\nThe following Velostream implementation policy is authoritative and mandatory:\n\n"
        f"================ VELO-IMPL POLICY ================\n{policy}\n"
        "================ END VELO-IMPL POLICY ============\n"
        + tool_contract_reminder(_tools)
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
    tools = _tools
    # Force the FIRST tool call to be zg_query, then hand choice back.
    #
    # A guarantee, NOT a rescue — the distinction matters, because an earlier
    # version of this comment got it wrong.
    #
    # #2166 registered ast_grep and appended guidance to the prompt: 45/45
    # bash. Moving the contract to the front fixed that — bash fell to 52/130
    # and is now only git/cargo/find — but zg_query stayed at ZERO across all
    # 49 turns of that run, whose own first step was a call-chain trace.
    #
    # That is NOT because instruction cannot move it. Measured on a clean
    # worktree with the forcing OFF, the contract alone put zg_query first and
    # answered a discovery question in 3 turns for $0.0025. The real pattern is
    # narrower: a long task that opens with worktree orientation (git log, git
    # status) proceeds file-by-file and never comes back to the index. That is
    # the expensive case, and the one this pins.
    #
    # Worth forcing, because the one call is not marginal: run by hand against
    # that same step-1 question, zg returned analyze_multi_statement at
    # query_analyzer.rs:379-442 — the exact seam — plus the test file the
    # worker did not open until turn 18, as hit #2 of 10.
    #
    # reset_tool_choice (SDK default, left on) flips tool_choice back to "auto"
    # after the first call, so this constrains the opening move and nothing
    # else. Omitted for read-only gates, whose task is already narrow, and
    # skipped when zg_query is not registered.
    # A named-function tool_choice is an object; LM Studio accepts only the
    # strings none/auto/required and 400s the whole run on turn 0.
    force_first = "zg_query" if (not read_only and not a.no_force_first_tool
                                 and "openrouter.ai" in a.base_url
                                 and "zg_query" in
                                 {getattr(t, "name", "") for t in tools}) else None
    agent = Agent(
        name="velo-worker",
        instructions=system,
        model=OpenAIChatCompletionsModel(model=a.model, openai_client=client),
        tools=tools,
        model_settings=ModelSettings(
            parallel_tool_calls=True,
            **({"tool_choice": force_first} if force_first else {}),
            # Local sampling is SENT, never left to the server: LM Studio's
            # per-model sampling config could not be shown to apply, and
            # llama.cpp's own default is temp 0.8, not the model's 1.0.
            **({} if is_gateway else {
                "temperature": float(local_conf("VELO_LOCAL_TEMPERATURE")),
                "top_p": float(local_conf("VELO_LOCAL_TOP_P"))}),
            max_tokens=MAX_TOKENS_BY_MODEL.get(a.model, a.max_tokens),
            # provider.order and usage.include are OpenRouter fields. A plain
            # OpenAI-compatible server rejects unknown body keys, so sending them
            # to LM Studio breaks every request (cf. openai-agents#4326, where
            # parallel_tool_calls sent to Azure did exactly that).
            extra_body=({"provider": {"order": PROVIDER_ORDER.get(a.model, []),
                                      "allow_fallbacks": True},
                         "usage": {"include": True}} if is_gateway else
                        {"top_k": int(local_conf("VELO_LOCAL_TOP_K")),
                         "min_p": float(local_conf("VELO_LOCAL_MIN_P"))})),
    )

    if a.max_budget_usd is not None and a.max_budget_usd <= 0:
        print("ERROR: --max-budget-usd must be > 0", file=sys.stderr)
        return 1
    # Written into the WORKTREE, which is where velo-impl.md says it lives and
    # where a human debugging the run will look for it.
    agent_log = AgentLog(a.cwd)
    agent_log.emit(f"RUN START model={a.model} cwd={a.cwd} "
                   f"read_only={str(read_only).lower()} max_turns={a.max_turns}")
    hooks = Hooks(log, "prompt 1", max_budget_usd=a.max_budget_usd,
                  agent_log=agent_log)
    hooks_ref["obj"] = hooks
    log.emit("[prompt 1] sdk system event=init")
    log.emit(f"[prompt 1] start timeout_seconds={a.prompt_timeout:.0f} "
             f"backend=openai-agents tools={len(tools)} read_only={str(read_only).lower()} "
             f"force_first_tool={force_first or 'none'}")

    t0 = time.time()
    status, text = "success", ""
    try:
        # tool_not_found_behavior: a model that improvises a tool name kills the
        # whole run under the default 'raise_error'. For an unattended worker the
        # error belongs back in the model's lap so it can recover.
        elided: set = set()

        def _compact(data):
            items, newly = compact_tool_outputs(list(data.model_data.input), elided)
            if newly:
                log.emit(f"[prompt 1] context compaction: elided {newly} old tool "
                         f"output(s), {len(elided)} total")
            data.model_data.input = items
            return data.model_data

        cfg = RunConfig(tool_not_found_behavior="return_error_to_model",
                        tool_execution=ToolExecutionConfig(max_function_tool_concurrency=6),
                        call_model_input_filter=_compact)
        # An EMPTY final turn — no text and no tool call — is not a finish.
        # openai-agents treats any reply without a tool call as the final
        # output, so a reasoning model that ends its turn at the close of its
        # thinking block (Qwen3.8 on #2235: 7,166 reasoning tokens ending
        # "Let me trace through the git history…", content="", tool_calls=[])
        # was recorded as status=success with nothing done. Mirror the
        # incumbent's max_tokens recovery: hand the conversation back with a
        # nudge, up to EMPTY_FINAL_RETRIES times, then fail loud.
        start_state = worktree_state(a.cwd)

        async def _run_with_empty_final_retry():
            inp = task + budget
            empty = stalled = 0
            while True:
                remaining = a.max_turns - hooks.turns
                if remaining <= 0:
                    raise MaxTurnsExceeded("max turns exhausted during final-turn retries")
                calls_before = hooks.tool_calls
                r = await Runner.run(agent, inp, max_turns=remaining,
                                     run_config=cfg, hooks=hooks)
                # CONSECUTIVE empty turns, as the failure message says. A nudge
                # that got the model calling tools again was a recovery, so the
                # count restarts. Never resetting it failed #2440 on its 4th
                # empty turn of the run, 21 minutes and 28 tool calls after the
                # 3rd.
                if hooks.tool_calls > calls_before:
                    empty = 0
                final = str(r.final_output or "").strip()
                if not final:
                    if empty == EMPTY_FINAL_RETRIES:
                        dump_final_input(log, r)
                        return r, "error_empty_final"
                    empty += 1
                    log.emit(f"[prompt 1] empty final turn (no text, no tool call) — "
                             f"continuing, retry {empty}/{EMPTY_FINAL_RETRIES} "
                             f"input_items={len(r.to_input_list())} turns={hooks.turns} "
                             f"tool_calls={hooks.tool_calls}")
                    nudge = EMPTY_FINAL_NUDGE
                elif (stalled < NO_PROGRESS_RETRIES and ended_without_progress(
                        read_only, final, start_state, worktree_state(a.cwd))):
                    stalled += 1
                    log.emit(f"[prompt 1] final reply with no worktree change — "
                             f"continuing, retry {stalled}/{NO_PROGRESS_RETRIES}")
                    nudge = NO_PROGRESS_NUDGE
                else:
                    return r, ""
                inp = r.to_input_list() + [{"role": "user", "content": nudge}]

        res, empty_status = await asyncio.wait_for(_run_with_empty_final_retry(),
                                                   timeout=a.prompt_timeout)
        text = str(res.final_output or "")
        if empty_status:
            status = empty_status
            text = (f"The model ended {EMPTY_FINAL_RETRIES + 1} consecutive turns with no "
                    f"text and no tool call; the run did not finish its task.")
            log.emit(f"[prompt 1] ERROR {status}: {text}")
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
    # files_changed comes from git, not from the worker's report — the whole
    # point of writing this trail in the runner is that it needs nothing from
    # the worker to be true.
    try:
        _diff = subprocess.run(["git", "-C", a.cwd, "diff", "--name-only", "HEAD"],
                               capture_output=True, text=True, timeout=30)
        _files = len([ln for ln in _diff.stdout.splitlines() if ln.strip()])
    except (OSError, subprocess.SubprocessError) as exc:
        # Not swallowed: an unknown file count makes the structural check
        # unresolvable, and saying so beats recording a confident 0.
        agent_log.emit(f"STRUCTURAL-EDIT-CHECK | VERDICT=unknown — git diff failed: {exc}")
        _files = -1
    if _files >= 0:
        agent_log.close(status, _files, read_only=read_only)
    else:
        agent_log.emit(f"FINAL STATE — status={status} files_changed=unknown")
    log.emit(f"[prompt 1] sdk result status={status} turns={hooks.turns} text_len={len(text)}")
    log.emit(f"[prompt 1] completed in_seconds={wall:.1f} status={status} final_result=true")

    # input_tokens EXCLUDES cached, matching the incumbent's convention — the two
    # are compared directly, and mixing conventions made a 229k-token run read as 7k.
    fresh = max(hooks.inp - hooks.cached, 0)
    log.emit(
        # A real count now. This was a hardcoded 0 until #2075, then honestly
        # `unmeasured` once it was clear nothing counted them — three consumers
        # read the field as a measurement (velo-record parses it and ranks it
        # above every other outcome; velo-status paints LEAKED red), so the
        # absence of evidence was displayed as evidence of absence on every run
        # from 2026-09-12. The detector the incumbent always had is now ported,
        # so the field means what its name says.
        f"TOTALS prompts=1 leaked_tool_calls={hooks.leaked} "
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

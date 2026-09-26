#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import os
import pathlib
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass
from typing import Any
from datetime import UTC, datetime

from open_agent_sdk import AgentOptions, create_agent
from open_agent_sdk.types import SDKMessageType, SDKResultStatus

# Runtime corrections to the SDK, applied before any tool can run (#2010).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from velo_zg_tool import ZgQueryTool
from velo_runner_lib import local_conf, salvage_on_failure  # noqa: E402
from velo_sdk_patches import (  # noqa: E402
    LEDGER,
    install_context_windows,
    install_provider_pinning,
    install_tool_input_normalisation,
    turn_budget_notice,
)

# --- provider profiles (#2007 F7) --------------------------------------------
# The two runners were 1030-line near-clones differing in ~92 lines: model and
# base-url defaults, one system-prompt sentence, api-key resolution, the log and
# label prefix, and whether a model can ever carry a real price. Every fix in
# this file previously had to land twice, and the .bak graveyard in bin/ shows
# how that drifts. One implementation, two profiles.
PROVIDERS: dict[str, dict[str, Any]] = {
    "openrouter": {
        "label": "velo-openrouter-agent",
        "default_model": "deepseek/deepseek-v4-flash-0731",
        "default_base_url": "https://openrouter.ai/api/v1",
        "base_url_env": "CODEANY_BASE_URL",
        "api_key_envs": ("OPENROUTER_API_KEY", "CODEANY_API_KEY"),
        "api_key_fallback": None,
        "system_prompt_suffix": "",
        # A hosted request really is billed, so an exact price-table hit is a
        # real price. Prefix matching is not — see model_is_priced.
        "billable": True,
        # Only a routed provider can be pinned; there is nothing to pin locally.
        "pin_provider": True,
    },
    "lmstudio": {
        "label": "velo-lmstudio-agent",
        "default_model": os.environ.get("LM_STUDIO_MODEL") or local_conf("VELO_LOCAL_MODEL_DEFAULT"),
        "default_base_url": os.environ.get("LM_STUDIO_BASE_URL") or local_conf("VELO_LOCAL_BASE_URL"),
        "base_url_env": "LM_STUDIO_BASE_URL",
        "api_key_envs": ("LM_STUDIO_API_KEY", "CODEANY_API_KEY"),
        "api_key_fallback": "lm-studio",
        "system_prompt_suffix": " running locally through LM Studio",
        # Pricing provenance is a property of the PROVIDER, not the model's name.
        # Nobody bills for a locally-served model whatever it calls itself, so no
        # dollar figure this profile produces is ever a price (#2012 H2 class).
        "billable": False,
        "pin_provider": False,
    },
}

PROVIDER = PROVIDERS["openrouter"]   # replaced by run() before anything reads it

DEFAULT_MODEL = PROVIDER["default_model"]
DEFAULT_BASE_URL = PROVIDER["default_base_url"]
DEFAULT_MAX_TURNS = 50
DEFAULT_MAX_CONTINUATIONS = 3
DEFAULT_MAX_TOKENS = 8000
DEFAULT_PROMPT_TIMEOUT_SECONDS = 1800
# The Bash tool caps a single command at 10 minutes by default, which is less
# than one cold `cargo nextest --lib --test mod` sweep on this workspace. A
# worker that hits it loses the command AND burns the rest of its prompt
# budget waiting. Raise both the default and the ceiling so the gate fits.
DEFAULT_BASH_TIMEOUT_MS = 2_400_000
DEFAULT_LOG_DIR = pathlib.Path.home() / ".agents" / "logs"

REVIEW_SKILLS = ("check-code", "check-spec", "code-review", "pr-gate")

READ_ONLY_MARKERS = (
    "read-only",
    "read only",
    "do not modify",
    "do not edit",
    "no changes",
    "without modifying",
)

IMPLEMENTATION_MARKERS = (
    "implement",
    "fix ",
    "change ",
    "modify",
    "edit",
    "refactor",
    "add ",
    "remove ",
    "update ",
    "create ",
)


def fail(message: str, code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)



# --- skill injection ---------------------------------------------------------
# Workers run with a fixed `allowed_tools` list and no `setting_sources`, so they
# have NO Skill tool: a brief that says "/check-code" is inert text to them, and
# whatever the orchestrator remembers of the skill gets hand-copied into the
# brief instead — differently every time. So resolve the skill file here and
# prepend its CONTENT, and let the brief carry only the scope.
SKILL_SEARCH = (
    "{home}/.agents/skills/{name}/SKILL.md",
    "{home}/.claude/skills/{name}/SKILL.md",
    "{home}/.claude/commands/{name}.md",
)

_FRONTMATTER_RE = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)


# Skill inlining lives in velo_skills so BOTH runtimes share one definition.
# Re-exported here because this module's callers import it from here.
from velo_skills import apply_skills, resolve_skill  # noqa: E402,F401
def worker_env(bash_timeout_ms: int) -> dict[str, str]:
    """Environment handed to the worker's Bash tool.

    ~/.agents/bin is on PATH here, GUARANTEED — never left to the operator's rc.

    velo-impl.md instructs every worker to run `zg query "..."` as its discovery
    step. The SDK merges this dict over os.environ (tools/bash.py:75), so without
    an explicit PATH the worker inherits whatever shell launched velo-dispatch.
    install.sh only WARNS that ~/.agents/bin should be added to a shell rc, so on
    any machine where that was not done, the documented first move of every
    worker is `zg: command not found` — and nothing tells the worker the shim
    exists at all.

    Observed exactly that way: a session with ~/.agents/bin absent from PATH hit
    command-not-found on bare `zg` and never tried it again. The runner knows
    where the tools live; the operator's shell configuration is not a dependency
    of the worker contract.

    Prepended, not appended: the shim must win over a stale global install.
    """
    agents_bin = pathlib.Path.home() / ".agents" / "bin"
    return {
        "BASH_DEFAULT_TIMEOUT_MS": str(bash_timeout_ms),
        "BASH_MAX_TIMEOUT_MS": str(bash_timeout_ms),
        "PATH": f"{agents_bin}:{os.environ.get('PATH', '')}",
    }


def git_output(root: pathlib.Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout if result.returncode == 0 else ""


def git_snapshot(root: pathlib.Path) -> str:
    """Worktree fingerprint: dirty state AND committed HEAD.

    `git status --porcelain` alone is empty once the agent commits, so a task
    that did its work AND committed it looked identical to a task that did
    nothing — the runner then burned every continuation re-running finished
    work and exited with a false ERROR. Including HEAD makes a commit count
    as a change, which is what the caller actually means by "did it do
    anything".
    """
    status = git_output(root, "status", "--porcelain=v1", "--untracked-files=all")
    head = git_output(root, "rev-parse", "HEAD")
    return f"{head}\n{status}"


def git_diff_summary(root: pathlib.Path) -> str:
    unstaged = git_output(root, "diff", "--stat")
    staged = git_output(root, "diff", "--cached", "--stat")
    status = git_snapshot(root)

    parts: list[str] = []
    if unstaged.strip():
        parts.append("Unstaged diff:\n" + unstaged.strip())
    if staged.strip():
        parts.append("Staged diff:\n" + staged.strip())
    if status.strip():
        parts.append("Status:\n" + status.strip())

    return "\n\n".join(parts) if parts else "No worktree changes detected."


def task_is_read_only(task: str) -> bool:
    lower = task.lower()
    return any(marker in lower for marker in READ_ONLY_MARKERS)


def task_looks_like_implementation(task: str) -> bool:
    if task_is_read_only(task):
        return False
    lower = task.lower()
    return any(marker in lower for marker in IMPLEMENTATION_MARKERS)


def build_system_prompt(model: str, root: pathlib.Path, policy: str) -> str:
    provider_suffix = PROVIDER["system_prompt_suffix"]
    return f"""
You are a full autonomous Velostream implementation worker{provider_suffix}.

MODEL:
{model}

WORKTREE:
{root}

You operate only inside the assigned Velostream worktree.

The following Velostream implementation policy is authoritative and mandatory:

================ VELO-IMPL POLICY ================
{policy}
================ END VELO-IMPL POLICY ============

Execution requirements:
- Own the delegated task from investigation through completion.
- Use Read, Glob, Grep, Bash, Edit, and Write as needed.
- Keep investigation focused on evidence needed for the requested task.
- For implementation tasks, do not stop after reconnaissance: make the minimal
  required edits, run focused validation, and return a final implementation report.
- For read-only tasks, never modify files.
- Do not commit, push, open pull requests, or post external comments unless the
  task explicitly requires it.
- Do not claim files, commands, or tests were inspected/run unless they actually were.
- Follow all STOP conditions in the implementation policy.
- Preserve unrelated work already present in the worktree.
- Finish with a concise report containing:
  1. files inspected or changed
  2. findings / implementation performed
  3. validation or tests run
  4. any remaining concerns
""".strip()


# A model sometimes emits its NATIVE tool-call syntax as plain assistant text
# instead of a real tool call — the SDK's parser does not recognise it, so the
# call silently never runs while the turn still reports success. Observed on
# DeepSeek (fullwidth-pipe `DSML` markers) when the task string carried nested
# quotes. It is not model-specific: Qwen leaks `<tool_call>`, and the
# `<function_calls>` / `<invoke name=` shapes show up across providers.
#
# This matters because the failure is SILENT: the intended edit never happens
# and the worker reports done. Detect it and surface it rather than trusting
# `status=success`.
#
# Two guards keep this from firing on a worker that legitimately QUOTES
# tool-call syntax in its report (e.g. writing up this very failure mode):
#   1. fenced and inline code spans are stripped before scanning, since a
#      report quoting syntax puts it in backticks while a real leak is bare;
#   2. each pattern requires the real structural delimiters, so prose that
#      merely says "DSML" or "invoke" does not match.
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")

LEAKED_TOOL_CALL_PATTERNS = (
    ("DSML", re.compile(r"<[|\uff5c]\s*DSML")),
    ("tool_call", re.compile(r"</?tool_calls?>")),
    ("function_calls", re.compile(r"</?function_calls>")),
    ("invoke", re.compile(r"<invoke\s+name=")),
)


def strip_quoted_code(text: str) -> str:
    """Remove fenced blocks and inline code spans — quoted syntax is not a leak."""
    return INLINE_CODE_RE.sub("", CODE_FENCE_RE.sub("", text))


def find_leaked_tool_calls(text: str) -> list[str]:
    """Markers present in `text` that indicate an unparsed, never-executed tool call."""
    if not text:
        return []
    scannable = strip_quoted_code(text)
    return [name for name, pattern in LEAKED_TOOL_CALL_PATTERNS if pattern.search(scannable)]


def extract_usage(event) -> tuple[int, int, int, float, str]:
    """Token counts and cost off an SDK RESULT event, with their PROVENANCE.

    The RESULT event carries `total_usage` (a TokenUsage) and `total_cost`;
    `usage`/`cost` are the PER-MESSAGE fields and are None on a RESULT. Reading
    only `usage` therefore returned nothing on every real run while passing
    every synthetic test — verified against a live LM Studio run on 2026-09-05,
    which reported usage_source=unavailable with the SDK holding the numbers all
    along. Both spellings are read here so an assistant-level event also works.

    cache_read_input_tokens is captured because cached input is the largest
    single cost lever and it is invisible in a raw input-token count: identical
    work can differ ~70x in spend on cache behaviour alone.

    Provenance is reported rather than defaulted, because a fabricated cost is
    worse than a missing one — it gets averaged into worker comparisons and
    silently moves routing decisions.
    """
    usage = getattr(event, "total_usage", None) or getattr(event, "usage", None)
    cost = getattr(event, "total_cost", None)
    if cost is None:
        cost = getattr(event, "cost", None)

    # No usage object AND no non-zero cost means the provider told us nothing.
    # `total_cost` defaults to 0.0, so it alone cannot distinguish "free" from
    # "unknown" — the usage object is what settles it. A local model that really
    # did cost nothing still reports source=sdk with real token counts.
    if usage is None and not cost:
        return 0, 0, 0, 0.0, "unavailable"

    inp = int(getattr(usage, "input_tokens", 0) or 0)
    out = int(getattr(usage, "output_tokens", 0) or 0)
    cached = int(getattr(usage, "cache_read_input_tokens", 0) or 0)
    cost = float(cost or 0.0)

    # An all-zero usage object carries no information — it is indistinguishable
    # from a provider that sent an empty struct. Reporting it as "sdk" would
    # claim we know a floor of zero when we know nothing, which is the same
    # fabricated-certainty failure as pricing an unpriced model.
    if not (inp or out or cached or cost):
        return 0, 0, 0, 0.0, "unavailable"

    return inp, out, cached, cost, "sdk"


try:
    from open_agent_sdk.utils.tokens import MODEL_PRICING as _SDK_MODEL_PRICING
except Exception:  # pragma: no cover - SDK internals may move
    _SDK_MODEL_PRICING = {}


def model_is_priced(model: str) -> bool:
    """Does the SDK have a real price for this model?

    `estimate_cost` matches MODEL_PRICING by prefix and, on a miss, silently
    falls back to {"input": 3.0, "output": 15.0} — frontier-Claude rates. The
    table holds only Anthropic/OpenAI names, so EVERY worker this repo routes to
    (local qwen, deepseek, glm) misses and is billed at that invented rate. A
    live local run on 2026-09-05 reported $0.063 for a model that costs nothing.

    That number is not merely imprecise, it is the same invented rate for every
    worker, so comparing workers on it compares token counts wearing a dollar
    sign — while looking entirely plausible. Hence: report the estimate, but
    never let it be mistaken for a price.

    EXACT match only. The first cut prefix-matched in both directions, which
    priced `deepseek-chat-v3-0324-mlx` off the `deepseek-chat` key and matched
    a one-character model id `g` against `gpt-4o`. Prefix matching answers "is
    there a vendor model whose name starts like this", which is not the question
    — the question is whether THIS request was billed at a rate we know, and a
    name has never been evidence of that.
    """
    if not PROVIDER["billable"]:
        return False
    return model in _SDK_MODEL_PRICING


@dataclass
class RunState:
    initial_snapshot: str
    prompts_sent: int = 0
    leaked_tool_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cached_tokens: int = 0
    cost_usd: float = 0.0
    usage_source: str = "unavailable"

    def absorb(self, outcome: "PromptOutcome") -> None:
        """Accumulate ONE prompt's usage AND its leaked tool calls.

        Called after EVERY prompt, including intermediate continuations. A run
        that continues four times and is only measured on the first and last
        prompt under-reports its own cost, which defeats the point of measuring.

        Leaks live here rather than at the call sites because keeping the two
        counters in separate places is exactly how they drifted: the leak total
        was accumulated once after prompt 1 and once after the loop, which
        double-counted prompt 1 on the normal break path and dropped the leaks
        of every continuation except the last. One absorb point, one chance to
        get it wrong.
        """
        self.input_tokens += outcome.input_tokens
        self.output_tokens += outcome.output_tokens
        self.cached_tokens += outcome.cached_tokens
        self.cost_usd += outcome.cost_usd
        self.leaked_tool_calls += outcome.leaked_tool_calls
        if outcome.usage_source != "unavailable":
            self.usage_source = outcome.usage_source


@dataclass
class PromptOutcome:
    text: str = ""
    num_turns: int | None = None
    status: SDKResultStatus | None = None
    saw_result: bool = False
    leaked_tool_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cached_tokens: int = 0
    cost_usd: float = 0.0
    usage_source: str = "unavailable"


class WorkerLogger:
    """Emit concise lifecycle records to stderr and a durable worker log."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, message: str) -> None:
        timestamp = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        line = f"{timestamp} {message}"
        print(line, file=sys.stderr, flush=True)
        with self.path.open("a", encoding="utf-8") as log_file:
            log_file.write(line + "\n")


def default_log_path() -> pathlib.Path:
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    return DEFAULT_LOG_DIR / f"{PROVIDER['label']}-{timestamp}-{os.getpid()}.log"


def result_text(result) -> str:
    return result.text.strip()


def result_num_turns(result) -> int | None:
    return result.num_turns


def result_status_name(result: PromptOutcome) -> str:
    return result.status.value if result.status is not None else "missing"


def result_succeeded(result: PromptOutcome) -> bool:
    return result.saw_result and result.status == SDKResultStatus.SUCCESS


# Tool-input logging: what a worker SEARCHED FOR, not just how often.
#
# The log recorded `tool start names=Grep,Grep` and discarded the arguments, so a
# worker could grep twelve times and the log would say only that it grepped
# twelve times. That is the "verify from evidence, not the self-report" rule
# failing at the one layer where a worker actually acts — and it made two agent
# runtimes impossible to compare like for like, because only one of them had
# instrumented tools.
#
# Three rules, because a tool input is not a safe thing to log verbatim:
#
#   1. BULK CONTENT IS ELIDED, never printed. A Write carries a whole file and an
#      Edit carries both sides of a replacement; those would bury the log and
#      could dump source into it. Rendered as `[N chars]`, after curl's
#      `[N bytes data]` — the size is the useful part, the body is not.
#   2. IDENTIFYING PARAMS ARE KEPT, truncated. `pattern`, `path`, `command`,
#      `file_path` are the audit trail; they are what makes a run reviewable.
#   3. ANYTHING THAT LOOKS LIKE A SECRET IS REDACTED. A worker can read a .env or
#      echo a token, and that value must not be copied into a log that is kept,
#      shipped to velo-record, and read by a human later.
_TOOL_INPUT_ELIDE_KEYS = frozenset({
    "content", "new_string", "old_string", "file_text", "replacement", "text",
})
_TOOL_INPUT_SECRET_KEYS = ("key", "token", "secret", "password", "passwd", "auth", "credential")
_TOOL_INPUT_SECRET_VALUE = re.compile(
    r"(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{12,}|xox[abpsr]-[A-Za-z0-9-]{10,})"
)
_TOOL_INPUT_MAX_VALUE = 160
_TOOL_INPUT_MAX_LINE = 400


def summarise_tool_input(raw: Any) -> str:
    """One line describing a tool call's arguments, safe to keep.

    Grep(pattern="merge_left_with_nulls", path="src/")
    Write(file_path="x.rs", content=[4096 chars])
    Bash(command="export TOKEN=[redacted]")
    """
    if not isinstance(raw, dict) or not raw:
        return ""
    parts: list[str] = []
    for key, value in raw.items():
        lowered = str(key).lower()
        if lowered in _TOOL_INPUT_ELIDE_KEYS and isinstance(value, str):
            parts.append(f"{key}=[{len(value)} chars]")
            continue
        if any(s in lowered for s in _TOOL_INPUT_SECRET_KEYS):
            parts.append(f"{key}=[redacted]")
            continue
        rendered = value if isinstance(value, str) else repr(value)
        rendered = _TOOL_INPUT_SECRET_VALUE.sub("[redacted]", rendered)
        # A newline would break the one-event-per-line contract every reader of
        # these logs relies on, including velo-record's greps.
        rendered = rendered.replace("\n", "\\n").replace("\r", "")
        if len(rendered) > _TOOL_INPUT_MAX_VALUE:
            rendered = rendered[:_TOOL_INPUT_MAX_VALUE] + f"…[+{len(rendered) - _TOOL_INPUT_MAX_VALUE} chars]"
        parts.append(f'{key}="{rendered}"' if isinstance(value, str) else f"{key}={rendered}")
    line = ", ".join(parts)
    if len(line) > _TOOL_INPUT_MAX_LINE:
        line = line[:_TOOL_INPUT_MAX_LINE] + "…"
    return line


def assistant_tool_calls(event) -> list[tuple[str, str]]:
    """(name, summarised input) for each tool_use block on an assistant event."""
    message = getattr(event, "message", None)
    if not isinstance(message, dict):
        return []
    content = message.get("content", [])
    if not isinstance(content, list):
        return []
    return [
        (block["name"], summarise_tool_input(block.get("input")))
        for block in content
        if isinstance(block, dict) and block.get("type") == "tool_use" and isinstance(block.get("name"), str)
    ]


def assistant_tool_names(event) -> list[str]:
    message = getattr(event, "message", None)
    if not isinstance(message, dict):
        return []
    content = message.get("content", [])
    if not isinstance(content, list):
        return []
    return [
        block["name"]
        for block in content
        if isinstance(block, dict) and block.get("type") == "tool_use" and isinstance(block.get("name"), str)
    ]


def log_sdk_event(logger: WorkerLogger, label: str, event) -> None:
    event_type = getattr(event.type, "value", str(event.type))
    if event.type == SDKMessageType.SYSTEM:
        subtype = getattr(getattr(event, "subtype", None), "value", "unknown")
        logger.emit(f"[{label}] sdk system event={subtype}")
    elif event.type == SDKMessageType.ASSISTANT:
        tool_names = assistant_tool_names(event)
        text_length = len(getattr(event, "text", "") or "")
        if tool_names:
            calls = assistant_tool_calls(event)
            detail = "  ".join(f"{n}({a})" if a else f"{n}()" for n, a in calls)
            logger.emit(f"[{label}] tool start names={','.join(tool_names)}"
                        + (f" | {detail}" if detail else ""))
        else:
            logger.emit(f"[{label}] sdk assistant text_len={text_length}")
    elif event.type == SDKMessageType.TOOL_RESULT:
        tool_name = getattr(event, "tool_name", "unknown") or "unknown"
        result_length = len(getattr(event, "result_content", "") or "")
        outcome = "error" if getattr(event, "is_error", False) else "ok"
        logger.emit(f"[{label}] tool completed name={tool_name} outcome={outcome} result_len={result_length}")
    elif event.type == SDKMessageType.RESULT:
        status = getattr(getattr(event, "status", None), "value", "missing")
        logger.emit(
            f"[{label}] sdk result status={status} turns={getattr(event, 'num_turns', 0)} "
            f"text_len={len(getattr(event, 'text', '') or '')}"
        )
    else:
        logger.emit(f"[{label}] sdk event={event_type}")


async def collect_prompt_events(
    agent, prompt: str, logger: WorkerLogger, label: str, outcome: PromptOutcome | None = None
) -> PromptOutcome:
    """Run a prompt through the SDK stream so tool lifecycle events are observable.

    `outcome` is accepted from the caller so that a prompt which dies MID-FLIGHT
    still leaves its partial usage somewhere the caller can reach. Tokens spent
    before a 402 or a timeout were really spent; a run that burned 42 turns and
    then died recorded input_tokens=0, which biases every later cost comparison
    towards whichever worker fails most often.
    """
    outcome = outcome if outcome is not None else PromptOutcome()
    async for event in agent.query(prompt):
        log_sdk_event(logger, label, event)
        if event.type == SDKMessageType.RESULT:
            outcome.saw_result = True
            outcome.text = event.text or ""
            outcome.num_turns = event.num_turns
            outcome.status = event.status
            inp, out, cached, cost, source = extract_usage(event)
            if source != "unavailable":
                # RESULT carries total_usage — CUMULATIVE for the whole prompt.
                # Replace the per-message tally rather than adding to it, or the
                # assistant-level accumulation below is counted twice.
                outcome.input_tokens = inp
                outcome.output_tokens = out
                outcome.cached_tokens = cached
                outcome.cost_usd = cost
                outcome.usage_source = source
        if event.type == SDKMessageType.ASSISTANT:
            # Per-message usage, accumulated as we go. If a RESULT arrives it
            # supersedes this; if the prompt dies first, this is all the honest
            # accounting that exists. Marked "sdk-partial" so a consumer can
            # tell an incomplete tally from a complete one.
            inp, out, cached, cost, source = extract_usage(event)
            if source != "unavailable":
                outcome.input_tokens += inp
                outcome.output_tokens += out
                outcome.cached_tokens += cached
                outcome.cost_usd += cost
                outcome.usage_source = "sdk-partial"
        if event.type == SDKMessageType.ASSISTANT and event.text:
            # Preserve the SDK's fallback text behaviour, but never mistake it
            # for a final response unless a RESULT event is also received.
            outcome.text = event.text
        if event.type in (SDKMessageType.RESULT, SDKMessageType.ASSISTANT):
            leaked = find_leaked_tool_calls(event.text or "")
            if leaked:
                outcome.leaked_tool_calls += 1
                logger.emit(
                    f"[{label}] WARNING leaked-tool-call markers={','.join(leaked)} "
                    "— the model emitted tool-call syntax as TEXT; that call never ran"
                )
    return outcome


async def prompt_with_watchdog(
    agent,
    prompt: str,
    logger: WorkerLogger,
    label: str,
    timeout_seconds: float,
    outcome: PromptOutcome | None = None,
) -> PromptOutcome:
    started = time.monotonic()
    logger.emit(f"[{label}] start timeout_seconds={timeout_seconds:g}")
    # The caller may pass its own outcome object so that partial usage survives
    # an exception — see collect_prompt_events. Tokens spent before a failure
    # were still spent.
    outcome = outcome if outcome is not None else PromptOutcome()
    try:
        outcome = await asyncio.wait_for(
            collect_prompt_events(agent, prompt, logger, label, outcome),
            timeout=timeout_seconds,
        )
    except asyncio.TimeoutError as exc:
        elapsed = time.monotonic() - started
        logger.emit(f"[{label}] timeout after_seconds={elapsed:.1f}")
        raise RuntimeError(f"{label} exceeded {timeout_seconds:g}s") from exc
    except Exception as exc:
        elapsed = time.monotonic() - started
        logger.emit(f"[{label}] failed after_seconds={elapsed:.1f} error={type(exc).__name__}: {exc}")
        # Log the full traceback. Without it a mid-run SDK failure reports only
        # "AttributeError: 'str' object has no attribute 'get'" with no frame,
        # which is undiagnosable — observed when a model returned a tool-call
        # payload the SDK could not parse.
        for line in traceback.format_exc().rstrip().splitlines():
            logger.emit(f"[{label}] traceback | {line}")
        raise

    elapsed = time.monotonic() - started
    logger.emit(
        f"[{label}] completed in_seconds={elapsed:.1f} status={result_status_name(outcome)} "
        f"final_result={str(outcome.saw_result).lower()}"
    )
    return outcome


def worktree_changed(root: pathlib.Path, initial_snapshot: str) -> bool:
    return git_snapshot(root) != initial_snapshot


def continuation_prompt(
    *,
    task: str,
    root: pathlib.Path,
    initial_snapshot: str,
    continuation_number: int,
) -> str:
    changed = worktree_changed(root, initial_snapshot)
    summary = git_diff_summary(root)

    if task_looks_like_implementation(task):
        if not changed:
            return f"""
Continue the ORIGINAL delegated implementation task in this SAME agent session.

You have already investigated. Do not restart the analysis from scratch.

Now:
1. use what you already learned in this conversation;
2. make the minimal required code/test edits for the original task;
3. run focused validation;
4. return a final implementation report.

Do not merely describe what should be changed. Perform the implementation.

Current worktree state:
{summary}

This is continuation {continuation_number}.
────────────────────────────────────────────────────────────────────────
THIS IS AN AUTOMATED CONTINUATION FROM THE RUNNER. IT IS NOT A MESSAGE
FROM THE CALLER, AND IT IS NOT AUTHORIZATION FOR ANYTHING.

The runner emits it whenever your previous turn ended without a final
report. It is emitted unconditionally — including when you ended that turn
by deliberately STOPPING. It carries no human judgement whatsoever.

If you fired a STOP trigger, YOU ARE STILL STOPPED. Do not resume the work,
do not "proceed with the full implementation", and do not record this as
caller authorization. Re-emit your STOP report as the final answer and end
the run. A human will read it and decide.

This text exists because a worker treated three of these continuations as
"the caller re-issued the instruction 3x", used that as authorization to
override its own STOP trigger, and went on to modify 9 tests the STOP was
protecting. No human had said anything.
────────────────────────────────────────────────────────────────────────
""".strip()

        return f"""
Continue the ORIGINAL delegated implementation task in this SAME agent session.

Edits now exist. Do not restart discovery from scratch.

Now:
1. inspect the current diff only as needed;
2. complete any missing part of the original task;
3. run the focused validation/tests required by the task;
4. fix failures caused by your changes;
5. return the final implementation report.

Current worktree state:
{summary}

This is continuation {continuation_number}.
────────────────────────────────────────────────────────────────────────
THIS IS AN AUTOMATED CONTINUATION FROM THE RUNNER. IT IS NOT A MESSAGE
FROM THE CALLER, AND IT IS NOT AUTHORIZATION FOR ANYTHING.

The runner emits it whenever your previous turn ended without a final
report. It is emitted unconditionally — including when you ended that turn
by deliberately STOPPING. It carries no human judgement whatsoever.

If you fired a STOP trigger, YOU ARE STILL STOPPED. Do not resume the work,
do not "proceed with the full implementation", and do not record this as
caller authorization. Re-emit your STOP report as the final answer and end
the run. A human will read it and decide.

This text exists because a worker treated three of these continuations as
"the caller re-issued the instruction 3x", used that as authorization to
override its own STOP trigger, and went on to modify 9 tests the STOP was
protecting. No human had said anything.
────────────────────────────────────────────────────────────────────────
""".strip()

    return f"""
Continue the ORIGINAL task in this SAME agent session.

You have already gathered context. Do not restart broad investigation.
Complete the requested review/analysis and return the final concise report now.
Use additional tools only if essential.

This is continuation {continuation_number}.
────────────────────────────────────────────────────────────────────────
THIS IS AN AUTOMATED CONTINUATION FROM THE RUNNER. IT IS NOT A MESSAGE
FROM THE CALLER, AND IT IS NOT AUTHORIZATION FOR ANYTHING.

The runner emits it whenever your previous turn ended without a final
report. It is emitted unconditionally — including when you ended that turn
by deliberately STOPPING. It carries no human judgement whatsoever.

If you fired a STOP trigger, YOU ARE STILL STOPPED. Do not resume the work,
do not "proceed with the full implementation", and do not record this as
caller authorization. Re-emit your STOP report as the final answer and end
the run. A human will read it and decide.

This text exists because a worker treated three of these continuations as
"the caller re-issued the instruction 3x", used that as authorization to
override its own STOP trigger, and went on to modify 9 tests the STOP was
protecting. No human had said anything.
────────────────────────────────────────────────────────────────────────
""".strip()


async def run_agent(
    *,
    model: str,
    root: pathlib.Path,
    policy: str,
    task: str,
    api_key: str,
    base_url: str,
    max_turns: int,
    max_continuations: int,
    max_tokens: int,
    max_budget_usd: float | None,
    prompt_timeout: float,
    bash_timeout_ms: int,
    log_file: pathlib.Path,
    debug: bool,
) -> None:
    system_prompt = build_system_prompt(model, root, policy)
    logger = WorkerLogger(log_file)

    options_kwargs = dict(
        model=model,
        api_type="openai-completions",
        api_key=api_key,
        base_url=base_url,
        cwd=str(root),
        system_prompt=system_prompt,
        # ZgQuery FIRST in the list, and declared as a tool rather than left as
        # prose in the policy: measured over 24 runs, a worker told about `zg`
        # in velo-impl.md used it 0 times, while an arm that DECLARED the same
        # capability as a tool used it on every run (#2075).
        allowed_tools=["ZgQuery", "Read", "Glob", "Grep", "Bash", "Edit", "Write"],
        tools=[ZgQueryTool()],
        permission_mode="bypassPermissions",
        env=worker_env(bash_timeout_ms),
        max_turns=max_turns,
        max_tokens=max_tokens,
        persist_session=False,
        debug=debug,
        # The installed SDK does not currently consume `debug_file`, but
        # passing it preserves compatibility if it gains support later. The
        # event stream is logged by `collect_prompt_events` today.
        debug_file=str(logger.path),
    )
    if max_budget_usd is not None:
        options_kwargs["max_budget_usd"] = max_budget_usd

    # Before any tool can run: the SDK hands a provider's tool-call `input`
    # downstream as a str on two paths, and the first `.get()` on it kills the
    # run mid-flight with nothing committed (#2010 — one dispatch lost 9.9M
    # input tokens that way).
    if not install_tool_input_normalisation(logger):
        logger.emit("WARNING string tool-call inputs are NOT normalised — see #2010")

    # Pin the provider endpoint and ask for real usage (#2007 F1/F2). OpenRouter
    # load-balances every request, and a prefix cache is per-endpoint, so an
    # agent loop that re-sends its transcript each turn missed the cache on every
    # turn — measured 97% cached and 4.4x cheaper once pinned.
    LEDGER.reset()
    if PROVIDER["pin_provider"]:
        install_provider_pinning(model, logger)
    # Real context windows, so auto-compaction stops tripping ~5x too early
    # (#2007 F4). The compactor itself is deliberately left broken — see the
    # docstring; a working one discards the whole conversation.
    install_context_windows(logger)

    agent = create_agent(AgentOptions(**options_kwargs))
    state = RunState(initial_snapshot=git_snapshot(root))

    async def run_prompt(prompt_text: str, label: str) -> PromptOutcome:
        """One prompt, whose usage is absorbed even when it dies mid-flight.

        Every prompt goes through here so the accounting cannot diverge between
        the first prompt and the continuations. The `except` is the point of it:
        a prompt killed by a timeout or a 402 has still spent whatever it spent,
        and dropping that produced records reading input_tokens=0 for runs that
        had really burned dozens of turns.
        """
        partial = PromptOutcome()
        try:
            outcome = await prompt_with_watchdog(
                agent, prompt_text, logger, label, prompt_timeout, partial
            )
        except Exception:
            state.absorb(partial)
            raise
        state.prompts_sent += 1
        state.absorb(outcome)
        return outcome

    try:
        startup = (
            f"[{PROVIDER['label']}:{model}] backend=open-agent-sdk "
            f"api_type={agent.get_api_type()} max_turns={max_turns} "
            f"max_continuations={max_continuations} prompt_timeout={prompt_timeout:g}s "
            f"bash_timeout={bash_timeout_ms}ms "
            f"log_file={logger.path}"
        )
        logger.emit(startup)

        # The runner knows the cap; the worker only ever learned it from
        # whatever the brief author wrote (#2007 F5).
        result = await run_prompt(task + turn_budget_notice(max_turns), "prompt 1")

        for continuation_number in range(1, max_continuations + 1):
            text = result_text(result)
            turns = result_num_turns(result)
            changed = worktree_changed(root, state.initial_snapshot)

            if not result_succeeded(result):
                continue_needed = True
                reason = f"SDK result status={result_status_name(result)}"
            elif task_is_read_only(task):
                continue_needed = not bool(text)
                reason = "read-only task returned no final text" if continue_needed else "complete"
            elif task_looks_like_implementation(task):
                if not changed:
                    continue_needed = True
                    reason = "implementation returned without worktree changes"
                elif text and (turns is None or turns < max_turns):
                    continue_needed = False
                    reason = "implementation changed worktree and returned final text"
                else:
                    continue_needed = True
                    reason = "implementation needs validation/finalization"
            else:
                continue_needed = not bool(text)
                reason = "task returned no final text" if continue_needed else "complete"

            if not continue_needed:
                break

            logger.emit(
                f"[{PROVIDER['label']}:{model}] continuation={continuation_number} "
                f"reason={reason}"
            )

            result = await run_prompt(
                continuation_prompt(
                    task=task,
                    root=root,
                    initial_snapshot=state.initial_snapshot,
                    continuation_number=continuation_number,
                ),
                f"continuation {continuation_number}",
            )

        final_text = result_text(result)
        changed = worktree_changed(root, state.initial_snapshot)

        if task_looks_like_implementation(task) and not changed:
            fail(
                "SDK worker exhausted same-session continuation attempts without "
                "making worktree changes for an implementation task."
            )

        if not result.saw_result:
            fail("SDK worker exhausted same-session continuation attempts without a final RESULT event.")

        if not result_succeeded(result):
            fail(f"SDK worker ended with result status {result_status_name(result)}.")

        if not final_text:
            fail(
                "SDK worker exhausted same-session continuation attempts without "
                "a final response."
            )

        print(final_text, flush=True)

        turns = result_num_turns(result)
        logger.emit(
            f"[{PROVIDER['label']}:{model}] prompts={state.prompts_sent} "
            f"final_turns={turns if turns is not None else 'unknown'} "
            f"changed={str(changed).lower()} "
            f"leaked_tool_calls={state.leaked_tool_calls}"
        )

        # A leaked tool call means an intended action never ran, yet the turn
        # still reported success. Surfacing it is the whole point — never let
        # this exit 0 and be mistaken for a clean run.
        if state.leaked_tool_calls:
            fail(
                f"{state.leaked_tool_calls} leaked tool call(s): the model emitted "
                "tool-call syntax as plain text, so those calls never executed. "
                "The run's final report is therefore not trustworthy. Re-run, "
                "avoiding nested quotes in the task string."
            )

    except SystemExit:
        # fail() lands here. The run is over either way; salvage first (#2007 F3).
        salvage_on_failure(root=str(root), agent=agent, log_path=str(logger.path),
                           reason="stop-or-fail", read_only=task_is_read_only(task),
                           logger=logger)
        raise
    except Exception as exc:
        # Timeout, 402, SDK crash. agent._engine.messages still holds every turn
        # of the dead prompt at this instant; after the raise it is gone.
        salvage_on_failure(root=str(root), agent=agent, log_path=str(logger.path),
                           reason=type(exc).__name__, read_only=task_is_read_only(task),
                           logger=logger)
        fail(f"{type(exc).__name__}: {exc}")
    finally:
        # Emitted from `finally`, so it is present on EVERY exit path — including
        # a timeout, a crash, and the leaked-tool-call failure below. A totals
        # line that only appears on the happy path measures only the happy path,
        # and the failures are the rows worth having.
        # Token counts come from the provider and are real. The dollar figure is
        # the SDK's own estimate, and for an unpriced model it is an invented
        # rate — so it is labelled, not silently passed off as a price.
        usage_source = state.usage_source
        # OpenRouter returns the REAL billed cost when usage.include is set. It
        # beats the SDK's price-table estimate outright, and it retires the
        # invented-rate problem for this path rather than labelling it.
        cost_usd = state.cost_usd
        cached_tokens = state.cached_tokens
        # `billable` gates this too (#2018 F1). The LEDGER is fed from
        # install_tool_input_normalisation, which runs on BOTH profiles, so
        # without this a local run against any OpenAI-compatible gateway that
        # reports usage.cost would write usage_source=openrouter-billed — naming
        # the wrong provider in the field routing decisions are read from.
        if PROVIDER["billable"] and LEDGER.saw_real_cost:
            cost_usd = LEDGER.cost_usd
            cached_tokens = LEDGER.cached_tokens
            usage_source = "openrouter-billed"
        elif usage_source.startswith("sdk") and not model_is_priced(model):
            usage_source += "-unpriced"
        logger.emit(
            f"TOTALS prompts={state.prompts_sent} "
            f"leaked_tool_calls={state.leaked_tool_calls} "
            f"input_tokens={state.input_tokens} "
            f"output_tokens={state.output_tokens} "
            f"cached_tokens={cached_tokens} "
            f"cost_usd={cost_usd:.6f} "
            f"usage_source={usage_source} "
            # The runner is the only place that knows whether this task was
            # classified read-only. Without it the recorder scores a review gate
            # — which correctly produces no commits — as "abandoned", and every
            # review in the history reads as a failed run.
            f"read_only={str(task_is_read_only(task)).lower()}"
        )
        try:
            await agent.close()
        except Exception as exc:
            logger.emit(f"WARNING: failed to close SDK agent cleanly: {type(exc).__name__}: {exc}")


def run(provider: str) -> None:
    """Entry point for the two thin shims. Selects the profile, then main()."""
    global PROVIDER, DEFAULT_MODEL, DEFAULT_BASE_URL
    if provider not in PROVIDERS:
        fail(f"unknown provider profile {provider!r}; have {sorted(PROVIDERS)}")
    PROVIDER = PROVIDERS[provider]
    DEFAULT_MODEL = PROVIDER["default_model"]
    DEFAULT_BASE_URL = PROVIDER["default_base_url"]
    main()


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            f"Run {PROVIDER['label']} as a persistent same-session Velostream "
            "implementation worker via Open Agent SDK."
        )
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument(
        "--skill",
        action="append",
        default=[],
        metavar="NAME",
        help=(
            "Inline a skill definition ahead of the task (repeatable, or "
            "comma-separated). Resolved from ~/.agents/skills/<n>/SKILL.md, "
            "~/.claude/skills/<n>/SKILL.md, then ~/.claude/commands/<n>.md."
        ),
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get(PROVIDER["base_url_env"], DEFAULT_BASE_URL),
        help=f"OpenAI-compatible provider base URL (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--max-turns",
        type=int,
        default=DEFAULT_MAX_TURNS,
        help=f"Maximum agentic turns per prompt (default: {DEFAULT_MAX_TURNS})",
    )
    parser.add_argument(
        "--max-continuations",
        type=int,
        default=DEFAULT_MAX_CONTINUATIONS,
        help=(
            "Maximum same-session continuation prompts after the initial prompt "
            f"(default: {DEFAULT_MAX_CONTINUATIONS})"
        ),
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=DEFAULT_MAX_TOKENS,
        help=f"Maximum output tokens per model response (default: {DEFAULT_MAX_TOKENS})",
    )
    parser.add_argument(
        "--max-budget-usd",
        type=float,
        default=None,
        help="Optional SDK spending cap for this agent run.",
    )
    parser.add_argument(
        "--bash-timeout-ms",
        type=int,
        default=DEFAULT_BASH_TIMEOUT_MS,
        help=(
            "Maximum milliseconds for a single Bash tool command "
            f"(default: {DEFAULT_BASH_TIMEOUT_MS}). The SDK's own default is "
            "600000, which is shorter than a cold cargo test sweep."
        ),
    )
    parser.add_argument(
        "--prompt-timeout",
        type=float,
        default=DEFAULT_PROMPT_TIMEOUT_SECONDS,
        help=(
            "Maximum seconds for each initial or continuation prompt "
            f"(default: {DEFAULT_PROMPT_TIMEOUT_SECONDS})."
        ),
    )
    parser.add_argument(
        "--log-file",
        type=pathlib.Path,
        default=None,
        help=(
            "Write timestamped SDK event/progress records here. Defaults to "
            f"~/.agents/logs/{PROVIDER['label']}-<timestamp>.log."
        ),
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable Open Agent SDK debug output.",
    )
    args = parser.parse_args()

    if args.max_turns < 1:
        fail("--max-turns must be >= 1")
    if args.max_continuations < 0:
        fail("--max-continuations must be >= 0")
    if args.max_tokens < 1:
        fail("--max-tokens must be >= 1")
    if args.max_budget_usd is not None and args.max_budget_usd <= 0:
        fail("--max-budget-usd must be > 0")
    if args.prompt_timeout <= 0:
        fail("--prompt-timeout must be > 0")
    if args.bash_timeout_ms < 1:
        fail("--bash-timeout-ms must be >= 1")

    api_key = next((os.environ[e] for e in PROVIDER["api_key_envs"] if os.environ.get(e)),
                   PROVIDER["api_key_fallback"])
    if not api_key:
        fail(" (or ".join(PROVIDER["api_key_envs"]) + ") is not set"
             if len(PROVIDER["api_key_envs"]) > 1 else
             PROVIDER["api_key_envs"][0] + " is not set")

    skills = [n for item in args.skill for n in item.split(",") if n.strip()]

    root = pathlib.Path(args.cwd).expanduser().resolve()
    policy_path = pathlib.Path(args.policy).expanduser().resolve()

    if not root.is_dir():
        fail(f"worktree does not exist: {root}")
    if not policy_path.is_file():
        fail(f"policy file does not exist: {policy_path}")

    policy = policy_path.read_text(errors="replace")

    asyncio.run(
        run_agent(
            model=args.model,
            root=root,
            policy=policy,
            task=apply_skills(args.task, skills),
            api_key=api_key,
            base_url=args.base_url,
            max_turns=args.max_turns,
            max_continuations=args.max_continuations,
            max_tokens=args.max_tokens,
            max_budget_usd=args.max_budget_usd,
            prompt_timeout=args.prompt_timeout,
            bash_timeout_ms=args.bash_timeout_ms,
            log_file=args.log_file or default_log_path(),
            debug=args.debug,
        )
    )


if __name__ == "__main__":
    # Not an entry point. install.sh chmod +x's every file in bin/, so this would
    # otherwise be runnable directly — silently under the openrouter profile, and
    # with an argv velo-status:48's pgrep pattern does not match, making the run
    # invisible (#2018 F6). Use the shims.
    fail("velo_worker_runner.py is a library. Run velo-openrouter-agent-sdk.py "
         "or velo-lmstudio-agent-sdk.py, which select a provider profile.")

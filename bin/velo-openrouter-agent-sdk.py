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
from datetime import UTC, datetime

from open_agent_sdk import AgentOptions, create_agent
from open_agent_sdk.types import SDKMessageType, SDKResultStatus

DEFAULT_MODEL = "deepseek/deepseek-v4-flash-0731"
DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
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
    return f"""
You are a full autonomous Velostream implementation worker.

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


@dataclass
class RunState:
    initial_snapshot: str
    prompts_sent: int = 0
    leaked_tool_calls: int = 0


@dataclass
class PromptOutcome:
    text: str = ""
    num_turns: int | None = None
    status: SDKResultStatus | None = None
    saw_result: bool = False
    leaked_tool_calls: int = 0


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
    return DEFAULT_LOG_DIR / f"velo-openrouter-agent-{timestamp}-{os.getpid()}.log"


def result_text(result) -> str:
    return result.text.strip()


def result_num_turns(result) -> int | None:
    return result.num_turns


def result_status_name(result: PromptOutcome) -> str:
    return result.status.value if result.status is not None else "missing"


def result_succeeded(result: PromptOutcome) -> bool:
    return result.saw_result and result.status == SDKResultStatus.SUCCESS


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
            logger.emit(f"[{label}] tool start names={','.join(tool_names)}")
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


async def collect_prompt_events(agent, prompt: str, logger: WorkerLogger, label: str) -> PromptOutcome:
    """Run a prompt through the SDK stream so tool lifecycle events are observable."""
    outcome = PromptOutcome()
    async for event in agent.query(prompt):
        log_sdk_event(logger, label, event)
        if event.type == SDKMessageType.RESULT:
            outcome.saw_result = True
            outcome.text = event.text or ""
            outcome.num_turns = event.num_turns
            outcome.status = event.status
        elif event.type == SDKMessageType.ASSISTANT and event.text:
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
) -> PromptOutcome:
    started = time.monotonic()
    logger.emit(f"[{label}] start timeout_seconds={timeout_seconds:g}")
    try:
        outcome = await asyncio.wait_for(
            collect_prompt_events(agent, prompt, logger, label),
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
""".strip()

    return f"""
Continue the ORIGINAL task in this SAME agent session.

You have already gathered context. Do not restart broad investigation.
Complete the requested review/analysis and return the final concise report now.
Use additional tools only if essential.

This is continuation {continuation_number}.
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
        allowed_tools=["Read", "Glob", "Grep", "Bash", "Edit", "Write"],
        permission_mode="bypassPermissions",
        env={
            "BASH_DEFAULT_TIMEOUT_MS": str(bash_timeout_ms),
            "BASH_MAX_TIMEOUT_MS": str(bash_timeout_ms),
        },
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

    agent = create_agent(AgentOptions(**options_kwargs))
    state = RunState(initial_snapshot=git_snapshot(root))

    try:
        startup = (
            f"[velo-openrouter-agent:{model}] backend=open-agent-sdk "
            f"api_type={agent.get_api_type()} max_turns={max_turns} "
            f"max_continuations={max_continuations} prompt_timeout={prompt_timeout:g}s "
            f"bash_timeout={bash_timeout_ms}ms "
            f"log_file={logger.path}"
        )
        logger.emit(startup)

        result = await prompt_with_watchdog(
            agent,
            task,
            logger,
            "prompt 1",
            prompt_timeout,
        )
        state.prompts_sent += 1
        state.leaked_tool_calls += result.leaked_tool_calls

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
                f"[velo-openrouter-agent:{model}] continuation={continuation_number} "
                f"reason={reason}"
            )

            result = await prompt_with_watchdog(
                agent,
                continuation_prompt(
                    task=task,
                    root=root,
                    initial_snapshot=state.initial_snapshot,
                    continuation_number=continuation_number,
                ),
                logger,
                f"continuation {continuation_number}",
                prompt_timeout,
            )
            state.prompts_sent += 1
        state.leaked_tool_calls += result.leaked_tool_calls

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
            f"[velo-openrouter-agent:{model}] prompts={state.prompts_sent} "
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
        raise
    except Exception as exc:
        fail(f"{type(exc).__name__}: {exc}")
    finally:
        try:
            await agent.close()
        except Exception as exc:
            logger.emit(f"WARNING: failed to close SDK agent cleanly: {type(exc).__name__}: {exc}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Run DeepSeek/OpenRouter as a persistent same-session Velostream "
            "implementation worker via Open Agent SDK."
        )
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument(
        "--base-url",
        default=os.environ.get("CODEANY_BASE_URL", DEFAULT_BASE_URL),
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
            "~/.agents/logs/velo-openrouter-agent-<timestamp>.log."
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

    api_key = os.environ.get("OPENROUTER_API_KEY") or os.environ.get("CODEANY_API_KEY")
    if not api_key:
        fail("OPENROUTER_API_KEY (or CODEANY_API_KEY) is not set")

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
            task=args.task,
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
    main()

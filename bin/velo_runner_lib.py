"""Shared runner helpers (#2007 F3).

Separate from `velo_sdk_patches` because these are not corrections to the SDK —
they are things the runner does around it. Both runners import this; it exists
once so the salvage path cannot be present in one and missing from the other.
"""
from __future__ import annotations

import asyncio
import json
import pathlib
import random
import subprocess
from typing import Any, Awaitable, Callable


def local_conf(key: str) -> str:
    """One plain value from velo-local.conf, the file that defines the local
    model, endpoint and sampling for every script. The shell tools source it;
    both Python runners read it through this one function. A missing or empty
    entry raises: there is nothing to fall back to.
    """
    conf = pathlib.Path(__file__).with_name("velo-local.conf")
    for line in conf.read_text().splitlines():
        k, sep, value = line.strip().partition("=")
        if sep and k == key and value.strip():
            return value.split(" #", 1)[0].strip().strip('"')
    raise RuntimeError(f"{conf} does not set {key}")


def local_base_url() -> str:
    """The endpoint worker:local uses right now. Resolved by SOURCING
    velo-local.conf — the backend choice is shell logic there, and re-deriving it
    here would be a second definition to drift."""
    conf = pathlib.Path(__file__).with_name("velo-local.conf")
    out = subprocess.run(["bash", "-c", f'. "{conf}" && printf %s "${{VELO_LOCAL_BASE_URL:-}}"'],
                         capture_output=True, text=True, timeout=10)
    if out.returncode != 0 or not out.stdout:
        raise RuntimeError(f"{conf} did not resolve VELO_LOCAL_BASE_URL: {out.stderr.strip()}")
    return out.stdout


def _git(root: str, *args: str) -> tuple[int, str]:
    r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    return r.returncode, (r.stdout or r.stderr).strip()


def worktree_is_dirty(root: str) -> bool:
    _, out = _git(root, "status", "--porcelain")
    return bool(out.strip())


def salvage_on_failure(
    *,
    root: str,
    agent: Any,
    log_path: str,
    reason: str,
    read_only: bool,
    logger=None,
) -> dict[str, Any]:
    """Preserve what a dying run produced. Never raises.

    Two runs have lost ALL their work to a wall-clock timeout. The defence until
    now was `velo-dispatch` refusing a brief that lacks an incremental-commit
    instruction — the harness ASKING THE MODEL to checkpoint. A property you need
    should be enforced by the system, not requested of it.

    Two things are salvaged, and they are independent:

    1. **A checkpoint commit**, for an implementation task whose worktree has
       uncommitted changes. Skipped for a read-only task: a review that dirties
       the tree it is reviewing is the failure `READ_ONLY_DECLARATION` exists to
       prevent, and committing on its behalf would manufacture exactly that.

    2. **The transcript.** `agent.py` writes conversation history back to the
       Agent only on clean completion, so a prompt killed by a timeout or a 402
       drops every turn it spent — while `agent._engine.messages` still holds
       them in memory at the moment we are killed. Reading them here is the only
       chance anyone gets. Note the runner exits after this, and the Agent is
       built with `persist_session=False`, so this file is for a HUMAN or the
       next brief; nothing automatically resumes from it (see #1914).
    """
    def _log(msg: str) -> None:
        if logger is not None:
            logger.emit(msg)

    result: dict[str, Any] = {"checkpoint": None, "transcript": None, "reason": reason}

    # --- 1. checkpoint --------------------------------------------------------
    try:
        if read_only:
            _log(f"salvage: read-only task, not committing (reason={reason})")
        elif not worktree_is_dirty(root):
            _log(f"salvage: worktree clean, nothing to checkpoint (reason={reason})")
        else:
            rc, _ = _git(root, "add", "-A")
            if rc == 0:
                rc, out = _git(root, "commit", "-m",
                               f"wip(harness): checkpoint on {reason}\n\n"
                               "Committed by the runner's salvage path, not by the worker.\n"
                               "The run did not finish; this preserves whatever it had done.")
                if rc == 0:
                    _, sha = _git(root, "rev-parse", "--short", "HEAD")
                    result["checkpoint"] = sha
                    _log(f"salvage: checkpoint commit {sha} (reason={reason})")
                else:
                    _log(f"salvage: commit failed: {out[:200]}")
    except Exception as exc:  # salvage must never mask the original failure
        _log(f"salvage: checkpoint raised {type(exc).__name__}: {exc}")

    # --- 2. transcript --------------------------------------------------------
    try:
        engine = getattr(agent, "_engine", None)
        messages = getattr(engine, "messages", None) if engine is not None else None
        if messages:
            dest = pathlib.Path(f"{log_path}.transcript.json")
            dest.write_text(json.dumps(messages, indent=2, default=str), encoding="utf-8")
            result["transcript"] = str(dest)
            _log(f"salvage: {len(messages)} messages -> {dest}")
        else:
            _log("salvage: no in-memory transcript to dump")
    except Exception as exc:
        _log(f"salvage: transcript dump raised {type(exc).__name__}: {exc}")

    return result


# ---- transient model-call failures -------------------------------------------
# A provider hiccup must not end a run that has the whole conversation in hand.
# Seen on the free tier (2026-10-25, #2593 replay): a 504 "Upstream idle timeout"
# returned as a 200 with an error payload and NO choices (the SDK then raised
# ModelBehaviorError and the run died at turn 86), a 429 "temporarily
# rate-limited upstream" at turn 6, both with the work still on disk. Retrying the
# single completion call keeps the conversation; restarting the task would not.
TRANSIENT_STATUS = frozenset({408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524})
TRANSIENT_RETRIES = 8
TRANSIENT_BASE_S = 5.0
TRANSIENT_CAP_S = 60.0
_TRANSIENT_EXC_NAMES = frozenset({"APITimeoutError", "APIConnectionError", "RateLimitError",
                                  "InternalServerError"})


def transient_status(exc: BaseException) -> int | None:
    """The HTTP status that makes `exc` worth retrying, 0 for a transport failure
    with no status, or None when it is not transient (400/401/403/404 are the
    caller's mistake and retrying them only burns time)."""
    code = getattr(exc, "status_code", None)
    if isinstance(code, int):
        return code if code in TRANSIENT_STATUS else None
    return 0 if type(exc).__name__ in _TRANSIENT_EXC_NAMES else None


def error_payload_status(resp: Any) -> int | None:
    """OpenRouter can answer 200 with {"error": {"code": 504, ...}} and no choices.
    Returns that code when it is transient, else None (including a normal response)."""
    if getattr(resp, "choices", None):
        return None
    err = getattr(resp, "error", None)
    if err is None:
        err = (getattr(resp, "model_extra", None) or {}).get("error")
    code = err.get("code") if isinstance(err, dict) else getattr(err, "code", None)
    try:
        code = int(code)
    except (TypeError, ValueError):
        return None
    return code if code in TRANSIENT_STATUS else None


def _retry_after(exc: BaseException) -> float | None:
    headers = getattr(getattr(exc, "response", None), "headers", None)
    try:
        return float(headers.get("retry-after")) if headers else None
    except (TypeError, ValueError, AttributeError):
        return None


async def call_with_transient_retry(
    call: Callable[[], Awaitable[Any]],
    emit: Callable[[str], None],
    *,
    retries: int = TRANSIENT_RETRIES,
    base_s: float = TRANSIENT_BASE_S,
    cap_s: float = TRANSIENT_CAP_S,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    jitter: Callable[[], float] = random.random,
) -> Any:
    """Run `call`, retrying transient provider failures with capped exponential
    backoff (honouring Retry-After). Anything else, and the last transient failure
    once `retries` is spent, is raised or returned unchanged so it still surfaces."""
    attempt = 0
    while True:
        try:
            resp = await call()
        except Exception as exc:
            status = transient_status(exc)
            if status is None or attempt >= retries:
                raise
            reason, wait_hint = f"{type(exc).__name__} {status or 'transport'}", _retry_after(exc)
        else:
            status = error_payload_status(resp)
            if status is None or attempt >= retries:
                return resp
            reason, wait_hint = f"error payload {status}, no choices", None
        attempt += 1
        wait = wait_hint if wait_hint is not None else min(cap_s, base_s * 2 ** (attempt - 1))
        wait = min(cap_s, wait) * (0.75 + 0.5 * jitter())
        emit(f"[prompt 1] transient model-call failure ({reason}) — retry "
             f"{attempt}/{retries} in {wait:.0f}s")
        await sleep(wait)


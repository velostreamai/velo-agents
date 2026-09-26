"""Shared runner helpers (#2007 F3).

Separate from `velo_sdk_patches` because these are not corrections to the SDK —
they are things the runner does around it. Both runners import this; it exists
once so the salvage path cannot be present in one and missing from the other.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
from typing import Any


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

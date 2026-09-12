"""`zg` as a first-class tool, because prose is not a capability.

`velo-impl.md` documents `zg query` SIX times, including the exact query for one
benchmark scenario verbatim. Across 24 measured runs our worker used it **zero
times**. An `openai-agents` arm given the same index, on the same repo, with
`zg_query` declared as an ordinary tool with a schema, reached for it **first on
every single run**.

The difference was not the model, the index or the prompt. Ours had
`allowed_tools=["Read","Glob","Grep","Bash","Edit","Write"]` — `zg` was a shell
string the model had to compose into `Bash` on the strength of a paragraph in a
41KB policy. Theirs had a declared tool.

A capability described in prose is not a capability the model uses. So this
declares it.

Two rules it inherits from the rest of this tooling:

  - **Degradation is never silent** (#2076). A missing index, a missing binary
    and a timeout each return a DISTINCT, explicit message. They must not look
    like "no results", because an agent cannot tell a broken tool from an empty
    codebase and will conclude the code does not exist.
  - **Output is capped, and the cap is stated.** A cap the model cannot see
    would have it read a partial answer as the whole answer.
"""
from __future__ import annotations

import pathlib
import shutil
import subprocess
from typing import Any

from open_agent_sdk.types import BaseTool, ToolContext, ToolInputSchema, ToolResult

# Generous: the value of this tool is one call replacing several searches, so a
# long result is the good case. Past this, truncation is announced.
MAX_OUTPUT_CHARS = 12_000
TIMEOUT_SECONDS = 90


class ZgQueryTool(BaseTool):
    """Semantic code discovery over the workspace index."""

    _name = "ZgQuery"
    _description = (
        "Semantic code search over a pre-built index of this repository. Ask in "
        "PLAIN ENGLISH what you are looking for — e.g. 'where is the null-padded "
        "column set for an unmatched outer join row decided'. Returns ranked hits "
        "with file, line range, and the ENCLOSING SYMBOL NAME AND SCOPE for each.\n\n"
        "USE THIS FIRST for any 'where is the code that does X' question, before "
        "Grep or Glob. Grep needs a term you can only guess at before you know the "
        "symbol name; this does not. Once you have a symbol name, Grep and Read are "
        "the right tools to confirm it."
    )

    def __init__(self) -> None:
        self._input_schema = ToolInputSchema(
            type="object",
            properties={
                "question": {
                    "type": "string",
                    "description": (
                        "What you are looking for, in plain English. A full "
                        "question works better than keywords."
                    ),
                },
            },
            required=["question"],
        )

    def is_read_only(self, input: dict[str, Any] | None = None) -> bool:
        return True

    def is_concurrency_safe(self, input: dict[str, Any] | None = None) -> bool:
        return True

    async def call(self, input: dict[str, Any], context: ToolContext) -> ToolResult:
        question = (input or {}).get("question", "")
        if not isinstance(question, str) or not question.strip():
            return ToolResult(
                tool_use_id="",
                content="Error: `question` is required (plain English, not keywords).",
                is_error=True,
            )

        # The runner guarantees ~/.agents/bin on the worker's PATH, but resolve
        # explicitly so a PATH regression reports THAT rather than surfacing as
        # an empty search — the exact confusion #2076 exists to prevent.
        zg = shutil.which("zg") or str(pathlib.Path.home() / ".agents" / "bin" / "zg")
        if not pathlib.Path(zg).exists():
            return ToolResult(
                tool_use_id="",
                content=(
                    "Error: `zg` is not installed or not on PATH. Discovery index "
                    "unavailable — fall back to Grep and Glob for this run."
                ),
                is_error=True,
            )

        try:
            proc = subprocess.run(
                [zg, "query", question],
                cwd=context.cwd,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            return ToolResult(
                tool_use_id="",
                content=(
                    f"Error: zg query timed out after {TIMEOUT_SECONDS}s. "
                    "Use Grep for this one."
                ),
                is_error=True,
            )
        except OSError as exc:
            return ToolResult(
                tool_use_id="", content=f"Error running zg: {exc}", is_error=True
            )

        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()

        if proc.returncode != 0:
            # NOT-INDEXED is the one failure worth naming precisely: it is
            # expected on a worktree cut without an index, it is recoverable, and
            # a worker that reads it as "no such code" makes a false claim about
            # the repository.
            if "WORKSPACE_INDEX_NOT_FOUND" in err or "No zvec-grep index" in err:
                return ToolResult(
                    tool_use_id="",
                    content=(
                        "No discovery index exists for this workspace, so semantic "
                        "search is unavailable for this run. This is NOT a statement "
                        "about whether the code exists. Use Grep and Glob instead. "
                        "Do not run `zg index` — building one is the dispatcher's job."
                    ),
                    is_error=True,
                )
            return ToolResult(
                tool_use_id="",
                content=f"zg query failed (exit {proc.returncode}): {err or 'no detail'}",
                is_error=True,
            )

        if not out:
            return ToolResult(
                tool_use_id="",
                content=(
                    "No hits for that question. The index IS present and the query "
                    "ran — try different wording, or narrow with Grep."
                ),
            )

        if len(out) > MAX_OUTPUT_CHARS:
            dropped = len(out) - MAX_OUTPUT_CHARS
            out = (
                out[:MAX_OUTPUT_CHARS]
                + f"\n\n... [zg result truncated: {dropped} of "
                f"{dropped + MAX_OUTPUT_CHARS} characters not shown — "
                "hits are ranked, so the best ones are above]"
            )
        return ToolResult(tool_use_id="", content=out)

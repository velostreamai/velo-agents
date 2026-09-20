"""Local filesystem tools for the openai-agents backend.

`openai-agents` ships ApplyPatch, CodeInterpreter, Computer and WebSearch, but
NO local Read/Grep/Glob/Bash/Edit/Write — those are hosted tools, not a working
set for a code worker. So a switch to that runtime has to bring its own.

Sizing this honestly from the tool logs rather than from the SDK's file count:
across three measured runs our workers used Bash 13-33 times, Grep 4-7, Read 0-3,
and everything else effectively never. The 24 tools in the incumbent SDK are not
what a run consumes; these seven are.

Every tool here follows the two rules the incumbent SDK had to be fixed to obey
(velo-agent-sdk#6, #7, #11), because they were learned the expensive way:

  - A DEGRADATION IS NEVER SILENT. Truncation says what it dropped; a failed
    search is an error, not an empty result. A silently-degraded Grep wasted 68%
    of its calls once, and the agent read "no matches" as a fact about the code.
  - EXTENDED REGEX, ALWAYS. POSIX grep without -E treats `|` as a literal, so
    `a|b` searches for the three-character string. Models write extended regex
    constantly; it is the dialect these descriptions advertise.
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess

from agents import function_tool

MAX_RESULT_CHARS = 20_000
DEFAULT_BASH_TIMEOUT_S = 2_400

_CWD = pathlib.Path(".")


def set_cwd(path: str) -> None:
    global _CWD
    _CWD = pathlib.Path(path)


def _cap(text: str, what: str) -> str:
    """Bound a result, and SAY when it was bounded (velo-agent-sdk#7)."""
    if len(text) <= MAX_RESULT_CHARS:
        return text
    dropped = len(text) - MAX_RESULT_CHARS
    return (
        text[:MAX_RESULT_CHARS]
        + f"\n\n... [{what} truncated: {dropped} of {len(text)} characters not shown]"
    )


def _run(cmd: list[str], timeout: int = 120) -> tuple[int, str, str]:
    env = {**os.environ, "PATH": f"{pathlib.Path.home()}/.agents/bin:{os.environ.get('PATH','')}"}
    try:
        p = subprocess.run(cmd, cwd=str(_CWD), capture_output=True, text=True,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except OSError as exc:
        return 126, "", str(exc)


@function_tool
def grep(pattern: str, path: str = ".", output_mode: str = "content",
         case_insensitive: bool = False, glob: str = "") -> str:
    """Search file CONTENTS by regex (extended/ripgrep syntax: `a|b`, `.?`, `(x|y)`).

    output_mode: "content" (file:line:text) or "files_with_matches" (paths only).
    Use this to find code when you already know a distinctive term."""
    rg = shutil.which("rg")
    if rg:
        cmd = [rg]
        cmd.append("--files-with-matches" if output_mode == "files_with_matches" else "-n")
        if case_insensitive:
            cmd.append("-i")
        if glob:
            cmd.extend(["--glob", glob])
        cmd.extend(["--", pattern, path])
    else:
        # -E is load-bearing: without it `|` is a literal and every alternation
        # the model writes silently matches nothing.
        cmd = ["grep", "-rE"]
        if case_insensitive:
            cmd.append("-i")
        cmd.append("-l" if output_mode == "files_with_matches" else "-n")
        if glob:
            cmd.append(f"--include={glob}")
        cmd.extend(["--", pattern, path])

    rc, out, err = _run(cmd)
    # 0 = matched, 1 = no match, >=2 = the search FAILED. Reporting a failure as
    # "no matches" lets an agent conclude code does not exist because the tool broke.
    if rc >= 2:
        return f"Search failed (exit {rc}): {err.strip() or 'no detail'}"
    if not out.strip():
        return "No matches found."
    return _cap(out.strip(), "grep")


@function_tool
def glob_files(pattern: str) -> str:
    """List files matching a glob, e.g. 'src/**/*.rs'. `**` recurses."""
    try:
        hits = sorted(
            str(p.relative_to(_CWD)) for p in _CWD.glob(pattern)
            if p.is_file() and "/target/" not in str(p)
        )
    except (ValueError, NotImplementedError) as exc:
        return f"Error: bad pattern {pattern!r}: {exc}"
    if not hits:
        return "(no matches)"
    shown = hits[:200]
    tail = "" if len(shown) == len(hits) else f"\n... [{len(hits)-len(shown)} more of {len(hits)} not shown]"
    return "\n".join(shown) + tail


@function_tool
def read_file(file_path: str, offset: int = 0, limit: int = 2000) -> str:
    """Read a file with line numbers, from `offset` for `limit` lines."""
    p = pathlib.Path(file_path)
    if not p.is_absolute():
        p = _CWD / p
    if not p.exists():
        return f"Error: file not found: {file_path}"
    try:
        lines = p.read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError as exc:
        return f"Error reading file: {exc}"
    if not lines or lines == [""]:
        return "(empty file)"
    sel = lines[offset:offset + limit]
    out = "\n".join(f"{i}\t{l}" for i, l in enumerate(sel, start=offset + 1))
    if offset + limit < len(lines):
        out += f"\n\n... ({len(lines) - offset - limit} more lines not shown)"
    return _cap(out, "read")


@function_tool
def bash(command: str, timeout_s: int = DEFAULT_BASH_TIMEOUT_S) -> str:
    """Run a shell command in the worktree root. Returns stdout, then stderr."""
    # Default is the operator's configured budget, not a hardcoded 10 minutes:
    # real tasks run 40+ minutes and a cold cargo sweep exceeds 600s
    # (velo-agent-sdk#11, where this exact cap was silently overriding config).
    rc, out, err = _run(["bash", "-lc", command], timeout=timeout_s)
    body = out + (("\n" + err) if err else "")
    if rc != 0:
        body += f"\n(exit code: {rc})"
    return _cap(body.strip() or "(no output)", "bash")


@function_tool
def edit_file(file_path: str, old_string: str, new_string: str, replace_all: bool = False) -> str:
    """Exact string replacement. Fails if `old_string` is absent or not unique."""
    p = pathlib.Path(file_path)
    if not p.is_absolute():
        p = _CWD / p
    if not p.exists():
        return f"Error: file not found: {file_path}"
    if old_string == new_string:
        return "Error: old_string and new_string must differ"
    text = p.read_text(encoding="utf-8", errors="replace")
    n = text.count(old_string)
    if n == 0:
        return f"Error: old_string not found in {file_path}"
    if n > 1 and not replace_all:
        return (f"Error: old_string found {n} times in {file_path}. "
                "Use replace_all=true or add context to make it unique.")
    p.write_text(text.replace(old_string, new_string, -1 if replace_all else 1), encoding="utf-8")
    return f"Successfully edited {file_path} ({n} replacement{'s' if n > 1 else ''})"


@function_tool
def write_file(file_path: str, content: str) -> str:
    """Write a file, creating parent directories. Overwrites."""
    p = pathlib.Path(file_path)
    if not p.is_absolute():
        p = _CWD / p
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"Wrote {file_path} ({len(content)} chars)"


@function_tool
def zg_query(question: str) -> str:
    """Semantic code search over a pre-built index. Ask in PLAIN ENGLISH what you
    are looking for. Returns ranked hits with file, line range and the ENCLOSING
    SYMBOL NAME AND SCOPE. Use this FIRST when you do not yet know the symbol
    name; Grep needs a term you can only guess at before you have one."""
    zg = shutil.which("zg") or str(pathlib.Path.home() / ".agents" / "bin" / "zg")
    if not pathlib.Path(zg).exists():
        return ("Error: `zg` is not installed or not on PATH. Discovery index "
                "unavailable — fall back to grep and glob_files for this run.")
    rc, out, err = _run([zg, "query", question], timeout=90)
    if rc != 0:
        if "WORKSPACE_INDEX_NOT_FOUND" in err or "No zvec-grep index" in err:
            return ("No discovery index exists for this workspace, so semantic search "
                    "is unavailable for this run. This is NOT a statement about whether "
                    "the code exists. Use grep and glob_files instead. Do not run "
                    "`zg index` — building one is the dispatcher's job.")
        return f"zg query failed (exit {rc}): {err.strip() or 'no detail'}"
    if not out.strip():
        return ("No hits for that question. The index IS present and the query ran — "
                "try different wording, or narrow with grep.")
    return _cap(out.strip(), "zg")


@function_tool
def ast_grep(pattern: str, path: str = "src/", rewrite: str = "",
             lang: str = "rust", apply: bool = False) -> str:
    """STRUCTURAL search/replace over Rust syntax. REQUIRED by the policy for any
    rename, signature change, match-arm change or trait change touching 2+ files.

    `grep` matches text; this matches SYNTAX, so it cannot hit a comment, a
    string, or a partial identifier, and it survives a signature split across
    lines. Meta-variables: $X is one node, $$$ARGS a list.

    Call it first WITHOUT rewrite to see the match count — a pattern matching 0
    is wrong, and applying it would silently change nothing. Then pass rewrite,
    and apply=True only once the dry run looks right.

    Examples:
      pattern='fn $NAME($$$ARGS) -> $RET'
      pattern='$X.record_count', rewrite='$X.record_count()'
    """
    # Registered as a TOOL rather than left to bash (#2075). Measured across both
    # dispatch paths on the same policy: codex ran ast-grep 894 times in 15 runs,
    # the SDK worker 0 times in 14 — because every convenience action here had a
    # first-class tool and the one the policy MANDATES did not. Asking the worker
    # in prose to reach past its tools into bash is weaker than giving it the
    # tool.
    if not shutil.which("ast-grep"):
        return ("Error: ast-grep is not on PATH. It is REQUIRED for structural "
                "changes across 2+ files — do not substitute grep + edit_file, "
                "which is a brief violation. Report this and STOP.")
    cmd = ["ast-grep", "run", "--pattern", pattern, "--lang", lang]
    if rewrite:
        cmd.extend(["--rewrite", rewrite])
        if apply:
            cmd.append("-U")
    cmd.append(path)
    rc, out, err = _run(cmd)
    # rc=1 is NO MATCHES, not failure — ast-grep follows grep's convention. An
    # earlier version reported it as "ast-grep failed", so the zero-match
    # guidance below never fired and the worker saw a broken tool instead of a
    # wrong pattern. rc>=2 is a real error (bad --lang, unreadable path).
    if rc >= 2 or (rc != 0 and err.strip()):
        return f"ast-grep failed (rc={rc}): {err.strip() or out.strip()}"
    if rc == 1 or not out.strip():
        # A zero-match pattern is the single most common ast-grep mistake and is
        # silent: with -U it rewrites nothing and reports success. Say so.
        return ("0 matches — the PATTERN is wrong, not the codebase. Vary the "
                "meta-variable count ($X vs $$$X) or the syntax anchor, and "
                "re-run WITHOUT rewrite until the count is non-zero.")
    if rewrite and not apply:
        return _cap(out, "ast-grep dry run") + "\n\n(DRY RUN — pass apply=True to write)"
    return _cap(out, "ast-grep")


ALL_TOOLS = [zg_query, ast_grep, grep, glob_files, read_file, bash, edit_file, write_file]
READ_ONLY_TOOLS = [zg_query, ast_grep, grep, glob_files, read_file, bash]

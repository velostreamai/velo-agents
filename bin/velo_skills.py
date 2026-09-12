"""Skill inlining, shared by both worker runtimes.

Extracted from velo_worker_runner so the openai-agents runner can reuse it
WITHOUT importing that module — which pulls in `open_agent_sdk` and fails on a
venv that does not have the rollback SDK installed. Importing it for one function
had quietly coupled the supported runtime to the one being retired.

A second copy was the alternative and is worse: a silently-missing skill produces
a review that looks like it ran a gate and did not, so the two runtimes must not
be able to disagree about what a skill is.
"""
from __future__ import annotations

import pathlib
import re
import sys


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


REVIEW_SKILLS = ("check-code", "check-spec", "code-review", "pr-gate")

SKILL_SEARCH = (
    "{home}/.agents/skills/{name}/SKILL.md",
    "{home}/.claude/skills/{name}/SKILL.md",
    "{home}/.claude/commands/{name}.md",
)

_FRONTMATTER_RE = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)

READ_ONLY_DECLARATION = """=== THIS IS A READ-ONLY REVIEW TASK ===
The skill applied below is a REVIEW skill. Do not modify, create or delete any
file in the worktree. Your report is your FINAL MESSAGE — not a file.

Two things went wrong that this exists to prevent:

  * The runner decides "implementation vs review" by scanning the task text for
    phrases like "read-only". A review brief that simply never used those words
    was classified as an implementation, and then FAILED for not changing any
    file — twice, on the same gate, producing no report at all.

  * The inverse: because a run only counted as successful if the worktree
    changed, the one review gate that DID "succeed" did so by writing its
    report into the PR worktree as a stray untracked file. A read-only gate was
    effectively required to dirty the tree it was reviewing.

Writing nothing is the CORRECT outcome for this task, and the runner now knows
that.
=== END READ-ONLY DECLARATION ===

"""


def resolve_skill(name: str) -> tuple[str, str]:
    """Return (path, body) for a skill, or fail loudly.

    Failing loudly matters: a silently-missing skill produces a review that
    looks like it ran a gate and did not.
    """
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        fail(f"invalid skill name '{name}' (expected lowercase-kebab)")
    home = str(pathlib.Path.home())
    tried = []
    for tpl in SKILL_SEARCH:
        p = pathlib.Path(tpl.format(home=home, name=name))
        tried.append(str(p))
        if p.is_file():
            body = _FRONTMATTER_RE.sub("", p.read_text(errors="replace")).strip()
            if not body:
                fail(f"skill '{name}' resolved to an empty file: {p}")
            return str(p), body
    fail("skill '" + name + "' not found. Tried:\n  " + "\n  ".join(tried))
    raise AssertionError("unreachable")


READ_ONLY_DECLARATION = """=== THIS IS A READ-ONLY REVIEW TASK ===
The skill applied below is a REVIEW skill. Do not modify, create or delete any
file in the worktree. Your report is your FINAL MESSAGE — not a file.

Two things went wrong that this exists to prevent:

  * The runner decides "implementation vs review" by scanning the task text for
    phrases like "read-only". A review brief that simply never used those words
    was classified as an implementation, and then FAILED for not changing any
    file — twice, on the same gate, producing no report at all.

  * The inverse: because a run only counted as successful if the worktree
    changed, the one review gate that DID "succeed" did so by writing its
    report into the PR worktree as a stray untracked file. A read-only gate was
    effectively required to dirty the tree it was reviewing.

Writing nothing is the CORRECT outcome for this task, and the runner now knows
that.
=== END READ-ONLY DECLARATION ===

"""


def apply_skills(task: str, names: list[str]) -> str:
    if not names:
        return task
    blocks = []
    for name in names:
        path, body = resolve_skill(name)
        print(f"  skill: /{name} <- {path} ({len(body)} chars)", file=sys.stderr)
        blocks.append(
            f"=== SKILL: /{name} ===\n"
            f"You do NOT have a Skill tool. The full definition of /{name} is\n"
            f"inlined below; follow it as written for the scope given after it.\n\n"
            f"{body}\n"
            f"=== END SKILL: /{name} ===\n"
        )
    prefix = READ_ONLY_DECLARATION if any(n in REVIEW_SKILLS for n in names) else ""
    return prefix + "\n".join(blocks) + "\n\n=== SCOPE ===\n" + task

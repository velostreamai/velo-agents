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

    Accepts EITHER a skill name (`check-code`, searched under SKILL_SEARCH) or a
    direct path to a skill file (`$HOME/.claude/commands/check-code.md`).

    The path form exists for #2301. velo-dispatch inlines /check-code into every
    SDK worker run, and the name form is the wrong instrument there for two
    reasons:

      * SKILL_SEARCH is ordered, so the name `check-code` resolves to
        ~/.agents/skills/check-code/SKILL.md whenever that exists and silently
        NOT to the ~/.claude/commands/check-code.md the gate names. A dispatch
        that says "inline this file" must inline THAT file.
      * A name is also the review-gate idiom (velo-pr-gate passes skill NAMES to
        dispatch a reviewer). Keeping the two forms distinguishable is what lets
        apply_skills decide the read-only declaration by form — see below.

    A path is a .md file, and the commands-style ones carry no YAML frontmatter,
    unlike SKILL.md. _FRONTMATTER_RE is anchored with \\A and needs the closing
    `---`, so stripping is a no-op on frontmatter-less input — the body is the
    file, stripped. Nothing here requires frontmatter; verified by
    tests/test_skill_inlining.py rather than assumed.

    Failing loudly matters: a silently-missing skill produces a review that
    looks like it ran a gate and did not.
    """
    if looks_like_path(name):
        return _read_skill_file(pathlib.Path(name).expanduser(), name)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        fail(f"invalid skill name '{name}' (expected lowercase-kebab, or a path to a .md file)")
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


def looks_like_path(value: str) -> bool:
    """True when `value` names a file rather than a skill to search for.

    `/` is unambiguous — a kebab name never contains one. The `.md` suffix covers
    a path given relative or bare (`check-code.md`), which the name regex would
    otherwise reject with a message about lowercase-kebab names.
    """
    return "/" in value or value.endswith(".md")


def _read_skill_file(p: pathlib.Path, label: str) -> tuple[str, str]:
    if not p.is_file():
        fail(f"skill '{label}' is not a file: {p}")
    body = _FRONTMATTER_RE.sub("", p.read_text(errors="replace")).strip()
    if not body:
        fail(f"skill '{label}' resolved to an empty file: {p}")
    return str(p), body



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
        # Two ways to ask for a skill, and they mean different jobs.
        #
        #   BY NAME   — the review-gate idiom. velo-pr-gate passes `check-code`
        #               to dispatch a REVIEWER, whose whole job is that skill.
        #   BY PATH   — #2301. velo-dispatch inlines the /check-code gate into a
        #               WORKER that is already implementing something.
        #
        # The distinction is load-bearing, not cosmetic. Both runners choose the
        # tool set from task_is_read_only(), which keys off exactly the
        # declaration below, so handing a WORKER the review framing would strip
        # its write tools mid-implementation.
        as_path = looks_like_path(name)
        # Keep the slash-label readable: `/x/check-code.md` is the file, but the
        # command it defines is `/check-code`.
        label = pathlib.PurePath(name).stem if as_path else name
        print(f"  skill: /{label} <- {path} ({len(body)} chars)", file=sys.stderr)
        framing = (
            "Your TASK is the SCOPE at the end of this prompt. This skill is a\n"
            f"gate to run over your OWN diff before you push — it is not a\n"
            "redefinition of the task and not a request to stop implementing\n"
            "and review instead. Finish the task, run /"
            f"{label} on what you changed, then report.\n"
            if as_path
            else "You do NOT have a Skill tool. The full definition of /"
            f"{label} is\ninlined below; follow it as written for the scope given after it.\n"
        )
        blocks.append(
            f"=== SKILL: /{label} ===\n"
            f"{framing}"
            f"\n{body}\n"
            f"=== END SKILL: /{label} ===\n"
        )
    # A review skill asked for BY NAME is the gate; asked for by PATH it is a
    # pre-push step inside an implementation run, which must keep its write
    # tools. A bare kebab name can never contain "/", so the two sets are
    # disjoint by construction — the second half is here to say so, not to filter.
    review = any(n in REVIEW_SKILLS and not looks_like_path(n) for n in names)
    prefix = READ_ONLY_DECLARATION if review else ""
    return prefix + "\n".join(blocks) + "\n\n=== SCOPE ===\n" + task


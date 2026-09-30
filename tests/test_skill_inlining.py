#!/usr/bin/env python3
"""Skill inlining for a path-named skill file (#2301).

`velo-dispatch` now inlines /check-code into every SDK-runner worker run via
`--skill "$HOME/.claude/commands/check-code.md"`. Two failure modes this pins,
both of which shipped silently in the sense that nothing here would have
noticed:

  * The runner accepted ONLY a lowercase-kebab skill NAME. Handing it the path
    the issue specifies died with "invalid skill name" — at dispatch, after the
    worktree was cut and the issue assigned.

  * The name form is the REVIEW-gate idiom: a name in REVIEW_SKILLS makes
    apply_skills prepend the read-only declaration, and both runners pick their
    tool set off that marker. Inlining `check-code` by NAME into a WORKER would
    have stripped its write tools mid-implementation — the one change that
    turns an implementation run into a review that fails for writing nothing.

The commands-style `~/.claude/commands/*.md` file also has NO YAML frontmatter,
unlike the `SKILL.md` files the search paths were built for, so the no-frontmatter
path is pinned here rather than assumed.

Run:  .agents/tests/run.sh
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

BIN = pathlib.Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

import velo_skills  # noqa: E402

failures: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'}  {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(label)


def dies(label: str, fn) -> bool:
    """True when fn() exits via velo_skills.fail() — i.e. fails LOUD."""
    try:
        fn()
    except SystemExit:
        return True
    except Exception as e:  # noqa: BLE001 — a crash is not the loud failure
        check(label, False, f"raised {type(e).__name__}: {e} instead of failing loudly")
        return False
    check(label, False, "returned normally; the missing file was accepted silently")
    return False


# A commands-style skill file: one line, no frontmatter. Exactly the shape of
# ~/.claude/commands/check-code.md, which is the file #2301 inlines.
NO_FRONTMATTER = "check the test coverage exhaustive, error handling, edgecases\n"
WITH_FRONTMATTER = "---\nname: demo\ndescription: d\n---\n\n# Demo\n\nbody text\n"


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        plain = root / "check-code.md"
        plain.write_text(NO_FRONTMATTER)
        fm = root / "demo.md"
        fm.write_text(WITH_FRONTMATTER)
        empty = root / "empty.md"
        empty.write_text("   \n\n")
        missing = root / "nope.md"

        print("a path-named skill resolves to THAT file")
        path, body = velo_skills.resolve_skill(str(plain))
        check("path form resolves", path == str(plain), path)
        check("body is the file content", body == NO_FRONTMATTER.strip(), repr(body))
        check("no frontmatter is required", "coverage" in body)

        print("frontmatter is stripped when present, left alone when absent")
        _, body = velo_skills.resolve_skill(str(fm))
        check("frontmatter stripped", body == "# Demo\n\nbody text", repr(body))
        _, body = velo_skills.resolve_skill(str(plain))
        check("frontmatter-less body untouched", body == NO_FRONTMATTER.strip(), repr(body))

        print("a missing or empty skill file fails loud, never silently")
        # A silently-missing skill produces a run that reports a gate it did not run.
        check("missing path fails loud", dies("missing", lambda: velo_skills.resolve_skill(str(missing))))
        check("empty file fails loud", dies("empty", lambda: velo_skills.resolve_skill(str(empty))))
        check("a directory is not a skill",
              dies("dir", lambda: velo_skills.resolve_skill(str(root))))
        check("a junk name still fails loud",
              dies("junk", lambda: velo_skills.resolve_skill("Check Code")))

        print("BY PATH does not declare the run read-only (#2301's hazard)")
        # The worker inlining /check-code is IMPLEMENTING something. The read-only
        # declaration is what both runners key their tool set off, so a run
        # carrying it loses edit_file — the worker fails for writing nothing.
        out = velo_skills.apply_skills("implement the thing", [str(plain)])
        check("path form: no read-only declaration",
              "THIS IS A READ-ONLY REVIEW TASK" not in out)
        check("path form: skill body is inlined", "test coverage exhaustive" in out)
        check("path form: labelled with the skill", "=== SKILL: /check-code ===" in out)
        check("path form: scope still the task", out.endswith("implement the thing"))
        check("path form: says finish the task, not stop and review",
              "Finish the task" in out and "not a request to stop implementing" in out)

        print("BY NAME keeps the review-gate contract the gates rely on")
        # velo-pr-gate dispatches reviewers with skill NAMES. Inlining a REVIEW
        # skill by name IS the read-only gate: #2109's fix, and both runners read
        # the marker to decide the tool set. If this regressed, a review gate
        # would be handed write tools again and write its report into the tree.
        for name in velo_skills.REVIEW_SKILLS:
            try:
                out_n = velo_skills.apply_skills("scope text", [name])
            except SystemExit:
                # Not every skill is installed on every machine; the contract
                # under test is the name FORM, so skip a genuinely absent skill.
                print(f"  SKIP  /{name} is not installed here")
                continue
            check(f"name form /{name}: declares read-only",
                  out_n.startswith("=== THIS IS A READ-ONLY REVIEW TASK ==="))
            check(f"name form /{name}: keeps the reviewer framing",
                  "You do NOT have a Skill tool" in out_n)

        print("the dispatch path form and the gate name form are disjoint")
        # `check-code` is in REVIEW_SKILLS, so a form test that lets a PATH slip
        # into the name branch is the whole bug. looks_like_path is the seam.
        check("a path is detected", velo_skills.looks_like_path(str(plain)))
        check("a bare .md is detected", velo_skills.looks_like_path("check-code.md"))
        for name in velo_skills.REVIEW_SKILLS + ("velo-implementation", "pr-gate"):
            check(f"a kebab name is not a path: {name}",
                  not velo_skills.looks_like_path(name))

    print()
    if failures:
        print(f"FAILED: {len(failures)} — {', '.join(failures)}")
        return 1
    print("skill inlining: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

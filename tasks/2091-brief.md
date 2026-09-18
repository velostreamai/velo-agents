# #2091 — install.sh --check reports permanent drift

BRANCH: fix/2091-auto
WORKTREE: /Users/neilavery/RustroverProjects/velostream-2091

## Objective

`./.agents/install.sh --check` fails on any machine that has ever run a `.agents`
python script, because the installer copies `bin/__pycache__/*.pyc` into the live
tree and then compares them. The `.pyc` files are untracked and gitignored, so
there is no real drift — but a check that always fails trains everyone to ignore
the one signal that would catch a genuinely stale live copy.

Reproduce:

    ./.agents/install.sh --check
    # warn: differs ... bin/__pycache__/velo_runner_lib.cpython-314.pyc
    # ERROR: drift detected

## Scope

ONLY `.agents/install.sh` and a new test. Do not change any other script.

## Acceptance criteria

1. `__pycache__` directories and `*.pyc` files are excluded from BOTH the copy
   and the `--check` comparison.
2. `./.agents/install.sh --check` exits 0 on a machine whose live copy matches
   the checkout, even after python has run against `.agents/bin`.
3. A REAL difference is still detected: edit an installed script and `--check`
   must fail naming that file.
4. No `.pyc` files are present in the installed tree after a fresh install.
5. New test `.agents/tests/test_install_check.sh`, registered in
   `.agents/tests/run.sh`, pinning 2, 3 and 4. `install.sh` currently has NO
   coverage. Follow the conventions in `test_runner_path.sh` — drive the real
   script in a temp dir, and state in each check name WHAT FAILURE it prevents.
6. `bash .agents/tests/run.sh` is green.

## Constraints

- Read `.agents/README.md` and `.agents/tests/test_runner_path.sh` before starting.
- Do NOT install to the real `~/.agents` from the test — use a temp destination.
- This is a tooling change; no Rust, so `run-commit.sh` does not apply.

## Authorisation

Commit and push to a branch. Open a PR titled `[#2091] ...`. Do NOT merge.

## Working rules

Do not cd into the worktree, except for `gh` commands (gh has no `-C`). Use `git -C <worktree> ...` and absolute paths
for every file operation. `cd` triggers a hook-trust prompt and stalls an
unattended run.

## Validation

This task touches NO Rust, so `cargo nextest` / `cargo check` and
`run-commit.sh` do not apply — there is nothing for them to compile. The
equivalent gate here is the `.agents` suite.

Run these and paste the output in your report:

    bash .agents/tests/test_install_check.sh
    bash .agents/tests/run.sh

Both must be green before you push. Also demonstrate acceptance criterion 3 by
editing an installed script in your temp destination and showing `--check` fails
naming it.

## Incremental commits

Commit after each working step — at minimum once when the `install.sh` change is
working, and again when the test passes. Do not save all work for a single commit
at the end: if this run times out or is killed, an uncommitted worktree loses
everything, and salvage can only preserve what was committed.

## STOP conditions

Stop and report rather than continuing if any of these hold:

- `install.sh --check` still reports drift after excluding `__pycache__` — the
  cause is something else and the brief's premise is wrong.
- The fix would require changing any file other than `.agents/install.sh` and the
  new test.
- A test you write passes against the UNFIXED `install.sh`; that means it does
  not test the defect.
- You cannot make the test detect a real edit (criterion 3) without weakening it.

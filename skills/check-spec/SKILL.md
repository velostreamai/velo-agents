---
name: check-spec
description: Verify that a pull request closes the contract in its linked spec issue. Use when the user asks to check a PR against a spec, acceptance criteria, issue contract, gap inventory, deletion requirements, or Tier1 benchmark documentation.
---

# Check Spec

Verify that a PR satisfies the contract in its linked spec issue.

## Inputs

The user may provide a PR number. If omitted, infer the current branch's open PR using `gh pr status` or `gh pr view` when available.

Find the linked issue from the PR body with `Closes #N`, `closes #N`, `Fixes #N`, or `fixes #N`. If multiple linked issues are present, ask which issue is the contract. If no linked spec issue can be found, stop and explain that the check is only meaningful against a contract.

## Process

1. Fetch the PR diff with `gh pr diff <PR>` and cache it to the OS temp directory, for example `/tmp/pr<PR>.diff`.
2. Fetch the linked spec with `gh issue view <ISSUE> --json title,body,comments,updatedAt`.
3. Detect rewritten specs: if the issue `updatedAt` is after the PR `mergedAt`, or for an open PR after the latest commit date, audit against the spec as it existed at PR merge/open time when that can be inferred from the PR body. If the rewrite is too substantial for the PR body to act as a proxy, stop and say so.
4. Read related design docs linked from the spec, especially `docs/architecture/*.md` and `docs/claude/*.md`.
5. Extract:
   - Gap inventory.
   - Numbered acceptance bars.
   - Out-of-scope items.
   - Deletion requirements.
6. Check each item against code, tests, diff evidence, and PR body evidence:
   - Gap closed: code plus a test proving it.
   - Acceptance bar met: line evidence in diff or PR body.
   - Out-of-scope: PR did not widen into deferred work.
   - Deletions: `git grep` confirms removed symbols are gone. If there are no deletion requirements, state that the deletion-grep step was skipped.
7. Check Tier1 benchmark documentation when the spec requires it or when the diff touches `tests/performance/` or `benchmarks/`. Treat benchmark documentation as required for performance-touching PRs even when the spec is silent.

## Output

Use a Markdown table per acceptance bar:

```markdown
| # | Acceptance bar | Status | Evidence |
|---|---|---|---|
| 1 | ... | pass / warn / fail | file:line or "missing" |
```

Then include:

- Gap inventory delta: `closed`, `open`, `regressed`, or `added`.
- Out-of-scope check: anything the PR touches that the spec deferred.
- Deletion verification: `pass`, `fail`, or `skipped`.
- Verdict: `merge-ready` or `blocked-by-spec`, with blocking items numbered.

Findings must name file lines when possible and quote only short spec snippets. Avoid vague recommendations; every failing row should be actionable.

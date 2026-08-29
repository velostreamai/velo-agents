---
name: check-code
description: Review code or a pull request for test coverage, error handling, edge cases, duplication, hot-path efficiency, and code complexity. Use when the user asks to check code quality, audit implementation robustness, or run a focused engineering review.
---

# Check Code

Review the target code with a code-review stance. Prioritize concrete bugs, behavioral risks, missing tests, and maintainability issues over style.

## Scope

If the user names a PR, branch, diff, commit, or file list, review that scope. If no scope is provided, inspect the current worktree diff first, then ask only if the intended target is still ambiguous.

## Review Areas

- Test coverage: important behavior, failure modes, regressions, and integration paths.
- Error handling: propagation, retries, resource cleanup, partial failure, and user-visible diagnostics.
- Edge cases: empty inputs, boundary values, concurrency, ordering, time, configuration, and compatibility.
- Duplication: repeated logic that can drift or create inconsistent behavior.
- Hot-path efficiency: unnecessary allocations, I/O, blocking, repeated work, and algorithmic cost.
- Code complexity: difficult control flow, unclear ownership, implicit invariants, and hard-to-test seams.

## Output

Lead with findings, ordered by severity. Each finding should include a concrete file and line when available, the impact, and the smallest actionable fix.

Use this shape:

```markdown
## Findings
- HIGH: file:line - ...
- MEDIUM: file:line - ...

## Open Questions
- ...

## Summary
...
```

If no issues are found, say that clearly and mention remaining test gaps or residual risk.

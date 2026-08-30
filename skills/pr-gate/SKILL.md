---
name: pr-gate
description: Run a full PR pre-merge gate by combining code review, high-effort review, spec-contract verification, local build sanity, deletion checks, and benchmark documentation checks. Use when the user asks for a PR gate, merge gate, pre-merge audit, or final PR disposition.
---

# PR Gate

Run the full PR pre-merge gate and synthesize a single merge disposition. Do not auto-merge.

## Inputs

The user should provide a PR number. If omitted, infer it from the current branch's open PR when possible.

## Process

1. Fan out reviews in parallel when sub-agent tools are available:
   - Code-quality review using the `check-code` workflow: test coverage, error handling, edge cases, duplication, hot-path efficiency, and complexity.
   - High-effort code review: diff scan, removed-behavior scan, cross-file tracing, then verified and ranked findings.
   - Spec-contract review using the `check-spec` workflow when the PR has a linked spec issue.
2. If sub-agent tools are unavailable, state that the gate is running inline and perform the same checks sequentially. Keep the final report explicit about that limitation.
3. While reviews run, perform cheap local checks:
   - Build sanity in the PR worktree when available: `cargo build --tests --no-default-features`.
   - Symbol deletion verification with `git grep` for symbols the spec says should be deleted. Skip only when the spec has no deletion requirements, and state that clearly.
4. Check Tier1 benchmark documentation when the spec requires it or when the diff touches performance or benchmark paths.
5. Wait for every review/check result, then synthesize the disposition.

## Hard Rules

- Any high-severity code-quality finding blocks the PR until addressed or explicitly waived.
- Any confirmed high-effort review finding blocks the PR until addressed or explicitly waived.
- Any unmet spec acceptance bar blocks the PR.
- Missing Tier1 benchmark numbers block the PR when the spec requires them or the PR touches performance paths.
- A failing local `cargo build --tests --no-default-features` blocks the PR.

## Output

```markdown
## PR <N> merge-gate report

### check-code
- HIGH: <count> / MEDIUM: <count> / LOW: <count> / NIT: <count>
- Top blockers: ...

### high-effort review
- Confirmed findings: <count> / Plausible: <count>
- Top blockers: ...

### check-spec
- Acceptance bars met: <M> / <N>
- Blocking items: ...
- Gap delta: closed / open / regressed / added

### Local checks
- cargo build --tests --no-default-features: pass / fail / skipped
- Symbol-deletion verification: pass / fail / skipped

### Verdict
merge-ready | blocked
```

If the PR has no linked spec issue, skip `check-spec`, note it in the report, and do not fail the gate for that alone.

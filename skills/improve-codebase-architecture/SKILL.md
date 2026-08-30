---
name: improve-codebase-architecture
description: Find deepening opportunities in a codebase, informed by domain language in CONTEXT.md and decisions in docs/adr/. Use when the user wants to improve architecture, find refactoring opportunities, consolidate tightly coupled modules, or make code more testable and AI-navigable.
---

# Improve Codebase Architecture

Surface architectural friction and propose deepening opportunities: refactors that turn shallow modules into deep ones. The aim is testability and AI-navigability.

## Glossary

Use these terms exactly in every suggestion. Full definitions are in [references/LANGUAGE.md](references/LANGUAGE.md).

- **Module**: anything with an interface and an implementation.
- **Interface**: everything a caller must know to use the module, including invariants, error modes, ordering, configuration, and performance characteristics.
- **Implementation**: the code inside.
- **Depth**: leverage at the interface. **Deep** means high leverage; **shallow** means the interface is nearly as complex as the implementation.
- **Seam**: where an interface lives; a place behavior can be altered without editing in place.
- **Adapter**: a concrete thing satisfying an interface at a seam.
- **Leverage**: what callers get from depth.
- **Locality**: what maintainers get from depth.

Key principles:

- Apply the deletion test: if deleting a module only moves complexity into callers, the module was earning its keep. If complexity vanishes, it was shallow pass-through.
- The interface is the test surface.
- One adapter means a hypothetical seam. Two adapters means a real seam.

## Process

### 1. Explore

Read the project's domain glossary first when it exists:

- `CONTEXT.md`
- Relevant files under `docs/adr/`
- Relevant architecture docs linked from the target area

Then explore the codebase. Use sub-agents in parallel if the environment exposes them; otherwise inspect directly. Look for friction:

- Understanding one concept requires bouncing between many small modules.
- Modules are shallow: the interface is nearly as complex as the implementation.
- Pure functions were extracted for testability, but the real bugs hide in how they are called, so locality is poor.
- Tightly coupled modules leak across their seams.
- Important behavior is untested or hard to test through the current interface.

Classify dependencies for each candidate using [references/DEEPENING.md](references/DEEPENING.md).

### 2. Present Candidates as an HTML Report

Write a self-contained HTML file to the OS temp directory so nothing lands in the repo. Resolve the temp dir from `$TMPDIR`, falling back to `/tmp` on Unix-like systems or `%TEMP%` on Windows. Write to `<tmpdir>/architecture-review-<timestamp>.html`.

Use Tailwind via CDN for layout and Mermaid via CDN for diagrams where graph or sequence structure communicates the architecture. Mix Mermaid with hand-built CSS/SVG visuals. Each candidate gets a before/after visualization.

For each candidate include:

- Files: modules involved.
- Problem: why the current architecture causes friction.
- Solution: what would change.
- Benefits: explain in terms of locality, leverage, and testability.
- Before / after diagram.
- Recommendation strength: `Strong`, `Worth exploring`, or `Speculative`.

End with a Top recommendation section: which candidate to tackle first and why.

Use `CONTEXT.md` vocabulary for the domain and [references/LANGUAGE.md](references/LANGUAGE.md) vocabulary for architecture. If a candidate contradicts an ADR, surface it only when the friction is real enough to warrant reopening the decision.

See [references/HTML-REPORT.md](references/HTML-REPORT.md) for the scaffold, diagram patterns, and styling guidance.

Do not propose detailed interfaces yet. After the file is written, give the user the absolute path and ask: "Which of these would you like to explore?"

Opening the file with a GUI command may require approval in restricted environments; ask through the normal approval path when needed.

### 3. Grilling Loop

Once the user picks a candidate, walk the design tree with them: constraints, dependencies, the shape of the deepened module, what sits behind the seam, and which tests survive.

Side effects happen as decisions crystallize:

- If a deepened module needs a domain term that is not in `CONTEXT.md`, add it. Create `CONTEXT.md` lazily if it does not exist.
- If a fuzzy domain term gets sharpened, update `CONTEXT.md`.
- If the user rejects a candidate for a durable architectural reason, offer to record an ADR so future architecture reviews do not re-suggest it.
- If the user wants alternative interfaces for the deepened module, follow [references/INTERFACE-DESIGN.md](references/INTERFACE-DESIGN.md).

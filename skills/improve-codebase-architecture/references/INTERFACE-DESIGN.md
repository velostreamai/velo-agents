# Interface Design

Use this when the user wants to explore alternative interfaces for a chosen deepening candidate. Based on "Design It Twice": the first idea is unlikely to be the best.

## Process

### 1. Frame the Problem Space

Before generating alternatives, write a user-facing explanation for the chosen candidate:

- Constraints any new interface must satisfy.
- Dependencies it relies on and their categories from `DEEPENING.md`.
- A rough illustrative code sketch to ground the constraints. This is not a proposal.

Show this to the user, then proceed.

### 2. Generate Alternative Interfaces

Use sub-agents in parallel when available. Otherwise, generate alternatives directly. Produce at least three radically different interfaces:

- Minimize the interface: 1 to 3 entry points, maximum leverage per entry point.
- Maximize flexibility: support many use cases and extension.
- Optimize for the most common caller: make the default case trivial.
- If applicable, design around ports and adapters for cross-seam dependencies.

Each design should include:

1. Interface: types, methods, parameters, invariants, ordering, and error modes.
2. Usage example.
3. What the implementation hides behind the seam.
4. Dependency strategy and adapters.
5. Trade-offs: where leverage is high and where it is thin.

### 3. Present and Compare

Present designs sequentially, then compare them by depth, locality, and seam placement.

End with a recommendation. If elements from different designs combine well, propose a hybrid.

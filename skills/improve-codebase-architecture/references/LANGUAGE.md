# Language

Shared vocabulary for every suggestion this skill makes. Use these terms exactly. Do not substitute "component", "service", "API", or "boundary".

## Terms

**Module**
Anything with an interface and an implementation. Deliberately scale-agnostic: applies equally to a function, class, package, or tier-spanning slice.
Avoid: unit, component, service.

**Interface**
Everything a caller must know to use the module correctly. Includes the type signature, invariants, ordering constraints, error modes, required configuration, and performance characteristics.
Avoid: API, signature.

**Implementation**
What is inside a module: its body of code. Distinct from adapter: a thing can be a small adapter with a large implementation, or a large adapter with a small implementation.

**Depth**
Leverage at the interface: the amount of behavior a caller or test can exercise per unit of interface they have to learn. A module is deep when a large amount of behavior sits behind a small interface. A module is shallow when the interface is nearly as complex as the implementation.

**Seam**
A place where behavior can be altered without editing in that place. The location at which a module's interface lives. Choosing where to put the seam is its own design decision, distinct from what goes behind it.
Avoid: boundary.

**Adapter**
A concrete thing that satisfies an interface at a seam. Describes role, not substance.

**Leverage**
What callers get from depth. More capability per unit of interface they have to learn. One implementation pays back across many call sites and tests.

**Locality**
What maintainers get from depth. Change, bugs, knowledge, and verification concentrate at one place rather than spreading across callers.

## Principles

- Depth is a property of the interface, not the implementation.
- A deep module can have internal seams private to its implementation, plus the external seam at its interface.
- Apply the deletion test. If complexity vanishes when the module is deleted, the module was not hiding anything. If complexity reappears across callers, the module was earning its keep.
- The interface is the test surface.
- One adapter means a hypothetical seam. Two adapters means a real seam.

## Relationships

- A module has exactly one interface.
- Depth is a property of a module measured against its interface.
- A seam is where a module's interface lives.
- An adapter sits at a seam and satisfies the interface.
- Depth produces leverage for callers and locality for maintainers.

## Rejected Framings

- Depth as a ratio of implementation lines to interface lines.
- Interface as only a type-level surface.
- Boundary. Say seam or interface.

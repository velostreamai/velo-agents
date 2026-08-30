# Deepening

How to deepen a cluster of shallow modules safely, given its dependencies. Assumes the vocabulary in `LANGUAGE.md`: module, interface, seam, and adapter.

## Dependency Categories

### 1. In-Process

Pure computation, in-memory state, no I/O. Always deepenable: merge the modules and test through the new interface directly. No adapter needed.

### 2. Local-Substitutable

Dependencies that have local test stand-ins, such as PGLite for Postgres or an in-memory filesystem. Deepenable if the stand-in exists. The deepened module is tested with the stand-in running in the test suite. The seam is internal; no port at the module's external interface.

### 3. Remote But Owned: Ports and Adapters

Your own modules across a network boundary. Define a port at the seam. The deep module owns the logic; the transport is injected as an adapter. Tests use an in-memory adapter. Production uses an HTTP, gRPC, or queue adapter.

Recommendation shape: define a port at the seam, implement a production adapter and an in-memory test adapter, so the logic sits in one deep module even though it crosses a network.

### 4. True External: Mock

Third-party dependencies you do not control. The deepened module takes the external dependency as an injected port; tests provide a mock adapter.

## Seam Discipline

- One adapter means a hypothetical seam. Two adapters means a real one.
- Do not introduce a port unless at least two adapters are justified, typically production plus test.
- A deep module can have internal seams used by its own tests. Do not expose internal seams through the interface just because tests use them.

## Testing Strategy

- Replace tests at shallow modules with tests at the deepened module's interface.
- Tests assert on observable outcomes through the interface, not internal state.
- Tests should survive internal refactors.
- If a test must change when the implementation changes, it is testing past the interface.

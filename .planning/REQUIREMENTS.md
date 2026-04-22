# Requirements: Gene Actor Runtime Migration

**Defined:** 2026-04-17
**Core Value:** The actor migration track is complete. Future work should build
on the actor-first runtime rather than preserving or reintroducing a public
thread-first surface.

## v1 Requirements (Phase 0 — Complete)

### Lifetime Semantics

- [x] **LIFE-01**: `Value` ownership uses a single ref-counting source of truth
  across manual VM writes, Nim `=copy` / `=destroy` hooks, and
  function/native-trampoline boundaries.

### Publication Safety

- [x] **PUB-01**: Lazy function and block compilation no longer publish
  `body_compiled` through unsynchronized writes.
- [x] **PUB-02**: Inline cache storage is pre-sized or synchronized so runtime
  execution does not grow `inline_caches` opportunistically.
- [x] **PUB-03**: Native code publication exposes `native_entry` only after
  `native_ready` is visible with release/acquire semantics or an equivalent
  eager-initialization guarantee.

### Thread Correctness

- [x] **THR-01**: `poll_event_loop` drains the caller's thread channel rather
  than hard-coding thread 0.
- [x] **THR-02**: `Thread.on_message` installs callbacks on the target thread VM
  rather than the caller VM.

### String Immutability

- [x] **STR-01**: `String.append` and related mutators stop mutating shared
  storage in place and return new strings instead.
- [x] **STR-02**: `IkPushValue` no longer copies string literals defensively
  before pushing them on the VM stack.

### Bootstrap Publication

- [x] **BOOT-01**: Bootstrap-shared runtime artifacts have an explicit
  publication/freeze boundary that excludes runtime-created namespaces and
  classes.

## v2 Requirements (Phase 1 — Active)

### Deep-Frozen Bit and Shared Heap

- [x] **FRZ-01**: `Value` header carries a `deep_frozen` bit readable without
  heap allocation on both payload and managed reference types.
- [x] **FRZ-02**: `Value` header carries a `shared` bit readable without heap
  allocation, orthogonal to `deep_frozen` at the bit level but set in lockstep
  by the freeze path for Phase 1 MVP scope.
- [x] **FRZ-03**: Stdlib `(freeze v)` transitions `array`, `map`, `hash_map`,
  `gene`, and `bytes` values to `deep_frozen`, recursively tagging nested
  containers in MVP scope.
- [x] **FRZ-04**: `(freeze v)` applied to a value whose MVP scope cannot be
  satisfied (non-freezable kinds, or nested non-freezable payload) fails with
  a typed error rather than partial tagging or a silent no-op.

### Shared-Heap Allocation

- [x] **HEAP-01**: Frozen values are reachable from any thread through the same
  heap without per-actor cloning, with documented invariants for pointer
  sharing distinct from owned-heap values.

### Refcount Branch

- [x] **RC-02**: Retain and release branch on the `shared` bit: shared values
  continue to use atomic increments and decrements; owned (non-shared) values
  may use plain increments and decrements where the lifetime is provably
  thread-local, restoring the owned-side refcount performance Phase 0 traded
  for uniformity.

### Naming

- [x] **NAME-01**: The two-level naming ("sealed" for shallow `#[]` / `#{}` /
  `#()` literals, "frozen" for deep `(freeze v)` output) is finalized with
  matching error messages, stdlib names, and documentation.

## v3 Requirements (Deferred Actor Work)

### Freezable Closures (Phase 1.5 — Hard Prerequisite for Phase 2)

- **CLO-01**: Closures with freezable captured environments can be frozen and
  sent by pointer across actor boundaries.

### Actor Runtime

- [x] **ACT-02**: Add actor scheduler, tiered send, reply futures, and actor stop
  semantics.
- **ACT-03**: Migrate process-global native resources behind port actors.
- **ACT-04**: Deprecate the legacy thread API after the actor API is verified.

**Phase 3 status:** complete. The extension substrate is in place, `genex/llm`
uses the explicit exported-function bridge, `genex/http` uses actor-backed
request ports for concurrent request work, and Socket Mode binding ownership in
`genex/ai/bindings` is actor-scoped instead of process-global.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Distributed actors / multi-process runtime | Proposal explicitly scopes work to single-process concurrency |
| Erlang-style supervision / hot code reload | Not required for the current runtime migration |
| Compile-time capability typing | Runtime-only enforcement is the approved design |
| `StringBuilder` optimization work | Deferred until immutable string semantics land and need profiling |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| LIFE-01 | Phase 0 | Complete (commit e2e776c) |
| PUB-01 | Phase 0 | Complete |
| PUB-02 | Phase 0 | Complete |
| PUB-03 | Phase 0 | Complete |
| THR-01 | Phase 0 | Complete |
| THR-02 | Phase 0 | Complete |
| STR-01 | Phase 0 | Complete |
| STR-02 | Phase 0 | Complete |
| BOOT-01 | Phase 0 | Complete (commit e2e776c) |
| FRZ-01 | Phase 1 | Complete |
| FRZ-02 | Phase 1 | Complete |
| FRZ-03 | Phase 1 | Complete |
| FRZ-04 | Phase 1 | Complete |
| HEAP-01 | Phase 1 | Complete |
| RC-02 | Phase 1 | Complete |
| NAME-01 | Phase 1 | Complete |
| CLO-01 | Phase 1.5 | Complete |
| ACT-02 | Phase 2 | Complete |
| ACT-03 | Phase 3 | Complete |
| ACT-04 | Phase 4 | Complete |

**Coverage:**
- v1 requirements (Phase 0): 9 complete
- v2 requirements (Phase 1): 7 complete
- v3 requirements (Phase 1.5+): 4 complete
- Unmapped: 0

---
*Requirements defined: 2026-04-17*
*Last updated: 2026-04-22 after Phase 4 completion*

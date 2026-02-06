## Context
The current type system has structured compile-time inference (`TypeExpr`) but serializes and transports runtime-checked metadata mostly as strings (`type_expectations`, matcher `type_name`, return type names). We want one canonical descriptor representation from compile to GIR to runtime.

## Goals / Non-Goals
- Goals:
  - Canonical type identity via descriptor objects + stable IDs.
  - GIR persistence for descriptor tables.
  - Runtime materialization path to real type objects.
  - Backward-compatible migration (retain existing string paths during rollout).
- Non-Goals:
  - Immediate removal of all string type fields in one change.
  - Full generic monomorphization.
  - Forcing strict static semantics.

## Decisions
- Decision: Add `TypeDesc` + `TypeId` to core type definitions.
- Decision: Extend `CompilationUnit` and GIR with descriptor tables.
- Decision: Keep existing string metadata in parallel during migration.
- Decision: Runtime descriptor objects can support lazy implementation hooks, but module/class initialization semantics must remain unchanged.

## Migration Plan
1. Phase 1 (this change slice): core descriptor schema + GIR read/write + tests.
2. Phase 2: compiler emits `TypeId` references in scope/matcher metadata.
3. Phase 3: runtime `validate_type` uses descriptor/runtime objects first, string parsing as fallback.
4. Phase 4: deprecate string-only paths once compatibility is proven.

## Risks / Trade-offs
- GIR format bump invalidates cache files between versions.
- Dual-path metadata temporarily increases code complexity.
- Descriptor/runtime object interning must be deterministic across module loads.

## Open Questions
- Exact runtime object API for descriptor-backed checks (`RtTypeObj` vs existing `RtType`).
- Whether function/effect descriptors should be normalized at compile time or load time.

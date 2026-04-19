# Phase 1: Deep-frozen bit, shared heap, and `(freeze v)` — Context

**Gathered:** 2026-04-18
**Status:** Ready for planning (planner uses defaults — `/gsd-plan-phase 1 --skip-research`)

<domain>
## Phase Boundary

Phase 1 adds the runtime substrate that every later actor phase depends on:
`deep_frozen` and `shared` bits on managed `Value` objects, a shared-heap
allocation path, an atomic-vs-plain refcount branch driven by the `shared`
bit, and the user-facing `(freeze v)` stdlib operation over the MVP container
scope (arrays, maps, hash maps, genes, bytes).

Phase 1 does **not** introduce any new concurrency API. Existing thread code
remains unchanged. The actor scheduler, tiered send, and port actors are
Phase 2+. Freezable closures are Phase 1.5 (hard prerequisite for Phase 2,
tracked as a separate phase after Phase 1 closes).

</domain>

<decisions>
## Implementation Decisions (planner defaults — revisable at review round)

### Scope
- **D-01:** MVP freeze scope is exactly `array`, `map`, `hash_map`, `gene`,
  `bytes`. Strings are already immutable post-P0.4 and are pointer-shareable
  without a `(freeze)` call. Instances, classes, bound methods, and closures
  are **not freezable in Phase 1** — `(freeze v)` over them raises a typed
  error.
- **D-02:** Freezable closures are **Phase 1.5**, not Phase 1. The captured-
  environment analysis is its own workstream.

### Bit Placement (FRZ-01, FRZ-02)
- **D-03:** `deep_frozen: bool` and `shared: bool` live on each managed
  object's header (`ArrayObj`, `MapObj`, `HashMapObj` / `Reference` for
  `VkHashMap`, `Gene`, `BytesObj` / `Reference` for `VkBytes`, `String`). They
  sit alongside the existing `ref_count` and the existing shallow `frozen:
  bool` field. Reading both bits is an O(1) single-cache-line load through the
  `Value` pointer after tag dispatch.
- **D-04:** The `Value` tag space (top 16 bits of `raw`) is **not** modified.
  Tag space is already dense (`0xFFF1`–`0xFFFD`); adding new tags to encode
  freeze state would break more than it gains. The existing shallow `frozen`
  field is kept and renamed in user-facing docs to **sealed**; the new deep
  variant is `deep_frozen`.
- **D-05:** Immediate (non-managed) values (`SMALL_INT_TAG`, `SYMBOL_TAG`,
  `POINTER_TAG`, `BYTES_TAG`, `BYTES6_TAG`, `SPECIAL_TAG`) are always
  semantically "deep-frozen + shared" — they carry no heap state. Helpers
  return `true` for both bits without dereferencing.

### `(freeze v)` Semantics (FRZ-03, FRZ-04)
- **D-06:** `(freeze v)` is **recursive in-place tag**, not copy-on-freeze.
  The op uses a two-pass walk: (1) validate every reachable value is in MVP
  scope or an already-immutable primitive; (2) if validation passes, set
  `deep_frozen = true` (and `shared = true`, see D-08) on every managed
  container in the subtree. If validation fails, no tags are written — the
  op raises a typed error referencing the offending kind and path.
- **D-07:** `(freeze v)` is **idempotent**: applying to an already-deep-frozen
  value is a no-op that returns the same value.

### Shared-Heap Allocation (HEAP-01)
- **D-08:** Phase 1 uses **tag-on-existing-heap**: there is no separate
  shared-heap allocator. The `shared` bit is set atomically with the
  `deep_frozen` bit by `(freeze v)`. Frozen values are reachable from any
  thread through the same heap. The separate-pool option from
  `actor-design.md:308-330` is deferred as a perf-tuning follow-up after
  Phase 2 ships.
- **D-09:** Bootstrap-interned strings from the Phase 0 intern table are
  considered pre-shared: their `shared` bit is set when the intern table
  freezes (`freeze_bootstrap_publication` in `src/gene/types/helpers.nim`).

### Atomic-vs-Plain Refcount Branch (RC-02)
- **D-10:** `retainManaged` and `releaseManaged` in `src/gene/types/memory.nim`
  branch on the `shared` bit:
  - `shared == true`: `atomicInc` / `atomicDec` (current Phase 0 behavior).
  - `shared == false`: plain `.inc` / `.dec` (restoring pre-Phase-0 owned-side
    performance).
- **D-11:** The branch is per-variant (ARRAY, MAP, INSTANCE, GENE, REF,
  STRING). All existing atomic paths in `memory.nim:88-170` are replaced with
  a conditional. The non-shared path recovers the pre-Phase-0 owned-case
  performance; the shared path preserves Phase 0 correctness.
- **D-12:** For types that carry no `shared` bit yet (Instances in Phase 1),
  refcount stays atomic. Adding `shared` to Instance is out of scope.

### Naming (NAME-01)
- **D-13:** Final user-facing naming: "sealed" for the shallow `#[]` / `#{}`
  / `#()` literal form (existing `frozen: bool` field); "frozen" for deep
  `(freeze v)` output. Error messages, stdlib names, and documentation use
  these terms consistently. No source-compat break — the existing `frozen:
  bool` field is renamed internally to `sealed` in follow-up hygiene work, not
  as a Phase 1 gate.

### the agent's Discretion
- Exact helper/API shapes for bit accessors, RC branching macros, and the
  `(freeze)` stdlib entry point, so long as the invariants above are met.
- Whether the two-pass freeze validation is inlined or split into helpers.
- Test file layout (augment existing files vs. create focused ones), as long
  as the Phase 0 acceptance sweep still runs clean.

</decisions>

<specifics>
## Specific Ideas

- Phase 1's hot paths are `memory.nim:78-170` (managed retain/release), the
  NaN-boxed type accessors in `value_ops.nim:60-120`, and the in-place
  mutation opcodes in `src/gene/vm/exec.nim`.
- A frozen-write guard already exists in `value_ops.nim` (the `is_frozen`
  helpers referenced for ARRAY/MAP/GENE/INSTANCE); Phase 1 extends this to
  check `deep_frozen` in addition to the shallow `frozen` bit, and to surface
  a typed error from mutating opcodes.
- The two-pass validator can reuse the existing deep-equality walker
  structure in `value_ops.nim:225-349`.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Approved design
- `docs/proposals/actor-design.md:279-330` — Architectural changes A & B
  (header bit and shared heap).
- `docs/proposals/actor-design.md:687-718` — Phase 1 scope and deferrals.
- `docs/proposals/actor-design.md:700-704` — Phase 1.5 gate.
- `docs/proposals/actor-design.md:411-427` — Runtime freeze discipline.

### Existing implementation hot spots
- `src/gene/types/type_defs.nim:14-18` — `Value` NaN-box definition.
- `src/gene/types/type_defs.nim:349-358` — `Gene` and `String` headers.
- `src/gene/types/memory.nim:78-210` — `retainManaged` / `releaseManaged` and
  the `=copy` / `=destroy` / `=sink` hooks.
- `src/gene/types/core/value_ops.nim:60-200` — NaN-tagged type accessors and
  shallow frozen checks.
- `src/gene/vm/exec.nim` — in-place mutation opcodes (`IkSetMember`,
  `IkSetChild`, `IkArrayPush`, `IkMapPut`, ...) that must honor `deep_frozen`.
- `src/gene/stdlib/core.nim` and `src/gene/stdlib/arrays.nim` /
  `maps.nim` / `genes.nim` — stdlib entry points for the `(freeze v)`
  operation.

### Existing regression coverage to extend
- `tests/integration/test_scope_lifetime.nim` — managed-value lifetime.
- `tests/test_native_trampoline.nim` — native publication.
- `tests/test_bootstrap_publication.nim` — bootstrap freeze boundary
  (Phase 1 must not regress this).
- `./testsuite/run_tests.sh` — full Phase 0 acceptance sweep.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Shallow `frozen: bool` on `Gene`, `ArrayObj`, `MapObj` already exists; the
  deep-frozen path can sit alongside it.
- `retainManaged` / `releaseManaged` already branch per-variant (ARRAY, MAP,
  INSTANCE, GENE, REF, STRING), so the atomic-vs-plain branch fits per-arm.
- `isManaged` template (`memory.nim:47`) is already the canonical test for
  whether a `Value` has a heap header to load bits from.

### Established Patterns
- NaN tag space is dense and treated as fixed; changes to tag layout break
  many sites — bits live in object headers, not tags (per D-04).
- Shallow `frozen` checks are already plumbed through the write path; Phase 1
  extends, not replaces, that plumbing.

### Integration Points
- `memory.nim` (RC branch)
- `type_defs.nim` (header fields)
- `value_ops.nim` (bit readers + freeze-violation error)
- `exec.nim` (mutation opcode guards)
- `stdlib/*.nim` (`(freeze v)` entry point + MVP-scope typed errors)
- `tests/` (freeze semantics + RC-branch lifetime + no Phase 0 regression)

</code_context>

<deferred>
## Deferred Ideas

- Freezable closures (Phase 1.5) — captured-env freezability analysis.
- Instance / Class / BoundMethod freezing — publication-protocol design
  required first (`actor-design.md:706-711`).
- Separate shared-heap allocator pool — perf-tuning after Phase 2.
- Renaming the existing `frozen: bool` field to `sealed` across the codebase
  — hygiene pass, not a Phase 1 gate.

</deferred>

---

*Phase: 01-deep-frozen-bit-shared-heap-freeze*
*Context gathered: 2026-04-18*
*Mode: planner defaults (--skip-research)*

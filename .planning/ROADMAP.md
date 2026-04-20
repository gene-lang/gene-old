# Roadmap: Gene Actor Runtime Migration

## Overview

This roadmap tracks the approved actor-design migration from
`docs/proposals/actor-design.md`. Phase 0 (substrate cleanup) landed in commit
`e2e776c`. Phase 1 (deep-frozen bit, shared heap, `(freeze v)`) is now
implemented across commits `f153f95`..`a36452b`. Later phases stay deferred in
the proposal until follow-on planning resumes.

The legacy `.planning/phases/01-architecture-comparison/` directory was
preserved historical exploratory material and has been moved to
`.planning/archive/01-architecture-comparison-legacy/` so the `01-` numeric
slot can be used for the real Phase 1.

## Phases

**Phase Numbering:**
- Proposal numbering is preserved for this actor-runtime track.
- Phase 1.5 is a named half-phase per the proposal (freezable closures, hard
  prerequisite for Phase 2); it is tracked here as a placeholder and planned
  only after Phase 1 closes.

- [x] **Phase 0: Unify lifetime and publication semantics** - Repay
  correctness debt in ref-counting, publication, thread messaging, string
  semantics, and bootstrap sharing before actor primitives land *(completed
  2026-04-18, commit e2e776c)*
- [x] **Phase 1: Deep-frozen bit, shared heap, and `(freeze v)`** - Add the
  header bits, shared-heap allocation path, atomic-vs-plain refcount branch,
  and the user-facing `(freeze v)` stdlib operation over the MVP container
  scope *(completed 2026-04-19, commits `f153f95`..`a36452b`)*
- [x] **Phase 1.5: Freezable closures** - Make closures with freezable
  captured environments deep-freezable and pointer-shareable so Phase 2 actor
  scheduling can use the same send semantics for callable payloads *(completed
  2026-04-19, commits `9e9a97a`..`cfb9140`)*
- [ ] **Phase 2: Actor runtime** - Add actor scheduler, tiered send semantics,
  reply futures, stop semantics, and the user-facing actor API on top of the
  Phase 0/1 substrate
- [ ] **Phase 3: Port actors for extensions** - Migrate process-global native
  resources and extension-side concurrency behind actor/port boundaries
- [ ] **Phase 4: Remove legacy thread-first concurrency surfaces** - Deprecate
  and remove the legacy thread API once actor support is verified, including
  `GENE_WORKERS` naming cleanup and other thread-centric concurrency entry
  points that should no longer be primary

## Phase Details

### Phase 0: Unify lifetime and publication semantics *(complete)*
**Goal**: Remove the current runtime ownership and publication hazards that would compound under actor concurrency, while keeping the only approved user-visible break limited to the string mutator cut.
**Depends on**: Nothing (active foundation phase)
**Requirements**: [LIFE-01, PUB-01, PUB-02, PUB-03, THR-01, THR-02, STR-01, STR-02, BOOT-01]
**Success Criteria** (what must be TRUE):
  1. Ref-counting and `Value` assignment semantics are uniform enough that scope, async, and native-boundary tests do not depend on mixed manual and hook-based ownership rules.
  2. Lazy publication points for compiled bodies, inline caches, and native entry state are synchronized or eagerly initialized with regression coverage.
  3. Thread replies and message callback registration work on the intended worker VM, not just thread 0 or the calling VM.
  4. Strings are immutable by default, `String.append` no longer mutates shared storage, and `IkPushValue` stops copying string literals defensively.
  5. Bootstrap-shared runtime artifacts have an explicit publication boundary that later actor/shared-heap work can rely on.
**Plans**: 5 plans

Plans:
- [x] 00-01: Unify ref-counting paths around managed `Value` hooks
- [x] 00-02: Fix lazy publication for compiled bodies, inline caches, and
  native entry
- [x] 00-03: Repair thread reply polling and target-VM callback registration
- [x] 00-04: Cut over to immutable strings and delete literal push copies
- [x] 00-05: Enforce bootstrap publication discipline and run phase acceptance
  sweep

### Phase 1: Deep-frozen bit, shared heap, and `(freeze v)` *(complete)*
**Goal**: Introduce the runtime substrate the proposal requires before the actor scheduler lands — deep-frozen and shared bits on `Value`, a shared-heap allocation path for frozen values, an atomic-vs-plain refcount branch driven by the `shared` bit, and a user-facing `(freeze v)` stdlib operation over the MVP container scope (arrays, maps, hash maps, genes, bytes). No new concurrency API is added; existing thread code remains unaffected.
**Depends on**: Phase 0 (landed Phase 0 substrate: unified RC, publication safety, bootstrap freeze)
**Requirements**: [FRZ-01, FRZ-02, FRZ-03, FRZ-04, HEAP-01, RC-02, NAME-01]
**Success Criteria** (what must be TRUE):
  1. Every `Value` exposes `deep_frozen` and `shared` as O(1) reads without heap allocation; both bits round-trip correctly through managed copy/destroy/sink hooks.
  2. `(freeze v)` over MVP scope (array, map, hash_map, gene, bytes) produces a deep-frozen value whose contents are either already immutable or tagged `deep_frozen`; non-MVP kinds fail with a typed error rather than a silent no-op.
  3. Shared-heap allocation is a documented, tested path: frozen values are pointer-shareable across threads and retain/release use atomic primitives; owned values may use plain refcount primitives where lifetime is provably local.
  4. The naming in user-facing APIs, errors, and docs finalizes as "sealed" (shallow `#[]` / `#{}` / `#()` literals) vs "frozen" (deep `(freeze v)` output) with no remaining mixed usage.
  5. No Phase 0 regression: the acceptance sweep (`./testsuite/run_tests.sh` plus `test_bootstrap_publication`, `test_scope_lifetime`, `test_cli_gir`, `test_thread`, `test_stdlib_string`, `test_native_trampoline`) still passes.
**Plans**: 6 plans

Plans:
- [x] 01-01: Header bits + O(1) accessors
- [x] 01-02: `(freeze v)` operation and typed errors
- [x] 01-03: Mutation opcode guards for `deep_frozen`
- [x] 01-04: Atomic-vs-plain refcount branch on `shared`
- [x] 01-05: Shared-heap semantics verification
- [x] 01-06: "sealed" vs "frozen" naming finalization

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 0. Unify lifetime and publication semantics | 5/5 | Complete | 2026-04-18 |
| 1. Deep-frozen bit, shared heap, and `(freeze v)` | 6/6 | Complete | 2026-04-19 |
| 1.5. Freezable closures | 2/2 | Complete | 2026-04-19 |
| 2. Actor runtime | 0/5 | Planned | - |
| 3. Port actors for extensions | 0/? | Unplanned | - |
| 4. Remove legacy thread-first concurrency surfaces | 0/? | Unplanned | - |

### Phase 1.5: Freezable closures *(complete)*
**Goal**: Allow closures whose captured environments are themselves freezable to
be deep-frozen and pointer-shared, closing the last major gap before the actor
scheduler lands.
**Depends on**: Phase 1
**Requirements**: [CLO-01]
**Success Criteria** (what must be TRUE):
  1. Closures with freezable captured environments can be frozen and sent by
     pointer without cloning their environment.
  2. Non-freezable closures fail with typed errors that surface the offending
     capture path or kind.
  3. The closure-freeze rules compose with the existing Phase 1 `(freeze v)`
     contract and do not regress Phase 0/1 acceptance sweeps.
**Plans**: 2 plans

Plans:
- [x] 01.5-01-PLAN.md — Extend the two-pass freeze walker to `VkFunction`
  capture graphs and lock the typed failure contract with focused tests
- [x] 01.5-02-PLAN.md — Prove frozen closures are actor-ready after scope
  teardown, add shared-pointer stress coverage, and document the migration
  boundary to Phase 2 / later thread-surface removal

### Phase 2: Actor runtime
**Goal**: Deliver the actual actor model on top of the verified substrate:
scheduler, tiered send behavior, reply futures, actor stop semantics, and the
user-facing actor API.
**Depends on**: Phase 1.5
**Requirements**: [ACT-02]
**Success Criteria** (what must be TRUE):
  1. Actor spawn/scheduling works without reusing the legacy thread API as the
     primary concurrency surface.
  2. Send semantics distinguish primitive, frozen, and mutable payload paths as
     described in the approved proposal.
  3. Reply futures and actor stop behavior are validated under concurrent load.
**Plans**: 5 plans

Plans:
- [ ] 02-01-PLAN.md — Define actor runtime value contracts and class plumbing
- [ ] 02-02-PLAN.md — Reuse the worker substrate for actor enable/spawn and `gene/actor/*` bootstrap
- [ ] 02-03-PLAN.md — Implement tiered send behavior with bounded mailbox backpressure
- [ ] 02-04-PLAN.md — Wire actor reply futures and stop semantics onto the existing Future runtime
- [ ] 02-05-PLAN.md — Publish actor docs, preserve thread compatibility guidance, and add black-box actor verification

### Phase 3: Port actors for extensions
**Goal**: Move process-global native resources and extension-side concurrency to
actor/port boundaries so external systems stop bypassing the actor model.
**Depends on**: Phase 2
**Requirements**: [ACT-03]
**Success Criteria** (what must be TRUE):
  1. Process-global or stateful extensions expose actor/port boundaries instead
     of ad hoc shared mutable runtime state.
  2. The actor runtime can safely isolate resource ownership for external
     systems such as HTTP/LLM integrations.
**Plans**: TBD

### Phase 4: Remove legacy thread-first concurrency surfaces
**Goal**: Finish the migration by deprecating and then removing the legacy
thread-first concurrency APIs once actors are proven out.
**Depends on**: Phase 2, Phase 3
**Requirements**: [ACT-04]
**Success Criteria** (what must be TRUE):
  1. The actor API is the primary supported concurrency surface.
  2. Legacy thread APIs and related naming (`GENE_WORKERS`, thread-centric entry
     points) are deprecated or removed with migration guidance.
  3. Other concurrent features that duplicate actor behavior are either routed
     through actors or explicitly retired.
**Plans**: TBD

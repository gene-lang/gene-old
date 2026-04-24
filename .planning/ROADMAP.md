# Roadmap: Gene Core Stabilization + Package MVP

## Overview

This roadmap starts the post-actor milestone. The actor migration track is
complete through Phase 4, so v1.1 focuses on the next trust boundary surfaced
by review: users need to know what is stable, core semantics need sharper
contracts, packages need a deterministic local MVP, and the optimized VM needs
checked-mode correctness support.

Phase numbering continues from the completed actor migration roadmap. New work
starts at Phase 5.

## Previous Milestone

- Phase 0: Lifetime/publication/string/bootstrap substrate - complete.
- Phase 1: Deep-frozen bit, shared heap, and `(freeze v)` - complete.
- Phase 1.5: Freezable closures - complete.
- Phase 2: Actor runtime - complete.
- Phase 3: Port actors for extensions - complete.
- Phase 4: Remove legacy thread-first concurrency surfaces - complete.

## Phases

- [x] **Phase 5: Feature status matrix and stable-core boundary** - Publish the
  public status matrix, classify stable/beta/experimental/future/removed
  surfaces, and define the stable core before changing package or VM behavior.
- [ ] **Phase 6: Core semantics tightening** - Lock `nil` vs `void`, selector
  failure behavior, Gene expression property/child evaluation rules, macro
  input shape, and pattern-matching status with docs and tests.
- [ ] **Phase 7: Package/module MVP** - Parse `package.gene`, expose package
  metadata, support local dependency declarations, deterministic package-aware
  import resolution, and a local lockfile/verification path.
- [ ] **Phase 8: VM correctness harness** - Add checked VM invariant support,
  instruction metadata, GIR compatibility checks, and parser/serdes/GIR stress
  coverage without slowing optimized default execution.

## Phase Details

### Phase 5: Feature status matrix and stable-core boundary

**Goal**: Make the public feature surface honest and navigable: users can see
what is stable, beta, experimental, future-only, or removed, and docs stop
presenting incomplete features as stable.

**Depends on**: Completed actor migration track; GPT Pro review triage
(`260423-s1y`).

**Requirements**: [STAT-01, STAT-02, STAT-03, CORE-01]

**Success Criteria** (what must be TRUE):
  1. A public feature-status matrix exists and covers core syntax, values,
     functions, macros, modules, packages, classes/adapters, selectors, async,
     actors, pattern matching, GIR, native extensions, WASM, LSP, and tooling.
  2. Each matrix row records spec/doc status, implementation status, tests,
     known gaps, and recommended user posture.
  3. README and docs index point users to the matrix and do not promote
     experimental or removed surfaces as stable.
  4. Stable-core membership is explicitly listed and tied to test coverage.

**Plans**: [05-01-PLAN.md](phases/05-feature-status-matrix-and-stable-core-boundary/05-01-PLAN.md)

### Phase 6: Core semantics tightening

**Goal**: Turn the review's semantic-boundary comments into concrete contracts
and tests for the stable core.

**Depends on**: Phase 5.

**Requirements**: [CORE-02, CORE-03, CORE-04, CORE-05]

**Success Criteria** (what must be TRUE):
  1. `nil` and `void` behavior is specified with examples for maps, arrays,
     objects/classes, Gene properties, selector failures, failed function
     returns, and optional values.
  2. Selector docs and tests agree on missing-key, missing-index, nil receiver,
     strict selector, stream-mode, and update behavior.
  3. Gene expression evaluation rules distinguish data, calls, properties,
     children, macro input, and metadata clearly enough for DSL authors.
  4. Pattern matching has a stable subset and known-gap list backed by runnable
     tests or focused Nim tests.

**Plans**: TBD

### Phase 7: Package/module MVP

**Goal**: Deliver the smallest package workflow that makes local projects and
local dependencies deterministic without claiming registry-level ecosystem
support.

**Depends on**: Phase 5; Phase 6 where package behavior relies on stable core
semantics.

**Requirements**: [PKG-01, PKG-02, PKG-03, PKG-04, PKG-05, PKG-06]

**Success Criteria** (what must be TRUE):
  1. `package.gene` is parsed into a package model with name, version, source
     directory, main module, test directory, and dependency declarations.
  2. Current package metadata is available through `$pkg` or a documented
     replacement surface.
  3. Local/path dependency declarations are parsed with deterministic
     diagnostics for malformed manifests, invalid paths, and cycles.
  4. Package-aware imports resolve deterministically from current package,
     source directory, local dependencies, direct import paths, and lockfile
     data.
  5. `package.gene.lock` can be generated and verified for local/path
     dependencies.
  6. Package docs and tests state the MVP boundary and defer registry/version
     solver behavior explicitly.

**Plans**: TBD

### Phase 8: VM correctness harness

**Goal**: Add opt-in correctness checks around the optimized VM so runtime
changes can be validated by invariant failures instead of only end-to-end
behavioral symptoms.

**Depends on**: Phase 5. Can proceed in parallel with Phase 7 after stable
instruction metadata scope is agreed.

**Requirements**: [VMCHK-01, VMCHK-02, VMCHK-03, VMCHK-04, VMCHK-05]

**Success Criteria** (what must be TRUE):
  1. Maintainers can enable a checked VM mode for tests/debug builds without
     changing optimized default execution.
  2. Instruction metadata records stack effects, operands, reference/lifetime
     behavior, and debug formatting for supported opcodes.
  3. Checked mode validates stack, frame, scope, exception, refcount/lifetime,
     and instruction operand invariants where practical.
  4. GIR compatibility tests fail clearly for stale or incompatible cache data.
  5. Parser, serializer/deserializer, and GIR round-trip stress coverage exists
     for representative stable-core values and failure paths.

**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 5. Feature status matrix and stable-core boundary | 1/1 | Complete | 2026-04-24 |
| 6. Core semantics tightening | 0/TBD | Not started | - |
| 7. Package/module MVP | 0/TBD | Not started | - |
| 8. VM correctness harness | 0/TBD | Not started | - |

## Coverage

| Requirement Group | Requirements | Phase |
|-------------------|--------------|-------|
| Feature Status | STAT-01..STAT-03 | Phase 5 |
| Stable Core Boundary | CORE-01 | Phase 5 |
| Core Semantics | CORE-02..CORE-05 | Phase 6 |
| Package MVP | PKG-01..PKG-06 | Phase 7 |
| VM Correctness | VMCHK-01..VMCHK-05 | Phase 8 |

**Total requirements:** 19
**Mapped to phases:** 19
**Unmapped:** 0

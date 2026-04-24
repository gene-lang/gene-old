# Requirements: Gene Core Stabilization + Package MVP

**Defined:** 2026-04-24
**Core Value:** Gene should feel trustworthy to build on: users can tell what
is stable, import packages deterministically, and rely on VM invariants being
actively checked.

## v1.1 Requirements

Requirements for the current milestone. Each maps to exactly one roadmap phase.

### Feature Status

- [ ] **STAT-01**: User can read one public feature-status matrix that marks
  each major Gene surface as stable, beta, experimental, future, or removed.
- [ ] **STAT-02**: User can see implementation status, test coverage status,
  and known gaps for each major feature without hunting across README, docs,
  specs, and planning files.
- [ ] **STAT-03**: Public README/docs do not promote experimental or removed
  surfaces as stable current capabilities.

### Core Semantics

- [ ] **CORE-01**: User can read a crisp stable-core definition covering
  syntax, values, variables, functions, lexical scope, macros, modules/imports,
  errors, collections, async futures, and actor-first concurrency.
- [ ] **CORE-02**: User can distinguish `nil` from `void` consistently across
  selectors, maps, arrays, objects, Gene properties, failed lookup, and function
  return behavior.
- [ ] **CORE-03**: User can understand when Gene expression properties are
  metadata, when children are evaluated, and what structure macros receive.
- [ ] **CORE-04**: User can identify the stable subset and known gaps of pattern
  matching, including destructuring, ADTs, branch failure, arity, and
  exhaustiveness behavior.
- [ ] **CORE-05**: Core semantic claims are backed by runnable tests or focused
  Nim tests for the stable subset.

### Package MVP

- [ ] **PKG-01**: User can define `package.gene` metadata with package name,
  version, source directory, main module, and test directory, and the VM/tooling
  parses those fields into a package model.
- [ ] **PKG-02**: User can access current package metadata through `$pkg` or the
  documented replacement surface.
- [ ] **PKG-03**: User can declare local/path dependencies with `$dep` or the
  documented replacement syntax and receive deterministic diagnostics for
  malformed dependency declarations.
- [ ] **PKG-04**: User can import modules through deterministic package-aware
  resolution that honors package root, source directory, local dependencies,
  and direct import paths.
- [ ] **PKG-05**: User can generate and verify a local `package.gene.lock` for
  reproducible local/path dependency resolution.
- [ ] **PKG-06**: Package/module behavior is covered by focused tests and docs
  that explain what is MVP, deferred, and out of scope.

### VM Correctness

- [ ] **VMCHK-01**: Runtime maintainers can run a checked VM mode that validates
  core instruction invariants without affecting optimized default execution.
- [ ] **VMCHK-02**: Instruction metadata exists for stack effects, operands,
  reference/lifetime behavior, and debug formatting for the currently supported
  opcode set.
- [ ] **VMCHK-03**: GIR compatibility checks fail clearly for stale or
  incompatible bytecode caches and are covered by regression tests.
- [ ] **VMCHK-04**: Parser, serializer/deserializer, and GIR round-trip stress
  coverage exists for representative stable-core values and failure paths.
- [ ] **VMCHK-05**: Checked-mode failures produce actionable diagnostics that
  identify the instruction or runtime boundary that violated an invariant.

## Future Requirements

Deferred to later milestones.

### Tooling And Ecosystem

- **TOOL-01**: User receives type-checker-backed LSP diagnostics.
- **TOOL-02**: User can run a broad benchmark suite covering selectors, maps,
  classes, adapters, async I/O, GIR cold start, extension calls, and
  serialization.
- **TOOL-03**: User can install packages from a registry or remote index.

### Runtime Trust And Types

- **EXT-01**: Native extensions have a documented trust, search-path, ABI, and
  signing/checksum policy.
- **TYPE-01**: Type descriptors flow canonically across checker, compiler, GIR,
  and runtime objects.
- **TYPE-02**: Advanced generic classes, flow typing, and broader interface
  conformance checks are implemented after the package/core boundary is stable.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Reintroduce public thread-first APIs | Phase 4 removed them; actors are the public concurrency surface |
| Package registry / network resolver | Local deterministic package MVP must land before external ecosystem machinery |
| Full package version solver | MVP needs path/local deterministic deps first; version graph policy can follow |
| LSP expansion | Valuable, but weaker than package/core/VM trust for this milestone |
| Native extension signing/trust model | Important future work, but separate from package MVP and VM checked mode |
| Advanced type-system/generics work | Defer until stable core and package boundaries are clearer |
| Distributed actors / supervision trees / hot code loading | Outside the current single-process Gene VM scope |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| STAT-01 | Phase 5 | Pending |
| STAT-02 | Phase 5 | Pending |
| STAT-03 | Phase 5 | Pending |
| CORE-01 | Phase 5 | Pending |
| CORE-02 | Phase 6 | Pending |
| CORE-03 | Phase 6 | Pending |
| CORE-04 | Phase 6 | Pending |
| CORE-05 | Phase 6 | Pending |
| PKG-01 | Phase 7 | Pending |
| PKG-02 | Phase 7 | Pending |
| PKG-03 | Phase 7 | Pending |
| PKG-04 | Phase 7 | Pending |
| PKG-05 | Phase 7 | Pending |
| PKG-06 | Phase 7 | Pending |
| VMCHK-01 | Phase 8 | Pending |
| VMCHK-02 | Phase 8 | Pending |
| VMCHK-03 | Phase 8 | Pending |
| VMCHK-04 | Phase 8 | Pending |
| VMCHK-05 | Phase 8 | Pending |

**Coverage:**
- v1.1 requirements: 19 total
- Mapped to phases: 19
- Unmapped: 0

---
*Requirements defined: 2026-04-24*
*Last updated: 2026-04-24 after v1.1 milestone initialization*

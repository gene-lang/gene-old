# Gene Core Stabilization + Package MVP

## What This Is

`gene-old` is the Nim bytecode VM implementation for Gene: parser, compiler,
VM, GIR cache, stdlib, extensions, async futures, and the now-complete
actor-first concurrency runtime. The current workstream moves beyond actor
migration and stabilizes the public language/product surface: feature status,
core semantics, package/module workflow, and VM correctness infrastructure.

## Core Value

Gene should feel trustworthy to build on: users can tell what is stable, import
packages deterministically, and rely on VM invariants being actively checked.

## Current Milestone: v1.1 Core Stabilization + Package MVP

**Goal:** Convert the broad post-review feedback into a focused stabilization
milestone that makes Gene easier to trust, package, and evolve.

**Target features:**
- Public feature status matrix with stable/beta/experimental boundaries.
- Tightened core semantics for `nil`/`void`, selectors, Gene expression
  evaluation, macros, and pattern-matching status.
- Package/module MVP covering `package.gene` metadata, `$pkg`, `$dep`, local
  dependency resolution, lockfile/install flow, and deterministic imports.
- VM correctness harness for debug invariants, instruction metadata, GIR
  compatibility checks, and parser/serdes stress coverage.

## Requirements

### Validated

- ✓ Bytecode execution, async futures, thread messaging, native trampoline
  compilation, and stdlib string operations already exist in the current
  runtime.
- ✓ Brownfield planning context in `.planning/codebase/`.
- ✓ Phase 0 substrate: unified managed RC with atomic increments, synchronized
  publication for lazy bodies and native entry, shared-inline-cache mutation
  removed, immutable strings and removed literal copies, bootstrap freeze
  boundary with init-time namespace snapshots *(commit e2e776c, 2026-04-18)*.
- ✓ Phase 1 substrate: header bits, `(freeze v)`, deep-frozen write guards,
  shared-vs-owned RC branching, shared-heap verification, and sealed-vs-frozen
  naming all landed and verified *(commits `f153f95`..`a36452b`, verified
  2026-04-19)*.
- ✓ Actor migration track complete: freezable closures, actor runtime, port
  actors for stateful extensions, and retired thread-first public API are all
  landed and verified through Phase 4.
- ✓ GPT Pro review triage complete; stale async/concurrency spec fixed in
  `b54b8f2`, with broader review items accepted as milestone-level work.
- ✓ Phase 5 feature status matrix and stable-core boundary are published in
  `docs/feature-status.md`, with README/docs/spec entry points aligned to
  actor-first concurrency.
- ✓ Phase 6 core semantics tightening documented and tested `nil`/`void`,
  selector defaults, Gene expression/macro behavior, and pattern-matching
  stable-subset boundaries.
- ✓ Phase 7 package/module MVP shipped shared `package.gene` parsing, `$pkg`
  metadata, local/path dependency lockfile diagnostics, and manifest/lockfile
  aware imports.

### Active

- [ ] Add a VM correctness harness so optimized execution has a checked mode
  and broader compatibility coverage.

### Out of Scope

- Reopening the public thread-first concurrency API - actors remain the public
  concurrency surface; worker threads are internal runtime machinery.
- Public package registry, remote dependency discovery, or hosted ecosystem
  services - local deterministic package workflow comes first.
- LSP expansion, benchmark suite expansion, and native-extension trust/signing
  model - valid future work, but lower priority than status/package/core/VM
  stabilization.
- Advanced type-system work such as generics, broad flow typing, or descriptor
  pipeline unification - defer until the stable core and package boundaries are
  clearer.
- Distributed actors, supervision trees, hot code loading, and compile-time
  effect typing - still outside the current product boundary.

## Context

The actor migration milestone is complete and should stay closed. The GPT Pro
review was useful because it identified the next product problem: Gene has
many promising surfaces, but users need clearer status boundaries, a package
story, and stronger VM correctness tooling before more features are added.

Existing local evidence supports this direction:
- `README.md` already says pattern matching, classes, modules, and packages
  have known limitations.
- `docs/package_support.md` says `package.gene` is marker/metadata only, `$dep`
  is not implemented, `$pkg` is not wired, and there is no version/lock/install
  story yet.
- `.planning/codebase/CONCERNS.md` flags monolithic VM execution, GIR
  compatibility, incomplete pattern/range/template coverage, and package
  ergonomics as known risks.
- `docs/handbook/actors.md` and `spec/10-async.md` now align on actor-first
  concurrency.

## Constraints

- **Tech stack**: Keep the existing Nim runtime and test harness - no new
  dependencies without explicit request.
- **Compatibility**: Do not break the actor-first API or the completed
  frozen/shared-value substrate while stabilizing docs and packages.
- **Validation**: Every implementation phase should include focused Nim tests
  and, when relevant, runnable `testsuite/` coverage.
- **Package scope**: Package MVP is local and deterministic first; no registry
  or network dependency workflow in this milestone.
- **Docs before claims**: Public docs must classify incomplete or experimental
  behavior before promoting it as stable.
- **Planning**: Legacy `.planning/phases/01-architecture-comparison/` is
  archived under `.planning/archive/`; do not resurrect without triage.
- **Performance**: VM correctness instrumentation must be opt-in/debug-mode so
  optimized execution stays fast.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Mirror P0.1-P0.5 as five executable plans | Preserves proposal rollback boundaries and keeps verification focused | ✓ Complete — all five plans shipped |
| Resolve P0.4 with return-new-string semantics for `String.append` | Smallest immutable-string cut that removes the current literal-copy workaround | ✓ Complete |
| Phase 0 closeout commit `e2e776c` addresses review gaps before Phase 1 | Cross-AI review flagged P0.1 RC race and P0.5 bootstrap as HIGH risk; both resolved in one commit | ✓ Complete |
| Archive legacy `01-architecture-comparison/` to unblock Phase 1 numbering | Legacy exploratory material (gene-old vs gene comparison) is unrelated to actor track | ✓ Moved to `.planning/archive/` |
| Phase 1 uses `--skip-research` with CONTEXT defaults rather than a discuss round | User elected fast path; defaults documented in Phase 1 CONTEXT.md and revisable at review round | ✓ Complete — Phase 1 shipped across commits `f153f95`..`a36452b` |
| Split freezable closures into Phase 1.5 (not Phase 1) | Closure captured-env analysis is its own workstream; holding Phase 1 to containers keeps the scope testable | ✓ Complete — Phase 1.5 shipped across commits `9e9a97a`..`cfb9140` |
| Keep legacy thread-first concurrency surfaces unchanged during Phase 1.5 | Closure freezeability is the last substrate gate; actor scheduling and thread-surface removal belong to later phases | ✓ Complete — Phase 1.5 docs/tests fence migration boundaries explicitly |
| Phase 2 keeps actor replies on the existing Future runtime | Reusing `FutureObj`/`MtReply` avoids a second await subsystem and keeps callbacks/timeouts consistent | ✓ Complete |
| Phase 3 uses `genex/llm` as the first host/extension ownership migration and `genex/http` / AI bindings as the next pool-or-factory migrations | These are the clearest remaining extension-side concurrency surfaces after Phase 2 | ✓ Complete |
| Resolve the dynamic `genex/llm` boundary with an explicit exported-function bridge plus host-owned `Model` / `Session` wrappers fronted by one host-owned actor | Live extension-owned `Value` returns across the dylib boundary proved unstable; host-owned wrappers preserve the public API while keeping backend handles internal | ✓ Complete (`03-02`) |
| Close Phase 3 by moving `genex/http` and `genex/ai/bindings` off extension-local thread/global callback ownership | HTTP now uses actor-backed request ports, and Socket Mode binding ownership is actor-scoped instead of process-global | ✓ Complete (`03-03`) |
| Keep legacy thread docs explicit during Phase 3 and defer actual thread-surface removal to Phase 4 | Extension migration and public API removal are different risks; Phase 3 closes ownership, Phase 4 removes the old surface | ✓ Complete |
| Remove the surviving thread-first public surface while preserving the internal worker substrate actors still use | The actor runtime still depends on worker threads internally, so Phase 4 removed only the public/compiler/docs lane and worker naming debt | ✓ Complete (`04-01`/`04-02`) |
| Start v1.1 as core stabilization plus package MVP | GPT Pro review exposed broad scope/status/package risks after actor migration; package/core/VM trust are higher leverage than new feature breadth | In progress - Phase 7 complete |
| Use `docs/feature-status.md` as the public status hub | Users need one place to see stable, beta, experimental, future, and removed surfaces before package/core/VM work expands claims | ✓ Complete (`05-01`) |
| Keep Phase 6 semantics scoped to documented stable subsets | `nil`/`void`, selectors, Gene evaluation, macros, and pattern matching needed explicit stable-vs-experimental boundaries before package and VM claims widen | ✓ Complete (`06-01`) |
| Keep package MVP local-first | A registry would multiply product and trust decisions before import/package semantics are stable | ✓ Complete (`07-01`) |
| Share manifest parsing between runtime and `gene deps` | Duplicate manifest parsing would drift package imports, `$pkg`, and lockfile diagnostics | ✓ Complete (`07-01`) |
| Keep VM correctness checks debug-oriented | The optimized VM deliberately trades checks for speed, so invariant coverage belongs in checked/test modes first | Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition:**
1. Requirements invalidated? -> Move to Out of Scope with reason
2. Requirements validated? -> Move to Validated with phase reference
3. New requirements emerged? -> Add to Active
4. Decisions to log? -> Add to Key Decisions
5. "What This Is" still accurate? -> Update if drifted

**After each milestone:**
1. Full review of all sections
2. Core Value check - still the right priority?
3. Audit Out of Scope - reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-24 after Phase 07 completion*

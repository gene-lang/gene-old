# Gene Actor Runtime Migration

## What This Is

This workstream ports the approved actor-based concurrency design in
`docs/proposals/actor-design.md` into the existing `gene-old` runtime. Phase 0
(substrate cleanup) is complete. Phase 1 introduced the runtime machinery —
deep-frozen and shared header bits on `Value`, a shared-heap allocation path,
an atomic-vs-plain refcount branch, and the user-facing `(freeze v)` stdlib
operation over the MVP container scope — that every later actor-runtime phase
depends on, without adding a new concurrency API.

## Core Value

Phase 1 delivered the deep-frozen / shared-heap runtime substrate and the
`(freeze v)` user surface that every subsequent actor phase (scheduler, tiered
send, port actors) requires, without destabilizing the existing VM or shipping
a new concurrency API.

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

### Active

- [x] Plan Phase 1.5 (freezable closures) as the next hard prerequisite for
  Phase 2 actor scheduling.
- [x] Scope and execute Phase 2 actor runtime work on top of the verified
  Phase 1.5 substrate.
- [ ] Plan Phase 3 extension migration on top of the now-verified Phase 2
  actor runtime.

### Out of Scope

- Freezable closures — deferred to Phase 1.5 as a hard prerequisite for Phase 2.
- Actor scheduler, tiered send, reply futures, stop semantics — Phase 2.
- Port-actor protocol and extension migration — Phase 3.
- Thread API deprecation and `GENE_WORKERS` rename — Phase 4.
- Move-semantics `send!`, work-stealing scheduler, `^frozen-default` — deferred
  indefinitely per the approved proposal.
- Distributed actors, supervision trees, hot code loading, compile-time effect
  typing — explicitly rejected by the approved proposal.

## Context

`gene-old` is a brownfield Nim runtime with a bytecode VM, async futures,
thread messaging, extension loading, native compilation, AOP, and a broad
stdlib surface. The approved actor design proposal identifies current
correctness debt in ref-counting, lazy publication, thread APIs, mutable
strings, and bootstrap sharing as the blocking substrate for every later actor
phase.

Existing codebase analysis in `.planning/codebase/CONCERNS.md` flags scope
lifetime, thread lifecycle, and monolithic VM execution as fragile areas. This
track intentionally leaves the older `.planning/phases/01-architecture-
comparison/` material untouched so current work can focus on the proposal's
Phase 0 without renumbering or rewriting historical exploratory docs.

## Constraints

- **Tech stack**: Keep the existing Nim runtime and test harness - no new
  dependencies without explicit request.
- **Compatibility**: No user-facing break in Phase 1. `(freeze v)` is additive;
  existing thread code is unaffected.
- **Validation**: Every Phase 1 plan must not regress the Phase 0 acceptance
  sweep.
- **Planning**: Legacy `.planning/phases/01-architecture-comparison/` is
  archived under `.planning/archive/`; do not resurrect without triage.
- **Performance**: Owned-side refcount performance must not regress below the
  pre-Phase-0 baseline once the atomic-vs-plain branch lands.

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
*Last updated: 2026-04-19 after Phase 1.5 execution and verification pass*

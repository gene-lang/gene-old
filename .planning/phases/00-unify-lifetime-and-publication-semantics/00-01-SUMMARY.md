---
phase: 00-unify-lifetime-and-publication-semantics
plan: 01
subsystem: infra
tags: [lifetime, refcount, ownership, vm]
requires: []
provides:
  - Managed retain/release uses one canonical implementation for both Nim hooks and manual VM/runtime ownership edges
  - Managed refcount increments are atomic on the same paths as managed decrements
  - Lifetime regressions cover async/scope-managed values and repeated native publication reuse
affects: [phase-0, runtime, ownership, native-runtime]
tech-stack:
  added: []
  patterns:
    - "Manual Value ownership helpers delegate to memory.nim instead of duplicating RC logic"
    - "Managed refcount transitions use the same atomic increment/decrement primitives"
key-files:
  created: []
  modified:
    - src/gene/types/memory.nim
    - src/gene/types/core/value_ops.nim
    - tests/integration/test_scope_lifetime.nim
    - tests/test_native_trampoline.nim
key-decisions:
  - "Kept memory.nim as the canonical ownership implementation and routed manual helpers through it"
  - "Moved away from duplicated release-side special cases in value_ops.nim so managed destruction owns descriptor cleanup"
patterns-established:
  - "Stack/runtime ownership edges stay explicit, but lifetime mechanics live in one place"
  - "Regression tests cover managed values surviving async capture and post-scope teardown"
requirements-completed: [LIFE-01]
duration: unknown
completed: 2026-04-18
---

# Phase 0 / Plan 00-01 Summary

**Managed `Value` lifetimes now flow through one ownership implementation instead of split manual-vs-hook refcount paths**

## Accomplishments
- Switched `retainManaged` to atomic increments so the managed retain/decrement paths no longer disagree under concurrent ownership.
- Routed manual `retain` / `release` in `value_ops.nim` through `memory.nim` instead of maintaining a second copy of the RC logic.
- Routed `to_ref_value` through the managed retain path so boxed reference ownership follows the same rules as other managed values.
- Added lifetime regressions for managed arrays surviving async capture and scope teardown.
- Added a native regression that exercises repeated published-descriptor reuse across repeated execution.

## Files Created/Modified
- `src/gene/types/memory.nim` - Canonical managed retain/release now uses atomic increments and remains the single ownership implementation.
- `src/gene/types/core/value_ops.nim` - Manual VM/runtime ownership helpers now delegate to `memory.nim`.
- `tests/integration/test_scope_lifetime.nim` - Added async/scope managed-value regressions.
- `tests/test_native_trampoline.nim` - Added repeated native descriptor publication reuse coverage.

## Decisions Made
- The VM still decides where ownership boundaries exist, but `memory.nim` is now the only place that updates managed `Value` refcounts.
- No frame/trampoline-specific lifetime rewrite was needed once the duplicated manual RC path was removed from `value_ops.nim`.

## Verification
- `nim c -r tests/integration/test_scope_lifetime.nim`
- `nim c -r tests/test_native_trampoline.nim`

## Remaining Risks
- This does not yet introduce the Phase 1 shared-vs-owned heap split; it only removes the duplicated Phase 0 ownership machinery.
- Existing non-fatal compiler hints remain in the repository and were not changed by this plan.

---
*Phase: 00-unify-lifetime-and-publication-semantics*
*Completed: 2026-04-18*

---
phase: 00-unify-lifetime-and-publication-semantics
plan: 02
subsystem: infra
tags: [publication, gir, native, inline-cache, compiler]
requires:
  - phase: 00-01
    provides: "Stable lifetime assumptions at the runtime boundary"
provides:
  - Compilation units publish with pre-sized inline caches across compile, compile_init, and GIR load paths
  - Lazy function/block body publication now uses synchronized read/write helpers instead of plain slot reads
  - Native code publication snapshots entry/descriptor/return metadata under the publication lock
affects: [phase-0, compiler, gir, native-runtime, dispatch]
tech-stack:
  added: []
  patterns:
    - "Published compilation units must satisfy inline_caches.len == instructions.len"
    - "Lazy body publication and native publication use explicit synchronized publication helpers"
key-files:
  created: []
  modified:
    - src/gene/types/helpers.nim
    - src/gene/compiler.nim
    - src/gene/compiler/pipeline.nim
    - src/gene/gir.nim
    - src/gene/vm/exec.nim
    - src/gene/vm/native.nim
    - src/gene/vm.nim
    - tests/integration/test_cli_gir.nim
key-decisions:
  - "Used explicit synchronized publication helpers rather than broad eager compilation"
  - "Removed shared inline-cache mutation instead of leaving advisory cache races in the runtime hot path"
patterns-established:
  - "compile, compile_init, and load_gir are all publication surfaces and must initialize inline caches before runtime use"
  - "native_ready is the final publish step after all native metadata is installed"
requirements-completed: [PUB-01, PUB-02, PUB-03]
duration: unknown
completed: 2026-04-17
---

# Phase 0 / Plan 00-02 Summary

**Compilation units and native entry points now publish through synchronized helper paths instead of ad hoc runtime mutation**

## Performance

- **Duration:** not recorded
- **Started:** 2026-04-17
- **Completed:** 2026-04-17
- **Tasks:** 3
- **Files modified:** 8

## Accomplishments
- Removed on-demand inline-cache growth from the VM hot path and enforced a published-CU invariant.
- Replaced plain `body_compiled` slot reads in the runtime with synchronized published-body lookups.
- Serialized native publication and now snapshot native entry/descriptor/return metadata before use.
- Removed shared inline-cache mutation from the runtime path so pre-sized cache slots no longer participate in cross-thread races.
- Added a concurrent first-call regression that invokes the same uncompiled function from two threads.

## Task Commits

None - changes are currently uncommitted in the working tree.

## Files Created/Modified
- `src/gene/types/helpers.nim` - Added synchronized published-body read helpers on top of the existing publication locks.
- `src/gene/compiler.nim` - Keeps function/block lazy compilation behind the body-publication lock.
- `src/gene/compiler/pipeline.nim` - Publishes pre-sized inline caches from `compile_init`.
- `src/gene/gir.nim` - Sizes inline caches immediately on GIR load.
- `src/gene/vm/exec.nim` - Uses published-body helpers and no longer mutates shared inline-cache slots.
- `src/gene/vm/native.nim` - Snapshots native publication state under lock and uses the snapshot during the call.
- `tests/integration/test_cli_gir.nim` - Adds concurrent first-call publication coverage plus inline-cache sizing/lazy hook assertions.

## Decisions Made
- Publication safety is enforced with synchronized helper reads/writes instead of eager compilation.
- The inline-cache invariant is now strict: published units arrive ready, and shared cache-slot mutation is disabled rather than repaired opportunistically at runtime.

## Deviations from Plan

### Auto-fixed Issues

**1. Reader-side publication was still plain slot access**
- **Found during:** Review follow-up after the initial publication lock landing
- **Issue:** Writer-side serialization existed, but runtime reads still dereferenced `body_compiled` and native publication fields directly.
- **Fix:** Added synchronized published-body loads in `helpers.nim`, routed runtime call paths through them, and snapshot native publication state under lock before invocation.
- **Files modified:** `src/gene/types/helpers.nim`, `src/gene/vm/exec.nim`, `src/gene/vm/native.nim`
- **Verification:** GIR, native trampoline, and full testsuite regressions stayed green.

**2. Shared inline-cache slots were still a cross-thread race**
- **Found during:** Same review follow-up
- **Issue:** Pre-sizing removed growth races, but shared cache-slot mutation still wrote advisory cache entries from multiple threads.
- **Fix:** Removed shared inline-cache mutation from the runtime path instead of leaving a racy advisory cache behind.
- **Files modified:** `src/gene/vm/exec.nim`
- **Verification:** Concurrent first-call publication test and full testsuite regressions stayed green.

---

**Total deviations:** 2 auto-fixed
**Impact on plan:** Tightened P0.2 to match the proposal's synchronized publication intent instead of leaving the initial writer-only lock as the final state.

## Issues Encountered

The first strict inline-cache assertion exposed a real missed publication surface in `compile_init`. The later review then exposed the remaining reader-side and cache-slot gaps. Tightening the helpers was cleaner than broad eager compilation or keeping a racy advisory cache path.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Publication safety now covers both publish and read-side usage for lazy bodies/native entry points, and the shared inline-cache mutation path is gone. The remaining independent Phase 0 closeout work is bootstrap publication discipline plus the final acceptance sweep.

---
*Phase: 00-unify-lifetime-and-publication-semantics*
*Completed: 2026-04-17*

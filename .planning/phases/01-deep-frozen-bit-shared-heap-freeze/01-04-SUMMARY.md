---
phase: 01-deep-frozen-bit-shared-heap-freeze
plan: 04
subsystem: infra
tags: [refcount, shared-heap, freeze, nim, runtime]
requires:
  - phase: 01-deep-frozen-bit-shared-heap-freeze
    provides: "Header-bit substrate from 01-01"
provides:
  - "Managed RC now branches on the shared header bit for ARRAY, MAP, INSTANCE, GENE, REF, and STRING"
  - "Focused regression coverage for plain-vs-atomic RC paths plus shared-path thread stress"
  - "Owned-case retain/release performance restored beyond the pre-e2e776c baseline on the benchmarked hot loop"
affects: [phase-1, freeze-runtime, shared-heap, refcount]
tech-stack:
  added: []
  patterns:
    - "Branch RC primitive per managed header instead of forcing atomic ops on all managed values"
    - "Use test-only compile-time probes to assert RC path selection without changing production behavior"
key-files:
  created:
    - tests/test_phase1_rc_branch.nim
  modified:
    - src/gene/types/memory.nim
key-decisions:
  - "Aligned InstanceObj with the same shared-bit RC branch as the other managed headers once flags existed on the instance header"
  - "Recorded the publication happens-before invariant directly in memory.nim beside the RC helpers"
requirements-completed: [RC-02]
duration: 24m
completed: 2026-04-18
---

# Phase 1 / Plan 01-04 Summary

**Managed retain/release now recover the owned-case fast path by branching on `shared` across all managed headers that carry the bit, while preserving atomic RC for published values**

## Performance

- **Duration:** 24m
- **Tasks:** 5
- **Files modified:** 3

## Accomplishments

- Added a module-level publication invariant comment and shared-bit RC helpers in `src/gene/types/memory.nim`, then switched the `ARRAY`, `MAP`, `INSTANCE`, `GENE`, `REF`, and `STRING` arms in both `retainManaged` and `releaseManaged` to branch on the managed header's `shared` bit.
- Added `tests/test_phase1_rc_branch.nim` with direct probe assertions for the plain and atomic paths across every managed header kind, plus shared-path threaded retain/release stress coverage and a reusable owned-array benchmark.
- Re-ran the full Phase 0 acceptance sweep with no regressions.

## Converted Arms

- `ARRAY`
- `MAP`
- `INSTANCE`
- `GENE`
- `REF`
- `STRING`

## Instance Branching

- `INSTANCE` now participates in the same branch contract as the other
  managed headers because `InstanceObj` already carries `flags` from `01-01`
  and Phase 1's owned-vs-shared RC split should not exempt actor-local
  instances.

## Benchmark

- **Current release benchmark:** `owned_array` retain/release pair = `2.71 ns/op`
- **Baseline release benchmark:** pre-`e2e776c` (`cbe098a`) `owned_array` retain/release pair = `3.73 ns/op`
- **Delta:** current is about `27.3%` faster than the baseline hot loop on this machine, comfortably inside the plan's "within 5%" acceptance target.

## Publication Comment

- The happens-before invariant is documented in `src/gene/types/memory.nim:1-9`.

## Verification

- `nim check src/gene.nim`
- `nim c -r tests/test_phase1_rc_branch.nim`
- `nim c -d:release -r tests/test_phase1_rc_branch.nim`
- Baseline comparison via temporary worktree at `cbe098a` using the same benchmark harness
- `nim c -r tests/test_bootstrap_publication.nim`
- `nim c -r tests/integration/test_scope_lifetime.nim`
- `nim c -r tests/integration/test_cli_gir.nim`
- `nim c -r tests/integration/test_thread.nim`
- `nim c -r tests/integration/test_stdlib_string.nim`
- `nim c -r tests/test_native_trampoline.nim`
- `./testsuite/run_tests.sh`

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None.

## Issues Encountered

- Shared `.planning` files already had unrelated uncommitted roadmap/state edits before this plan started, so only the plan-local summary file was added here.

## Self-Check

PASSED

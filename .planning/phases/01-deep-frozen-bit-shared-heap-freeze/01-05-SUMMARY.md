---
phase: 01-deep-frozen-bit-shared-heap-freeze
plan: 05
subsystem: infra
tags: [shared-heap, freeze, threads, tsan, nim, runtime]
requires:
  - phase: 01-deep-frozen-bit-shared-heap-freeze
    provides: "Header-bit accessors and freeze tagging from 01-01 and 01-02"
  - phase: 01-deep-frozen-bit-shared-heap-freeze
    provides: "Shared-bit retain/release branching from 01-04"
provides:
  - "Proposal text that fixes Phase 1 shared-heap semantics as tag-on-heap publication rather than a new allocator"
  - "A module-level retain/release invariant spelling out when shared values may be dereferenced across threads"
  - "A cross-thread shared-heap regression that freezes a nested value, publishes it through an atomic slot, and proves stable refcounts under contention"
affects: [phase-1, phase-2, shared-heap, freeze-runtime, actor-send]
tech-stack:
  added: []
  patterns:
    - "Use an Atomic[uint64] publication slot to model raw-pointer handoff while retaining through the runtime RC hooks"
    - "Prove cross-thread read safety by recursively traversing the frozen graph and asserting exact refcount restoration after worker joins"
key-files:
  created:
    - tests/test_phase1_shared_heap.nim
  modified:
    - docs/proposals/actor-design.md
    - src/gene/types/memory.nim
key-decisions:
  - "Phase 1 shared heap remains semantic: shared frozen values stay on the existing managed heap and become cross-thread readable by publication discipline, not allocator migration"
  - "The regression pins correctness to exact before/after refcount equality instead of assuming a specific initial count for the constructed nested graph"
requirements-completed: [HEAP-01]
duration: 7m
completed: 2026-04-19
---

# Phase 1 / Plan 01-05 Summary

**Phase 1 shared-heap semantics are now documented as tag-on-heap publication, with a passing cross-thread frozen-value stress test and TSAN coverage proving shared reads preserve exact refcounts**

## Performance

- **Duration:** 7m
- **Started:** 2026-04-19T00:39:30Z
- **Completed:** 2026-04-19T00:46:38Z
- **Tasks:** 5
- **Files modified:** 3

## Accomplishments

- Clarified `docs/proposals/actor-design.md:308-339` so the approved Phase 1 "shared heap" is semantic (`shared == true` on the existing managed heap), while a dedicated pool allocator stays deferred as a later performance track.
- Strengthened the module header in `src/gene/types/memory.nim:1-13` with the full publication invariant: set `shared` under the publication barrier, dereference across threads only through `shared == true`, and treat cross-thread `shared == false` handoff as a bug.
- Added `tests/test_phase1_shared_heap.nim:1-188`, which freezes a nested gene/array/map/hash-map/bytes graph, publishes its raw pointer via `Atomic[uint64]`, retains and traverses it from worker threads, and checks both recursive readability and exact refcount restoration.
- Completed the required 100-iteration stress loop, the best-effort TSAN lane, and the full Phase 0 acceptance sweep without regressions.

## Implementation Commit

- `24a1efd` — `feat(01-05): prove shared frozen values stay safe across threads`

## Verification

- `nim check src/gene.nim` — PASS
- `nim c -r --mm:orc --threads:on tests/test_phase1_shared_heap.nim` — PASS
- `nim c -r --mm:orc --threads:on tests/test_phase1_shared_heap.nim` x100 — PASS (100/100)
- `nim c -r --mm:orc --threads:on --passC:-fsanitize=thread --passL:-fsanitize=thread tests/test_phase1_shared_heap.nim` — PASS
- `nim c -r tests/test_bootstrap_publication.nim` — PASS
- `nim c -r tests/integration/test_scope_lifetime.nim` — PASS
- `nim c -r tests/integration/test_cli_gir.nim` — PASS
- `nim c -r tests/integration/test_thread.nim` — PASS
- `nim c -r tests/integration/test_stdlib_string.nim` — PASS
- `nim c -r tests/test_native_trampoline.nim` — PASS
- `./testsuite/run_tests.sh` — PASS

## Stress Test Run Log

```text
iteration 1 PASS
iteration 2 PASS
iteration 3 PASS
iteration 4 PASS
iteration 5 PASS
iteration 6 PASS
iteration 7 PASS
iteration 8 PASS
iteration 9 PASS
iteration 10 PASS
iteration 11 PASS
iteration 12 PASS
iteration 13 PASS
iteration 14 PASS
iteration 15 PASS
iteration 16 PASS
iteration 17 PASS
iteration 18 PASS
iteration 19 PASS
iteration 20 PASS
iteration 21 PASS
iteration 22 PASS
iteration 23 PASS
iteration 24 PASS
iteration 25 PASS
iteration 26 PASS
iteration 27 PASS
iteration 28 PASS
iteration 29 PASS
iteration 30 PASS
iteration 31 PASS
iteration 32 PASS
iteration 33 PASS
iteration 34 PASS
iteration 35 PASS
iteration 36 PASS
iteration 37 PASS
iteration 38 PASS
iteration 39 PASS
iteration 40 PASS
iteration 41 PASS
iteration 42 PASS
iteration 43 PASS
iteration 44 PASS
iteration 45 PASS
iteration 46 PASS
iteration 47 PASS
iteration 48 PASS
iteration 49 PASS
iteration 50 PASS
iteration 51 PASS
iteration 52 PASS
iteration 53 PASS
iteration 54 PASS
iteration 55 PASS
iteration 56 PASS
iteration 57 PASS
iteration 58 PASS
iteration 59 PASS
iteration 60 PASS
iteration 61 PASS
iteration 62 PASS
iteration 63 PASS
iteration 64 PASS
iteration 65 PASS
iteration 66 PASS
iteration 67 PASS
iteration 68 PASS
iteration 69 PASS
iteration 70 PASS
iteration 71 PASS
iteration 72 PASS
iteration 73 PASS
iteration 74 PASS
iteration 75 PASS
iteration 76 PASS
iteration 77 PASS
iteration 78 PASS
iteration 79 PASS
iteration 80 PASS
iteration 81 PASS
iteration 82 PASS
iteration 83 PASS
iteration 84 PASS
iteration 85 PASS
iteration 86 PASS
iteration 87 PASS
iteration 88 PASS
iteration 89 PASS
iteration 90 PASS
iteration 91 PASS
iteration 92 PASS
iteration 93 PASS
iteration 94 PASS
iteration 95 PASS
iteration 96 PASS
iteration 97 PASS
iteration 98 PASS
iteration 99 PASS
iteration 100 PASS
```

## Citations

- **Doc update:** `docs/proposals/actor-design.md:308-339`
- **Invariant comment:** `src/gene/types/memory.nim:1-13`
- **Cross-thread regression:** `tests/test_phase1_shared_heap.nim:1-188`
- **TSAN lane:** exercised successfully on this macOS build lane with the command above

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed the nested graph assembly in the new stress test**
- **Found during:** Task 3
- **Issue:** The first test version wrote the checksum map into `root.gene.children[1]`, but the constructed graph only added one root child array, so the first runtime pass failed with `IndexDefect`.
- **Fix:** Redirected the write to the nested leaf gene inside `root.gene.children[0]`.
- **Files modified:** `tests/test_phase1_shared_heap.nim`
- **Verification:** `nim c -r --mm:orc --threads:on tests/test_phase1_shared_heap.nim`
- **Committed in:** `24a1efd`

**2. [Rule 3 - Blocking] Relaxed the baseline refcount assertion to the actual invariant**
- **Found during:** Task 4
- **Issue:** The first stress assertion assumed the constructed shared root would start at refcount `1`, but legitimate nested retains meant the baseline count was higher on the assembled graph.
- **Fix:** Changed the test to assert `baseline_refcount >= 1` and exact before/after equality after all worker threads release.
- **Files modified:** `tests/test_phase1_shared_heap.nim`
- **Verification:** 100/100 ORC threaded stress loop plus the TSAN lane
- **Committed in:** `24a1efd`

**Total deviations:** 2 auto-fixed (2 blocking)
**Impact on plan:** Both fixes were local to the new regression harness and necessary to make the intended shared-heap proof executable. No scope creep.

## Known Stubs

None.

## Issues Encountered

- Shared `.planning` files already had unrelated uncommitted changes before this plan started, so this plan only adds its own summary and the required state/roadmap bookkeeping on top of that existing workspace state.

## Self-Check

PASSED

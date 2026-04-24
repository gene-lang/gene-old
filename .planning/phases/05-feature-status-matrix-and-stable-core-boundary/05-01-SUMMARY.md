---
phase: 05-feature-status-matrix-and-stable-core-boundary
plan: 01
subsystem: documentation
tags: [feature-status, stable-core, docs, actors, packages]

requires:
  - phase: 04-remove-legacy-thread-first-concurrency-surfaces
    provides: retired public thread-first API boundary and actor-first concurrency baseline
provides:
  - public feature-status matrix
  - stable-core boundary
  - README/docs/spec entry-point alignment
affects: [phase-06-core-semantics, phase-07-package-module-mvp, phase-08-vm-correctness]

tech-stack:
  added: []
  patterns: [public status matrix, stable-core inclusion and exclusion list]

key-files:
  created:
    - docs/feature-status.md
  modified:
    - README.md
    - docs/README.md
    - spec/README.md
    - docs/wasm.md

key-decisions:
  - "Feature stability claims now live in docs/feature-status.md."
  - "Actors are documented as the public concurrency surface; native workers remain internal."
  - "Packages, selectors, classes/adapters, pattern matching, GIR compatibility, native extension trust, WASM parity, and public thread-first APIs are excluded from the stable core."

patterns-established:
  - "Public feature rows include status, docs/specs, implementation state, tests, known gaps, and user posture."
  - "Stable-core claims require implementation, public docs/specs, and focused tests."

requirements-completed: [STAT-01, STAT-02, STAT-03, CORE-01]

duration: 3 min
completed: 2026-04-24
---

# Phase 05 Plan 01: Feature Status Matrix And Stable-Core Boundary Summary

**Public feature-status matrix with explicit stable-core membership and actor-first concurrency entry-point cleanup**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-24T02:44:17Z
- **Completed:** 2026-04-24T02:47:26Z
- **Tasks:** 4
- **Files modified:** 5

## Accomplishments

- Created `docs/feature-status.md` as the public matrix for stable, beta,
  experimental, future, and removed Gene surfaces.
- Defined the stable core and explicitly excluded partial or future surfaces
  such as package manifests, selector edge semantics, advanced OOP/adapters,
  pattern matching, GIR compatibility guarantees, native-extension trust
  policy, WASM parity, distributed actors, and public thread-first APIs.
- Updated README, docs index, spec index, and WASM docs to link the matrix and
  use actor-first concurrency wording.

## Task Commits

1. **Task 1: Create the public feature status matrix** - `fbc8ff7`
2. **Task 2: Define the stable core boundary** - `ccbbe8c`
3. **Task 3: Update public entry points** - `1d6adc5`
4. **Task 4: Run documentation verification** - verification-only task; results captured below and in the plan metadata commit.

## Files Created/Modified

- `docs/feature-status.md` - public feature-status matrix and stable-core boundary
- `README.md` - links the matrix, lists actor-first concurrency, and removes the stale implementation-status link
- `docs/README.md` - points readers to the status matrix first
- `spec/README.md` - changes async/concurrency wording from threads to actors/public concurrency surface
- `docs/wasm.md` - describes unsupported actor/native worker-backed concurrency instead of public thread APIs

## Decisions Made

- Kept Phase 05 documentation-only. Runtime gaps are documented as beta,
  experimental, or future work rather than silently fixed in this phase.
- Classified packages as experimental because current package behavior is root
  detection and path/import support, while manifest interpretation, `$pkg`,
  `$dep`, lockfiles, and dependency diagnostics belong to Phase 07.
- Classified selectors, classes/adapters, gradual typing, GIR, native
  extensions, WASM, and tooling as beta where useful but not stable core.

## Deviations from Plan

None - plan executed exactly as written.

**Total deviations:** 0 auto-fixed.
**Impact on plan:** None.

## Issues Encountered

- `gsd-sdk query state.begin-phase` and requirement helpers used local formatting
  that required manual cleanup in `.planning/STATE.md` and
  `.planning/REQUIREMENTS.md`.

## Verification

- `test -f docs/feature-status.md`
- `rg -n "## Feature Status Matrix|## Stable Core Boundary|Stable|Beta|Experimental|Future|Removed" docs/feature-status.md`
- `rg -n "syntax|values|functions|macros|modules|packages|classes|adapters|selectors|async|actors|pattern|GIR|native extensions|WASM|LSP|tooling" docs/feature-status.md`
- `rg -n "feature-status.md" README.md docs/README.md`
- `rg -n "actor-first|gene/actor|public concurrency surface" README.md docs/feature-status.md spec/README.md docs/wasm.md`
- `! rg -n "docs/IMPLEMENTATION_STATUS.md|Futures, async/await, threads|thread APIs|Thread spawn/messaging APIs" README.md spec/README.md docs/wasm.md`
- `git diff --check`

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Phase 06 can now tighten nil/void, selectors, Gene expression evaluation, macro
input shape, and pattern-matching semantics against a clear stable-core
boundary.

## Self-Check: PASSED

- Required file exists: `docs/feature-status.md`
- README and docs index link to the matrix.
- Public concurrency wording is actor-first.
- Stale implementation-status and thread-first strings are absent from the
  public entry docs targeted by the plan.

---
*Phase: 05-feature-status-matrix-and-stable-core-boundary*
*Completed: 2026-04-24*

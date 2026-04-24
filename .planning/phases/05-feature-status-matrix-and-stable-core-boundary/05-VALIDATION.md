# Phase 05 Validation Strategy

status: planned
phase: 05-feature-status-matrix-and-stable-core-boundary
requirements: [STAT-01, STAT-02, STAT-03, CORE-01]

## Validation Approach

Phase 05 is documentation-only. Validation should prove that the public status
surface exists, covers the required feature classes, defines the stable core,
and removes stale public entry points.

## Acceptance Checks

Run these checks after execution:

```bash
test -f docs/feature-status.md
rg -n "## Feature Status Matrix|## Stable Core Boundary|Stable|Beta|Experimental|Future|Removed" docs/feature-status.md
rg -n "syntax|values|functions|macros|modules|packages|classes|adapters|selectors|async|actors|pattern|GIR|native extensions|WASM|LSP|tooling" docs/feature-status.md
rg -n "feature-status.md" README.md docs/README.md
rg -n "actor-first|gene/actor|public concurrency surface" README.md docs/feature-status.md spec/README.md docs/wasm.md
! rg -n "docs/IMPLEMENTATION_STATUS.md|Futures, async/await, threads|thread APIs|Thread spawn/messaging APIs" README.md spec/README.md docs/wasm.md
git diff --check
```

## Requirement Coverage

| Requirement | Validation |
|-------------|------------|
| STAT-01 | Matrix includes all required status labels and required feature surfaces. |
| STAT-02 | Each row includes implementation status, test status, and known gaps. |
| STAT-03 | Grep checks reject stale implementation-status and thread-first wording in public entry docs. |
| CORE-01 | Stable-core section names the required stable surfaces and actor-first concurrency. |

## Runtime Test Decision

No Nim/runtime tests are required for this phase unless execution changes code.
If execution discovers runtime status claims that cannot be backed by existing
tests, the correct response is to mark the row beta/experimental or defer test
work to Phase 06/07/08, not to broaden Phase 05 into runtime implementation.

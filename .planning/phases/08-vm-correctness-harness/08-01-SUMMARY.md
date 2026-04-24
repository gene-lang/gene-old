---
phase: 08-vm-correctness-harness
plan: 01
status: complete
completed_at: 2026-04-24
requirements_completed: [VMCHK-01, VMCHK-02, VMCHK-03, VMCHK-04, VMCHK-05]
commits:
  - 8bf5fd5
  - 81edc28
  - 685e29e
  - 31beba7
  - final documentation/status commit
---

# Phase 08 Plan 01 Summary

## Outcome

Completed the VM correctness harness. Gene now has centralized instruction
metadata, opt-in checked VM execution for debug builds, actionable invariant
diagnostics, GIR header compatibility failures with expected/actual values, and
stable-core stress coverage across parser, serdes, direct GIR, and cached GIR
paths.

## Changes

- Added `src/gene/types/instruction_metadata.nim` and routed instruction debug
  formatting through metadata-backed operand formatting.
- Added `VirtualMachine.checked_vm`, `src/gene/vm/checks.nim`, and
  `--checked-vm` support for `run`, `eval`, and `pipe`.
- Wired checked dispatch hooks behind `when defined(geneVmChecks)` so optimized
  default execution remains unchecked.
- Validated checked-mode stack, frame, scope, operand, exception-handler, and
  boundary refcount invariants with targeted tests.
- Hardened GIR load diagnostics and cache invalidation for GIR version,
  compiler version, Value ABI, instruction ABI, bad magic, and source hash.
- Added stable-core stress tests for missing selector `void` semantics, parser
  rendering, serdes, direct GIR, cached GIR, and deterministic failure paths.
- Made `void` a compilable and serializable literal so user code can write
  `(if (g/x == void) ...)` for missing selector handling.
- Updated docs, requirements, roadmap, and state for Phase 08 completion.

## Verification

- `nim c -r tests/test_instruction_metadata.nim`
- `nim c -d:geneVmChecks -r tests/test_vm_checked_mode.nim`
- `nim c -r tests/integration/test_cli_gir.nim`
- `nim c -r tests/integration/test_cli_run.nim`
- `nim c -r tests/integration/test_stable_core_stress.nim`
- `nim c -r tests/integration/test_core_semantics.nim`
- `nim c -r tests/integration/test_serdes.nim`
- `nim c src/gene.nim`
- `nimble testintegration`
- `git diff --check`

## Deviations

- Tasks 2 and 3 were committed together because the checked-mode activation
  tests required the dispatch and exception-boundary hooks to prove the mode.
- The stable-core stress harness exposed that parsed `void` was not yet
  compilable or serializable. That runtime gap was fixed in scope because it is
  required for the documented `(if (g/x == void) ...)` user path.

## Remaining Risks

- Checked mode is a practical debug harness, not a formal verifier. Full
  retain/release accounting and formal exception-flow verification remain
  deferred.
- Some dynamic opcodes are intentionally listed through `metadata_gap_kinds`
  rather than claimed as fully checked.
- GIR remains a versioned local VM cache format, not a long-term portable
  bytecode contract.

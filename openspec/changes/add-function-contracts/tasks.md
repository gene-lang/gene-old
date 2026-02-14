## 1. Implementation
- [x] 1.1 Add contract metadata fields to function runtime types and parse `^pre`/`^post` in function construction.
- [x] 1.2 Add compiler support to emit precondition checks at function entry.
- [x] 1.3 Add compiler support to emit postcondition checks for explicit `return` and implicit function-end returns, binding `result`.
- [x] 1.4 Add runtime helper functions for contract gating/violations with detailed diagnostics.
- [x] 1.5 Add `--contracts=on|off` to `gene run` and `gene eval` and store setting on VM.
- [x] 1.6 Ensure method/constructor lowering preserves function properties needed for contracts.
- [x] 1.7 Add tests under `testsuite/contracts/` and wire category into `testsuite/run_tests.sh`.

## 2. Validation
- [x] 2.1 Run targeted compile/runtime tests for contracts.
- [x] 2.2 Run `./testsuite/run_tests.sh`.
- [x] 2.3 Run `openspec validate add-function-contracts --strict`.

## Why

Gene needs first-class function contracts to support AI-first correctness workflows. Preconditions and postconditions should be declarative metadata on functions/methods and enforceable at runtime with clear diagnostics.

## What Changes

- Add `^pre` and `^post` function contract properties.
- Enforce contracts at runtime for both regular functions and methods.
- Introduce `--contracts=on|off` on `gene run` and `gene eval` with VM-level control.
- Emit `ContractViolation` runtime errors with function name, failed condition index, condition text, and argument snapshot.
- Add contract-focused tests under `testsuite/contracts/` and wire them into the testsuite runner.

## Impact

- Affected specs: `function-contracts`
- Affected code:
  - `src/gene/types/type_defs.nim`
  - `src/gene/types/core/functions.nim`
  - `src/gene/compiler.nim`
  - `src/gene/compiler/functions.nim`
  - `src/gene/stdlib.nim`
  - `src/commands/run.nim`
  - `src/commands/eval.nim`
  - `testsuite/run_tests.sh`
  - `testsuite/contracts/*.gene`

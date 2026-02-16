## Why

Gene function documentation should be executable, not only descriptive. A first-class `^examples` property on `fn` definitions plus a dedicated `gene run-examples` command enables quick behavior checks and CI validation directly from source examples.

## What Changes

- Add `^examples` function property syntax for example cases:
  - `[args...] -> expected_result`
  - `[args...] -> _`
  - `[args...] throws ExceptionType`
- Add `^intent` function property syntax for human-readable intent/docstring metadata on both `fn` and `method` definitions.
- Define `_` as wildcard success (any non-exception return is acceptable).
- Add `gene run-examples <file.gene>` command that:
  - loads a file,
  - discovers functions with `^examples`,
  - executes all examples after compilation of the file,
  - reports pass/fail with summary and non-zero exit on failures.
- Standardize error reporting format for failed examples and spec/syntax errors.
- Expose runtime access to function metadata (`function_intent`, `function_examples`) and class method intent (`Class.method_intent`).

## Impact

- Affected specs: `function-examples`
- Affected code (expected):
  - `src/gene/types/type_defs.nim`
  - `src/gene/types/core/functions.nim`
  - `src/gene/vm/exec.nim`
  - `src/commands/` (new `run_examples.nim` or equivalent)
  - `src/gene.nim` command dispatch
  - `testsuite/` for example-runner coverage

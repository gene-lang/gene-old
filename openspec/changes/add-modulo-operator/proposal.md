## Why

Gene supports `+`, `-`, `*`, and `/` but lacks `%` modulo, which limits arithmetic expressiveness and parity with common language operator sets.

## What Changes

- Add `%` arithmetic operator for `Int` and `Float` values.
- Add `%=` compound assignment support.
- Add bytecode instructions `IkMod` and `IkVarModValue` with compiler and VM execution support.
- Extend native compilation pipeline (HIR + ARM64 + x86_64) to lower modulo operations.
- Add tests for `%` and `%=` and document `%` in `examples/full.gene`.

## Impact

- Affected specs: `operators`
- Affected code:
  - `src/gene/types/type_defs.nim`
  - `src/gene/types/instructions.nim`
  - `src/gene/compiler/operators.nim`
  - `src/gene/compiler/control_flow.nim`
  - `src/gene/type_checker.nim`
  - `src/gene/vm/exec.nim`
  - `src/gene/native/hir.nim`
  - `src/gene/native/bytecode_to_hir.nim`
  - `src/gene/native/arm64_codegen.nim`
  - `src/gene/native/x86_64_codegen.nim`
  - `src/gene/native/runtime.nim`
  - `testsuite/operators/7_modulo.gene`
  - `examples/full.gene`

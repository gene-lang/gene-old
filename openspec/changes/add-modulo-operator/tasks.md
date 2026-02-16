## 1. Implementation
- [x] 1.1 Add `IkMod` and `IkVarModValue` instruction kinds and instruction-string rendering support.
- [x] 1.2 Compile `%` expressions and `%=` assignments in compiler operator/assignment paths.
- [x] 1.3 Add VM execution support for `IkMod` and `IkVarModValue` (int modulo, float modulo).
- [x] 1.4 Extend type checker/operator recognition for `%` and `%=`.
- [x] 1.5 Extend native HIR and bytecode lowering with modulo ops.
- [x] 1.6 Implement ARM64 and x86_64 native codegen for integer and float modulo.
- [x] 1.7 Update native runtime HIR validation allowlist for modulo ops.
- [x] 1.8 Add operator tests and update `examples/full.gene` arithmetic section.

## 2. Validation
- [x] 2.1 Run `PATH=$HOME/.nimble/bin:$PATH nimble build`.
- [x] 2.2 Run `./testsuite/run_tests.sh`.
- [x] 2.3 Run `openspec validate add-modulo-operator --strict`.

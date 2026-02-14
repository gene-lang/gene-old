## 1. OpenSpec
- [x] 1.1 Define requirements for native method type metadata and type-checker integration.
- [x] 1.2 Validate change with `openspec validate add-native-method-type-metadata --strict`.

## 2. Implementation
- [x] 2.1 Extend `Method` with native parameter/return type metadata fields.
- [x] 2.2 Add typed `def_native_method` overload and wire default overload to it.
- [x] 2.3 Update type checker to use native metadata when checking known-class method calls.
- [x] 2.4 Annotate key stdlib native methods (String/Array/Map/Int/Float).
- [x] 2.5 Add tests in `testsuite/types/9_native_types.gene`.

## 3. Validation
- [x] 3.1 Run `PATH=$HOME/.nimble/bin:$PATH nimble build`.
- [x] 3.2 Run `./testsuite/run_tests.sh`.

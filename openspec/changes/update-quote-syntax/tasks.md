## 1. Implementation
- [x] 1.1 Update parser macro table to use backtick for quote and remove `:` as a macro.
- [x] 1.2 Ensure tokenization treats `:` as a normal constituent (no quote expansion).
- [x] 1.3 Update syntax highlighting / editor grammar for quote prefix.

## 2. Tests
- [x] 2.1 Update testsuite and examples to use backtick quote syntax.
- [x] 2.2 Add/adjust tests to assert `:a` parses as a symbol named `:a`.
- [x] 2.3 Run `./testsuite/run_tests.sh`.

## 3. Docs
- [x] 3.1 Update docs to describe backtick quote and colon symbols.
- [x] 3.2 Add a migration note for `:(...)` → ``(...).`

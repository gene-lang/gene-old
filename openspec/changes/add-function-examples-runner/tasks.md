## 1. Implementation
- [x] 1.1 Add `^examples` metadata support on function definitions and store it in function runtime metadata.
- [x] 1.2 Parse and validate example clauses for supported forms (`->`, `throws`, wildcard `_`).
- [x] 1.3 Implement example execution engine that invokes target functions with example args and checks expected outcomes.
- [x] 1.4 Implement `gene run-examples <file.gene>` command and wire command dispatch.
- [x] 1.5 Implement standardized error reporting and summary output format.
- [x] 1.6 Add tests for happy path, wildcard `_`, expected-throws, wrong-return, wrong-throw, and invalid example syntax.
- [x] 1.7 Add `^intent` metadata support for functions/methods and runtime retrieval helpers.

## 2. Validation
- [x] 2.1 Run targeted example-runner tests.
- [x] 2.2 Run `./testsuite/run_tests.sh`.
- [x] 2.3 Run `openspec validate add-function-examples-runner --strict`.

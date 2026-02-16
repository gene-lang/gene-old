## ADDED Requirements

### Requirement: Function Example Metadata
The language SHALL support a `^examples` property on `fn` definitions for executable examples.

#### Scenario: Result expectation example
- **WHEN** a function defines an example entry in the form `[args...] -> expected_result`
- **THEN** the runtime treats it as a test case expecting the function call to return a value equal to `expected_result`

#### Scenario: Throws expectation example
- **WHEN** a function defines an example entry in the form `[args...] throws ExceptionType`
- **THEN** the runtime treats it as a test case expecting the function call to raise `ExceptionType` (or subtype)

### Requirement: Function Intent Metadata
The language SHALL support a `^intent` property on `fn` and `method` definitions for runtime intent/docstring metadata.

#### Scenario: Function intent stored
- **WHEN** a function defines `^intent "some description"`
- **THEN** the runtime stores the intent string on the function metadata

#### Scenario: Method intent stored
- **WHEN** a class method defines `^intent "some description"`
- **THEN** the lowered method function carries the same intent metadata and it is retrievable at runtime

### Requirement: Wildcard Return Expectation
The wildcard `_` SHALL represent "any successful return value" in examples.

#### Scenario: Wildcard return passes
- **WHEN** an example is `[args...] -> _` and function execution returns normally
- **THEN** the example passes regardless of the returned value

#### Scenario: Wildcard return fails on exception
- **WHEN** an example is `[args...] -> _` and function execution throws
- **THEN** the example fails

### Requirement: Run Examples Command
The CLI SHALL provide a command to execute function examples in a source file.

#### Scenario: Execute examples from file
- **WHEN** user runs `gene run-examples <file.gene>`
- **THEN** the command loads the file, discovers all functions with `^examples`, executes each example, and prints pass/fail plus summary

#### Scenario: Non-zero exit on failures
- **WHEN** one or more examples fail
- **THEN** `gene run-examples` exits with a non-zero status

### Requirement: Example Error Reporting
The command SHALL emit structured failure output with enough detail to identify the failing case.

#### Scenario: Result mismatch reporting
- **WHEN** an example expected return value differs from actual return value
- **THEN** output includes function name, example index, source location, expected outcome, and actual outcome

#### Scenario: Throws mismatch reporting
- **WHEN** an example expects `throws ExceptionType` but function returns normally or throws a different type
- **THEN** output includes function name, example index, source location, expected thrown type, and actual outcome

#### Scenario: Invalid examples syntax reporting
- **WHEN** `^examples` contains malformed entries
- **THEN** command reports a spec/syntax error with function context and source location and exits non-zero

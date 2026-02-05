## ADDED Requirements

### Requirement: Declare Effects In Function Signatures
The system SHALL support effect lists in function declarations using the `! [Effect ...]` clause after the return type.

#### Scenario: Declared effects on a function
- **WHEN** a function is declared with `! [Db Http]`
- **THEN** the type checker records `Db` and `Http` as the function's effects

### Requirement: Represent Effects In Function Type Expressions
The system SHALL parse effect lists inside `Fn` type expressions written as `(Fn [Args] Return ! [Effects])`.

#### Scenario: Effectful function type in an annotation
- **WHEN** a parameter is annotated with `(Fn [Int] Int ! [Db])`
- **THEN** the parameter's type includes the `Db` effect

### Requirement: Enforce Effect Boundaries
The system SHALL reject calls to effectful functions from contexts that do not declare the required effects.

#### Scenario: Pure caller invokes effectful callee
- **GIVEN** a function with no `!` clause (pure)
- **WHEN** it calls a function declared with `! [Db]`
- **THEN** the type checker reports an effect error

#### Scenario: Effectful caller invokes effectful callee
- **GIVEN** a function declared with `! [Db Http]`
- **WHEN** it calls a function declared with `! [Db]`
- **THEN** the call is accepted

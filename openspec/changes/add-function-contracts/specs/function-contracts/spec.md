## ADDED Requirements

### Requirement: Function Preconditions
The runtime SHALL support function preconditions declared with `^pre` as an array of expressions.

#### Scenario: Preconditions pass
- **WHEN** all `^pre` expressions evaluate truthy
- **THEN** function execution continues normally

#### Scenario: Preconditions fail
- **WHEN** any `^pre` expression evaluates falsey
- **THEN** runtime raises a `ContractViolation` including function name, failed precondition index, condition text, and argument values

### Requirement: Function Postconditions
The runtime SHALL support function postconditions declared with `^post` as an array of expressions.

#### Scenario: Postconditions pass
- **WHEN** all `^post` expressions evaluate truthy with `result` bound to return value
- **THEN** function returns normally

#### Scenario: Postconditions fail
- **WHEN** any `^post` expression evaluates falsey
- **THEN** runtime raises a `ContractViolation` including function name, failed postcondition index, condition text, argument values, and result value

### Requirement: Runtime Contract Mode
The CLI SHALL expose contract runtime mode controls for execution commands.

#### Scenario: Contracts enabled (default)
- **WHEN** running `gene run` or `gene eval` without explicit contracts override
- **THEN** contracts are checked at runtime

#### Scenario: Contracts disabled
- **WHEN** running `gene run --contracts=off` or `gene eval --contracts=off`
- **THEN** pre/post contract checks are skipped

### Requirement: Contracts Apply To Methods
Contract support SHALL apply uniformly to methods lowered to function callables.

#### Scenario: Method contract violation
- **WHEN** a method declares `^pre` or `^post` and a condition fails
- **THEN** runtime raises `ContractViolation` with method/function context and diagnostics

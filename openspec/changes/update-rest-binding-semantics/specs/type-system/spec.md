## ADDED Requirements

### Requirement: Positional Rest Parameters Preserve Their Position
The type system SHALL preserve the position of a positional rest parameter instead of assuming the rest parameter is always the last positional parameter.

#### Scenario: Fixed suffix parameter is type-checked against the trailing argument
- **GIVEN** a function with parameters `[head: Int rest... tail: Bool]`
- **WHEN** the function is called with `1 2 3 true`
- **THEN** `head` is validated against the first argument
- **AND** `tail` is validated against the final argument
- **AND** the middle arguments are assigned to `rest`

#### Scenario: Trailing fixed parameter is not swallowed by rest typing
- **GIVEN** a function with parameters `[head: Int rest... tail: Bool]`
- **WHEN** the function is called with `1 2 3 4`
- **THEN** type checking fails because the trailing fixed parameter expects `Bool`

### Requirement: Typed Rest Payload Checking
When a positional rest parameter is annotated as an array type, the type checker SHALL validate each consumed middle argument against the array element type.

#### Scenario: Typed rest accepts matching middle arguments
- **GIVEN** a function with parameters `[head: Int nums...: (Array Int) tail: Bool]`
- **WHEN** the function is called with `1 2 3 true`
- **THEN** type checking succeeds because the rest payload elements are all `Int`

#### Scenario: Typed rest rejects mismatched middle arguments
- **GIVEN** a function with parameters `[head: Int nums...: (Array Int) tail: Bool]`
- **WHEN** the function is called with `1 2 "x" true`
- **THEN** type checking fails because the rest payload contains a non-`Int` value

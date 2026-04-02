## ADDED Requirements

### Requirement: Positional Rest Binding
Argument matchers and destructuring patterns SHALL allow exactly one named positional rest binder. The spellings `name...` and `name ...` SHALL be equivalent in matcher contexts.

#### Scenario: Standalone postfix rest token applies to the preceding binder
- **WHEN** a function uses the parameter list `[items ... tail]` and is called with `1 2 3 4`
- **THEN** `items` is bound to `[1 2 3]`
- **AND** `tail` is bound to `4`

#### Scenario: Non-tail rest binder captures the middle of a destructuring input
- **WHEN** `(var [first middle... last] [1 2 3 4])` executes
- **THEN** `first` is bound to `1`
- **AND** `middle` is bound to `[2 3]`
- **AND** `last` is bound to `4`

### Requirement: Invalid Positional Rest Declarations
Matcher contexts SHALL reject anonymous positional rest tokens and multiple positional rest binders.

#### Scenario: Bare rest token is rejected
- **WHEN** a function parameter list contains `[a ... ...]` or a destructuring pattern contains `[... tail]`
- **THEN** compilation fails with a diagnostic explaining that positional rest must be named and unique

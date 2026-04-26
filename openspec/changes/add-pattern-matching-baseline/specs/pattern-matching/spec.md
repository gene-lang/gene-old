## ADDED Requirements
### Requirement: Argument Matching Baseline
Argument pattern binding SHALL reuse the current binding context, allow shadowing where the existing binder permits it, and SHALL NOT construct an aggregate object of all arguments just to bind parameters.

#### Scenario: Bind two args without aggregate argument object
- **GIVEN** a function `(fn f [a b] ...)`
- **WHEN** `f` is invoked with two positional arguments
- **THEN** `a` and `b` are bound through the argument matcher
- **AND** no aggregate argument object is constructed during binding

### Requirement: Existing Destructuring Baseline
The public Beta pattern-matching baseline SHALL use existing `var` destructuring for binding and `case/when` for branching. The standalone `(match ...)` expression SHALL remain outside the Beta subset and MUST be rejected with a diagnostic that points users to `(var pattern value)` or `(case ...)`.

#### Scenario: Destructure array with var
- **WHEN** `(var [a b] [1 2])` executes
- **THEN** `a` is bound to `1`
- **AND** `b` is bound to `2`

#### Scenario: Removed match expression guides users to supported forms
- **WHEN** `(match [a b] [1 2])` is compiled
- **THEN** compilation fails with a diagnostic explaining that `match has been removed`
- **AND** the diagnostic points users to `(var pattern value)` for binding or `(case ...)` for branching

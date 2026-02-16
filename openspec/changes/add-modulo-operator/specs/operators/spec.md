## ADDED Requirements

### Requirement: Modulo Operator
The language SHALL support `%` as an arithmetic operator on numeric operands.

#### Scenario: Integer modulo
- **WHEN** evaluating `(10 % 3)`
- **THEN** the result is `1`

#### Scenario: Float modulo
- **WHEN** evaluating `(10.0 % 3.0)`
- **THEN** the result is `1.0`

### Requirement: Modulo Compound Assignment
The language SHALL support `%=` compound assignment on assignable values.

#### Scenario: Variable modulo assignment
- **WHEN** evaluating `(var x 10)` then `(x %= 3)`
- **THEN** `x` becomes `1`

### Requirement: Native Lowering for Modulo
Native compilation SHALL lower modulo bytecode instructions for supported numeric types.

#### Scenario: Native integer modulo
- **WHEN** a native-eligible typed function contains integer `%`
- **THEN** native code executes integer modulo without VM fallback for the arithmetic operation

#### Scenario: Native float modulo
- **WHEN** a native-eligible typed function contains float `%`
- **THEN** native code executes float modulo and preserves runtime semantics

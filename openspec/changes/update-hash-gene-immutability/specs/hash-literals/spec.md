## ADDED Requirements

### Requirement: Hash-Paren Literals Create Immutable Genes
The system SHALL interpret `#(...)` syntax as immutable gene literal values rather than executable call forms.

#### Scenario: Immutable gene with type, props, and children
- **WHEN** a program evaluates `#(f ^a 1 2)`
- **THEN** it produces a gene value with type `f`
- **AND** prop `a` set to `1`
- **AND** child `2`
- **AND** the gene is marked immutable

#### Scenario: Empty immutable gene
- **WHEN** a program evaluates `#()`
- **THEN** it produces an empty gene value
- **AND** the gene is marked immutable

### Requirement: Immutable Genes Reject Structural Mutation
Immutable genes MUST reject operations that would mutate their type, props, or children.

#### Scenario: Gene.set is rejected
- **WHEN** a program evaluates `(do (var g #(f ^a 1 2)) (g .set "a" 3))`
- **THEN** execution fails with a clear runtime error indicating the gene is immutable

#### Scenario: Property assignment is rejected
- **WHEN** a program evaluates `(do (var g #(f ^a 1 2)) (g/a = 3))`
- **THEN** execution fails with a clear runtime error indicating the gene is immutable

#### Scenario: Child assignment is rejected
- **WHEN** a program evaluates `(do (var g #(f 1 2)) (g/0 = 3))`
- **THEN** execution fails with a clear runtime error indicating the gene is immutable

#### Scenario: Gene.add_child is rejected
- **WHEN** a program evaluates `(do (var g #(f 1 2)) (g .add_child 3))`
- **THEN** execution fails with a clear runtime error indicating the gene is immutable

### Requirement: Immutable Genes Remain Readable and Observable
Immutable genes SHALL behave like normal genes for read operations and SHALL expose their frozen state.

#### Scenario: Reads and predicate succeed
- **WHEN** a program evaluates `(do (var g #(f ^a 1 2)) [g/a (g .get_child 0) (g .immutable?)])`
- **THEN** it reads `1` and `2` successfully
- **AND** `immutable?` returns `true`

#### Scenario: immutable? distinguishes frozen and mutable genes
- **WHEN** a program evaluates `[(#(f) .immutable?) ((_ f) .immutable?)]`
- **THEN** the first result is `true`
- **AND** the second result is `false`

### Requirement: Hash-Paren Literals Do Not Change String Interpolation
The system SHALL keep `#"` string interpolation behavior unchanged while adding top-level `#(...)` literals.

#### Scenario: Interpolated string gene syntax still parses
- **WHEN** the parser reads `#"a#(b)c"`
- **THEN** it produces the existing string interpolation representation
- **AND** it does not parse the embedded `#(b)` as a top-level immutable gene literal

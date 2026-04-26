## ADDED Requirements

### Requirement: Canonical Enum ADT Declaration
The language SHALL use `enum` as the canonical public declaration form for both simple enumerations and payload-bearing algebraic data types.

#### Scenario: Generic enum declaration canonicalizes the base name
- **WHEN** source declares `(enum Result:T:E (Ok value: T) (Err error: E) Empty)`
- **THEN** the declaration registers the enum under the canonical name `Result`
- **AND** type positions may refer to the generic application as `(Result Int String)`

#### Scenario: Legacy ADT declaration is not the public model
- **WHEN** public documentation describes sum-type declarations
- **THEN** it presents `enum` as the supported ADT declaration syntax
- **AND** it does not present `(type (Result T E) ...)` as an alternate supported public declaration form

### Requirement: Enum Variant Metadata
Enum declarations SHALL record each variant as either a unit variant or a payload variant, and payload variants SHALL preserve ordered field metadata.

#### Scenario: Payload variant records ordered fields
- **WHEN** source declares `(enum Shape (Circle radius) (Rect width height) Point)`
- **THEN** `Circle` records the single field `radius`
- **AND** `Rect` records the ordered fields `width` and `height`
- **AND** `Point` records no payload fields

#### Scenario: Payload field annotation records type metadata
- **WHEN** source declares `(enum Result:T:E (Ok value: T) (Err error: E))`
- **THEN** the `Ok` member records field name `value` with its resolved type descriptor when available
- **AND** the `Err` member records field name `error` with its resolved type descriptor when available

### Requirement: Enum Declaration Diagnostics
Malformed enum declarations SHALL fail with diagnostics that identify the declaration category that failed.

#### Scenario: Invalid enum declarations report targeted categories
- **WHEN** source contains a malformed enum head, duplicate variant, duplicate field, invalid generic parameter, or invalid field annotation
- **THEN** compilation fails
- **AND** the diagnostic identifies the relevant enum declaration category rather than surfacing an unrelated low-level runtime error

### Requirement: Staged Enum ADT Semantics
The declaration contract SHALL distinguish delivered declaration metadata from downstream constructor, matching, migration, and identity semantics.

#### Scenario: Constructor enforcement is downstream from declaration metadata
- **WHEN** documentation describes the S01 enum ADT declaration boundary
- **THEN** it states that constructor arity, keyword behavior, and annotated field type enforcement are downstream work
- **AND** it states that the declaration slice provides the metadata those behaviors consume

#### Scenario: Pattern matching and Result/Option migration are downstream
- **WHEN** documentation describes enum ADT pattern matching or Result/Option behavior
- **THEN** it identifies enum metadata as the intended source of truth
- **AND** it does not describe hardcoded `Ok`, `Err`, `Some`, or `None` Gene-expression matching as the stable ADT model

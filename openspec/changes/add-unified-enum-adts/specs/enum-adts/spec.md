## ADDED Requirements

### Requirement: Canonical Enum ADT Declaration
The language SHALL use `enum` as the canonical public declaration form for both simple enumerations and payload-bearing algebraic data types.

#### Scenario: Generic enum declaration canonicalizes the base name
- **WHEN** source declares `(enum Result:T:E (Ok value: T) (Err error: E) Empty)`
- **THEN** the declaration registers the enum under the canonical name `Result`
- **AND** type positions may refer to the generic application as `(Result Int String)`

#### Scenario: Simple enums are unit-variant enum ADTs
- **WHEN** source declares `(enum Color red green blue)` or `(enum Status ^values [ready done])`
- **THEN** each declared member is registered as an ordered unit variant of the parent enum
- **AND** each member carries the nominal identity of that enum declaration

#### Scenario: Legacy ADT declaration is not the public model
- **WHEN** public documentation describes sum-type declarations
- **THEN** it presents `enum` as the supported ADT declaration syntax
- **AND** it does not present `(type (Result T E) ...)` as an alternate supported public declaration form

### Requirement: Enum Variant Metadata and Constructors
Enum declarations SHALL record each variant as either a unit variant or a payload variant, and constructor behavior SHALL use the recorded metadata.

#### Scenario: Payload variant records ordered fields
- **WHEN** source declares `(enum Shape (Circle radius) (Rect width height) Point)`
- **THEN** `Circle` records the single field `radius`
- **AND** `Rect` records the ordered fields `width` and `height`
- **AND** `Point` records no payload fields

#### Scenario: Payload field annotation records type metadata
- **WHEN** source declares `(enum Result:T:E (Ok value: T) (Err error: E))`
- **THEN** the `Ok` member records field name `value` with its resolved type descriptor when available
- **AND** the `Err` member records field name `error` with its resolved type descriptor when available

#### Scenario: Positional and keyword constructors use declaration metadata
- **WHEN** source constructs `(Shape/Rect 10 20)` or `(Shape/Rect ^width 10 ^height 20)`
- **THEN** the resulting enum value stores payloads in declaration order
- **AND** field access by declared field name returns the corresponding payload

#### Scenario: Constructors reject invalid payload calls
- **WHEN** a payload constructor receives the wrong arity, mixed positional and keyword arguments, missing keyword fields, unknown keyword fields, duplicate keyword fields, or values that violate concrete field annotations
- **THEN** construction fails with a targeted diagnostic

### Requirement: Built-in Result, Option, and Question Operator
Built-in `Result`, `Option`, and the `?` operator SHALL be backed by canonical enum identities.

#### Scenario: Built-in variants construct enum values
- **WHEN** source evaluates `(Ok 42)`, `(Err "boom")`, `(Some "value")`, or `None`
- **THEN** the values are enum values or unit variants belonging to the built-in `Result` or `Option` enum declarations
- **AND** `typeof` reports the parent enum name

#### Scenario: Question operator uses built-in enum identity
- **WHEN** `?` receives built-in `Ok` or `Some`
- **THEN** it unwraps the payload
- **WHEN** `?` receives built-in `Err` or `None`
- **THEN** it returns early with that enum value
- **AND** same-named variants from user-defined enums do not receive built-in shortcut behavior by name alone

### Requirement: Enum Variant Case Patterns
The language SHALL support enum ADT matching through `case` and `when` patterns using enum metadata.

#### Scenario: Qualified payload pattern binds declaration-order fields
- **WHEN** source matches `(Shape/Rect 10 20)` with `when (Shape/Rect width height)`
- **THEN** `width` is bound to `10`
- **AND** `height` is bound to `20`

#### Scenario: Unit and bare variants resolve by enum identity
- **WHEN** a `case` pattern names `Shape/Point` or an unambiguous bare `Point`
- **THEN** it matches the unit variant with the same enum identity
- **AND** ambiguous bare variants require qualification

#### Scenario: Enum pattern diagnostics are targeted
- **WHEN** an enum pattern names an unknown enum, unknown variant, ambiguous bare variant, non-symbol payload binder, or wrong number of payload binders
- **THEN** checking fails with a diagnostic for that enum pattern category

#### Scenario: Exhaustiveness is checked for statically known enum cases
- **WHEN** a `case` over a statically known enum value omits `else` and wildcard handling
- **THEN** the checker verifies that every declared variant is covered
- **AND** missing variants are reported in declaration order

### Requirement: Nominal Enum Identity Persistence
Enum values SHALL preserve nominal identity across module, cache, and serialization boundaries; display strings SHALL NOT define identity.

#### Scenario: Imported enum value keeps declaration identity
- **WHEN** an enum value is constructed in one module and consumed through an import
- **THEN** type boundaries and enum pattern matching use the original enum declaration identity
- **AND** same printed variant names from different declarations remain distinct

#### Scenario: GIR cache preserves enum identity
- **WHEN** code using enum ADTs is compiled, cached, and loaded from GIR artifacts
- **THEN** enum type checks and enum pattern matches behave the same as source execution

#### Scenario: Runtime and tree serialization preserve enum identity
- **WHEN** enum values are serialized and deserialized through runtime serialization or tree serialization/hash paths
- **THEN** the restored values retain the parent enum identity and variant identity required for equality, type checks, and patterns

### Requirement: Legacy ADT Migration Boundary
Legacy Gene-expression ADT declarations and quoted legacy Result/Option-shaped values SHALL be treated as migration cases, not as supported enum ADT values.

#### Scenario: Legacy type ADT declaration is rejected
- **WHEN** source declares a legacy ADT shape such as `(type (Result T E) (Ok T) (Err E))`
- **THEN** the checker reports a migration diagnostic that directs users to `enum Result:T:E`

#### Scenario: Quoted legacy Result or Option shape does not satisfy enum boundaries
- **WHEN** a quoted Gene value has the same printed shape as `Ok`, `Err`, `Some`, or `None`
- **THEN** it is not treated as a built-in enum value
- **AND** enum type boundaries and enum case patterns reject it or fail to match it as an enum ADT value

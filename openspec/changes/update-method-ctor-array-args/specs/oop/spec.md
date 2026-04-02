## MODIFIED Requirements
### Requirement: Methods And Constructors Use Function-Style Argument Lists
The system SHALL require methods and constructors to use array argument lists, matching function definitions.

#### Scenario: Zero-argument method uses empty array
- **WHEN** a class defines `(method get [] /value)`
- **THEN** the method compiles successfully
- **AND** the method is callable without explicit arguments beyond the implicit receiver

#### Scenario: Zero-argument constructor uses empty array
- **WHEN** a class defines `(ctor [] (/ready = true))`
- **THEN** the constructor compiles successfully
- **AND** `(new ClassName)` invokes it normally

#### Scenario: Legacy underscore method syntax is rejected
- **WHEN** code defines `(method get _ /value)`
- **THEN** compilation fails with an error explaining that methods require an array argument list

#### Scenario: Legacy underscore constructor syntax is rejected
- **WHEN** code defines `(ctor _ (/ready = true))`
- **THEN** compilation fails with an error explaining that constructors require an array argument list

#### Scenario: Scalar method argument syntax is rejected
- **WHEN** code defines `(method echo value value)`
- **THEN** compilation fails with an error explaining that methods require an array argument list

#### Scenario: Scalar constructor argument syntax is rejected
- **WHEN** code defines `(ctor value (/value = value))`
- **THEN** compilation fails with an error explaining that constructors require an array argument list

#### Scenario: External adapter methods use array argument lists
- **WHEN** an external implementation defines `(method read [] (/_genevalue .get_data))`
- **THEN** the method compiles successfully
- **AND** adapter dispatch behaves the same as before

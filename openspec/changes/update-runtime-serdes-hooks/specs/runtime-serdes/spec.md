## ADDED Requirements

### Requirement: Non-Instance Runtime Serdes Remains Native And Canonical

The system SHALL keep the existing native `gene/serdes` path as the canonical
serialization mechanism for values other than anonymous instances and custom
runtime values.

#### Scenario: primitives and structural values bypass class serdes hooks

- **WHEN** `gene/serdes/serialize` serializes a primitive, array, map, Gene
  value, or typed reference
- **THEN** it SHALL use the native runtime serializer for that value kind
- **AND** it SHALL NOT require or invoke class `serialize` methods for those
  values

### Requirement: Anonymous Instances Are Rejected By Runtime Serdes

Anonymous user-defined instances or object-like runtime values SHALL not be
part of the supported runtime serdes surface.

#### Scenario: serializing an anonymous instance is rejected

- **WHEN** `gene/serdes/serialize` serializes an instance or object-like value
  without a canonical module/path identity
- **THEN** it SHALL reject the operation rather than serialize an inline
  snapshot payload

#### Scenario: deserializing a legacy anonymous-instance envelope is rejected

- **WHEN** `gene/serdes/deserialize` reads a legacy inline anonymous-instance
  envelope
- **THEN** it SHALL reject that payload rather than reconstruct an instance

### Requirement: Named Instances Preserve Reference Semantics

Named or exported instances with canonical origins SHALL continue to serialize
as references rather than snapshots.

#### Scenario: named instance remains `InstanceRef`

- **WHEN** `gene/serdes/serialize` serializes an instance with a canonical
  module/path origin
- **THEN** it SHALL emit `InstanceRef`
- **AND** it SHALL NOT use inline anonymous-instance payload serialization

### Requirement: Custom Runtime Values Round-Trip Through Explicit Hooks

Custom runtime values SHALL round-trip through `gene/serdes` only through
explicit class-controlled hooks.

#### Scenario: custom value serializes through class payload hooks

- **WHEN** `gene/serdes/serialize` serializes a `VkCustom` value whose class
  defines `serialize` or `.serialize`
- **AND** whose class also defines `deserialize` or `.deserialize`
- **THEN** it SHALL emit the `Instance` envelope shape carrying a class
  reference and the hook-produced payload
- **AND** `gene/serdes/deserialize` of that envelope SHALL call the class
  `deserialize` or `.deserialize` hook with the deserialized payload

#### Scenario: custom value without required hooks is rejected

- **WHEN** `gene/serdes` is asked to serialize or deserialize a custom runtime
  value form without the required class hooks
- **THEN** it SHALL reject the operation rather than attempt a generic fallback
- **AND** both `serialize`/`.serialize` and `deserialize`/`.deserialize` SHALL
  be treated as required for the round-trip contract

### Requirement: Serdes Hooks Exchange Values, Not Final Text

Class serdes hooks SHALL operate on ordinary Gene values rather than on raw
`(gene/serialization ...)` strings.

#### Scenario: serialize hook returns a payload value

- **WHEN** a serdes hook returns a Gene value payload
- **THEN** `gene/serdes` SHALL serialize that payload using the canonical
  runtime serializer
- **AND** deserialize hooks SHALL receive the reconstructed payload value

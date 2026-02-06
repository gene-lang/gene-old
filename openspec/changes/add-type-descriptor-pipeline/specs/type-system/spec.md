## ADDED Requirements

### Requirement: Canonical Type Descriptors
The type system SHALL provide canonical type descriptors with stable IDs for compile-time and serialized metadata.

#### Scenario: Descriptor IDs identify equivalent types
- **WHEN** the compiler encounters repeated equivalent type expressions in one compilation unit
- **THEN** metadata references a stable descriptor ID rather than duplicating string-only identity

### Requirement: GIR Descriptor Persistence
GIR files SHALL persist type descriptor tables and restore them when loaded.

#### Scenario: Descriptor table roundtrip
- **WHEN** a compilation unit with a descriptor table is saved to GIR and loaded back
- **THEN** descriptor entries and their IDs are preserved

### Requirement: Gradual-Compatible Migration
Descriptor-based typing SHALL coexist with existing string-based metadata during migration.

#### Scenario: Backward-compatible runtime validation
- **WHEN** runtime metadata contains descriptor IDs or legacy type strings
- **THEN** validation succeeds using descriptor-backed logic when available and string fallback otherwise

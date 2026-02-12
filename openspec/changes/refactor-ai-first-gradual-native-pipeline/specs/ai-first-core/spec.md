## ADDED Requirements

### Requirement: Descriptor-First Type Identity
The compiler and runtime SHALL use canonical descriptor identities (`TypeDesc`/`TypeId`) for type metadata across type checking, bytecode metadata, GIR, and runtime validation.

#### Scenario: Descriptor identity preserved through cache
- **WHEN** a module with typed declarations is compiled, cached to GIR, and loaded again
- **THEN** all type validations and compatibility checks use descriptor identities without reparsing type strings

### Requirement: Gradual Typing Compatibility
The language SHALL remain gradual-first by default, where unannotated code executes with dynamic semantics while annotated boundaries are validated.

#### Scenario: Mixed typed and untyped modules
- **WHEN** a typed module calls an untyped module and vice versa
- **THEN** execution remains valid, and typed boundaries enforce declared constraints with clear diagnostics on mismatch

### Requirement: GIR Cache Compatibility Policy
The system SHALL treat GIR as a cache and invalidate incompatible cached artifacts when descriptor metadata format versions change.

#### Scenario: Legacy GIR cache invalidated
- **WHEN** the runtime encounters a GIR artifact with an older incompatible type-metadata version
- **THEN** it rejects that artifact and recompiles from source instead of attempting transparent migration

### Requirement: Descriptor Serialization Safety
Descriptor serialization and deserialization SHALL preserve symbol-table integrity and SHALL NOT produce out-of-range symbol lookups at runtime.

#### Scenario: Cached execution does not corrupt symbol lookup
- **WHEN** a typed program is compiled to GIR and executed from cache
- **THEN** runtime symbol resolution does not access symbol indices outside valid bounds

### Requirement: Typed Machine-Readable Diagnostics
The runtime and compile-time type validation paths SHALL emit diagnostics with stable machine-readable error codes and structured type context.

#### Scenario: Type mismatch diagnostic payload
- **WHEN** type validation fails at compile time or runtime
- **THEN** the diagnostic includes stable code, expected type, actual type, and source location context

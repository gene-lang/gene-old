## ADDED Requirements

### Requirement: `gene deser|deserialize` Uses The Runtime Serdes Contract

The `gene deser` command and its `deserialize` alias SHALL expose the same
runtime deserialization behavior as `gene/serdes/deserialize`.

#### Scenario: command honors hook-driven instance and custom payloads

- **WHEN** `gene deser` or `gene deserialize` reads serialized text for a
  hook-driven custom runtime value
- **THEN** it SHALL deserialize that text through the runtime serdes
  implementation
- **AND** it SHALL honor the relevant class `deserialize` or `.deserialize`
  hooks when reconstructing the value

#### Scenario: command rejects anonymous inline instance payloads

- **WHEN** `gene deser` or `gene deserialize` reads a legacy inline anonymous
  instance payload
- **THEN** it SHALL reject that payload using the same runtime serdes rules

### Requirement: `gene deser|deserialize` Help And Docs Reflect Current Serdes Forms

The command help text, examples, and related documentation SHALL describe the
current runtime serialization format accurately.

#### Scenario: command examples describe typed refs and custom hook payloads

- **WHEN** the project documents `gene deser` or `gene deserialize`
- **THEN** the examples SHALL use the current typed-reference shape with
  `^module` and `^path`
- **AND** the examples/help text SHALL document custom-value hook-driven
  deserialization behavior
- **AND** they SHALL document that anonymous inline instance payloads are not
  supported
- **AND** they SHALL not rely on outdated positional typed-reference examples

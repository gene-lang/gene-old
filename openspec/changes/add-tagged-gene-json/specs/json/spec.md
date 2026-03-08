## ADDED Requirements

### Requirement: Plain JSON Helpers Remain Plain JSON

The system SHALL preserve the existing plain JSON behavior for
`gene/json/parse`, `gene/json/stringify`, and `.to_json`. Tagged Gene JSON
behavior SHALL be opt-in through separate helpers.

#### Scenario: Plain JSON parse still returns a map

- **WHEN** a program evaluates `(gene/json/parse "{\"a\": true}")`
- **THEN** it SHALL return a Gene map whose `a` key is `true`.

#### Scenario: Plain JSON stringify still emits ordinary JSON

- **WHEN** a program evaluates `([1 2].to_json)`
- **THEN** it SHALL return `"[1,2]"`.

### Requirement: Tagged Gene JSON Uses `#GENE#...` Strings

The system SHALL provide tagged Gene JSON helpers that encode and decode
Gene-specific scalar values through JSON strings beginning with `#GENE#`.

#### Scenario: Tagged serialization preserves a symbol

- **WHEN** a program serializes the Gene symbol `a` through the tagged helper
- **THEN** the JSON string SHALL contain `"#GENE#a"`.

#### Scenario: Tagged deserialization parses exactly one Gene value

- **WHEN** a program deserializes the JSON string `"#GENE#1 2"`
- **THEN** the runtime SHALL fail because the tagged payload contains multiple
  Gene values.

### Requirement: Tagged Gene JSON Preserves Literal Strings Starting With `#GENE#`

The system SHALL preserve literal strings beginning with `#GENE#` by encoding
them as tagged Gene string literals rather than treating them as plain tagged
payloads.

#### Scenario: Tagged serialization preserves a literal `#GENE#` string

- **WHEN** a program serializes the Gene string `"#GENE#a"` through the tagged
  helper
- **THEN** the JSON output SHALL encode it as a tagged Gene string literal
- **AND** deserializing that JSON SHALL return the original Gene string.

### Requirement: Tagged Gene JSON Preserves Large Integers

The system SHALL preserve integers outside the JSON safe integer range by
encoding them through tagged Gene literals rather than plain JSON numbers.

#### Scenario: Large integer uses tagged encoding

- **WHEN** a program serializes the integer `9007199254740993`
- **THEN** the tagged JSON output SHALL use a `#GENE#...` string
- **AND** deserializing it SHALL return the same integer value.

### Requirement: Tagged Gene JSON Preserves Gene Nodes

The system SHALL preserve Gene nodes through tagged JSON objects that contain
`genetype`, prop fields, and `children`.

#### Scenario: Gene node serializes to object form

- **WHEN** a program serializes `(f ^a 1 ^b 2 3 4)` through the tagged helper
- **THEN** the JSON object SHALL contain:
  - `genetype` encoded as the Gene type value
  - `a: 1`
  - `b: 2`
  - `children: [3, 4]`

#### Scenario: Tagged object without `children` defaults to empty children

- **WHEN** a tagged Gene JSON object contains `genetype` but omits `children`
- **THEN** deserialization SHALL treat the node children as `[]`.

### Requirement: Tagged JSON Objects Without `genetype` Become Maps

Tagged helper behavior SHALL continue to decode plain JSON objects without a
`genetype` field as Gene maps.

#### Scenario: Object without `genetype` becomes a map

- **WHEN** a program deserializes `{"a": 1, "b": 2}` through the tagged helper
- **THEN** the result SHALL be a Gene map, not a Gene node.

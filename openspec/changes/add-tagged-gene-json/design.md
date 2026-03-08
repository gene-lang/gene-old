## Context

Gene already exposes plain JSON helpers:

- `gene/json/parse`
- `gene/json/stringify`
- `.to_json`

Those helpers are appropriate for ordinary JSON interop, but they do not
preserve Gene-specific values like symbols and Gene nodes across a round trip.

The design note in `docs/json_serialization.md` defines a tagged JSON format
built around a single string prefix, `#GENE#`, whose payload is parsed as one
Gene value.

## Goals

- Preserve plain JSON behavior for existing callers.
- Add an explicit tagged mode for Gene-to-Gene transport through JSON.
- Reuse the Gene parser for tagged scalar payloads instead of inventing many
  type-specific transport tags.
- Preserve symbols, Gene nodes, `#GENE#`-prefixed literal strings, and large
  integers.

## Non-Goals

- Changing ordinary JSON parse/stringify semantics.
- Solving every non-JSON Gene value in v1.
- Solving raw-map `genetype` collisions in tagged mode for v1.
- Adding an explicit format version marker in v1.

## Decisions

### 1. Plain and Tagged Modes Stay Separate

Existing plain JSON helpers remain unchanged.

Tagged mode is added as separate public helpers in the `gene/json` namespace so
callers opt in explicitly.

### 2. `#GENE#...` Means "Parse the Rest as One Gene Value"

Tagged JSON strings are decoded by passing the suffix through the Gene reader.

Contract:

- zero parsed values => error
- more than one parsed value => error
- parse failure => error

### 3. Strings Starting With `#GENE#` Reuse Gene String Syntax

There is no extra transport escape prefix in v1.

Literal strings beginning with `#GENE#` are encoded as tagged Gene string
literals, for example:

```json
"#GENE#\"#GENE#a\""
```

This keeps the meaning of tagged strings uniform.

### 4. Large Integers Use Tagged Literal Encoding

Plain JSON numbers are used only where safe and unsurprising.

Integers outside the JSON safe integer range are encoded through tagged Gene
literals so downstream JSON tooling does not silently lose precision.

### 5. Gene Nodes Use Object Encoding

Tagged Gene nodes are represented as:

- `genetype`
- prop fields
- `children`

`genetype` is recursively encoded through the same tagged JSON rules and is not
restricted to symbols.

### 6. v1 Known Limitations Are Explicit

Known limitations carried by the design:

- objects with raw `genetype` keys are ambiguous in tagged mode and are treated
  as Gene nodes
- prop insertion order is not preserved if deterministic key sorting is used
- there is no explicit version marker in v1

## Risks / Trade-offs

- Reusing the parser is elegant, but tagged decoding must be strict about the
  exactly-one-value rule.
- Keeping plain and tagged modes separate avoids breakage, but adds API
  surface.
- Tagged object encoding is readable, but `genetype` collisions remain a known
  limitation until a wrapper scheme is introduced.

## Migration Plan

1. Add internal tagged encode/decode helpers without changing plain behavior.
2. Expose tagged public helpers under `gene/json`.
3. Add regression tests that prove plain JSON is unchanged.
4. Add tagged round-trip tests for symbols, strings, large ints, maps, and
   Gene nodes.
5. Update docs after behavior is validated.

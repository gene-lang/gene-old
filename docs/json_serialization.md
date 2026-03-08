# Gene <-> JSON Serialization

This document sketches a tagged JSON format for round-tripping Gene values
through JSON while preserving the distinction between plain JSON data and Gene
values that do not map cleanly onto JSON.

It is a design note, not a description of the current implementation.
Current runtime status:

- plain `gene/json/parse`, `gene/json/stringify`, and `.to_json` remain plain
  JSON helpers
- tagged Gene JSON is exposed separately through:
  - `gene/json/serialize`
  - `gene/json/deserialize`

## Core Idea

Use a reserved JSON-string prefix:

```text
#GENE#
```

When a JSON string starts with `#GENE#`, the remainder is passed to the Gene
parser and must decode into exactly one Gene value.

Examples:

```json
"#GENE#nil"
"#GENE#a"
"#GENE#[1 2]"
"#GENE#(f ^a 1 2)"
```

Single-value rule:

- if the suffix parses into exactly one Gene value, use that value
- if it parses into zero values, raise an error
- if it parses into multiple values, raise an error
- if the Gene parse fails, raise an error

This keeps the encoding simple and avoids inventing separate string tags for
symbols, nil, or future literal forms.

## Proposed Mapping

### Scalars

| Gene | JSON | Notes |
| --- | --- | --- |
| `nil` | `null` | direct mapping |
| `true` | `true` | direct mapping |
| `false` | `false` | direct mapping |
| `123` | `123` | direct mapping within JSON safe-integer limits |
| `1.5` | `1.5` | direct mapping |
| `"str"` | `"str"` | normal JSON string |
| `a` | `"#GENE#a"` | symbol encoded through Gene parser |

### Collections

| Gene | JSON | Notes |
| --- | --- | --- |
| `[1 2]` | `[1, 2]` | direct mapping |
| `{^a 1}` | `{"a": 1}` | JSON object becomes Gene map if `genetype` is absent |

### Gene Forms

Gene nodes serialize as JSON objects with:

- `genetype`: the Gene type value, recursively encoded through the same rules
- normal JSON object fields for props
- `children`: JSON array for positional children

Example:

```gene
(f ^a 1 ^b 2 3 4)
```

```json
{
  "genetype": "#GENE#f",
  "a": 1,
  "b": 2,
  "children": [3, 4]
}
```

Important point:

- `genetype` is not limited to symbols
- it may be any Gene value representable by this JSON encoding

## Round-Trip Rules

### Deserialize JSON -> Gene

1. `null` becomes `nil`.
2. JSON booleans, numbers, and arrays map directly to Gene booleans, numbers,
   and arrays.
3. A JSON string becomes:
   - a parsed Gene value if it starts with `#GENE#`
   - otherwise a Gene string
4. A JSON object becomes:
   - a Gene form if it contains `genetype`
   - otherwise a Gene map
5. For Gene-form objects:
   - `genetype` is recursively deserialized and used as the Gene node type
   - all fields except `genetype` and `children` become props
   - `children` is recursively deserialized as the node children array
   - missing `children` should be treated as `[]`

### Serialize Gene -> JSON

1. Scalars map directly where JSON has an exact equivalent.
2. Symbols and other non-plain-JSON scalar values that need preservation may be
   encoded as `#GENE#...` strings.
3. Arrays become JSON arrays.
4. Maps become JSON objects when they can be represented without loss.
5. Gene nodes become JSON objects with `genetype`, props, and `children`.

## Worked Examples

### Simple values

```gene
nil
```

```json
null
```

```gene
"str"
```

```json
"str"
```

```gene
a
```

```json
"#GENE#a"
```

### Maps and arrays

```gene
{^a 1 ^b [2 3]}
```

```json
{
  "a": 1,
  "b": [2, 3]
}
```

### Gene nodes

```gene
(f ^a 1 ^b 2 3 4)
```

```json
{
  "genetype": "#GENE#f",
  "a": 1,
  "b": 2,
  "children": [3, 4]
}
```

## Ambiguities and Trade-offs

### `#GENE#` Strings Collide With Literal Strings

This string:

```gene
"#GENE#a"
```

would be misread as the symbol `a` if serialized as the plain JSON string
`"#GENE#a"`.

The cleanest fix is to encode it as a tagged Gene string literal instead of
inventing a second transport-level escape prefix.

Example:

```json
"#GENE#\"#GENE#a\""
```

This decodes as the Gene string `"#GENE#a"`, not the symbol `a`.

So the intended rule is:

- plain JSON string `"abc"` => Gene string `"abc"`
- tagged JSON string `"#GENE#a"` => Gene symbol `a`
- tagged JSON string `"#GENE#\"#GENE#a\""` => Gene string `"#GENE#a"`

### `genetype` Is a Reserved Object Field

Under this design, any JSON object containing `genetype` becomes a Gene form.

That means a plain map like:

```json
{
  "genetype": "http",
  "value": 1
}
```

cannot round-trip as an ordinary Gene map without an additional escape or
wrapper rule.

## Known Limitations in v1

### Maps With Raw `genetype` Keys In Tagged Mode

In tagged mode, any object containing `genetype` is interpreted as a Gene form.

That means a Gene map that genuinely wants a plain `genetype` key is not
representable without an escape or wrapper mechanism.

For v1, this should be documented as a known limitation rather than guessed
around implicitly.

### Prop Order Is Not Preserved

If Gene node props are insertion-ordered, deterministic sorted JSON output will
lose that ordering.

For v1, treat prop ordering as not preserved by this format.

### No Version Marker Yet

The current sketch has no explicit format version marker.

If the tagged encoding changes incompatibly later, existing serialized payloads
may become ambiguous without an additional convention such as `#GENE1#`.

## Additional Suggestions

### 1. Keep Plain JSON Mode Separate

This tagged format is useful for Gene-to-Gene transport through JSON, but it is
not the same thing as plain JSON interop.

Recommendation:

- keep current plain `gene/json/parse` and `gene/json/stringify` behavior for
  ordinary API work
- add a separate tagged mode for round-tripping Gene values, such as:
  - `gene/json/serialize`
  - `gene/json/deserialize`
  - or `gene/json/stringify` / `gene/json/parse` with an explicit tagged option

That avoids surprising users who expect normal JSON behavior.

### 2. Prefer Tagged Gene String Literals For `#GENE#` Strings

Because `#GENE#` is a reserved prefix, literal strings beginning with that
prefix need an escape path.

Preferred rule:

- if a literal string does not start with `#GENE#`, encode it as a normal JSON
  string
- if a literal string does start with `#GENE#`, encode it as a tagged Gene
  string literal

Example:

```json
"#GENE#\"#GENE#a\""
```

This is attractive because:

- it does not require another magic prefix
- it reuses normal Gene reader rules
- it keeps the meaning of `#GENE#...` uniform: parse the rest as one Gene
  value

Alternative transport escapes like `##GENE#...` are still possible, but they
appear unnecessary if tagged Gene string literals are allowed.

### 3. Keep Raw `genetype` Map Keys As A Documented v1 Limitation

Because `genetype` marks a Gene form, tagged mode cannot also represent raw
maps with ordinary `genetype` keys unless an additional escape or wrapper rule
is introduced.

Recommendation:

- document this as a known limitation in v1
- do not invent implicit heuristics for it
- revisit wrappers only when there is a concrete use case

### 4. Require `children` To Be an Array If Present

Recommendation:

- if `children` is present on a Gene-form object, it must be a JSON array
- otherwise deserialization should fail deterministically
- if omitted, treat it as `[]`

That keeps node decoding predictable.

### 5. Reject Unsupported Runtime Types Explicitly

Reasonable v1 support:

- `nil`
- booleans
- integers
- floats
- strings
- symbols
- arrays
- maps with JSON-compatible keys
- Gene nodes

Recommendation:

- explicitly reject values like functions, classes, instances, regexes,
  futures, bytes, and native pointers until there is a deliberate encoding for
  them

Failing explicitly is better than silently stringifying runtime objects.

### 6. Preserve Big Integers With `#GENE#...`

Plain JSON numbers are effectively IEEE 754 doubles in most downstream systems.
Integers larger than `2^53` will commonly lose precision.

Recommendation:

- use normal JSON numbers only inside the safe integer range
- encode larger integers through the tagged path, for example:

```json
"#GENE#99999999999999999999"
```

This should be documented as part of the format contract, not left to
implementation accident.

### 7. Use Deterministic Object Field Ordering

For debugging and tests, stable output is valuable.

Recommendation:

- serialize Gene-form objects in this order:
  1. `genetype`
  2. props sorted by key
  3. `children`

Known limitation:

- if Gene prop insertion order matters semantically, this JSON format does not
  preserve it in v1

### 8. Parse Through `read_all` and Enforce Exactly One Value

The `#GENE#...` rule should be defined in parser terms, not informal text.

Recommendation:

- decode the suffix with the same reader Gene uses elsewhere
- require exactly one parsed value
- reject trailing extra forms such as:

```json
"#GENE#1 2"
```

This is important enough to be part of the formal contract, not just an
implementation detail.

## Suggested Initial Contract

If the goal is to implement this incrementally, the safest first contract is:

1. Keep plain JSON parse/stringify unchanged.
2. Add separate tagged Gene-JSON encode/decode helpers.
3. Treat `#GENE#...` as a general single-value Gene literal tag.
4. Encode literal strings starting with `#GENE#` as tagged Gene string
   literals, for example `"#GENE#\"#GENE#a\""`.
5. Treat any object containing `genetype` as a Gene node in tagged mode.
6. Default missing `children` to `[]`.
7. Use tagged strings for integers outside the JSON safe integer range.
8. Reject ambiguous or unsupported values explicitly rather than guessing.

## Why

Gene's current JSON support is plain JSON only. That is correct for ordinary
API interop, but it loses Gene-specific structure on round trip:

- symbols become plain strings
- Gene nodes become plain maps or strings
- strings beginning with reserved tagged prefixes cannot be disambiguated
- integers outside the JSON safe integer range risk downstream precision loss

The project now has a concrete tagged JSON design in
`docs/json_serialization.md`. The next step is to add an explicit tagged mode
for Gene-to-Gene transport through JSON without breaking the current plain JSON
behavior.

## What Changes

- Keep current plain `gene/json/parse`, `gene/json/stringify`, and `.to_json`
  behavior unchanged for ordinary JSON interop.
- Add separate tagged Gene JSON helpers in the `gene/json` namespace for
  round-tripping Gene values through JSON.
- Implement `#GENE#...` tagged JSON strings that are decoded by parsing the
  suffix as exactly one Gene value.
- Serialize Gene nodes as JSON objects with `genetype`, props, and `children`,
  where `genetype` is recursively encoded and may itself be any Gene value.
- Preserve literal strings that start with `#GENE#` by encoding them as tagged
  Gene string literals rather than introducing a second magic transport prefix.
- Preserve integers outside the JSON safe integer range by encoding them
  through tagged Gene literals.
- Document the v1 known limitations for raw map keys named `genetype`, prop
  ordering, and the lack of an explicit format version marker.

## Impact

- Affected specs:
  - `json` (new)
- Affected code:
  - `src/gene/stdlib/json.nim`
  - `src/gene/parser.nim` or existing parse helpers used by JSON decoding
  - `tests/test_stdlib_json.nim`
  - Gene-level JSON tests/examples
  - `docs/json_serialization.md`
- Risk: medium
- Key risks:
  - ambiguity around raw maps containing `genetype` in tagged mode
  - accidental breakage of existing plain JSON behavior if helpers are not kept
    separate
  - parser-based tagged decoding must enforce the exactly-one-value contract

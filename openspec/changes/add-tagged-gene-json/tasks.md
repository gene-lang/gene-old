## 1. Implementation

- [x] 1.1 Add internal tagged-Gene-JSON encode/decode helpers in
      `src/gene/stdlib/json.nim`.
- [x] 1.2 Keep plain `gene/json/parse`, `gene/json/stringify`, and `.to_json`
      behavior unchanged.
- [x] 1.3 Add separate tagged public helpers in `gene/json` for serializing and
      deserializing Gene values through JSON.
- [x] 1.4 Implement `#GENE#...` decoding via the Gene reader with an
      exactly-one-value contract.
- [x] 1.5 Encode symbols as tagged Gene literals and encode literal strings
      starting with `#GENE#` as tagged Gene string literals.
- [x] 1.6 Encode integers outside the JSON safe integer range via tagged Gene
      literals.
- [x] 1.7 Serialize and deserialize Gene nodes through JSON objects with
      `genetype`, props, and `children`.
- [x] 1.8 Add Nim tests and Gene-level tests for plain JSON compatibility,
      tagged round trips, `#GENE#` string preservation, large integers, and
      Gene node encoding.
- [x] 1.9 Update JSON docs/examples to describe the tagged mode and v1 known
      limitations.

## 2. Validation

- [x] 2.1 Run `nim c -r tests/test_stdlib_json.nim`.
- [x] 2.2 Run focused JSON/string tests affected by the new helpers.
- [x] 2.3 Run `openspec validate add-tagged-gene-json --strict`.

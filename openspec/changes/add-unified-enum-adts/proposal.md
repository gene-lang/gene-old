## Why
Gene has historically split sum-type behavior across simple enums and hardcoded Result/Option-like ADTs. That split leaves declaration syntax, metadata, type checking, pattern matching, and persistence fighting different models.

## What Changes
- **BREAKING**: Establish `enum` as the one public ADT declaration model; legacy Gene-expression ADT declarations are not a supported alternate public syntax.
- Add generic enum declarations using colon parameters, such as `(enum Result:T:E ...)`, while preserving the canonical base enum name.
- Record enum member metadata for unit variants and payload variants, including ordered field names and optional field type descriptors.
- Require targeted diagnostics for malformed enum declarations, duplicate variants, duplicate fields, invalid generic parameters, and invalid field annotations.
- Stage constructor enforcement, Result/Option cleanup, enum pattern matching, import identity, persistence, and final examples as downstream work built on the declaration contract.

## Impact
- Affected specs: `enum-adts`, `type-system`, `pattern-matching`
- Affected code: compiler enum declaration parsing, type checker enum registration, runtime enum metadata, GIR/module type metadata, enum declaration tests, type-checker tests, GIR tests, and public docs.

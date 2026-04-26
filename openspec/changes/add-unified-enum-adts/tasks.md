## 1. S01 Declaration Contract
- [x] 1.1 Canonicalize generic enum declaration heads so `(enum Result:T:E ...)` declares the base enum name `Result`.
- [x] 1.2 Preserve unit variant and payload variant metadata in enum definitions.
- [x] 1.3 Record ordered payload field names and optional field type descriptors for downstream constructor enforcement.
- [x] 1.4 Reject malformed enum declarations, duplicate variants, duplicate fields, invalid generic parameters, and invalid field annotations with targeted diagnostics.
- [x] 1.5 Align public docs/specs with the S01 declaration boundary.

## 2. Downstream Enum ADT Runtime Semantics
- [ ] 2.1 Enforce payload constructor arity, keyword behavior, and annotated field types using the S01 metadata.
- [ ] 2.2 Complete Result/Option migration onto ordinary enum declarations and define compatibility handling for existing shortcuts.
- [ ] 2.3 Implement enum variant pattern matching and destructuring through enum metadata.
- [ ] 2.4 Preserve nominal enum identity across imports, GIR/cache, and serialization boundaries.
- [ ] 2.5 Publish final user examples only after constructor, matching, and identity semantics are closed.

## 3. Validation
- [x] 3.1 Add declaration-contract tests for generic enum heads, payload field metadata, simple enums, and enum type annotations.
- [x] 3.2 Add/maintain negative tests for declaration diagnostics.
- [ ] 3.3 Run the full final enum ADT regression matrix after all downstream tasks are complete.

## 1. Matcher Semantics
- [x] 1.1 Normalize `name...` and `name ...` into the same positional rest binder representation in matcher parsing.
- [x] 1.2 Reject bare `...` and multiple positional rest binders with clear compile-time errors.
- [x] 1.3 Update positional binding so fixed prefix params bind from the start, fixed suffix params bind from the end, and the rest binder receives the middle slice.

## 2. Type-System Alignment
- [x] 2.1 Preserve positional rest position in function type metadata instead of assuming the last positional parameter is variadic.
- [x] 2.2 Update call-site checking so fixed suffix params are validated against trailing call arguments.
- [x] 2.3 Validate typed rest payloads against the declared rest element type when the rest binder uses an `(Array T)` annotation.

## 3. Validation
- [x] 3.1 Add tests for tail rest, non-tail rest, `name ...` postfix spelling, defaults around rest, destructuring, and invalid rest declarations.
- [x] 3.2 Run `openspec validate update-rest-binding-semantics --strict`.

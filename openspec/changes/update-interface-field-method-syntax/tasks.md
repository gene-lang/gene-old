## 1. Spec And Design
- [x] 1.1 Define `field` as the canonical typed field declaration syntax with mandatory type.
- [x] 1.2 Define `method` with no body as an abstract declaration and `method` with one or more expressions as an implementation.
- [x] 1.3 Define interface member syntax and class-header `implements` conformance rules using the same named-parameter method declaration form.

## 2. Language Semantics
- [x] 2.1 Require named parameters in abstract methods and interface methods; omitted parameter types default to `Any`.
- [x] 2.2 Require concrete method implementations to contain at least one expression.
- [x] 2.3 Require explicit `void` for implementations declared as `-> Void`.

## 3. Validation
- [x] 3.1 Add spec deltas for object model and type system.
- [x] 3.2 Run `openspec validate update-interface-field-method-syntax --strict`.

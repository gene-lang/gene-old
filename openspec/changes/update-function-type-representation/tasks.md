## 1. Signature Model
- [ ] 1.1 Replace flat function-type metadata with a canonical callable-signature representation that distinguishes fixed positional, positional variadic, fixed keyword, and keyword-rest parameters.
- [ ] 1.2 Normalize omitted return clauses to `Any` in `TypeExpr`, `TypeDesc`, and GIR metadata while preserving explicit `Void` returns.
- [ ] 1.3 Update type descriptor stringification and registry keys to round-trip canonical `Fn` syntax without losing keyword names or variadic placement.

## 2. Parsing And Inference
- [ ] 2.1 Parse canonical function type syntax: `(Fn)`, `(Fn [Args])`, `(Fn -> Return)`, `(Fn [Args] -> Return)`, and effectful variants with `! [Effects]`.
- [ ] 2.2 Infer canonical function types from function, method, ctor, and native callable definitions, including positional rest and keyword splat parameters.
- [ ] 2.3 Normalize keyword splat bindings to the anonymous contract form `^... T` and positional rest bindings to the contract form `T ...`.
- [ ] 2.4 Resolve `Self` as a class-scoped contextual type while keeping method surface signatures receiver-hidden.
- [ ] 2.5 Reject user-defined bindings or type declarations named `self` or `Self`.

## 3. Compatibility And Validation
- [ ] 3.1 Update compile-time and runtime function compatibility checks to use canonical signature structure instead of arity-only comparisons.
- [ ] 3.2 Add tests covering zero-arg/no-return, explicit return, positional variadic with fixed suffix, fixed keyword parameters, keyword rest, and mixed signatures.
- [ ] 3.3 Run `openspec validate update-function-type-representation --strict`.

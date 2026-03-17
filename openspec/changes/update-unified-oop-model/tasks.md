## 1. Runtime Model
- [ ] 1.1 Represent classes as canonical Gene values with `^name`, `^parent`, `^ctor`, `^methods`, and optional `^on_method_missing`.
- [ ] 1.2 Represent instances as Gene values whose type slot is their class and whose props/children remain Gene-visible.
- [ ] 1.3 Define bootstrap initialization for `Object`, `Class`, `Nil`, and built-in primitive classes.

## 2. Dispatch And Navigation
- [ ] 2.1 Implement parent-chain lookup for methods and inherited `^on_method_missing`.
- [ ] 2.2 Implement inherited constructor lookup through the same `^parent` chain.
- [ ] 2.3 Implement nil-safe receiver navigation and strict `/!` assertion behavior consistent with this spec.
- [ ] 2.4 Preserve optimized primitive/runtime representations without changing observable object-model semantics.

## 3. Validation
- [ ] 3.1 Add Nim tests for bootstrap classes, built-in `is` checks, and method resolution.
- [ ] 3.2 Add Gene tests for user-defined inheritance, dynamic class construction, and nil-safe chains.
- [ ] 3.3 Update language documentation and examples to reflect the unified object model.

## Context
`docs/oop_updated_design.md` defines a unified OOP model for Gene: classes and instances are language-level Gene values, not separate Nim-only structures with a Gene wrapper. The runtime can keep optimized internal representations, but those optimizations must preserve a single observable object model.

This change sits underneath existing and pending class-related proposals:
- `rename-class-member-keywords` defines class-body declaration syntax.
- `implement-macro-constructors` defines regular vs macro constructor behavior.
- `add-selector-transform` defines missing-value semantics for selector traversal.

This design focuses on the canonical runtime model and observable semantics for classes, instances, inheritance, `is`, and nil-safe receiver behavior.

## Goals / Non-Goals
- Goals:
  - Make classes first-class Gene values with Gene-visible metadata.
  - Make instances ordinary Gene values whose type slot points at their class.
  - Define one inheritance and method-resolution model for user-defined and built-in types.
  - Define bootstrap semantics for `Object`, `Class`, and `Nil`.
  - Define nil-safe receiver behavior and strict navigation with `/!`.
- Non-Goals:
  - Add metaclasses or subclassable `Class`.
  - Add interfaces, protocols, mixins, or traits.
  - Add class-level namespace/member lookup rules.
  - Re-specify the full selector missing-value model for non-nil receivers.
  - Reintroduce pseudo-macro class member declarations such as `method!` or `ctor!` as separate object-model concepts.

## Decisions

### Decision: Class values are the canonical representation of classes
Every class SHALL be observable as a Gene value whose type is `Class`.

Required metadata:
- `^name`: class name
- `^parent`: parent class, defaulting to `Object` except for `Object` itself
- `^ctor`: constructor callable, if defined or inherited
- `^methods`: method table mapping names to callables
- `^on_method_missing`: optional fallback callable

Rationale:
- This keeps metaprogramming and serialization aligned with the data model.
- It avoids maintaining separate "real runtime class" and "Gene-visible class" concepts.

### Decision: Instances are typed Gene values
Instances SHALL be observable as ordinary Gene values whose type slot is the class being instantiated. Instance state lives in Gene-visible props and optional children.

Rationale:
- This keeps user-defined objects compatible with quoting, inspection, serialization, and pattern matching.
- It lets optimized internal layouts remain an implementation detail.

### Decision: Built-ins participate in the same object hierarchy
`Object` is the root of the inheritance hierarchy. `Class` inherits from `Object` and is an instance of itself as a bootstrap special case. Built-ins such as `Int`, `String`, `Bool`, `Array`, `Map`, and `Nil` also inherit from `Object`.

Rationale:
- This gives `is` one uniform meaning across user-defined and built-in values.
- It preserves fast-path representations while exposing a consistent language model.

### Decision: Method lookup, constructor inheritance, and fallback all use the parent chain
Method resolution SHALL:
1. Check the receiver class's `^methods`
2. Walk `^parent` until a matching method is found
3. If unresolved, walk the same chain for `^on_method_missing`
4. Throw a method-missing exception if no method or fallback exists

Constructors SHALL use the same inheritance model: if a class does not define `^ctor`, construction uses the first inherited constructor in the `^parent` chain.

Rationale:
- This keeps inheritance rules uniform across ordinary methods, constructors, and fallback behavior.
- It avoids special-case constructor semantics beyond macro-constructor behavior handled elsewhere.

### Decision: Nil is a real object with nil-safe receiver semantics
`nil` is the sole instance of `Nil < Object`. `Nil` may define methods such as `to_s`, `to_bool`, `serialize`, and `on_method_missing`.

Receiver navigation rules:
- Accessing a property or zero-argument method from a `nil` receiver returns `nil`.
- Chained navigation from a `nil` receiver remains `nil`.
- `/!` asserts that the current navigation value is neither `nil` nor `void`, and throws before continuing when the assertion fails.

Rationale:
- This preserves Gene's nil-safe style without introducing separate optional-chaining syntax.
- It keeps `/!` compatible with existing strict-navigation work that already treats missing as exceptional.

## Risks / Trade-offs
- The object model reaches across parser, compiler, VM dispatch, selector navigation, and built-in type registration.
  - Mitigation: keep syntax proposals separate from runtime-model requirements and stage implementation behind this spec.
- Nil-safe receiver behavior can be confused with missing-member behavior on non-nil containers.
  - Mitigation: this change only defines `nil` receiver semantics; selector specs remain authoritative for non-nil missing lookups.
- Bootstrap rules (`Class is Class`, `Object is Object`) are subtle and easy to implement inconsistently.
  - Mitigation: add explicit tests for bootstrap cases and built-in/user-defined `is` checks.

## Migration Plan
1. Align class metadata structures in `src/gene/types.nim` and built-in class registration in `src/gene/vm/core.nim`.
2. Update compiler/VM class creation and instantiation so observed runtime values match the spec.
3. Implement parent-chain method lookup, constructor inheritance, and `^on_method_missing`.
4. Harmonize nil receiver navigation with existing selector/runtime behavior.
5. Add VM-level and Gene-level tests for bootstrap types, inheritance, and nil-safe chains.

## Open Questions
- None in this change. Broader selector missing-value semantics remain in `add-selector-transform`.

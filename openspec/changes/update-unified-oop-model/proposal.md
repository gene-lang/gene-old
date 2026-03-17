## Why
Gene's current class and instance behavior is spread across runtime implementation details, syntax proposals, and design notes, but there is no single spec that defines the canonical object model. `docs/oop_updated_design.md` proposes a unified model where classes and instances are Gene values, built-in types participate in the same hierarchy as user-defined classes, and `nil` behavior is explained at the object-model level.

Without a spec, follow-on work around inheritance, constructor behavior, method dispatch, serialization, and nil-safe navigation can drift or conflict.

## What Changes
- Define a unified object model where classes are Gene values of type `Class` and instances are Gene values whose type slot is their class.
- Specify the canonical class metadata surface: `^name`, `^parent`, `^ctor`, `^methods`, and optional `^on_method_missing`.
- Define the bootstrap hierarchy and `is` semantics for `Object`, `Class`, `Nil`, built-in primitives, and user-defined classes.
- Define parent-chain method resolution, inherited constructors, and inherited `on_method_missing`.
- Define nil-safe receiver navigation and strict `/!` behavior for nil receivers, while keeping missing-member semantics on non-nil receivers aligned with selector work.
- Explicitly exclude metaclasses, class-level namespaces, mixins/traits, interfaces/protocols, and pseudo-macro class member forms from this change.

## Impact
- Affected specs: `object-model`
- Affected code: `src/gene/types.nim`, `src/gene/compiler.nim`, `src/gene/vm.nim`, `src/gene/vm/core.nim`, selector/navigation handling, testsuite, `docs/oop_updated_design.md`

## Why
Gene currently transports type information between compiler, GIR, and runtime primarily as strings. This makes type identity less robust, duplicates parsing work, and blocks a clean path to runtime type objects with lazy implementation hooks.

## What Changes
- Introduce canonical type descriptor objects (`TypeDesc`) and stable IDs (`TypeId`) in core types.
- Persist descriptor tables in GIR and wire compilation unit metadata to include descriptors.
- Add runtime-facing migration path from string-backed metadata to descriptor-backed validation.
- Keep gradual semantics: dynamic fallback remains valid for untyped code.

## Impact
- Affected specs: type-system
- Affected code: `src/gene/types/type_defs.nim`, `src/gene/types/value_core.nim`, `src/gene/types/instructions.nim`, `src/gene/gir.nim`, compiler/runtime type metadata paths, GIR tests

# Descriptor Pipeline Migration Notes (Phase A)

This document describes what changed in the descriptor-first rollout and what
developers and extension authors need to update.

## Scope

Phase A unified type identity across:

- type checker
- compiler metadata
- GIR serialization
- VM runtime validation

Gene remains gradual-first by default. Untyped code still runs dynamically, and
typed boundaries are validated.

## Breaking/Internal Changes

1. Type transport is descriptor-first:
   - canonical `TypeDesc`/`TypeId` are now the executable metadata path
   - string forms remain diagnostics/display only
2. Function metadata transport changed:
   - `FunctionDefInfo.type_expectation_ids: seq[TypeId]`
   - `FunctionDefInfo.return_type_id: TypeId`
3. Runtime mismatch diagnostics now carry machine-readable mismatch codes:
   - `GENE_TYPE_MISMATCH`
4. Flow narrowing in the checker was strengthened for:
   - `if` guards (`.is` and infix `is`)
   - `case` and `match` branch guards

## GIR Cache Policy

- `GIR_VERSION` is now `17`.
- Older incompatible GIR artifacts are rejected and recompiled from source.
- There is no transparent migration path for old cache binaries.

Operationally: treat GIR as a cache, not a distribution artifact.

## Developer Migration Checklist

1. Stop using string type names as runtime/compiler metadata keys.
2. Use descriptor IDs and tables:
   - `type_id`
   - `type_descriptors`
   - `type_registry`
3. When building registries programmatically, use canonical helpers:
   - `new_module_type_registry`
   - `register_type_desc`
   - `rebuild_module_registry_indexes`
4. If you have stale build artifacts, rerun compilation or clear `build/`.
5. If you depend on `FunctionDefInfo`, switch consumers to the new TypeId fields.

## Extension Author Notes

If your extension inspects callable/type metadata:

1. Read matcher/argument type IDs instead of string type names.
2. Resolve IDs through the active descriptor table for comparisons.
3. Do not assume old GIR cache compatibility across this boundary.
4. Prefer runtime/type helper APIs instead of hand-parsing serialized metadata.

## Validation Expectations

After migration:

- mixed typed/untyped module boundaries still execute correctly
- typed boundaries fail with clear mismatch diagnostics
- cached GIR runs with the same descriptor behavior as fresh compilation

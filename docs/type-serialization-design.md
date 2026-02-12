# Type Serialization: Cross-Module Type Persistence

**Author:** Sunni  
**Date:** 2026-02-12  
**Status:** 🟡 Design

## Problem

GIR already serializes `TypeDesc` tables per compilation unit (`writeTypeDescTable`/`readTypeDescTable` in `gir.nim`). However:

1. **`ModuleTypeRegistry`** (Phase 4) is not serialized — module-scoped type registries are lost when loading from cached GIR
2. **`GlobalTypeRegistry`** is not persisted — cross-module type lookups fail after cache load
3. **Type aliases** (`type_aliases: Table[string, TypeId]`) on `CompilationUnit` are not serialized
4. **`module_path`** on `TypeDesc` was added (Phase 2) but GIR round-trips may not preserve module origin correctly

## Goal

After this work, a program compiled to GIR and loaded back should have identical type information as a freshly compiled program. Cross-module imports should resolve types correctly from cached GIR.

## Design

### 1. Serialize `ModuleTypeRegistry` in GIR

Each `CompilationUnit` has a `type_registry: ModuleTypeRegistry`. Serialize it after the existing `type_descriptors`:

```
[existing type_descriptors seq]
[type_registry descriptor count: int32]
[for each (TypeId, TypeDesc) pair in registry.descriptors ordered table:]
  [type_id: int32]
  [TypeDesc via existing writeTypeDesc]
```

### 2. Serialize Type Aliases

```
[alias count: int32]
[for each (name, TypeId) in type_aliases:]
  [name: string]
  [type_id: int32]
```

### 3. GlobalTypeRegistry Reconstruction

Don't serialize `GlobalTypeRegistry` directly. Instead, reconstruct it at load time by:
- Loading each module's `ModuleTypeRegistry` from its GIR
- Re-registering into the global registry during module loading

This keeps the GIR format per-module and avoids duplication.

### 4. Validate Round-Trip

Add tests that:
1. Compile a multi-module program
2. Save to GIR
3. Load from GIR
4. Verify `ModuleTypeRegistry` matches
5. Verify cross-module type lookups work
6. Verify type aliases resolve correctly

## Files to Modify

- `src/gene/gir.nim` — add registry/alias serialization
- `src/gene/vm/module.nim` — reconstruct GlobalTypeRegistry on GIR load
- `tests/` or `testsuite/` — round-trip tests

## Non-Goals

- Changing the TypeDesc format itself (already works)
- Type inference (separate concern)
- Binary compatibility versioning (defer)

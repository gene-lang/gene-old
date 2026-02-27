# Design: Stabilize Module and Package Semantics

## Context

Current loader behavior spans multiple paths (`import_from_namespace`, package lock/deps lookup, workspace search, package-root fallback, native fallback), with practical behavior that is mostly correct but still too implicit for core-language semantics.

Key gaps to close:

- First-hit resolution across multiple roots can hide ambiguity.
- `^pkg` imports need strict package-root confinement.
- Export metadata exists but is not consistently used to gate imports.
- Diagnostics are not consistently structured for debugging and tooling.

## Goals

- Deterministic module resolution independent of incidental runtime context.
- Explicit package boundary enforcement for package-qualified imports.
- Export-surface correctness as part of module semantics.
- Diagnostics that are stable, contextual, and testable.

## Non-Goals

- New import syntax.
- New package manager/version solver behavior.
- Transparent migration of older non-deterministic behavior.

## Decisions

### 1. Canonical Resolution Descriptor

Resolution uses an internal descriptor:

- `importer_module`
- `raw_module_specifier`
- `package_name` (optional)
- `package_root` (optional)
- `resolved_path` (canonical absolute path)
- `is_gir`
- `is_native`

All cache keys and cycle tracking use canonical `resolved_path`.

### 2. Deterministic Search Order

For non-`^pkg` imports:

1. importer directory
2. importer package root logical roots (`<pkg>`, `<pkg>/src`, `<pkg>/lib`, `<pkg>/build`)

For `^pkg` imports:

1. resolve package root using fixed precedence:
   - explicit `^path` override
   - lockfile graph
   - materialized `.gene/deps`
   - package search paths
2. resolve module only within that package root logical roots.

No cross-package fallback is allowed after package root is selected.

### 3. Ambiguity Policy

If multiple candidates are valid within the same precedence tier, resolution fails with explicit ambiguity diagnostics instead of selecting arbitrarily.

### 4. Export Enforcement

- If module namespace has explicit exports metadata, imports (named and wildcard) must respect it.
- If no explicit exports metadata exists, keep current open-surface behavior.

### 5. Diagnostics Contract

Module/package errors include:

- stable code (e.g., `GENE.MODULE.NOT_FOUND`, `GENE.MODULE.AMBIGUOUS`, `GENE.PACKAGE.BOUNDARY`, `GENE.IMPORT.EXPORT_MISSING`, `GENE.MODULE.CYCLE`)
- importer module path
- requested module/package specifier
- searched roots/candidates (where applicable)
- cycle chain (for cyclic imports)

## Risks / Trade-offs

- Existing projects relying on accidental fallback behavior may fail.
- Export enforcement can surface latent coupling to non-public module internals.

Mitigation:

- clear diagnostics with migration guidance,
- focused conformance tests,
- maintain legacy open behavior only when exports are not declared.

## Migration Plan

1. Implement canonical resolution + diagnostics scaffolding.
2. Enforce package boundaries and ambiguity checks.
3. Wire export gating in import paths.
4. Add conformance tests and finalize docs.

## Open Questions

- Whether ambiguity detection should fail only within a tier (chosen) or across all tiers.
  - Proposed: fail within a tier; preserve precedence semantics across tiers.
- Whether export enforcement should be opt-in by explicit `export` declaration (chosen).
A: exported by default. No need for explicit export for now.

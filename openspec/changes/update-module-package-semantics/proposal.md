# Proposal: Stabilize Module and Package Semantics

## Why

Module/package behavior currently works but still has context-sensitive edges that create surprises:

- module resolution uses multiple fallbacks where first-hit behavior can depend on environment and layout,
- package imports can silently drift across candidate roots instead of clearly enforcing package boundaries,
- explicit export metadata exists but import paths do not consistently enforce it,
- import failures are not consistently diagnostic-rich (missing importer context, search roots, and stable error codes).

For Core Gene stability, module resolution and package boundaries should be treated as language semantics, not incidental loader behavior.

## What Changes

- Define one deterministic module resolution contract with explicit precedence and ambiguity handling.
- Canonicalize resolved module identity so one file maps to one cache key and one load lifecycle.
- Enforce package boundaries for `^pkg` imports (no path-escape fallthrough outside resolved package root).
- Enforce explicit module export boundaries when a module declares exports.
- Standardize module/package diagnostics with stable error codes and contextual payload.
- Add conformance tests for resolution determinism, package boundary enforcement, export gating, and cycle diagnostics.

### **BREAKING**

- Imports of non-exported names from modules with explicit exports will fail deterministically.
- Ambiguous package/module matches that previously resolved by incidental search order will fail with explicit ambiguity diagnostics.
- Some imports that previously succeeded via context-dependent fallback outside intended package scope will now fail with boundary errors.

## Impact

- Affected specs: `language-module-system`, `package-system`
- Affected code:
  - `src/gene/vm/module.nim` (resolver contract, package boundary rules, diagnostics)
  - `src/gene/vm/core_helpers.nim` (export-aware import behavior)
  - `src/gene/vm/exec.nim` (cycle error payload consistency)
  - `src/gene/compiler/modules.nim` (metadata alignment where needed)
  - tests in `tests/test_module.nim`, `tests/test_package.nim`, `tests/test_cli_run.nim`, `testsuite/imports/`

- Risk profile: medium (core loading semantics)
- Mitigation:
  - fixed precedence contract,
  - strict ambiguity rejection,
  - conformance tests as gate.

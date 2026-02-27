## 1. Resolution Contract
- [x] 1.1 Implement and document a single deterministic module resolution order for non-`^pkg` imports.
- [x] 1.2 Canonicalize resolved module identities (absolute normalized path keying) before cache lookup/load.
- [x] 1.3 Add ambiguity detection and explicit failure for conflicting matches in the same precedence tier.

## 2. Package Boundary Enforcement
- [x] 2.1 Define and enforce package root precedence (`^path` override -> lockfile -> `.gene/deps` -> search paths).
- [x] 2.2 Enforce that `^pkg` module resolution remains within the resolved package root (reject path escape).
- [x] 2.3 Add deterministic errors when lockfile/deps metadata is inconsistent (missing node, name mismatch, invalid root).

## 3. Export Surface Enforcement
- [x] 3.1 Enforce explicit exports for modules that declare `__exports__` metadata.
- [x] 3.2 Keep deterministic legacy behavior for modules without explicit exports.
- [x] 3.3 Ensure wildcard imports include only allowed exported/public names and always skip internal loader keys.

## 4. Diagnostics
- [x] 4.1 Add stable error codes for module/package failures (`not_found`, `ambiguous`, `boundary_violation`, `export_missing`, `cycle`).
- [x] 4.2 Include contextual diagnostics: importer module, requested specifier, package context, and searched roots/candidates.
- [x] 4.3 Ensure cycle diagnostics consistently include the complete import chain.

## 5. Conformance Tests
- [x] 5.1 Add deterministic resolution tests (same target across cwd/workspace/package context).
- [x] 5.2 Add package boundary tests for `^pkg` imports and path-escape rejection.
- [x] 5.3 Add export enforcement tests for named and wildcard import behavior.
- [x] 5.4 Add ambiguity and cycle diagnostics tests with expected stable codes/messages.

## 6. Validation
- [x] 6.1 Run targeted suites: `tests/test_module.nim`, `tests/test_package.nim`, `tests/test_cli_run.nim`.
- [x] 6.2 Run import testsuite category (`./testsuite/run_tests.sh` imports).
- [x] 6.3 Run `openspec validate update-module-package-semantics --strict`.

## 0. Pre-Work Blocker
- [x] 0.1 Reproduce and root-cause the symbol-index overflow regression reported in descriptor/GIR paths.
- [x] 0.2 Fix the symbol-index regression before descriptor-pipeline rollout.
- [x] 0.3 Add a regression test that exercises cached GIR execution (not only `--no-gir-cache` paths).

## 1. Descriptor Pipeline (Phase A)
- [x] 1.1 Define canonical `TypeDesc`/`TypeId` ownership and module-level registries (builtins, named types, applied types, unions, function types).
- [x] 1.2 Remove string-first type transport from compiler metadata (`type_expectations`) and switch to descriptor references.
- [x] 1.3 Persist descriptor tables in GIR with stable IDs and module-path provenance.
- [x] 1.4 Bump GIR type-metadata version and invalidate/recompile legacy caches (no transparent migration).

## 2. Runtime Validation and Diagnostics (Phase A)
- [x] 2.1 Make VM validation paths descriptor-first (`IkVar`, assignment, matcher binding, returns).
- [x] 2.2 Improve runtime type errors with expected/actual type, binding context, and source location.
- [x] 2.3 Add flow-sensitive narrowing improvements for `if`/`case`/`match` guards in the type checker where required by descriptor adoption.

## 3. Quality Gates (Phase A)
- [x] 3.1 Add targeted tests for mixed typed/untyped modules and descriptor serialization parity.
- [x] 3.2 Add GIR cache invalidation tests (old cache rejected/recompiled, new cache accepted).
- [x] 3.3 Publish migration notes for developers and extension authors.

## Deferred Follow-Ups
- [ ] Phase B proposal: native compilation tiers (`never`/`guarded`/`fully-typed`) with deopt behavior.
- [ ] Phase C proposal: formatter spec + implementation and expanded AI/tooling metadata surface.

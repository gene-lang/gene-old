## Why
Gene already has strong building blocks (gradual type checker, runtime validation, GIR serialization), but the architecture is still fragmented across string-based and descriptor-based type paths. This blocks a coherent AI-first foundation and makes further optimization/tooling risky.

Review feedback correctly identified that the original proposal was too broad. This change is intentionally narrowed to a single foundational phase.

## What Changes
- Establish a descriptor-first type pipeline across type checker, compiler metadata, GIR serialization, and VM runtime validation.
- Keep gradual typing as the default language mode, with stricter checks available per module/profile.
- Define GIR migration behavior as version bump + cache invalidation/recompile (no transparent migration path).
- Fix and guard against the symbol-index regression in descriptor/GIR paths before descriptor-pipeline rollout.
- Improve typed runtime diagnostics (expected/actual/context) in the validation paths touched by Phase A.

Deferred to follow-up proposals:
- Phase B: native compilation tiers and deopt model
- Phase C: formatter + broader AI/tooling metadata surface

## Impact
- Affected specs: `ai-first-core` (new capability)
- Affected code:
  - `src/gene/type_checker.nim`
  - `src/gene/compiler.nim`
  - `src/gene/gir.nim`
  - `src/gene/types/runtime_types.nim`
  - `src/gene/vm/*.nim`
- **BREAKING**:
  - Internal compiler/runtime type metadata format will change from mixed string/descriptor forms to descriptor-first.
  - GIR type metadata version will bump; older caches are invalidated and recompiled.

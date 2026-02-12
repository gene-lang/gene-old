## Context
Gene has working pieces for the long-term vision:
- Gradual type checker with inference
- Runtime type validation
- GIR serialization with type metadata

The main architectural gap is coherence: type identity is still split between descriptors and strings. This Phase A change focuses only on unifying that foundation.

## Goals
- Deliver a stable AI-first foundation by unifying type identity end-to-end.
- Preserve gradual typing defaults while making typed code more reliable and optimizable.
- Improve runtime diagnostics in descriptor-validated paths.
- Land a safe GIR migration policy for cache compatibility.

## Non-Goals
- Replace the VM with a new runtime.
- Require fully static typing for all code.
- Implement native compilation tiers in this change.
- Implement canonical formatter or broad tooling metadata in this change.

## Decisions

### 1) Descriptor-first type identity
All compile/runtime boundaries MUST use canonical `TypeDesc`/`TypeId` identities. String forms may remain as display-only diagnostics, not executable metadata.

### 2) Gradual by default, strict by policy
Unannotated code remains valid (`Any` semantics). Strictness is configured per module/profile and enforced through checker/runtime policies, not a global language flip.

### 3) GIR migration strategy
GIR is a cache, not a stable distribution artifact. The migration policy is:
- bump GIR type-metadata version for this change,
- reject old incompatible cache entries,
- recompile from source automatically.

### 4) Symbol-index regression is a release blocker
Descriptor/GIR work does not proceed until the reported symbol-index overflow path is root-caused and guarded by regression tests.

## Architecture

### Type Pipeline
1. Parse annotations and forms.
2. Type checker produces canonical descriptors.
3. Compiler stores descriptor IDs in matcher/scope metadata and instruction payloads.
4. GIR persists descriptor tables and references.
5. VM validates values against descriptors directly.

## Risks and Mitigations
- Risk: GIR compatibility break
  - Mitigation: explicit version bump + cache invalidation/recompile.
- Risk: symbol table corruption/overflow in descriptor serialization paths
  - Mitigation: blocker fix before rollout + regression tests on cached GIR path.
- Risk: complexity growth in checker/runtime
  - Mitigation: phase-limited scope and explicit follow-up proposals.

## Rollout Plan
1. Resolve symbol-index regression and add coverage.
2. Unify descriptor pipeline end-to-end.
3. Migrate runtime validators and diagnostics.
4. Enforce descriptor/GIR regression gates.
5. Propose Phase B and C separately after Phase A stabilizes.

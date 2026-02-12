# Review: refactor-ai-first-gradual-native-pipeline

**Reviewer:** Sunni  
**Date:** 2026-02-12

## Overall Assessment

This is an ambitious and well-structured proposal. The vision is right: Gene's type infrastructure is fragmented, and unifying it under a descriptor-first model is the correct architectural move. The phased approach is sensible.

However, I have concerns about scope and some specific design choices.

## What I Like

1. **Descriptor-first identity** — This is exactly right. We already started this work (type serialization in GIR is now working), and making it the canonical path everywhere will eliminate a class of bugs. The string-vs-descriptor split is a real pain point.

2. **Gradual by default, strict by policy** — Smart. Don't force typing on anyone but reward those who opt in. Per-module/profile configuration is the right granularity.

3. **Quality gates before enablement** — The "parity tests + performance gates" approach is mature. Native codegen that subtly changes behavior would be catastrophic for trust.

4. **AI metadata surface** — `^intent`, `^examples`, typed signature export are exactly what makes Gene AI-first in practice, not just in marketing.

## Concerns

### 1. Scope is very large
This proposal touches type_checker, compiler, GIR, VM runtime, native codegen, LSP, CLI, AND formatter. That's essentially the entire compiler pipeline. For a language with one primary developer (and AI assistants), this is a multi-month effort.

**Suggestion:** Split into 2-3 smaller proposals:
- **Phase A:** Descriptor pipeline unification (tasks 1.x + 2.x) — this is foundational
- **Phase B:** Native compilation tiers (tasks 3.x) — depends on Phase A
- **Phase C:** Tooling/AI metadata (tasks 4.x) — can partially parallelize with B

### 2. Native compilation tiers may be premature
Gene's current performance (~950K-5M calls/sec) is acceptable for its use case (AI scripting, tool orchestration, DSLs). The native compilation tier adds significant complexity (guard/deopt hooks, HIR coverage, cross-function compatibility).

**Question:** What concrete workloads need native compilation today? If the answer is "none yet," defer Phase B and invest in stdlib/ecosystem instead. Users care more about `(http/get url)` working than about loop throughput.

### 3. GIR migration strategy is underspecified
Task 1.4 says "Implement GIR migration strategy and fallback for legacy caches." This is critical — old `.gir` files with the pre-descriptor format will exist. The proposal doesn't specify whether we:
- Auto-detect and re-compile (safest)
- Version the GIR header and reject old versions
- Attempt transparent migration

**Recommendation:** Simple version bump + recompile. GIR is a cache, not a distribution format. Just invalidate old caches.

### 4. Canonical formatter needs a language spec
Task 4.1 assumes we know what "canonical" means for Gene. We don't have a formal grammar or formatting spec. Without it, `gene fmt` will be making arbitrary choices that become de facto standards.

**Suggestion:** Write the formatting rules as a separate mini-spec before implementing. Key decisions: indentation (2 vs 4 spaces), line width, property ordering, when to break lines.

### 5. Conflict with our AOP work
The proposal says it will change "Internal compiler/runtime type metadata format" which is BREAKING. Our AOP improvements (just committed as `d09500e`) modify dispatch.nim, exec.nim, and stdlib.nim in the same areas. The openspec proposal's src changes (`645e6f9`) also touched these files.

**Action needed:** Coordinate the AOP chaining work and this refactor to avoid merge conflicts and semantic regression.

## Pre-existing Bug Note

There's a symbol index overflow regression in `testsuite/oop/2_aop_aspects.gene` introduced by commit `5c4780a` (type serialization). The error is `index 397 not in 0 .. 350` in `get_symbol`. This should be fixed before starting the descriptor pipeline work, since it indicates the current type descriptor handling already has an edge case bug.

## Recommendation

**Approve Phase A (descriptor pipeline + runtime validation) only.** Defer native compilation and tooling to separate proposals. Fix the symbol index regression first.

The descriptor work is the right foundation and has clear, testable milestones. The native compilation and formatter work are valuable but should wait until the foundation is solid.

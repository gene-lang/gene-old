# Milestones

## v1.0 Actor Runtime Migration

**Status:** Complete
**Completed:** 2026-04-23
**Roadmap phases:** 0, 1, 1.5, 2, 3, 4

The actor migration track delivered the runtime substrate needed for
actor-first concurrency:

- unified lifetime and publication semantics
- deep-frozen/shared-value support
- freezable closures
- actor runtime with tiered sends, reply futures, and stop semantics
- port actors for stateful extensions
- removal of the public thread-first concurrency surface

## v1.1 Core Stabilization + Package MVP

**Status:** Active
**Started:** 2026-04-24
**Roadmap phases:** 5, 6, 7, 8

This milestone follows the GPT Pro review triage and focuses on the next trust
boundary for Gene:

- feature status matrix and stable-core boundary
- core semantic tightening
- local deterministic package/module MVP
- VM correctness harness

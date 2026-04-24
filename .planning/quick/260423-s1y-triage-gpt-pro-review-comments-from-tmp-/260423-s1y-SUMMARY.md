---
quick_id: 260423-s1y
status: complete
description: Triage GPT Pro review comments from tmp/gpt-pro-comments.md
completed: 2026-04-24T00:11:57.438Z
---

# Quick Task 260423-s1y: GPT Pro Review Triage

## Source

- `tmp/gpt-pro-comments.md`

## Accepted And Actioned

- The review's concurrency-surface criticism had one concrete stale-doc
  instance in the current repo: `spec/10-async.md` still documented the retired
  thread-first public API (`spawn`, `spawn_return`, top-level message helpers,
  `GENE_MAX_THREADS`) even though Phase 4 removed that surface and the actor
  handbook now states that actors are the public concurrency API.
- Updated `spec/10-async.md` to describe actor-first concurrency, tiered actor
  message semantics, worker limits, and actor-oriented future improvements.

## Valid Roadmap-Level Items

- Package/module system: still the largest product gap. `docs/package_support.md`
  already says `package.gene` is marker/metadata only, `$dep` is not
  implemented, `$pkg` is not wired, and no version/lock/install story exists.
  This should be a future milestone, not a drive-by quick fix.
- Feature-status matrix: useful next documentation/product task. The repo has
  status notes spread across README, docs, specs, and planning artifacts, but
  no single public matrix mapping feature status, implementation status, tests,
  and known gaps.
- VM correctness infrastructure: valid as a future milestone. Debug/invariant
  checking, fuzzing, and instruction metadata would be valuable, but they are
  broad runtime work.
- Core-language freeze: valid product guidance. The review's recommendation to
  make the stable core smaller and label beta/experimental features explicitly
  aligns with current README caveats.

## Stale Or Already Addressed

- Public thread-first concurrency: already removed from the active runtime
  surface during Phase 4. Remaining native threads are internal worker
  substrate for actors.
- Actor/extension ownership boundaries: already addressed in the actor
  migration track. The actor handbook documents actor-backed `genex/llm`,
  `genex/http`, and `genex/ai/bindings` ownership.
- The review did not run the local suite and appears partly based on public
  repo docs, so claims should be treated as triage signals rather than
  execution-verified defects.

## Changed Files

- `spec/10-async.md` - replaced retired thread-first public API documentation
  with actor-first concurrency semantics.

## Implementation Commit

- `b54b8f2` - Align async spec with actor-first concurrency

## Verification

- `rg -n "spawn_return|send_expect_reply worker|GENE_MAX_THREADS|thread \\.on_message" spec/10-async.md` returns no matches.
- `rg -n "Actors|gene/actor|Worker Limits|retired thread-first" spec/10-async.md` confirms the new actor-first section is present.

---
phase: 04-remove-legacy-thread-first-concurrency-surfaces
plan: 02
subsystem: naming-and-docs
tags: [docs, examples, env, naming, actors]
requires:
  - phase: 04-01
    provides: Public thread-first compiler/runtime surface removed
provides:
  - Worker-facing public naming uses `GENE_WORKERS`
  - Active docs/examples no longer teach the retired thread-first surface
affects: [04-03, docs, examples, runtime-config]
key-files:
  modified:
    - src/gene/types/core.nim
    - src/gene/vm/runtime_helpers.nim
    - src/gene/types/helpers.nim
    - docs/README.md
    - docs/architecture.md
    - docs/handbook/actors.md
    - docs/handbook/freeze.md
    - docs/how-exception-works.md
    - docs/http_server_and_client.md
    - docs/ongoing-cleanup.md
    - examples/README.md
    - examples/full.gene
    - examples/run_examples.sh
    - tests/test_wasm.nim
  deleted:
    - docs/thread_support.md
    - examples/thread.gene
completed: 2026-04-22T00:00:00Z
---

# Phase 4 Plan 2 Summary

**The active docs/examples are now actor-only, and the public worker knob is `GENE_WORKERS`**

## Accomplishments

- Renamed the public worker-count env var from `GENE_MAX_THREADS` to `GENE_WORKERS`.
- Updated the runtime error wording to use “workers” instead of “threads” on the public path.
- Removed the active `docs/thread_support.md` page and all active links to it from current docs.
- Removed the `examples/thread.gene` example and the curated example runner/reference to it.
- Replaced the `spawn_return` snippet in `examples/full.gene` with an actor-based `send_expect_reply` example.
- Updated the active handbook/docs so they no longer teach the retired thread-first surface.

## Verification

- `rg -n "GENE_WORKERS|GENE_MAX_THREADS" src/gene/types/core.nim src/gene/vm/runtime_helpers.nim src/gene/types/helpers.nim docs examples tests`
- `nim c -r tests/integration/test_actor_runtime.nim`
- `nim c -r tests/integration/test_http_port_ownership.nim`
- `nim c -r tests/integration/test_ai_slack_socket_mode.nim`

## Follow-up for 04-03

- Run the final actor replacement sweep and publish milestone-complete metadata.

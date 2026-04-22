---
phase: 03-port-actors-for-extensions
plan: 02
subsystem: llm-extension
tags: [nim, extensions, actors, abi, llm]
requires:
  - phase: 03
    provides: Extension port registration/materialization substrate and host port-call bridge
provides:
  - Stable exported-function ABI for dynamic `genex/llm` operations
  - Host-owned `Model` / `Session` wrappers that no longer cross the dylib boundary as live extension values
  - One host-owned singleton actor that serializes LLM bridge calls without reusing extension-local threadvars
affects: [03-03, extension-runtime, actor-runtime, llm-runtime]
key-files:
  created:
    - src/gene/vm/llm_host_abi.nim
  modified:
    - src/gene/extension/gene_extension.h
    - src/gene/types/type_defs.nim
    - src/gene/vm/actor.nim
    - src/gene/vm/extension.nim
    - src/gene/vm/extension_abi.nim
    - src/genex/llm.nim
    - tests/integration/test_llm_mock.nim
completed: 2026-04-21T20:15:51Z
---

# Phase 3 Plan 2 Summary

**`genex/llm` now crosses the host/extension boundary through an explicit bridge instead of live extension-owned values**

## Accomplishments

- Added a dedicated LLM host ABI surface in `src/gene/vm/llm_host_abi.nim` for:
  - ABI version check
  - model load
  - session creation
  - inference
  - model/session close
  - returned-string cleanup
- Reworked `src/genex/llm.nim` so the dynamic extension exports those bridge functions, keeps backend-owned model/session handles internally, and returns only ids or serialized data to the host.
- Reworked `src/gene/vm/extension.nim` so the host resolves the exported LLM bridge symbols, installs host-owned `Model` / `Session` wrappers, and routes wrapper calls through one host-owned singleton actor.
- Moved actor reply delivery off extension-local threadvars and onto explicit `ActorContext` reply metadata so actor-backed bridge calls work safely from the host side.
- Updated `src/gene/extension/gene_extension.h` to match the real host ABI layout after the Phase 3 substrate callbacks were added, fixing the dynamic C extension crash caused by struct layout drift.
- Updated `tests/integration/test_llm_mock.nim` to exercise the real dynamic-extension path and verify that the public API now returns host-owned wrapper instances rather than raw extension-owned values.

## Decisions Made

- Rejected the original "return live `Value`s from the dylib" path because it was unstable across the dynamic boundary and produced invalid host-visible values.
- Rejected the extension-owned singleton actor path because it still relied on dynamic-extension callback semantics that were not yet stable enough for public reply handling.
- Kept the public Gene API stable while moving the unsafe boundary into an explicit exported-function ABI plus a host-owned serialization actor.

## Verification

- `nim c --app:lib -d:GENE_LLM_MOCK --mm:orc -o:build/libllm.dylib src/genex/llm.nim`
- `nim c -r -d:GENE_LLM_MOCK tests/integration/test_llm_mock.nim`
- `nim c -r tests/integration/test_actor_reply_futures.nim`
- `nim c -r tests/integration/test_extension_ports.nim`
- `nim c -r tests/test_c_extension.nim`

## Follow-up for 03-03

- `genex/http` and AI bindings still need the same ownership cleanups so process-global callbacks, pools, or resource handles stop bypassing the actor runtime.
- The LLM bridge is intentionally extension-specific; generalizing exported bridge patterns across extensions is future cleanup, not a prerequisite for `03-03`.

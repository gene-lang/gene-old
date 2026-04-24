# Gene Documentation

`spec/` is the canonical language reference for implemented behavior.

`docs/` is for current implementation notes, subsystem reference material, and
operational guidance. Design proposals, speculative work, and design-era docs
for implemented subsystems now live under [`docs/proposals/`](proposals/README.md).

Start with [feature-status.md](feature-status.md) for the public feature-status
matrix and stable-core boundary.

## Spec Companion Docs

- [generator_functions.md](generator_functions.md) — shipped generator semantics
- [regex.md](regex.md) — current regex syntax and helper behavior
- [package_support.md](package_support.md) — current package/import behavior
- [type-system-mvp.md](type-system-mvp.md) — current gradual typing status
- [deserialize_command.md](deserialize_command.md) — `gene deser` command behavior
- [how-types-work.md](how-types-work.md) — runnable typing walkthrough
- [adapter-design.md](adapter-design.md) — interface and adapter system design

## Implementation-Only Docs

These are current and useful, but they are not yet covered by `spec/`.

- [architecture.md](architecture.md) — VM/compiler/runtime architecture overview
- [compiler.md](compiler.md) — compiler pipeline and descriptor-first typing notes
- [gir.md](gir.md) — GIR format, caching, and CLI workflow
- [descriptor-pipeline-migration.md](descriptor-pipeline-migration.md) — descriptor pipeline migration notes
- [wasm.md](wasm.md) — wasm build target and ABI contract
- [http_server_and_client.md](http_server_and_client.md) — HTTP extension surface
- [c_extensions.md](c_extensions.md) — native extension API and build flow
- [lsp.md](lsp.md) — current LSP implementation status

## Performance And Ops

- [performance.md](performance.md) — benchmark numbers and optimization priorities
- [gir-benchmarks.md](gir-benchmarks.md) — GIR-specific benchmark notes
- [benchmark_http_server.md](benchmark_http_server.md) — HTTP benchmarking workflow
- [ongoing-cleanup.md](ongoing-cleanup.md) — living cleanup tracker

## Working Notes

- [implementation/async_design.md](implementation/async_design.md) — async implementation diary
- [implementation/async_progress.md](implementation/async_progress.md) — async rollout progress log
- [implementation/async_tasks.md](implementation/async_tasks.md) — async task checklist
- [implementation/caller_eval.md](implementation/caller_eval.md) — `$caller_eval` implementation notes

## Design And Proposal Docs

- [proposals/README.md](proposals/README.md) — future proposals, implemented-but-design-era notes, and archived historical docs

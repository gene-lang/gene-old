# Phase 05 Pattern Map

## Existing Documentation Patterns To Reuse

| Existing doc | Pattern | Phase 05 use |
|--------------|---------|--------------|
| `docs/package_support.md` | States what works today, what is aspirational, and known mismatches. | Use the same "current implementation vs missing" honesty for package rows. |
| `docs/type-system-mvp.md` | Separates delivered behavior from still-missing and deferred behavior. | Use this shape for beta surfaces in the feature matrix. |
| `docs/lsp.md` | Lists current capabilities and current limits compactly. | Use for tooling rows without overclaiming. |
| `docs/handbook/actors.md` | Defines the public actor-first boundary and references tests. | Use for the stable actor-concurrency row. |
| `spec/10-async.md` | Separates futures/async from actor-backed concurrency and names retired thread-first APIs. | Mirror this language in README/spec index updates. |

## New Documentation Pattern

`docs/feature-status.md` should be the public status hub:

- start with status definitions: stable, beta, experimental, future, removed
- use one matrix with columns for feature, status, spec/docs, implementation,
  tests, known gaps, and user posture
- follow the matrix with a stable-core section that lists included and excluded
  surfaces explicitly
- link to focused docs rather than duplicating all subsystem details

## Anti-Patterns To Avoid

- Do not make packages look stable because import path search exists.
- Do not list classes, selectors, gradual typing, pattern matching, native
  extensions, WASM, or LSP as stable core unless the docs/tests already support
  that claim.
- Do not revive public thread-first APIs in public docs; worker threads are an
  internal substrate only.
- Do not make the README carry the full matrix; it should summarize and link.

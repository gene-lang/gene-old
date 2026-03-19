# Implementation Tasks: Unified Runtime Logging

## 1. Backend And Routing
- [ ] 1.1 Refactor `logging_core` to store immutable routing config with root route, per-logger overrides, sink registry, and route cache.
- [ ] 1.2 Implement sink backends for `console` and append-only `file`, with fan-out to multiple targets from one event.
- [ ] 1.3 Ensure disabled logs return before message formatting and that formatted lines are reused across selected text sinks.

## 2. Configuration
- [ ] 2.1 Extend `config/logging.gene` parsing to support `sinks` and `targets`.
- [ ] 2.2 Preserve backward compatibility with the existing root `level` + `loggers` config shape.
- [ ] 2.3 Emit clear warnings for invalid sink definitions without breaking valid sinks.

## 3. APIs And Adoption
- [ ] 3.1 Keep `genex/logging/Logger` on the shared backend, make it accept any value via `.to_s`, and add Nim-facing helpers for cheap runtime call sites.
- [ ] 3.2 Replace CLI bootstrap in `src/commands/base.nim` so commands initialize the unified backend instead of Nim stdlib logging.
- [ ] 3.3 Convert parser, compiler, VM, stdlib, and extension-host diagnostic call sites to stable named loggers on the shared backend.

## 4. Tests & Validation
- [ ] 4.1 Add Nim tests for sink parsing, multi-target routing, append-only file behavior, legacy config compatibility, and logger `.to_s` construction.
- [ ] 4.2 Add runtime tests that exercise parser/compiler/vm/stdlib log call sites through the shared backend.
- [ ] 4.3 Run `nimble test` and focused runtime checks for representative logging paths.

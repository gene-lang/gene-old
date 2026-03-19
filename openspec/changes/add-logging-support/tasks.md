# Implementation Tasks: Unified Runtime Logging

## 1. Backend And Routing
- [x] 1.1 Refactor `logging_core` to store immutable routing config with root route, per-logger overrides, sink registry, and route cache.
- [x] 1.2 Introduce a shared log-event object carrying `thr`, `lvl`, `time`, `name`, and `value`, and pass it through sink fan-out once per emitted event.
- [x] 1.3 Implement sink backends for `console` and append-only `file`, with fan-out to multiple targets from one event.
- [x] 1.4 Ensure disabled logs return before event construction or message formatting, and that renderer output is reused across sinks that share the same format.

## 2. Configuration
- [x] 2.1 Extend `config/logging.gene` parsing to support `sinks`, sink `format`, and `targets`.
- [x] 2.2 Emit clear warnings for invalid sink definitions or unsupported sink formats without breaking valid sinks.

## 3. APIs And Adoption
- [x] 3.1 Keep `genex/logging/Logger` on the shared backend, make it accept any value via `.to_s`, and keep Nim-facing helpers for cheap runtime call sites.
- [x] 3.2 Replace CLI bootstrap in `src/commands/base.nim` so commands initialize the unified backend instead of Nim stdlib logging.
- [x] 3.3 Convert parser, compiler, VM, stdlib, and extension-host diagnostic call sites to stable named loggers on the shared backend.
- [x] 3.4 Add built-in renderers for `verbose`, `concise`, and `record` sink formats.

## 4. Tests & Validation
- [x] 4.1 Add Nim tests for sink parsing, sink format parsing, multi-target routing, append-only file behavior, and logger `.to_s` construction.
- [x] 4.2 Add runtime tests that exercise parser/compiler/vm/stdlib log call sites through the shared backend.
- [x] 4.3 Add focused tests for `verbose`, `concise`, and `record` renderer output and for shared-event reuse across multiple sinks.
- [ ] 4.4 Run `nimble test` and focused runtime checks for representative logging paths.

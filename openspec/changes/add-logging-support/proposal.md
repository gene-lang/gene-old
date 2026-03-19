# Proposal: Add Unified Runtime Logging

## Why

Gene now has three different diagnostic paths: Nim stdlib logging in commands, the newer `logging_core` backend used by `genex/logging`, and many direct `echo`/`stderr.writeLine` calls in parser/compiler/vm/stdlib and extensions. That fragmentation makes runtime diagnostics inconsistent, hard to route, and hard to disable cheaply in hot paths.

We need one logging system that is shared by parser, compiler, VM, stdlibs, and extensions, preserves a simple Gene logging API, and can write to multiple targets without forcing callers to care about the output backend.

## What Changes

- Expand the shared logging subsystem so the same backend is used by Gene code, Nim runtime code, and extension-host logging bridges.
- Add sink routing for `console` and `file`, including fan-out to multiple targets from a single log event.
- Keep hierarchical logger names and longest-prefix configuration, while introducing stable runtime logger namespaces such as `gene/parser`, `gene/compiler`, `gene/vm`, `gene/stdlib/*`, and `genex/*`.
- Extend `config/logging.gene` to configure sinks and per-logger target selection.
- Replace Nim stdlib logger bootstrap in CLI commands and convert runtime diagnostic call sites in parser/compiler/vm/stdlibs to the unified backend.
- Keep fixed text formatting for human-readable sinks, with sink-specific transport details handled by the backend.

## Impact

- Affected specs: logging (new)
- Affected code: `src/gene/logging_core.nim`, `src/genex/logging.nim`, `src/commands/base.nim`, parser/compiler/vm/stdlib runtime call sites, extension logging bridge, tests

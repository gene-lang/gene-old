## Context

Gene currently has a partial logging backend (`logging_core`) plus a Gene-facing `genex/logging` wrapper, but most runtime code still bypasses it. CLI commands still initialize Nim's stdlib logger, parser/compiler/vm/stdlib code frequently writes directly to stdout/stderr, and some extension paths already bridge into `logging_core`.

The new requirement is broader than the original console-only logger: parser, compiler, VM, stdlibs, and extensions must share the same logging backend; the backend must stay cheap on disabled paths; and a single log event may need to fan out to console and file sinks.

## Goals / Non-Goals

Goals:
- Provide a shared logging backend for both Gene and Nim callers.
- Use the same backend in parser, compiler, VM, stdlibs, `genex/*`, and extension host bridges.
- Configure logging via `config/logging.gene`.
- Support hierarchical logger names with level inheritance and per-logger sink routing.
- Support `console` and `file` sinks, including multi-target fan-out.
- Keep disabled log statements cheap enough for parser/compiler/vm code paths.
- Preserve a simple Gene API (`genex/logging/Logger`) and support the current simple config shape.

Non-Goals:
- Log rotation, retention policies, or compression.
- JSON/structured log serialization.
- Dynamic reloading or runtime config mutation.
- Replacing user-facing program output such as `println`, REPL prompts, or compiler command results.
- Replacing high-volume instruction tracing formats used by explicit `--trace` / execution-trace modes in this change.

## Decisions

### Logger Naming
- Logger names remain strings and continue to support Gene code names of the form `dir/file/ns/class`.
- Nim runtime code uses stable subsystem names:
  - `gene/parser`
  - `gene/compiler`
  - `gene/vm`
  - `gene/stdlib/<module>`
  - `genex/<module>`
- Gene logger construction accepts any value. The logger name is derived by calling `.to_s` on that value.
- Examples:
  - Explicit Gene string logger for module-level code → `examples/app.gene`
  - Explicit Gene string logger for a method in class `Todo` under namespace `Http` → `examples/app.gene/Http/Todo`
  - Parser warning emitted from Nim → `gene/parser`
  - HTTP extension startup message → `genex/http`

### Log Levels
- Levels are ordered by severity as:
  `ERROR > WARN > INFO > DEBUG > TRACE`
- A logger configured at `INFO` emits `ERROR`, `WARN`, and `INFO`, and suppresses `DEBUG` and `TRACE`.

### Hierarchical Resolution
- Configuration uses longest-prefix matching similar to log4j for both level and sink selection:
  - `examples` applies to everything under that directory.
  - `examples/app.gene` applies to the file.
  - `examples/app.gene/Http` applies to that namespace.
  - `examples/app.gene/Http/Todo` applies to that class.
  - `gene` applies to all runtime subsystems.
  - `gene/vm` applies to VM diagnostics specifically.
- The effective route is the most specific match; otherwise fallback to the root route.

### Config File Format (Gene)
- File location: `config/logging.gene` (root = current working directory).
- Example structure:
  ```gene
  {^level "INFO"
   ^sinks {
     ^console {^type "console" ^stream "stderr" ^color true}
     ^main_file {^type "file" ^path "logs/gene.log"}
   }
   ^targets ["console"]
   ^loggers {
     ^"gene" {^level "INFO" ^targets ["console" "main_file"]}
     ^"gene/vm" {^level "WARN"}
     ^"examples/app.gene" {^level "DEBUG" ^targets ["console" "main_file"]}
     ^"examples/app.gene/Http/Todo" {^level "ERROR"}
   }}
  ```
- Backward compatibility:
  - Existing configs that only define `level` and `loggers` continue to work.
  - When `sinks` are omitted, the backend creates an implicit console sink.
  - When `targets` are omitted, the logger inherits the root targets.

### Logging API
- Nim API: `log_message(level, name, message)` with shared backend and config.
- Nim runtime convenience helpers may be added for fast call sites, for example `log_enabled(level, name)` checks before building expensive messages.
- Gene API: `genex/logging/Logger` class with `.info`, `.warn`, `.error`, `.debug`, `.trace` methods.
  - `Logger` constructor accepts any value; the logger name comes from `value/.to_s`.
  - Typical usage: define `/logger = (new Logger self)` inside a class body or `(var logger (new Logger "gene/vm"))` for explicit subsystem names.
- Extension API: host logging callback continues to call the same backend, so C/Nim extensions participate in the same routing and filtering rules.
- All APIs share the same filtering, routing, and formatting pipeline.

### Sink Model
- A log event is created once, routed once, and then fanned out to zero or more sinks.
- Supported sink types:
  - `console`: stdout/stderr with optional ANSI color
  - `file`: append to an opened file handle
- File sinks are append-only.
- File and console sinks write the same rendered line format.
- A single event is formatted once for text sinks and reused across all selected text targets.

### Output Format
- Human-readable sinks use the fixed text format:
  `T00 LEVEL yy-mm-dd Wed HH:mm:ss.xxx logger message`

### Performance Strategy
- Disabled logs must return before formatting, color checks, or sink iteration.
- Configuration is parsed once into an immutable routing snapshot that runtime calls only read.
- Logger route lookup should support caching so hot logger names such as `gene/vm` or `gene/parser` do not re-run prefix scans on every event.
- Sink fan-out happens only after a log passes level filtering.
- File sinks keep their file handles open instead of reopening per event.

### Runtime Adoption
- Parser, compiler, VM, stdlibs, and `genex/*` modules should stop using Nim stdlib logging or ad hoc `echo` calls for diagnostics that are logically logs.
- CLI `setup_logger` should initialize the unified backend instead of Nim's `logging` module.
- Explicit command output, REPL prompts, and end-user program output remain direct stdout/stderr writes.

## Risks / Trade-offs

- Converting all runtime diagnostics at once is broad; the first pass should prioritize parser/compiler/vm/stdlib and extension boot paths, then clean up remaining leaf modules.
- Route caching adds state that must stay thread-safe; because config is parsed once and treated as immutable for the process lifetime, the implementation can keep cache behavior simple.
- High-volume execution tracing is intentionally deferred to avoid slowing the dispatch loop with a general-purpose log abstraction.

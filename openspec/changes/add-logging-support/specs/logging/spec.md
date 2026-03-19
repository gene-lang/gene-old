## ADDED Requirements

### Requirement: Logging Configuration File
The system SHALL load logging configuration from `config/logging.gene` rooted at the current working directory when the file exists.

#### Scenario: Missing config uses defaults
- **WHEN** `config/logging.gene` is absent
- **THEN** logging uses the default root level `INFO` and console output is enabled

### Requirement: Hierarchical Logger Levels
The system SHALL resolve logger routes using longest-prefix matching on logger names, including Gene code names (`dir/file/ns/class`) and runtime subsystem names (`gene/parser`, `gene/compiler`, `gene/vm`, `gene/stdlib/*`, `genex/*`).

#### Scenario: Specific logger overrides directory level
- **WHEN** the config sets `examples` to `WARN` and `examples/app.gene/Http/Todo` to `ERROR`
- **AND** a log is emitted with logger name `examples/app.gene/Http/Todo`
- **THEN** the effective level is `ERROR`

#### Scenario: Runtime subsystem inherits root route
- **WHEN** the config sets `gene` to `INFO` and `gene/vm` is not overridden
- **AND** a log is emitted with logger name `gene/vm`
- **THEN** the effective level is inherited from `gene`

### Requirement: Log Level Ordering
The system SHALL order log levels by severity as `ERROR > WARN > INFO > DEBUG > TRACE`.

#### Scenario: Info threshold suppresses debug
- **WHEN** a logger is configured at `INFO`
- **AND** it emits both `INFO` and `DEBUG` events
- **THEN** the `INFO` event is emitted
- **AND** the `DEBUG` event is suppressed

### Requirement: Multiple Sink Targets
The system SHALL support routing a single log event to one or more configured targets of type `console` and `file`.

#### Scenario: Single event fans out to multiple targets
- **WHEN** the root route targets both `console` and `file`
- **AND** a logger emits one `INFO` event
- **THEN** the same event is written to both configured sinks

#### Scenario: File sink appends output
- **WHEN** a file sink is configured for `logs/gene.log`
- **AND** two log events are emitted in sequence
- **THEN** both events are appended to the file in emission order

### Requirement: Structured Log Event
The system SHALL construct one shared log event for each emitted message after level filtering passes and SHALL route that event through the selected sinks.

#### Scenario: Event exposes stable fields
- **WHEN** a `DEBUG` log is emitted from logger `src/tools.gene` on thread `0`
- **THEN** the routed event exposes fields equivalent to `thr`, `lvl`, `time`, `name`, and `value`
- **AND** `lvl` is `DEBUG`
- **AND** `name` is `src/tools.gene`

#### Scenario: Disabled log does not allocate event
- **WHEN** logger `gene/compiler` is configured at `INFO`
- **AND** compiler code attempts to emit a `DEBUG` log
- **THEN** the runtime can suppress the log before constructing the routed event object

### Requirement: Sink-Specific Output Formats
The system SHALL allow each sink to select its own built-in output format independently of the sink transport.

#### Scenario: Verbose text format includes thread and logger
- **WHEN** a log at level `INFO` is emitted with logger name `examples/app.gene`
- **AND** the sink format is `verbose`
- **THEN** the output uses the form `T00 LEVEL yy-mm-dd Wed HH:mm:ss.xxx logger message`
- **AND** the output contains the `INFO` level and `examples/app.gene` logger name

#### Scenario: Concise text format omits thread label
- **WHEN** a log at level `DEBUG` is emitted with logger name `src/tools.gene`
- **AND** the sink format is `concise`
- **THEN** the output uses the form `LEVEL MM-dd HH:mm:ss.xxx logger message`
- **AND** the output does not include the `T00` thread prefix

#### Scenario: Record format writes structured Gene map
- **WHEN** a log at level `DEBUG` is emitted with logger name `src/tools.gene`
- **AND** the sink format is `record`
- **THEN** the sink writes one append-only Gene map record per event
- **AND** the record contains stable keys `thr`, `lvl`, `time`, `name`, and `value`

### Requirement: Sink Format Configuration
The system SHALL allow sink definitions in `config/logging.gene` to choose a built-in `format`.

#### Scenario: Omitted format uses verbose output
- **WHEN** a sink declaration omits `^format`
- **THEN** that sink uses `verbose` formatting by default

#### Scenario: Invalid format warns without breaking valid sinks
- **WHEN** one sink declares an unsupported `^format`
- **THEN** configuration loading warns about that sink
- **AND** valid sink declarations remain active

### Requirement: Gene Logging API
The system SHALL provide a `genex/logging/Logger` class with level methods whose constructor accepts any value and derives the logger name from `value/.to_s`.

#### Scenario: Logger constructed from a string
- **WHEN** code creates `(new Logger "gene/vm")`
- **THEN** emitted log events use `gene/vm` as the logger name

#### Scenario: Logger constructed from any value
- **WHEN** code creates `(new Logger value)`
- **THEN** the logger name is derived from `value/.to_s`

### Requirement: Unified Runtime Backend
The system SHALL route diagnostics from parser, compiler, VM, stdlibs, and extension host callbacks through the same logging backend used by `genex/logging`.

#### Scenario: Parser diagnostic uses shared backend
- **WHEN** parser code emits a warning through the runtime logger
- **THEN** the event is filtered, formatted, and routed by the shared logging backend

#### Scenario: Extension host callback participates in routing
- **WHEN** an extension emits a log via the host logging callback
- **THEN** the event uses the same level filtering and sink routing as core runtime logs

### Requirement: Cheap Disabled Logs
The system SHALL avoid message formatting and sink writes for log events that are disabled by effective logger level.

#### Scenario: Disabled debug log skips formatting
- **WHEN** logger `gene/compiler` is configured at `INFO`
- **AND** compiler code attempts to emit a `DEBUG` log with an expensive formatted message
- **THEN** the runtime can determine the log is disabled before performing sink output

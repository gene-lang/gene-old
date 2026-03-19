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

### Requirement: Human-Readable Output Format
The system SHALL emit human-readable logs in the fixed format:
`T00 LEVEL yy-mm-dd Wed HH:mm:ss.xxx logger message`.

#### Scenario: Format includes level and logger name
- **WHEN** a log at level `INFO` is emitted with logger name `examples/app.gene`
- **THEN** the output contains the `INFO` level and `examples/app.gene` logger name in the fixed format

### Requirement: Backward-Compatible Configuration
The system SHALL continue accepting the existing logging config shape that defines only a root `level` and `loggers`.

#### Scenario: Legacy config keeps implicit console output
- **WHEN** a config file defines `level` and `loggers` but no sink declarations
- **THEN** the backend creates an implicit console target
- **AND** logger level resolution behaves as before

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

## ADDED Requirements

### Requirement: Apps SHALL classify persisted data by storage tier

Gene SHALL provide storage capabilities for Config, Hot State, Keyed Records,
Archive, Append-Only Log, Secrets, and Ephemeral data, and an app SHALL assign
each persisted data domain to the capabilities it adopts based on access
pattern, mutation behavior, and sensitivity.

#### Scenario: New durable data is assigned to a tier

- **WHEN** a new app data domain is introduced that survives restart
- **THEN** its intended storage tier SHALL be explicit in design and spec
- **AND** its load/save behavior SHALL match that tier's contract

### Requirement: Apps SHALL choose their own home-directory layout for adopted storage capabilities

Gene SHALL not require every app to use one fixed directory schema for all
storage capabilities. An app SHALL choose which storage capabilities it uses
and how it maps them into its own home directory.

#### Scenario: GeneClaw chooses its own directory structure

- **WHEN** GeneClaw adopts the shared storage capabilities
- **THEN** it MAY map them into app-specific directories such as `config/`,
  `state/`, `sessions/`, `scheduler/jobs/`, `scheduler/runs/`, `assets/`,
  `logs/`, `archive/`, and `tmp/`
- **AND** that app-specific mapping SHALL remain compatible with the capability
  contracts for the data stored there

### Requirement: Config SHALL use human-authored text files

An app's human-authored durable configuration SHALL use text `.gene` files and
SHALL be loaded eagerly at startup from whatever config root the app defines.

#### Scenario: Config is loaded and edited as authored text

- **WHEN** an app starts and reads durable configuration
- **THEN** it SHALL load config from the app-defined config root
- **AND** that config SHALL remain human-inspectable and human-editable as
  text `.gene`

### Requirement: Hot runtime state SHALL use eagerly loaded small text state

An app SHALL store small, always-live runtime state such as the system prompt,
runtime flags, and hotswap state as eagerly loaded text `.gene` persistence in
the app-defined hot-state root and SHALL save it on logical change.

#### Scenario: Hot state is restored eagerly at startup

- **WHEN** an app initializes durable runtime state
- **THEN** it SHALL eagerly load hot-state data from the app-defined hot-state
  root
- **AND** that startup path SHALL not require scanning cold keyed-record files

### Requirement: Apps SHALL derive keyed-record indexes instead of persisting authoritative registries

Indexes such as the active session list, job list, or document catalog SHALL
be derived from the keyed-record directories at startup rather than stored as
separate authoritative registries.

#### Scenario: Startup rebuilds a session index from record files

- **WHEN** an app initializes a keyed collection such as sessions
- **THEN** it SHALL derive its in-memory index by scanning the collection's
  directory contents
- **AND** it SHALL not depend on a separately persisted registry file as the
  source of truth

### Requirement: Apps SHALL store mutable durable records as keyed per-entry text files

An app SHALL store mutable durable collections as independently addressable
keyed records using one text `.gene` file per record.

GeneClaw, as the first adopter, MAY map this rule to collection roots such as
`sessions/`, `scheduler/jobs/`, and `scheduler/runs/`.

#### Scenario: A session is loaded lazily and saved independently

- **WHEN** an app accesses a specific keyed record such as a session
- **THEN** it SHALL load that session record on first access rather than
  eagerly loading every session
- **AND** a later save for that session SHALL rewrite only that session record

#### Scenario: Updating one keyed record does not require sibling rewrites

- **WHEN** an app updates one scheduler job, run record, or document record
- **THEN** it SHALL persist only the affected record file
- **AND** it SHALL not require rewriting unrelated siblings in the same
  collection

### Requirement: Apps SHALL keep append-only operational logs separate from mutable records

An app SHALL store operational logs such as tool audit, request/response logs,
and error logs as append-only data in the app-defined log root and SHALL not
use that log tier as the canonical storage format for sessions, runs,
scheduler jobs, or documents.

#### Scenario: Audit data is appended without record mutation semantics

- **WHEN** an app writes an operational audit or event entry
- **THEN** it SHALL append that entry to a date-partitioned log under
  the app-defined log root
- **AND** that append path SHALL remain distinct from keyed-record update paths

### Requirement: Apps SHALL keep archived data cold and excluded from startup load

Archived sessions, runs, and similar cold data SHALL live under
the app-defined archive root and SHALL not be loaded during normal startup.

#### Scenario: Startup ignores archived data

- **WHEN** an app starts with archived data present
- **THEN** it SHALL not eagerly load archived data into active runtime state
- **AND** archived data SHALL only be loaded on explicit access

### Requirement: Apps SHALL be able to define asset and scratch directories outside keyed-record storage

Gene SHALL allow an app to define app-specific directories for uploaded
assets, generated assets, and temporary working files as long as those
directories do not weaken the durability or secrecy guarantees of the storage
capabilities in use.

#### Scenario: GeneClaw uses uploaded, generated, and tmp directories

- **WHEN** GeneClaw stores uploaded assets, generated outputs, or scratch files
- **THEN** it SHALL be allowed to place them under app-specific roots such as
  `assets/uploaded/<session-id>/`, `assets/generated/<session-id>/`, and
  `tmp/`
- **AND** those directories SHALL remain distinct from keyed-record and
  append-only log semantics

### Requirement: Apps SHALL never durably persist secrets in expanded form

Secrets SHALL be sourced externally, referenced durably only by placeholder or
redacted form, and never written to disk as expanded plaintext values.

#### Scenario: Placeholder-backed config remains unexpanded on disk

- **WHEN** an app resolves a secret-bearing config or prompt value into
  runtime memory
- **THEN** the durable on-disk form SHALL remain the authored placeholder or
  other non-secret representation
- **AND** public config or log surfaces SHALL redact the secret value

### Requirement: Apps SHALL not durably persist ephemeral runtime data

An app SHALL not write request-scoped context, temporary caches, in-flight
tool state, and similar ephemeral runtime values to durable storage merely for
completeness.

#### Scenario: Request-scoped runtime state is discarded on restart

- **WHEN** an app restarts after handling in-flight request work
- **THEN** ephemeral request-scoped state MAY be lost
- **AND** the system SHALL not treat that loss as a durability failure

## MODIFIED Requirements

### Requirement: GeneClaw SHALL maintain a rebuildable derived search index

GeneClaw SHALL maintain a derived search index for `MEMORY.md` under
`GENECLAW_HOME/memory/.index.gene`, and that index SHALL be rebuildable from
the markdown source. The index SHALL store local keyword-search metadata, and
it MAY additionally store embedding vectors when embedding credentials are
configured.

#### Scenario: memory_search detects stale index state

- **WHEN** `memory_search` runs and the stored `file_hash` does not match the
  current `MEMORY.md`
- **THEN** GeneClaw SHALL rebuild the derived index before scoring results
- **AND** the rebuilt index SHALL correspond to the current markdown content

#### Scenario: search index is usable without embedding credentials

- **WHEN** GeneClaw rebuilds `.index.gene` without usable embedding
  credentials
- **THEN** it SHALL still persist keyword-search metadata derived from
  `MEMORY.md`
- **AND** it SHALL not require embedding vectors for the index to be usable

### Requirement: GeneClaw SHALL expose long-term memory tools

GeneClaw SHALL expose `memory_read`, `memory_write`, and `memory_search` as
agent tools for interacting with long-term memory.

#### Scenario: memory_read returns section markdown

- **WHEN** the agent calls `memory_read` with a section name
- **THEN** GeneClaw SHALL return the matching `##` section from `MEMORY.md`
- **AND** it SHALL not require `.index.gene` to satisfy that read

#### Scenario: memory_search falls back without embedding credentials

- **WHEN** the agent calls `memory_search` without usable OpenAI embedding
  credentials
- **THEN** GeneClaw SHALL return keyword-search results derived from
  `MEMORY.md`
- **AND** `memory_read` and `memory_write` SHALL remain usable on markdown

#### Scenario: memory_search does not treat OpenAI OAuth token as embedding key

- **WHEN** the runtime has an OpenAI OAuth token for chat requests but no
  `OPENAI_EMBEDDING_API_KEY` or `OPENAI_API_KEY`
- **THEN** `memory_search` SHALL remain available through keyword search
- **AND** it SHALL not attempt to treat the OAuth token as an embedding API key

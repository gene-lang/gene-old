## Context

GeneClaw already persists long-term memory in `MEMORY.md` and rebuilds a
derived `.index.gene` file, but the current implementation only stores
embedding vectors. That makes search unavailable in local-only deployments and
causes tests to encode an unnecessary credential dependency.

The reviewed redesign keeps `MEMORY.md` as the source of truth while widening
`.index.gene` into a general search index:

- Keyword metadata (`tokens`, `token_counts`, `doc_freq`) is always computed.
- Embeddings remain optional and are only stored when an embedding API key is
  available.

## Goals / Non-Goals

- Goals:
  - Make `memory_search` usable without external credentials.
  - Keep tool schemas stable.
  - Reuse the existing memory store/module layout.
  - Preserve embedding-based search as an upgrade path.
- Non-Goals:
  - Cross-process locking or shared index ownership.
  - A new storage format outside `MEMORY.md` and `.index.gene`.
  - Changing `memory_write` or `memory_read` semantics.

## Decisions

- Decision: `.index.gene` becomes a general derived search index.
  - Rationale: keyword metadata and embeddings are both derived from the same
    markdown source, so they should live in one rebuildable file.

- Decision: keyword metadata is always computed during index rebuild.
  - Rationale: local tokenization is cheap and makes search available in every
    deployment mode.

- Decision: embeddings remain optional and only use
  `CONFIG/llm/openai/embedding_api_key`.
  - Rationale: keeps current auth boundaries intact and avoids treating OAuth
    chat tokens as embedding credentials.

- Decision: `memory_search` prefers embeddings when available, with keyword
  fallback when they are not.
  - Rationale: preserves higher-quality semantic retrieval when configured
    while removing the current hard failure path.

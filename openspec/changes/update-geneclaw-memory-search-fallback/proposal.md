## Why

GeneClaw's shipped long-term memory search is embedding-only. When
`CONFIG/llm/openai/embedding_api_key` is not configured, `memory_search`
returns an explicit unavailable error even though `MEMORY.md` already exists
and can be searched locally.

The reviewed redesign in
`example-projects/geneclaw/docs/memory_system.md` changes that contract:
keyword/BM25 search should work without external dependencies, while
embeddings become an optional upgrade path.

## What Changes

- Change long-term memory indexing from embedding-only to search-mode aware:
  keyword metadata is always derived locally, embeddings are optional.
- Change `memory_search` so it falls back to keyword/BM25 search when no
  embedding credentials are configured.
- Preserve the existing tool wrapper schemas for `memory_read`,
  `memory_write`, and `memory_search`.
- Keep OpenAI embedding credentials as an optional enhancement path and do not
  treat OAuth chat tokens as embedding credentials.
- Update design docs and tests to reflect keyword fallback and optional hybrid
  search.

## Impact

- Affected specs:
  - `geneclaw-memory-system`
- Affected code:
  - `example-projects/geneclaw/src/memory_store.gene`
  - `example-projects/geneclaw/src/tools/memory.gene`
  - `example-projects/geneclaw/docs/memory_system.md`
  - `example-projects/geneclaw/tests/test_memory_store.gene`
  - `example-projects/geneclaw/tests/test_memory_search_oauth_only.gene`
  - `example-projects/geneclaw/tests/test_memory_tools.gene`
- Breaking behavior:
  - `memory_search` will no longer error merely because embedding credentials
    are missing; it will return keyword-search results instead.

## 1. Implementation

- [x] 1.1 Extend `memory_store.gene` index building to derive keyword search
      metadata from `MEMORY.md` and store it in `.index.gene`.
- [x] 1.2 Implement keyword/BM25 search in `memory_store.gene`.
- [x] 1.3 Change `memory_search` to use embedding search when credentials are
      available and keyword search otherwise.
- [x] 1.4 Update `memory_write`/index refresh behavior so keyword metadata is
      rebuilt without requiring embedding credentials.
- [x] 1.5 Update the `memory_search` tool description and memory design docs to
      reflect the new fallback behavior.
- [x] 1.6 Update GeneClaw tests to cover keyword fallback, no-credential
      search, and OAuth-only behavior.

## 2. Validation

- [x] 2.1 Run focused GeneClaw memory tests.
- [x] 2.2 Run `openspec validate update-geneclaw-memory-search-fallback --strict`.

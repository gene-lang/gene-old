# GeneClaw Memory System Design

> **Status:** V1 keyword fallback implemented — updated 2026-03-19.
>
> **Current state:** The shipped implementation (`memory_store.gene`,
> `tools/memory.gene`) supports keyword/BM25 search without external
> dependencies. When `CONFIG/llm/openai/embedding_api_key` is set, the derived
> index may also include embeddings and `memory_search` prefers that path.
>
> **This doc records** the shipped v1 design and the future v2 direction for a
> blended keyword + embedding search mode.

## Overview

A two-tier memory system for GeneClaw: **session memory** (per-conversation working context) and **long-term memory** (durable knowledge with search). Markdown is the source of truth.

- **Current v1:** Keyword/BM25 search works without external dependencies
- **Current enhancement:** Embedding search is used when credentials are available
- **Future v2:** Hybrid search (keyword + embeddings blended) when credentials are available

This design assumes one running GeneClaw instance serves one workspace and one agent.

## Operating Model

- `GENECLAW_HOME/memory/*` is owned by the running GeneClaw process.
- Users change long-term memory by telling the agent what to remember, correct, or forget.
- Direct edits to `MEMORY.md` by users or third-party programs are unsupported in normal operation.
- `MEMORY.md` is canonical; index files are disposable derived state.
- V1 assumes one owning GeneClaw process.

## Architecture

```
┌─────────────────────────────────────┐
│           System Prompt             │  ← Injected every turn
│  (persona, rules, tool instructions)│
└─────────────────┬───────────────────┘
                  │
┌─────────────────▼───────────────────┐
│         Long-Term Memory            │  ← Global durable memory for this instance
│  GENECLAW_HOME/memory/MEMORY.md     │  ← Source of truth (markdown)
│  GENECLAW_HOME/memory/.index.gene   │  ← Derived search index (auto-generated)
└─────────────────┬───────────────────┘
                  │
┌─────────────────▼───────────────────┐
│         Session Memory              │  ← Per-conversation (exists today)
│  GENECLAW_HOME/sessions/<id>/       │
│  {role, content, meta, created_at}  │
└─────────────────────────────────────┘
```

## Layer 1: Session Memory (existing)

Already implemented in `workspace_state.gene`. No changes needed.

- Scoped to a single conversation (Slack thread, API session, etc.)
- Stores message history as `{role, content, meta, created_at_ms}` entries
- Loaded on session start, saved on each interaction
- Ephemeral — not searchable across sessions

## Layer 2: Long-Term Memory

### Storage

```
GENECLAW_HOME/memory/
├── MEMORY.md          # Source of truth — human-readable, agent-owned
└── .index.gene        # Derived search index (auto-generated, rebuildable)
```

**MEMORY.md** is a plain markdown file organized by headings:

```markdown
## User Preferences
- Prefers concise responses
- Bilingual: English and Chinese

## Projects
### Gene Language
- Architecture improvement branch active
- Key insight: gene-old has better type system than gene-new

## Decisions
### 2026-03-18 — Memory system design
- Two tiers: session + long-term
- Markdown source of truth with keyword search
```

Rules:
- Agent reads and writes through `memory_read`, `memory_write`, and `memory_search`
- Users request memory changes through the agent
- Organized by `##` sections for chunking
- `.index.gene` is derived state; rebuilt automatically when stale

### Chunking

Split MEMORY.md into chunks at `##` heading boundaries:

```gene
(fn chunk_markdown [text]
  # Split on lines starting with "## "
  # Each chunk = heading + all content until next ## or EOF
  # Nested ### stays within parent ## chunk
  # Content before first ## is chunk 0 (preamble)
  (var chunks [])
  (var lines (text .split "\n"))
  (var current_heading "")
  (var current_lines [])
  (var chunk_id 0)
  (var start_line 0)

  (for i in (range 0 lines/.size)
    (var line (lines .at i))
    (if (line .starts_with? "## ")
      # Flush previous chunk
      (if current_lines/.not_empty?
        (var chunk_text (current_lines .join "\n"))
        (chunks .append {
          ^id chunk_id
          ^heading current_heading
          ^text chunk_text
          ^start_line start_line
          ^end_line (i - 1)
          ^hash (gene/crypto/sha256 chunk_text)
        })
        (chunk_id += 1)
      )
      (current_heading = ((line .slice 3) .trim))
      (current_lines = [line])
      (start_line = i)
    else
      (current_lines .append line)
    )
  )

  # Flush final chunk
  (if current_lines/.not_empty?
    (var chunk_text (current_lines .join "\n"))
    (chunks .append {
      ^id chunk_id
      ^heading current_heading
      ^text chunk_text
      ^start_line start_line
      ^end_line (lines/.size - 1)
      ^hash (gene/crypto/sha256 chunk_text)
    })
  )

  chunks
)
```

Design choices:
- Chunk boundary: `##` (h2) headings — balances granularity vs context
- Nested `###` stays within parent `##` chunk
- Content before first `##` is chunk 0 (preamble)
- Each chunk gets a SHA-256 hash for change detection
- Typical chunk: 100-500 tokens

## V1: Keyword Search (Pure Gene)

No external dependencies. Works immediately.

### Tokenization

```gene
(var STOPWORDS #{"the" "a" "an" "is" "are" "was" "were" "be" "been"
                 "has" "have" "had" "do" "does" "did" "will" "would"
                 "can" "could" "should" "may" "might" "must" "shall"
                 "to" "of" "in" "for" "on" "with" "at" "by" "from"
                 "and" "or" "not" "but" "if" "then" "so" "that" "this"
                 "it" "its" "i" "my" "me" "we" "our" "you" "your"
                 "he" "she" "they" "them" "his" "her" "their"})

(fn tokenize [text]
  # Lowercase, split on non-alphanumeric, remove stopwords and short tokens
  (var words ((text .downcase) .split /[^a-z0-9]+/))
  (words .filter (fn [w]
    (and (w/.length > 2) (not (STOPWORDS .include? w)))
  ))
)
```

### Index Structure

`.index.gene` stores pre-tokenized chunks for fast search:

```gene
{
  ^version 1
  ^file_hash "<sha256 of full MEMORY.md>"
  ^chunks [
    {
      ^id 0
      ^heading "User Preferences"
      ^text "## User Preferences\n- Prefers concise responses\n..."
      ^hash "<sha256 of chunk text>"
      ^start_line 0
      ^end_line 5
      ^tokens ["prefers" "concise" "responses" "bilingual" "english" "chinese"]
      ^token_counts {"prefers" 1 "concise" 1 ...}  # term frequency
    }
    ...
  ]
  ^doc_freq {"prefers" 1 "concise" 1 "english" 2 ...}  # document frequency across all chunks
  ^total_chunks 5
}
```

### BM25 Scoring

```gene
# BM25 parameters
(var BM25_K1 1.2)
(var BM25_B 0.75)

(fn bm25_score [query_tokens chunk doc_freq total_chunks avg_doc_len]
  # Standard BM25 scoring
  (var score 0.0)
  (var doc_len chunk/tokens/.size)

  (for qt in query_tokens
    (var tf ((chunk/token_counts .get qt 0) .to_f))
    (if (tf > 0)
      (var df ((doc_freq .get qt 0) .to_f))
      # IDF: log((N - df + 0.5) / (df + 0.5) + 1)
      (var idf (math/log (((total_chunks - df + 0.5) / (df + 0.5)) + 1.0)))
      # TF component: (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl/avgdl))
      (var tf_norm (/ (* tf (BM25_K1 + 1.0))
                      (+ tf (* BM25_K1 (+ (- 1.0 BM25_B) (* BM25_B (/ doc_len avg_doc_len)))))))
      (score += (* idf tf_norm))
    )
  )
  score
)

(fn search_keyword [query chunks_index ^limit 5 ^threshold 0.1]
  (var query_tokens (tokenize query))
  (if query_tokens/.empty?
    (return [])
  )

  (var doc_freq chunks_index/doc_freq)
  (var total_chunks chunks_index/total_chunks)
  (var chunks chunks_index/chunks)

  # Calculate average document length
  (var total_tokens 0)
  (for c in chunks (total_tokens += c/tokens/.size))
  (var avg_doc_len (if (total_chunks > 0) (/ total_tokens/.to_f total_chunks) else 1.0))

  # Score each chunk
  (var scored [])
  (for chunk in chunks
    (var score (bm25_score query_tokens chunk doc_freq total_chunks avg_doc_len))
    (if (score > threshold)
      (scored .append {
        ^heading chunk/heading
        ^text chunk/text
        ^score score
        ^start_line chunk/start_line
        ^end_line chunk/end_line
      })
    )
  )

  # Sort by score descending, take top N
  (scored .sort_by (fn [a b] (b/score - a/score)))
  (scored .take limit)
)
```

### Index Sync Pipeline

```
memory_write / memory_search
  → acquire process-local memory lock
  → load current MEMORY.md, compute file hash
  → compare against .index.gene/file_hash
  → if stale or missing:
      → re-chunk markdown
      → tokenize each chunk, compute token_counts
      → compute doc_freq across all chunks
      → write .index.gene atomically (tmp + rename)
  → perform search / return results
  → release lock
```

- Only re-indexes when MEMORY.md changes (hash comparison)
- No API calls needed — pure computation
- Fast: tokenizing + indexing 100 chunks takes <10ms

## V2: Hybrid Search (Optional Upgrade)

When an embedding provider is configured, `.index.gene` additionally stores
embedding vectors per chunk, enabling semantic search.

### Additional fields in `.index.gene` (v2)

```gene
{
  ^version 2
  ^embedding_model "text-embedding-3-small"
  ^dimensions 1536
  ^chunks [
    {
      # ... all v1 fields ...
      ^vector [0.0123 -0.0456 ...]  # 1536-dim float array (only if v2)
    }
  ]
}
```

### Cosine Similarity

```gene
(fn cosine_similarity [a b]
  (var dot 0.0)
  (var norm_a 0.0)
  (var norm_b 0.0)
  (for i in (range 0 a/.size)
    (dot += (a/i * b/i))
    (norm_a += (a/i * a/i))
    (norm_b += (b/i * b/i))
  )
  (dot / ((math/sqrt norm_a) * (math/sqrt norm_b)))
)
```

### Hybrid Scoring

```gene
(fn search_hybrid [query chunks_index ^limit 5 ^keyword_weight 0.3 ^vector_weight 0.7]
  # Get keyword scores (normalized to 0-1)
  (var keyword_results (search_keyword query chunks_index ^limit chunks_index/total_chunks))
  (var max_kw_score (if keyword_results/.not_empty? (keyword_results .at 0)/score else 1.0))

  # Get embedding scores
  (var query_vector (embed_text query))  # OpenAI API call
  (var results [])

  (for chunk in chunks_index/chunks
    (if chunk/vector
      (var vec_score (cosine_similarity query_vector chunk/vector))
      (var kw_score 0.0)
      # Find matching keyword score
      (for kr in keyword_results
        (if (kr/heading == chunk/heading)
          (kw_score = (kr/score / max_kw_score))
        )
      )
      (var combined (+ (* keyword_weight kw_score) (* vector_weight vec_score)))
      (results .append {
        ^heading chunk/heading
        ^text chunk/text
        ^score combined
        ^keyword_score kw_score
        ^vector_score vec_score
        ^start_line chunk/start_line
        ^end_line chunk/end_line
      })
    )
  )

  (results .sort_by (fn [a b] (b/score - a/score)))
  (results .take limit)
)
```

### V2 Sync Pipeline (extends V1)

```
Same as V1, plus:
  → for each chunk:
      → if chunk hash unchanged AND vector exists: keep existing vector
      → if chunk is new/modified: call embedding API
  → store vectors in .index.gene alongside tokens
```

This minimizes API calls — only modified chunks get re-embedded.

### Embedding Provider

- **Model:** `text-embedding-3-small` (OpenAI) — hardcoded in `memory_store.gene:8`
- **1536 dimensions**, ~$0.02 per 1M tokens
- **Auth:** `CONFIG/llm/openai/embedding_api_key` (canonical path)
  - Config schema falls back from `OPENAI_EMBEDDING_API_KEY` env var
    to `OPENAI_API_KEY` if the dedicated key is not set (see `config.gene:38`)
- **Fallback:** If no embedding credentials, `memory_search` uses keyword-only mode
  (currently it returns an error — this doc proposes the fallback)

## Retrieval Model

Long-term memory is tool-driven, not eagerly injected into every turn.

- The system prompt teaches the agent when to use memory tools.
- `memory_search` — find relevant chunks (keyword or hybrid)
- `memory_read` — exact section retrieval
- `memory_write` — persist new knowledge
- No special startup injection in `agent.gene` is required for v1.

## Agent Tools

Tool wrappers are in `tools/memory.gene`. The return schemas below match
the shipped implementations — no changes proposed.

### memory_search

```gene
# Search long-term memory
# Input:  {^query "what are user's preferences?" ^limit 5 ^threshold 0.3}
# Output: {^results [{^heading "..." ^text "..." ^score 0.89} ...] ^count 2}
#   (see tools/memory.gene:52-53)
#
# Current: keyword/BM25 fallback is always available
# Current enhancement: embedding search is preferred when credentials are available
# Future: blend keyword + embeddings into one hybrid score
#
# Flow:
# 1. Load MEMORY.md, compute file hash
# 2. Ensure .index.gene exists and is current, rebuild if needed
# 3. If embedding credentials are available and vectors exist: cosine similarity
# 4. Otherwise: keyword/BM25 search
# 5. Return top-k matches above threshold
```

### memory_read

```gene
# Read canonical MEMORY.md or a specific section
# Input:  {^section "Projects"}       — returns that ## section
# Input:  {}                          — returns full file
# Output: {^content "..." ^section "Projects"}
#   (see tools/memory.gene:18-19)
#
# Notes:
# - Reads MEMORY.md directly, no index needed
# - No changes proposed
```

### memory_write

```gene
# Write to MEMORY.md — append or replace a section
# Input:  {^section "Decisions" ^content "### 2026-03-18 — New decision\n..." ^mode "append"}
# Modes:
#   "append"  — add content to end of section (create section if missing)
#   "replace" — replace entire section content
#   "create"  — create new section (error if exists)
# Output: {^section "Decisions" ^mode "append" ^file_hash "..." ^reindexed true ^warning ""}
#   (see tools/memory.gene:37-43)
#
# Side effects:
# - Serialized through process-local memory lock
# - Writes MEMORY.md atomically via tmp + rename
# - Rebuilds keyword metadata in `.index.gene`
# - Adds or refreshes embeddings when credentials are available
# - No changes proposed to this tool's contract
```

## Consistency Rules

- `memory_write` holds a process-local lock; overlapping writes are serialized.
- `memory_search` checks `.index.gene/file_hash` against current MEMORY.md before using the index.
- If `.index.gene` is missing or stale, it's rebuilt under the lock before answering.
- Cross-process access is unsupported in v1.

## System Prompt Additions

```
## Memory

You have a long-term memory stored in MEMORY.md. Use it wisely:

- **Before answering** questions about past context, decisions, or preferences:
  call memory_search to check what you know.
- **After important interactions** (decisions made, new facts learned,
  user preferences expressed): call memory_write to store them.
- **Be selective** — store what's worth recalling later. Skip ephemeral details.
- **Organize by topic** — use clear ## headings when creating new sections.
```

## Performance Characteristics (V1)

At GeneClaw's expected scale:

| Metric | Value |
|--------|-------|
| Chunks (typical) | 20-100 |
| Tokens per chunk | 50-500 |
| Index file size | ~50-200 KB |
| Search latency | <5ms (in-process tokenize + score) |
| Reindex latency | <50ms (no API calls) |
| Memory usage | Entire index loaded (~200KB) |

For comparison, V2 hybrid search adds:
- ~2-5 MB for embedding vectors (100 chunks × 1536 dims × 4 bytes)
- ~200ms per API call for query embedding
- ~200ms per API call per new/modified chunk

## Implementation Order

### Adding keyword fallback to existing code

The memory system already exists in:
- `src/memory_store.gene` (688 lines) — chunker, embedding, index, read/write/search
- `src/tools/memory.gene` (63 lines) — tool registration wrapper

Changes needed (all in `memory_store.gene` unless noted):

1. **Add tokenizer** — `tokenize` function (lowercase + split + stopword removal)
2. **Add BM25 scorer** — `bm25_score` function with IDF weighting
3. **Add keyword search** — `search_keyword` function using tokenized chunks
4. **Extend index format** — add `tokens`, `token_counts`, `doc_freq` fields
   alongside existing `vector` field in `.index.gene`
5. **Modify `memory_search`** — when `embedding_credentials_available?` is false,
   fall back to keyword search instead of returning an error
6. **Modify index builder** — always compute tokens/doc_freq (cheap);
   only compute embeddings when credentials available
7. **Update tool description** — change "semantic similarity" to
   "search" in `tools/memory.gene:48` since it now supports both modes

### Optional: hybrid mode
8. **Add hybrid scorer** — blend BM25 + cosine when both are available
9. **Update `memory_search`** — use hybrid when embeddings present

## File Changes

```
src/
├── memory_store.gene    # MODIFY — add tokenizer, BM25, keyword fallback
└── tools/memory.gene    # MODIFY — update tool description

GENECLAW_HOME/
└── memory/
    └── .index.gene      # MODIFY — add tokens/token_counts/doc_freq fields
```

## Future Enhancements (not in v1/v2)

- **Multiple memory files** — split by topic when MEMORY.md gets large
- **Session-to-memory promotion** — auto-extract key facts from session on close
- **Auto-compaction** — summarize old sections to keep file manageable
- **Memory expiry** — age out stale entries
- **Cross-session search** — search across session histories (not just MEMORY.md)

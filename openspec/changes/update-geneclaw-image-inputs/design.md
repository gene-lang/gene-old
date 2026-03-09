## Context

GeneClaw already normalizes Slack attachments and stores document metadata, but
the current image path routes `png/jpg/jpeg` through OCR. That makes image
support text-centric and misses the important visual semantics that multimodal
models can consume directly.

## Goals / Non-Goals

- Goals:
  - Treat image attachments as multimodal LLM inputs.
  - Keep the normalized envelope source-agnostic.
  - Preserve stored file metadata and session linkage for images.
  - Support OpenAI, Anthropic, and similar multimodal providers through a
    provider-neutral internal representation.
- Non-Goals:
  - OCR fallback for non-vision providers.
  - Thread-wide image retrieval beyond the current message attachment set.
  - Outbound image generation or image editing tools.

## Decisions

- Decision: split attachment handling by media class.
  - Images become `image_attachments` in the run context and are passed to the
    LLM request builder.
  - PDFs/text remain document ingestion inputs with extracted text.

- Decision: use local staged files as the canonical image source.
  - Slack files are still downloaded and stored under managed roots before the
    run.
  - Provider request builders decide whether to pass local bytes as base64/data
    URLs or other provider-native image payloads.

- Decision: add provider capability gating.
  - If the configured provider/model cannot accept images, GeneClaw returns a
    clear message such as “current model does not support image inputs”.
  - It must not silently reduce the request to OCR text.

- Decision: keep prompt text small and image payload separate.
  - The user prompt remains text.
  - Image attachments are sent as separate multimodal content blocks, not
    flattened into synthetic text.

## Risks / Trade-offs

- Larger request payloads:
  - Mitigation: apply per-image size caps and image-count caps before request
    construction.
- Provider divergence:
  - Mitigation: keep a provider-neutral internal attachment shape, with
    translation isolated inside `llm_provider.gene`.
- Mixed attachment messages:
  - Mitigation: allow one run to include both text documents and image inputs.

## Migration Plan

1. Change the image branch in `documents.gene` to stage image files without OCR.
2. Extend the agent/LLM boundary to carry image attachments separately from
   text document context.
3. Teach OpenAI and Anthropic request builders to emit multimodal image blocks.
4. Add capability failure responses and tests.

## Open Questions

- Whether to enforce provider capability by provider name only or add
  model-level allowlists.
  A: enforce by provider name only.
- Whether to resize/compress large images before sending or simply reject them
  in v1.
  A: reject in v1.

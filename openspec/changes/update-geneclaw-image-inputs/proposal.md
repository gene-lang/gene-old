## Why

GeneClaw currently treats uploaded images as OCR sources. That works for
text-heavy screenshots and scanned pages, but it does not support the main
image-question use cases: charts, UI screenshots, diagrams, photos, and any
question that depends on visual structure rather than extracted text.

The intended deployment targets are OpenAI, Anthropic, and other multimodal
models, so GeneClaw should pass supported image attachments directly to the
LLM instead of running OCR first.

## What Changes

- Replace OCR-based image ingestion with multimodal image attachment handling
  for supported providers.
- Keep PDF and plain-text document ingestion text-based.
- Preserve image metadata and local storage, but stop extracting OCR text for
  normal image question answering.
- Extend the provider request builders so OpenAI/Anthropic requests can include
  image content blocks alongside text.
- Add explicit provider capability handling: if the configured model/provider
  cannot accept images, GeneClaw returns a clear failure instead of silently
  degrading to OCR.
- Update GeneClaw document/image design docs and tests to reflect the new
  contract.

## Impact

- Affected specs: `geneclaw-document-support`
- Affected code:
  - `example-projects/geneclaw/src/documents.gene`
  - `example-projects/geneclaw/src/agent.gene`
  - `example-projects/geneclaw/src/llm_provider.gene`
  - `src/genex/ai/control_slack.nim`
  - `src/genex/ai/utils.nim`
- Breaking behavior:
  - Image uploads will no longer be OCR-expanded into text context by default.
  - Non-vision providers will no longer attempt image fallback via OCR.

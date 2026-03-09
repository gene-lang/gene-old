## 1. Implementation

- [x] 1.1 Change GeneClaw attachment ingestion to classify images separately
      from text documents and stop OCR extraction for normal image inputs.
- [x] 1.2 Preserve staged image metadata/storage without storing OCR text in
      document context.
- [x] 1.3 Extend the agent-side run context so image attachments can be passed
      to the LLM request builder alongside normal text prompt content.
- [x] 1.4 Add multimodal request construction for supported providers in
      `llm_provider.gene`.
- [x] 1.5 Add provider/model capability checks and explicit failures for
      non-vision configurations.
- [x] 1.6 Update GeneClaw design docs to describe image-to-LLM handling rather
      than OCR-based image extraction.
- [x] 1.7 Add focused tests for image attachment classification, request
      building, and capability failures.

## 2. Validation

- [x] 2.1 Run AI/document-focused Nim tests.
- [x] 2.2 Run GeneClaw-focused Gene tests covering image attachment handling.
- [x] 2.3 Rebuild the AI extension and validate the OpenSpec change with
      `openspec validate update-geneclaw-image-inputs --strict`.

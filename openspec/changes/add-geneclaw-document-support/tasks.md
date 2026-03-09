## 1. Implementation

- [x] 1.1 Extend Slack event parsing and the normalized command envelope to
      carry attachment metadata for message events.
- [x] 1.2 Add GeneClaw document tables and helpers for storing document
      metadata, extracted text status, and chunks.
- [x] 1.3 Implement inbound Slack document download/staging using authenticated
      Slack file URLs and managed document roots.
- [x] 1.4 Reuse existing document extraction helpers for supported types and
      surface explicit failure state for unreadable files.
- [x] 1.5 Add agent-side document context shaping so runs see bounded document
      excerpts/chunks without storing full documents in conversation memory.
- [x] 1.6 Add a `send_document` tool that uploads a managed local file to Slack
      with `files.getUploadURLExternal` and `files.completeUploadExternal`.
- [x] 1.7 Add/update docs and examples for document ingestion and outbound file
      delivery.
- [x] 1.8 Add focused Nim and Gene tests for Slack attachment parsing, document
      persistence, inbound context shaping, and outbound Slack upload flow.

## 2. Validation

- [x] 2.1 Run document/slack-focused Nim tests.
- [x] 2.2 Run GeneClaw-focused Gene tests for inbound document context and
      outbound document tool behavior.
- [x] 2.3 Rebuild the AI extension and validate the OpenSpec change with
      `openspec validate add-geneclaw-document-support --strict`.

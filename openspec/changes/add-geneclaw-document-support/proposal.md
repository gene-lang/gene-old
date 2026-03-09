## Why

GeneClaw currently treats Slack messages as text-only inputs and can only reply
with text. That blocks two common agent workflows:

- a user uploads a document and asks GeneClaw to read or summarize it
- GeneClaw generates an artifact and needs to send it back through Slack as a
  downloadable file

The project now has a concrete design in
`example-projects/geneclaw/docs/document_support.md`. The next step is to add
document ingestion and delivery as first-class GeneClaw capabilities.

## What Changes

- Extend Slack ingress so a message can carry document attachments into the
  normalized agent input envelope.
- Add a GeneClaw document store in SQLite for uploaded/generated document
  metadata and extracted chunks.
- Download Slack-hosted files with authenticated requests, stage them under a
  managed workspace path, and extract text for supported document types.
- Expose uploaded document context to the agent run without stuffing full
  document contents into conversation memory.
- Add a `send_document` tool so the agent can upload a local artifact to Slack
  using Slack's current external-upload flow.
- Keep document handling explicit about failures: unsupported or unreadable
  files are preserved with failure metadata and surfaced back to the user.

## Impact

- Affected specs:
  - `geneclaw-document-support` (new)
- Affected code:
  - `src/genex/ai/utils.nim`
  - `src/genex/ai/control_slack.nim`
  - `src/genex/ai/bindings.nim`
  - `example-projects/geneclaw/src/main.gene`
  - `example-projects/geneclaw/src/agent.gene`
  - `example-projects/geneclaw/src/llm_provider.gene`
  - `example-projects/geneclaw/src/db.gene`
  - `example-projects/geneclaw/src/tools.gene`
  - `example-projects/geneclaw/src/tools/send_document.gene`
  - Slack/document-focused tests and docs
- Risk: medium
- Key risks:
  - Slack file metadata and download flows differ from plain message handling
  - document extraction can fail or be slow for large files
  - outbound uploads must avoid arbitrary filesystem exfiltration

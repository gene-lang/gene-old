## Context

GeneClaw already has the following pieces:

- Slack event parsing in `src/genex/ai/control_slack.nim`
- a `CommandEnvelope` for agent input in `src/genex/ai/utils.nim`
- document extraction/chunking helpers in `src/genex/ai/documents.nim`
- SQLite-backed memory/audit storage in `example-projects/geneclaw/src/db.gene`
- Slack reply logic for text messages

What is missing is the end-to-end path that carries Slack file attachments into
the agent run and lets the agent send a generated file back to Slack.

## Goals

- Support user-uploaded Slack documents as agent context.
- Support agent-generated outbound Slack file uploads.
- Preserve the existing text-first UX while adding document metadata and
  extracted context cleanly.
- Reuse the current document extraction helpers instead of building a separate
  extraction path.
- Keep document downloads/uploads auditable and constrained to managed roots.

## Non-Goals

- Full retrieval or vector search over historical thread documents in v1.
- Content deduplication in v1.
- Parallel document ingestion in v1.
- Remote-file integrations outside Slack-hosted uploads in v1.

## Decisions

### 1. Normalize Attachments on the Command Envelope

The command boundary should become a normalized envelope with an `attachments`
collection instead of adding more positional callback parameters.

Implementation detail:

- socket mode and webhook mode continue to extract `workspace_id`, `channel_id`,
  `thread_id`, and `text`
- they now also populate attachment metadata in `CommandEnvelope.metadata`
  and/or a dedicated envelope field
- GeneClaw runtime converts that normalized shape into document ingestion work

### 2. Document Ingestion Happens Before the LLM Call

Inbound Slack documents are part of the message context, not tool-discovered
side effects.

Flow:

1. detect Slack file metadata on the message event
2. resolve details with `files.info` when needed
3. download bytes with bot-token auth
4. stage under managed document storage
5. extract text/chunks for supported types
6. build a compact document context block for the run

### 3. Full Document Text Does Not Enter Conversation Memory

Conversation memory remains lightweight.

Instead:

- `memory_events` stores user/assistant exchanges
- documents live in dedicated document tables
- prompt assembly pulls bounded excerpts/chunks from the document store

### 4. Outbound Delivery Uses Slack External Upload APIs

GeneClaw should use Slack's current upload flow:

1. `files.getUploadURLExternal`
2. upload bytes to the returned URL
3. `files.completeUploadExternal`

`files.upload` is not used.

### 5. Document Roots Stay Managed

Inbound files are saved under a GeneClaw-managed document root.

Outbound `send_document` accepts only files under configured workspace/artifact
roots after realpath/symlink resolution.

## Risks / Trade-offs

- The envelope refactor touches multiple runtime boundaries, but it prevents the
  callback interface from becoming brittle.
- Document extraction can fail; surfacing explicit failure state is better than
  silent omission, but it adds more run-state branching.
- Keeping ingestion sequential simplifies correctness at the cost of slower
  multi-file runs.

## Migration Plan

1. Extend envelope and Slack parsing to carry file metadata.
2. Add SQLite document tables and local document staging helpers.
3. Ingest and extract inbound files, then include bounded context in the agent
   prompt.
4. Add `send_document` and Slack upload helpers.
5. Add tests for Slack parsing, DB persistence, prompt shaping, and outbound
   upload request assembly.

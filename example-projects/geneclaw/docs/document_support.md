# GeneClaw Document Support

## Goal

Support both directions:

1. A user uploads a document in Slack and GeneClaw can read and use it.
2. GeneClaw generates or selects a document and sends it back to Slack so the user can download it.

The design should fit the current GeneClaw architecture:

- Slack ingress stays responsible for turning Slack events into an agent input envelope.
- Document ingestion happens before the LLM call.
- Extraction and chunking reuse the existing helpers in `src/genex/ai/documents.nim`.
- Outbound file delivery is exposed to the agent as an explicit tool.

## Summary

### Inbound: Slack -> GeneClaw

- Detect file attachments in Slack message events.
- Resolve each file via Slack `files.info`.
- Download file bytes using the bot token and the file's authenticated `url_private` or `url_private_download`.
- Save the file under a GeneClaw-managed document store.
- Extract text for supported document types.
- Persist document metadata and extracted chunks.
- Pass document references into the agent run.

### Outbound: GeneClaw -> Slack

- Agent writes or selects a local file.
- Agent calls a `send_document` tool.
- Tool uploads the file to Slack using:
  - `files.getUploadURLExternal`
  - upload raw bytes to the returned URL
  - `files.completeUploadExternal`
- File is shared into the current channel/thread so the user can download it in Slack.

## Why this shape

Inbound document handling should not be a normal tool call. If a user uploads a file, that file is part of the message itself, not a secondary action the model needs to discover.

Outbound document sending should be a tool call. That is an intentional side effect and should be explicit, auditable, and permission-scoped.

## Scope boundary

The long-term direction is to move `run_agent` to a single envelope/map input instead of positional arguments.

That should be treated as a prerequisite refactor, not accidental scope growth inside document work. In practice:

- Phase 1 may add a small adapter layer if needed.
- The target shape is still a normalized envelope with `text`, ids, metadata, and `attachments`.
- New document handling should be implemented against that normalized shape, not by adding more positional parameters.

## Slack API choices

### Inbound download

Use Slack-hosted file URLs from the file object:

- `files.info` to resolve file metadata
- `url_private` or `url_private_download` to fetch bytes
- `Authorization: Bearer <bot token>` on all file fetches

This requires `files:read`.

### Outbound upload

Do not use `files.upload`.

Slack deprecated `files.upload`, new apps lost access on May 16, 2024, and the method was sunset on November 12, 2025. GeneClaw should use the current upload flow:

1. `files.getUploadURLExternal`
2. upload bytes to the returned URL
3. `files.completeUploadExternal`

This requires `files:write`.

### References

- [Slack working with files](https://docs.slack.dev/messaging/working-with-files)
- [Slack files.completeUploadExternal](https://docs.slack.dev/reference/methods/files.completeUploadExternal/)
- [Slack files.info](https://docs.slack.dev/reference/methods/files.info)
- [Slack file object](https://docs.slack.dev/reference/objects/file-object)
- [Slack files:read scope](https://docs.slack.dev/reference/scopes/files.read)
- [Slack files:write scope](https://docs.slack.dev/reference/scopes/files.write/)

## Inbound document support

### Event handling

GeneClaw should extend Slack ingress so message events can carry attachments into the agent envelope.

Proposed normalized envelope shape:

```gene
{
  ^workspace_id "T..."
  ^user_id "U..."
  ^channel_id "C..."
  ^thread_id "1741..."
  ^text "please summarize this"
  ^attachments [
    {
      ^source "slack"
      ^file_id "F..."
      ^filename "spec.pdf"
      ^mime_type "application/pdf"
      ^size 123456
      ^url_private "https://files.slack.com/..."
    }
  ]
}
```

The agent boundary should move toward accepting this envelope instead of a growing list of positional arguments.

`attachments` is the recommended normalized field name even though raw Slack payloads use `files`. The point is to keep the internal envelope source-agnostic so future non-Slack inputs can use the same field.

### File detection

V1 should support files attached directly to the message that triggered the run.

Sources to inspect on Slack events:

- `event/files`
- `event/subtype == "file_share"`
- optional follow-up support for `file_shared`

V1 should not try to crawl older files in the thread automatically.

Future phases should add thread-scoped document recall so users can say things like "look at the file I uploaded earlier in this thread" without re-uploading it.

### Download and staging

For each attachment:

1. Call `files.info(file_id)` if the message payload is incomplete.
2. Download bytes from `url_private_download` when present, else `url_private`.
3. Save to a managed location such as:

```text
$GENECLAW_WORKSPACE/documents/inbox/<workspace>/<channel>/<thread>/<document_id>/<filename>
```

4. Record metadata:
   - workspace/channel/thread/user
   - Slack file id
   - original filename
   - MIME type
   - byte size
   - SHA-256
   - local path

V1 should process multiple attachments sequentially. That keeps implementation and failure handling simple. Parallel downloads can be added later if large multi-file uploads become common.

### Extraction

Reuse existing helpers in `src/genex/ai/documents.nim`:

- `extract_pdf`
- `file_to_base64`
- `extract_and_chunk`
- `chunk`

V1 supported types:

- `pdf`
- `txt`
- `md`
- `png`
- `jpg`
- `jpeg`
- `gif`
- `webp`

Plain text and markdown should be read directly without OCR/external extraction.

Images should not go through OCR in GeneClaw. For image attachments:

- download and persist the original file
- mark the record as staged/usable without extracted text
- pass the image itself to the configured multimodal LLM request
- fail explicitly if the current provider/model configuration cannot accept images

Only PDFs and text-like files should contribute extracted text/chunks to prompt context in V1.

If extraction fails:

- keep the original file and metadata
- mark the document `status = failed`
- store the error text
- expose that failure to the agent run

The user-facing behavior should be explicit. GeneClaw should tell the user that the file was received but could not be read, instead of silently ignoring it.

### Persistence

Add document tables instead of stuffing extracted text into `memory_events`.

Suggested schema:

```text
documents
- document_id
- workspace_id
- session_id
- source                # slack_upload | generated
- source_ref            # Slack file id or local artifact id
- filename
- mime_type
- byte_size
- sha256
- local_path
- extracted_text
- status                # staged | extracted | failed
- error
- created_at_ms

document_chunks
- document_id
- chunk_index
- text
- meta_json

session_documents
- session_id
- document_id
- role                  # inbound | outbound
- created_at_ms
```

V1 does not need content deduplication. If the same file is uploaded twice in the same thread, it is acceptable to create two document records. The stored SHA-256 is mainly for observability and future dedup policy.

### Prompt handling

Do not inject the full contents of every uploaded document into the conversation history.

V1 prompt strategy:

- small documents: inline a bounded excerpt
- large documents: inline a short summary plus top chunks
- keep a document reference list in the run context

`GENECLAW_DOCUMENT_MAX_INLINE_CHARS` should apply to prompt injection, not raw extraction. Extraction and chunking should preserve the full usable text; prompt assembly is where the inline cap should be enforced.

Example synthetic context block:

```text
Attached documents:
1. spec.pdf (12 pages, 38 KB, document_id=doc-123)
   Excerpt: ...
2. notes.txt (3 KB, document_id=doc-124)
   Excerpt: ...
```

Phase 2 can add retrieval-style tools such as:

- `list_documents`
- `read_document`
- `search_document_chunks`

## Outbound document support

### Use case

The agent may need to send a generated report, patch, transcript, CSV, markdown file, or other artifact back to Slack so the user can download it.

### Tool shape

Add a dedicated tool, for example `send_document`.

Suggested arguments:

```gene
{
  ^path "reports/summary.md"
  ^title "summary.md"
  ^comment "Here is the requested report."
  ^channel_id "C..."
  ^thread_ts "1741..."
}
```

Context defaults:

- `channel_id` defaults to the current Slack channel
- `thread_ts` defaults to the current thread

### Upload flow

1. Resolve and validate local file path.
2. Refuse files outside the allowed workspace/artifact roots.
3. Determine size and MIME type.
4. Call `files.getUploadURLExternal`.
5. Upload raw bytes to the returned URL.
6. Call `files.completeUploadExternal` with:
   - file id/title pair
   - `channel_id`
   - `thread_ts`
   - optional `initial_comment`

Return:

```gene
{
  ^ok true
  ^file_id "F..."
  ^title "summary.md"
}
```

### Why hosted Slack files, not public links

Default behavior should be Slack-hosted files shared into the current conversation:

- users can download directly in Slack
- no separate hosting service is required
- access follows Slack channel permissions

GeneClaw should not create public file URLs by default.

### Remote files

Slack remote files are useful when GeneClaw wants Slack to point at an externally hosted document system. That is a later feature, not v1.

V1 should only support hosted uploads to Slack.

## Security and limits

### Inbound

- allowlist supported file types
- enforce size caps before extraction
- sanitize filenames
- never execute uploaded files
- keep downloaded originals under managed storage only

### Outbound

- only allow files under configured workspace/artifact roots
- resolve symlinks and validate the real path, not only the input path
- do not allow arbitrary filesystem exfiltration
- audit every send
- optionally cap upload size

### Recommended config

```text
GENECLAW_DOCUMENT_MAX_UPLOAD_BYTES
GENECLAW_DOCUMENT_MAX_INLINE_CHARS
GENECLAW_DOCUMENT_ROOT
GENECLAW_ARTIFACT_ROOT
```

## Audit and observability

Document handling should be first-class in logs and storage.

Add audit entries for:

- document detected
- metadata resolved
- download succeeded/failed
- extraction succeeded/failed
- outbound upload succeeded/failed

Useful log fields:

- document_id
- slack file id
- filename
- MIME type
- byte size
- session id
- channel/thread ids

## Recommended implementation order

### Phase 1

- Extend Slack ingress to collect file attachments
- Introduce document store tables
- Download and save inbound Slack files
- Extract text for `pdf`, `txt`, `md`, `png`, `jpg`, `jpeg`
- Pass document references into the agent run

### Phase 2

- Add `send_document` tool for outbound Slack uploads
- Restrict uploads to managed artifact roots
- Audit outbound file sends

### Phase 3

- Add document retrieval/search tools
- Add better chunk ranking for large files
- Add remote file support if an external document system is needed

## Recommended v1 behavior

If a user uploads a supported document and asks a question in the same Slack message or thread:

1. GeneClaw downloads and extracts it automatically.
2. The agent receives a compact document context block.
3. The model can answer immediately for small documents.
4. For generated artifacts, the agent can call `send_document` to return a downloadable file in the same thread.

This keeps the user experience simple:

- upload document
- ask question
- receive answer
- optionally receive generated file back in Slack

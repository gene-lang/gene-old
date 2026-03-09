## ADDED Requirements

### Requirement: Slack Message Envelopes Preserve Attachment Metadata

The system SHALL preserve supported Slack file attachments on the normalized
command envelope used by GeneClaw runs.

#### Scenario: Slack message event with files becomes an attachment-aware envelope

- **WHEN** GeneClaw receives a Slack `message` event containing one or more
  files
- **THEN** the normalized command envelope SHALL retain the message text,
  thread identity, and attachment metadata for those files

### Requirement: GeneClaw Ingests Supported Slack Documents Before LLM Execution

The system SHALL ingest supported Slack-hosted documents before the agent run
builds the LLM request.

#### Scenario: Uploaded PDF becomes document context

- **WHEN** a user uploads a supported PDF in Slack and asks GeneClaw a question
- **THEN** GeneClaw SHALL download the file, extract usable text, persist
  document metadata, and include bounded document context in the run

#### Scenario: Unsupported or unreadable document is surfaced explicitly

- **WHEN** a Slack-uploaded file cannot be extracted successfully
- **THEN** GeneClaw SHALL persist the document with failed status
- **AND** the run SHALL surface that failure instead of silently ignoring the
  file

### Requirement: Document Content Is Stored Outside Conversation Memory

The system SHALL keep document content in dedicated document storage rather
than stuffing full extracted text into conversation memory history.

#### Scenario: Document ingestion does not append full text to memory events

- **WHEN** GeneClaw ingests a Slack document successfully
- **THEN** conversation memory SHALL continue to store the user/assistant
  exchange
- **AND** document text/chunks SHALL be stored in dedicated document tables

### Requirement: GeneClaw Can Upload Managed Files Back To Slack

The system SHALL allow the agent to send a managed local file back to Slack as
 a downloadable hosted file.

#### Scenario: Agent uploads a generated artifact to the current thread

- **WHEN** the agent calls `send_document` with a valid managed file path
- **THEN** GeneClaw SHALL upload the file using Slack's external upload flow
- **AND** share the file into the target channel/thread

#### Scenario: Outbound file path outside managed roots is rejected

- **WHEN** the agent calls `send_document` with a path outside the configured
  managed roots after realpath resolution
- **THEN** GeneClaw SHALL reject the request

### Requirement: Document Handling Is Auditable

The system SHALL log and persist meaningful document-ingestion and
document-delivery outcomes.

#### Scenario: Inbound document failure is auditable

- **WHEN** document download or extraction fails
- **THEN** the stored document metadata SHALL record failure status and error
  details

#### Scenario: Outbound Slack upload result is auditable

- **WHEN** the agent attempts to send a document to Slack
- **THEN** GeneClaw SHALL record whether the upload succeeded or failed

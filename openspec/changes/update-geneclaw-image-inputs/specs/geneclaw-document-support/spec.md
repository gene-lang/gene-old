## MODIFIED Requirements

### Requirement: GeneClaw Ingests Supported Slack Documents Before LLM Execution

The system SHALL ingest supported Slack-hosted attachments before the agent run
builds the LLM request.

#### Scenario: Uploaded PDF becomes document context

- **WHEN** a user uploads a supported PDF in Slack and asks GeneClaw a question
- **THEN** GeneClaw SHALL download the file, extract usable text, persist
  document metadata, and include bounded document context in the run

#### Scenario: Uploaded image becomes multimodal LLM input

- **WHEN** a user uploads a supported image in Slack and asks GeneClaw a
  question about it
- **THEN** GeneClaw SHALL download and persist the image
- **AND** the run SHALL pass that image to the configured multimodal LLM as an
  image input rather than OCR text

#### Scenario: Unsupported or unreadable attachment is surfaced explicitly

- **WHEN** a Slack-uploaded attachment cannot be prepared successfully
- **THEN** GeneClaw SHALL persist the attachment with failed status
- **AND** the run SHALL surface that failure instead of silently ignoring the
  file

### Requirement: Document Content Is Stored Outside Conversation Memory

The system SHALL keep extracted document text in dedicated document storage
rather than stuffing full content into conversation memory history.

#### Scenario: Image uploads do not generate OCR-backed memory text

- **WHEN** GeneClaw ingests an image attachment successfully
- **THEN** conversation memory SHALL store the user/assistant exchange
- **AND** the system SHALL not append OCR-derived image text as conversation
  memory content

## ADDED Requirements

### Requirement: GeneClaw Uses Multimodal Provider Inputs For Images

The system SHALL pass supported image attachments directly to configured
multimodal providers.

#### Scenario: Anthropic request includes image content blocks

- **WHEN** the configured provider is Anthropic and the run contains an image
  attachment
- **THEN** the request builder SHALL emit Anthropic-compatible image content
  blocks for that attachment

#### Scenario: OpenAI request includes image input parts

- **WHEN** the configured provider is OpenAI and the run contains an image
  attachment
- **THEN** the request builder SHALL emit OpenAI-compatible image input parts
  for that attachment

### Requirement: GeneClaw Fails Clearly For Image Inputs On Non-Vision Models

The system SHALL fail explicitly when image attachments are present but the
configured model/provider cannot handle image inputs.

#### Scenario: Non-vision provider rejects image question

- **WHEN** a run includes one or more image attachments and the configured
  provider/model does not support image inputs
- **THEN** GeneClaw SHALL return a clear error or user-facing response
  explaining that image input is unsupported in the current configuration
- **AND** it SHALL not silently fall back to OCR

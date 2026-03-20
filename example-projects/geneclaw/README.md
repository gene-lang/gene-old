# GeneClaw

A tool-using AI agent platform built entirely in Gene.

## What it does

GeneClaw receives commands (via REST API or Slack webhook), runs a bounded agent loop that can call tools, and returns the result. Tool audit, run tracking, schedules, document metadata, session state, and hot runtime state are persisted across tiered home roots under `GENECLAW_HOME`.

## Architecture

```
Slack/REST → Router → Agent Orchestrator → LLM Provider (OpenAI / Anthropic)
                              ↓
                        Tool Registry
                        ↓      ↓       ↓       ↓        ↓
                     shell  read_file  http   get_time  browser_playwright
                               ↓
      GENECLAW_HOME (config + state + records + logs filesystem tree)
```

## Files

- `src/main.gene` - HTTP server, routing, Slack webhook handler
- `src/agent.gene` - Agent run loop with step/tool-call budget
- `src/llm_provider.gene` - Provider adapter for OpenAI and Anthropic
- `src/tools.gene` - Tool registry/orchestration
- `src/tools/*.gene` - Individual tool modules
- `src/tools/*.mjs` - Playwright helper scripts
- `src/config.gene` - Home-backed config loader and public config export
- `src/home_store.gene` - `GENECLAW_HOME` bootstrap and interpolation helpers
- `src/workspace_state.gene` - Serialized hot-state and session memory store
- `src/db.gene` - filesystem-backed keyed-record and append-only log storage

## Docs

- `docs/hotswap.md` - self-upgrade and restart design
- `docs/document_support.md` - inbound and outbound Slack document handling design

## Quick start

```bash
# Build Gene (from repo root)
cd gene && nimble build

# Run GeneClaw
cd example-projects/geneclaw
../../gene/bin/gene run src/main.gene
```

## Configuration

GeneClaw now boots from `GENECLAW_HOME`.

- `GENECLAW_HOME/config` stores non-sensitive runtime config as serialized Gene.
- `GENECLAW_HOME/state` stores hot runtime state such as the system prompt.
- `GENECLAW_HOME/sessions`, `GENECLAW_HOME/scheduler/jobs`, and `GENECLAW_HOME/scheduler/runs` store keyed durable records.
- `GENECLAW_HOME/assets/uploaded` and `GENECLAW_HOME/assets/generated` are managed roots for inbound and generated files.
- `GENECLAW_HOME/logs` stores append-only audit data.
- `GENECLAW_HOME/archive` is reserved for cold durable data.
- `GENECLAW_HOME/tmp` is the managed scratch workspace root used by mutating tools (`write_file`, `edit_file`, `patch_file`, `delete_file`, and shell/browser helpers). Read-only inspection tools use the process launch directory instead.
- The built-in repository instance uses `/Users/gcao/gene-workspace/gene-old/example-projects/geneclaw/home`.

Non-sensitive config can use environment placeholders inside any string:

```text
{ENV:NAME:default value}
```

Every placeholder occurrence in a loaded string is expanded at runtime. Secrets remain environment-sourced and should not be committed to `GENECLAW_HOME/config`.

Key bootstrap and secret environment variables:

| Variable | Description |
|---|---|
| `GENECLAW_HOME` | Root directory for serialized config, hot state, keyed records, logs, archive, and managed files |
| `OPENAI_API_KEY` | OpenAI API key |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `ANTHROPIC_AUTH_TOKEN` | Anthropic auth token / OAuth token |
| `SLACK_SIGNING_SECRET` | Slack app signing secret |
| `SLACK_BOT_TOKEN` | Slack bot OAuth token |
| `SLACK_APP_TOKEN` | Slack Socket Mode token |
| `SLACK_AGENTX_TOKEN` | Slack token used by outbound `send_message` |
| `BRAVE_API_KEY` | Brave Search API key |

## LLM providers

- `openai` remains the default and uses the existing OpenAI-compatible chat/tool-calling flow.
- `anthropic` uses the Anthropic Messages API through `AnthropicClient`.
- Anthropic auth can use either `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`.
- If the selected provider has no usable credentials, GeneClaw stays in mock mode.

## API

**Health check:**
```
GET /health
```

**Inspect runtime config:**
```
GET /api/config
```

Returns the current effective GeneClaw config as a Gene map. Secret values are always redacted as `"hidden"`.

You can also fetch a nested value with a slash-delimited query path:
```
GET /api/config?path=llm/provider
GET /api/config?path=home/root
GET /api/config?path=home/state_root
GET /api/config?path=home/sessions_root
GET /api/config?path=home/tmp_root
GET /api/config?path=assets/uploaded_root
GET /api/config?path=slack/bot_token_configured
```

**Send message:**
```
POST /api/chat
{"workspace_id": "ws1", "user_id": "u1", "channel_id": "general", "text": "what time is it?"}
```

**Slack webhook:**
```
POST /slack/events
(Slack Events API payload)
```

## Built-in tools

- `get_time` - Current date/time
- `shell` - Run shell commands from `GENECLAW_HOME/tmp`
- `read_file` - Read files from the launch directory using a relative path (path-traversal blocked)
- `write_file` - Write files only inside `GENECLAW_HOME/tmp`
- `http_get` - Fetch a URL
- `browser_playwright` - Browser control (`list_pages`, `navigate`, `click`, `fill`, `text`, `screenshot`, etc.) with auto-attach to Chrome CDP (`http://127.0.0.1:9333`) and managed Playwright server fallback
- `web_search` - Search the web via Brave Search API (requires `BRAVE_API_KEY`)
- `list_files` - List files/directories from the launch directory using a relative path (supports recursive)
- `edit_file` - Edit a file by exact text replacement only inside `GENECLAW_HOME/tmp`
- `patch_file` - Apply a unified diff patch only inside `GENECLAW_HOME/tmp`
- `send_message` - Send a message to a Slack channel/thread (requires `SLACK_AGENTX_TOKEN`)
- `delete_file` - Delete a file only inside `GENECLAW_HOME/tmp` (files only, no directories)
- `tmux_send` - Send keys to a tmux pane
- `tmux_tail` - Capture recent output from a tmux pane
- `grep` - Search file contents from the launch directory using ripgrep and relative paths

## Playwright tool prerequisites

- Install Node.js and Playwright package in `example-projects/geneclaw`:

```bash
npm i playwright
```

- If you already run Chrome with DevTools open (for example `--remote-debugging-port=9333`), the tool will auto-connect on normal actions.
- If no browser is listening, the tool auto-starts a managed browser server by default.
- You can still start explicitly:
  - `browser_playwright` with `{^action "server_start" ^channel "chrome" ^headless true}`
- Optional args for control:
  - `cdp_url` (e.g. `http://127.0.0.1:9333`)
  - `auto_start` (default `true`)
  - `connect_timeout_ms`

## Safety

- All tool invocations are audit-logged with run_id, duration, args, and result
- Agent runs are bounded by `MAX_STEPS` (16) and `MAX_TOOL_CALLS` (8)

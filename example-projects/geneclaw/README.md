# GeneClaw

A tool-using AI agent platform built entirely in Gene.

## What it does

GeneClaw receives commands (via REST API or Slack webhook), runs a bounded agent loop that can call tools, and returns the result. All tool calls are audit-logged to SQLite.

## Architecture

```
Slack/REST → Router → Agent Orchestrator → LLM (OpenAI)
                              ↓
                        Tool Registry
                        ↓      ↓       ↓       ↓        ↓
                     shell  read_file  http   get_time  browser_playwright
                               ↓
                     SQLite (memory + audit)
```

## Files

- `src/main.gene` - HTTP server, routing, Slack webhook handler
- `src/agent.gene` - Agent run loop with step/tool-call budget
- `src/tools.gene` - Tool registry/orchestration
- `src/tools/*.gene` - Individual tool modules
- `src/tools/*.mjs` - Playwright helper scripts
- `src/config.gene` - Environment variable configuration
- `src/db.gene` - SQLite schema, memory, audit log, run tracking

## Quick start

```bash
# Build Gene (from repo root)
cd gene && nimble build

# Run GeneClaw
cd example-projects/geneclaw
../../gene/bin/gene run src/main.gene
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `OPENAI_API_KEY` | (empty = mock mode) | OpenAI API key |
| `OPENAI_MODEL` | `gpt-5-mini` | Model to use |
| `SLACK_SIGNING_SECRET` | | Slack app signing secret |
| `SLACK_BOT_TOKEN` | | Slack bot OAuth token |
| `GENECLAW_WORKSPACE` | `/tmp/geneclaw` | Filesystem tool root |

## API

**Health check:**
```
GET /health
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
- `shell` - Run allowlisted commands (ls, cat, echo, date, etc.)
- `read_file` - Read files within workspace (path-traversal blocked)
- `write_file` - Write files within workspace
- `http_get` - Fetch a URL
- `browser_playwright` - Browser control (`list_pages`, `navigate`, `click`, `fill`, `text`, `screenshot`, etc.) with auto-attach to Chrome CDP (`http://127.0.0.1:9333`) and managed Playwright server fallback
- `web_search` - Search the web via Brave Search API (requires `BRAVE_API_KEY`)
- `list_files` - List files/directories within workspace (supports recursive)
- `edit_file` - Edit a file by exact text replacement within workspace
- `patch_file` - Apply a unified diff patch to a file within workspace
- `send_message` - Send a message to a Slack channel/thread (requires `SLACK_AGENTX_TOKEN`)
- `delete_file` - Delete a file within workspace (files only, no directories)
- `tmux_send` - Send keys to a tmux pane
- `tmux_tail` - Capture recent output from a tmux pane
- `grep` - Search file contents using ripgrep within workspace

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

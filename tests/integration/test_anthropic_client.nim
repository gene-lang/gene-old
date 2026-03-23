import unittest, json, tables, os, strutils

import ../src/genex/ai/anthropic_client

proc splitBetas(value: string): seq[string] =
  for part in value.split(','):
    let trimmed = part.strip()
    if trimmed.len > 0:
      result.add(trimmed)

suite "Anthropic Client":
  test "auth token takes precedence over api token":
    let cfg = buildAnthropicConfig(%*{
      "api_token": "sk-ant-api-123",
      "auth_token": "sk-ant-oat-xyz"
    })
    check cfg.auth_token == "sk-ant-oat-xyz"
    check cfg.headers.hasKey("Authorization")
    check cfg.headers["Authorization"] == "Bearer sk-ant-oat-xyz"
    check not cfg.headers.hasKey("x-api-key")

  test "oauth token prefix in api_token is auto-detected":
    let cfg = buildAnthropicConfig(%*{
      "api_token": "sk-ant-oat-from-api-token"
    })
    check cfg.auth_token == "sk-ant-oat-from-api-token"
    check cfg.headers.hasKey("Authorization")
    check not cfg.headers.hasKey("x-api-key")

  test "oauth setup token adds Claude Code headers and betas":
    let cfg = buildAnthropicConfig(%*{
      "auth_token": "sk-ant-oat01-test-token",
      "anthropic_beta": "custom-beta"
    })
    check cfg.headers["Authorization"] == "Bearer sk-ant-oat01-test-token"
    check cfg.headers["User-Agent"] == CLAUDE_CODE_USER_AGENT
    check cfg.headers["x-app"] == "cli"
    check cfg.headers["anthropic-dangerous-direct-browser-access"] == "true"
    check cfg.headers["Accept"] == "application/json"
    let betas = splitBetas(cfg.headers["anthropic-beta"])
    check "claude-code-20250219" in betas
    check "oauth-2025-04-20" in betas
    check "fine-grained-tool-streaming-2025-05-14" in betas
    check "interleaved-thinking-2025-05-14" in betas
    check "custom-beta" in betas

  test "api token mode uses x-api-key header":
    let cfg = buildAnthropicConfig(%*{
      "api_token": "sk-ant-api-only",
      "anthropic_version": "2023-06-01"
    })
    check cfg.headers.hasKey("x-api-key")
    check cfg.headers["x-api-key"] == "sk-ant-api-only"
    check not cfg.headers.hasKey("Authorization")
    check cfg.headers["anthropic-version"] == "2023-06-01"

  test "env var resolution prefers ANTHROPIC_OAUTH_TOKEN over ANTHROPIC_API_KEY":
    let had_api = existsEnv("ANTHROPIC_API_KEY")
    let had_oauth = existsEnv("ANTHROPIC_OAUTH_TOKEN")
    let old_api = getEnv("ANTHROPIC_API_KEY")
    let old_oauth = getEnv("ANTHROPIC_OAUTH_TOKEN")
    try:
      putEnv("ANTHROPIC_API_KEY", "sk-ant-api-env")
      putEnv("ANTHROPIC_OAUTH_TOKEN", "sk-ant-oat-env")
      let cfg = buildAnthropicConfig()
      check cfg.auth_token == "sk-ant-oat-env"
      check cfg.headers.hasKey("Authorization")
      check not cfg.headers.hasKey("x-api-key")
    finally:
      if had_api:
        putEnv("ANTHROPIC_API_KEY", old_api)
      else:
        delEnv("ANTHROPIC_API_KEY")
      if had_oauth:
        putEnv("ANTHROPIC_OAUTH_TOKEN", old_oauth)
      else:
        delEnv("ANTHROPIC_OAUTH_TOKEN")

  test "messages payload merges required and optional fields":
    let cfg = buildAnthropicConfig(%*{
      "api_token": "sk-ant-api-123",
      "model": "claude-3-5-haiku-latest"
    })
    let payload = buildAnthropicMessagesPayload(cfg, %*{
      "messages": [{"role": "user", "content": "hello"}],
      "max_tokens": 42,
      "temperature": 0.2,
      "system": "You are helpful."
    })
    check payload["model"].getStr() == "claude-3-5-haiku-latest"
    check payload["max_tokens"].getInt() == 42
    check payload["temperature"].getFloat() == 0.2
    check payload["system"].getStr() == "You are helpful."
    check payload["messages"].kind == JArray
    check payload["messages"].len == 1

  test "oauth payload prepends Claude Code system prompt":
    let cfg = buildAnthropicConfig(%*{
      "auth_token": "sk-ant-oat01-test-token",
      "model": "claude-sonnet-4-6"
    })
    let payload = buildAnthropicMessagesPayload(cfg, %*{
      "messages": [{"role": "user", "content": "hello"}],
      "max_tokens": 42,
      "system": "You are helpful."
    })
    check payload["system"].kind == JArray
    check payload["system"].len == 2
    check payload["system"][0]["type"].getStr() == "text"
    check payload["system"][0]["text"].getStr() == CLAUDE_CODE_SYSTEM_PROMPT
    check payload["system"][1]["type"].getStr() == "text"
    check payload["system"][1]["text"].getStr() == "You are helpful."

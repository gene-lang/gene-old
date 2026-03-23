import unittest, json, tables, os

import ../src/genex/ai/openai_client

suite "OpenAI Client":
  test "oauth token selects codex auth headers":
    let cfg = buildOpenAIConfig(%*{
      "auth_token": "oauth-token",
      "account_id": "acct-1",
      "model": "gpt-5.4"
    })
    check isCodexOAuth(cfg)
    check cfg.headers["Authorization"] == "Bearer oauth-token"
    check cfg.headers["originator"] == GENECLAW_CODEX_ORIGINATOR
    check cfg.headers["User-Agent"] == GENECLAW_CODEX_USER_AGENT
    check cfg.headers["ChatGPT-Account-Id"] == "acct-1"
    check cfg.base_url == DEFAULT_BASE_URL

  test "oauth env vars take precedence over api key mode":
    let had_api = existsEnv("OPENAI_API_KEY")
    let had_auth = existsEnv("OPENAI_AUTH_TOKEN")
    let old_api = getEnv("OPENAI_API_KEY")
    let old_auth = getEnv("OPENAI_AUTH_TOKEN")
    try:
      putEnv("OPENAI_API_KEY", "sk-api-test")
      putEnv("OPENAI_AUTH_TOKEN", "oauth-from-env")
      let cfg = buildOpenAIConfig()
      check isCodexOAuth(cfg)
      check cfg.auth_token == "oauth-from-env"
      check cfg.headers["Authorization"] == "Bearer oauth-from-env"
    finally:
      if had_api:
        putEnv("OPENAI_API_KEY", old_api)
      else:
        delEnv("OPENAI_API_KEY")
      if had_auth:
        putEnv("OPENAI_AUTH_TOKEN", old_auth)
      else:
        delEnv("OPENAI_AUTH_TOKEN")

  test "explicit api key does not inherit oauth token from env":
    let had_auth = existsEnv("OPENAI_AUTH_TOKEN")
    let old_auth = getEnv("OPENAI_AUTH_TOKEN")
    try:
      putEnv("OPENAI_AUTH_TOKEN", "oauth-from-env")
      let cfg = buildOpenAIConfig(%*{
        "api_key": "sk-explicit-test"
      })
      check not isCodexOAuth(cfg)
      check cfg.auth_token == ""
      check cfg.headers["Authorization"] == "Bearer sk-explicit-test"
      check not cfg.headers.hasKey("ChatGPT-Account-Id")
    finally:
      if had_auth:
        putEnv("OPENAI_AUTH_TOKEN", old_auth)
      else:
        delEnv("OPENAI_AUTH_TOKEN")

  test "codex payload uses responses contract":
    let cfg = buildOpenAIConfig(%*{
      "auth_token": "oauth-token",
      "model": "gpt-5.4"
    })
    let payload = buildCodexResponsesPayload(cfg, %*{
      "instructions": "You are helpful.",
      "input": [
        {"type": "message", "role": "user", "content": "Reply with OK."}
      ],
      "tools": [
        {
          "type": "function",
          "name": "write_file",
          "parameters": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            }
          }
        }
      ]
    })
    check payload["model"].getStr() == "gpt-5.4"
    check payload["instructions"].getStr() == "You are helpful."
    check payload["input"].kind == JArray
    check payload["input"].len == 1
    check payload["store"].getBool() == false
    check payload["stream"].getBool() == true
    check payload["tools"].kind == JArray
    check payload["tools"].len == 1
    check not payload.hasKey("max_output_tokens")

  test "codex sse parser returns completed text response":
    let response = parseCodexResponsesSSE("""
event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","object":"response","created_at":1,"status":"completed","model":"gpt-5.4","output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}

""")
    check response["status"].getStr() == "completed"
    check response["output"].kind == JArray
    check response["output"].len == 1
    check response["output"][0]["type"].getStr() == "message"
    check response["output"][0]["content"][0]["text"].getStr() == "OK"

  test "codex sse parser returns completed function call response":
    let response = parseCodexResponsesSSE("""
event: response.completed
data: {"type":"response.completed","response":{"id":"resp_2","object":"response","created_at":1,"status":"completed","model":"gpt-5.4","output":[{"id":"fc_1","type":"function_call","status":"completed","call_id":"call_1","name":"write_file","arguments":"{\"path\":\"hello.txt\",\"content\":\"hi\"}"}]}}

""")
    check response["output"].kind == JArray
    check response["output"].len == 1
    check response["output"][0]["type"].getStr() == "function_call"
    check response["output"][0]["call_id"].getStr() == "call_1"
    check response["output"][0]["name"].getStr() == "write_file"
    check response["output"][0]["arguments"].getStr() == """{"path":"hello.txt","content":"hi"}"""

  test "codex sse parser surfaces stream error":
    expect OpenAIError:
      discard parseCodexResponsesSSE("""
event: error
data: {"type":"error","code":"bad_request","message":"Instructions are required"}

""")

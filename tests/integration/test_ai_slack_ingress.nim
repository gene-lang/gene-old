import unittest
import std/json

import ../src/genex/ai/control_slack
import ../src/genex/ai/slack_ingress
import ../src/genex/ai/agent_runtime
import ../src/genex/ai/tools
import ../src/genex/ai/conversation
import ../src/genex/ai/utils

const TEST_NOW = 1700000000'i64 * 1000  # fixed test time in ms

proc echo_provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
  %*{"action": "final", "message": "echo: " & envelope.text}


suite "Slack ingress":
  test "rejects invalid signature":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let ingress = new_slack_ingress(
      signing_secret = "test-secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider
    )

    let resp = ingress.handle_slack_request(
      raw_body = "{}",
      timestamp_header = "1700000000",
      signature_header = "v0=invalid",
      now_ms = TEST_NOW
    )
    check resp.status_code == 401

  test "handles url verification challenge":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let ingress = new_slack_ingress(
      signing_secret = "test-secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider
    )

    let body = $(%*{"type": "url_verification", "challenge": "abc123"})
    let ts = "1700000000"
    let sig = compute_slack_signature("test-secret", ts, body)

    let resp = ingress.handle_slack_request(
      raw_body = body,
      timestamp_header = ts,
      signature_header = sig,
      now_ms = TEST_NOW
    )
    check resp.status_code == 200
    check resp.body["challenge"].getStr() == "abc123"

  test "processes event and runs agent":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let store = new_conversation_store()
    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider,
      conversation_store = store
    )

    let event_payload = %*{
      "type": "event_callback",
      "team_id": "T1",
      "event_id": "Ev1",
      "event_time": 1700000000,
      "event": {
        "type": "message",
        "user": "U1",
        "text": "hello agent",
        "channel": "C1",
        "ts": "1700000000.001"
      }
    }

    let body = $event_payload
    let ts = "1700000000"
    let sig = compute_slack_signature("secret", ts, body)

    let resp = ingress.handle_slack_request(
      raw_body = body,
      timestamp_header = ts,
      signature_header = sig,
      now_ms = TEST_NOW
    )
    check resp.status_code == 200
    check resp.body["ok"].getBool() == true
    check resp.body["state"].getStr() == "ArsCompleted"
    check resp.body["message"].getStr() == "echo: hello agent"

    # Verify conversation store recorded the exchange
    let session = "T1:C1"
    let recent = store.get_recent(session, 10)
    check recent.len == 2
    check recent[0].role == "user"
    check recent[0].content == "hello agent"
    check recent[1].role == "assistant"
    check recent[1].content == "echo: hello agent"

  test "deduplicates events by event_id":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider
    )

    let event_payload = %*{
      "type": "event_callback",
      "team_id": "T1",
      "event_id": "EvDup",
      "event_time": 1700000000,
      "event": {
        "type": "message",
        "user": "U1",
        "text": "dup test",
        "channel": "C1",
        "ts": "1700000000.001"
      }
    }

    let body = $event_payload
    let ts = "1700000000"
    let sig = compute_slack_signature("secret", ts, body)

    # First request processes normally
    let resp1 = ingress.handle_slack_request(body, ts, sig, now_ms = TEST_NOW)
    check resp1.status_code == 200
    check resp1.body.hasKey("run_id")

    # Second request with same event_id is deduplicated
    let resp2 = ingress.handle_slack_request(body, ts, sig, now_ms = TEST_NOW)
    check resp2.status_code == 200
    check not resp2.body.hasKey("run_id")  # Just an ack, no new run

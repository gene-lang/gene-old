import unittest
import std/json

import ../src/genex/ai/slack_socket_mode
import ../src/genex/ai/control_slack
import ../src/genex/ai/slack_ingress
import ../src/genex/ai/agent_runtime
import ../src/genex/ai/tools
import ../src/genex/ai/conversation
import ../src/genex/ai/utils


suite "Socket Mode envelope parsing":
  test "parses events_api envelope":
    let raw = $ %*{
      "envelope_id": "env-123",
      "type": "events_api",
      "accepts_response_payload": false,
      "retry_attempt": 0,
      "retry_reason": "",
      "payload": {
        "type": "event_callback",
        "team_id": "T1",
        "event_id": "Ev1",
        "event": {
          "type": "message",
          "user": "U1",
          "text": "hello",
          "channel": "C1",
          "ts": "1700000000.001"
        }
      }
    }

    let envelope = parse_envelope(raw)
    check envelope.envelope_id == "env-123"
    check envelope.envelope_type == "events_api"
    check envelope.accepts_response_payload == false
    check envelope.retry_attempt == 0
    check envelope.payload["type"].getStr() == "event_callback"
    check envelope.payload["event"]["text"].getStr() == "hello"

  test "parses hello envelope":
    let raw = $ %*{
      "type": "hello",
      "num_connections": 1,
      "debug_info": {"host": "applink-111"},
      "connection_info": {"app_id": "A111"}
    }

    let envelope = parse_envelope(raw)
    check envelope.envelope_type == "hello"
    check envelope.envelope_id == ""

  test "parses interactive envelope":
    let raw = $ %*{
      "envelope_id": "env-456",
      "type": "interactive",
      "accepts_response_payload": true,
      "payload": {"type": "block_actions", "trigger_id": "123"}
    }

    let envelope = parse_envelope(raw)
    check envelope.envelope_id == "env-456"
    check envelope.envelope_type == "interactive"
    check envelope.accepts_response_payload == true

  test "handles missing payload gracefully":
    let raw = $ %*{
      "envelope_id": "env-789",
      "type": "events_api"
    }

    let envelope = parse_envelope(raw)
    check envelope.envelope_id == "env-789"
    check envelope.payload.kind == JObject
    check envelope.payload.len == 0

  test "rejects non-object JSON":
    expect(ValueError):
      discard parse_envelope("\"not an object\"")

  test "parses retry fields":
    let raw = $ %*{
      "envelope_id": "env-retry",
      "type": "events_api",
      "retry_attempt": 2,
      "retry_reason": "timeout",
      "payload": {}
    }

    let envelope = parse_envelope(raw)
    check envelope.retry_attempt == 2
    check envelope.retry_reason == "timeout"


suite "Socket Mode ACK generation":
  test "generates simple ACK":
    let ack = make_ack("env-123")
    let parsed = parseJson(ack)
    check parsed["envelope_id"].getStr() == "env-123"
    check parsed.len == 1

  test "generates ACK with payload":
    let payload = %*{"text": "acknowledged"}
    let ack = make_ack_with_payload("env-456", payload)
    let parsed = parseJson(ack)
    check parsed["envelope_id"].getStr() == "env-456"
    check parsed["payload"]["text"].getStr() == "acknowledged"


suite "Socket Mode event extraction":
  test "extracts events_api payload":
    let envelope = SocketModeEnvelope(
      envelope_id: "env-1",
      envelope_type: "events_api",
      payload: %*{
        "type": "event_callback",
        "team_id": "T1",
        "event": {"type": "message", "user": "U1", "text": "hi", "channel": "C1", "ts": "1.1"}
      }
    )

    let payload = extract_event_payload(envelope)
    check not payload.isNil
    check payload["type"].getStr() == "event_callback"
    check payload["event"]["text"].getStr() == "hi"

  test "returns nil for non-events_api":
    let envelope = SocketModeEnvelope(
      envelope_id: "env-2",
      envelope_type: "interactive",
      payload: %*{"type": "block_actions"}
    )

    let payload = extract_event_payload(envelope)
    check payload.isNil

  test "extracted payload works with slack_event_to_command":
    let envelope = SocketModeEnvelope(
      envelope_id: "env-3",
      envelope_type: "events_api",
      payload: %*{
        "type": "event_callback",
        "team_id": "T1",
        "event_id": "Ev42",
        "event": {
          "type": "message",
          "user": "U1",
          "text": "socket mode test",
          "channel": "C1",
          "ts": "1700000000.001"
        }
      }
    )

    let payload = extract_event_payload(envelope)
    check not payload.isNil

    let cmd = slack_event_to_command(payload)
    check cmd.source == CsSlack
    check cmd.workspace_id == "T1"
    check cmd.user_id == "U1"
    check cmd.channel_id == "C1"
    check cmd.text == "socket mode test"


suite "Socket Mode client construction":
  test "creates client with defaults":
    let client = new_slack_socket_mode(app_token = "xapp-test")
    check client.app_token == "xapp-test"
    check client.bot_token == ""
    check client.running == false
    check client.ws.isNil
    check client.reconnect_delay_ms == 1000
    check client.max_reconnect_delay_ms == 30000

  test "creates client with all options":
    var handler_called = false
    let handler = proc(et: string; p: JsonNode) {.gcsafe.} =
      handler_called = true

    let client = new_slack_socket_mode(
      app_token = "xapp-abc",
      bot_token = "xoxb-bot",
      event_handler = handler,
      reconnect_delay_ms = 2000,
      max_reconnect_delay_ms = 60000
    )
    check client.app_token == "xapp-abc"
    check client.bot_token == "xoxb-bot"
    check client.reconnect_delay_ms == 2000
    check client.max_reconnect_delay_ms == 60000
    check not client.event_handler.isNil


suite "Socket Mode ingress integration":
  test "start_socket_mode returns configured client":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)

    proc echo_provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      %*{"action": "final", "message": "echo: " & envelope.text}

    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-bot",
      runtime = runtime,
      provider = echo_provider
    )

    let client = ingress.start_socket_mode("xapp-test-token")
    check client.app_token == "xapp-test-token"
    check client.bot_token == "xoxb-bot"
    check not client.event_handler.isNil
    check client.running == false

  test "dispatch_socket_mode_event processes events through pipeline":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let store = new_conversation_store()

    proc echo_provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      %*{"action": "final", "message": "echo: " & envelope.text}

    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider,
      conversation_store = store
    )

    let client = ingress.start_socket_mode("xapp-test")

    # Simulate receiving an events_api payload
    let payload = %*{
      "type": "event_callback",
      "team_id": "T1",
      "event_id": "EvSocket1",
      "event": {
        "type": "message",
        "user": "U1",
        "text": "hello from socket mode",
        "channel": "C1",
        "ts": "1700000000.001"
      }
    }

    # Dispatch through the handler
    client.event_handler("events_api", payload)

    # Verify conversation was recorded
    let session = "T1:C1"
    let recent = store.get_recent(session, 10)
    check recent.len == 2
    check recent[0].role == "user"
    check recent[0].content == "hello from socket mode"
    check recent[1].role == "assistant"
    check recent[1].content == "echo: hello from socket mode"

  test "dispatch deduplicates by event_id":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let store = new_conversation_store()

    proc echo_provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      %*{"action": "final", "message": "echo: " & envelope.text}

    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider,
      conversation_store = store
    )

    let client = ingress.start_socket_mode("xapp-test")

    let payload = %*{
      "type": "event_callback",
      "team_id": "T1",
      "event_id": "EvDupSocket",
      "event": {
        "type": "message",
        "user": "U1",
        "text": "dup test",
        "channel": "C1",
        "ts": "1700000000.001"
      }
    }

    # First dispatch goes through
    client.event_handler("events_api", payload)
    let session = "T1:C1"
    check store.get_recent(session, 10).len == 2

    # Second dispatch with same event_id is deduplicated
    client.event_handler("events_api", payload)
    check store.get_recent(session, 10).len == 2  # No new messages

  test "dispatch ignores non-events_api":
    let registry = new_tool_registry()
    let runtime = new_agent_runtime(registry)
    let store = new_conversation_store()

    proc echo_provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      %*{"action": "final", "message": "should not reach"}

    let ingress = new_slack_ingress(
      signing_secret = "secret",
      bot_token = "xoxb-fake",
      runtime = runtime,
      provider = echo_provider,
      conversation_store = store
    )

    let client = ingress.start_socket_mode("xapp-test")

    # interactive type should be ignored
    client.event_handler("interactive", %*{"type": "block_actions"})
    check store.get_recent("any:key", 10).len == 0

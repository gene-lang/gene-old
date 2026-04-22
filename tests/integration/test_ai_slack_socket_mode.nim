import unittest
import std/json
import std/[locks, tables, times, os]
import gene/types except Exception
import gene/vm
import gene/vm/actor
import gene/vm/extension
import gene/vm/extension_abi
import gene/vm/thread

import ../../src/genex/ai/slack_socket_mode
import ../../src/genex/ai/control_slack
import ../../src/genex/ai/slack_ingress
import ../../src/genex/ai/agent_runtime
import ../../src/genex/ai/tools
import ../../src/genex/ai/conversation
import ../../src/genex/ai/utils
from ../../src/genex/ai/bindings import gene_init, reset_slack_socket_mode_for_test,
  create_slack_socket_binding_for_test, jsonToGeneValue

var binding_results_lock: Lock
var binding_results: seq[string] = @[]
initLock(binding_results_lock)

proc build_host(): GeneHostAbi =
  GeneHostAbi(
    abi_version: GENE_EXT_ABI_VERSION,
    user_data: cast[pointer](VM),
    app_value: App,
    symbols_data: nil,
    log_message_fn: nil,
    register_scheduler_callback_fn: nil,
    register_port_fn: host_register_port_bridge,
    call_port_fn: host_call_port_bridge,
    result_namespace: nil
  )

proc await_vm_future(future_value: Value, timeout_ms = 2_000): Value =
  let deadline = epochTime() + (timeout_ms.float / 1000.0)
  let future = future_value.ref.future
  while future.state == FsPending and epochTime() < deadline:
    VM.event_loop_counter = 100
    poll_event_loop(VM)
    sleep(10)

  check future.state != FsPending
  check future.state == FsSuccess
  future.value

proc command_text(value: Value): string =
  if value.kind != VkMap:
    return ""
  let text_val = map_data(value).getOrDefault("text".to_key(), NIL)
  if text_val.kind != VkString:
    return ""
  text_val.str

proc record_binding_result(tag, text: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(binding_results_lock):
      binding_results.add(tag & ":" & text)

proc binding_callback_one(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard arg_count
  record_binding_result("one", command_text(get_positional_arg(args, 0, has_keyword_args)))
  NIL

proc binding_callback_two(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard arg_count
  record_binding_result("two", command_text(get_positional_arg(args, 0, has_keyword_args)))
  NIL


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


suite "Socket Mode binding ownership":
  test "separate actor-backed bindings keep independent callbacks":
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()
    init_actor_runtime()
    clear_registered_extension_ports_for_test()
    reset_slack_socket_mode_for_test()
    withLock(binding_results_lock):
      binding_results.setLen(0)

    var host = build_host()
    check gene_init(addr host) == int32(GeneExtOk)

    actor_enable_for_test(2)
    let binding_one = create_slack_socket_binding_for_test(VM, NativeFn(binding_callback_one).to_value(), "")
    let binding_two = create_slack_socket_binding_for_test(VM, NativeFn(binding_callback_two).to_value(), "")

    check binding_one.kind == VkActor
    check binding_two.kind == VkActor

    let envelope_one = new_command_envelope(
      command_id = "cmd-1",
      source = CsSlack,
      workspace_id = "T1",
      user_id = "U1",
      channel_id = "C1",
      text = "hello one"
    )
    let envelope_two = new_command_envelope(
      command_id = "cmd-2",
      source = CsSlack,
      workspace_id = "T2",
      user_id = "U2",
      channel_id = "C2",
      text = "hello two"
    )

    discard await_vm_future(actor_send_value(VM, binding_one, jsonToGeneValue(command_to_json(envelope_one)), true))
    discard await_vm_future(actor_send_value(VM, binding_two, jsonToGeneValue(command_to_json(envelope_two)), true))

    var got: seq[string] = @[]
    withLock(binding_results_lock):
      got = binding_results
    check got == @["one:hello one", "two:hello two"]

## Slack Socket Mode client
##
## Connects to Slack via an outbound WebSocket (no public URL needed).
## Uses an app-level token (xapp-...) to obtain a one-time WSS URL,
## then receives event envelopes, ACKs them, and dispatches payloads
## to a caller-supplied handler.
##
## Lifecycle:
##   1. POST apps.connections.open → get WSS URL
##   2. ws_connect(url)
##   3. recv loop: parse envelope → ACK → dispatch
##   4. Auto-reconnect on close/error

import std/[json, httpclient, strutils]
import asyncdispatch

import ../websocket
import ../../gene/logging_core
import ../../gene/vm/extension_abi

const SlackSocketModeLogger = "genex/ai/slack_socket_mode"

template slack_socket_mode_log(level: LogLevel, message: untyped) =
  if extension_log_enabled(level, SlackSocketModeLogger):
    extension_log_message(level, SlackSocketModeLogger, message)


type
  SocketModeEventHandler* = proc(event_type: string; payload: JsonNode) {.gcsafe.}

  SlackSocketMode* = ref object
    app_token*: string
    bot_token*: string
    ws*: WebSocket
    running*: bool
    reconnect_delay_ms*: int
    max_reconnect_delay_ms*: int
    event_handler*: SocketModeEventHandler

  SocketModeEnvelope* = object
    envelope_id*: string
    envelope_type*: string  # "events_api", "interactive", "slash_commands", "hello"
    accepts_response_payload*: bool
    payload*: JsonNode
    retry_attempt*: int
    retry_reason*: string


proc new_slack_socket_mode*(
  app_token: string;
  bot_token: string = "";
  event_handler: SocketModeEventHandler = nil;
  reconnect_delay_ms = 1000;
  max_reconnect_delay_ms = 30000
): SlackSocketMode =
  SlackSocketMode(
    app_token: app_token,
    bot_token: bot_token,
    ws: nil,
    running: false,
    reconnect_delay_ms: reconnect_delay_ms,
    max_reconnect_delay_ms: max_reconnect_delay_ms,
    event_handler: event_handler
  )


# ---------------------------------------------------------------------------
# Envelope parsing
# ---------------------------------------------------------------------------

proc json_get_str(obj: JsonNode; key: string): string =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JString:
    obj[key].getStr()
  else:
    ""

proc json_get_int(obj: JsonNode; key: string): int =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JInt:
    obj[key].getInt()
  else:
    0

proc json_get_bool(obj: JsonNode; key: string): bool =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JBool:
    obj[key].getBool()
  else:
    false

proc parse_envelope*(data: string): SocketModeEnvelope =
  ## Parse a Socket Mode envelope from raw JSON text.
  let obj = parseJson(data)
  if obj.kind != JObject:
    raise newException(ValueError, "Socket Mode envelope must be a JSON object")

  SocketModeEnvelope(
    envelope_id: json_get_str(obj, "envelope_id"),
    envelope_type: json_get_str(obj, "type"),
    accepts_response_payload: json_get_bool(obj, "accepts_response_payload"),
    payload: if obj.hasKey("payload") and obj["payload"].kind == JObject: obj["payload"] else: newJObject(),
    retry_attempt: json_get_int(obj, "retry_attempt"),
    retry_reason: json_get_str(obj, "retry_reason")
  )


# ---------------------------------------------------------------------------
# ACK generation
# ---------------------------------------------------------------------------

proc make_ack*(envelope_id: string): string =
  ## Build the JSON ACK message to send back over the WebSocket.
  $ %*{"envelope_id": envelope_id}

proc make_ack_with_payload*(envelope_id: string; payload: JsonNode): string =
  ## Build an ACK with a response payload (for interactive messages).
  $ %*{"envelope_id": envelope_id, "payload": payload}


# ---------------------------------------------------------------------------
# Extract event_callback payload
# ---------------------------------------------------------------------------

proc extract_event_payload*(envelope: SocketModeEnvelope): JsonNode =
  ## Extract the inner event_callback-style payload from a Socket Mode envelope.
  ## The envelope's payload field contains the same structure as a webhook
  ## event_callback, so this can be fed directly to slack_event_to_command().
  if envelope.envelope_type != "events_api":
    return nil
  envelope.payload


# ---------------------------------------------------------------------------
# WSS URL acquisition
# ---------------------------------------------------------------------------

proc get_ws_url*(app_token: string; base_url = "https://slack.com"): string =
  ## Call apps.connections.open to obtain a one-time WebSocket URL.
  let url = base_url & "/api/apps.connections.open"
  var http = newHttpClient()
  try:
    http.headers = newHttpHeaders({
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": "Bearer " & app_token
    })
    let response = http.request(url, httpMethod = HttpPost, body = "")
    let body = parseJson(response.body)

    if body.kind != JObject or not body.hasKey("ok") or not body["ok"].getBool():
      let err =
        if body.kind == JObject and body.hasKey("error"):
          body["error"].getStr()
        else:
          "unknown error"
      raise newException(IOError, "apps.connections.open failed: " & err)

    let ws_url = json_get_str(body, "url")
    if ws_url.len == 0:
      raise newException(IOError, "apps.connections.open returned empty URL")
    ws_url
  finally:
    http.close()


# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

proc connect*(client: SlackSocketMode) {.async.} =
  ## Obtain a WSS URL and connect.
  let url = get_ws_url(client.app_token)
  client.ws = await ws_connect(url)


# ---------------------------------------------------------------------------
# Async receive loop
# ---------------------------------------------------------------------------

proc handle_envelope(client: SlackSocketMode; raw: string) {.async.} =
  ## Parse an envelope, ACK it, and dispatch to the event handler.
  var envelope: SocketModeEnvelope
  try:
    envelope = parse_envelope(raw)
  except CatchableError as e:
    slack_socket_mode_log(LlWarn, "Socket Mode: failed to parse envelope: " & e.msg)
    return

  # "hello" messages don't need ACK — they confirm the connection is live
  if envelope.envelope_type == "hello":
    slack_socket_mode_log(LlDebug, "Socket Mode: connected (hello received)")
    return

  # ACK immediately
  if envelope.envelope_id.len > 0 and not client.ws.isNil and not client.ws.closed:
    try:
      await ws_send(client.ws, make_ack(envelope.envelope_id))
    except CatchableError as e:
      slack_socket_mode_log(LlWarn, "Socket Mode: failed to send ACK: " & e.msg)

  # Dispatch events_api envelopes
  if envelope.envelope_type == "events_api":
    let payload = extract_event_payload(envelope)
    if not payload.isNil and not client.event_handler.isNil:
      try:
        client.event_handler("events_api", payload)
      except CatchableError as e:
        slack_socket_mode_log(LlError, "Socket Mode: event handler error: " & e.msg)

proc run_loop*(client: SlackSocketMode) {.async.} =
  ## Receive frames until the connection closes.
  while client.running and not client.ws.isNil and not client.ws.closed:
    let frame = await ws_recv(client.ws)
    if frame.opcode == WsOpClose:
      slack_socket_mode_log(LlDebug, "Socket Mode: connection closed by server")
      break
    if frame.opcode == WsOpText and frame.payload.len > 0:
      await handle_envelope(client, frame.payload)


# ---------------------------------------------------------------------------
# Start with auto-reconnect
# ---------------------------------------------------------------------------

proc start*(client: SlackSocketMode) {.async.} =
  ## Connect and run the receive loop with automatic reconnection.
  client.running = true
  var delay = client.reconnect_delay_ms

  while client.running:
    try:
      slack_socket_mode_log(LlDebug, "Socket Mode: connecting...")
      await client.connect()
      slack_socket_mode_log(LlDebug, "Socket Mode: WebSocket connected")
      delay = client.reconnect_delay_ms  # reset backoff on success
      await client.run_loop()
    except CatchableError as e:
      slack_socket_mode_log(LlWarn, "Socket Mode: error: " & e.msg)

    if not client.running:
      break

    slack_socket_mode_log(LlDebug, "Socket Mode: reconnecting in " & $delay & "ms...")
    await sleepAsync(delay)
    delay = min(delay * 2, client.max_reconnect_delay_ms)

proc stop*(client: SlackSocketMode) {.async.} =
  ## Gracefully stop the Socket Mode client.
  client.running = false
  if not client.ws.isNil and not client.ws.closed:
    await ws_close(client.ws)

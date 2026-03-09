import std/json
import std/times
import std/strutils


type
  CommandSource* = enum
    CsUnknown
    CsSlack
    CsTelegram
    CsWeb

  CommandEnvelope* = object
    command_id*: string
    source*: CommandSource
    workspace_id*: string
    user_id*: string
    channel_id*: string
    thread_id*: string
    text*: string
    attachments*: JsonNode
    metadata*: JsonNode
    received_at_ms*: int64

  AgentRunState* = enum
    ArsQueued
    ArsRunning
    ArsWaitingTool
    ArsCompleted
    ArsFailed
    ArsCancelled

  AgentRunEvent* = enum
    AreStart
    AreWaitTool
    AreToolResult
    AreComplete
    AreFail
    AreCancel

  AgentRun* = object
    run_id*: string
    state*: AgentRunState
    error_message*: string
    created_at_ms*: int64
    updated_at_ms*: int64

proc now_unix_ms*(): int64 {.inline.} =
  (epochTime() * 1000).int64

proc parse_command_source*(s: string): CommandSource =
  case s.toLowerAscii()
  of "slack": CsSlack
  of "telegram": CsTelegram
  of "web": CsWeb
  else: CsUnknown

proc source_to_string*(source: CommandSource): string =
  case source
  of CsSlack: "slack"
  of CsTelegram: "telegram"
  of CsWeb: "web"
  else: "unknown"

proc new_command_envelope*(
  command_id: string;
  source = CsUnknown;
  workspace_id = "";
  user_id = "";
  channel_id = "";
  thread_id = "";
  text = "";
  attachments: JsonNode = nil;
  metadata: JsonNode = nil
): CommandEnvelope =
  CommandEnvelope(
    command_id: command_id,
    source: source,
    workspace_id: workspace_id,
    user_id: user_id,
    channel_id: channel_id,
    thread_id: thread_id,
    text: text,
    attachments: if attachments.isNil: newJArray() else: attachments,
    metadata: if metadata.isNil: newJObject() else: metadata,
    received_at_ms: now_unix_ms()
  )

proc command_to_json*(cmd: CommandEnvelope): JsonNode =
  %*{
    "command_id": cmd.command_id,
    "source": source_to_string(cmd.source),
    "workspace_id": cmd.workspace_id,
    "user_id": cmd.user_id,
    "channel_id": cmd.channel_id,
    "thread_id": cmd.thread_id,
    "text": cmd.text,
    "attachments": if cmd.attachments.isNil: newJArray() else: cmd.attachments,
    "metadata": if cmd.metadata.isNil: newJObject() else: cmd.metadata,
    "received_at_ms": cmd.received_at_ms
  }

proc get_str_field(obj: JsonNode; key: string): string =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JString:
    obj[key].getStr()
  else:
    ""

proc get_int_field(obj: JsonNode; key: string): int64 =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind in {JInt, JFloat}:
    obj[key].getInt().int64
  else:
    0'i64

proc command_from_json*(obj: JsonNode): CommandEnvelope =
  if obj.kind != JObject:
    raise newException(ValueError, "CommandEnvelope JSON must be an object")
  result = new_command_envelope(
    command_id = get_str_field(obj, "command_id"),
    source = parse_command_source(get_str_field(obj, "source")),
    workspace_id = get_str_field(obj, "workspace_id"),
    user_id = get_str_field(obj, "user_id"),
    channel_id = get_str_field(obj, "channel_id"),
    thread_id = get_str_field(obj, "thread_id"),
    text = get_str_field(obj, "text"),
    attachments =
      if obj.hasKey("attachments") and obj["attachments"].kind == JArray: obj["attachments"]
      else: newJArray(),
    metadata =
      if obj.hasKey("metadata") and obj["metadata"].kind == JObject: obj["metadata"]
      else: newJObject()
  )
  let ts = get_int_field(obj, "received_at_ms")
  if ts > 0:
    result.received_at_ms = ts

proc new_agent_run*(run_id: string): AgentRun =
  let ts = now_unix_ms()
  AgentRun(
    run_id: run_id,
    state: ArsQueued,
    error_message: "",
    created_at_ms: ts,
    updated_at_ms: ts
  )

proc can_transition*(current: AgentRunState; target: AgentRunState): bool =
  case current
  of ArsQueued:
    target in {ArsRunning, ArsCancelled}
  of ArsRunning:
    target in {ArsWaitingTool, ArsCompleted, ArsFailed, ArsCancelled}
  of ArsWaitingTool:
    target in {ArsRunning, ArsFailed, ArsCancelled}
  of ArsCompleted, ArsFailed, ArsCancelled:
    false

proc apply_transition*(run: var AgentRun; target: AgentRunState; error_message = "") =
  if not can_transition(run.state, target):
    raise newException(ValueError, "Invalid state transition: " & $run.state & " -> " & $target)
  run.state = target
  run.updated_at_ms = now_unix_ms()
  if target == ArsFailed:
    run.error_message = error_message

proc apply_event*(run: var AgentRun; event: AgentRunEvent; error_message = "") =
  case event
  of AreStart:
    run.apply_transition(ArsRunning)
  of AreWaitTool:
    run.apply_transition(ArsWaitingTool)
  of AreToolResult:
    run.apply_transition(ArsRunning)
  of AreComplete:
    run.apply_transition(ArsCompleted)
  of AreFail:
    run.apply_transition(ArsFailed, error_message)
  of AreCancel:
    run.apply_transition(ArsCancelled)

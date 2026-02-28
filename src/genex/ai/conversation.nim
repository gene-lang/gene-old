import std/tables
import std/times
import std/json
import std/strutils


type
  ConversationEvent* = object
    role*: string
    content*: string
    created_at_ms*: int64
    metadata*: JsonNode

  ConversationStore* = ref object
    sessions*: Table[string, seq[ConversationEvent]]

proc now_unix_ms(): int64 {.inline.} =
  (epochTime() * 1000).int64

proc new_conversation_store*(): ConversationStore =
  ConversationStore(sessions: initTable[string, seq[ConversationEvent]]())

proc new_conversation_event*(role: string; content: string; metadata: JsonNode = nil): ConversationEvent =
  ConversationEvent(
    role: role,
    content: content,
    created_at_ms: now_unix_ms(),
    metadata: if metadata.isNil: newJObject() else: metadata
  )

proc append_event*(store: ConversationStore; session_id: string; event: ConversationEvent) =
  if store.isNil:
    raise newException(ValueError, "ConversationStore is nil")
  if session_id.len == 0:
    raise newException(ValueError, "session_id cannot be empty")

  if not store.sessions.hasKey(session_id):
    store.sessions[session_id] = @[]
  store.sessions[session_id].add(event)

proc append_message*(store: ConversationStore; session_id: string; role: string; content: string; metadata: JsonNode = nil) =
  store.append_event(session_id, new_conversation_event(role, content, metadata))

proc get_recent*(store: ConversationStore; session_id: string; limit = 20): seq[ConversationEvent] =
  if store.isNil or not store.sessions.hasKey(session_id):
    return @[]
  let events = store.sessions[session_id]
  if limit <= 0 or events.len <= limit:
    return events
  events[events.len - limit .. ^1]

proc prune_session*(store: ConversationStore; session_id: string; keep_last: int) =
  if store.isNil or not store.sessions.hasKey(session_id):
    return
  if keep_last <= 0:
    store.sessions[session_id] = @[]
    return

  let events = store.sessions[session_id]
  if events.len <= keep_last:
    return
  store.sessions[session_id] = events[events.len - keep_last .. ^1]

proc summarize_recent*(store: ConversationStore; session_id: string; limit = 12): string =
  let recent = store.get_recent(session_id, limit)
  if recent.len == 0:
    return ""

  var lines: seq[string] = @[]
  for item in recent:
    lines.add(item.role.toLowerAscii() & ": " & item.content)
  lines.join("\n")

proc event_to_json*(event: ConversationEvent): JsonNode =
  %*{
    "role": event.role,
    "content": event.content,
    "created_at_ms": event.created_at_ms,
    "metadata": event.metadata
  }

proc events_to_json*(events: seq[ConversationEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add(event.event_to_json())

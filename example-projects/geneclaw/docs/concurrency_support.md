# GeneClaw Concurrency Support

## Overview

GeneClaw uses the actor runtime for concurrent request handling.

A thin ingress layer accepts HTTP, WebSocket, and Slack socket-mode traffic, converts each request into a literal Gene message, routes it to an actor handle, awaits the reply, and writes the result back to the client.

Business logic lives in actors. The ingress only owns transport concerns and minimal routing state.

## Startup

Actors are disabled by default in Gene. GeneClaw must enable the actor runtime during startup before spawning any handler actors:

```gene
(gene/actor/enable ^workers 8)
```

The worker count is application-level configuration. The actor runtime mailbox limit remains the global default from [actor_support.md](/Users/gcao/gene-workspace/gene-old/docs/actor_support.md#L182).

## Architecture

```
                    ┌──────────────────────────────┐
                    │        Ingress Layer         │
                    │   (Nim, 1-2 threads)         │
                    │                              │
                    │  HTTP ─┐                     │
                    │  WS   ─┼─→ parse + route     │
                    │  Slack ─┘                    │
                    └──────────────┬───────────────┘
                                   │
                     handler/.send_expect_reply
                                   │
                    ┌──────────────▼───────────────┐
                    │        Handler Actors        │
                    │    (Gene actor runtime)      │
                    │                              │
                    │  ┌────────┐ ┌────────┐       │
                    │  │Actor A │ │Actor B │  ...  │
                    │  └────────┘ └────────┘       │
                    └──────────────────────────────┘
```

## Ingress Layer

The ingress layer:
- accepts HTTP, WebSocket, and Slack socket-mode traffic
- parses each incoming request into a literal Gene message
- selects an actor handle
- dispatches with request/reply semantics equivalent to `(handler .send_expect_reply msg)`
- awaits the reply and translates it back to the transport response

The ingress stays thin:
- no business logic
- no conversation state
- only minimal routing state when needed, such as a handler pool or a `session_id -> actor` table

## Handler Actors

Each handler actor processes one message at a time and does the full unit of work itself: database reads and writes, LLM calls, tool execution, and response construction.

```gene
(var request_handler
  (fn [ctx msg state]
    (case msg/type
     when "chat"
      (do
        (var session (db_query "SELECT * FROM sessions WHERE id = ?" [msg/session_id]))
        (var response (call_llm msg/content session/history))
        (var updated_history (append_history session/history msg/content response))
        (db_exec "UPDATE sessions SET history = ? WHERE id = ?" [updated_history msg/session_id])
        (ctx .reply {^type "chat" ^content response})
        state)
     when "tool_call"
      (do
        (var result (run_tool msg/tool msg/args))
        (ctx .reply {^type "tool_result" ^result result})
        state)
     else
      (do
        (ctx .reply {^type "error" ^code "GENECLAW.UNSUPPORTED_MESSAGE"})
        state))))
```

The ingress should only send literal message payloads. Request instances and live connection objects should not cross the actor boundary.

## Routing Models

GeneClaw can route requests in two ways.

### Pool of Identical Actors

Ingress maintains a fixed pool and distributes requests round-robin or by current load.

```gene
(var handlers [])

(for i in (range worker_count)
  (handlers .add (gene/actor/spawn request_handler)))
```

This model is simple and works well when requests are mostly independent.

### One Actor Per Session

Ingress routes all messages for the same session to the same actor handle, so a conversation is serialized naturally.

This is the recommended default for GeneClaw, but it requires explicit lifecycle management because the current actor proposal has no automatic actor GC.

Ingress responsibilities in the per-session model:
- maintain `session_id -> actor` routing state
- track `last_seen` for each session actor
- stop and remove actors that have been idle past the configured session timeout
- stop and remove the actor immediately when a session is deleted or closed

This is infrastructure state, not business state. Conversation history still belongs in the database and actor-local execution.

## Request Flow

1. A request arrives at ingress.
2. Ingress converts it to a literal Gene message.
3. Ingress selects the target actor handle.
4. Ingress dispatches with `.send_expect_reply`.
5. The actor performs the full application workflow.
6. The actor replies with a literal response payload.
7. Ingress writes the result back to HTTP, WebSocket, or Slack.

There is one level of work. Handler actors do not delegate to sub-actors in the MVP design.

## Overload and Failure Policy

The actor runtime uses bounded mailboxes. When handlers are slow, ingress must not wait forever.

GeneClaw policy:
- ingress applies a bounded dispatch-and-reply timeout per request
- if dispatch cannot complete within that deadline, HTTP returns `503 Service Unavailable`
- WebSocket and Slack transports return a structured temporary-overload error
- if a handler raises during `send_expect_reply`, the exception propagates back through the reply future and ingress converts it into a transport error response

This keeps actor backpressure from turning into unbounded transport stalls.

## Why Actors

- **No shared mutable conversation state**: request execution is isolated per actor
- **No locks in application code**: actors process one message at a time
- **Natural session serialization**: the per-session model prevents concurrent mutation of one conversation
- **Failure containment**: one handler error does not crash the whole service
- **Simple mental model**: ingress routes, actor executes, ingress replies

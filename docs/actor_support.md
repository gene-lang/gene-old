# Actor Support for Gene

## Status

This document is a proposal for a minimal actor API in Gene.

The goal is a simple programming model for concurrency:
- spawn an actor
- send it messages
- optionally await a reply
- stop it

This proposal intentionally avoids Erlang-style completeness in the first version. Name registries, supervision, and other advanced features should come later if the core model proves useful.

## Goals

- Provide a simpler alternative to explicit threads for common concurrent workflows
- Keep actor state isolated and message-driven
- Reuse the existing serialization boundary for cross-worker messages
- Reuse the existing `Future` machinery for request/reply
- Keep the public API small and learnable

## Non-Goals for MVP

- Named actors or global/process-local registries
- Selective `receive`
- `link`, `monitor`, `trap_exit`, or supervisors
- Public mailbox tuning knobs
- Actor migration between workers
- Hot code swap
- Actor garbage collection beyond explicit stop

## Core Model

An actor is:
- a handle
- a private mailbox
- a private state value
- a handler function

An actor processes one message at a time. User code does not manage threads directly. The runtime is responsible for scheduling actors onto workers.

## MVP API

### Spawning

`gene/actor/spawn` has one shape:

```gene
# ^state is optional; default is nil
(gene/actor/spawn
  ^state initial_state
  handler)
```

The handler always has the same signature:

```gene
(fn [ctx msg state]
  state)
```

- `ctx` is the actor context for the current message
- `msg` is the delivered message
- `state` is the actor's current private state
- the handler return value becomes the actor's next state

Example:

```gene
(var counter
  (gene/actor/spawn
    ^state {^count 0}
    (fn [ctx msg state]
      (case msg/kind
      when "increment"
        {^count (state/count + 1)}
      when "get"
        (ctx .reply state/count)
        state
      when "stop"
        ctx/.stop
        state
      else
        state))))
```

### Sending

The MVP uses actor handles only. Sending by name is out of scope.

```gene
(counter .send {^kind "increment"})

(var result
  (await (counter .send_expect_reply {^kind "get"})))
```

- `(actor .send msg)` enqueues a message and returns immediately
- `(actor .send_expect_reply msg)` enqueues a message and returns a `Future`

### Stopping

There are two ways to stop an actor:

```gene
counter/.stop
```

or from inside the handler:

```gene
ctx/.stop
```

There is no implicit actor `self` function in the MVP. Inside a handler, self access goes through `ctx`.

## Actor Context

The handler context keeps reply and lifecycle operations explicit.

MVP context methods:

- `ctx/.actor` returns the current actor handle
- `(ctx .reply value)` resolves the pending request created by `send_expect_reply`
- `ctx/.stop` marks the actor to stop after the current message finishes

This proposal uses one request/reply model only:
- `send` is fire-and-forget
- `send_expect_reply` creates a pending reply slot
- the handler answers with `(ctx .reply value)`
- if the handler raises before replying, the reply future fails with that exception and `await` propagates it back to the sender

If a handler calls `(ctx .reply ...)` for a message that was not sent with `send_expect_reply`, the runtime should raise an error.

## State Model

The state model is intentionally simple:

- the runtime passes the current state into each handler call
- the handler returns the next state
- state is private to the actor

There is no separate stateless API. A stateless actor simply ignores `state` and returns it unchanged.

Example:

```gene
(var logger
  (gene/actor/spawn
    (fn [ctx msg state]
      (println msg)
      state)))
```

## Message Model

Messages follow the same isolation rules as current thread messaging:

- literals are sendable
- arrays, maps, and Gene values are copied through the serialization boundary
- functions, classes, instances, and threads are not sendable
- actor handles are sendable

The exact implementation can reuse the same serialization strategy already used for thread communication.

## Error Handling

When a handler raises an unhandled exception:
- The actor **does not stop** — it continues processing the next message
- The runtime logs the exception at error level
- If the current message was sent via `send_expect_reply`, the pending reply future transitions to `failure` with the same exception, and `await` on the sender side re-raises it
- Fire-and-forget messages (`send`) have no sender notification

When `ctx/.stop` is called or `actor/.stop` is called externally:
- The actor stops after the current message finishes
- Remaining messages in the mailbox are dropped
- All pending reply futures transition to `failure`

When `send` or `send_expect_reply` targets a stopped actor:
- The runtime raises an error

## Runtime Notes

The programming model should be simple even if the runtime is not.

For the MVP, the runtime should stay conservative:

- actors run on an internal worker pool
- each actor is assigned to one worker when spawned
- actor state stays with that worker in the initial implementation
- each actor mailbox is bounded FIFO with a default limit of 10,000 messages
- when a mailbox is full, `send` and `send_expect_reply` block until capacity is available
- each scheduled turn processes one message

This avoids the complexity of moving live actor state across worker VMs in the first version.

## Configuration

The actor system is a global runtime subsystem.

For the MVP:
- it is **disabled by default**
- it is enabled programmatically by application code
- worker threads are created only when the actor system is enabled

If the actor system is disabled, calling `gene/actor/spawn` raises a runtime error.

Proposed startup API:

```gene
(gene/actor/enable)
(gene/actor/enable ^workers 4)
```

Rules:
- `gene/actor/enable` is called once during application startup, before any `gene/actor/spawn`
- `^workers` is optional; if omitted, it defaults to the number of CPU cores
- calling `gene/actor/enable` after actors have already been spawned raises a runtime error
- calling `gene/actor/enable` more than once raises a runtime error

Out of scope for the MVP:
- per-actor worker selection
- global actor count limits
- mailbox limit configuration
- config-file based actor runtime setup

The mailbox limit remains a fixed runtime default of `10,000` messages in the MVP.

## Deferred Features

These are explicitly out of scope for the MVP and should be designed separately after the core API lands:

### Named Actors

Possible future APIs:

```gene
(register actor "order-service")
(whereis "order-service")
```

### Supervision and Failure Propagation

Possible future APIs:

```gene
(link actor_a actor_b)
(monitor actor)
(trap_exit true)
```

### Advanced Mailbox Behavior

Possible future work:

- mailbox size configuration
- overflow policy
- priority system messages
- metrics

### Advanced Scheduling

Possible future work:

- work stealing
- actor rebalancing
- batching

### Selective Receive

This is intentionally not part of the MVP.

The proposed actor model is callback-driven: one delivered message invokes one handler call. Adding `receive` would introduce a second mailbox-consumption model and should only be considered in a separate proposal.

## Implementation Strategy

### Phase 1: Minimal Actor Runtime

- Global actor runtime enable API with `(gene/actor/enable ^workers ...)`
- Actor handle type
- `gene/actor/spawn`
- `send`
- `send_expect_reply`
- `stop`
- Actor context with `ctx/.actor`, `.reply`, `.stop`
- Private state carried by handler return value
- Bounded FIFO mailbox with a default limit of 10,000 messages
- Internal worker pool with actor-to-worker pinning

### Phase 2: Ergonomics

- Better diagnostics and tracing
- Optional naming and lookup if real usage needs it
- Mailbox policy options if real usage needs them

### Phase 3: Fault Tolerance

- `link`
- `monitor`
- `trap_exit`
- supervisor patterns

### Phase 4: Performance Work

- work stealing
- batching
- runtime metrics
- rebalancing if the pinned-worker model becomes too limiting

## Resolved Questions

1. **Mailbox size**: bounded FIFO with a default limit of 10,000 messages.
2. **Mailbox full behavior**: block the sender until capacity is available.
3. **Send to dead actor**: raises a runtime error.
4. **Unhandled exception in handler**: the actor continues processing the next message. The runtime logs the exception at error level. If the sender used `send_expect_reply`, the reply future fails with the same exception and `await` re-raises it on the sender side.
5. **`ctx/.stop` behavior**: the actor stops after the current message. Remaining mailbox messages are dropped. Pending reply futures transition to `failure`.
6. **Message schemas**: no runtime enforcement. Message structure is a user-level concern following normal Gene semantics.
7. **Actor system configuration**: global runtime activation only. The actor system is disabled by default and must be enabled programmatically with `(gene/actor/enable ...)`. Worker count is configurable. The mailbox limit stays fixed at `10,000` in the MVP.

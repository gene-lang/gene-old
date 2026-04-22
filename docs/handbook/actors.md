# Actors

Actors are the public concurrency API in Gene.

Actors build on the frozen-value substrate from Phases 1 and 1.5:

- mutable ordinary data is cloned on send
- frozen graphs and frozen closures can be shared by pointer
- replies use the existing `Future` surface

Phase 3 extends that actor-first boundary into stateful extensions:

- `genex/llm` uses a host-owned bridge and serialization actor
- `genex/http` uses actor-backed request ports for concurrent request work
- `genex/ai/bindings` uses actor-owned Socket Mode binding state

## Enabling the runtime

The actor runtime is disabled by default.

```gene
(gene/actor/enable)
(gene/actor/enable ^workers 4)
```

Rules:

- call `gene/actor/enable` before the first `gene/actor/spawn`
- call it once per process
- omit `^workers` to use the runtime default worker count

## Spawning

```gene
(gene/actor/spawn
  ^state initial_state
  handler)
```

The handler shape is always:

```gene
(fn [ctx msg state]
  state)
```

- `ctx` is the `ActorContext` for the current turn
- `msg` is the delivered message
- `state` is the actor's private state
- the return value becomes the next state

Example:

```gene
(var counter
  (gene/actor/spawn
    ^state 0
    (fn [ctx msg state]
      (case msg/kind
      when "increment"
        (+ state 1)
      when "get"
        (ctx .reply state)
        state
      else
        state))))
```

## Sending

```gene
(counter .send {^kind "increment"})
(await (counter .send_expect_reply {^kind "get"}))
```

- `.send` is fire-and-forget
- `.send_expect_reply` returns a `Future`
- `await` on that future reuses the normal Future success, failure, and timeout behavior

If the handler throws before replying, the reply future fails and `await` re-raises the failure on the sender side. The actor stays alive by default.

## ActorContext

`ActorContext` keeps reply and lifecycle operations explicit:

- `(ctx .actor)` returns the current actor handle
- `(ctx .reply value)` resolves the pending request from `send_expect_reply`
- `(ctx .stop)` marks the actor to stop after the current message finishes

Calling `(ctx .reply ...)` for a message that was not sent with `send_expect_reply` raises an error.

## Stop semantics

Actors stop after the current turn:

```gene
(worker .stop)
```

or from inside the handler:

```gene
(ctx .stop)
```

When stop wins:

- the current turn finishes
- queued mailbox work is dropped
- queued reply futures fail
- the current reply future fails if the handler did not already reply
- later sends raise an error

## Send tiers

Phase 2 send rules are:

- primitives move by value
- mutable arrays, maps, genes, strings, and bytes are cloned on send
- frozen graphs and frozen closures can be shared by pointer
- non-sendable capability values still fail

That means this pattern is safe:

```gene
(var payload {^count 1})
(worker .send {^kind "remember" ^payload payload})
(payload/count = 9)
```

The actor sees the cloned `payload` from the send, not the later local mutation.

## Public boundary

The public concurrency surface is actor-first:

- use `gene/actor/*` for new concurrency work
- prefer actor/port-backed extension ownership over extension-local worker or callback state
- do not use the retired thread-first surface in new code

## References

- [docs/handbook/freeze.md](/Users/gcao/gene-workspace/gene-old/docs/handbook/freeze.md)
- `testsuite/10-async/actors/`

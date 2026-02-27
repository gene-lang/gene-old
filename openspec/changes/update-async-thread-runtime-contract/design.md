# Design: Unified Async + Thread Runtime Contract

## Context

The runtime currently has multiple valid completion paths:
- Nim-backed futures (`pending_futures`) updated from `nim_future`,
- thread reply futures (`thread_futures`) completed from message channel,
- manual completion (`Future.complete`, `complete_future`),
- callback execution utilities present in more than one module.

The system needs one contract with deterministic behavior independent of source (I/O, thread, manual).

## Goals

- One lifecycle model for all futures.
- One scheduler authority for polling and callback dispatch.
- Deterministic timeout/cancel semantics.
- Deterministic callback semantics (ordering, once-only, failure propagation).
- Thread request/reply futures follow same contract as Nim-backed futures.

## Non-Goals

- CPS transformation or coroutine rewrite.
- New syntax forms.
- Multi-scheduler architecture.

## Decisions

### 1. Canonical Future Lifecycle

Future states:
- `pending`
- `success` (terminal)
- `failure` (terminal)
- `cancelled` (terminal)

Allowed transitions:
- `pending -> success | failure | cancelled`
- no transitions out of terminal states

Any attempt to re-complete terminal futures is ignored or raises deterministic runtime error (implementation choice documented in code comments/tests).

### 2. Single Scheduler Authority

`poll_event_loop` is the authoritative place to:
- advance Nim async futures,
- consume thread reply messages,
- enqueue/dispatch callbacks,
- finalize future lifecycle transitions.

No secondary code path is allowed to run callbacks with different semantics.

### 3. Await Contract

`await` behavior:
- if future is terminal, return/throw immediately according to state,
- if pending, continue polling scheduler until terminal,
- optional timeout returns deterministic timeout failure (`GENE.ASYNC.TIMEOUT`).

### 4. Callback Semantics

- callbacks run in registration order,
- each callback list runs at most once,
- adding callback after terminal state schedules immediate deterministic execution via scheduler rules,
- callback error handling:
  - success callback failure transitions future to `failure` if still in success-dispatch flow,
  - failure callback errors do not re-open lifecycle; last error is preserved for diagnostics.

### 5. Thread Future Integration

Thread futures (reply-based) use same lifecycle + callback + timeout/cancel rules.
- `send_expect_reply`/`run_expect_reply` create normal Future objects under unified contract.
- thread termination or decode failures complete affected futures as `failure` with typed error codes.

## Risks / Trade-offs

- Runtime behavior changes can break implicit assumptions in existing tests.
- Tightening semantics may surface latent bugs (good, but noisy).

Mitigation:
- add conformance tests before broad refactors,
- keep change atomic to avoid split semantics across commits.

## Migration Plan

1. Introduce lifecycle/state and transition guards.
2. Route all completion paths through one scheduler dispatch helper.
3. Add timeout/cancel support and wire await/thread paths.
4. Enable conformance tests as gating suite.

## Open Questions

- Should re-completing a terminal future throw (`GENE.ASYNC.ALREADY_TERMINAL`) or no-op?
A: throw
- Should late callback registration execute synchronously or next scheduler tick? (recommend next scheduler tick for uniformity)
A: next scheduler tick

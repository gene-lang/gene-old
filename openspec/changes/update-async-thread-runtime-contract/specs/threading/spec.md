# Threading Capability Specification

## ADDED Requirements

### Requirement: Unified Thread Future Lifecycle
Thread request/reply futures SHALL use the same lifecycle contract as async futures (`pending`, `success`, `failure`, `cancelled`).

#### Scenario: Reply future completes once
- **WHEN** a thread request/reply future is created by `send_expect_reply` or `run_expect_reply`
- **THEN** it SHALL start in `pending`
- **AND** it SHALL transition to exactly one terminal state (`success`, `failure`, or `cancelled`)
- **AND** terminal states SHALL be immutable

#### Scenario: Terminal thread future cannot be re-completed
- **WHEN** completion is attempted on a terminal thread reply future
- **THEN** runtime behavior SHALL follow the unified deterministic policy for terminal futures
- **AND** the current terminal payload SHALL remain unchanged

### Requirement: Thread Reply Dispatch Uses Scheduler Contract
Thread reply processing SHALL dispatch completion and callbacks through the same runtime scheduler contract used by async futures.

#### Scenario: Thread reply callback ordering matches async
- **WHEN** multiple callbacks are registered on a thread reply future
- **THEN** they SHALL execute in registration order
- **AND** each callback SHALL execute at most once
- **AND** ordering SHALL be consistent with non-thread async futures

#### Scenario: No duplicate callback paths for thread replies
- **WHEN** a thread reply is received
- **THEN** completion and callback dispatch SHALL use the unified scheduler path
- **AND** callback execution SHALL NOT occur via an alternate thread-only path

### Requirement: Thread Reply Timeout and Cancellation
Thread request/reply futures SHALL support deterministic timeout and cancellation behavior aligned with `await`.

#### Scenario: Await timeout on thread reply future
- **WHEN** awaiting a pending thread reply future with a timeout and the timeout elapses
- **THEN** await SHALL fail with typed timeout error code `GENE.ASYNC.TIMEOUT`
- **AND** pending reply tracking SHALL be cleaned up deterministically

#### Scenario: Await cancelled thread reply future
- **WHEN** awaiting a cancelled thread reply future
- **THEN** await SHALL fail with typed cancellation error code `GENE.ASYNC.CANCELLED`
- **AND** it SHALL not continue polling

### Requirement: Thread Failure Propagation
Thread-level execution failures SHALL complete affected reply futures as deterministic failures.

#### Scenario: Worker termination before reply
- **WHEN** a worker thread terminates before producing a reply
- **THEN** pending reply futures tied to that request SHALL transition to `failure`
- **AND** the failure SHALL carry a typed runtime error code

#### Scenario: Reply decode/validation failure
- **WHEN** a reply message cannot be decoded or validated
- **THEN** the associated reply future SHALL transition to `failure`
- **AND** callback and await behavior SHALL follow the unified failure contract

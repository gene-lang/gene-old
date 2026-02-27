# Async Capability Specification

## ADDED Requirements

### Requirement: Unified Future Lifecycle
The runtime SHALL use one canonical lifecycle for all Future values regardless of completion source (Nim async, thread reply, or manual completion).

#### Scenario: Pending future reaches terminal state once
- **WHEN** a Future is in `pending`
- **THEN** it MAY transition to exactly one of `success`, `failure`, or `cancelled`
- **AND** it SHALL NOT transition to another terminal state afterward

#### Scenario: Terminal future cannot be re-completed
- **WHEN** completion is attempted on a terminal Future
- **THEN** runtime behavior SHALL be deterministic (typed error or explicit no-op policy)
- **AND** the existing terminal state SHALL be preserved

### Requirement: Single Scheduler Authority
Future polling and callback dispatch SHALL be governed by one scheduler authority in the VM runtime.

#### Scenario: All future sources use same dispatch path
- **WHEN** a future completes from any source
- **THEN** callback dispatch SHALL go through the same scheduler contract
- **AND** callback ordering and error semantics SHALL be identical across sources

#### Scenario: No duplicate callback execution
- **WHEN** callbacks are registered for a future
- **THEN** each callback SHALL execute at most once
- **AND** duplicate execution from multiple runtime paths SHALL NOT occur

### Requirement: Deterministic Callback Semantics
Future callbacks SHALL execute deterministically and in registration order.

#### Scenario: Callback ordering is stable
- **WHEN** multiple callbacks are registered on the same future
- **THEN** they SHALL run in registration order
- **AND** each callback SHALL observe the same terminal future payload

#### Scenario: Late callback registration on terminal future
- **WHEN** a callback is registered after the future is terminal
- **THEN** it SHALL execute using the same scheduler contract
- **AND** behavior SHALL be deterministic and consistent with non-late registration

### Requirement: Await Timeout and Cancellation
`await` SHALL support deterministic timeout and cancellation behavior.

#### Scenario: Await timeout
- **WHEN** awaiting a pending future with timeout and timeout elapses
- **THEN** await SHALL terminate with typed timeout failure
- **AND** the pending future tracking SHALL be cleaned up deterministically

#### Scenario: Await cancelled future
- **WHEN** awaiting a cancelled future
- **THEN** await SHALL terminate with typed cancellation failure
- **AND** it SHALL NOT block or continue polling

### Requirement: Unified Async Error Model
Async lifecycle failures SHALL use typed runtime error codes.

#### Scenario: Timeout failure carries typed code
- **WHEN** a timeout occurs
- **THEN** the runtime error SHALL include code `AIR.ASYNC.TIMEOUT`

#### Scenario: Cancellation failure carries typed code
- **WHEN** cancellation is observed
- **THEN** the runtime error SHALL include code `AIR.ASYNC.CANCELLED`

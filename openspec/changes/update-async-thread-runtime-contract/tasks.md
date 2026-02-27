## 1. Future Lifecycle Model
- [ ] 1.1 Add cancellation as terminal future state in runtime type definitions.
- [ ] 1.2 Add guarded transition helper (pending -> terminal only).
- [ ] 1.3 Add typed runtime errors for timeout/cancel/invalid transition paths.

## 2. Scheduler Unification
- [ ] 2.1 Consolidate callback execution into one runtime dispatch path.
- [ ] 2.2 Ensure Nim-backed futures, thread reply futures, and manual completion all route through the same transition+dispatch helper.
- [ ] 2.3 Remove duplicate/legacy callback execution behavior that bypasses unified scheduler semantics.

## 3. Await + Timeout Contract
- [ ] 3.1 Implement deterministic await behavior for success/failure/cancelled.
- [ ] 3.2 Add timeout support to await path with deterministic failure semantics.
- [ ] 3.3 Ensure timeout/cancel remove/cleanup pending future tracking.

## 4. Thread Integration
- [ ] 4.1 Make `send_expect_reply` and `run_expect_reply` futures use unified lifecycle helpers.
- [ ] 4.2 Ensure thread termination/decode failures complete futures as terminal failures.
- [ ] 4.3 Add cancellation/timeout handling for thread reply futures.

## 5. Conformance Tests (Release Gate)
- [ ] 5.1 Add tests for exactly-once completion across all future sources.
- [ ] 5.2 Add callback ordering and late-registration tests.
- [ ] 5.3 Add await timeout/cancel tests.
- [ ] 5.4 Add thread reply timeout/failure/cancel tests.
- [ ] 5.5 Add regression tests for mixed async + thread workloads.

## 6. Validation
- [ ] 6.1 Run targeted suites: async, thread, callback, await.
- [ ] 6.2 Run full opcode/compiler guard tests to ensure no runtime dispatch regressions.
- [ ] 6.3 Update docs/comments for contract behavior and error model.

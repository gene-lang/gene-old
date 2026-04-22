---
phase: 04
slug: remove-legacy-thread-first-concurrency-surfaces
status: planned
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-22
---

# Phase 04 — Validation Strategy

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Nim `std/unittest` plus selected example/testsuite smokes |
| **Quick run command** | `nim c -r tests/integration/test_actor_runtime.nim && nim c -r tests/integration/test_actor_reply_futures.nim && nim c -r tests/integration/test_http_port_ownership.nim` |
| **Full suite command** | `nim c -r tests/integration/test_thread.nim && nim c -r tests/integration/test_ai_slack_socket_mode.nim && ./testsuite/run_tests.sh testsuite/10-async/actors/1_send_expect_reply.gene testsuite/10-async/actors/2_frozen_vs_mutable_send.gene testsuite/10-async/actors/3_stop_semantics.gene` |
| **Estimated runtime** | ~180 seconds |

## Sampling Rate

- after every task commit: run the narrowest affected compiler/runtime/doc regression
- after each plan wave: run actor replacement confidence tests plus any touched legacy-removal tests
- before phase verification: full suite command plus selected examples/docs greps

## Per-Task Verification Map

| Task ID | Plan | Requirement | Automated Command | Status |
|---------|------|-------------|-------------------|--------|
| 04-01-01 | 01 | ACT-04 | `nim c -r tests/integration/test_thread.nim` | ⬜ pending |
| 04-01-02 | 01 | ACT-04 | `rg -n "spawn_return|Thread\\.send|keep_alive|GENE_MAX_THREADS" docs examples testsuite` | ⬜ pending |
| 04-02-01 | 02 | ACT-04 | `nim c -r tests/integration/test_actor_runtime.nim && nim c -r tests/integration/test_actor_reply_futures.nim && nim c -r tests/integration/test_http_port_ownership.nim` | ⬜ pending |
| 04-02-02 | 02 | ACT-04 | `rg -n "GENE_WORKERS|GENE_MAX_THREADS" src docs examples tests` | ⬜ pending |
| 04-03-01 | 03 | ACT-04 | `./testsuite/run_tests.sh testsuite/10-async/actors/1_send_expect_reply.gene testsuite/10-async/actors/2_frozen_vs_mutable_send.gene testsuite/10-async/actors/3_stop_semantics.gene` | ⬜ pending |

## Wave 0 Requirements

- [ ] phase plan files exist
- [ ] legacy thread-first public surfaces explicitly enumerated
- [ ] actor replacement verification lane identified
- [ ] worker naming migration (`GENE_WORKERS`) included explicitly

**Approval:** ready for execution planning

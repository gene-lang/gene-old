---
phase: 02
slug: actor-runtime
status: ready
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-20
---

# Phase 02 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Nim `std/unittest` plus `testsuite/run_tests.sh` |
| **Config file** | none |
| **Quick run command** | `nim c -r --threads:on tests/test_phase2_actor_send_tiers.nim && nim c -r tests/integration/test_actor_runtime.nim && nim c -r tests/integration/test_actor_reply_futures.nim && nim c -r tests/integration/test_actor_stop_semantics.nim` |
| **Full suite command** | `nimble test && nimble testintegration && ./testsuite/run_tests.sh` |
| **Estimated runtime** | ~180 seconds |

---

## Sampling Rate

- **After every task commit:** run the Phase 2 actor-targeted quick suite for the task being changed, plus any directly affected legacy thread/future regression
- **After every plan wave:** run `nimble test && nim c -r tests/integration/test_thread.nim && nim c -r tests/integration/test_future_callbacks.nim && ./testsuite/run_tests.sh testsuite/10-async/threads/1_send_expect_reply.gene testsuite/10-async/threads/2_keep_alive_reply.gene`
- **Before `$gsd-verify-work`:** `nimble test && nimble testintegration && ./testsuite/run_tests.sh` must be green
- **Max feedback latency:** 180 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | ACT-02 | — | Actor types / API surfaces compile and are wired without regressing thread compatibility | unit + integration | `nim c -r tests/integration/test_actor_runtime.nim` | ❌ W0 | ⬜ pending |
| 02-01-02 | 01 | 1 | ACT-02 | — | Actor scheduler processes one message at a time and preserves lifecycle state transitions | integration | `nim c -r tests/integration/test_actor_runtime.nim` | ❌ W0 | ⬜ pending |
| 02-02-01 | 02 | 2 | ACT-02 | — | Send tiers distinguish primitive, frozen, frozen-closure, mutable, and capability-rejection paths | unit + stress | `nim c -r --threads:on tests/test_phase2_actor_send_tiers.nim` | ❌ W0 | ⬜ pending |
| 02-03-01 | 03 | 3 | ACT-02 | — | Reply futures succeed, fail, and time out correctly through actor messaging | integration | `nim c -r tests/integration/test_actor_reply_futures.nim` | ❌ W0 | ⬜ pending |
| 02-03-02 | 03 | 3 | ACT-02 | — | Stop semantics drop queued work, fail pending replies, and reject sends to stopped actors | integration | `nim c -r tests/integration/test_actor_stop_semantics.nim` | ❌ W0 | ⬜ pending |
| 02-04-01 | 04 | 4 | ACT-02 | — | Compatibility/docs wave preserves thread/future behavior while actor surfaces become primary | regression + docs | `nim c -r tests/integration/test_thread.nim && nim c -r tests/integration/test_future_callbacks.nim` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test_phase2_actor_send_tiers.nim` — unit/stress coverage for primitive / frozen / frozen-closure / mutable / capability send behavior
- [ ] `tests/integration/test_actor_runtime.nim` — actor spawn, scheduling, state threading, and pinning/lifecycle behavior
- [ ] `tests/integration/test_actor_reply_futures.nim` — reply success, failure, timeout, and callback behavior
- [ ] `tests/integration/test_actor_stop_semantics.nim` — stop behavior, queue drop semantics, pending future failure, and send-to-dead rejection
- [ ] `testsuite/10-async/actors/` — Gene-level actor semantics regression suite
- [ ] `tests/test_extended_types.nim` updates — actor/runtime kinds covered in ValueKind completeness checks if new kinds are added

---

## Manual-Only Verifications

All planned Phase 02 behaviors should have automated verification. No manual-only checks are expected.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all missing references
- [ ] No watch-mode flags
- [ ] Feedback latency < 180s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** ready for execution planning

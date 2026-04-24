---
phase: 05-feature-status-matrix-and-stable-core-boundary
verified: 2026-04-24T02:47:26Z
status: passed
score: 4/4 must-haves verified
overrides_applied: 0
human_verification: []
---

# Phase 5: Feature Status Matrix And Stable-Core Boundary Verification Report

**Phase Goal:** Make the public feature surface honest and navigable: users can
see what is stable, beta, experimental, future-only, or removed, and docs stop
presenting incomplete features as stable.

**Verified:** 2026-04-24T02:47:26Z
**Status:** passed

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A public feature-status matrix exists and covers the required feature surfaces. | PASS | `docs/feature-status.md` exists and contains rows for syntax, values, functions, macros, modules, packages, classes/adapters, selectors, async, actors, pattern matching, GIR, native extensions, WASM, LSP, tooling, and removed thread-first APIs. |
| 2 | Matrix rows record spec/doc status, implementation status, test status, known gaps, and user posture. | PASS | The matrix columns are `Feature surface`, `Status`, `Spec or docs`, `Implementation status`, `Test status`, `Known gaps`, and `User posture`. |
| 3 | Public README/docs entry points route users to the matrix and no longer use stale implementation-status or thread-first wording. | PASS | `README.md` and `docs/README.md` link `docs/feature-status.md`; negative grep for `docs/IMPLEMENTATION_STATUS.md`, `Futures, async/await, threads`, `thread APIs`, and `Thread spawn/messaging APIs` passed for the targeted public docs. |
| 4 | Stable-core membership is explicitly listed and tied to current implementation/docs/test support. | PASS | `docs/feature-status.md` includes `## Stable Core Boundary`, lists stable core inclusions, and excludes beta/experimental/future surfaces. |

**Score:** 4/4 truths verified

## Automated Checks

| Check | Command | Result |
|-------|---------|--------|
| Status document exists | `test -f docs/feature-status.md` | PASS |
| Matrix/status labels present | `rg -n "## Feature Status Matrix|## Stable Core Boundary|Stable|Beta|Experimental|Future|Removed" docs/feature-status.md` | PASS |
| Required surfaces covered | `rg -n "syntax|values|functions|macros|modules|packages|classes|adapters|selectors|async|actors|pattern|GIR|native extensions|WASM|LSP|tooling" docs/feature-status.md` | PASS |
| Matrix linked from public docs | `rg -n "feature-status.md" README.md docs/README.md` | PASS |
| Actor-first public concurrency wording present | `rg -n "actor-first|gene/actor|public concurrency surface" README.md docs/feature-status.md spec/README.md docs/wasm.md` | PASS |
| Stale wording removed | `! rg -n "docs/IMPLEMENTATION_STATUS.md|Futures, async/await, threads|thread APIs|Thread spawn/messaging APIs" README.md spec/README.md docs/wasm.md` | PASS |
| Whitespace sanity | `git diff --check` | PASS |

## Gate Notes

- Code review gate: skipped because this phase changed documentation and
  planning files only; no source files changed under `src/`, `tests/`,
  `testsuite/`, `examples/`, `tools/`, `web/`, or Nim/Gene source paths.
- Regression gate: skipped for the same reason; no runtime code or tests were
  changed.
- Security gate: Phase 05 threat was documentation overclaiming. The plan
  included a threat model and the verification checks prove public claims now
  point to the status matrix and actor-first boundary.

## Requirements Coverage

| Requirement | Status | Evidence |
|-------------|--------|----------|
| STAT-01 | SATISFIED | `docs/feature-status.md` marks major surfaces as stable, beta, experimental, future, or removed. |
| STAT-02 | SATISFIED | Each matrix row includes implementation status, test status, and known gaps. |
| STAT-03 | SATISFIED | README/docs entry points link the matrix and stale public thread/implementation-status wording is removed. |
| CORE-01 | SATISFIED | `## Stable Core Boundary` lists syntax, values, variables, functions, lexical scope, macros, modules/imports, errors, collections, async futures, and actor-first concurrency. |

## Verdict

Phase 05 achieved its goal. Phase 06 can now tighten core semantic behavior
against a published stable-core boundary.

---
_Verified: 2026-04-24T02:47:26Z_
_Verifier: Codex_

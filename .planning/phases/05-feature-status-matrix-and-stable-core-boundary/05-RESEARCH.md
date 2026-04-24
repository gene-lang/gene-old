# Phase 05: Feature Status Matrix And Stable-Core Boundary - Research

**Researched:** 2026-04-24
**Domain:** public feature status, stable-core boundary, documentation truthfulness
**Confidence:** HIGH

## User Constraints

- Phase 05 is the first phase of milestone v1.1 and follows the completed actor
  migration track through Phase 04. [VERIFIED: `.planning/ROADMAP.md`]
- Phase 05 covers `STAT-01`, `STAT-02`, `STAT-03`, and `CORE-01`.
  [VERIFIED: `.planning/REQUIREMENTS.md`]
- The review in `tmp/gpt-pro-comments.md` recommends a smaller stable core and
  a public status matrix before package or VM correctness work expands the
  surface area. [VERIFIED: `tmp/gpt-pro-comments.md`]
- Per current user direction, planning was completed locally without Codex MCP
  or subagent dependency.

## Requirement Mapping

| ID | Requirement | Research Support |
|----|-------------|------------------|
| STAT-01 | One public matrix marks major Gene surfaces stable, beta, experimental, future, or removed. | Public docs currently spread status across README, docs, specs, and planning notes. |
| STAT-02 | Matrix shows implementation status, tests, and known gaps. | Existing focused docs already contain many current-status fragments that can be consolidated. |
| STAT-03 | README/docs do not promote experimental or removed surfaces as stable. | README and spec index contain stale or over-broad wording that Phase 05 should correct. |
| CORE-01 | Stable core definition covers syntax, values, variables, functions, scope, macros, modules/imports, errors, collections, futures, and actors. | These surfaces have specs/tests or recent actor hardening work, but docs need an explicit boundary. |

## Current Public-Doc Findings

The highest-value Phase 05 work is documentation correction, not runtime
implementation:

- `README.md` points to `docs/IMPLEMENTATION_STATUS.md`, but that file does
  not exist. [VERIFIED: `README.md`, `ls docs`]
- `README.md` describes WASM limitations as "thread APIs" even though Phase 04
  retired the public thread-first API. [VERIFIED: `README.md`]
- `spec/README.md` still describes section 10 as "Futures, async/await,
  threads", while `spec/10-async.md` now states actors are the public
  message-passing API and native worker threads are internal. [VERIFIED:
  `spec/README.md`, `spec/10-async.md`]
- `docs/package_support.md` already states package manifests are marker plus
  metadata today and that `$dep`, `$pkg`, version selection, lockfiles, and
  install are not implemented. Phase 05 should link this truth from the matrix,
  not restate packages as stable.
- `docs/type-system-mvp.md` already marks the type system as active and
  partially delivered. The matrix should classify it as beta, not stable core.
- `docs/lsp.md` already marks LSP as lightweight and parser-backed, with no
  formatter, rename, signature help, code actions, or type-checker-backed
  semantic analysis. The matrix should classify LSP as beta/tooling, not core.
- `docs/handbook/actors.md` and `spec/10-async.md` agree that concurrency is
  actor-first publicly and worker-thread-backed internally.

## Feature Status Starting Point

This is the planning-time classification recommendation. Execution may refine
individual rows after reading additional focused docs/tests.

| Surface | Recommended status | Evidence to cite in matrix | Notes |
|---------|--------------------|----------------------------|-------|
| Syntax and literals | Stable | `spec/01-syntax.md`, parser tests | Core language entry point. |
| Values, primitives, collections | Stable | `spec/02-types.md`, `spec/06-collections.md`, stdlib tests | Include nil/void caveat for Phase 06 semantics. |
| Variables, functions, lexical scope | Stable | `spec/03-expressions.md`, `spec/05-functions.md`, testsuite functions/scopes | Function/type metadata can be beta where tied to gradual typing. |
| Macros | Stable core subset | `spec/05-functions.md`, `tests/integration/test_macro.nim` | Keep AOP and advanced macro-adjacent behavior outside stable core if not covered. |
| Basic modules/imports | Stable core subset | `spec/08-modules.md`, `docs/package_support.md`, module tests | Separate from package manifest/dependency behavior. |
| Errors/contracts | Stable core subset | `spec/09-errors.md` | Contracts may need caveat if coverage is incomplete. |
| Async futures | Stable | `spec/10-async.md`, async tests | Clarify `async` wraps synchronously; it is not a spawn primitive. |
| Actors | Stable public concurrency surface | `docs/handbook/actors.md`, actor integration tests | Single-process actor API is public; supervision/distributed actors are out of scope. |
| Selectors | Beta | `spec/17-selectors.md`, selector tests | Powerful but nil/void/failure semantics are Phase 06 risk. |
| Classes/OOP | Beta | `spec/07-oop.md`, OOP tests, README limitation | README already says class features need more coverage. |
| Interfaces/adapters | Beta | `docs/adapter-design.md`, testsuite interfaces/adapters | Useful, not part of Phase 05 stable core. |
| Gradual type system | Beta | `docs/type-system-mvp.md`, type checker tests | Active and partially delivered. |
| Packages | Experimental/future split | `docs/package_support.md`, package tests | Root detection/imports exist; manifests/deps/lockfile are Phase 07. |
| Pattern matching | Experimental | `spec/12-patterns.md`, pattern tests | Review and README already flag incomplete behavior. |
| GIR | Beta | `docs/gir.md`, GIR tests | Strong implementation, but correctness harness is Phase 08. |
| Native extensions | Beta/trusted host surface | `docs/c_extensions.md` | Security/trust model is future work. |
| WASM | Beta/limited target | `docs/wasm.md`, WASM tests | Host-embedded eval with deterministic unsupported features. |
| LSP/tooling | Beta | `docs/lsp.md` | Lightweight parser-backed tooling. |
| Thread-first APIs | Removed | Phase 04 docs/tests | Worker threads remain internal substrate only. |

## Stable-Core Boundary Recommendation

Phase 05 should publish the stable core as a user-facing boundary, not as an
implementation guarantee for every advanced feature. The stable core should
include:

- syntax and literals
- primitive values and collection values
- variables, assignment, functions, returns, closures, and lexical scope
- core macro behavior with unevaluated input
- basic module/import behavior
- error handling surface
- async futures and `await`
- actor-first single-process message passing

Phase 05 should explicitly exclude or caveat:

- selector edge semantics that depend on Phase 06 nil/void work
- advanced classes/adapters and AOP behavior
- gradual type-system advanced behavior
- package manifests, dependencies, lockfiles, registry/install flows
- pattern matching beyond the tested subset
- native extension trust/security policy
- distributed actors, supervision trees, and hot code loading
- public thread-first concurrency APIs

## Planning Recommendation

Use one execution plan:

1. Create `docs/feature-status.md` with definitions, matrix rows, known gaps,
   and stable-core membership tied to existing tests/specs.
2. Update `README.md`, `docs/README.md`, `spec/README.md`, and `docs/wasm.md`
   so public entry points route users to the matrix and stop using stale
   thread-first or non-existent implementation-status wording.
3. Verify with targeted grep checks. Runtime tests are not required for a
   docs-only phase, but `git diff --check` should pass.

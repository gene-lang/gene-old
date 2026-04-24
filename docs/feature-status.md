# Gene Feature Status

This page is the public status map for the Nim VM implementation. It separates
the stable core from beta, experimental, future, and removed surfaces so users
can choose the right level of trust for each feature.

## Status Labels

| Status | Meaning | User posture |
|--------|---------|--------------|
| Stable | Implemented, documented or specified, and backed by focused tests for normal use. | Safe to build on within the documented boundary. |
| Beta | Implemented and useful, but still has known gaps, incomplete coverage, or unsettled edge semantics. | Use deliberately and expect some churn. |
| Experimental | Available only for exploration or a narrow subset; design may change substantially. | Avoid depending on it for durable code. |
| Future | Documented as a goal or proposal, but not implemented as a dependable current surface. | Treat as roadmap context only. |
| Removed | No longer part of the public API. | Do not use in new code. |

## Feature Status Matrix

| Feature surface | Status | Spec or docs | Implementation status | Test status | Known gaps | User posture |
|-----------------|--------|--------------|-----------------------|-------------|------------|--------------|
| Core syntax and literals | Stable | `spec/01-syntax.md` | Parser and VM support current Gene expression syntax, primitive literals, comments, quoting, interpolation, reserved words, slash paths, and ranges. | Parser coverage exists in `tests/test_parser.nim`, `tests/test_parser_interpolation.nim`, and syntax testsuite files. | Formal grammar is still implicit in the parser/spec/tests rather than a standalone EBNF. | Build on the documented syntax; use tests as the arbiter for edge cases. |
| Values and primitive types | Stable | `spec/02-types.md`, `spec/01-syntax.md` | NaN-boxed values cover nil, void, booleans, numbers, symbols, strings, and managed runtime values. | Value/type coverage exists in `tests/test_types.nim`, `tests/test_extended_types.nim`, `testsuite/02-types/`, and `tests/integration/test_core_semantics.nim`. | nil versus void semantics are specified; optional-flow helpers and broader type narrowing remain future work. | Stable for ordinary values and documented missing-value semantics. |
| Collections and Gene values | Stable | `spec/06-collections.md`, `spec/01-syntax.md` | Arrays, maps, and Gene values are core runtime data structures. | Collection and stdlib coverage exists in `tests/integration/test_stdlib_array.nim`, `test_stdlib_map.nim`, `test_stdlib_gene.nim`, and testsuite collection examples. | Advanced mutation/freeze interactions are documented elsewhere and should stay within tested patterns. | Use as core data structures. |
| Variables, assignment, functions, and lexical scope | Stable | `spec/03-expressions.md`, `spec/05-functions.md` | Functions are first-class, support arguments, returns, closures, lexical scope, and `.call`. | Function and scope coverage exists in `tests/integration/test_function_optimization.nim` and `testsuite/05-functions/`. | Advanced typed function behavior belongs to the gradual type-system beta surface. | Build on normal function and closure behavior. |
| Core macros | Stable | `spec/05-functions.md`, `docs/implementation/caller_eval.md` | Functions ending in `!` receive unevaluated argument structure, including Gene type, properties, and children, and can use `$caller_eval` and `$render`. | Macro coverage exists in `tests/integration/test_macro.nim` and macro testsuite entries. | AOP and broader macro-adjacent features are not part of this stable-core claim. | Use the documented macro function model for DSL work. |
| Basic modules and imports | Stable | `spec/08-modules.md`, `docs/package_support.md` | Filesystem and namespace imports work, including basic named, wildcard, and package-qualified lookup forms. | Module coverage exists in `tests/integration/test_module*.nim` and `testsuite/08-modules/`. | Registry/version workflows remain outside the stable module surface. | Use basic imports; use package manager behavior through the documented local MVP boundary. |
| Error handling | Stable | `spec/09-errors.md` | Exceptions, throw, try/catch, and async failure propagation are part of the runtime surface. | Error paths are covered through focused runtime and async tests. | Contract/precondition coverage may need separate tightening if promoted beyond the basic error surface. | Use ordinary exception handling. |
| Async futures and await | Stable | `spec/10-async.md` | `async` wraps a value or failure in a Future, `await` waits/polls, and Future completion/failure/cancel behavior is implemented. | Async and future coverage exists in `tests/integration/test_async.nim` and `testsuite/10-async/`. | `async` is not a background scheduling primitive; structured concurrency is future work. | Use futures for async I/O and unified sync/async result paths. |
| Actors | Stable | `spec/10-async.md`, `docs/handbook/actors.md` | `gene/actor/*` is the public message-passing concurrency API, backed internally by native workers and per-worker VMs. | Actor coverage exists in `tests/integration/test_actor_runtime.nim`, `test_actor_reply_futures.nim`, `test_actor_stop_semantics.nim`, `tests/test_phase2_actor_send_tiers.nim`, and `testsuite/10-async/actors/`. | No supervision tree, monitor API, distributed actors, or hot code loading. | Use actors as the public concurrency surface. |
| Selectors | Beta | `spec/17-selectors.md` | Selectors unify access across paths, maps, arrays, namespaces, objects, and related runtime surfaces; documented missing/default/strict behavior is specified. | Selector coverage exists in `tests/integration/test_selector.nim` and `tests/test_selector`. | Ranges/slices, predicate operators, rich Gene-specific views, generator integration, and deep update/delete remain outside the stable subset. | Use the documented lookup/default/strict/stream/simple `$set` subset; treat advanced selector forms as beta. |
| Classes and OOP | Beta | `spec/07-oop.md` | Classes, constructors, methods, inheritance, namespaces, and related object behavior exist. | OOP coverage exists in `tests/integration/test_oop.nim`, `test_stdlib_class.nim`, and `testsuite/07-oop/`. | README still calls out class feature coverage gaps; advanced OOP/AOP behavior is not stable core. | Use for experiments and covered patterns; avoid claiming it as the core portability layer. |
| Interfaces and adapters | Beta | `docs/adapter-design.md`, `spec/07-oop.md` | Adapter/interface behavior exists in the VM and examples. | Interface and adapter tests exist under `testsuite/07-oop/interfaces/`. | Conformance, diagnostics, and type-system integration are still maturing. | Use where tested; expect refinement. |
| Gradual type system | Beta | `docs/type-system-mvp.md`, `docs/how-types-work.md` | Compile-time checking, runtime descriptor validation, typed arguments, locals, returns, and typed properties are partially delivered. | Type checker and typed tests exist in `tests/test_type_checker.nim`, `testsuite/02-types/`, and typed function tests. | Canonical descriptor pipeline, negative-path coverage, flow typing breadth, generic classes, and diagnostics remain incomplete. | Use explicit annotations at boundaries; expect beta-level churn. |
| Packages and dependency metadata | Beta | `docs/package_support.md`, `spec/08-modules.md` | Local package MVP supports shared `package.gene` parsing, `$pkg` and `$app/.pkg` metadata, local/path `$dep` declarations, `gene deps` lockfile generation/verification, and package-aware imports through manifest and lockfile data. | Package coverage exists in `tests/integration/test_package_manifest.nim`, `test_package.nim`, `test_cli_package_context.nim`, `test_deps_command.nim`, and `test_cli_run.nim`. | Registry or hosted installation, remote indexes, complete version solving, native trust/signing policy, and package publishing are future work. | Use the documented local package MVP for local projects and local/path dependencies; avoid assuming registry-grade ecosystem behavior. |
| Pattern matching | Experimental | `spec/12-patterns.md` | Array and Gene destructuring plus simple `case/when` exist; ADT/Option matching and `?` are explicitly experimental. | Pattern coverage exists in `tests/integration/test_pattern_matching.nim`, `tests/integration/test_case.nim`, and `testsuite/12-patterns/`. | tested subset is documented; nested patterns, guards, exhaustiveness, map destructuring, broad function-parameter patterns, match/or/as patterns, and arity diagnostics remain open. | Use only the documented tested subset for durable code. |
| GIR bytecode/cache format | Beta | `docs/gir.md`, `docs/gir-benchmarks.md` | GIR serialization and caching exist with version/fingerprint/hash checks and CLI support. | GIR coverage exists in `tests/integration/test_cli_gir.nim` and related CLI tests. | Phase 8 will add broader compatibility checks and VM correctness instrumentation. | Useful for cold-start and cache workflows; validate with source when debugging. |
| Native extensions | Beta | `docs/c_extensions.md`, `docs/http_server_and_client.md` | Dynamic extension loading and C extension APIs exist for trusted host environments. | Extension and integration coverage exists in focused native/HTTP tests where enabled. | Trust model, search path policy, signing/checksum policy, ABI lifecycle, and unload behavior are future work. | Use only for trusted local/native deployments. |
| WASM target | Beta | `docs/wasm.md`, README | Emscripten build exposes `gene_eval` and deterministic unsupported-feature errors. | WASM coverage exists in `tests/test_wasm.nim`. | Native workers, dynamic extension loading, process execution, and file-backed module loading are unavailable in WASM. | Use for embedded evaluation with the documented limited runtime profile. |
| LSP and editor tooling | Beta | `docs/lsp.md` | `gene lsp` supports sync, parser-backed diagnostics, completion, definition, hover, references, and workspace symbols. | LSP has implementation-level coverage through command and parser behavior. | No formatter, rename, signature help, code actions, or type-checker-backed semantic analysis. | Useful as lightweight tooling; not a complete IDE contract. |
| Formatting, CLI, and operational tooling | Beta | README, command docs, `docs/README.md` | CLI commands for run, eval, repl, parse, compile, GIR, LSP, and related operations exist. | Command coverage is split across Nim integration tests and shell tests. | Tooling coverage is uneven and should not be confused with language-core stability. | Use documented commands; verify less common tooling paths locally. |
| Public thread-first APIs | Removed | `spec/10-async.md`, Phase 04 planning artifacts | Public thread-first entry points were retired; native workers remain as internal actor/runtime substrate. | Actor and retired-thread tests cover the migration boundary. | None for new user code; retained internals are not public API. | Use `gene/actor/*`; do not use retired thread-first APIs. |

## Stable Core Boundary

The stable core is the part of Gene users can build on while the broader
runtime continues to mature. A feature is in the stable core only when the
current implementation, public docs/specs, and focused tests all support the
claim.

Stable core includes:

- syntax and literals from `spec/01-syntax.md`
- primitive values including specified `nil` versus `void` semantics, Gene
  values, arrays, maps, and other core collections
- variables, assignment, functions, returns, closures, and lexical scope
- core macros through unevaluated macro-function arguments, `$caller_eval`, and
  `$render`
- documented selector lookup/default/strict semantics for maps, arrays, Gene
  values, instances, and `nil` receivers
- basic module and import behavior for files and namespaces
- error handling through `throw`, `try`, `catch`, and normal exception
  propagation
- async futures and `await`, with `async` defined as a future-producing wrapper
  rather than a background scheduler
- actor-first single-process concurrency through `gene/actor/*`

Stable core does not include:

- package registries, hosted installers, native trust/signing policy, or full
  version solving beyond the documented local package MVP
- selector ranges/slices, dedicated predicates, rich Gene-specific selector
  views, generator integration, or generalized deep update/delete semantics
- advanced classes, adapters, AOP, or broad object-model guarantees beyond the
  tested beta surface
- the gradual type system beyond documented beta usage
- pattern matching beyond the documented tested subset
- GIR compatibility guarantees that Phase 8 will formalize
- native-extension trust, signing, ABI lifecycle, or unload policy
- WASM parity with the native runtime
- distributed actors, supervision trees, monitor APIs, hot code loading, or
  public thread-first concurrency APIs

The practical rule is conservative: if a surface is useful but not stable-core,
its docs should say so directly and link to the relevant subsystem page for the
current implementation boundary.

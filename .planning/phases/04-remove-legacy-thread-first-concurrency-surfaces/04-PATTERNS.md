# Phase 04: Remove Legacy Thread-First Concurrency Surfaces - Pattern Map

**Mapped:** 2026-04-22  
**Files analyzed:** 14  
**Analogs found:** 14 / 14

## File Classification

| New/Modified File | Role | Closest Analog | Match Quality |
|---|---|---|---|
| `src/gene/compiler/async.nim` | public language entrypoint | itself | exact |
| `src/gene/compiler/operators.nim` | user-facing sugar/router | itself | exact |
| `src/gene/vm/thread.nim` | public class bootstrap shim | itself | exact |
| `src/gene/vm/thread_native.nim` | thread-first runtime surface | itself | exact |
| `src/gene/stdlib/core.nim` | public global helper registration | itself | exact |
| `src/gene/types/core.nim` | env-var/public naming source | itself | exact |
| `src/gene/vm/runtime_helpers.nim` | thread-local public handles | itself | exact |
| `src/gene/types/helpers.nim` | main-thread namespace bootstrap | itself | exact |
| `docs/thread_support.md` | legacy surface reference | itself | exact |
| `docs/handbook/actors.md` | preferred public replacement | itself | exact |
| `examples/thread.gene`, `examples/full.gene` | user-facing examples | themselves | exact |
| `tests/integration/test_thread.nim` | legacy behavior regression | itself | exact |
| `testsuite/10-async/threads/*` | public thread examples | themselves | exact |
| `tests/integration/test_actor_runtime.nim` / `test_actor_reply_futures.nim` | actor replacement confidence lane | themselves | exact |

## Pattern Assignments

### Public-surface removal pattern

Use the Phase 2 boundary pattern from `docs/handbook/actors.md` and
`docs/thread_support.md`: actors stay primary, thread-first surfaces become
explicit migration errors or disappear from the public namespace.

### Preserve-internal-substrate pattern

Use `src/gene/vm/actor.nim` as the constraint boundary. Anything still required
for actor worker scheduling stays internal even if the thread-first public API
goes away.

### Naming migration pattern

Use the existing env-var resolution site in `src/gene/types/core.nim` as the
single place to flip `GENE_MAX_THREADS` to `GENE_WORKERS`. Avoid renaming by
grep-only edits in scattered docs first.

### Verification pattern

Use dual-lane verification:

- legacy surface tests updated to assert deprecation/removal behavior
- actor tests proving replacement behavior still works

## Testing Patterns

- add/update one focused legacy-removal suite for old surfaces
- keep `tests/integration/test_thread.nim` only if it is repurposed to assert explicit migration behavior
- keep actor runtime/reply-future tests as the replacement confidence lane
- update examples/tests so the docs no longer teach thread-first usage

## Anti-Patterns

- silently leaving old names as undocumented-but-working paths
- breaking actor worker internals while removing public thread APIs
- removing tests without replacing them with actor migration assertions

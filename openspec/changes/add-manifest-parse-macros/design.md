## Context
We need metadata files (especially `package.gene`) to vary output based on environment, while remaining deterministic and safe. Full runtime evaluation is too broad for manifest parsing and introduces unnecessary side effects.

The design introduces a constrained parse-macro evaluator for manifest contexts.

## Goals / Non-Goals
- Goals:
  - Support declarative, environment-aware manifest values using `#`-prefixed parse macros.
  - Keep normal Gene module parsing/execution unchanged.
  - Provide clear diagnostics for malformed parse macros.
- Non-Goals:
  - General compile-time metaprogramming for all source files.
  - Arbitrary runtime execution (imports, I/O, user function calls) during manifest parse.

## Decisions
- Decision: Parse-macro evaluation is enabled only in manifest parsing mode (starting with `package.gene`).
  - Rationale: Limits blast radius and keeps runtime semantics stable.

- Decision: `#`-prefixed forms are parse-macro calls in manifest mode.
  - Example: `(#If (#Eq (#Env HOME) "/Users/alice") A B)`.

- Decision: Initial macro set is fixed and built-in:
  - `#Var`, `#If`, `#Eq`, `#Env`, `#Inc`.
  - Rationale: Covers requested use cases with minimal surface area.

- Decision: Macro variables use `#`-prefixed symbols (for example `#name`, `#i`).
  - Rationale: Avoids collisions with manifest keys and plain symbols.

- Decision: Manifest mode evaluates only parse-macro forms and data expressions needed by those macros.
  - Rationale: Prevents arbitrary runtime execution and keeps parsing safe.

## Evaluation Model
- Parse source into normal Gene values with existing reader behavior.
- Evaluate expressions sequentially with a dedicated parse-macro environment.
- Macro variables persist across expressions in the same manifest parse session.
- `#Env` accepts either:
  - plain symbol or string environment key (`HOME`, `"HOME"`), or
  - macro-variable reference resolving to symbol/string (`#name`).

## Risks / Trade-offs
- Added complexity in manifest loading path.
  - Mitigation: Isolate evaluator in a dedicated module with focused tests.
- Potential confusion between parse macros and runtime macros.
  - Mitigation: Restrict parse-macro mode to manifest reader entrypoints and document boundaries clearly.

## Migration Plan
1. Add evaluator behind manifest parse entrypoint without changing default module parsing.
2. Update package manifest loader to use parse-macro mode.
3. Add compatibility tests for existing static `package.gene` files.

## Open Questions
- Should parse-macro mode later be exposed for other config files beyond `package.gene`?
- Should `#Var` return assigned value or `NIL` in manifest mode (current proposal allows assignment + retrieval patterns regardless)?

## Context

Contracts must run correctly for all function entry/exit paths, including explicit `return`. Pure AST wrapping is insufficient because early returns can bypass postconditions.

## Goals

- Support `^pre` and `^post` on functions and methods.
- Ensure postconditions run on explicit `return` and implicit function-end return.
- Allow runtime disablement via CLI/VM flag.
- Keep diagnostics structured and readable.

## Non-Goals

- Static contract verification.
- New contract DSL beyond expression arrays.
- Contract optimization/JIT specialization.

## Decisions

- Store contract expressions on `Function` objects (`pre_conditions`, `post_conditions`).
- Inject checks during function compilation:
  - preconditions emitted before body execution
  - postconditions emitted in `compile_return` and at implicit function end
- Gate checks through runtime function `__contracts_enabled__` so `--contracts=off` skips condition evaluation entirely.
- Raise `ContractViolation` via runtime helper `__contract_violation__` with contextual metadata.

## Risks / Trade-offs

- Injected contract instructions increase bytecode size for contracted functions.
- Condition text uses canonical Value stringification, which may differ from source formatting.
- Reserving a synthetic postcondition `result` slot introduces additional local index pressure.

## Migration Plan

- Add new behavior as opt-in syntax (`^pre`/`^post`) with runtime checks on by default.
- Existing functions without contracts are unaffected.
- Production workloads can disable checks using `--contracts=off`.

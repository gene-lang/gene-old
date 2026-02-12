## Context

The current native path is on/off (`VM.native_code`). It supports guarded argument checks but does not expose policy-level intent to users. We need explicit tiers to control eligibility strictness and deopt behavior.

## Goals

- Expose native policy as a first-class runtime setting.
- Preserve existing behavior as default compatibility mode.
- Keep fallback behavior predictable and testable.

## Non-Goals

- New machine-code backends.
- Cross-module AOT packaging changes.
- Global static-typing enforcement changes.

## Tier Semantics

- `never`
  - Native compilation is disabled.
  - VM always executes bytecode.
- `guarded`
  - Native compilation is attempted for eligible functions.
  - Runtime argument guard failures deopt to bytecode execution.
- `fully-typed`
  - Native compilation requires fully typed signatures at boundary (typed params + typed return supported by native path).
  - If runtime guards fail, execution deopts to bytecode path.

## Backward Compatibility

- Existing `--native-code` remains valid and maps to `guarded`.
- Existing VM callers that set `native_code = true` continue to work as guarded mode.

## Deopt Model

- Deopt means: skip native dispatch for a call and execute through existing VM path.
- Deopt is per-call and preserves language semantics.

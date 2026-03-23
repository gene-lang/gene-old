## Why
Symbol resolution rules are currently documented but not formalized as OpenSpec requirements. Converting them into a spec ensures consistent compiler/VM behavior and provides a foundation for future changes, including namespace import aliasing.

## What Changes
- Define a new `symbol-resolution` capability covering keywords, scopes, namespaces, globals, and special variables.
- Specify namespace import aliasing for `(import genex/llm)` and `(import genex/llm:llm2)`.
- Clarify that `global/` is NOT a global-variable namespace (documenting existing behavior); globals use `$name` only.
- Clarify that `nil` is the only nil literal and `NIL` is treated as a normal symbol.
- Add global assignment validation via a built-in `global_set` function, including read-only global protection for `$ex` and `$env`.
- Define `$ex` as thread-local, even though it uses the `$` prefix.
- Specify `synchronized` for global access with root or direct-child lock semantics, plus a discouraged global-lock fallback when `^on` is omitted.

## Impact
- Affected specs: new `symbol-resolution` capability.
- Affected docs: `docs/proposals/archive/symbol_resolution.md` should be aligned after approval.
- Affected code: parser keyword handling, compiler symbol resolution order, namespace/import handling, and VM symbol lookup.
- Related changes: overlaps with `openspec/changes/add-module-system`, `openspec/changes/implement-complex-symbol-access`, and `openspec/changes/add-thread-support`.

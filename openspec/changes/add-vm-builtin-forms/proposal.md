## Why
Introduce dedicated $vm and $vmstmt forms so core VM operations can be compiled to single instructions with explicit stack effects, avoiding overhead and confusing value reuse for statement-only operations.

## What Changes
- Add special forms `($vm ...)` (value) and `($vmstmt ...)` (statement-only) for VM builtins.
- Whitelist VM builtin names: `duration_start` for `$vmstmt`, `duration` for `$vm`.
- Compile `($vmstmt duration_start)` to a dedicated instruction with no stack value.
- Compile `($vm duration)` to a dedicated instruction that returns a duration value.
- **BREAKING**: Using `$vmstmt` builtins in expression position becomes a compile-time error.

## Impact
- Affected code: `src/gene/compiler.nim`, `src/gene/types/type_defs.nim`, `src/gene/vm.nim`, testsuite.
- Affected specs: new `vm-builtins` capability.

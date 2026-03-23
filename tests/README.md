# Gene Unit Tests

This directory is reserved for **unit-level Nim tests**:

- parser and reader behavior
- compiler / bytecode / VM core logic
- low-level runtime internals that `testsuite/` cannot cover directly
- small ABI/internal tests such as native codegen, extension hooks, custom values, and wasm ABI coverage
- not end-to-end language semantics that can be expressed as runnable Gene programs

## Running Tests

```bash
# Run the unit suite
nimble test

# Run a specific unit test file
nim c -r tests/test_parser.nim
```

## Test Organization

### Parser / Compiler / VM Core
- `test_parser.nim` - Parser tests
- `test_parser_interpolation.nim` - Interpolation parsing
- `test_stream_parser.nim` - stream/hash-array parsing behavior
- `test_types.nim` - Type system tests
- `test_type_checker.nim` - static type checker behavior
- `test_opcode_dispatch.nim` - compiler/VM opcode alignment
- `test_compile_eager.nim` - eager compilation internals
- `test_source_trace.nim` - diagnostic/source trace internals

### VM / Compiler Internals
- `test_vm_builtins.nim` - VM internal helper surfaces such as `$vm` / `$vmstmt`
- `test_vm_neg.nim` - direct opcode execution for unary negation
- `test_extended_types.nim` - internal `ValueKind` / runtime type completeness
- `test_logging.nim` - logging config and logger runtime internals

### Internal / Not Well Covered By `testsuite/`
- `test_native_trampoline.nim`
- `test_bytecode_to_hir.nim`
- `test_ext.nim`
- `test_c_extension.nim`
- `test_custom_value.nim`
- `test_thread_msg.nim`
- `test_wasm.nim`

## Test Conventions

1. Each test file focuses on a specific component or feature
2. Tests use Nim's unittest framework
3. Test names should be descriptive: `test "parse simple addition"`
4. Group related tests in suites

## Integration Tests

Broader Nim integration tests have been moved to `/tests/integration/`.
For end-to-end Gene program coverage, see `/testsuite/`.

## Adding New Tests

When adding new tests:
1. Put **unit-level** tests here only.
2. If the behavior can be expressed as a runnable Gene program, prefer `testsuite/`.
3. If the test is language semantics, CLI flow, stdlib behavior, or broader runtime integration, put it in `tests/integration/` or `testsuite/`.
4. Ensure the relevant Nimble task includes the new file.

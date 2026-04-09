# Testing Patterns

**Analysis Date:** 2026-04-09

## Test Framework

**Runner:**
- Nim `unittest` module for unit and integration tests (`tests/test_*.nim`)
- Bash shell script for black-box language tests (`testsuite/run_tests.sh`)
- Project-level task aggregation through `nimble test` and `nimble testintegration` in `gene.nimble`

**Assertion Library:**
- Nim unittest built-ins: `suite`, `test`, `check`, `fail()`
- Helper macros in `tests/helpers.nim`: `test_vm()`, `test_parser()`, `test_parser_error()`, `test_vm_error()`, `test_serdes()`

**Run Commands:**
```bash
nimble test                                    # All unit tests (40+ test files)
nimble testintegration                        # All integration tests (stdlib, async, modules, etc.)
nim c -r tests/test_parser.nim               # Single Nim test file
nim c -r tests/integration/test_async.nim    # Feature-specific test
./testsuite/run_tests.sh                     # Black-box Gene source tests
./testsuite/run_tests.sh testsuite/01-syntax/basics/1_literals.gene  # Targeted test
```

**Tasks in gene.nimble:**
- `testcore`: Parser, types, stream parsing tests (lines 65-69)
- `test`: Unit tests only — 16 test files (lines 71-91)
- `testintegration`: Integration tests — 65+ test files (lines 93-156)
- `testapp`: App/network tests with external integrations (lines 158-177)
- `testpostgres`: Postgres-specific tests with environment setup (lines 179-181)

## Test File Organization

**Location:**
- Nim unit tests: `tests/test_*.nim` (40+ files)
- Nim integration tests: `tests/integration/test_*.nim` (60+ files)
- Black-box Gene tests: `testsuite/` with subdirectories by feature
- Helpers and shared code: `tests/helpers.nim`

**Naming:**
- Nim tests: `test_<feature>.nim` (e.g., `test_parser.nim`, `test_async.nim`, `test_stdlib_sqlite.nim`)
- Integration tests: `test_<subsystem>.nim` (e.g., `test_http.nim`, `test_websocket.nim`, `test_oop.nim`)
- Testsuite directories: numbered feature categories (e.g., `01-syntax/`, `05-functions/`, `10-async/`)
- Testsuite files: sequential numbers with descriptive names (e.g., `1_literals.gene`, `2_variables.gene`)

**Structure:**
```
tests/
  helpers.nim                       # Shared test utilities and initialization
  test_types.nim                    # Type system and value tests
  test_parser.nim                   # Parser tests
  integration/
    test_basic.nim                  # Basic arithmetic and literals
    test_async.nim                  # Async/future behavior
    test_exception.nim              # Exception handling
    test_oop.nim                    # Object-oriented features
    test_stdlib_string.nim          # String methods
    ...65+ integration test files

testsuite/
  run_tests.sh                      # Test runner with # Expected: validation
  01-syntax/
    basics/1_literals.gene
    basics/2_variables.gene
    strings/1_interpolation.gene
  03-expressions/
  05-functions/
  10-async/
  ...26 feature directories
```

## Test Structure

**Suite Organization (Nim tests):**

From `tests/test_types.nim:7-10`:
```nim
test "Value kind":
  check NIL.kind == VkNil
  check VOID.kind == VkVoid
  check PLACEHOLDER.kind == VkPlaceholder
```

From `tests/integration/test_basic.nim:7-12`:
```nim
test_vm "nil", NIL
test_vm "1", 1
test_vm "true", true
test_vm "(1 + 2)", 3
test_vm "(if true 1 else 2)", 1
```

**Patterns:**
- Shared initialization through `init_all()` in `tests/helpers.nim:119`
- Parser and VM behavior tested separately with dedicated helper wrappers
- Test names embedded in `test_vm()` macro call sites
- Multiple overloads of test helpers for different use cases

**Helper Wrappers** (`tests/helpers.nim:134-221`):
```nim
# Parser tests with expected value
proc test_parser*(code: string, result: Value)

# VM tests with result value
proc test_vm*(code: string, result: Value)

# VM tests with callback for complex assertions
proc test_vm*(code: string, callback: proc(result: Value))

# Error tests expecting exceptions
proc test_vm_error*(code: string)

# Serialization round-trip tests
proc test_serdes*(code: string, result: Value)
```

## Mocking

**Framework:**
- No centralized mocking library (gomock, mockito-style)
- Tests execute real parser/compiler/VM paths for fast feedback
- Environment variables control external service tests

**Patterns:**
- Conditional compilation for optional tests: `when defined(postgresTest):` (`gene.nimble:179-180`)
- Environment variable guards: `GENE_LLM_MOCK` for LLM mock backends
- Commented-out tests for incomplete features (e.g., `test_ai_*.nim` files commented in `testapp` task, lines 165-173)
- Native test functions registered at runtime: `test1`, `test2`, `test_increment`, `test_reentry` (`helpers.nim:84-127`)

**What to Mock/Isolate:**
- External databases: Postgres tests require `DYLD_LIBRARY_PATH` setup (`testpostgres` task)
- LLM services: Use `GENE_LLM_MOCK` flag to avoid OpenAI/Anthropic calls
- Network services: HTTP tests mock server responses where needed
- File I/O: Most tests use in-memory data structures

**What NOT to Mock:**
- Parser/compiler/VM execution: Real codepath testing is preferred
- Standard library: String methods, array operations tested directly
- Type system: Type validation runs real type checker

## Fixtures and Factories

**Test Data:**
- In-memory value constructors in `tests/helpers.nim`: `new_gene_int()`, `new_gene_symbol()`
- Converter functions for easy test expression: `to_value()` for seq[int], `seq_to_gene()` for strings
- Gene code as string literals with `"""..."""` multiline syntax

**Location:**
- `tests/helpers.nim`: central helper and initialization logic (lines 12-222)
- `tests/helpers.nim` converters (lines 12-28): Convert Nim seq/tuple to Gene values
- Helper procedures (lines 31-58): `gene_type()`, `gene_props()`, `gene_children()`
- Cleanup utility (lines 60-64): `cleanup()` normalizes code formatting

**Fixtures Used:**
- Gene code fixtures: String expressions passed directly to `test_vm()`
- Extension module tests: Ensure `libhttp`, `libsqlite`, etc. are built before running (`ensure_core_extensions_built()`)
- Test initialization: `init_all()` sets up VM, parser, and stdlib globals

**Factory Example** (`helpers.nim:31-41`):
```nim
proc new_gene_int*(val: int): Value =
  val.to_value()

proc new_gene_symbol*(s: string): Value =
  s.to_symbol_value()

proc gene_type*(v: Value): Value =
  if v.kind == VkGene:
    v.gene.type
  else:
    raise newException(ValueError, "Not a gene value")
```

## Coverage

**Requirements:**
- No enforced numeric coverage gate or threshold
- Quality bar is passing all test tasks and integration test suite
- CI validates build + test suite success (not explicit coverage reports)

**Configuration:**
- Coverage tools not configured in `nim.cfg` or `gene.nimble`
- Test selection is manual and organized by feature/subsystem
- Testability achieved through modular architecture and unit test density

## Test Types

**Unit Tests:**
- Parser/compiler/type-system tests in `tests/test_*.nim` (16 files, ~500+ test cases)
- Focus: individual runtime subsystems with fast feedback
- Examples: `test_parser.nim`, `test_types.nim`, `test_opcode_dispatch.nim`, `test_extended_types.nim`

**Integration Tests:**
- Command-level, stdlib, async, module tests in `tests/integration/` (65+ files)
- Focus: subsystem interactions and language features
- Examples: `test_async.nim`, `test_oop.nim`, `test_stdlib_sqlite.nim`, `test_thread.nim`, `test_module.nim`

**End-to-End Language Tests:**
- `testsuite/` executes `.gene` programs against compiled `bin/gene` binary
- Validates output against `# Expected:` comments (one per line)
- Validates exit codes via `# ExitCode:` comment
- 26 feature categories with 100+ test files

**End-to-End Test Validation** (`testsuite/run_tests.sh:42-68`):
```bash
# Extract expected output from comments
expected_output=$(grep "^# Expected:" "$test_file" | sed 's/^# Expected: //' | grep -v '^$')

# Run test and capture output
actual_output=$(cd "$test_dir" && run_gene $extra_args "$test_basename" 2>&1)

# Compare with type warning filtering
# Filter out empty lines and compile-time type warnings
```

## Common Patterns

**Test Initialization:**
- Global setup in `tests/helpers.nim:119-128`: `init_all()` initializes parser, VM, stdlib
- Per-test cleanup: Tests are isolated and reuse shared global state
- Extension setup: `ensure_core_extensions_built()` runs `nimble buildext` if needed

**Async Testing:**
- Future checking with value extraction: `check r.kind == VkFuture`, `check r.ref.future.value.int64 == 1` (`test_async.nim:40-42`)
- Await syntax testing: `(await (async 1))` returns unwrapped value
- Async error propagation: `(async (throw))` then caught by `await` or `on_failure`

**Error Testing:**
- Dedicated error helpers:
  - `test_parser_error(code)`: Expects ParseError exception
  - `test_vm_error(code)`: Expects CatchableError on execution
  - `catch *` syntax in Gene code for exception handling
- Exception access via `$ex` variable in `catch` blocks

**Pattern: Exception Testing** (`tests/integration/test_exception.nim:14-16`):
```nim
test_vm_error """
  (throw "test error")
"""
```

**Pattern: Callback-based Testing** (`tests/integration/test_async.nim:38-42`):
```nim
test_vm """
  (async 1)
""", proc(r: Value) =
  check r.kind == VkFuture
  check r.ref.future.state == FsSuccess
  check r.ref.future.value.int64 == 1
```

**Snapshot Testing:**
- Not explicitly used; assertions are value-driven and explicit
- Testsuite uses textual output matching with `# Expected:` comments

## Test Organization Best Practices

**For Adding Tests:**

**Unit test:** Create `tests/test_<subsystem>.nim`
- Import `unittest` and `gene/types`
- Use `test "description": check condition`
- Call `init_all()` before VM/stdlib usage

**Integration test:** Create `tests/integration/test_<feature>.nim`
- Import helpers and use `test_vm()` macro
- Test multi-component interactions
- Example: `test_vm "(do 1 2 3)", 3`

**E2E language test:** Create `testsuite/<category>/<N>_<feature>.gene`
- Include `# Expected: <output>` comments for each expected line
- Optionally include `# Args: <args>` for CLI arguments
- Optionally include `# ExitCode: <N>` for exit code validation

**Fixture data:** Add to `tests/helpers.nim`
- Define converter functions or factory procedures
- Register with `init_all()` if needing VM registration

---

*Testing analysis: 2026-04-09*

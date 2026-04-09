# Coding Conventions

**Analysis Date:** 2026-04-09

## Naming Patterns

**Files:**
- Underscores for separation: `test_types.nim`, `test_parser.nim`, `core_helpers.nim`
- Logical grouping by module: `types/`, `vm/`, `compiler/`, `native/`, `extension/`
- Descriptive module names matching content: `logging_core.nim`, `parser.nim`, `type_checker.nim`, `formatter.nim`

**Functions and Procedures:**
- snake_case for all procedures and functions: `new_str_value()`, `to_value()`, `exec_function()`, `split_container_name()`
- Getter functions use no prefix: `str(v: Value)`, `kind(v: Value)`, `array_data()`
- Constructors prefix with `new_`: `new_str_value()`, `new_array_value()`, `new_map_value()`, `new_parser()`
- Converter functions use `to_`: `to_value()`, `to_int()`, `to_bool()`, `to_symbol_value()`, `to_key()`
- Predicates use `is_` prefix: `is_nil()`, `is_method_frame()`, `is_function_like()`
- Public procs marked with `*`: `proc to_value*(v: int)`, `proc exec*(self: ptr VirtualMachine): Value`

**Variables:**
- snake_case for all local and instance variables: `var initialized = false`, `let symbol_index = ...`, `test_name`, `actual_output`
- Constants use UPPER_SNAKE_CASE: `NAN_MASK`, `SMALL_INT_MIN`, `SMALL_INT_MAX`, `NIL`, `TRUE`, `FALSE`, `VOID`, `PLACEHOLDER`, `CHANNEL_LIMIT`, `MAX_THREADS`, `EVENT_LOOP_POLL_INTERVAL`
- Thread-local/global variables marked with `{.threadvar.}` or `var` declarations: `var VM {.threadvar.}`, `var App`, `var THREADS`
- Module-level state prefixed with context: `parser_config {.threadvar.}`, `connection_class_global`

**Types:**
- PascalCase for type definitions: `ParseError`, `VirtualMachine`, `Value`, `Key`, `Namespace`, `Scope`, `Gene`, `String`
- Enum variants in PascalCase: `VkNil`, `VkBool`, `VkInt`, `VkString`, `VkSymbol`, `VkArray`, `VkMap`, `VkGene`, `VkFunction`, `FkMethod`, `FkMacroMethod`
- Discriminator prefixes indicate type: `Vk*` for ValueKind, `Fk*` for FrameKind, `Tk*` for TokenKind, `Ll*` for LogLevel
- Ref types use `ptr` for low-level references: `ptr VirtualMachine`, `ptr Gene`, `ptr String`, `ptr Reference`

## Code Style

**Formatting:**
- No explicit formatter (no `.nimpretty`, Prettier, or ESLint config)
- Indentation: 2 spaces (consistent across `gene.nimble`, test files, source code)
- Line continuation: Natural Nim style with implicit line joining in function calls
- Module organization uses both `import` (for modularity) and `include` (for composition)

**Linting:**
- Relies on Nim compiler type checking and warnings
- Compiler flags in `nim.cfg` suppress specific warning categories
- No automated code quality gates beyond compilation and test suite

**Compiler Warnings:**
- Suppressed in `vm.nim` line 1: `warning[ResultShadowed]`, `warning[UnreachableCode]`, `warning[UnusedImport]`
- Type checking is gradual (not strict) with optional runtime type annotations
- Runtime type system coerces values when possible (e.g., int↔float)
- Release builds optimize for speed: `nim.cfg` uses `--mm:orc`, `--opt:speed`, `--panics:on`

## Import Organization

**Order (from `types/core.nim`, `parser.nim`, `compiler.nim`):**
1. Standard library imports: `import tables, strutils, streams, times, os, asyncdispatch, unicode, locks, random`
2. Local relative imports: `import ./types`, `import ./parser`, `import ./logging_core`
3. Re-exports via `export` for public API surfaces
4. Conditional imports for optional features: `when not defined(noExtensions): import ./vm/extension`

**Path Aliases:**
- Relative imports use `./` prefix: `import ./types`, `import ../helpers`
- Nested modules included with quotes: `import "./vm/native"`, `import "./compiler/if"`
- Selective imports for narrower scope: `from ./types/runtime_types import validate_type, validate_or_coerce_type`
- Module files re-export sub-modules for cleaner API: `src/gene/types.nim` exports from `types/core.nim`, `types/classes.nim`, `types/helpers.nim`

**Example** (`vm.nim:1-35`):
```nim
import tables, strutils, strformat, algorithm, options, streams
import times, os
import asyncdispatch

import ./types
import ./logging_core
from ./types/runtime_types import validate_type, validate_or_coerce_type
import ./compiler
from ./parser import read, read_all
import ./hash_map_support
import ./vm/args
import ./vm/module
export profile
include ./vm/native
include ./vm/async
```

## Error Handling

**Patterns:**
- Raises custom exceptions for parsing: `raise new_exception(ParseError, "read_string failure: " & $self.error)` (`parser.nim:384`)
- Nim exception syntax: `except CatchableError`, `except CatchableError as e`, `except ValueError`
- Try/except blocks used for recoverable errors in parser, config, and integration code
- Gene language has separate exception mechanism (`catch *` syntax in Gene code) from Nim exceptions
- Wrapper type `GeneException` for Nim↔Gene exception translation in `src/gene/vm/exceptions.nim`
- Casting for gcsafe workarounds: `{.cast(gcsafe).}:` used in reentrant code (helpers.nim:105)

**Error Propagation:**
- Parser raises `ParseError` and `ParseEofError` for syntax issues
- VM catches exceptions at module/type-checking level and formats for display
- Config loading uses try/except to handle missing or invalid files gracefully (`logging_config.nim:87-106`)
- Integrations (HTTP, database) return error values in structured form

## Logging

**Framework:** Built-in `log_message()` and `log_enabled()` (from `logging_core.nim`)

**Patterns:**
- Thread-local `LogLevel` constants: `LlTrace`, `LlDebug`, `LlInfo`, `LlWarn`, `LlError`
- Logger names use module path format: `"gene/parser"`, `"gene/vm/exec"`, `"gene/vm/dispatch"`, `"gene/vm/thread"`
- Guard with `log_enabled()` before expensive logging to avoid overhead
- Template wrappers for cleaner syntax: `template vm_log(level, logger_name, message) = ...` (`vm.nim:43-45`)
- Configurable via `logging_config.nim` — parses YAML/JSON configuration at startup
- No logging in performance-critical hot paths (parser, VM opcodes)

**Usage Examples:**
```nim
# vm.nim:43-45
template vm_log(level: LogLevel, logger_name: string, message: untyped) =
  if log_enabled(level, logger_name):
    log_message(level, logger_name, message)

# parser.nim:1842
if log_enabled(LlTrace, ParserLogger):
  log_message(LlTrace, ParserLogger, "base64 chunk " & s)
```

## Comments

**When to Comment:**
- Explain "why" not "what": Comments describe reasoning, not code mechanics
- Document non-obvious algorithm choices or low-level encoding (e.g., NaN boxing in `types/core.nim:12-13`)
- Mark unfinished work with `TODO:` or `FIXME:` (found in test files and implementation)
- Credit external sources: `parser.nim:1-5` credits EDN Parser inspiration
- Document workarounds for compiler limitations: `{.cast(gcsafe).}:` with explanation

**JSDoc/TSDoc Style:**
- Documentation comments use `##` syntax (Nim style): `## In strict mode, raise an error.`
- Used selectively for complex algorithms in `type_checker.nim`
- Procedure signatures include forward declarations with full type info
- Not pervasive — selective documentation focused on non-obvious behavior

**Comment Style Examples:**
```nim
# parser.nim:1-5 (External credit)
# Credit:
# The parser and basic data types are built on top of EDN Parser[1] that is
# created by Roland Sadowski.
# 1. https://github.com/rosado/edn.nim

# types/core.nim:12-14 (Algorithm explanation)
#################### NaN Boxing implementation ####################
# We use the negative quiet NaN space (0xFFF0-0xFFFF prefix) for non-float values
# This allows all valid IEEE 754 floats to work correctly
```

## Function Design

**Size:** 
- Generally compact (15-40 lines per function)
- Large orchestration files segmented with `include`: `vm.nim` (144 lines) includes 10+ sub-modules
- Nested helper functions used for code organization: `split_container_name()` defines nested `normalize_prefix()` (`compiler.nim:38-82`)
- VM dispatch functions larger due to opcode handling requirements

**Parameters:**
- Leading `self` for instance methods: `proc to_value*(self: Value): string`
- VM native function signature (standardized): `proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.}`
- Reference parameters use `var`: `proc apply_container_to_child(gene: ptr Gene, child_index: int)`
- Default parameters used sparingly — prefer overload variants
- Argument extraction from arrays: `let arg = get_positional_arg(args, 0, has_keyword_args)` (helpers.nim:91)

**Return Values:**
- Explicit return type in signature: `proc parse_bin(self: var Parser): Value`
- Implicit return from last expression (Nim style)
- Early return for error/edge conditions: `if len == 0: return NIL` or `if not initialized: return`
- Multiple return values via tuples: `proc split_container_name(name: Value): tuple[base: Value, container: Value]` (`compiler.nim:38`)

## Module Design

**Exports:**
- Modules re-export from sub-modules for API clarity: `types.nim` exports from `types/core.nim`, `types/classes.nim`, `types/helpers.nim`
- Forward declarations in main module, implementations in sub-modules
- Public procs marked with `*` suffix: `proc to_value*(v: int)`, `proc exec*(self: ptr VirtualMachine): Value`
- Private procs have no suffix and are not exported

**Barrel Files:**
- `src/gene/types.nim` acts as index, importing and re-exporting all type modules (lines 1-17)
- `src/gene/vm.nim` includes multiple sub-files via `include` directive for composition (lines 56-109)
- Supports both modular (`import`) and monolithic (`include`) organization

**Module Conventions** (`types.nim:1-17`):
```nim
import types/type_defs
import types/core
import types/classes
import types/custom_value
import types/instructions
import types/helpers
import types/interfaces
import ./utils

export type_defs
export core
export classes
export custom_value
export instructions
export helpers
export interfaces
export utils
```

**Thread-local State:**
- Global VMs are thread-local: `var VM* {.threadvar.}: ptr VirtualMachine` (`types/core.nim:81`)
- Parser state is thread-local: `var parser_config {.threadvar.}: ParserConfig` (`parser.nim:119`)
- App instance shared across threads (initialized once): `var App*: Value` (`types/core.nim:85`)
- Thread pool metadata: `var THREADS*: array[MAX_THREADS, ThreadMetadata]` (`types/core.nim:92`)

**Include vs Import:**
- `import` used for dependency clarity when modules are independent
- `include` used for composition when splitting large files (VM, compiler, async)
- Callbacks for extension registration: `VmCreatedCallbacks` seq holds init procs that run after App creation

---

*Convention analysis: 2026-04-09*

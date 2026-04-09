# Codebase Structure

**Analysis Date:** 2025-04-09

## Directory Layout

```
gene-old/
├── src/                   # Nim source code (CLI, VM, compiler, parser, stdlib, extensions)
│   ├── gene.nim          # CLI entry point and command dispatch
│   ├── commands/         # CLI command handlers (run, eval, repl, compile, etc.)
│   ├── gene/             # Core language runtime internals
│   │   ├── parser.nim
│   │   ├── compiler.nim
│   │   ├── compiler/     # Compiler sub-modules (control flow, functions, operators, etc.)
│   │   ├── vm.nim
│   │   ├── vm/           # VM sub-modules (exec, dispatch, async, module, exceptions, etc.)
│   │   ├── type_checker.nim
│   │   ├── types/        # Type system definitions
│   │   ├── stdlib/       # Standard library native functions
│   │   ├── extension/    # Extension system and C API
│   │   ├── native/       # Native code generators (x86_64, arm64, bytecode_to_hir)
│   │   ├── gir.nim       # GIR serialization format
│   │   ├── serdes.nim    # Serialization/deserialization
│   │   └── lsp/          # Language server protocol support
│   └── genex/            # Optional extension namespaces (http, db, ai, websocket)
│       └── ai/           # AI agent platform
├── tests/                 # Nim unittest-based test files
│   ├── test_*.nim        # Individual test modules
│   ├── integration/      # Integration tests
│   └── fixtures/         # Test data and helper modules
├── testsuite/            # Black-box Gene program test suite (.gene files)
│   ├── 01-syntax/        # Syntax and literal tests
│   ├── 02-types/         # Type system tests
│   ├── 03-expressions/   # Expression and operator tests
│   ├── 04-control-flow/  # Control flow (if, case, try) tests
│   ├── 05-functions/     # Function and scope tests
│   ├── 06-collections/   # Array, map, set tests
│   ├── 07-oop/           # Object-oriented programming tests
│   ├── 08-modules/       # Module and import tests
│   ├── 09-errors/        # Exception handling tests
│   ├── 10-async/         # Async/await tests
│   ├── 11-generators/    # Generator tests
│   ├── 12-patterns/      # Pattern matching tests
│   ├── 13-regex/         # Regular expression tests
│   ├── 14-stdlib/        # Standard library function tests
│   ├── 15-serialization/ # Serialization tests
│   ├── ai/               # AI integration tests
│   ├── examples/         # Example program tests
│   ├── pipe/             # Pipe command tests
│   ├── fmt/              # Formatter tests
│   └── run_tests.sh      # Main test runner
├── docs/                 # Architecture and design documentation
├── examples/             # Gene language example programs
├── example-projects/     # Sample applications and libraries
├── benchmarks/           # Performance benchmarks
├── scripts/              # Utility scripts (profiling, benchmarking)
├── tools/                # Extra tooling (vscode extension, nginx config)
├── openspec/             # Spec proposals and change tracking
├── bin/                  # Compiled executables (gitignored)
├── build/                # Build artifacts and GIR cache (gitignored)
├── gene.nimble           # Nimble package manifest and tasks
├── nim.cfg               # Compiler build flags
└── README.md             # Project overview
```

## Directory Purposes

**src/**
- Purpose: Main implementation code
- Contains: Nim source files (`*.nim`) for runtime, compiler, parser, stdlib, and extensions
- Key files: `src/gene.nim`, `src/gene/vm.nim`, `src/gene/compiler.nim`, `src/gene/parser.nim`
- Subdirectories:
  - `src/commands/` - CLI command implementations
  - `src/gene/` - Core language runtime
  - `src/genex/` - Optional extension modules

**src/commands/**
- Purpose: CLI command handlers
- Contains: Individual command modules (run.nim, eval.nim, compile.nim, etc.)
- Key files: `run.nim` (file execution), `eval.nim` (inline evaluation), `repl.nim` (interactive shell)
- Naming: Command names match their implementations (`run.nim` for `gene run`)

**src/gene/**
- Purpose: Core language implementation
- Contains: Parser, compiler, VM, type system, stdlib
- Key files:
  - `parser.nim` - Source code parser (57K)
  - `compiler.nim` - Bytecode compiler (27K)
  - `vm.nim` - VM core (5K, includes vm/ submodules)
  - `type_checker.nim` - Type validation (114K)
  - `serdes.nim` - Serialization (72K)
  - `gir.nim` - GIR format (31K)
- Subdirectories:
  - `compiler/` - Compiler form-specific modules (control_flow, functions, operators, etc.)
  - `vm/` - VM subsystem modules (exec, dispatch, async, module, exceptions, etc.)
  - `types/` - Type system definitions
  - `stdlib/` - Standard library native functions
  - `extension/` - Extension boilerplate and C API
  - `native/` - Native code generation

**src/gene/compiler/**
- Purpose: Form-specific compilation logic
- Contains: Compiler modules split by language construct type
- Key files:
  - `control_flow.nim` - if, case, try/catch compilation (57K)
  - `functions.nim` - function/method/class compilation (22K)
  - `operators.nim` - operator overloading (54K)
  - `comptime.nim` - macro expansion and compile-time evaluation (14K)
  - `pipeline.nim` - pipeline operators (30K)
  - `collections.nim` - collection literal compilation

**src/gene/vm/**
- Purpose: VM execution and support subsystems
- Contains: Instruction dispatch, method dispatch, async, module loading, etc.
- Key files (by size/importance):
  - `exec.nim` - Main instruction dispatch loop (273K)
  - `dispatch.nim` - Method and call dispatch (33K)
  - `module.nim` - Module loading and namespace (50K)
  - `async.nim` - Async/await primitives (13K)
  - `adapter.nim` - Adapter pattern for interfaces (16K)
  - `arithmetic.nim` - Arithmetic operations (10K)

**src/gene/types/**
- Purpose: Value representation and type definitions
- Contains: NaN-boxing implementation, value kinds, memory management
- Key files:
  - `type_defs.nim` - Value enum, NaN-boxing constants (41K)
  - `core.nim` - NaN-boxing and value operations (10K)
  - `runtime_types.nim` - Type descriptors and validation (22K)
  - `classes.nim` - Class definitions (10K)
  - `memory.nim` - Reference counting (6K)

**src/gene/stdlib/**
- Purpose: Built-in functions and types
- Contains: Native implementations of core functions (strings, collections, I/O, math, regex, etc.)
- Key files (largest first):
  - `core.nim` - Core functions (print, len, map, etc.) (174K)
  - `collections.nim` - Array/map/set operations (74K)
  - `strings.nim` - String manipulation (34K)
  - `system.nim` - System functions (29K)
  - `gene_meta.nim` - Reflection (31K)
  - `dates.nim` - Date/time (14K)
  - `regex.nim` - Regular expressions (19K)
- Registered as native functions in VM, callable from Gene code

**src/genex/**
- Purpose: Optional domain-specific extensions (HTTP, database, AI)
- Contains: Extension modules and feature-specific implementations
- Key files:
  - `http.nim` - HTTP client/server, WebSocket (75K)
  - `websocket.nim` - RFC 6455 WebSocket (11K)
  - `llm.nim` - LLM integration (43K)
  - `sqlite.nim`, `postgres.nim` - Databases (10K, 14K)
  - `html.nim`, `test.nim`, `logging.nim` - Utilities
- Subdirectory:
  - `ai/` - AI agent platform with Slack, LLM, tool dispatch, memory

**tests/**
- Purpose: Unit and integration tests (Nim unittest framework)
- Contains: `test_*.nim` files and integration test suites
- Key files: `test_parser.nim`, `test_vm_*.nim`, `test_type_checker.nim`, `test_stream_parser.nim`
- Subdirectories:
  - `integration/` - Integration tests for major features
  - `fixtures/` - Sample modules and test data

**testsuite/**
- Purpose: End-to-end language behavior validation via `.gene` programs
- Contains: Category folders with numeric-prefixed test files
- Numbered sections (01-syntax through 15-serialization) ordered for spec-aligned execution
- Test organization:
  - `01-syntax/` - Syntax, literals, basic operations
  - `02-types/` - Type system behavior
  - `03-expressions/` - Operators and expressions
  - `04-control-flow/` - if, case, try statements
  - `05-functions/` - Function definitions and calls
  - `06-collections/` - Array, map, set operations
  - `07-oop/` - Classes, methods, inheritance
  - `08-modules/` - Module imports and namespaces
  - `09-errors/` - Exception handling
  - `10-async/` - Async/await and futures
  - `11-generators/` - Generator expressions
  - `12-patterns/` - Pattern matching and destructuring
  - `13-regex/` - Regular expression matching
  - `14-stdlib/` - Standard library functions
  - `15-serialization/` - Serialization/deserialization
- Separate suites: `pipe/`, `examples/`, `fmt/`, `ai/`
- Runner: `testsuite/run_tests.sh`

## Key File Locations

**Entry Points:**
- `src/gene.nim` - CLI main entry, command dispatch
- `src/commands/run.nim` - File execution command
- `src/commands/eval.nim` - Inline expression evaluation
- `src/commands/repl.nim` - Interactive REPL

**Configuration:**
- `gene.nimble` - Package metadata, build tasks
- `nim.cfg` - Nim compiler build flags
- `.github/workflows/build-and-test.yml` - CI pipeline

**Core Logic:**
- `src/gene/parser.nim` - Source parser
- `src/gene/compiler.nim` - Bytecode compiler
- `src/gene/vm.nim` - VM core
- `src/gene/type_checker.nim` - Type validation

**Type System:**
- `src/gene/types/type_defs.nim` - Value kind definitions
- `src/gene/types/core.nim` - NaN-boxing implementation
- `src/gene/types/runtime_types.nim` - Type descriptor registry

**Testing:**
- `tests/` - Nim-based unit tests
- `testsuite/run_tests.sh` - Main black-box test runner
- `testsuite/TEST_ORGANIZATION.md` - Test structure documentation

**Documentation:**
- `README.md` - Project overview
- `docs/` - Architecture and design documents
- `CLAUDE.md` - AI assistant guidelines
- `openspec/` - Specification proposals

## Naming Conventions

**Files:**
- `snake_case.nim` for most files (`type_checker.nim`, `runtime_helpers.nim`)
- Command files use simple names (`run.nim`, `eval.nim`, `compile.nim`)
- Test files: `test_*.nim` or `*_test.nim`
- Testsuite files: Numeric prefixes (`1_*.gene`, `2_*.gene`) for ordering

**Directories:**
- lowercase names, mostly snake_case for multi-word (`example-projects`, `known_issues`)
- Feature-organized testsuite directories (`control_flow/`, `callable_instances/`)

**Special Patterns:**
- `src/gene/compiler/*.nim` - Compiler split by form/concern
- `src/gene/vm/*.nim` - VM split by subsystem
- `src/genex/ai/*.nim` - AI platform subsystem modules
- `testsuite/` - Numbered top-level sections (01-, 02-, etc.) for spec alignment

## Where to Add New Code

**New Language Feature:**
- Parser updates: `src/gene/parser.nim`
- Compiler emission: `src/gene/compiler.nim` or `src/gene/compiler/<concern>.nim`
- VM instruction semantics: `src/gene/vm.nim` and/or `src/gene/vm/<subsystem>.nim`
- Tests: `tests/test_*.nim` + relevant `testsuite/<category>/`
- Examples: `examples/`

**New CLI Command:**
- Implementation: `src/commands/<command>.nim`
- Registration: Add to command manager in `src/gene.nim`
- Tests: Add/extend tests in `tests/` or `testsuite/pipe/`

**New Extension Namespace:**
- Implementation: `src/genex/<feature>.nim` or `src/genex/<feature>/`
- Registration: Extension init proc + VM init hook
- Tests: Focused tests in `tests/` and examples in `examples/`

**New Standard Library Function:**
- Implementation: Add proc to appropriate `src/gene/stdlib/<module>.nim`
- Registration: Export from stdlib module, register in VM
- Tests: Add to `testsuite/14-stdlib/<feature>/`

**Documentation Changes:**
- Architecture/design: `docs/`
- Spec proposals: `openspec/changes/...`
- README updates: `README.md`

## Special Directories

**build/**
- Purpose: Generated artifacts (GIR cache, build outputs)
- Source: Produced by compile/run commands
- Committed: No (gitignored)

**bin/**
- Purpose: Compiled executable output (`bin/gene`)
- Source: Nim build outputs
- Committed: No (gitignored)

**tmp/**
- Purpose: Temporary files and caches
- Committed: No (gitignored)

**docs/**
- Purpose: Architecture, design, and feature documentation
- Committed: Yes
- Key files: Various markdown files documenting design decisions

**openspec/**
- Purpose: Specification proposals and change tracking
- Committed: Yes
- Files: `AGENTS.md`, `project.md`, `changes/`

---

*Structure analysis: 2025-04-09*

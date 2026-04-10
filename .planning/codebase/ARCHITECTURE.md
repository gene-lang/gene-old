# Architecture

**Analysis Date:** 2025-04-09

## Pattern Overview

**Overall:** Stack-based bytecode VM with NaN-boxed values and multi-stage compilation pipeline

**Key Characteristics:**
- S-expression Lisp-like syntax parsed into Gene AST structures with source traces
- Multi-stage compiler: parser → type-checker → bytecode compiler → VM execution
- Stack-based virtual machine with manual memory management and NaN-boxed 64-bit values
- Rich type system with 100+ value kinds (scalars, collections, classes, async, exceptions)
- Inline caching for method dispatch and property lookups
- Both synchronous and asynchronous execution with event loop integration
- Aspect-oriented programming (AOP) support with interception and advice
- Exception handling with normalized exception classes

## Layers

**Parser Layer:**
- Purpose: Convert S-expression source code into AST (Gene objects) with source traces
- Location: `src/gene/parser.nim` (57K lines)
- Contains: Lexer, token handling, macro readers (regex, quotes, date/time literals), multiple parse modes (Document, Stream, First, Package, Archive)
- Depends on: `src/gene/types` (AST representation), `src/gene/logging_core`
- Used by: Compiler, REPL, file loading, module imports

**Type Checking Layer:**
- Purpose: Static type validation and inference before bytecode generation
- Location: `src/gene/type_checker.nim` (114K lines)
- Contains: Type descriptor registry, type unification, runtime type objects (RtTypeObj), type validation, method resolution
- Depends on: Parser output (Gene AST), type system definitions in `src/gene/types/`
- Used by: Compiler, provides type information for runtime dispatch

**Compiler Layer:**
- Purpose: Transform AST into bytecode instructions for VM execution
- Location: `src/gene/compiler.nim` (27K lines) + `src/gene/compiler/` (13 modules, 180K lines)
- Contains: Expression compilation, function/method/class compilation, control flow, operator compilation, pipeline operators, optimization
- Sub-modules:
  - `compiler/control_flow.nim` - if, case, try/catch compilation (57K lines)
  - `compiler/functions.nim` - function/method/class compilation (22K lines)
  - `compiler/operators.nim` - operator overloading and special forms (54K lines)
  - `compiler/comptime.nim` - compile-time evaluation (macro expansion) (14K lines)
  - `compiler/optimize.nim` - peephole optimization
  - `compiler/pipeline.nim` - pipeline operators
- Depends on: Parser (Gene AST), type information, instruction definitions
- Used by: VM, REPL, CLI compile command

**VM Execution Layer:**
- Purpose: Execute bytecode instructions with stack-based evaluation
- Location: `src/gene/vm.nim` (5K lines - header) + `src/gene/vm/` (26 modules, 1.1M+ lines)
- Contains: Instruction dispatch loop, frame management, scope tracking, reference counting
- Core execution files:
  - `vm/exec.nim` - Main instruction dispatch loop with computed goto (273K lines)
  - `vm/dispatch.nim` - Call dispatch, unified method resolution (33K lines)
  - `vm/async.nim` - Async/await implementation with event loop (13K lines)
  - `vm/async_exec.nim` - Async execution bridge (8K lines)
  - `vm/module.nim` - Module loading and namespace management (50K lines)
  - `vm/exceptions.nim` - Exception handling and class normalization (5K lines)
  - `vm/adapter.nim` - Adapter wrapper pattern for interface implementation (16K lines)
  - `vm/arithmetic.nim` - Arithmetic operations (10K lines)
  - `vm/extension.nim` - Extension loading and native function bridging
  - `vm/thread.nim` - Thread pool and message passing
- Depends on: Compiler (bytecode), Types, Extensions, Stdlib
- Used by: Commands, REPL, native code generators

**Type System Layer:**
- Purpose: Define all value kinds and their representations using NaN-boxing
- Location: `src/gene/types/` (12 modules, 150K+ lines)
- Contains:
  - `type_defs.nim` (41K) - Value enum (100+ kinds), NaN-boxing constants, memory layout
  - `core.nim` (10K) - NaN-boxing implementation, value creation/conversion
  - `classes.nim` (10K) - Class definitions (class, method, instance)
  - `runtime_types.nim` (22K) - Runtime type objects, type descriptors, type validation
  - `memory.nim` (6K) - Reference counting, garbage collection
  - `instructions.nim` (5K) - Bytecode instruction definitions (200+ instruction kinds)
  - `helpers.nim` (12K) - Value helper functions and conversions
  - `reference_types.nim` (6K) - Reference type management
- Depends on: None (foundational)
- Used by: Parser, Compiler, VM, Extensions

**Standard Library Layer:**
- Purpose: Provide built-in functions and types (strings, collections, I/O, math, regex)
- Location: `src/gene/stdlib/` (14 modules, 400K+ lines)
- Contains: Native function implementations registered in `core.nim` (174K lines)
  - `core.nim` - Core functions (print, map, select, len, etc.), string methods, collection functions
  - `collections.nim` - Array/map/set operations, sorting, filtering (74K)
  - `strings.nim` - String manipulation, case conversion, splitting (34K)
  - `system.nim` - System functions (sleep, exit, gc) (29K)
  - `dates.nim` - Date/time handling with timezone support (14K)
  - `regex.nim` - Regular expression matching and substitution (19K)
  - `io.nim` - File I/O, directory operations (17K)
  - `classes.nim` - OOP support (class definition, inheritance, method dispatch) (21K)
  - `json.nim` - JSON serialization/deserialization (11K)
  - `math.nim` - Math functions (11K)
  - `aspects.nim` - AOP support (12K)
  - `gene_meta.nim` - Reflection and meta-programming (31K)
- Depends on: VM, Types
- Used by: All Gene programs

**Extension Layer:**
- Purpose: Allow native Nim code to integrate with Gene as functions/classes
- Location: `src/gene/extension/`
- Contains: Extension boilerplate, C API, native function registration, boilerplate macro
- Depends on: VM, Types
- Used by: External modules, genex extensions

**External Integration Layer (genex):**
- Purpose: Provide domain-specific libraries for web (HTTP/WebSocket), AI (LLM, RAG), databases
- Location: `src/genex/` (15 modules, 200K+ lines)
- Contains:
  - `http.nim` (75K) - HTTP client/server with WebSocket support, async request handling, worker pools
  - `websocket.nim` (11K) - RFC 6455 WebSocket implementation (frame encode/decode, handshake)
  - `ai/` (22 modules) - AI agent platform (Slack integration, LLM providers, tool dispatch, memory store, RAG)
  - `sqlite.nim` (10K), `postgres.nim` (14K) - Database drivers
  - `html.nim` (18K), `test.nim` (12K), `logging.nim`, `db.nim` - Utility libraries
  - `llm.nim` (43K) - Local and cloud LLM integration
- Depends on: VM, Types, External libraries (asynchttpserver, websocket module, sqlite3, etc.)
- Used by: Gene programs that need web/AI/database capabilities

**Commands Layer:**
- Purpose: CLI interface for building, running, and analyzing Gene programs
- Location: `src/commands/` (18 modules, 200K+ lines)
- Contains:
  - `run.nim` - Execute Gene files with caching support (13K)
  - `eval.nim` - Evaluate inline expressions (8K)
  - `repl.nim` - Interactive REPL (2K)
  - `compile.nim` - Compile to bytecode or GIR cache (15K)
  - `gir.nim` - Generate intermediate representation (4K)
  - `parse.nim` - Parse and display AST (8K)
  - `deps.nim` - Dependency analysis (31K)
  - `pipe.nim` - Execute Gene code from stdin (9K)
  - `fmt.nim` - Code formatter
  - `help.nim`, `lsp.nim`, `view.nim`, `deser.nim`, `package_context.nim`
- Depends on: VM, Compiler, Parser
- Used by: `src/gene.nim` entry point

## Data Flow

**Compilation Pipeline:**

1. **Source → AST**: Parser reads `.gene` files/stdin, creates Gene objects with source traces
   - Input: String with source code
   - Processing: Lexical analysis, token stream, macro expansion
   - Output: Gene object (S-expression tree) with SourceTrace hierarchy

2. **AST → Type-annotated AST**: Type checker walks the tree, validates types, creates type descriptors
   - Input: Gene AST
   - Processing: Type unification, method resolution, annotation
   - Output: Type information (TypeDesc, TypeId) attached to compilation units

3. **AST → Bytecode**: Compiler generates instructions for each expression
   - Input: Gene AST + type info
   - Processing: Expression compilation, function flattening, constant folding, peephole optimization
   - Output: CompilationUnit with bytecode instructions + metadata (inline caches, source maps, constants)

4. **Bytecode → Execution**: VM instruction loop executes compiled code
   - Input: Bytecode instructions + operand stack
   - Processing: Dispatch loop with computed goto, inline cache lookup, method dispatch
   - Output: Result value on stack

**Async Data Flow:**

1. **Future Creation**: Native functions and async operations return Future values (VkFuture)
2. **Future Polling**: VM periodically calls `poll_event_loop()` to advance pending futures (every 100 instructions)
3. **Callback Execution**: When futures complete, success/failure callbacks are executed in VM
4. **Result Extraction**: `await` or callback extracts result from FutureObj

**State Management:**

- **Stack**: Operand stack per frame (256 values), call argument buffers
- **Scope Chain**: Linked scopes with local variable tracking via ScopeTracker
- **Inline Caches**: Per-instruction cache for method lookups to avoid repeated resolution
- **Global State**:
  - `App`: Singleton application instance (VkApplication) with global namespaces
  - `VM`: Thread-local virtual machine instance
  - `THREADS`: Global thread pool (64 max) for multi-threaded execution
  - `EventLoopCallbacks`: Hooks for event-driven processing (HTTP handlers, etc.)

## Key Abstractions

**Value (NaN-Boxed):**
- Purpose: 64-bit unified representation for all data types
- Location: `src/gene/types/core.nim`
- Pattern: Union using IEEE 754 NaN space for type tagging
  - Immediate values (NIL, TRUE, FALSE, small ints -2^47 to 2^47-1, single chars) packed directly in 64 bits
  - Reference values (strings, objects, arrays) stored as tagged pointers to heap-allocated Reference objects
- Examples: `NIL`, `Value(raw: 42)` (small int), string pointer with STRING_TAG prefix
- Size: 8 bytes (fits in register, supports copy semantics)

**CompilationUnit:**
- Purpose: Compiled representation of a function/method/top-level code block
- Pattern: Contains bytecode instructions + metadata
  - `instructions`: Array of Instruction structs
  - `inline_caches`: Per-instruction inline cache for method dispatch (pre-allocated or grown on demand)
  - `constants`: Literal values (strings, numbers, symbols)
  - `source_trace`: Source location tracking for error reporting
  - `scope_tracker`: Compile-time metadata about variable scopes

**Frame:**
- Purpose: Execution context for a function call or block
- Pattern: Stack frame with scope, operand stack, exception handlers
  - `scope`: Current variable binding scope (ScopeTracker + member values)
  - `operand_stack`: 256 values for expression evaluation
  - `exception_handlers`: Stack of exception handler offsets (PC values)
  - `kind`: FkFunction, FkMethod, FkMacro, FkAsyncFunction, etc. for dispatch logic
  - `call_bases`: Stack of call base indices for varargs/keyword arguments

**Scope:**
- Purpose: Variable binding context with parent chain for closures
- Pattern: Linked list of scopes with reference counting
  - `tracker`: ScopeTracker (compile-time metadata about variables)
  - `members`: Array of variable values
  - `parent`: Parent scope for closure access
  - `immutable_vars`: Set of variables declared with `let` (cannot be reassigned)
  - `ref_count`: Reference counting for garbage collection

**Method/Class:**
- Purpose: Define callable objects and type hierarchies
- Pattern: Method contains code + metadata; Class contains methods + inheritance
  - Method: `matcher` (parameter matching), `parent_scope`, `ns` (namespace), `body_compiled` (compiled bytecode)
  - Class: `methods` table (name → Method), `superclass`, `instance_methods`, `class_methods`

**Interception/Aspect (AOP):**
- Purpose: Wrap method execution with before/after/around advice
- Pattern: Metadata-driven interception
  - `Aspect`: Stores advice functions organized by method parameter name
    - `before_advices`, `after_advices`, `around_advices`, `before_filter_advices`
  - `Interception`: Links original callable to its aspect
  - Dispatch intercepts method calls, runs before-advice, calls original, runs after-advice

**Native Function:**
- Purpose: Bridge between Gene code and Nim implementations
- Pattern: Function pointer with unified signature
  - Signature: `proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}`
  - VM passes arguments in a buffer, function extracts using `get_positional_arg()` / `get_keyword_arg()`
  - Returns Value result
  - Used extensively in stdlib and genex modules

## Entry Points

**CLI Entry (`src/gene.nim`):**
- Location: `src/gene.nim`, lines 29-67
- Triggers: `./gene run file.gene`, `./gene eval expr`, `./gene repl`, etc.
- Responsibilities: 
  1. Initialize command manager with all available commands
  2. Parse command-line arguments
  3. Dispatch to appropriate command handler
  4. Clean up VM resources on exit

**REPL Entry (`src/commands/repl.nim`):**
- Location: `src/commands/repl.nim`
- Triggers: `./gene repl` or no arguments
- Responsibilities:
  1. Create persistent VM instance
  2. Load readline/history support
  3. Read expressions from stdin in a loop
  4. Compile and execute each expression
  5. Display results

**File Execution (`src/commands/run.nim`):**
- Location: `src/commands/run.nim`
- Triggers: `./gene run file.gene`
- Responsibilities:
  1. Load source file
  2. Parse into AST
  3. Compile to bytecode
  4. Create new VM instance
  5. Execute bytecode and return exit code

**Module Loading (`src/gene/vm/module.nim`):**
- Location: `src/gene/vm/module.nim` (51K lines)
- Triggers: `(import "module.gene")` in Gene code
- Responsibilities:
  1. Resolve module paths (relative to current file, standard library)
  2. Parse and compile module source
  3. Create module namespace
  4. Execute module initialization code
  5. Cache compiled modules to avoid recompilation

## Error Handling

**Strategy:** Exception-based with three levels of error handling

**Compile-time errors:**
- ParseError, ParseEofError thrown during parsing
- Type errors during type checking (reported but continue)
- Compile errors during bytecode generation

**Runtime errors:**
- Nim exceptions (ValueError, not_allowed, etc.) propagate as Exception
- Exception objects (VkException) caught by try/catch expressions
- Caught in exception handler stack (`frame.exception_handlers`)
- Exception normalization in `vm/exceptions.nim`: Infers exception class from message

**Patterns:**
- `try-catch` expressions: `(try (risky_op) (catch e (handle e)))`
- Exception display with source traces in error messages
- Exception.instance field removed (PR e43d791)

## Cross-Cutting Concerns

**Logging:** 
- Approach: Per-module loggers registered with `src/gene/logging_core.nim`
- Loggers: "gene/parser", "gene/compiler", "gene/vm/exec", "gene/vm/dispatch", "genex/http"
- Controlled by: `src/gene/logging_config.nim` with hierarchical levels (Debug, Info, Warn, Error)
- Template: `log_message(level, logger_name, message)`

**Validation:** 
- Approach: Per-value-kind validation functions in `src/gene/types/runtime_types.nim`
- Functions: `validate_type()`, `validate_or_coerce_type()`, `is_compatible()`
- Used by: Type checker (compile-time), method dispatch (runtime)

**Authentication:** 
- Approach: Workspace-scoped access control in `src/genex/ai/workspace_policy.nim`
- Enforces: Secret redaction, workspace isolation in AI agent platform
- Used by: AI extension functions with API key management

---

*Architecture analysis: 2025-04-09*

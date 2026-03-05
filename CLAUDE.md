<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# Gene Agent Guide

These notes summarise the current VM implementation so future agents can orient quickly.  
Refer back to `CLAUDE.md` for the long-form deep dive when needed.

## Codebase Snapshot

- **Bytecode VM** in Nim (`src/gene/`) with stack frames, pooled scopes, and computed-goto dispatch (`src/gene/vm.nim`).
- **Gene IR (GIR)** (`src/gene/gir.nim`) persists compiled bytecode (`*.gir`) under `build/` for reuse.
- **Command infrastructure** (`src/gene/commands/`) exposes `run`, `eval`, `repl`, `parse`, and `compile`.
- **Reference interpreter** remains in `gene-new/` and is the behavioral oracle during parity work.

Key modules:
- `src/gene/parser.nim` — S-expression reader with macro dispatch table.
- `src/gene/compiler.nim` — emits instructions defined in `src/gene/types.nim`.
- `src/gene/vm.nim` — VM implementation

## Language Syntax Quick Look

```gene
# Comments start with #
(var x 10)                 # Variable declaration
(x = (+ x 1))              # Assignment
(fn add [a b] (+ a b))     # Function definition
(if (> x 5) "big" "small") # Conditional
(do expr1 expr2 expr3)     # Sequencing
(try
  (throw "boom")
catch *
  ($ex .message))          # Catch all exceptions with $ex
(async (println "hi"))     # Real async execution with event loop
{:a 1 :b [1 2 3]}          # Map literal with nested array
```

## Syntax Reminder (Do Not Deviate)

```gene
(if cond
  ...
else
  ...)

(a == b)
(x + y)

{^key "value"}
arr/0
obj/.method    # Preferred over (obj .method) for no-arg calls
```

## VM Architecture Highlights

- Stack-based VM with pooled frames (256-value stack per frame) and computed-goto dispatch (`{.computedGoto.}`).
- Scopes (`ScopeObj`) are manually managed structures allocated via `alloc0`; always initialise `members = newSeq[Value]()`.
- Compilation pipeline: parse S-expressions → build AST (`Gene` nodes) → emit `Instruction` seq defined in `src/gene/types.nim`.
- GIR serializer (`src/gene/gir.nim`) persists constants + instructions; cached under `build/` and reused by the CLI.
- Async uses real event loop integration: VM polls Nim's asyncdispatch every 100 instructions. Await blocks until the future completes.

## Instruction Cheatsheet

`InstructionKind` lives in `src/gene/types.nim` (see around `IkPushValue` onwards). Handy groups:
- **Stack**: `IkPushValue`, `IkPop`, `IkDup`, `IkSwap`.
- **Variables & Scopes**: `IkVar`, `IkVarResolve`, `IkVarAssign`, `IkScopeStart`, `IkScopeEnd`.
- **Control Flow**: `IkJump`, `IkJumpIfFalse`, `IkReturn`, `IkLoopStart`, `IkLoopEnd`.
- **Function/Macro**: `IkFunction`, `IkCall`, `IkCallerEval`.
- **Async**: `IkAsyncStart`, `IkAsyncEnd`, `IkAwait`.

When adding new instructions: extend the enum, teach the compiler (emit case), and handle execution in `vm.nim`.

## Method Dispatch Notes

- `IkCallMethod1` in `src/gene/vm.nim` directs dispatch:
  - `VkInstance` uses the class method tables.
  - `VkString` methods are provided by `App.app.string_class` (ensure new methods registered in `vm/core.nim`).
  - `VkFuture` and other special types have dedicated class objects (`future_class`, etc.).
- `$env`, `$program`, and `$args` are macro-powered helpers living in the global namespace (`gene/types.nim` initialises them).

## CLI & Tooling

- Build with `nimble build` (outputs `bin/gene`). `nimble speedy` enables release+native flags.
- `bin/gene run <file>` caches bytecode to `build/<path>.gir` unless `--no-gir-cache`.
- `bin/gene eval` accepts inline code or STDIN, with `--trace`, `--compile`, and formatter flags.
- `bin/gene compile` supports multiple output formats (`pretty`, `compact`, `bytecode`, `gir`) and `--emit-debug`.
- `bin/gene repl` starts an interactive shell; ensure `register_io_functions` runs before relying on `io/*`.

## Testing

- `nimble test` executes the curated Nim test matrix defined in `gene.nimble`.
- Individual Nim tests can be run with `nim c -r tests/test_X.nim`.
- `./testsuite/run_tests.sh` drives Gene source programs and expects `bin/gene` to exist.
- When adding language features, mirror coverage in both Nim tests and Gene test programs.

## Database Clients

Gene provides SQLite and PostgreSQL client support through the `genex/sqlite` and `genex/postgres` namespaces.

### API Overview

```gene
# Open connections
(var db (genex/sqlite/open "/path/to/db.sqlite"))
(var pg (genex/postgres/open "host=localhost port=5432 dbname=mydb user=postgres"))

# Query - returns results (SELECT)
(var rows (db .query "SELECT * FROM users WHERE active = ?" true))
# PostgreSQL uses $1, $2 for parameters
(var pg_rows (pg .query "SELECT * FROM users WHERE active = $1" true))

# Exec - executes without returning results (INSERT/UPDATE/DELETE)
(db .exec "INSERT INTO users (name, age) VALUES (?, ?)" "Alice" 30)

# PostgreSQL transactions
(pg .begin)
(pg .exec "UPDATE accounts SET balance = balance - $1 WHERE id = $2" 100 1)
(pg .exec "UPDATE accounts SET balance = balance + $1 WHERE id = $2" 100 2)
(pg .commit)
# or rollback: (pg .rollback)

# Close connection
(db .close)
```

### Parameter Syntax Differences

- **SQLite**: Uses `?` for parameters: `WHERE id = ?`
- **PostgreSQL**: Uses `$1`, `$2` for parameters: `WHERE id = $1`

### Result Format

Both clients return results as arrays of arrays:
```gene
[[id1 name1 age1] [id2 name2 age2] ...]
```

Column values are converted to Gene types: `VkString`, `VkInt`, `VkFloat`, `VkBool`, `NIL` (for NULL).

### Building Database Extensions

```bash
# Build extension modules
nimble buildext

# Output: build/libsqlite.dylib, build/libpostgres.dylib
```

## Known Hazards

- **Exception handling**: use `catch *`; naming the exception (`catch ex`) still panics on macOS.
- **String methods**: `IkCallMethod1` must dispatch to `App.app.string_class` for string-specific natives.
- **Value initialisation**: manually allocate (`alloc0`) structures; always set `members = newSeq[Value]()` for new scopes.
- **Environment helpers**: `$env`, `$program`, and `$args` rely on `set_program_args`; ensure command modules set them before evaluating code.

## Documentation Map

- `docs/architecture.md` — high-level VM and compiler overview.
- `docs/gir.md` — GIR format and serialization details.
- `docs/performance.md` — current fib(24) numbers (~3.8M calls/sec optimised) and optimisation backlog.
- `docs/IMPLEMENTATION_STATUS.md` — parity tracking vs. the interpreter (update when shipping new language features).
- `docs/implementation/*.md` — design notes for async, caller_eval, and current dev questions.

## 🚨 CRITICAL: Gene Syntax Reference for AI Agents

**AI AGENTS**: Before writing ANY Gene code, you MUST study the complete syntax reference in `examples/full.gene`. This file contains canonical, tested examples of ALL major Gene language features.

### How to Use This Reference

1. **First**: Read and internalize `examples/full.gene` - it's your primary syntax guide
2. **Reference**: Keep it open while writing Gene code to avoid syntax errors
3. **Test**: When uncertain, copy the canonical patterns from the reference

### Key Syntax Patterns to Memorize

```gene
# Comments start with #

# Variables & Assignment
(var x 10)                    # Declaration
(x = 20)                      # Assignment

# Arithmetic & logic operators are infix
(x + y)

# Functions
(fn add [a b] (a + b))        # Function with parameters
(fn hello [] (print "Hi"))    # No parameters

# Macros
(fn debug! [a]
  (println a "=" ($caller_eval a))
)

# Arrays & Maps
(var arr [1 2 3])             # Array
(var m {^key "value"})        # Map (use ^ prefix for keys)

# Classes
(class Point
  (ctor [x y]
    (/x = x)                  # Use / for property access
    (/y = y)
  )
  (method get_x _ /x)            # Method definition
)

# Method calls
(var p (new Point 3 4))
(p .get_x)                    # Regular method call
p/.get_x                      # Use /. for method call that doesn't take arguments, do not use ().

# Control flow
(if (x > 5) then              # then is optional
  ...
  "big" 
elif (x == 5)                 # elif means else if
  ...
  "equal"
else
  ...
  "small")

# Maps/Arrays access
arr/0                         # Array access
m/key                         # Map access
```

### Common Pitfalls to Avoid

- **NEVER** use JavaScript/C syntax `{}` `;`
- **ALWAYS** use parentheses `()` for expressions
- **Maps**: Use `^` prefix for keys: `{^name "Alice"}`
- **Arrays**: Use slash for access: `arr/0`
- **Classes**: Use `/` for properties, `/.` for methods

**STUDY `examples/full.gene` BEFORE WRITING GENE CODE!**

## Contribution Tips

- Align new behaviour with `gene-new/` unless intentionally diverging; port interpreter tests when possible.
- Maintain GIR compatibility when touching instruction encoding.
- Prefer adding new VM instructions to `InstructionKind` with corresponding compiler/VM changes together in one change.
- Keep new docs linked from `docs/README.md` to avoid stale references.

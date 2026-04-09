# Technology Stack

**Analysis Date:** 2026-04-09

## Languages

**Primary:**
- Nim 2.0.0+ - Core language implementation in `src/gene/` (106 .nim files)
  - Compiler: `src/gene/compiler.nim`
  - Parser: `src/gene/parser.nim`
  - VM: `src/gene/vm/` (26 .nim files)
  - Type system: `src/gene/types/` (14 .nim files)
  - Standard library: `src/gene/stdlib/` (16 .nim files)

**Secondary:**
- Gene (`*.gene`) - Language examples, testsuite programs, package manifests (`package.gene`, `examples/`, `testsuite/`)
- C - FFI bindings and integration:
  - Database: `db_connector` bindings in `src/genex/sqlite.nim`, `src/genex/postgres.nim`
  - HTTP: `src/genex/http.nim` (asynchttpserver wrapper)
  - WebSocket: `src/genex/websocket.nim` (RFC 6455 framing)
  - Crypto: OpenSSL bindings in `src/genex/ai/wrappers/openssl.nim`
  - C Extension API: `src/gene/extension/c_api.nim`
- Bash - Build and test tooling (`tools/`, scripts)
- YAML - CI/CD workflows

## Runtime

**Environment:**
- Nim 2.0+ compiler with ORC memory mode
- Native CLI executable: `bin/gene` (built from `src/gene.nim`)
- Stack-based bytecode VM (`src/gene/vm/exec.nim`)
- Event loop integration via Nim's `asyncdispatch` module
- Thread pool support: `src/gene/vm/thread.nim`

**Memory Management:**
- Memory mode: `--mm:orc` (ARC with cycle collector)
- Value representation: NaN-boxed 8-byte discriminated union (`src/gene/types/type_defs.nim:14`)
- Scope lifetime: Manual with ref-counting for async blocks
- Custom destructor hooks via `=copy`/`=destroy` (Nim 2.x)

**Package Manager:**
- Nimble (Nim package manager)
- Manifest: `gene.nimble`
- Dependencies: `db_connector >= 0.1.0` (only explicit external dependency)

## Frameworks

**Core Language Features:**
- **Parser** (`src/gene/parser.nim`) - S-expression to AST
- **Compiler** (`src/gene/compiler.nim`) - AST to bytecode
- **VM** (`src/gene/vm.nim`, `src/gene/vm/exec.nim`) - Bytecode execution with 256-value operand stacks
- **Type System** (`src/gene/types/`) - 100+ value types with pattern matching

**Runtime Capabilities:**
- **Async/Await** - `src/gene/vm/async.nim`, `src/gene/vm/async_exec.nim`
  - Futures with success/failure callbacks
  - Event loop polling (100ms intervals)
  - WebSocket client/server support
- **Object-Oriented** - `src/gene/types/classes.nim` (classes, methods, inheritance)
- **Functional** - First-class functions, closures, macros (`src/gene/compiler/`)
- **Aspect-Oriented** - Interceptions and advices (`src/gene/types/type_defs.nim:71-80`)
- **Pub/Sub** - Event subscriptions (`src/gene/vm/pubsub.nim`)
- **Generators** - Lazy evaluation with yield (`src/gene/vm/generator.nim`)
- **Exception Handling** - `catch *` syntax (`src/gene/vm/exceptions.nim`)

**Extension Libraries:**
- HTTP/WebSocket: `src/genex/http.nim` (client/server), `src/genex/websocket.nim`
- Database: `src/genex/sqlite.nim`, `src/genex/postgres.nim` (via db_connector)
- AI Platform: `src/genex/ai/` (22 files) - Slack, OpenAI, Anthropic integrations
- LLM: `src/genex/llm.nim` (llama.cpp runtime)
- Logging: `src/genex/logging.nim`
- HTML: `src/genex/html.nim`

**CLI & Commands:**
- Command framework: `src/commands/base.nim`
- Commands: run, eval, repl, help, parse, compile, gir, lsp, pipe, fmt, run_examples, deps, view, deser
- REPL: `src/gene/repl_input.nim`, `src/gene/repl_session.nim`

**Testing:**
- Unit tests: `tests/test_*.nim` (Nim-based, run individually)
- Integration tests: `tests/integration/test_*.nim` (organized by feature)
- Test discovery and execution: Manual via `nimble test` and `nimble testintegration`

**Build Tools:**
- Nimble tasks: standard, optimized (speedy), benchmarks, WASM, extensions
- Direct Nim compiler invocation for custom configurations

## Key Dependencies

**Critical (Package Manager):**
- `db_connector >= 0.1.0` - SQLite/PostgreSQL abstraction
  - Used by: `src/genex/sqlite.nim`, `src/genex/postgres.nim`, `src/genex/ai/memory_store.nim`
  - APIs: `db_connector/db_sqlite`, `db_connector/db_postgres`

**Standard Library (Nim):**
- `asyncdispatch` - Async/event loop runtime
- `tables`, `sets` - Collections
- `hashes` - Hashing support
- `strutils`, `strformat` - String processing
- `times`, `os` - System utilities
- `dynlib` (native only) - Dynamic library loading for extensions

**External Libraries:**
- **OpenSSL (libcrypto)** - Cryptography
  - Header location: `/opt/homebrew/opt/openssl@3/` (macOS)
  - Used by: Slack signature verification (`src/genex/ai/control_slack.nim`)
  - FFI wrapper: `src/genex/ai/wrappers/openssl.nim`

**Optional (Feature-Gated):**
- llama.cpp - LLM runtime (submodule, built via `buildllmamacpp` task)
  - Used when compiled with `-d:geneLLM`

## Configuration

**Environment Variables:**
- `GENE_PROFILE` - Build profile selection
  - `"native"` (default) - Native compilation
  - `"wasm-emscripten"` - Emscripten WebAssembly
  - `"wasm-wasi"` - WASI WebAssembly
  - Set in: `config.nims:6`

**Build Configuration Files:**
- `nim.cfg` - Nim compiler flags for release builds
  - Memory mode: `--mm:orc`
  - Optimization: `--opt:speed`
  - CPU: `--passC:"-march=native"`
  - SSL: `-d:ssl`
- `config.nims` - Profile-based compilation switches
  - Native: defines `gene_native`, enables threading
  - WASM: disables threading, sets target architecture

**Feature Flags (build-time defines):**
- `-d:gene_native` - Native compilation (default)
- `-d:gene_wasm` - WebAssembly mode
- `-d:gene_wasm_emscripten` - Emscripten backend
- `-d:gene_wasm_wasi` - WASI backend
- `-d:geneLLM` - LLM support with llama.cpp
- `-d:postgresTest` - PostgreSQL integration tests
- `-d:GENE_LLM_MOCK` - Mock LLM mode for testing
- `-d:ssl` - OpenSSL support (default)

## Platform Support

**Native Compilation:**
- Targets: x86_64, ARM64
- OS: macOS, Linux, Windows
- Features: Full (threading, dynamic loading, async)
- OpenSSL: System package or Homebrew `/opt/homebrew/opt/openssl@3/`

**WebAssembly (Emscripten):**
- Entry point: `src/gene_wasm.nim`
- Export: `_gene_eval` function, `memory`, `cwrap` runtime methods
- Restrictions: No threading, no file system, web environment only
- Build: Requires `emcc` (emsdk)

**WebAssembly (WASI):**
- Sandboxed system calls via WASI
- No threading
- Target: Serverless/edge computing environments

**Extension System:**
- Native: Dynamic library loading via `dynlib` (`.dylib`/`.so`/`.dll`)
- Built libraries (output to `build/`):
  - `libhttp` - HTTP server/client
  - `libsqlite` - SQLite database
  - `libpostgres` - PostgreSQL database
  - `libhtml` - HTML parsing
  - `liblogging` - Structured logging
  - `libtest` - Testing utilities
  - `libai` - AI platform (OpenAI, Anthropic, Slack)
  - `libllm` - LLM runtime
- C Extension API: `src/gene/extension/c_api.nim`

## Build Tasks

**Standard:**
```bash
nimble build              # Default release build
nimble test              # All unit tests
nimble testcore          # Parser/type core tests
nimble testintegration   # All integration tests (52+ test files)
nimble testapp           # Network/external integration tests
nimble testpostgres      # PostgreSQL integration tests
```

**Optimized:**
```bash
nimble speedy            # Native CPU optimization (-march=native -O3)
nimble bench             # Build + run benchmarks
```

**Specialized:**
```bash
nimble wasm              # WebAssembly (Emscripten, outputs web/gene_wasm.js)
nimble buildext          # Dynamic extension libraries
nimble buildcext         # C extension example
nimble buildllmamacpp    # LLM runtime dependencies
nimble buildwithllm      # Build with LLM support (-d:geneLLM)
```

**WASM Profile Example:**
```bash
export GENE_PROFILE=wasm-emscripten
# Install: git clone https://github.com/emscripten-core/emsdk.git && cd emsdk && ./emsdk install latest && ./emsdk activate latest
nimble wasm              # Outputs: web/gene_wasm.js
```

---

*Stack analysis: 2026-04-09*

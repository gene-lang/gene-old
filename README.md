# Gene Programming Language

Gene is a general-purpose, homoiconic language with a Lisp-like surface syntax.  
This repository hosts the bytecode virtual machine (VM) implementation written in Nim.  

## Repository Layout

- `src/gene.nim` — entry point for the VM executable  
- `src/gene/` — core compiler, VM, GIR, and command modules  
- `bin/` — build output from `nimble build` (`bin/gene`)  
- `build/` — cached Gene IR (`*.gir`) emitted by the compiler  
- `tests/` — Nim-based unit and integration tests for the VM  
- `testsuite/` — black-box Gene programs with an expectation harness  
- `examples/` — sample Gene source files  

## VM Status

See [`docs/feature-status.md`](docs/feature-status.md) for the public feature
status matrix and stable-core boundary.

- **Available today**
  - Bytecode compiler + stack-based VM with computed-goto dispatch
  - S-expression parser compatible with the reference interpreter
  - Macro system with unevaluated argument support
  - Basic class system (`class`, `new`, nested classes) and namespaces
  - Async I/O with event loop integration (`async`, `await`)
  - Actor-first concurrency through `gene/actor/*`
  - Command-line toolchain (`run`, `eval`, `repl`, `parse`, `compile`)
  - File I/O helpers via the `io` namespace (`io/read`, `io/write`, async variants)
- **In progress / known limitations**
  - Pattern matching beyond argument binders is still experimental
  - Many class features (constructors, method dispatch, inheritance) need more coverage
  - Module/import system and package management are not complete
  - ...

## Major Features

### The Gene Data Structure — The Heart of Gene

The Gene data structure is **unique and central** to the language. Unlike JSON or S-expressions, Gene combines three structural components into one unified type:

```gene
(type ^prop1 value1 ^prop2 value2 child1 child2 child3)
```

| Component | Description | Example |
|-----------|-------------|---------|
| **Type** | The first element, identifying what kind of data this is. <br>Type can be any Gene data. | `if`, `fn`, <br>`(fn f [a b] (+ a b))` |
| **Properties** | Key-value pairs (prefixed with `^`). <br>Keys are strings. Values can be any Gene data. | `^name "Alice"`, `^age 30` |
| **Children** | Positional elements after the type. <br>Children can be any Gene data. | `child1 child2 child3` |

This unified structure enables:
- **Homoiconicity**: Code and data share the same representation
- **Macros**: Transform code as data before evaluation
- **Self-describing data**: Type information is always present
- **Flexible DSLs**: Build domain-specific languages naturally

**Example - Data as Code:**
```gene
# This is data:
(Person ^name "Alice" ^age 30)

# This is code (same structure!):
(class Person < Object
  ^final true

  (ctor [name age]
    (/name = name)
    (/age = age))

  (method greet []
    (print "Hello, my name is " /name)))
```

### Other Key Features

| Feature | Description |
|---------|-------------|
| **Lisp-like Syntax** | S-expression based, but with Gene's unique type/props/children structure |
| **Homoiconic** | Code is data, data is code — enabling powerful metaprogramming |
| **Macro System** | Transform code at compile-time with full access to the AST |
| **Class System** | OOP with classes, inheritance, constructors, and methods |
| **Async/Await** | Real async I/O with event loop for concurrent programming |
| **NaN-boxed Values** | Efficient 8-byte value representation for performance |

## Building

```bash
# Clone the repository
git clone https://github.com/gene-language/gene
cd gene

# Build the VM (produces bin/gene)
nimble build

# Optimised build (native flags, release mode)
nimble speedy

# Direct Nim invocation (places the binary in ./bin/gene by default)
nim c -o:bin/gene src/gene.nim
```

### WASM Build (Emscripten)

```bash
nimble wasm
```

This produces:
- `web/gene_wasm.js`
- `web/gene_wasm.wasm`

WASM mode exports `gene_eval(code: cstring): cstring` and uses host ABI wrappers for time/random/file effects.

Current wasm limitations are explicit runtime errors with stable code `GENE.WASM.UNSUPPORTED` for:
- actor/native worker-backed concurrency
- dynamic native extension loading
- process/shell execution
- file-backed module loading and directory/delete filesystem operations

See `docs/wasm.md` for details.

## Local LLM Runtime (llama.cpp)

Gene ships with a `genex/llm` namespace that can call local GGUF models through [llama.cpp](https://github.com/ggerganov/llama.cpp). The runtime is optional — you can stay on the built-in mock backend by compiling with `-d:GENE_LLM_MOCK` — but if you want real inference:

1. Fetch the submodule and its dependencies:
   ```bash
   git submodule update --init --recursive tools/llama.cpp
   ```
2. Build the native libraries (runs CMake inside `build/llama/` and compiles the shim to `libgene_llm.a`):
   ```bash
   tools/build_llama_runtime.sh            # set GENE_LLAMA_METAL=1 or GENE_LLAMA_CUDA=1 for GPU variants
   ```
   The script leaves `build/llama/libllama.a` and `build/llama/libgene_llm.a` in place so the Nim build/linker can pick them up automatically.
3. Rebuild Gene as usual (`nimble build`, `nimble speedy`, etc.). No extra flags are needed once the libraries exist.

Usage tips:
- `examples/llm/mock_completion.gene` looks for `GENE_LLM_MODEL=/path/to/model.gguf` and falls back to `tests/fixtures/llm/mock-model.gguf` (a tiny placeholder) when the env var is absent.
- To force the mock backend without rebuilding the native shim, compile with `nimble build -d:GENE_LLM_MOCK`.

## Command-Line Tool

All commands are dispatched through `bin/gene <command> [options]`:

- `run <file>` — parse, compile (with GIR caching), and execute a `.gene` program  
  - respects cached IR in `build/` unless `--no-gir-cache` is supplied  
- `eval <code>` — evaluate inline Gene code or read from `stdin`  
  - supports debug output (`--debug`), instruction tracing, CSV/Gene formatting  
- `repl` — interactive REPL with multi-line input and helpful prompts  
- `parse <file | code>` — parse Gene source and print the AST representation  
- `compile` — compile to bytecode or `.gir` on disk (`-f pretty|compact|bytecode|gir`, `-o`, `--emit-debug`)

Run `bin/gene help` for the complete command list and examples.

## Examples

```gene
# Hello World
(print "Hello, World!")

# Define a function
(fn add [a b]
  (+ a b))

# Fibonacci
(fn fib [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

(print "fib(10) =" (fib 10))
```

See `examples/` for additional programs and CLI demonstrations.

## Testing

```bash
# Run the curated Nim test suite (see gene.nimble)
nimble test

# Execute an individual Nim test
nim c -r tests/test_parser.nim

# Run the Gene program suite (requires bin/gene)
./testsuite/run_tests.sh
```

The Nim tests exercise compiler/VM internals, while the shell suite runs real Gene code end-to-end.

## Documentation

The documentation index in `docs/README.md` lists the current architecture notes, design discussions, and implementation diaries. Highlights include:
- `docs/feature-status.md` — public feature-status matrix and stable-core boundary
- `docs/architecture.md` — VM and compiler design overview
- `docs/gir.md` — Gene Intermediate Representation format
- `docs/performance.md` — benchmark data and optimisation roadmap

## Performance

Latest fib(24) benchmarks (2025 measurements) place the optimised VM around **3.8M function calls/sec** on macOS ARM64. See `docs/performance.md` for methodology, historical comparisons, and profiling insights.

## License

[MIT License](LICENSE)

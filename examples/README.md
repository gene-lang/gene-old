# Gene Examples

This directory contains example Gene programs demonstrating various language features.

## Basic Examples

- `hello_world.gene` - Simple Hello World program
- `print.gene` - Various print operations
- `fib.gene` - Fibonacci sequence calculation
- `cmd_args.gene` - Command line argument handling via `$program`/`$args`
- `env.gene` - Environment variable access

## Data Structures

- `json.gene` - JSON parsing and manipulation
- `datetime.gene` - Date and time operations

## Control Flow and Functions

- `benchmark.gene` - Performance benchmarking example
- `fib_benchmark.gene` - Fibonacci benchmark
- `simple_test.gene` - Simple test framework
- `sample_typed.gene` - Gradual typing walkthrough sample (typed + untyped code)
- `how-types-work.md` - End-to-end explanation of parse/typecheck/compile/GIR/runtime behavior for `sample_typed.gene`

## I/O and Files

- `io.gene` - File I/O operations
- `pipe.gene` - Unix pipe operations
- `parser.gene` - Parsing examples

## Web and Network

- `http.gene` - HTTP client example
- `http_server.gene` - HTTP server implementation
- `http_async.gene` - Asynchronous HTTP operations
- `http_websocket.gene` - WebSocket example
- `http_todo_app.gene` - Complete TODO app with HTTP API
- `ai/openai_chat.gene` - Uses `genex/ai` to call an OpenAI-compatible chat endpoint; reads `OPENAI_API_KEY`, `OPENAI_API_BASE`, and `OPENAI_API_MODEL` (defaults to `https://api.openai.com/v1` + built-in model when unset)

## Database

- `sqlite.gene` - SQLite database operations
- `mysql.gene` - MySQL database operations

## Advanced Features

- `async.gene`, `async2.gene` - Asynchronous programming
- `thread.gene` - Multi-threading example
- `repl.gene` - REPL implementation
- `repl-on-demand.gene`, `repl-on-error.gene` - Debug REPL examples

## UI and Graphics

- `html.gene`, `html2.gene` - HTML generation
- `svg.gene` - SVG graphics generation

## Platform-Specific

- `alfred_workflow.gene` - macOS Alfred workflow
- `chrome_tabs.gene` - Chrome tab manipulation

## Running Examples

To run any example:

```bash
./gene run examples/hello_world.gene
```

Or if the example has a shebang line:

```bash
./examples/hello_world.gene
```

## Adding New Examples

When adding new examples:
1. Use descriptive filenames
2. Add a comment at the top explaining what the example demonstrates
3. Keep examples focused on demonstrating specific features
4. Update this README with a description

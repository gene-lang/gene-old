# Gene Examples

This directory contains a curated set of example Gene programs.
The goal is to keep examples small, current, and runnable against the codebase as it exists today.

## Core Language

- `hello_world.gene` - Simple Hello World program
- `print.gene` - `print`, `println`, and stderr output
- `cmd_args.gene` - Command line argument handling via `$args`
- `env.gene` - Environment variable access via `$env` and `set_env`
- `fib.gene` - Simple recursive function example
- `oop.gene` - Classes, fields, inheritance, and `super`
- `sample_typed.gene` - Gradual typing walkthrough sample
- `full.gene` - Canonical language syntax reference
- `how-types-work.md` - Walkthrough for `sample_typed.gene`

## Data and Stdlib

- `json.gene` - JSON parsing and manipulation
- `datetime.gene` - Date and DateTime values
- `io.gene` - File I/O operations
- `process_management.gene` - `system/Process` spawning and control
- `sqlite.gene` - SQLite queries using `genex/sqlite`

## Concurrency

- `async.gene` - Futures, callbacks, and `await`
- `http_actor_server.gene` - Actor-backed background work behind an HTTP front door

## Experimental

- `interception.gene` - Explicit runtime interception for selected class methods and standalone callables using `(interceptor ...)`, `(fn-interceptor ...)`, direct callable application, and slash toggles. Historical broad AOP material remains compatibility/migration context; start here for current experiments.

## Extensions and Web

- `html.gene` - HTML generation with `genex/html/tags`
- `http_server.gene` - Minimal HTTP server using `genex/http`
- `http_actor_server.gene` - Actor-backed HTTP job server using `genex/http` plus a small Gene actor pool
- `http_ab_demo.gene` - Slow concurrent HTTP demo for `ab` benchmarking
- `http_ab_actor_demo.gene` - Actor-backed end-to-end `ab` benchmark using 10 Gene actor workers behind the HTTP front door
- `openai_chat.gene` - OpenAI-compatible chat example using `genex/ai`

## Shell Integration

- `pipe.gene` - Reading piped stdin

## Running Examples

To run a self-contained example:

```bash
./bin/gene run examples/hello_world.gene
```

Run the lightweight curated batch:

```bash
./examples/run_examples.sh
```

Some examples depend on extension modules:

```bash
nimble buildext
```

That is required for `html.gene`, `http_server.gene`, `http_actor_server.gene`, `http_ab_demo.gene`, `http_ab_actor_demo.gene`, `sqlite.gene`, and `openai_chat.gene`.

`http_server.gene`, `http_actor_server.gene`, `http_ab_demo.gene`, and `http_ab_actor_demo.gene` are long-running by design. `openai_chat.gene` also requires `OPENAI_API_KEY`.

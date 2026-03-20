# Story 2: GeneClaw CLI Mode

> **Status:** Design sketch (pseudocode). API names and signatures reflect the
> current codebase as of 2026-03-19 but some primitives (noted below) do not
> yet exist in the Gene runtime and must be implemented first.

## Goal

Add a command-line interactive mode to GeneClaw that reads user messages from stdin and writes responses to stdout, using a simple text protocol with prompts as synchronization points. This enables test automation via the Process API (Story 1).

## Motivation

- **Test automation** — programmatically send messages and verify responses without HTTP server, threading, or polling
- **Local development** — quick REPL for testing agent behavior
- **Pipe-friendly** — works with shell scripts, `expect`, and the Gene Process API
- **Simpler than REST** — no concurrency concerns, just sequential stdin/stdout

## CLI Protocol

### Format

```
User: what time is it?
Assistant: The current time is 2026-03-18 20:30 EDT.
User: _
```

- `User: ` prompt signals "ready for input" — this is the synchronization point
- Agent reads everything after `User: ` until newline
- Agent processes the message (may call tools)
- Agent writes `Assistant: <response>` (may be multi-line)
- Agent writes next `User: ` prompt when done
- Tool calls optionally shown between User and Assistant lines

### Tool call visibility (optional, configurable)

```
User: what time is it?
[Tool: get_time] → "2026-03-18 20:30:00 EDT"
Assistant: The current time is 2026-03-18 20:30 EDT.
User: _
```

### Multi-line responses

```
User: list 3 colors
Assistant: Here are 3 colors:
  1. Red
  2. Blue
  3. Green
User: _
```

The `User: ` prompt at column 0 is the only reliable delimiter. Responses can contain any text.

### Exit

- `Ctrl-C` (SIGINT) — graceful shutdown
- `Ctrl-D` (EOF on stdin) — graceful shutdown
- Typing `exit` or `quit` — graceful shutdown

## Usage

```bash
# Interactive REPL
gene run src/main.gene --cli

# With persistent session
gene run src/main.gene --cli --session my-test

# One-shot mode (pipe — exits after EOF on stdin)
echo "what time is it?" | gene run src/main.gene --cli

# With specific home directory (set via env var, not CLI flag —
# GENECLAW_HOME is bound at import time in home_store.gene)
GENECLAW_HOME=/path/to/geneclaw_home gene run src/main.gene --cli
```

## Workspace semantics

CLI mode now uses two filesystem roots on purpose:

- **Read-only inspection tools** (`read_file`, `list_files`, `grep`) resolve relative paths from the process launch directory. If you start CLI mode from `example-projects/geneclaw`, `README.md` means `example-projects/geneclaw/README.md`.
- **Mutating tools** (`write_file`, `edit_file`, `patch_file`, `delete_file`) stay confined to `GENECLAW_HOME/tmp`.
- **Shell/browser helpers** also start from managed roots under `GENECLAW_HOME`, not the launch directory.

This split lets the agent inspect the repo you launched it from while keeping file creation and edits inside the managed scratch area.

## Implementation

### Runtime primitives needed

The following Gene-level functions are **not yet implemented** in the runtime.
They currently exist only on the Nim side (`repl_session.nim`, `lsp/server.nim`).
These must be exposed as stdlib builtins before this sketch works:

| Primitive | Purpose | Nim equivalent |
|-----------|---------|----------------|
| `(flush stdout)` | Flush stdout buffer | `stdout.flushFile()` in `repl_session.nim:99` |
| `(readline)` | Read a line from stdin, return `nil` on EOF | `input_file.readLine(input)` in `repl_session.nim:102` |
| `(on_signal "INT" handler)` | Register signal handler | Not yet implemented |

### Entry point (main.gene)

Uses `$parse_cmd_args` (the repo's standard pattern — `$args` is an array,
not an option map).

CLI mode must be **mutually exclusive** with the normal server boot path.
The current startup sequence in `main.gene` (lines ~280+) unconditionally runs
`init_db`, `init_tools`, `start_scheduler`, and `start_server`. The `--cli`
branch must either `(exit 0)` after the CLI loop returns, or the existing boot
path must be wrapped in an `else` block.

```gene
# Parse CLI arguments using the standard $parse_cmd_args pattern
# (see examples/parse_cmd_args.gene)
# NOTE: This must run BEFORE imports that trigger side effects.
# However, GENECLAW_HOME is bound at import time (home_store.gene:7
# reads $env GENECLAW_HOME), so --home cannot be a CLI flag — use
# the GENECLAW_HOME env var instead.
($parse_cmd_args
  [
    program
    (option ^^toggle --cli)
    (option --session)
    (option ^^toggle --show-tools)
    (argument ^!optional file)
  ]
  $args
)

(if cli
  # CLI mode: skip server/scheduler startup entirely
  (init_db)
  (init_tools)
  (start_cli session show_tools)
  (exit 0)
else
  # Normal server boot path (existing code)
  # ... init_db, init_tools, start_scheduler, start_server ...
)
```

### CLI loop (cli.gene)

```gene
(fn start_cli [session_name show_tools]
  # Build a workspace-scoped session ID matching the app's model.
  # CLI uses workspace "default", channel "cli".
  # --session <name> maps to thread_id, giving: "default:cli:<name>"
  # No --session gives: "default:cli"
  (var workspace_id "default")
  (var thread_id (session_name || ""))

  # Print startup banner (stderr so it doesn't pollute the protocol)
  (eprintln "GeneClaw CLI mode. Type 'exit' to quit.")

  # Register SIGINT handler for clean shutdown
  # ⚠️ REQUIRES: on_signal (not yet in Gene runtime)
  (on_signal "INT" (fn []
    (eprintln "\nInterrupted.")
    (exit 0)
  ))

  # Main loop
  (loop
    # Read input BEFORE printing prompt when stdin is a pipe.
    # This avoids printing a dangling "User: " after the last response.
    # ⚠️ REQUIRES: flush, readline (not yet in Gene runtime)
    (print "User: ")
    (flush stdout)

    (var input (readline))

    # Handle exit conditions
    (if (input == nil) (break))              # EOF (Ctrl-D / pipe exhausted)
    (if (input == "exit") (break))
    (if (input == "quit") (break))
    (var trimmed (input .trim))
    (if trimmed/.empty? (continue))

    # Run agent through the standard pipeline (reuses existing logic).
    # thread_id carries --session so each named session gets its own
    # conversation history via build_session_id.
    (var result (run_agent_envelope {
      ^workspace_id workspace_id
      ^user_id      "cli-user"
      ^channel_id   "cli"
      ^thread_id    thread_id
      ^text         trimmed
      ^attachments  []
    }))

    # Print response
    (println #"Assistant: #{result/response}")
  )

  (eprintln "Bye.")
)
```

> **Note on --show-tools:** The flag is parsed but not yet wired. Real-time
> tool call display requires a callback/event hook inside `execute_agent_steps`
> (which currently runs tools synchronously and only returns the final result).
> This is deferred to a follow-up story. Remove `--show-tools` from the CLI
> if you don't plan to implement the hook soon — exposing a non-functional
> flag is worse than not offering it.

> **Note on one-shot / pipe mode:** When stdin is a pipe, `readline` returns
> `nil` after the last line, which breaks the loop. The final `User: ` prompt
> will still be printed before EOF is detected. To suppress it, the loop could
> check `(stdin .isatty?)` and skip the prompt for non-TTY input — but
> `isatty` is another runtime primitive that doesn't exist yet. For v1, the
> trailing prompt in pipe mode is acceptable.

> **Known issue: stdout logging noise:** Current GeneClaw logging writes to
> stdout, and the default config is verbose. For v1, CLI automation should
> treat `User: ` as the only synchronization token and tolerate extra stdout
> lines outside the prompt/response flow. The critical constraint is that once
> `User: ` is printed, nothing else should be written to stdout until that
> input line is consumed; otherwise prompt-based automation can desync. A later
> improvement can disable CLI logging or redirect logs to stderr/file.

### Key design decision: reuse `run_agent_envelope`, don't fork it

The CLI adapter calls `run_agent_envelope` from `agent.gene` directly.
This ensures CLI mode gets the same behavior as the HTTP path:

- Repeated-invalid-tool detection and abort
- `max_steps` / `max_tool_calls` limits from CONFIG
- Attachment ingestion (empty for CLI v1, but the path exists)
- Follow-up prompt construction via `build_tool_followup_text`
- Proper session memory recording (`session_append_memory` with workspace_id)
- Session persistence (`save_session`)

**Do not** reimplement the agent loop in the CLI adapter.

### Session model

CLI sessions use the same workspace-scoped model as the rest of the app.
The `--session` flag maps to `thread_id` in the `run_agent_envelope` call,
which flows through `build_session_id` in `agent.gene:49`:

```
--session flag    →  thread_id  →  session_id (via build_session_id)
(not provided)       ""            "default:cli"
my-test              "my-test"     "default:cli:my-test"
```

`run_agent_envelope` handles the full lifecycle internally:
`build_session_id` → `load_session(id, workspace_id)` →
`session_append_memory(workspace_id, ...)` → `save_session(id, session)`.
The CLI loop does not need to call any session APIs directly.

## Test Automation (using Story 1 Process API)

Uses `system/Process/start` (the actual API — see `system.nim:413`,
`test_stdlib_process.nim`).

String containment uses `.contain` or `.include?` (registered at
`strings.nim:609`), not `.contains`.

```gene
# test_geneclaw_cli.gene — automated test script

(fn test_basic_conversation []
  (var gc (system/Process/start "gene" "run" "src/main.gene" "--cli" "--session" "test-basic"))

  # Wait for first prompt
  (gc .read_until "User: " ^timeout 10)

  # Test basic response
  (gc .write_line "what time is it?")
  (var response (gc .read_until "User: " ^timeout 30))
  (assert (response .include? "Assistant:"))

  # Clean exit
  (gc .signal "INT")
  (gc .wait)
  (println "PASS: basic conversation")
)

(fn test_session_persistence []
  # Session 1: store information
  (var gc1 (system/Process/start "gene" "run" "src/main.gene" "--cli" "--session" "test-persist"))
  (gc1 .read_until "User: ")
  (gc1 .write_line "remember: the project deadline is March 30")
  (gc1 .read_until "User: ")
  (gc1 .signal "INT")
  (gc1 .wait)

  # Session 2: recall information (same session ID)
  (var gc2 (system/Process/start "gene" "run" "src/main.gene" "--cli" "--session" "test-persist"))
  (gc2 .read_until "User: ")
  (gc2 .write_line "when is the project deadline?")
  (var response (gc2 .read_until "User: " ^timeout 30))
  (assert (response .include? "March 30"))
  (gc2 .signal "INT")
  (gc2 .wait)
  (println "PASS: session persistence")
)

(fn test_memory_tools []
  (var gc (system/Process/start "gene" "run" "src/main.gene" "--cli" "--session" "test-memory"))
  (gc .read_until "User: ")

  # Ask agent to store in long-term memory
  (gc .write_line "remember in long-term memory: my favorite language is Gene")
  (gc .read_until "User: " ^timeout 30)

  # Search memory
  (gc .write_line "search your memory for my favorite language")
  (var response (gc .read_until "User: " ^timeout 30))
  (assert (response .include? "Gene"))

  (gc .signal "INT")
  (gc .wait)
  (println "PASS: memory tools")
)

# Run all tests
(test_basic_conversation)
(test_session_persistence)
(test_memory_tools)
(println "All tests passed.")
```

## Dependencies

- **Story 1 (Process API)** — required for test automation, not for CLI mode itself
- **Runtime primitives** — `flush`, `readline`, `on_signal` must be exposed as Gene builtins; `isatty` is nice-to-have for clean pipe mode
- **Existing agent pipeline** — reuse `run_agent_envelope` from `agent.gene`
- **Existing session store** — accessed indirectly via `run_agent_envelope` (no direct calls needed)
- **`GENECLAW_HOME` env var** — must be set before launch (not a CLI flag; bound at import time in `home_store.gene:7`)

## Out of Scope (v1)

- Multi-line user input (heredoc syntax)
- Streaming responses (character by character)
- Rich terminal UI (colors, progress bars)
- Concurrent sessions in one CLI process
- Real-time tool call display (needs event hook in `execute_agent_steps`)

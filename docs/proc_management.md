# Process Management API — Spawn and Control Child Processes

## Goal

Extend the existing `system` namespace with a `Process` class that provides piped access to stdin/stdout/stderr of child processes, enabling programmatic control of interactive CLI programs.

## Motivation

GeneClaw needs to run child processes (including itself in CLI mode) and communicate via pipes for test automation and orchestration. Gene currently has `system/exec` (capture output) and `system/shell` (run command, return output + exit code), but no way to interact with a running process's streams.

## Platform

Unix/macOS only for v1. Windows support is out of scope.

## API Design

### Namespace

Extend `system` — there's already `system/exec`, `system/shell`, and a stub `system/Process` class in `src/gene/stdlib/system.nim`. The new API fills out that stub.

### Spawn a process

```gene
(var proc (system/Process/start "gene" "run" "src/main.gene" "--cli"))

# With options
(var proc (system/Process/start "gene" "run" "src/main.gene"
  ^cwd "/path/to/workdir"
  ^env {^KEY "value"}
  ^stderr_to_stdout true          # merge stderr into stdout (avoids deadlocks)
))
```

Returns a Process instance with piped stdin/stdout/stderr.

**`^stderr_to_stdout true`** — redirects child's stderr to stdout. Recommended for most use cases to avoid the deadlock scenario where stderr fills its pipe buffer while the parent only drains stdout.

### Write to stdin

```gene
(proc .write "hello\n")
(proc .write_line "hello")   # auto-appends newline
```

### Read from stdout

All blocking reads require `^timeout` (seconds). Returns `nil` on timeout.

```gene
# Read one line (blocks until newline or timeout)
(var line (proc .read_line ^timeout 10))

# Read until a pattern appears in output
# Returns all text up to and including the pattern
# The delimiter IS consumed (unambiguous — caller knows exactly where the boundary is)
(var output (proc .read_until "User: " ^timeout 30))

# Read all available output (non-blocking, returns "" if nothing ready)
(var output (proc .read_available))
```

### Read from stderr

Only available when `^stderr_to_stdout` is false (the default).

```gene
(var err (proc .read_stderr ^timeout 5))   # read available stderr, with timeout
```

**Warning:** Reading stdout and stderr separately risks deadlocks if the child writes to both. For interactive use cases, prefer `^stderr_to_stdout true`.

### Process control

```gene
# Check if process is still running
(proc .alive?)         # returns true/false (this is a method, not a property)

# Send signal (Unix only)
(proc .signal "INT")      # SIGINT (Ctrl-C)
(proc .signal "TERM")     # SIGTERM
(proc .signal "KILL")     # SIGKILL

# Close stdin (signal EOF to child) — does NOT kill the child
(proc .close_stdin)

# Wait for process to exit (blocks, requires timeout)
(var exit_code (proc .wait ^timeout 30))   # returns exit code, or nil on timeout

# Explicit shutdown — full state machine:
#
#   close_stdin
#       ↓
#   wait(timeout / 2)
#       ↓
#   alive? ──no──→ return exit_code
#       │
#      yes
#       ↓
#   signal TERM
#       ↓
#   wait(timeout / 2)
#       ↓
#   alive? ──no──→ return exit_code
#       │
#      yes
#       ↓
#   signal KILL
#       ↓
#   wait(1s, hard ceiling)
#       ↓
#   return exit_code (or nil if KILL didn't reap — should not happen on Unix)
#
(var exit_code (proc .shutdown ^timeout 10))
```

### Properties

```gene
proc/pid          # Process ID (int)
proc/exit_code    # Exit code (int after exit, nil if still running)
```

### Lifecycle contract

- **Explicit shutdown is the only contract.** The caller must call `.shutdown` or `.signal` + `.wait` when done.
- **No implicit cleanup.** If a Process instance is GC'd while the child is still running, the child is NOT killed and no guarantees are made about warnings or logging. This matches Gene's existing native-resource pattern (explicit close, no finalizer-side reporting).
- **Orphaned children are the caller's fault.** Use `try/finally` or equivalent to ensure `.shutdown` runs.

## Implementation Notes

### Nim layer (`src/gene/stdlib/system.nim`)

- Use Nim's `osproc.startProcess` with `poUsePath` and piped streams (no `poParentStreams`)
- For `^stderr_to_stdout`: use `poStdErrToStdOut` option
- Pipe access via `Process.inputStream` (stdin), `outputStream` (stdout), `errorStream` (stderr)
- `read_until` needs a buffered reader that accumulates output and scans for the delimiter pattern
- All blocking reads use `poll`/`select` with deadline for timeout enforcement
- `read_available` uses non-blocking peek (`readDataStr` with poll timeout 0)

### Gene VM layer

- Fill out the existing `init_process_class()` stub in `system.nim`
- Process handle stored as native data on the class instance (similar to how HTTP/WebSocket handles work)
- `start` registered as a static method via `def_static_method` on the Process class (accessed as `system/Process/start`)
- Instance methods (dot-call): `.write`, `.write_line`, `.read_line`, `.read_until`, `.read_available`, `.read_stderr`, `.signal`, `.close_stdin`, `.wait`, `.shutdown`, `.alive?`
- Properties (slash-access): `proc/pid`, `proc/exit_code`

### VM interaction

Blocking reads (`.read_line`, `.read_until`, `.wait`) block the current VM execution path. This means:

- In the main VM thread, async futures and thread replies won't progress during a blocking read (the VM's instruction-loop polling drives those).
- **Mitigation for v1:** All blocking operations require `^timeout`. Callers should use reasonable timeouts (seconds, not minutes).
- **Future improvement:** Make process I/O async-aware by integrating with the VM's poll loop, yielding control between poll intervals. This is out of scope for v1 but the timeout contract ensures the API doesn't change when async support is added.

### Buffering

Child stdout may be fully-buffered when connected to a pipe (not a TTY). The child process must explicitly flush after writing prompts/output. For GeneClaw CLI mode, this is handled by flushing stdout after each `User: ` prompt. No PTY support in v1.

## Test Cases

```gene
# Basic spawn and read
(var proc (system/Process/start "echo" "hello"))
(var output (proc .read_line ^timeout 5))
(assert (output == "hello"))
(proc .wait ^timeout 5)
(assert (proc/exit_code == 0))

# Interactive process
(var proc (system/Process/start "cat" ^stderr_to_stdout true))
(proc .write_line "test")
(var line (proc .read_line ^timeout 5))
(assert (line == "test"))
(proc .close_stdin)
(proc .wait ^timeout 5)

# Timeout behavior
(var proc (system/Process/start "sleep" "60"))
(var result (proc .read_until "never" ^timeout 1))
(assert (result == nil))   # timed out
(proc .signal "KILL")
(proc .wait ^timeout 5)

# Exit code
(var proc (system/Process/start "sh" "-c" "exit 42"))
(proc .wait ^timeout 5)
(assert (proc/exit_code == 42))

# Shutdown — graceful (child exits on EOF)
(var proc (system/Process/start "cat"))
(var code (proc .shutdown ^timeout 5))
(assert (code == 0))

# Shutdown — TERM branch (child ignores EOF, gets killed)
(var proc (system/Process/start "sh" "-c" "trap '' HUP; sleep 60"))
(var code (proc .shutdown ^timeout 4))   # close_stdin won't stop it → TERM after 2s
(assert (code != nil))

# Shutdown — KILL fallback (child traps TERM)
(var proc (system/Process/start "sh" "-c" "trap '' TERM; sleep 60"))
(var code (proc .shutdown ^timeout 4))   # TERM ignored → KILL after 2s
(assert (code != nil))

# Merged stderr — verify both streams appear
(var proc (system/Process/start "sh" "-c" "echo err >&2; echo out" ^stderr_to_stdout true))
(var line1 (proc .read_line ^timeout 5))
(var line2 (proc .read_line ^timeout 5))
(var combined #"#{line1} #{line2}")
(assert (combined .contain "err"))
(assert (combined .contain "out"))
(proc .wait ^timeout 5)

# read_until consumes the delimiter
(var proc (system/Process/start "sh" "-c" "printf 'helloXworldX'"))
(var first (proc .read_until "X" ^timeout 5))
(assert (first == "helloX"))              # delimiter included
(var second (proc .read_until "X" ^timeout 5))
(assert (second == "worldX"))             # next read starts after consumed delimiter
(proc .wait ^timeout 5)
```

## Out of Scope (v1)

- PTY/terminal emulation
- Process groups / job control
- Async/callback-based reading (integrate with VM poll loop)
- Multiplexed simultaneous stdout + stderr reading
- Windows support

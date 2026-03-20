# `gene deser` / `gene deserialize` Command

## Purpose

Deserialize Gene serialization text back into runtime objects and print the result. This is useful for inspecting `.gene` state files, debugging serialized objects, and verifying round-trip serialization.

The command runs in a full VM environment (like `gene eval`) so it can resolve class references, namespace paths, and other runtime dependencies from the current project.

## Usage

```bash
# From a file
gene deser state.gene

# From stdin (pipe)
echo '(gene/serialization (Instance (ClassRef "myapp/models" "User") {^name "Alice" ^age 30}))' | gene deser

# From a string argument
gene deser -e '(gene/serialization {^key "value"})'

# Pretty print (default)
gene deser state.gene

# Compact output
gene deser --format compact state.gene

# Gene syntax output
gene deser --gene state.gene

# With project context (loads package.gene dependencies)
gene deser --project . session_state.gene
```

## Options

| Flag | Description |
|------|-------------|
| `-e`, `--eval <text>` | Deserialize the given text string |
| `--format <fmt>` | Output format: `pretty` (default), `compact`, `gene` |
| `--gene` | Shorthand for `--format gene` |
| `--project <path>` | Load project context before deserializing (resolves class refs) |
| `-d`, `--debug` | Enable debug logging |
| `-p`, `--print-type` | Print the type/kind of the deserialized value |
| `-h`, `--help` | Show help message |

## Input Sources (priority order)

1. **`-e` flag**: Deserialize inline text
2. **File argument**: Read and deserialize file contents
3. **Stdin pipe**: Read from piped input

## Examples

### Inspect a GeneClaw session state file
```bash
gene deser home/sessions/default%3Acli%3Amain/memory/v42D735E5DEEC.gene
```

### Pipe from another command
```bash
cat home/state/system_prompt.gene | gene deser
```

### Deserialize with project context
When the serialized data references project-specific classes:
```bash
cd my-project
gene deser --project . saved_state.gene
```

### Check the type of a serialized value
```bash
gene deser -p -e '(gene/serialization [1 2 3])'
# Output:
# [1 2 3]
# Type: Array
```

## How It Works

1. Reads serialized Gene text from the specified source
2. Parses it using the Gene parser (`read_all`)
3. Initializes the VM with stdlib (same as `gene eval`)
4. Optionally loads project dependencies via `--project`
5. Calls `serdes.deserialize()` to reconstruct runtime objects
6. Prints the result in the requested format

## Serialization Format

Gene serialization wraps values in `(gene/serialization ...)`:

```gene
# Primitives pass through
(gene/serialization 42)
(gene/serialization "hello")
(gene/serialization [1 2 3])

# Class instances use Instance/ClassRef
(gene/serialization
  (Instance
    (ClassRef "module/path" "ClassName")
    {^prop1 "value1" ^prop2 42}))

# References to named objects
(gene/serialization (NamespaceRef "module/path" "name"))
(gene/serialization (FunctionRef "module/path" "fn_name"))
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Parse error or deserialization failure |
| 2 | File not found or I/O error |

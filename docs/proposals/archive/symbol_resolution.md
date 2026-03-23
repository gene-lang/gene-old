# Symbol Resolution in Gene

This document describes how symbols are resolved in the Gene language.

## Symbol Categories

### 1. Keywords

Keywords are reserved identifiers handled directly by the parser/compiler. They cannot be redefined.

| Keyword | Description |
|---------|-------------|
| `if` | Conditional expression |
| `elif` | Else-if branch |
| `else` | Else branch |
| `fn` | Function definition |
| `class` | Class definition |
| `var` | Variable declaration |
| `loop` | Loop construct |
| `break` | Break out of loop |
| `continue` | Continue to next iteration |
| `return` | Return from function |
| `try` | Exception handling |
| `catch` | Catch exception |
| `finally` | Finally block |
| `throw` | Throw exception |
| `import` | Import module |
| `ns` | Namespace definition |
| `macro` | Macro definition |
| `new` | Object instantiation |
| `nil` | Nil value |
| `void` | Void value |
| `true` | Boolean true |
| `false` | Boolean false |

**Note:** Only `nil` is the nil literal. `NIL` is treated as a normal symbol.

### 2. Built-in Global Namespaces

These are predefined namespaces accessible from anywhere:

| Namespace | Description |
|-----------|-------------|
| `gene` | Core Gene runtime namespace |
| `genex` | Gene extensions namespace (HTTP, SQLite, LLM, etc.) |

**Usage:**
```gene
(gene/Object)           # Access Object class
(genex/llm/load_model)  # Access LLM extension
(genex/sqlite/open)     # Access SQLite extension
```

### 3. Global Variables

Global variables are accessed using the `$` prefix. There is no `global/` namespace for globals.

```gene
$x            # Read global
($x = 10)     # Set global
```

## Resolution Order

When the VM encounters a symbol, it resolves in this order:

1. **Keywords & Built-in Variables** - Reserved identifiers (`if`, `fn`, `nil`, `true`, etc.) - these are mutually exclusive and cannot be redefined
2. **Local scope** - Variables defined in current scope (`var x = ...`)
3. **Enclosing scopes** - Lexically enclosing function/block scopes
4. **Namespace scope** - Current namespace (`ns` block)
5. **Parent namespace** - Enclosing namespaces up to root

**Note:** The following require explicit prefixes and are NOT part of automatic resolution:
- Global variables: Must use `$x`
- Gene namespace: Must use `gene/...`
- Genex namespace: Must use `genex/...`

## Module / Namespace / Class Bodies

Bindings inside module, namespace, and class bodies are **lexical by default**.
Use an explicit namespace write to export members:

```gene
(var local_value 1)     # local binding
(var /exported 2)       # exported to current namespace

(fn local_fn [x] x)
(fn /exported_fn [x] x)
```

## Namespace Prefixes

| Prefix | Namespace | Example |
|--------|-----------|---------|
| `$` | Global | `$config` |
| `gene/` | Gene core | `gene/Object` |
| `genex/` | Extensions | `genex/http/start_server` |

## Namespace Imports

The `import` form binds a namespace alias into the current namespace. If no alias is provided, the last path segment is used.

```gene
(import genex/llm)        # Binds llm
(import genex/llm:llm2)   # Binds llm2
```

## Special Variables

| Variable | Description |
|----------|-------------|
| `self` | Current object instance (in methods) |
| `$ex` | Current exception (in `catch` blocks) |
| `$ex/message` | Exception message |
| `$env` | Environment variables |

## Examples

```gene
# Keywords
(if (x > 0)
  (gene/println "positive")
else
  (gene/println "not positive")
)

# Local variable
(var name "Gene")

# Global variable
($debug_mode = true)

# Accessing built-in namespaces
(gene/Array)              # Array class from gene namespace
(genex/llm/load_model)    # LLM function from genex namespace

# Environment variable
($env .get "HOME" "/tmp")
```

## Future Improvements

### Global Variable Access Control

Global variable assignment `($x = 1)` should be compiled to a special function that:
1. Validates write permissions
2. Rejects writes to read-only system globals

### Threading Semantics

| Variable Type | Scope | Description |
|---------------|-------|-------------|
| `$x` | **Global (shared)** | Visible to all threads |
| `$ex` | **Thread-local** | Each thread has its own exception context |

> **Note:** `$ex` using `$` prefix but being thread-local is a known design inconsistency.
> This is a pragmatic choice for now until a cleaner solution is designed (e.g., separate prefix for thread-locals).

**Read-only System Globals:**

| Variable | Description | Writability |
|----------|-------------|-------------|
| `$ex` | Current exception | Thread-local, runtime-only |
| `$env` | Environment access | Read-only |

**Proposed Compilation:**

```gene
# User writes:
($x = 1)

# Compiles to:
(global_set "x" 1)  # global_set is a built-in native function
```

### Concurrent Access to Globals

When multiple threads access shared global variables, explicit locking is required:

```gene
# Safe concurrent access
($shared_data = {}) # atomic read/write
(synchronized ^on "$shared_data"
  ($shared_data/x = 1)
)
```

**Rules:**
- Direct reads/writes to `$name` are atomic
- Nested mutations (`$data/x = 1`) require `synchronized` on that global child
- `^on` names a direct child of global (for example `"$shared_data"`), not a path
- Omitting `^on` locks all globals and is discouraged
- Locking one global child does not block access to other globals
- User is responsible for proper synchronization

### Other Improvements

- [ ] Improve error messages for undefined symbols

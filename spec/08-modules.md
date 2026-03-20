# 8. Modules & Namespaces

## 8.1 Namespaces

```gene
(ns Geometry
  (class /Shape2D
    (method area _ 0))

  (class /Rect < Shape2D
    (ctor [w h] (/w = w) (/h = h))
    (method area _ (/w * /h))))
```

- Members prefixed with `/` are exported from the namespace
- Access via path: `Geometry/Rect`, `Geometry/Shape2D`
- Namespaces can be nested

## 8.2 Imports

### Basic Import
```gene
(import a b from "path/to/module")
```

### Aliased Import
```gene
(import n/f:my_fn from "path/to/module")
# n/f in the module is bound as my_fn locally
```

### Group Import
```gene
(import n/[one:x two:y] from "path/to/module")
# n/one bound as x, n/two bound as y
```

### Namespace Import
```gene
(import genex/http)
# Binds the genex/http namespace into scope
```

## 8.3 File Modules

Each `.gene` file is a module. Exported names (prefixed with `/`) are available to importers.

Module paths are relative to the importing file:
```gene
(import helper from "./utils/helper")
(import config from "../config")
```

## 8.4 Built-in Namespaces

| Namespace      | Description                     |
|----------------|---------------------------------|
| `gene/`        | Core runtime (Object, Array, String classes) |
| `gene/io`      | File I/O operations             |
| `gene/json`    | JSON serialization              |
| `gene/time`    | Time functions                  |
| `gene/thread`  | Threading                       |
| `gene/base64`  | Base64 encoding/decoding        |
| `genex/`       | Extensions namespace            |
| `genex/http`   | HTTP client/server              |
| `genex/sqlite` | SQLite database client          |
| `genex/postgres`| PostgreSQL database client     |

## 8.5 Global Variables

Special variables available everywhere:

| Variable    | Description                              |
|-------------|------------------------------------------|
| `$env`      | Environment variables (read-only map)    |
| `$program`  | Current program path                     |
| `$args`     | Command-line arguments                   |
| `$ex`       | Current exception in catch block         |

```gene
$env/HOME              # => "/Users/gcao"
($env/MISSING || "default")   # Fallback for missing
```

---

## Potential Improvements

- **Circular imports**: Behavior on circular module dependencies is undefined. Should either be detected with a clear error or handled gracefully.
- **Selective re-export**: No way to re-export imported names from a module. Must manually wrap.
- **Module-level initialization order**: When modules have side effects, import order matters but is not explicitly controlled.
- **Package system**: No package manager or dependency resolution. Files must be referenced by path.
- **Namespace merging**: Cannot extend or augment an existing namespace from another file. Each `ns` block is self-contained.
- **Private module members**: No explicit private members — anything not `/`-prefixed is effectively private, but this is convention, not enforced at import time.
- **Dynamic imports**: No `(import ... if ...)` or `(require ...)` for conditional/runtime loading.
- **Import wildcards**: `(import * from "module")` imports all exports, which can pollute the local scope with unexpected names.
- **Versioned modules**: No version specification in imports. All modules are resolved by file path only.

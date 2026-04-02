# 8. Modules & Namespaces

## 8.1 Namespaces

```gene
(ns geometry
  (class /Shape2D
    (method area [] 0))

  (class /Rect < Shape2D
    (ctor [w h] (/w = w) (/h = h))
    (method area [] (/w * /h))))
```

- Members prefixed with `/` are exported from the namespace
- Access via path: `geometry/Rect`, `geometry/Shape2D`
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

## 8.4 Built-in Namespaces and Core Paths

| Path            | Description                                |
|-----------------|--------------------------------------------|
| `gene/`         | Core runtime root namespace                |
| `gene/io`       | File I/O helpers                           |
| `gene/json`     | JSON serialization                         |
| `gene/Future`   | Future class for async values              |
| `gene/Thread`   | Thread class for message-passing threads   |
| `system/`       | Process and environment helpers            |
| `genex/`        | Extensions namespace                       |
| `genex/http`    | HTTP client/server                         |
| `genex/sqlite`  | SQLite database client                     |
| `genex/postgres`| PostgreSQL database client                 |

The `gene/` root namespace also exposes helpers such as `gene/now`, `gene/today`, `gene/yesterday`, `gene/tomorrow`, `gene/base64_encode`, `gene/base64_decode`, and `gene/sleep_async`.

## 8.5 Global Variables

Special variables available everywhere:

| Variable    | Description                              |
|-------------|------------------------------------------|
| `$app`      | The application object                   |
| `$env`      | Environment variables (read-only map)    |
| `$cwd`      | Current working directory path           |
| `$program`  | Current program path                     |
| `$args`     | Command-line arguments                   |
| `$ex`       | Current exception in catch block         |

```gene
$env/HOME                     # => "/Users/gcao"
($env/MISSING || "default")   # Fallback for missing
```

---

## Potential Improvements

- **Selective re-export**: No way to re-export imported names from a module. Must manually wrap.
- **Module-level initialization order**: When modules have side effects, import order matters but is not explicitly controlled.
- **Package registry/version workflows**: `gene deps` provides package/dependency tooling, but imports themselves are still source-oriented rather than version-pinned at the language level.
- **Namespace merging**: Cannot extend or augment an existing namespace from another file. Each `ns` block is self-contained.
- **Private module members**: No explicit private members — anything not `/`-prefixed is effectively private, but this is convention, not enforced at import time.
- **Dynamic imports**: No `(import ... if ...)` or `(require ...)` for conditional/runtime loading.
- **Import wildcards**: `(import * from "module")` imports all exports, which can pollute the local scope with unexpected names.
- **Versioned modules**: No version specification in import syntax. Version resolution lives in package tooling rather than in the import form itself.

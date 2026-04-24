# Package + Module Support in the Gene VM

This document describes the current local-first package/module MVP implemented
by the Nim VM. It is intentionally smaller than a registry package manager:
local manifests, local/path dependencies, lockfiles, and deterministic imports
are implemented; hosted registries and full version solving are future work.

## Local package MVP

A Gene package is a directory tree with a `package.gene` file at its root. The
runtime and `gene deps` both parse that manifest through the shared parser in
`src/gene/vm/package_manifest.nim`.

Supported MVP manifest fields:

```gene
^name "x/app"
^version "0.1.0"
^license "MIT"
^homepage "https://example.invalid/app"
^source-dir "src"
^main-module "main"
^test-dir "tests"
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/lib")
]
```

Defaults:

- `^source-dir`: `src`
- `^main-module`: `index`
- `^test-dir`: `tests`
- absent `^version` and `^license`: `nil` through Package methods

Manifests may be written as flat key/value pairs or as a single map:

```gene
{
  ^name "x/app"
  ^version "0.1.0"
  ^source-dir "src"
  ^main-module "main"
  ^test-dir "tests"
  ^dependencies []
}
```

## Package metadata

The current package is available as `$pkg`. The application package is available
as `$app/.pkg`.

Supported Package methods:

- `$pkg/.name`
- `$pkg/.version`
- `$pkg/.dir`
- `$pkg/.source_dir`
- `$pkg/.main_module`
- `$pkg/.test_dir`

The same methods work through `$app/.pkg`, for example
`$app/.pkg/.name` and `$app/.pkg/.version`.

CLI package context is supported by `run`, `eval`, `repl`, and other command
paths that use `src/commands/package_context.nim`. These commands preserve the
launch working directory; `--pkg` selects package metadata and package-relative
path resolution without changing `cwd`.

## Dependencies and lockfiles

`gene deps` is the canonical local lockfile writer for the MVP.

Common commands:

```sh
gene deps install --root .
gene deps update --root .
gene deps verify --root .
gene deps gc --root .
gene deps clean --root .
```

Local/path dependencies use `$dep` inside `^dependencies`:

```gene
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/lib")
]
```

Dependency names must be `<parent>/<pkg>`, such as `x/lib` or `org/tool`.
The MVP supports:

- `^path` for a local package directory
- `^subdir` for a package subdirectory inside the owner package
- `^git` with at most one of `^commit`, `^tag`, or `^branch`

The local lockfile is `package.gene.lock`. It records:

- `^lock_version`
- `^root_dependencies`
- materialized package nodes under `^packages`
- each node's relative `.gene/deps/...` directory
- source metadata
- SHA-256 content hash
- dependency edges for transitive package imports

Example shape:

```gene
{
  ^lock_version 1
  ^root_dependencies {
    ^x/lib "x/lib@1.0.0"
  }
  ^packages {
    ^x/lib@1.0.0 {
      ^name "x/lib"
      ^resolved "1.0.0"
      ^node_id "x/lib@1.0.0"
      ^dir ".gene/deps/x/lib/1.0.0"
      ^source {^type "path" ^path "./vendor/lib"}
      ^sha256 "..."
      ^singleton false
      ^dependencies {}
    }
  }
}
```

`gene deps verify` validates lockfile version, materialized directories, and
content hashes. `gene deps install` reuses an existing lockfile by verifying it
instead of re-resolving dependencies.

## Package-aware imports

Package-qualified imports use either `^pkg` or `of "<pkg>"`:

```gene
(import value from "index" ^pkg "x/lib")
(import value from "feature" ^pkg "x/lib")
```

Resolution behavior:

1. Direct importer-relative modules are checked first for normal imports.
2. For package-qualified imports, `package.gene.lock` is authoritative when it
   maps the importer package node to a dependency node.
3. Package entrypoint imports from `"index"` honor manifest `^main-module`
   before falling back to `index`.
4. Package module bases include manifest `^source-dir` before hard-coded
   `src`, then retain `lib` and `build` fallbacks.
5. Package-qualified imports enforce package boundaries so `../` paths cannot
   escape the resolved package root.
6. When no lockfile edge applies, the resolver falls back to explicit `^path`,
   dependency registry overrides, materialized `.gene/deps`, `GENE_PACKAGE_PATH`,
   and sibling search.

## Native modules

Native imports are still trusted-local only:

```gene
(import upcase from "my_lib/libindex.dylib" ^native true)
```

The module resolver can also auto-detect a matching native library under
`build/` for a resolved `.gene` module. Native trust, signing, checksum policy,
and ABI lifecycle are not part of the local package MVP.

## Out of scope

The following remain future work:

- registry or hosted package installation
- remote index discovery
- complete semver solving and compatibility policy
- native extension signing or trust policy
- lockfile format compatibility beyond `^lock_version 1`
- package publishing workflows
- distributed package caches

The stable current contract is local and deterministic: parse `package.gene`,
materialize local/path dependencies with `gene deps`, verify `package.gene.lock`,
and resolve imports through manifest and lockfile data.

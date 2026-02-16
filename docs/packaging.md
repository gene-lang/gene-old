# Packaging and Dependency Installation (Proposed)

## Status

- State: Draft proposal
- Owner: package manager implementation workstream
- Approval target: after spec review and lockfile schema sign-off
- Related current behavior: `docs/package_support.md`

## Table of Contents

1. Goals and Non-Goals
2. Package Naming
3. Filesystem Layout
4. Dependency Declaration in `package.gene`
5. Version and Ref Semantics
6. Lockfile (`package.gene.lock`)
7. Install and Update Behavior
8. Native Dependency Compilation
9. Module Loading Resolution
10. Security and Reproducibility
11. Operations (`deps gc`, offline installs)
12. Error Examples
13. Future Work

## 1. Goals and Non-Goals

Goals:

- Reproducible dependency installation per project.
- Git-first package sources with `commit`, `tag`, or `branch` refs.
- Deterministic transitive dependency graph pinned in a lockfile.
- Native dependencies compiled during install.
- Dependencies stored under project-local `.gene/deps` (no symlinks).

Non-Goals (initial):

- Hosted binary registry/CDN.
- Cross-compilation for every target in v1.
- Sandboxed build execution in v1.

## 2. Package Naming

Package names use slash-separated namespace format:

- `<parent>/<pkg>`
- Example: `x/http`

Rules:

- At least 2 segments.
- `parent` is the first segment of package name.
- Allowed characters and reserved namespaces follow package-system rules already defined in `docs/package_support.md`.

## 3. Filesystem Layout

All resolved dependencies, including child dependencies, are materialized inside the project:

- `<project>/.gene/deps/<parent>/<pkg>/<commit_or_version>/`

Examples:

- `.gene/deps/x/http/1.4.2/`
- `.gene/deps/x/fastjson/sha-7a5f3db8/`

Other install-time paths:

- `<project>/.gene/tmp/` for download/build staging.
- `<project>/package.gene.lock` for resolved graph.

No symlink indirection is used for dependency directories.

Rationale:

- Project-local dependencies avoid symlink portability issues across platforms.
- Project-local dependencies make CI and repository migration behavior explicit and self-contained.

## 4. Dependency Declaration in `package.gene`

Dependencies remain declared in `^dependencies` using `($dep ...)`.

Supported fields:

- Positional 1: package name (for example `"x/http"`).
- Positional 2: version constraint expression.
- `^path`: local path dependency.
- `^git`: Git remote URL.
- `^commit`: exact commit SHA.
- `^tag`: Git tag.
- `^branch`: Git branch.
- `^subdir`: local subdirectory under current package root containing dependency source.
- `^native`: boolean.
- `^native-build`: explicit list of build commands.

Package-level metadata used by dependency solver:

- `^globals`: list of process-global symbols the package defines/owns.
- `^singleton`: optional boolean override indicating process-wide single-version requirement.

`^subdir` materialization rule:

- `^subdir` is always resolved relative to the current package root.
- `^subdir` cannot be combined with `^git`.
- `^subdir` must remain inside current package root (no parent traversal escape).
- Installer materializes dependency contents from `<current_package_root>/<subdir>` into `.gene/deps/...`.
- Lockfile `^dir` always points to the materialized package root used by loader.
- Lockfile `^source` records local source information for subdir-backed dependencies.

Example global-state declarations:

```gene
^name "x/message-queue"
^globals ["MESSAGE_QUEUE"]
^singleton true
```

Conflict example:

- If `x/a` requires `x/message-queue@1.0.0` and `x/b` requires `x/message-queue@2.0.0`, install fails because `x/message-queue` is singleton/global-state.

Ref rules:

- At most one of `^commit`, `^tag`, `^branch`.
- Multiple ref selectors are an error.
- `^subdir` with `^git` is an error.

Git URL formats:

- `https://github.com/org/repo.git`
- `ssh://git@github.com/org/repo.git`
- `git@github.com:org/repo.git`

## 5. Version and Ref Semantics

Version constraints use semver semantics:

- Exact: `1.2.3`
- Compatible range: `^1.4.0`
- Patch range: `~1.4.0`
- Comparator ranges: `>=1.0.0`, `>1.0.0`, `<=2.0.0`, `<2.0.0`
- Wildcard: `*`

Resolution precedence:

- `^commit` pins exactly to that commit.
- `^tag` resolves to commit and lockfile stores both tag and resolved commit.
- `^branch` resolves latest visible commit and lockfile stores both branch and resolved commit.

Version derivation for Git refs:

- If positional version is provided, that value is used as the resolved version string in lockfile.
- If positional version is omitted and tag matches `v?MAJOR.MINOR.PATCH`, the semver value is derived from the tag.
- If positional version is omitted and tag is non-semver (for example `release-2026-02`), install fails and requires explicit positional version.
- Branch-based dependencies without explicit positional version use `sha-<short_commit>` as resolved id in lockfile.

Dependency graph rules (v1):

- A package node cannot resolve two different versions of the same direct dependency name.
- Different subgraphs may resolve different versions of the same package name.
- If a package declares process-global state (`^globals` non-empty or `^singleton true`), only one resolved version may exist across the full application graph.
- If a singleton/global-state package is requested at conflicting versions, install fails with a global-state conflict diagnostic.
- No "newest wins" implicit override.

## 6. Lockfile (`package.gene.lock`)

Lockfile path:

- `<project>/package.gene.lock`

Lockfile format:

- Gene map format.
- Top-level includes lock version, direct root dependency map, and full resolved package node map.

Lock version compatibility:

- Reader validates `^lock_version` before resolution.
- Unsupported lock versions fail with a clear error and upgrade guidance.
- Example guidance: `Lockfile version 2 is not supported by this Gene build. Upgrade Gene or regenerate lockfile with gene deps update.`

Root dependency note:

- `^root_dependencies` contains only direct dependencies declared by the current package.
- Transitive dependencies are represented only in `^packages` and linked via per-node `^dependencies`.

Required lock fields per dependency node:

- package name.
- node id (`<name>@<resolved>`).
- resolved version or commit id.
- source type (`git` or `path`).
- source descriptor (`url`, `path`, `tag`, `branch`, `commit`; optional `subdir` for local subdir-backed sources only).
- resolved commit SHA when source is Git.
- content hash using SHA-256.
- resolved directory path under `.gene/deps`.
- dependency map of child dependency names to child node ids.
- singleton/global-state marker used by resolver checks.

Example shape:

```gene
{
  ^lock_version 1
  ^root_dependencies {
    ^x/http "x/http@1.4.2"
    ^x/sql "x/sql@2.0.0"
  }
  ^packages {
    ^x/http@1.4.2 {
      ^name "x/http"
      ^resolved "1.4.2"
      ^node_id "x/http@1.4.2"
      ^dir ".gene/deps/x/http/1.4.2"
      ^source {^type "git" ^url "https://github.com/gene-lang/http.git" ^tag "v1.4.2" ^commit "abc123..."}
      ^sha256 "..."
      ^singleton false
      ^dependencies {^x/core "x/core@1.9.0"}
    }
    ^x/sql@2.0.0 {
      ^name "x/sql"
      ^resolved "2.0.0"
      ^node_id "x/sql@2.0.0"
      ^dir ".gene/deps/x/sql/2.0.0"
      ^source {^type "git" ^url "https://github.com/gene-lang/sql.git" ^tag "v2.0.0" ^commit "def456..."}
      ^sha256 "..."
      ^singleton false
      ^dependencies {^x/core "x/core@2.3.1"}
    }
    ^x/core@1.9.0 {
      ^name "x/core"
      ^resolved "1.9.0"
      ^node_id "x/core@1.9.0"
      ^dir ".gene/deps/x/core/1.9.0"
      ^source {^type "git" ^url "https://github.com/gene-lang/core.git" ^tag "v1.9.0" ^commit "ghi789..."}
      ^sha256 "..."
      ^singleton false
      ^dependencies {}
    }
    ^x/core@2.3.1 {
      ^name "x/core"
      ^resolved "2.3.1"
      ^node_id "x/core@2.3.1"
      ^dir ".gene/deps/x/core/2.3.1"
      ^source {^type "git" ^url "https://github.com/gene-lang/core.git" ^tag "v2.3.1" ^commit "jkl012..."}
      ^sha256 "..."
      ^singleton false
      ^dependencies {}
    }
  }
}
```

`^path` dependency lock behavior:

- `path` stays as declared relative/absolute path.
- Lockfile records SHA-256 of current source tree snapshot.
- Hash scope for `^path` snapshot:
  - Recursive hash over sorted relative file paths and file contents.
  - Exclude `.git/`, `.gene/`, and `build/` directories by default.
  - Exclude lockfile files (`package.gene.lock`) from snapshot.
- `path` dependencies are treated as floating; install compares hash and reports drift.
- Drift severity on `gene deps install`: warning (install continues).
- Teams that require strict reproducibility should avoid `^path` in release workflows.

## 7. Install and Update Behavior

Install command:

- `gene deps install`

First install behavior:

- If `package.gene.lock` does not exist, install performs a fresh resolve and writes a new lockfile.
- If `package.gene.lock` exists, install follows the lockfile graph and verifies hashes unless an update command is requested.

Install algorithm:

1. Read `package.gene`.
2. Resolve direct dependencies.
   - For `^subdir`, resolve from current package root only.
3. Resolve transitive dependencies.
4. Detect circular dependency edges in the package graph.
   - Current policy: reject cycles with an explicit cycle path diagnostic.
5. Solve graph with package-scoped versioning:
   - one version per dependency name per package node.
   - allow different versions in different subgraphs.
   - enforce singleton/global-state constraint across full graph.
6. Materialize each node under `.gene/deps/<parent>/<pkg>/<commit_or_version>/`.
7. Build native dependencies (if any) after source materialization.
8. Write `package.gene.lock`.

Atomicity and failure recovery:

- Fetch/build in `.gene/tmp`.
- Move into final `.gene/deps/...` only on success.
- On failure, temp artifacts are cleaned and partial target directory is not committed.

Update command:

- `gene deps update [name]`

Update behavior:

- Without name: re-resolve all dependencies to latest versions allowed by constraints.
- With name: re-resolve named dependency and affected subgraph only.
- Always rewrites `package.gene.lock`.
- For `^path` dependencies, update re-hashes current local source and updates lockfile hash metadata (no network resolution).

Offline behavior:

- If all required resolved nodes already exist in `.gene/deps` and match lockfile hashes, install succeeds offline.
- If required node is missing and network is unavailable, install fails with missing-artifact error.

## 8. Native Dependency Compilation

Native dependencies are compiled at install time.

Prerequisites when native dependency exists:

- `nim` in `PATH`.
- C toolchain in `PATH`.
- Gene source checkout available locally.

Native declaration rules:

- If `^native true`, `^native-build` is required.
- Missing `^native-build` for native dependency is an error.

Trust model:

- Native build execution requires explicit opt-in via `gene deps install --allow-native`.
- Without opt-in, resolver may fetch native dependencies but must not execute build commands.

Build environment variables:

- `GENE_SOURCE_DIR`
- `GENE_BIN`
- `GENE_PACKAGE_DIR`

Build outputs:

- Native artifacts are written under each dependency's own `build/` directory.
- macOS example: `.gene/deps/x/http/1.4.2/build/libhttp.dylib`
- Linux example: `.gene/deps/x/http/1.4.2/build/libhttp.so`
- Windows example: `.gene/deps/x/http/1.4.2/build/http.dll`

Rebuild behavior:

- If lockfile node hash and build marker match existing artifact, skip rebuild.
- If source hash or toolchain signature changed, rebuild.

Toolchain signature intent:

- Include OS/arch, `nim --version`, C compiler id/version, and hash of `^native-build` command list.

## 9. Module Loading Resolution

Module loading order is:

1. Current package modules.
2. Resolved dependency package directory from `package.gene.lock` and `.gene/deps`, using the importer package node's dependency map.

Dependency module lookup uses lockfile-resolved node ids, not live network or floating refs.

This allows two siblings to load different versions of the same dependency when permitted by the solver rules.

Worked example:

- If `x/http@1.4.2` imports `x/core`, loader reads node `x/http@1.4.2`, finds dependency mapping `x/core -> x/core@1.9.0`, then loads from `.gene/deps/x/core/1.9.0/`.
- If sibling `x/sql@2.0.0` imports `x/core`, loader may map it to `x/core@2.3.1` and load from `.gene/deps/x/core/2.3.1/`.

## 10. Security and Reproducibility

- Lockfile must pin resolved commit for Git dependencies.
- Lockfile hashes use SHA-256.
- Lockfile/source mismatch fails install unless explicit update command is requested.
- Unknown or malformed ref selectors fail fast.
- Unknown native build commands are never auto-generated by installer.

## 11. Operations (`deps gc`, Offline, Cleanup)

Proposed maintenance commands:

- `gene deps gc`: remove unreferenced directories from `.gene/deps` not present in current lockfile.
- `gene deps clean`: clear `.gene/tmp` staging artifacts.
- `gene deps verify`: read-only integrity check that validates lockfile graph and hashes against `.gene/deps` without mutating files.

These commands are safe for project-local storage and keep repository cache growth bounded.

`.gitignore` recommendation:

- Add `.gene/deps/`
- Add `.gene/tmp/`
- Keep `package.gene.lock` committed as the source of reproducible dependency state.

## 12. Error Examples

- Multiple ref selectors:
  - `Dependency x/http cannot specify more than one of ^commit, ^tag, ^branch`
- Invalid source combination:
  - `Dependency x/http cannot combine ^subdir with ^git`
- Unknown package ref target:
  - `Failed to resolve x/http: tag 'v1.4.2' not found in https://github.com/gene-lang/http.git`
- Global-state version conflict:
  - `Global-state conflict: x/message-queue requested as 1.0.0 and 2.0.0`
- Circular dependency:
  - `Dependency cycle detected: x/a -> x/b -> x/a`
- Native toolchain missing:
  - `Native dependency x/sqlite requires nim in PATH`
- Native build blocked without opt-in:
  - `Native build blocked for x/sqlite: rerun with --allow-native`
- Offline missing artifact:
  - `Offline install failed: missing .gene/deps/x/http/1.4.2`
- Unsupported lock version:
  - `Lockfile version 2 is not supported by this Gene build. Upgrade Gene or regenerate lockfile with gene deps update.`

## 13. Future Work

- Central package index for name-to-Git discovery.
- Optional shared global cache for cross-project deduplication.
- Sandboxed native build execution.
- Prebuilt native artifacts with signature verification.

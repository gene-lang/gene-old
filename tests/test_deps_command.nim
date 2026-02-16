import std/[os, strutils, tempfiles, unittest]

import commands/deps as deps_command

proc write_manifest(path: string, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

suite "Deps CLI":
  test "install and verify local path dependency":
    let root = createTempDir("gene_deps_test_", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let dep_root = root / "vendor" / "lib"
    write_manifest(dep_root / "package.gene", """
^name "x/lib"
^version "1.2.3"
^dependencies []
""")
    createDir(dep_root / "src")
    writeFile(dep_root / "src" / "index.gene", "(fn value [] 123)")

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/lib")
]
""")

    let install_result = deps_command.handle("deps", @["install", "--root", root])
    check install_result.success
    check fileExists(root / "package.gene.lock")
    check dirExists(root / ".gene" / "deps" / "x" / "lib" / "1.2.3")

    let verify_result = deps_command.handle("deps", @["verify", "--root", root])
    check verify_result.success

  test "path dependency drift reports warning":
    let root = createTempDir("gene_deps_drift_", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let dep_root = root / "vendor" / "lib"
    write_manifest(dep_root / "package.gene", """
^name "x/lib"
^version "1.0.0"
^dependencies []
""")
    createDir(dep_root / "src")
    writeFile(dep_root / "src" / "index.gene", "(fn value [] 1)")

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/lib")
]
""")

    let first = deps_command.handle("deps", @["install", "--root", root])
    check first.success

    writeFile(dep_root / "src" / "index.gene", "(fn value [] 2)")
    let second = deps_command.handle("deps", @["update", "--root", root])
    check second.success
    check second.output.contains("Path dependency drift")

  test "reject invalid ^subdir with ^git combination":
    let root = createTempDir("gene_deps_subdir_git_", "")
    defer:
      if dirExists(root):
        removeDir(root)

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^git "https://example.com/repo.git" ^subdir "packages/lib")
]
""")

    let result = deps_command.handle("deps", @["install", "--root", root])
    check not result.success
    check result.error.contains("cannot combine ^subdir with ^git")

  test "reject multiple git ref selectors":
    let root = createTempDir("gene_deps_multi_ref_", "")
    defer:
      if dirExists(root):
        removeDir(root)

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^git "https://example.com/repo.git" ^tag "v1.0.0" ^branch "main")
]
""")

    let result = deps_command.handle("deps", @["install", "--root", root])
    check not result.success
    check result.error.contains("at most one of ^commit, ^tag, ^branch")

  test "install uses existing lockfile instead of re-resolving":
    let root = createTempDir("gene_deps_lock_mode_", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let dep_root = root / "vendor" / "lib"
    write_manifest(dep_root / "package.gene", """
^name "x/lib"
^version "1.0.0"
^dependencies []
""")
    createDir(dep_root / "src")
    writeFile(dep_root / "src" / "index.gene", "(fn value [] 1)")

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/lib")
]
""")

    let first = deps_command.handle("deps", @["install", "--root", root])
    check first.success

    write_manifest(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/lib" "*" ^path "./vendor/missing")
]
""")

    let second = deps_command.handle("deps", @["install", "--root", root])
    check second.success
    check second.output.contains("mode: lockfile")

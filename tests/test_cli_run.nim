import unittest, os, streams
import std/tempfiles

import gene/gir
import commands/run as run_command

suite "Run CLI":
  test "run falls back to source when cached GIR is unreadable":
    let source_path = absolutePath("tmp/run_cli_fallback.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(var x 42)\nx")

    let gir_path = get_gir_path(source_path, "build")
    createDir(parentDir(gir_path))
    writeFile(gir_path, "broken-gir")

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let result = run_command.handle("run", @[source_path])
    check result.success

  test "run invalidates stale GIR version caches and recompiles":
    let source_path = absolutePath("tmp/run_cli_version_invalidation.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(var x 7)\nx")

    let gir_path = get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let first = run_command.handle("run", @[source_path])
    check first.success
    check fileExists(gir_path)

    var stream = newFileStream(gir_path, fmReadWrite)
    check stream != nil
    stream.setPosition(4)
    stream.write(1'u32)
    stream.close()

    let second = run_command.handle("run", @[source_path])
    check second.success

    let refreshed = load_gir_file(gir_path)
    check refreshed.header.version == GIR_VERSION

  test "run accepts fresh GIR caches without recompiling":
    let source_path = absolutePath("tmp/run_cli_cache_reuse.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(var x 11)\nx")

    let gir_path = get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let first = run_command.handle("run", @[source_path])
    check first.success
    check fileExists(gir_path)
    let cache_before = getFileInfo(gir_path).lastWriteTime

    # Ensure timestamp precision can observe a rewrite if recompilation happens.
    sleep(1100)

    let second = run_command.handle("run", @[source_path])
    check second.success
    let cache_after = getFileInfo(gir_path).lastWriteTime

    check cache_after == cache_before

  test "run resolves package imports from lockfile deps graph":
    let root = createTempDir("gene_run_pkg_lock_", "")
    let app_src = root / "src" / "index.gene"
    let dep_root = root / ".gene" / "deps" / "x" / "core" / "1.0.0"
    let lock_path = root / "package.gene.lock"

    createDir(root / "src")
    createDir(dep_root / "src")
    writeFile(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/core" "*" ^path "./vendor/core")
]
""")
    writeFile(app_src, """
(import version from "index" ^pkg "x/core")
(version)
""")
    writeFile(dep_root / "package.gene", """
^name "x/core"
^version "1.0.0"
^dependencies []
""")
    writeFile(dep_root / "src" / "index.gene", """
(fn version [] 42)
""")
    writeFile(lock_path, """
{
  ^lock_version 1
  ^root_dependencies {
    ^x/core "x/core@1.0.0"
  }
  ^packages {
    ^x/core@1.0.0 {
      ^name "x/core"
      ^resolved "1.0.0"
      ^node_id "x/core@1.0.0"
      ^dir ".gene/deps/x/core/1.0.0"
      ^source {^type "path" ^path "./vendor/core"}
      ^sha256 "dummy"
      ^singleton false
      ^dependencies {}
    }
  }
}
""")

    defer:
      if dirExists(root):
        removeDir(root)

    let result = run_command.handle("run", @[app_src])
    check result.success

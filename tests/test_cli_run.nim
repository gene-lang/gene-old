import unittest, os, streams, strutils
import std/tempfiles

import gene/gir
import commands/run as run_command

proc skip_gir_string(stream: Stream) =
  let str_len = stream.readUint32()
  if str_len > 0:
    discard stream.readStr(str_len.int)

proc find_gir_source_hash_offset(gir_path: string): int =
  var reader = newFileStream(gir_path, fmRead)
  doAssert reader != nil, "Failed to open GIR for source-hash offset lookup"
  defer:
    reader.close()

  var magic: array[4, char]
  doAssert reader.readData(magic[0].addr, 4) == 4, "Failed to read GIR magic"
  discard reader.readUint32()
  skip_gir_string(reader)
  skip_gir_string(reader)
  discard reader.readInt64()
  discard reader.readBool()
  discard reader.readBool()
  result = reader.getPosition().int

proc overwrite_gir_source_hash(gir_path: string, new_hash: int64) =
  let source_hash_offset = find_gir_source_hash_offset(gir_path)
  var stream = newFileStream(gir_path, fmReadWriteExisting)
  doAssert stream != nil, "Failed to open GIR for source-hash overwrite"
  defer:
    stream.close()

  stream.setPosition(source_hash_offset)
  stream.write(new_hash)

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

    var stream = newFileStream(gir_path, fmReadWriteExisting)
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

  test "run invalidates stale GIR source hash caches and recompiles":
    let source_path = absolutePath("tmp/run_cli_hash_invalidation.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(var x 13)\nx")

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

    let original_hash = load_gir_file(gir_path).header.source_hash
    let corrupted_hash = cast[int64](original_hash) + 1'i64
    overwrite_gir_source_hash(gir_path, corrupted_hash)
    check cast[int64](load_gir_file(gir_path).header.source_hash) == corrupted_hash

    # Ensure timestamp precision can observe a rewrite if recompilation happens.
    sleep(1100)

    let second = run_command.handle("run", @[source_path])
    check second.success

    let refreshed = load_gir_file(gir_path)
    check refreshed.header.source_hash == original_hash

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

  test "run formats runtime diagnostics as Gene values":
    let source_path = absolutePath("tmp/run_cli_runtime_error.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(1 .missing)")

    defer:
      if fileExists(source_path):
        removeFile(source_path)

    let result = run_command.handle("run", @[source_path, "--no-gir-cache"])
    check not result.success
    check result.error.startsWith("{")
    check result.error.contains("^severity \"error\"")
    check result.error.contains("^stage \"runtime\"")
    check result.error.contains("^code \"GENE.RUNTIME.ERROR\"")
    check result.error.contains("^message \"Unified method call not supported for VkInt\"")

  test "run rejects package-qualified imports that escape package root":
    let root = createTempDir("gene_run_pkg_boundary_", "")
    let app_src = root / "src" / "index.gene"
    let dep_root = root / ".gene" / "deps" / "x" / "core" / "1.0.0"
    let dep_parent = root / ".gene" / "deps" / "x" / "core"
    let lock_path = root / "package.gene.lock"

    createDir(root / "src")
    createDir(dep_root / "src")
    createDir(dep_parent)
    writeFile(root / "package.gene", """
^name "x/app"
^version "0.1.0"
^dependencies [
  ($dep "x/core" "*" ^path "./vendor/core")
]
""")
    writeFile(app_src, """
(import data from "../outside" ^pkg "x/core")
(data)
""")
    writeFile(dep_root / "package.gene", """
^name "x/core"
^version "1.0.0"
^dependencies []
""")
    writeFile(dep_root / "src" / "index.gene", """
(fn version [] 42)
""")
    writeFile(dep_parent / "outside.gene", """
(var /data 99)
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
    check not result.success
    check result.error.contains("GENE.PACKAGE.BOUNDARY")

  test "run prefers importer-relative modules over workspace fallback":
    let root = createTempDir("gene_run_resolve_precedence_", "")
    let workspace = createTempDir("gene_run_workspace_", "")
    let app_src = root / "src" / "index.gene"
    let local_mod = root / "src" / "libtarget.gene"
    let workspace_mod = workspace / "src" / "libtarget.gene"
    let previous_workspace = getEnv("GENE_WORKSPACE_PATH", "")

    createDir(root / "src")
    createDir(workspace / "src")
    writeFile(app_src, """
(import marker from "libtarget")
(assert ((marker) == 1))
1
""")
    writeFile(local_mod, """
(fn marker [] 1)
""")
    writeFile(workspace_mod, """
(fn marker [] 2)
""")

    putEnv("GENE_WORKSPACE_PATH", workspace)
    defer:
      if previous_workspace.len > 0:
        putEnv("GENE_WORKSPACE_PATH", previous_workspace)
      else:
        delEnv("GENE_WORKSPACE_PATH")
      if dirExists(root):
        removeDir(root)
      if dirExists(workspace):
        removeDir(workspace)

    let result = run_command.handle("run", @[app_src])
    check result.success

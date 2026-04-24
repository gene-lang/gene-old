import unittest, os, strutils

import gene/parser
import gene/compiler
import gene/gir
import gene/serdes
import gene/types except Exception
import gene/vm
import commands/run as run_command

import ../helpers

const missingVoidProgram = """
  (do
    (var g `(item ^present nil nil))
    [
      (if (g/x == void) "gene-missing" else "gene-present")
      (if (g/present == nil) "gene-present-nil" else "gene-present-other")
      (if (g/9 == void) "gene-child-missing" else "gene-child-present")
      (if (g/0 == nil) "gene-child-nil" else "gene-child-other")
    ]
  )
"""

const mixedVoidProgram = """
  (do
    (var m {^present nil})
    (var xs [nil])
    (class Box
      (ctor []
        (/present = nil)
      )
    )
    (var box (new Box))
    [
      (if (m/missing == void) "map-missing" else "map-present")
      (if (m/present == nil) "map-present-nil" else "map-present-other")
      (if (xs/8 == void) "array-missing" else "array-present")
      (if (xs/0 == nil) "array-present-nil" else "array-present-other")
      (if (box/missing == void) "instance-missing" else "instance-present")
      (if (box/present == nil) "instance-present-nil" else "instance-present-other")
      (if ((case 5 when 1 "one" when 2 "two") == nil) "case-nil" else "case-other")
    ]
  )
"""

proc exec_stress(code, filename: string): Value =
  init_all()
  VM.exec(cleanup(code), filename)

proc check_array_strings(value: Value, expected: openArray[string]) =
  check value.kind == VkArray
  check array_data(value).len == expected.len
  for idx, item in array_data(value):
    check item == expected[idx].to_value()

suite "stable core stress":
  test "stable-core stress parser round trips representative values":
    for source in [
      "#(item ^present nil nil)",
      "{^present nil}",
      "[nil]",
      "(if (g/x == void) \"missing\" else \"present\")",
      "(case 5 when 1 \"one\" when 2 \"two\")",
    ]:
      let parsed = parser.read(source)
      let rendered = value_to_gene_str(parsed)
      check value_to_gene_str(parser.read(rendered)) == rendered

  test "missing gene selectors are checkable with void":
    let result = exec_stress(missingVoidProgram, "stable_core_gene_void.gene")
    check_array_strings(result, [
      "gene-missing",
      "gene-present-nil",
      "gene-child-missing",
      "gene-child-nil",
    ])

  test "missing map array and instance selectors are checkable with void":
    let result = exec_stress(mixedVoidProgram, "stable_core_mixed_void.gene")
    check_array_strings(result, [
      "map-missing",
      "map-present-nil",
      "array-missing",
      "array-present-nil",
      "instance-missing",
      "instance-present-nil",
      "case-nil",
    ])

  test "stable-core stress serdes round trips representative values":
    init_all()
    init_serdes()
    for source in [
      "{^present nil}",
      "[nil void \"text\"]",
      "`(item ^present nil nil)",
      "#(1 ^present nil nil)",
    ]:
      let value = VM.exec(source, "stable_core_serdes.gene")
      let serialized = serialize(value).to_s()
      let roundtripped = deserialize(serialized)
      check value_to_gene_str(roundtripped) == value_to_gene_str(value)

  test "stable-core stress GIR round trips representative programs":
    let gir_path = "build/tests/stable_core_stress.gir"
    createDir(parentDir(gir_path))

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    let compiled = compiler.parse_and_compile(cleanup(mixedVoidProgram), "stable_core_direct_gir.gene", module_mode = true, run_init = false)
    gir.save_gir(compiled, gir_path)
    let loaded = gir.load_gir(gir_path)

    check loaded.instructions.len == compiled.instructions.len
    check loaded.inline_caches.len == loaded.instructions.len
    check loaded.skip_return == compiled.skip_return

  test "stable-core stress cached GIR execution preserves void checks":
    let source_path = absolutePath("tmp/stable_core_cached.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, cleanup("""
      (var g `(item ^present nil nil))
      (assert ((g/x == void) == true))
      (assert ((g/present == nil) == true))

      (var m {^present nil})
      (assert ((m/missing == void) == true))
      (assert ((m/present == nil) == true))

      (var xs [nil])
      (assert ((xs/4 == void) == true))
      (assert ((xs/0 == nil) == true))
    """))

    let gir_path = gir.get_gir_path(source_path, "build")
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

    let second = run_command.handle("run", @[source_path])
    check second.success

  test "stable-core stress failure paths are deterministic":
    let source_path = absolutePath("tmp/stable_core_failure.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, cleanup("""
      (var g `(item ^present nil nil))
      (assert ((g/x == nil) == true))
    """))

    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let result = run_command.handle("run", @[source_path])
    check not result.success
    check result.error.contains("^severity \"error\"")
    check result.error.contains("^stage \"runtime\"")

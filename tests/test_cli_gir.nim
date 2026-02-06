import unittest, os, strutils

import gene/parser
import gene/compiler
import gene/gir
import gene/types except Exception
import gene/type_checker
import commands/gir as gir_command

suite "GIR CLI":
  test "gir show renders instructions":
    let source_path = "examples/hello_world.gene"
    let code = readFile(source_path)
    let parsed = parser.read_all(code)
    let compiled = compiler.compile(parsed)

    let out_dir = "build/tests"
    createDir(out_dir)
    let gir_path = out_dir / "hello_world_test.gir"
    gir.save_gir(compiled, gir_path, source_path)

    let result = gir_command.handle("gir", @["show", gir_path])
    check result.success
    check result.output.contains("GIR File: " & gir_path)
    check result.output.contains("Instructions (")
    check result.output.contains("Timestamp: ")

    let aliasResult = gir_command.handle("gir", @["visualize", gir_path])
    check aliasResult.success

    removeFile(gir_path)

  test "gir show reports missing file":
    let result = gir_command.handle("gir", @["show", "build/does_not_exist.gir"])
    check not result.success
    check result.error.contains("not found")

  test "gir preserves module type hierarchy":
    let code = """
      (ns api
        (class Request)
        (enum Status ok error)
        (ns v1
          (class User)
        )
      )
      (class Root)
    """

    let compiled = compiler.parse_and_compile(code, "<module>", module_mode = true, run_init = false)
    check compiled.module_types.len > 0

    let gir_path = "build/tests/module_type_hierarchy.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)
    let loaded = gir.load_gir(gir_path)

    proc find_node(nodes: seq[ModuleTypeNode], path: seq[string]): ModuleTypeNode =
      if path.len == 0:
        return nil
      var current_nodes = nodes
      var current: ModuleTypeNode = nil
      for part in path:
        current = nil
        for node in current_nodes:
          if node != nil and node.name == part:
            current = node
            break
        if current == nil:
          return nil
        current_nodes = current.children
      return current

    let api = find_node(loaded.module_types, @["api"])
    let request = find_node(loaded.module_types, @["api", "Request"])
    let status = find_node(loaded.module_types, @["api", "Status"])
    let user = find_node(loaded.module_types, @["api", "v1", "User"])
    let root = find_node(loaded.module_types, @["Root"])

    check api != nil
    check api.kind == MtkNamespace
    check request != nil
    check request.kind == MtkClass
    check status != nil
    check status.kind == MtkEnum
    check user != nil
    check user.kind == MtkClass
    check root != nil
    check root.kind == MtkClass

    removeFile(gir_path)

  test "type imports use GIR module type metadata":
    let module_source = absolutePath("tmp/type_import_module.gene")
    createDir(parentDir(module_source))
    writeFile(module_source, "(class User)")
    let module_compiled = compiler.parse_and_compile(readFile(module_source), module_source, module_mode = true, run_init = false)
    let module_gir = gir.get_gir_path(module_source, "build")
    gir.save_gir(module_compiled, module_gir, module_source)

    defer:
      if fileExists(module_source):
        removeFile(module_source)
      if fileExists(module_gir):
        removeFile(module_gir)

    let code = "(import User:user_t from \"" & module_source & "\") (var x: user_t)"
    let checker = type_checker.new_type_checker(strict = true, module_filename = absolutePath("tmp/type_import_main.gene"))
    let nodes = parser.read_all(code)
    for node in nodes:
      checker.type_check_node(node)

  test "gir preserves type descriptor table":
    let code = "(var x 1) x"
    let compiled = compiler.parse_and_compile(code, "<descriptor-test>")
    compiled.type_descriptors = @[
      TypeDesc(kind: TdkNamed, name: "Int"),
      TypeDesc(kind: TdkNamed, name: "String"),
      TypeDesc(kind: TdkUnion, members: @[0'i32, 1'i32]),
      TypeDesc(kind: TdkFn, params: @[0'i32], ret: 1'i32, effects: @["io/read"])
    ]

    let gir_path = "build/tests/type_descriptor_roundtrip.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)
    let loaded = gir.load_gir(gir_path)

    check loaded.type_descriptors.len == 4
    check loaded.type_descriptors[0].kind == TdkNamed
    check loaded.type_descriptors[0].name == "Int"
    check loaded.type_descriptors[2].kind == TdkUnion
    check loaded.type_descriptors[2].members == @[0'i32, 1'i32]
    check loaded.type_descriptors[3].kind == TdkFn
    check loaded.type_descriptors[3].params == @[0'i32]
    check loaded.type_descriptors[3].ret == 1'i32
    check loaded.type_descriptors[3].effects == @["io/read"]

    removeFile(gir_path)

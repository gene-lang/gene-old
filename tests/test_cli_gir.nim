import unittest, os, strutils, tables, osproc

import gene/parser
import gene/compiler
import gene/gir
import gene/types except Exception
import gene/types/runtime_types
import gene/type_checker
import gene/vm/args
import gene/vm
import commands/gir as gir_command
import ./helpers

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

  test "mixed typed and untyped modules enforce typed boundaries":
    init_all()
    let untyped_source = absolutePath("tmp/mixed_untyped_module.gene")
    let typed_source = absolutePath("tmp/mixed_typed_module.gene")
    let untyped_import = "tmp/mixed_untyped_module"
    let typed_import = "tmp/mixed_typed_module"
    createDir(parentDir(untyped_source))
    writeFile(untyped_source, "(fn emit_bad [] \"oops\")")
    writeFile(typed_source, "(fn expects_int [x: Int] -> Int x)")
    let untyped_gir = gir.get_gir_path(untyped_source, "build")
    let typed_gir = gir.get_gir_path(typed_source, "build")

    defer:
      for path in [untyped_source, typed_source, untyped_gir, typed_gir]:
        if fileExists(path):
          removeFile(path)

    var raised_typed_calls_untyped = false
    try:
      discard VM.exec(
        "(import emit_bad from \"" & untyped_import & "\") (fn requires_int [x: Int] -> Int x) (requires_int (emit_bad))",
        "mixed_typed_calls_untyped.gene"
      )
    except CatchableError as e:
      raised_typed_calls_untyped = true
      check e.msg.contains("expected Int")
      check e.msg.contains("got String")
    check raised_typed_calls_untyped

    var raised_untyped_calls_typed = false
    try:
      discard VM.exec(
        "(import expects_int from \"" & typed_import & "\") (expects_int \"oops\")",
        "mixed_untyped_calls_typed.gene"
      )
    except CatchableError as e:
      raised_untyped_calls_typed = true
      check e.msg.contains("expected Int")
      check e.msg.contains("got String")
    check raised_untyped_calls_typed

  test "cached GIR keeps symbol-key maps valid across process runs":
    let source_path = absolutePath("tmp/gir_symbol_key_regression.gene")
    createDir(parentDir(source_path))

    var lines: seq[string] = @["(var m {"]
    for i in 0..520:
      lines.add("  ^sym_" & $i & " " & $i)
    lines.add("})")
    writeFile(source_path, lines.join("\n"))

    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let gene_bin = absolutePath("bin/gene")
    let first = execCmdEx(gene_bin & " run " & source_path)
    check first.exitCode == 0
    check fileExists(gir_path)

    let second = execCmdEx(gene_bin & " run " & source_path)
    check second.exitCode == 0
    check not second.output.contains("IndexDefect")

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

  test "gir preserves module type registry and aliases":
    let code = "(var x 1) x"
    let compiled = compiler.parse_and_compile(code, "<registry-test>")
    let module_path = "tmp/type_registry_roundtrip.gene"
    let user_id = 11'i32
    let union_id = 27'i32
    let fn_id = 43'i32

    let user_desc = TypeDesc(module_path: module_path, kind: TdkNamed, name: "User")
    let union_desc = TypeDesc(module_path: module_path, kind: TdkUnion, members: @[user_id, 1'i32])
    let fn_desc = TypeDesc(module_path: module_path, kind: TdkFn, params: @[user_id], ret: union_id, effects: @["io/read"])

    compiled.type_descriptors = @[user_desc, union_desc, fn_desc]
    compiled.type_registry = new_module_type_registry(module_path)
    register_type_desc(compiled.type_registry, user_id, user_desc, module_path)
    register_type_desc(compiled.type_registry, union_id, union_desc, module_path)
    register_type_desc(compiled.type_registry, fn_id, fn_desc, module_path)
    compiled.type_aliases = initTable[string, TypeId]()
    compiled.type_aliases["UserType"] = user_id
    compiled.type_aliases["UserResult"] = union_id
    compiled.type_aliases["UserFactory"] = fn_id

    let gir_path = "build/tests/type_registry_roundtrip.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)
    let loaded = gir.load_gir(gir_path)

    check loaded.type_registry != nil
    check loaded.type_registry.module_path == module_path
    check loaded.type_registry.descriptors.len == 3
    check loaded.type_registry.descriptors.hasKey(user_id)
    check loaded.type_registry.descriptors[user_id].kind == TdkNamed
    check loaded.type_registry.descriptors[user_id].name == "User"
    check loaded.type_registry.descriptors.hasKey(union_id)
    check loaded.type_registry.descriptors[union_id].kind == TdkUnion
    check loaded.type_registry.descriptors[union_id].members == @[user_id, 1'i32]
    check loaded.type_registry.descriptors.hasKey(fn_id)
    check loaded.type_registry.descriptors[fn_id].kind == TdkFn
    check loaded.type_registry.descriptors[fn_id].params == @[user_id]
    check loaded.type_registry.descriptors[fn_id].ret == union_id
    check loaded.type_registry.descriptors[fn_id].effects == @["io/read"]
    check loaded.type_registry.named_types.len == 1
    check loaded.type_registry.union_types.len == 1
    check loaded.type_registry.function_types.len == 1

    check loaded.type_aliases.len == 3
    check loaded.type_aliases["UserType"] == user_id
    check loaded.type_aliases["UserResult"] == union_id
    check loaded.type_aliases["UserFactory"] == fn_id

    removeFile(gir_path)

  test "module registry canonicalizes ownership and kind indexes":
    let module_path = "tmp/descriptor_ownership.gene"
    var descs = builtin_type_descs()

    let user_id = intern_type_desc(descs, TypeDesc(kind: TdkNamed, module_path: module_path, name: "User"))
    let applied_id = intern_type_desc(descs, TypeDesc(kind: TdkApplied, ctor: "Array", args: @[user_id]))
    let union_id = intern_type_desc(descs, TypeDesc(kind: TdkUnion, members: @[user_id, BUILTIN_TYPE_NIL_ID]))
    let fn_id = intern_type_desc(descs, TypeDesc(kind: TdkFn, params: @[user_id], ret: union_id, effects: @["io/read"]))

    let registry = populate_registry(descs, module_path)
    check registry != nil
    check registry.module_path == module_path
    check registry.descriptors[user_id].module_path == module_path
    check registry.descriptors[applied_id].module_path == module_path
    check registry.descriptors[union_id].module_path == module_path
    check registry.descriptors[fn_id].module_path == module_path
    check registry.builtin_types["Int"] == BUILTIN_TYPE_INT_ID
    check registry.named_types.len >= 1
    check registry.applied_types.len >= 1
    check registry.union_types.len >= 1
    check registry.function_types.len >= 1

    var saw_named = false
    var saw_applied = false
    var saw_union = false
    var saw_fn = false
    for _, type_id in registry.named_types:
      if type_id == user_id:
        saw_named = true
    for _, type_id in registry.applied_types:
      if type_id == applied_id:
        saw_applied = true
    for _, type_id in registry.union_types:
      if type_id == union_id:
        saw_union = true
    for _, type_id in registry.function_types:
      if type_id == fn_id:
        saw_fn = true

    check saw_named
    check saw_applied
    check saw_union
    check saw_fn

  test "gir preserves module registry module-path provenance":
    let module_path = absolutePath("tmp/registry_module_path_only_builtins.gene")
    let compiled = compiler.parse_and_compile("(var x: Int 1)", module_path)
    compiled.type_registry = populate_registry(compiled.type_descriptors, module_path)

    let gir_path = "build/tests/type_registry_module_path_roundtrip.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path, module_path)
    let loaded = gir.load_gir(gir_path)

    check loaded.type_registry != nil
    check loaded.type_registry.module_path == module_path
    check loaded.type_registry.builtin_types["Int"] == BUILTIN_TYPE_INT_ID

    removeFile(gir_path)

  test "descriptor serialization roundtrip keeps registry indexes in parity":
    let module_path = absolutePath("tmp/descriptor_registry_parity.gene")
    let code = """
      (var x: (Int | String) 1)
      (fn wrap [a: (Array Int)] -> (Result Int String)
        (Ok 1)
      )
      (fn to_text [n: Int] -> String
        (n .to_s)
      )
    """
    let compiled = compiler.parse_and_compile(code, module_path)
    let gir_path = "build/tests/descriptor_registry_parity_roundtrip.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path, module_path)
    let loaded = gir.load_gir(gir_path)

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    check loaded.type_registry != nil
    check loaded.type_descriptors.len > 0
    check loaded.type_registry.descriptors.len > 0

    for type_id, desc in loaded.type_registry.descriptors:
      check type_id >= 0'i32
      check int(type_id) < loaded.type_descriptors.len
      check descriptor_registry_key(desc) == descriptor_registry_key(loaded.type_descriptors[int(type_id)])

    let builtins_before = loaded.type_registry.builtin_types
    let named_before = loaded.type_registry.named_types
    let applied_before = loaded.type_registry.applied_types
    let unions_before = loaded.type_registry.union_types
    let functions_before = loaded.type_registry.function_types

    rebuild_module_registry_indexes(loaded.type_registry, module_path)

    check loaded.type_registry.builtin_types.len == builtins_before.len
    check loaded.type_registry.named_types.len == named_before.len
    check loaded.type_registry.applied_types.len == applied_before.len
    check loaded.type_registry.union_types.len == unions_before.len
    check loaded.type_registry.function_types.len == functions_before.len

    for key, type_id in builtins_before:
      check loaded.type_registry.builtin_types.hasKey(key)
      check loaded.type_registry.builtin_types[key] == type_id
    for key, type_id in named_before:
      check loaded.type_registry.named_types.hasKey(key)
      check loaded.type_registry.named_types[key] == type_id
    for key, type_id in applied_before:
      check loaded.type_registry.applied_types.hasKey(key)
      check loaded.type_registry.applied_types[key] == type_id
    for key, type_id in unions_before:
      check loaded.type_registry.union_types.hasKey(key)
      check loaded.type_registry.union_types[key] == type_id
    for key, type_id in functions_before:
      check loaded.type_registry.function_types.hasKey(key)
      check loaded.type_registry.function_types[key] == type_id

  test "type checker propagates descriptor ids into compiler metadata":
    let code = """
      (var x: Int 1)
      (fn id [a: Int] -> Int
        a
      )
      (id x)
    """

    let compiled = compiler.parse_and_compile(code, "<typed-descriptor-test>")
    check compiled.type_descriptors.len > 0

    var saw_var_type_id = false
    var saw_fn_type_ids = false

    for inst in compiled.instructions:
      if inst.kind == IkScopeStart and inst.arg0.kind == VkScopeTracker and not saw_var_type_id:
        let tracker = inst.arg0.ref.scope_tracker
        if tracker != nil:
          for type_id in tracker.type_expectation_ids:
            if type_id != NO_TYPE_ID:
              saw_var_type_id = true
              break
      if inst.kind == IkFunction and inst.arg0.kind == VkFunctionDef and not saw_fn_type_ids:
        let info = to_function_def_info(inst.arg0)
        check info.type_expectation_ids.len == 1
        check info.type_expectation_ids[0] != NO_TYPE_ID
        check info.return_type_id != NO_TYPE_ID
        let f = to_function(info.input, type_expectation_ids = info.type_expectation_ids,
          return_type_id = info.return_type_id)
        check f.matcher.children.len == 1
        check f.matcher.children[0].type_id != NO_TYPE_ID
        check f.matcher.return_type_id != NO_TYPE_ID

        let mismatched_input = parser.read("(fn id [a: String] -> String a)")
        let f_from_precomputed = to_function(mismatched_input, compiled.type_descriptors,
          compiled.type_aliases, compiled.module_path, compiled.type_registry,
          info.type_expectation_ids, info.return_type_id)
        check f_from_precomputed.matcher.children[0].type_id == info.type_expectation_ids[0]
        check f_from_precomputed.matcher.return_type_id == info.return_type_id

        saw_fn_type_ids = true

    check saw_var_type_id
    check saw_fn_type_ids

  test "gir preserves function type expectation metadata":
    let code = """
      (fn typed [a: Int] -> Int a)
    """
    let module_path = absolutePath("tmp/function_type_expectations_roundtrip.gene")
    let compiled = compiler.parse_and_compile(code, module_path)
    let gir_path = "build/tests/function_type_expectations_roundtrip.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path, module_path)
    let loaded = gir.load_gir(gir_path)

    var saw_fn_info = false
    for inst in loaded.instructions:
      if inst.kind == IkFunction and inst.arg0.kind == VkFunctionDef:
        let info = to_function_def_info(inst.arg0)
        check info.type_expectation_ids.len == 1
        check info.type_expectation_ids[0] == BUILTIN_TYPE_INT_ID
        check info.return_type_id == BUILTIN_TYPE_INT_ID
        saw_fn_info = true
        break

    check saw_fn_info
    removeFile(gir_path)

  test "cached GIR preserves immutable array runtime semantics":
    let code = """
      (var xs #[1 2])
      (var caught false)
      (try
        (xs .add 3)
      catch *
        (caught = true)
      )
      (assert (caught == true))
    """
    let source_path = absolutePath("tmp/gir_immutable_array_literal.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, code)
    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let gene_bin = absolutePath("bin/gene")
    let first = execCmdEx(gene_bin & " run " & source_path)
    check first.exitCode == 0
    check fileExists(gir_path)

    let second = execCmdEx(gene_bin & " run " & source_path)
    check second.exitCode == 0

  test "cached GIR preserves immutable map runtime semantics":
    let code = """
      (var m #{^a 1})
      (assert ((m .immutable?) == true))
      (var caught false)
      (try
        (m .set "a" 2)
      catch *
        (caught = true)
      )
      (assert (caught == true))
    """
    let source_path = absolutePath("tmp/gir_immutable_map_literal.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, code)
    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let gene_bin = absolutePath("bin/gene")
    let first = execCmdEx(gene_bin & " run " & source_path)
    check first.exitCode == 0
    check fileExists(gir_path)

    let second = execCmdEx(gene_bin & " run " & source_path)
    check second.exitCode == 0

  test "cached GIR preserves immutable gene runtime semantics":
    let code = """
      (var g #(1 ^a 2 3))
      (assert ((g .immutable?) == true))
      (var caught false)
      (try
        (g .set "a" 4)
      catch *
        (caught = true)
      )
      (assert (caught == true))
    """
    let source_path = absolutePath("tmp/gir_immutable_gene_literal.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, code)
    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(source_path):
        removeFile(source_path)
      if fileExists(gir_path):
        removeFile(gir_path)

    let gene_bin = absolutePath("bin/gene")
    let first = execCmdEx(gene_bin & " run " & source_path)
    check first.exitCode == 0
    check fileExists(gir_path)

    let second = execCmdEx(gene_bin & " run " & source_path)
    check second.exitCode == 0

  test "runtime validation accepts descriptor-backed type ids":
    let type_descs = @[TypeDesc(kind: TdkNamed, name: "Int")]

    check is_compatible(1.to_value(), 0'i32, type_descs)
    check not is_compatible("oops".to_value(), 0'i32, type_descs)

    var converted = NIL
    var warning = ""
    check coerce_value_to_type(1.5.to_value(), 0'i32, type_descs, "value", converted, warning)
    check converted.kind == VkInt
    check warning.len > 0

    var bad = "oops".to_value()
    var raised = false
    try:
      discard validate_or_coerce_type(bad, 0'i32, type_descs, "value")
    except CatchableError as e:
      raised = true
      check e.msg.contains("GENE_TYPE_MISMATCH")
      check e.msg.contains("in value")
    check raised

  test "try-unwrap early return enforces descriptor return types":
    init_all()
    var raised = false
    try:
      discard VM.exec("(fn bad [] -> Int (var v ((Err \"boom\") ?)) v) (bad)", "typed_try_unwrap_return_validation.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("GENE_TYPE_MISMATCH")
      check e.msg.contains("return value of bad")
      check e.msg.contains("typed_try_unwrap_return_validation.gene")
    check raised

  test "runtime function compatibility compares applied args structurally":
    var actual_descs = builtin_type_descs()
    let fn_obj = to_function(parser.read("(fn takes_int_array [a: (Array Int)] a)"), actual_descs)

    let fn_ref = new_ref(VkFunction)
    fn_ref.fn = fn_obj
    let fn_value = fn_ref.to_ref_value()

    var expected_descs = builtin_type_descs()
    let expected_int_id = resolve_type_value_to_id(parser.read("(Fn [(Array Int)] Any)"), expected_descs)
    let expected_string_id = resolve_type_value_to_id(parser.read("(Fn [(Array String)] Any)"), expected_descs)

    check is_compatible(fn_value, expected_int_id, expected_descs)
    check not is_compatible(fn_value, expected_string_id, expected_descs)

  test "types_equivalent builtin compares structural applied types":
    init_all()
    let same = VM.exec("(types_equivalent `(Array Int) `(Array Int))", "types_equivalent_same.gene")
    let diff = VM.exec("(types_equivalent `(Array Int) `(Array String))", "types_equivalent_diff.gene")
    let alias_same = VM.exec("(types_equiv Int Int)", "types_equiv_alias.gene")

    check same == TRUE
    check diff == FALSE
    check alias_same == TRUE

  test "to_function anchors descriptors to parent module registry":
    var parent_descs = builtin_type_descs()
    var aliases = initTable[string, TypeId]()
    let parent_registry = populate_registry(parent_descs)
    parent_registry.module_path = ""
    let fn_obj = to_function(
      parser.read("(fn anchored [a: (Array String)] -> (Array String) a)"),
      parent_descs,
      aliases,
      "tmp/anchored_module.gene",
      parent_registry
    )

    check parent_registry.module_path == "tmp/anchored_module.gene"
    check parent_registry.descriptors.len == parent_descs.len
    check fn_obj.matcher != nil
    check fn_obj.matcher.type_descriptors.len == parent_descs.len

    var saw_applied = false
    for desc in fn_obj.matcher.type_descriptors:
      if desc.kind == TdkApplied:
        saw_applied = true
        check desc.module_path == "tmp/anchored_module.gene"
    check saw_applied

  test "matcher argument checks use descriptor ids when names are absent":
    let matcher = new_arg_matcher()
    let param = new_matcher(matcher, MatchData)
    param.name_key = "arg".to_key()
    param.type_id = 0'i32
    matcher.children.add(param)
    matcher.has_type_annotations = true
    matcher.type_descriptors = @[TypeDesc(kind: TdkNamed, name: "Int")]
    matcher.check_hint()

    let scope = new_scope(new_scope_tracker(), nil)
    var args = new_gene(NIL)
    args.children.add("oops".to_value())

    var raised = false
    try:
      process_args(matcher, args.to_gene_value(), scope)
    except CatchableError:
      raised = true
    check raised

  test "runtime type objects load ctor/method/init implementations lazily":
    let rt = new_runtime_type_object(0'i32, TypeDesc(kind: TdkNamed, name: "Widget"))

    let ctor_fn = to_function(parser.read("(fn __ctor [] 1)"))
    let method_fn = to_function(parser.read("(fn ping [] 2)"))
    let init_fn = to_function(parser.read("(fn init [] 3)"))
    ctor_fn.scope_tracker = new_scope_tracker()
    method_fn.scope_tracker = new_scope_tracker()
    init_fn.scope_tracker = new_scope_tracker()
    let ctor_ref = new_ref(VkFunction)
    let method_ref = new_ref(VkFunction)
    let init_ref = new_ref(VkFunction)
    ctor_ref.fn = ctor_fn
    method_ref.fn = method_fn
    init_ref.fn = init_fn
    let ctor_value = ctor_ref.to_ref_value()
    let method_value = method_ref.to_ref_value()
    let init_value = init_ref.to_ref_value()

    var ctor_loads = 0
    var method_loads = 0
    var init_loads = 0

    attach_constructor_hook(rt, proc(): Value =
      ctor_loads.inc()
      if ctor_fn.body_compiled == nil:
        compile(ctor_fn)
      ctor_value
    )
    attach_method_hook(rt, "ping".to_key(), proc(): Value =
      method_loads.inc()
      if method_fn.body_compiled == nil:
        compile(method_fn)
      method_value
    )
    attach_initializer_hook(rt, proc(): Value =
      init_loads.inc()
      if init_fn.body_compiled == nil:
        compile(init_fn)
      init_value
    )

    check ctor_fn.body_compiled == nil
    check method_fn.body_compiled == nil
    check init_fn.body_compiled == nil

    discard resolve_constructor(rt)
    discard resolve_method(rt, "ping".to_key())
    discard resolve_initializer(rt)

    check ctor_fn.body_compiled != nil
    check method_fn.body_compiled != nil
    check init_fn.body_compiled != nil
    check ctor_loads == 1
    check method_loads == 1
    check init_loads == 1

    # Cached resolves must not reload
    discard resolve_constructor(rt)
    discard resolve_method(rt, "ping".to_key())
    discard resolve_initializer(rt)
    check ctor_loads == 1
    check method_loads == 1
    check init_loads == 1

  test "class definitions attach lazy runtime hooks":
    init_all()
    let class_value = VM.exec("""
      (class Hooked
        (ctor [] NIL)
        (method ping [] 1)
        (method init [] NIL)
      )
      Hooked
    """, "hooked_runtime_type.gene")

    check class_value.kind == VkClass
    let class_obj = class_value.ref.class
    check class_obj.runtime_type != nil
    check class_obj.runtime_type.constructor != NIL
    check class_obj.runtime_type.initializer != NIL
    check len(class_obj.runtime_type.methods) > 0

  test "generic function signatures intern type variables as descriptors":
    var descs = builtin_type_descs()
    let fn_obj = to_function(parser.read("(fn identity:T [x: T] -> T x)"), descs)

    check fn_obj.matcher != nil
    check fn_obj.matcher.children.len == 1
    let param_type_id = fn_obj.matcher.children[0].type_id
    check param_type_id != NO_TYPE_ID
    check descs[int(param_type_id)].kind == TdkVar
    check fn_obj.matcher.return_type_id != NO_TYPE_ID
    check descs[int(fn_obj.matcher.return_type_id)].kind == TdkVar

  test "generic function matcher survives GIR roundtrip":
    let code = """
      (fn identity:T [x: T] -> T x)
      (identity 42)
    """
    let compiled = compiler.parse_and_compile(code, "<generic-descriptor-roundtrip>")
    var generic_fn: Function = nil
    for inst in compiled.instructions:
      if inst.kind == IkFunction:
        let info = to_function_def_info(inst.arg0)
        generic_fn = to_function(info.input, compiled.type_descriptors, compiled.type_aliases,
          compiled.module_path, populate_registry(compiled.type_descriptors, compiled.module_path),
          info.type_expectation_ids, info.return_type_id)
        break

    check generic_fn != nil
    check generic_fn.matcher.children.len == 1
    let before_param_type = generic_fn.matcher.children[0].type_id
    check before_param_type != NO_TYPE_ID
    check compiled.type_descriptors[int(before_param_type)].kind == TdkVar

    let out_dir = "build/tests"
    createDir(out_dir)
    let gir_path = out_dir / "generic_descriptor_roundtrip.gir"
    gir.save_gir(compiled, gir_path, "<generic-descriptor-roundtrip>")
    let loaded = gir.load_gir(gir_path)
    removeFile(gir_path)

    var loaded_fn: Function = nil
    for inst in loaded.instructions:
      if inst.kind == IkFunction:
        let info = to_function_def_info(inst.arg0)
        loaded_fn = to_function(info.input, loaded.type_descriptors, loaded.type_aliases,
          loaded.module_path, populate_registry(loaded.type_descriptors, loaded.module_path),
          info.type_expectation_ids, info.return_type_id)
        break

    check loaded_fn != nil
    let after_param_type = loaded_fn.matcher.children[0].type_id
    check after_param_type != NO_TYPE_ID
    check loaded.type_descriptors[int(after_param_type)].kind == TdkVar

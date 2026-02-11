import unittest, os, strutils, tables

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
        let f = to_function(info.input)
        check f.matcher.children.len == 1
        check f.matcher.children[0].type_id != NO_TYPE_ID
        check f.matcher.return_type_id != NO_TYPE_ID
        saw_fn_type_ids = true

    check saw_var_type_id
    check saw_fn_type_ids

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
    except CatchableError:
      raised = true
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

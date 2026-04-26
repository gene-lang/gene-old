import unittest, os, streams, strutils, tables, osproc, locks

import gene/parser
import gene/compiler
import gene/gir
import gene/types except Exception
import gene/types/runtime_types
import gene/type_checker
import gene/vm/args
import gene/vm
import commands/gir as gir_command
import ../helpers

type
  ConcurrentCompileBarrier = object
    lock: Lock
    cond: Cond
    ready_count: int
    start: bool

  ConcurrentCompileJob = object
    fn_value: Value
    input_value: Value
    barrier: ptr ConcurrentCompileBarrier
    output_value: int64
    raised: bool

proc concurrent_compile_worker(job: ptr ConcurrentCompileJob) {.thread.} =
  {.cast(gcsafe).}:
    acquire(job.barrier[].lock)
    job.barrier[].ready_count.inc()
    while not job.barrier[].start:
      wait(job.barrier[].cond, job.barrier[].lock)
    release(job.barrier[].lock)

    let vm = new_vm_ptr()
    VM = vm
    try:
      let result = vm.exec_function(job[].fn_value, @[job[].input_value])
      job[].output_value = result.to_int()
    except CatchableError:
      job[].raised = true
    finally:
      free_vm_ptr(vm)
      VM = nil

proc read_gir_string_payload(stream: Stream): tuple[offset: int, len: int, value: string] =
  let str_len = stream.readUint32().int
  result.offset = stream.getPosition().int
  result.len = str_len
  if str_len > 0:
    result.value = stream.readStr(str_len)

proc compiler_version_payload(gir_path: string): tuple[offset: int, len: int, value: string] =
  var stream = newFileStream(gir_path, fmRead)
  doAssert stream != nil, "Failed to open GIR for compiler-version offset lookup"
  defer:
    stream.close()

  var magic: array[4, char]
  doAssert stream.readData(magic[0].addr, 4) == 4, "Failed to read GIR magic"
  discard stream.readUint32()
  result = read_gir_string_payload(stream)

proc vm_abi_payload(gir_path: string): tuple[offset: int, len: int, value: string] =
  var stream = newFileStream(gir_path, fmRead)
  doAssert stream != nil, "Failed to open GIR for VM ABI offset lookup"
  defer:
    stream.close()

  var magic: array[4, char]
  doAssert stream.readData(magic[0].addr, 4) == 4, "Failed to read GIR magic"
  discard stream.readUint32()
  discard read_gir_string_payload(stream)
  result = read_gir_string_payload(stream)

proc overwrite_gir_bytes(gir_path: string, offset: int, value: string) =
  var stream = newFileStream(gir_path, fmReadWriteExisting)
  doAssert stream != nil, "Failed to open GIR for byte overwrite"
  defer:
    stream.close()

  stream.setPosition(offset)
  stream.write(value)

proc alternate_same_len_digits(value: string): string =
  result = repeat("9", value.len)
  if result == value:
    result = repeat("8", value.len)

proc expect_load_gir_error(gir_path: string, parts: openArray[string]) =
  var raised = false
  try:
    discard gir.load_gir_file(gir_path)
  except CatchableError as e:
    raised = true
    checkpoint e.msg
    for part in parts:
      check e.msg.contains(part)
  check raised

proc expect_load_gir_metadata_error(gir_path: string, owner_path: string,
                                    invalid_type_id: TypeId,
                                    descriptor_count: int,
                                    parts: openArray[string] = []) =
  var raised = false
  try:
    discard gir.load_gir(gir_path)
  except CatchableError as e:
    raised = true
    checkpoint e.msg
    for part in [
      TypeMetadataInvalidMarker,
      "phase=GIR load",
      "owner/path=" & owner_path,
      "invalid TypeId=" & $invalid_type_id,
      "descriptor count=" & $descriptor_count,
      "descriptor-table length=" & $descriptor_count,
      "source path=" & gir_path,
    ]:
      check e.msg.contains(part)
    for part in parts:
      check e.msg.contains(part)
  check raised

proc find_module_type_node_for_test(nodes: seq[ModuleTypeNode], path: seq[string]): ModuleTypeNode =
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
  current

proc check_descriptor_metadata_summaries_equal(source_path: string,
                                               source_summary: seq[string],
                                               loaded_summary: seq[string]) =
  checkpoint "descriptor metadata parity fixture=" & source_path
  check source_summary.len > 0
  check loaded_summary.len > 0

  if source_summary.len != loaded_summary.len:
    checkpoint "source summary length=" & $source_summary.len &
      "; loaded summary length=" & $loaded_summary.len

  let common_len = min(source_summary.len, loaded_summary.len)
  var mismatch_index = -1
  for index in 0..<common_len:
    if source_summary[index] != loaded_summary[index]:
      mismatch_index = index
      break

  if mismatch_index >= 0:
    checkpoint "first descriptor metadata mismatch line=" & $mismatch_index
    checkpoint "source: " & source_summary[mismatch_index]
    checkpoint "loaded: " & loaded_summary[mismatch_index]
  elif source_summary.len != loaded_summary.len:
    if source_summary.len > common_len:
      checkpoint "first extra source line: " & source_summary[common_len]
    if loaded_summary.len > common_len:
      checkpoint "first extra loaded line: " & loaded_summary[common_len]

  check source_summary == loaded_summary

proc summary_contains(summary: seq[string], needle: string): bool =
  for line in summary:
    if line.contains(needle):
      return true
  false

proc check_source_gir_descriptor_metadata_parity(source_path, gir_path: string) =
  let compiled = compiler.parse_and_compile(readFile(source_path), source_path)
  verify_type_metadata(compiled, phase = "source descriptor parity", source_path = source_path)

  createDir(parentDir(gir_path))
  gir.save_gir(compiled, gir_path, source_path)
  let loaded = gir.load_gir(gir_path)
  verify_type_metadata(loaded, phase = "loaded descriptor parity", source_path = gir_path)

  check compiled.type_descriptors.len > BUILTIN_TYPE_COUNT
  check loaded.type_descriptors.len > BUILTIN_TYPE_COUNT

  let source_summary = descriptor_metadata_summary(compiled)
  let loaded_summary = descriptor_metadata_summary(loaded)
  check summary_contains(source_summary, ".type_registry.module_path=")
  check summary_contains(source_summary, ".IkFunction.arg0.return_type_id=")
  check_descriptor_metadata_summaries_equal(source_path, source_summary, loaded_summary)

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

  test "load_gir_file reports bad magic with path":
    let gir_path = "build/tests/bad_magic.gir"
    createDir(parentDir(gir_path))
    writeFile(gir_path, "NOPE")

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    expect_load_gir_error(gir_path, [gir_path, "magic", "Expected GENE", "got NOPE"])

  test "load_gir_file reports expected and actual version":
    let compiled = compiler.parse_and_compile("(var x 1) x", "<gir-version-diagnostic>")
    let gir_path = "build/tests/bad_version.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)

    var stream = newFileStream(gir_path, fmReadWriteExisting)
    check stream != nil
    stream.setPosition(4)
    stream.write(1'u32)
    stream.close()

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    expect_load_gir_error(gir_path, [gir_path, "GIR_VERSION", "Expected " & $GIR_VERSION, "got 1"])

  test "load_gir_file reports compiler version mismatch":
    let compiled = compiler.parse_and_compile("(var x 2) x", "<gir-compiler-diagnostic>")
    let gir_path = "build/tests/bad_compiler_version.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)

    let payload = compiler_version_payload(gir_path)
    let bad_version = alternate_same_len_digits(COMPILER_VERSION)
    check bad_version.len == payload.len
    overwrite_gir_bytes(gir_path, payload.offset, bad_version)

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    expect_load_gir_error(gir_path, [gir_path, "COMPILER_VERSION", "Expected " & COMPILER_VERSION, "got " & bad_version])

  test "load_gir_file reports value ABI mismatch":
    let compiled = compiler.parse_and_compile("(var x 3) x", "<gir-value-abi-diagnostic>")
    let gir_path = "build/tests/bad_value_abi.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)

    let payload = vm_abi_payload(gir_path)
    let current_marker = "valueabi" & $VALUE_ABI_VERSION
    let bad_marker = "valueabi" & alternate_same_len_digits($VALUE_ABI_VERSION)
    let bad_abi = payload.value.replace(current_marker, bad_marker)
    check bad_abi.len == payload.len
    overwrite_gir_bytes(gir_path, payload.offset, bad_abi)

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    expect_load_gir_error(gir_path, [gir_path, "VALUE_ABI", "Expected -valueabi" & $VALUE_ABI_VERSION, "got " & bad_abi])

  test "load_gir_file reports instruction ABI mismatch":
    let compiled = compiler.parse_and_compile("(var x 4) x", "<gir-instruction-abi-diagnostic>")
    let gir_path = "build/tests/bad_instruction_abi.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)

    let payload = vm_abi_payload(gir_path)
    let current_marker = "instabi" & $INSTRUCTION_ABI_VERSION
    let bad_marker = "instabi" & alternate_same_len_digits($INSTRUCTION_ABI_VERSION)
    let bad_abi = payload.value.replace(current_marker, bad_marker)
    check bad_abi.len == payload.len
    overwrite_gir_bytes(gir_path, payload.offset, bad_abi)

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    expect_load_gir_error(gir_path, [gir_path, "INSTRUCTION_ABI", "Expected -instabi" & $INSTRUCTION_ABI_VERSION, "got " & bad_abi])

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
    check loaded.inline_caches.len == loaded.instructions.len

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

  test "gir canonicalizes generic enum module type names":
    let code = """
      (ns api
        (enum Result:T:E
          (Ok value: T)
          (Err error: E))
      )
      (enum Box:T
        (Full value: T)
        Empty)
    """

    let compiled = compiler.parse_and_compile(code, "<generic-enum-module>", module_mode = true, run_init = false)

    let compiled_api_result = find_module_type_node_for_test(compiled.module_types, @["api", "Result"])
    let compiled_raw_api_result = find_module_type_node_for_test(compiled.module_types, @["api", "Result:T:E"])
    let compiled_box = find_module_type_node_for_test(compiled.module_types, @["Box"])
    let compiled_raw_box = find_module_type_node_for_test(compiled.module_types, @["Box:T"])

    check compiled_api_result != nil
    check compiled_api_result.kind == MtkEnum
    check compiled_raw_api_result == nil
    check compiled_box != nil
    check compiled_box.kind == MtkEnum
    check compiled_raw_box == nil

    let gir_path = "build/tests/generic_enum_module_types.gir"
    createDir(parentDir(gir_path))
    gir.save_gir(compiled, gir_path)
    let loaded = gir.load_gir(gir_path)

    let loaded_api_result = find_module_type_node_for_test(loaded.module_types, @["api", "Result"])
    let loaded_raw_api_result = find_module_type_node_for_test(loaded.module_types, @["api", "Result:T:E"])
    let loaded_box = find_module_type_node_for_test(loaded.module_types, @["Box"])
    let loaded_raw_box = find_module_type_node_for_test(loaded.module_types, @["Box:T"])

    check loaded_api_result != nil
    check loaded_api_result.kind == MtkEnum
    check loaded_raw_api_result == nil
    check loaded_box != nil
    check loaded_box.kind == MtkEnum
    check loaded_raw_box == nil

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
      TypeDesc(kind: TdkFn, params: @[CallableParamDesc(kind: CpkPositional, keyword_name: "", type_id: 0'i32)], ret: 1'i32, effects: @["io/read"])
    ]
    compiled.type_registry = populate_registry(compiled.type_descriptors, compiled.module_path)

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
    check loaded.type_descriptors[3].params.len == 1
    check loaded.type_descriptors[3].params[0].kind == CpkPositional
    check loaded.type_descriptors[3].params[0].type_id == 0'i32
    check loaded.type_descriptors[3].ret == 1'i32
    check loaded.type_descriptors[3].effects == @["io/read"]

    removeFile(gir_path)

  test "gir preserves module type registry and aliases":
    let code = "(var x 1) x"
    let compiled = compiler.parse_and_compile(code, "<registry-test>")
    let module_path = "tmp/type_registry_roundtrip.gene"
    let user_id = 0'i32
    let string_id = 1'i32
    let union_id = 2'i32
    let fn_id = 3'i32

    let user_desc = TypeDesc(module_path: module_path, kind: TdkNamed, name: "User")
    let string_desc = TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "String")
    let union_desc = TypeDesc(module_path: module_path, kind: TdkUnion, members: @[user_id, string_id])
    let fn_desc = TypeDesc(
      module_path: module_path,
      kind: TdkFn,
      params: @[CallableParamDesc(kind: CpkPositional, keyword_name: "", type_id: user_id)],
      ret: union_id,
      effects: @["io/read"]
    )

    compiled.type_descriptors = @[user_desc, string_desc, union_desc, fn_desc]
    compiled.type_registry = populate_registry(compiled.type_descriptors, module_path)
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
    check loaded.type_registry.descriptors.len == 4
    check loaded.type_registry.descriptors.hasKey(user_id)
    check loaded.type_registry.descriptors[user_id].kind == TdkNamed
    check loaded.type_registry.descriptors[user_id].name == "User"
    check loaded.type_registry.descriptors.hasKey(string_id)
    check loaded.type_registry.descriptors[string_id].kind == TdkNamed
    check loaded.type_registry.descriptors[string_id].name == "String"
    check loaded.type_registry.descriptors.hasKey(union_id)
    check loaded.type_registry.descriptors[union_id].kind == TdkUnion
    check loaded.type_registry.descriptors[union_id].members == @[user_id, string_id]
    check loaded.type_registry.descriptors.hasKey(fn_id)
    check loaded.type_registry.descriptors[fn_id].kind == TdkFn
    check loaded.type_registry.descriptors[fn_id].params.len == 1
    check loaded.type_registry.descriptors[fn_id].params[0].kind == CpkPositional
    check loaded.type_registry.descriptors[fn_id].params[0].type_id == user_id
    check loaded.type_registry.descriptors[fn_id].ret == union_id
    check loaded.type_registry.descriptors[fn_id].effects == @["io/read"]
    check loaded.type_registry.builtin_types.len == 1
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
    let fn_id = intern_type_desc(descs, TypeDesc(
      kind: TdkFn,
      params: @[CallableParamDesc(kind: CpkPositional, keyword_name: "", type_id: user_id)],
      ret: union_id,
      effects: @["io/read"]
    ))

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

  test "runtime function compatibility supports typed rest element shorthand":
    var actual_descs = builtin_type_descs()
    let fn_obj = to_function(parser.read("(fn collect [head: String items...: Int] items)"), actual_descs)

    let fn_ref = new_ref(VkFunction)
    fn_ref.fn = fn_obj
    let fn_value = fn_ref.to_ref_value()

    var expected_descs = builtin_type_descs()
    let expected_ok = resolve_type_value_to_id(parser.read("(Fn [String Int...] Any)"), expected_descs)
    let expected_bad = resolve_type_value_to_id(parser.read("(Fn [String String...] Any)"), expected_descs)

    check is_compatible(fn_value, expected_ok, expected_descs)
    check not is_compatible(fn_value, expected_bad, expected_descs)

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
    check ctor_fn.body_compiled.inline_caches.len == ctor_fn.body_compiled.instructions.len
    check method_fn.body_compiled.inline_caches.len == method_fn.body_compiled.instructions.len
    check init_fn.body_compiled.inline_caches.len == init_fn.body_compiled.instructions.len
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

  test "concurrent first-call publication compiles a shared function once and publishes a ready body":
    init_all()
    let fn_value = VM.exec("""
      (do
        (fn shared_add [x: Int] -> Int
          (var a (+ x 1))
          (var b (+ a 2))
          (var c (+ b 3))
          (+ c 4))
        shared_add)
    """, "concurrent_lazy_compile.gene")

    check fn_value.kind == VkFunction
    let f = fn_value.ref.fn
    check load_published_body(f) == nil

    var barrier: ConcurrentCompileBarrier
    initLock(barrier.lock)
    initCond(barrier.cond)
    defer:
      deinitCond(barrier.cond)
      deinitLock(barrier.lock)

    var job1 = ConcurrentCompileJob(fn_value: fn_value, input_value: 10.to_value(), barrier: addr barrier)
    var job2 = ConcurrentCompileJob(fn_value: fn_value, input_value: 20.to_value(), barrier: addr barrier)
    var thread1: system.Thread[ptr ConcurrentCompileJob]
    var thread2: system.Thread[ptr ConcurrentCompileJob]

    createThread(thread1, concurrent_compile_worker, addr job1)
    createThread(thread2, concurrent_compile_worker, addr job2)

    while true:
      acquire(barrier.lock)
      let ready = barrier.ready_count
      if ready >= 2:
        barrier.start = true
        broadcast(barrier.cond)
        release(barrier.lock)
        break
      release(barrier.lock)
      sleep(10)

    joinThread(thread1)
    joinThread(thread2)

    check not job1.raised
    check not job2.raised
    check job1.output_value == 20
    check job2.output_value == 30

    let compiled = load_published_body(f)
    check compiled != nil
    check compiled.inline_caches.len == compiled.instructions.len

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

  test "source and loaded GIR descriptor metadata summaries match for typed fixtures":
    let fixtures = @[
      (source: "testsuite/05-functions/functions/4_typed_functions.gene",
       gir: "build/tests/descriptor_parity_typed_functions.gir"),
      (source: "testsuite/02-types/types/10_generic_and_guards.gene",
       gir: "build/tests/descriptor_parity_generic_and_guards.gir"),
      (source: "testsuite/02-types/types/16_enum_declaration_contract.gene",
       gir: "build/tests/descriptor_parity_enum_declaration_contract.gir"),
    ]

    for fixture in fixtures:
      defer:
        if fileExists(fixture.gir):
          removeFile(fixture.gir)
      check fileExists(fixture.source)
      check_source_gir_descriptor_metadata_parity(fixture.source, fixture.gir)

  test "cached GIR preserves S05 imported enum identity fixture":
    let source_path = absolutePath("tests/fixtures/s05_gir_identity_main.gene")
    let gir_path = gir.get_gir_path(source_path, "build")
    if fileExists(gir_path):
      removeFile(gir_path)

    defer:
      if fileExists(gir_path):
        removeFile(gir_path)

    let gene_bin = absolutePath("bin/gene")
    let first = execCmdEx(gene_bin & " run " & source_path)
    checkpoint first.output
    check first.exitCode == 0
    check first.output == "s05 gir identity ok\n"
    check fileExists(gir_path)

    let second = execCmdEx(gene_bin & " run " & source_path)
    checkpoint second.output
    check second.exitCode == 0
    check second.output == first.output

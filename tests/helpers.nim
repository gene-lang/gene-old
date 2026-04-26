import unittest, strutils, tables, os, algorithm

import ../src/gene/types except Exception
import ../src/gene/parser
import ../src/gene/vm
import ../src/gene/serdes

# Uncomment below lines to see logs
# import logging
# addHandler(newConsoleLogger())

converter to_value*(self: seq[int]): Value =
  var r = new_array_value()
  for item in self:
    array_data(r).add(item.to_value())
  result = r

converter seq_to_gene*(self: seq[string]): Value =
  var r = new_array_value()
  for item in self:
    array_data(r).add(item.to_value())
  result = r

converter to_value*(self: openArray[(string, Value)]): Value =
  var map = Table[Key, Value]()
  for (k, v) in self:
    map[k.to_key()] = v
  new_map_value(map)

# Helper functions for serialization tests
proc new_gene_int*(val: int): Value =
  val.to_value()

proc new_gene_symbol*(s: string): Value =
  s.to_symbol_value()

proc sorted_summary_lines(values: seq[string]): seq[string] =
  result = values
  sort(result, system.cmp[string])

proc type_id_summary(ids: seq[TypeId]): string =
  var parts: seq[string] = @[]
  for id in ids:
    parts.add($id)
  "[" & parts.join(",") & "]"

proc is_zero_value_for_summary(value: Value): bool {.inline.} =
  value.raw == 0'u64

proc type_id_value_summary(value: Value): string =
  if is_zero_value_for_summary(value):
    return "<zero>"
  if value.kind != VkInt:
    return "<" & $value.kind & ">"
  $value.to_int()

proc type_id_array_value_summary(value: Value): string =
  if is_zero_value_for_summary(value):
    return "<zero>"
  if value.kind == VkNil:
    return "nil"
  if value.kind != VkArray:
    return "<" & $value.kind & ">"
  var parts: seq[string] = @[]
  for item in array_data(value):
    parts.add(type_id_value_summary(item))
  "[" & parts.join(",") & "]"

proc add_scope_tracker_summary(lines: var seq[string], owner: string,
                               tracker: ScopeTracker, depth = 0) =
  if tracker == nil:
    lines.add(owner & "=nil")
    return
  if depth > 32:
    lines.add(owner & ".parent=<depth-limit>")
    return

  lines.add(owner &
    " next_index=" & $tracker.next_index &
    " parent_index_max=" & $tracker.parent_index_max &
    " scope_started=" & $tracker.scope_started &
    " expectations=" & type_id_summary(tracker.type_expectation_ids))
  if tracker.parent == nil:
    lines.add(owner & ".parent=nil")
  else:
    lines.add(owner & ".parent=present")
    add_scope_tracker_summary(lines, owner & ".parent", tracker.parent, depth + 1)

proc summarize_compilation_unit(cu: CompilationUnit, owner: string,
                                lines: var seq[string], depth: int)

proc add_compiled_body_summary(lines: var seq[string], owner: string,
                               value: Value, depth: int) =
  if is_zero_value_for_summary(value):
    lines.add(owner & "=<zero>")
    return
  case value.kind
  of VkNil:
    lines.add(owner & "=nil")
  of VkCompiledUnit:
    lines.add(owner & "=present")
    summarize_compilation_unit(value.ref.cu, owner, lines, depth + 1)
  else:
    lines.add(owner & "=<" & $value.kind & ">")

proc add_function_def_summary(lines: var seq[string], owner: string,
                              value: Value, depth: int) =
  if is_zero_value_for_summary(value):
    lines.add(owner & "=<zero>")
    return
  if value.kind != VkFunctionDef:
    lines.add(owner & "=<" & $value.kind & ">")
    return

  let info = to_function_def_info(value)
  if info == nil:
    lines.add(owner & "=nil")
    return
  lines.add(owner & ".type_expectation_ids=" & type_id_summary(info.type_expectation_ids))
  lines.add(owner & ".return_type_id=" & $info.return_type_id)
  add_scope_tracker_summary(lines, owner & ".scope_tracker", info.scope_tracker)
  add_compiled_body_summary(lines, owner & ".compiled_body", info.compiled_body, depth)

proc add_scope_start_operand_summary(lines: var seq[string], owner: string,
                                     value: Value) =
  if is_zero_value_for_summary(value):
    lines.add(owner & "=<zero>")
    return
  case value.kind
  of VkNil:
    lines.add(owner & "=nil")
  of VkScopeTracker:
    add_scope_tracker_summary(lines, owner, value.ref.scope_tracker)
  else:
    lines.add(owner & "=<" & $value.kind & ">")

proc add_type_id_index_summary(lines: var seq[string], owner, name: string,
                               index: OrderedTable[string, TypeId]) =
  var entries: seq[string] = @[]
  for key, type_id in index:
    entries.add(owner & ".type_registry." & name & "[" & key & "]=" & $type_id)
  for entry in sorted_summary_lines(entries):
    lines.add(entry)

proc add_registry_summary(lines: var seq[string], owner: string,
                          registry: ModuleTypeRegistry,
                          type_descriptors: seq[TypeDesc]) =
  if registry == nil:
    lines.add(owner & ".type_registry=nil")
    return

  lines.add(owner & ".type_registry.module_path=" & registry.module_path)
  lines.add(owner & ".type_registry.descriptor_count=" & $registry.descriptors.len)

  var descriptor_entries: seq[string] = @[]
  for type_id, desc in registry.descriptors:
    descriptor_entries.add(owner & ".type_registry.descriptors[" & $type_id & "]" &
      " kind=" & $desc.kind &
      " key=" & descriptor_registry_key(desc) &
      " rendered=" & type_desc_to_string(type_id, type_descriptors))
  for entry in sorted_summary_lines(descriptor_entries):
    lines.add(entry)

  add_type_id_index_summary(lines, owner, "builtin_types", registry.builtin_types)
  add_type_id_index_summary(lines, owner, "named_types", registry.named_types)
  add_type_id_index_summary(lines, owner, "applied_types", registry.applied_types)
  add_type_id_index_summary(lines, owner, "union_types", registry.union_types)
  add_type_id_index_summary(lines, owner, "function_types", registry.function_types)

proc add_alias_summary(lines: var seq[string], owner: string,
                       aliases: Table[string, TypeId]) =
  var entries: seq[string] = @[]
  for alias_name, type_id in aliases:
    entries.add(owner & ".type_aliases[" & alias_name & "]=" & $type_id)
  for entry in sorted_summary_lines(entries):
    lines.add(entry)

proc add_instruction_metadata_summary(lines: var seq[string], owner: string,
                                      instructions: seq[Instruction], depth: int) =
  for index, instr in instructions:
    let instr_owner = owner & ".instructions[" & $index & "]." & $instr.kind
    case instr.kind
    of IkScopeStart:
      add_scope_start_operand_summary(lines, instr_owner & ".arg0", instr.arg0)
    of IkVar:
      lines.add(instr_owner & ".arg1_type_id=" & $instr.arg1)
    of IkDefineProp:
      lines.add(instr_owner & ".arg1_type_id=" & $instr.arg1)
    of IkEnumAddMember:
      lines.add(instr_owner & ".arg0_type_ids=" & type_id_array_value_summary(instr.arg0))
    of IkPushTypeValue:
      lines.add(instr_owner & ".arg0_type_id=" & type_id_value_summary(instr.arg0))
    of IkFunction, IkBlock:
      add_function_def_summary(lines, instr_owner & ".arg0", instr.arg0, depth)
    else:
      discard

proc summarize_compilation_unit(cu: CompilationUnit, owner: string,
                                lines: var seq[string], depth: int) =
  if cu == nil:
    lines.add(owner & "=nil")
    return
  if depth > 16:
    lines.add(owner & ".compiled_body=<depth-limit>")
    return

  lines.add(owner & ".kind=" & $cu.kind)
  lines.add(owner & ".descriptor_count=" & $cu.type_descriptors.len)
  for type_id, desc in cu.type_descriptors:
    lines.add(owner & ".type_descriptors[" & $type_id & "]" &
      " kind=" & $desc.kind &
      " module=" & desc.module_path &
      " key=" & descriptor_registry_key(desc) &
      " rendered=" & type_desc_to_string(type_id.TypeId, cu.type_descriptors))

  add_registry_summary(lines, owner, cu.type_registry, cu.type_descriptors)
  add_alias_summary(lines, owner, cu.type_aliases)
  add_instruction_metadata_summary(lines, owner, cu.instructions, depth)

proc descriptor_metadata_summary*(cu: CompilationUnit): seq[string] =
  ## Deterministic, metadata-focused summary for source/GIR parity tests.
  ## Intentionally excludes volatile CompilationUnit.module_path values,
  ## timestamps, raw bytecode dumps, traces, and generated/cache paths.
  result = @[]
  summarize_compilation_unit(cu, "cu", result, 0)

proc gene_type*(v: Value): Value =
  if v.kind == VkGene:
    v.gene.type
  else:
    raise newException(ValueError, "Not a gene value")

proc gene_props*(v: Value): Table[string, Value] =
  if v.kind == VkGene:
    result = initTable[string, Value]()
    for k, val in v.gene.props:
      # k is a Key (distinct int64), which is a packed symbol value
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      result[get_symbol(symbol_index.int)] = val
  else:
    raise newException(ValueError, "Not a gene value")

proc gene_children*(v: Value): seq[Value] =
  if v.kind == VkGene:
    v.gene.children
  else:
    raise newException(ValueError, "Not a gene value")

proc cleanup*(code: string): string =
  result = code
  result.stripLineEnd
  if result.contains("\n"):
    result = "\n" & result

var initialized = false
var core_extensions_built = false

proc extension_suffix(): string =
  when defined(macosx):
    ".dylib"
  elif defined(windows):
    ".dll"
  else:
    ".so"

proc ensure_core_extensions_built() =
  if core_extensions_built:
    return
  discard execShellCmd("nimble buildext")
  core_extensions_built = true

# Test-specific native functions
proc test1(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  1.to_value()

proc test2(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  # TODO: Implement instance_props access when needed
  # For now, just add the two arguments
  if arg_count >= 2:
    let a = get_positional_arg(args, 0, has_keyword_args).to_int()
    let b = get_positional_arg(args, 1, has_keyword_args).to_int()
    return (a + b).to_value()
  else:
    return 0.to_value()

proc test_increment(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  if arg_count > 0:
    let x = get_positional_arg(args, 0, has_keyword_args).to_int()
    return (x + 1).to_value()
  else:
    return 1.to_value()

proc test_reentry(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 2:
      return NIL

    let fn_val = get_positional_arg(args, 0, has_keyword_args)
    let arg_val = get_positional_arg(args, 1, has_keyword_args)

    if fn_val.kind != VkFunction:
      not_allowed("test_reentry expects a function as first argument")

    let first = vm.exec_function(fn_val, @[arg_val])
    let second = vm.exec_function(fn_val, @[first])
    return second

proc init_all*() =
  if not initialized:
    init_app_and_vm()
    init_stdlib()
    # Register test functions in gene namespace
    App.app.gene_ns.ns["test1".to_key()] = test1.to_value()
    App.app.gene_ns.ns["test2".to_key()] = test2.to_value()
    App.app.gene_ns.ns["test_increment".to_key()] = test_increment.to_value()
    App.app.gene_ns.ns["test_reentry".to_key()] = test_reentry.to_value()
    initialized = true

proc init_all_with_extensions*() =
  ensure_core_extensions_built()
  init_all()

proc test_parser*(code: string, result: Value) =
  var code = cleanup(code)
  test "Parser / read: " & code:
    check read(code) == result

proc test_parser*(code: string, callback: proc(result: Value)) =
  var code = cleanup(code)
  test "Parser / read: " & code:
    var parser = new_parser()
    callback parser.read(code)

proc test_parser_error*(code: string) =
  var code = cleanup(code)
  test "Parser error expected: " & code:
    try:
      discard read(code)
      fail()
    except ParseError:
      discard

proc test_read_all*(code: string, result: seq[Value]) =
  var code = cleanup(code)
  test "Parser / read_all: " & code:
    check read_all(code) == result

proc test_read_all*(code: string, callback: proc(result: seq[Value])) =
  var code = cleanup(code)
  test "Parser / read_all: " & code:
    callback read_all(code)

proc test_vm*(code: string) =
  var code = cleanup(code)
  test "Compilation & VM: " & code:
    init_all()
    discard VM.exec(code, "test_code")

proc test_vm*(trace: bool, code: string, result: Value) =
  var code = cleanup(code)
  test "Compilation & VM: " & code:
    init_all()
    VM.trace = trace
    check VM.exec(code, "test_code") == result

proc test_vm*(code: string, result: Value) =
  test_vm(false, code, result)

proc test_vm*(code: string, callback: proc(result: Value)) =
  var code = cleanup(code)
  test "Compilation & VM: " & code:
    init_all()
    callback VM.exec(code, "test_code")

proc test_vm*(trace: bool, code: string, callback: proc(result: Value)) =
  var code = cleanup(code)
  test "Compilation & VM: " & code:
    init_all()
    VM.trace = trace
    callback VM.exec(code, "test_code")

proc test_vm_error*(code: string) =
  var code = cleanup(code)
  test "Compilation & VM: " & code:
    init_all()
    try:
      discard VM.exec(code, "test_code")
      fail()
    except CatchableError:
      discard

proc test_serdes*(code: string, result: Value) =
  var code = cleanup(code)
  test "Serdes: " & code:
    init_all()
    init_serdes()
    var value = VM.exec(code, "test_code")
    var s = serialize(value).to_s()
    var value2 = deserialize(s)
    check value2 == result

proc test_serdes*(code: string, callback: proc(result: Value)) =
  var code = cleanup(code)
  test "Serdes: " & code:
    init_all()
    init_serdes()
    var value = VM.exec(code, "test_code")
    var s = serialize(value).to_s()
    var value2 = deserialize(s)
    callback(value2)

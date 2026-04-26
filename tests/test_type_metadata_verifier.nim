import unittest, strutils, streams, tables

import gene/compiler
import gene/parser
import gene/types except Exception

type
  MetadataFixture = object
    cu: CompilationUnit
    module_path: string
    user_id: TypeId
    applied_id: TypeId
    union_id: TypeId
    fn_id: TypeId

const TestSourcePath = "tests/fixtures/type_metadata_verifier.gene"

proc new_metadata_fixture(): MetadataFixture =
  result.module_path = TestSourcePath
  var descs = builtin_type_descs()

  result.user_id = intern_type_desc(descs,
    TypeDesc(module_path: result.module_path, kind: TdkNamed, name: "User"))
  result.applied_id = intern_type_desc(descs,
    TypeDesc(module_path: result.module_path, kind: TdkApplied, ctor: "Array", args: @[result.user_id]))
  result.union_id = intern_type_desc(descs,
    TypeDesc(module_path: result.module_path, kind: TdkUnion, members: @[result.user_id, BUILTIN_TYPE_NIL_ID]))
  result.fn_id = intern_type_desc(descs,
    TypeDesc(
      module_path: result.module_path,
      kind: TdkFn,
      params: @[CallableParamDesc(kind: CpkPositional, keyword_name: "", type_id: result.applied_id)],
      ret: result.union_id,
      effects: @["io/read"]
    ))

  result.cu = new_compilation_unit()
  result.cu.module_path = result.module_path
  result.cu.type_descriptors = descs
  result.cu.type_registry = populate_registry(result.cu.type_descriptors, result.cu.module_path)

proc expect_metadata_error(cu: CompilationUnit, expected_parts: openArray[string]) =
  var raised = false
  try:
    verify_type_metadata(cu, phase = "unit-test", source_path = TestSourcePath)
  except CatchableError as e:
    raised = true
    checkpoint e.msg
    check e.msg.contains(TypeMetadataInvalidMarker)
    check e.msg.contains("phase=unit-test")
    check e.msg.contains("owner/path=")
    check e.msg.contains("invalid TypeId=")
    check e.msg.contains("descriptor count=")
    check e.msg.contains("descriptor-table length=")
    check e.msg.contains("source path=" & TestSourcePath)
    for part in expected_parts:
      check e.msg.contains(part)
  check raised

proc expect_compile_metadata_error(action: proc() {.closure.}, expected_parts: openArray[string]) =
  var raised = false
  try:
    action()
  except CatchableError as e:
    raised = true
    checkpoint e.msg
    check e.msg.contains(TypeMetadataInvalidMarker)
    check e.msg.contains("owner/path=")
    check e.msg.contains("invalid TypeId=")
    check e.msg.contains("descriptor count=")
    check e.msg.contains("descriptor-table length=")
    check e.msg.contains("source path=" & TestSourcePath)
    for part in expected_parts:
      check e.msg.contains(part)
  check raised

proc typed_source_fixture(): string =
  """
  (type UserId Int)
  (fn typed_add [a: Int b: Int] -> Int
    (+ a b))
  (fn make_id [n: Int] -> UserId
    n)
  (typed_add 1 2)
  """

proc read_one_with_test_source(code: string): Value =
  var p = new_parser()
  var stream = new_string_stream(code)
  p.read(stream, TestSourcePath)

proc type_id_array_value_for_test(items: openArray[TypeId]): Value =
  var values: seq[Value] = @[]
  for item in items:
    values.add(item.to_value())
  new_array_value(values)

suite "Type metadata verifier":
  test "accepts valid descriptor graph and registry parity":
    let fixture = new_metadata_fixture()
    verify_type_metadata(fixture.cu, phase = "unit-test", source_path = TestSourcePath)
    check fixture.cu.type_registry != nil
    check fixture.cu.type_registry.descriptors.hasKey(fixture.fn_id)

  test "accepts NO_TYPE_ID for intentionally untyped callable references":
    let fixture = new_metadata_fixture()
    var fn_desc = fixture.cu.type_descriptors[fixture.fn_id.int]
    fn_desc.params[0].type_id = NO_TYPE_ID
    fn_desc.ret = NO_TYPE_ID
    fixture.cu.type_descriptors[fixture.fn_id.int] = fn_desc
    fixture.cu.type_registry = populate_registry(fixture.cu.type_descriptors, fixture.cu.module_path)

    verify_type_metadata(fixture.cu, phase = "unit-test", source_path = TestSourcePath)

  test "rejects out-of-range applied descriptor argument":
    let fixture = new_metadata_fixture()
    var applied_desc = fixture.cu.type_descriptors[fixture.applied_id.int]
    applied_desc.args[0] = 999'i32
    fixture.cu.type_descriptors[fixture.applied_id.int] = applied_desc

    expect_metadata_error(fixture.cu, [
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.applied_id & "].args[0]",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range union descriptor member":
    let fixture = new_metadata_fixture()
    var union_desc = fixture.cu.type_descriptors[fixture.union_id.int]
    union_desc.members[1] = 777'i32
    fixture.cu.type_descriptors[fixture.union_id.int] = union_desc

    expect_metadata_error(fixture.cu, [
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.union_id & "].members[1]",
      "invalid TypeId=777",
      "TypeId is outside the descriptor table"
    ])

  test "rejects NO_TYPE_ID in non-callable descriptor graph edges":
    let fixture = new_metadata_fixture()
    var union_desc = fixture.cu.type_descriptors[fixture.union_id.int]
    union_desc.members[0] = NO_TYPE_ID
    fixture.cu.type_descriptors[fixture.union_id.int] = union_desc

    expect_metadata_error(fixture.cu, [
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.union_id & "].members[0]",
      "invalid TypeId=" & $NO_TYPE_ID,
      "NO_TYPE_ID is not valid"
    ])

  test "rejects out-of-range function descriptor return":
    let fixture = new_metadata_fixture()
    var fn_desc = fixture.cu.type_descriptors[fixture.fn_id.int]
    fn_desc.ret = 888'i32
    fixture.cu.type_descriptors[fixture.fn_id.int] = fn_desc

    expect_metadata_error(fixture.cu, [
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.fn_id & "].ret",
      "invalid TypeId=888",
      "TypeId is outside the descriptor table"
    ])

  test "rejects missing registry descriptor entry without repairing registry":
    let fixture = new_metadata_fixture()
    fixture.cu.type_registry.descriptors.del(fixture.user_id)

    expect_metadata_error(fixture.cu, [
      "owner/path=type_registry.descriptors[" & $fixture.user_id & "]",
      "invalid TypeId=" & $fixture.user_id,
      "registry descriptor entry is missing"
    ])
    check not fixture.cu.type_registry.descriptors.hasKey(fixture.user_id)

  test "rejects altered registry descriptor entry":
    let fixture = new_metadata_fixture()
    fixture.cu.type_registry.descriptors[fixture.user_id] =
      TypeDesc(module_path: fixture.module_path, kind: TdkNamed, name: "Account")

    expect_metadata_error(fixture.cu, [
      "owner/path=type_registry.descriptors[" & $fixture.user_id & "]",
      "invalid TypeId=" & $fixture.user_id,
      "registry descriptor mismatch"
    ])

  test "rejects stale kind index without rebuilding registry":
    let fixture = new_metadata_fixture()
    let union_key = descriptor_registry_key(fixture.cu.type_registry.descriptors[fixture.union_id])
    fixture.cu.type_registry.union_types[union_key] = fixture.user_id

    expect_metadata_error(fixture.cu, [
      "owner/path=type_registry.union_types[" & union_key & "]",
      "invalid TypeId=" & $fixture.user_id,
      "registry kind index points at stale TypeId"
    ])
    check fixture.cu.type_registry.union_types[union_key] == fixture.user_id

  test "rejects nil registry at verification boundary":
    let fixture = new_metadata_fixture()
    fixture.cu.type_registry = nil

    expect_metadata_error(fixture.cu, [
      "owner/path=type_registry",
      "invalid TypeId=" & $NO_TYPE_ID,
      "type_registry is nil"
    ])

  test "rejects out-of-range compilation unit type alias":
    let fixture = new_metadata_fixture()
    fixture.cu.type_aliases = initTable[string, TypeId]()
    fixture.cu.type_aliases["BadAlias"] = 999'i32

    expect_metadata_error(fixture.cu, [
      "owner/path=type_aliases[BadAlias]",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range root matcher return type":
    let fixture = new_metadata_fixture()
    fixture.cu.matcher = new_arg_matcher()
    fixture.cu.matcher.return_type_id = 999'i32

    expect_metadata_error(fixture.cu, [
      "owner/path=matcher.return_type_id",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range nested matcher child type":
    let fixture = new_metadata_fixture()
    let root = new_arg_matcher()
    let parent = new_matcher(root, MatchData)
    let child = new_matcher(root, MatchData)
    child.type_id = 777'i32
    parent.children.add(child)
    root.children.add(parent)
    fixture.cu.matcher = root

    expect_metadata_error(fixture.cu, [
      "owner/path=matcher.children[0].children[0].type_id",
      "invalid TypeId=777",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range scope tracker parent expectation":
    let fixture = new_metadata_fixture()
    let parent = new_scope_tracker()
    parent.next_index = 1
    parent.type_expectation_ids = @[888'i32]
    let child = new_scope_tracker(parent)
    fixture.cu.instructions.add(Instruction(kind: IkScopeStart, arg0: child.to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkScopeStart.arg0.parent.type_expectation_ids[0]",
      "invalid TypeId=888",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range function definition parameter expectation":
    let fixture = new_metadata_fixture()
    let info = new_function_def_info(new_scope_tracker(), nil, NIL, @[999'i32], NO_TYPE_ID)
    fixture.cu.instructions.add(Instruction(kind: IkFunction, arg0: info.to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkFunction.arg0.type_expectation_ids[0]",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range block definition return type":
    let fixture = new_metadata_fixture()
    let info = new_function_def_info(new_scope_tracker(), nil, NIL, @[], 999'i32)
    fixture.cu.instructions.add(Instruction(kind: IkBlock, arg0: info.to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkBlock.arg0.return_type_id",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects invalid nested compiled body descriptor metadata with owner context":
    let fixture = new_metadata_fixture()
    let nested = new_compilation_unit()
    nested.module_path = fixture.module_path
    nested.type_descriptors = fixture.cu.type_descriptors
    nested.type_registry = populate_registry(nested.type_descriptors, nested.module_path)
    var applied_desc = nested.type_descriptors[fixture.applied_id.int]
    applied_desc.args[0] = 666'i32
    nested.type_descriptors[fixture.applied_id.int] = applied_desc
    let info = new_function_def_info(new_scope_tracker(), nested, NIL)
    fixture.cu.instructions.add(Instruction(kind: IkFunction, arg0: info.to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkFunction.arg0.compiled_body/" &
        fixture.module_path & "/type_descriptors[" & $fixture.applied_id & "].args[0]",
      "invalid TypeId=666",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range IkVar type metadata but ignores IkVarValue arg1 slot index":
    let fixture = new_metadata_fixture()
    fixture.cu.instructions.add(Instruction(kind: IkVarValue, arg0: NIL, arg1: 999'i32))
    verify_type_metadata(fixture.cu, phase = "unit-test", source_path = TestSourcePath)

    fixture.cu.instructions.add(Instruction(kind: IkVar, arg0: 0.to_value(), arg1: 999'i32))
    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[1].IkVar.arg1",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range IkDefineProp metadata":
    let fixture = new_metadata_fixture()
    fixture.cu.instructions.add(Instruction(
      kind: IkDefineProp,
      arg0: "prop".to_key().to_value(),
      arg1: 999'i32))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkDefineProp.arg1",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range IkEnumAddMember field metadata":
    let fixture = new_metadata_fixture()
    fixture.cu.instructions.add(Instruction(
      kind: IkEnumAddMember,
      arg0: type_id_array_value_for_test([999'i32])))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkEnumAddMember.arg0[0]",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "rejects out-of-range IkPushTypeValue metadata":
    let fixture = new_metadata_fixture()
    fixture.cu.instructions.add(Instruction(kind: IkPushTypeValue, arg0: 999.to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkPushTypeValue.arg0",
      "invalid TypeId=999",
      "TypeId is outside the descriptor table"
    ])

  test "reports malformed instruction TypeId payloads as verifier diagnostics":
    let fixture = new_metadata_fixture()
    fixture.cu.instructions.add(Instruction(kind: IkPushTypeValue, arg0: "not-a-type-id".to_value()))

    expect_metadata_error(fixture.cu, [
      "owner/path=instructions[0].IkPushTypeValue.arg0",
      "invalid TypeId=" & $NO_TYPE_ID,
      "expected integer TypeId, got VkString"
    ])

  test "accepts NO_TYPE_ID in intentionally untyped source metadata owners":
    let fixture = new_metadata_fixture()
    let root = new_arg_matcher()
    let child = new_matcher(root, MatchData)
    root.children.add(child)
    fixture.cu.matcher = root

    let tracker = new_scope_tracker()
    tracker.type_expectation_ids = @[NO_TYPE_ID]
    let info = new_function_def_info(tracker, nil, NIL, @[NO_TYPE_ID], NO_TYPE_ID)
    fixture.cu.instructions.add(Instruction(kind: IkScopeStart, arg0: tracker.to_value()))
    fixture.cu.instructions.add(Instruction(kind: IkVar, arg0: 0.to_value(), arg1: NO_TYPE_ID))
    fixture.cu.instructions.add(Instruction(kind: IkDefineProp,
      arg0: "prop".to_key().to_value(), arg1: NO_TYPE_ID))
    fixture.cu.instructions.add(Instruction(kind: IkEnumAddMember,
      arg0: type_id_array_value_for_test([NO_TYPE_ID])))
    fixture.cu.instructions.add(Instruction(kind: IkFunction, arg0: info.to_value()))

    verify_type_metadata(fixture.cu, phase = "unit-test", source_path = TestSourcePath)

  test "source parse finalizers accept representative typed source":
    let cu = compiler.parse_and_compile(typed_source_fixture(), TestSourcePath)
    check cu.type_registry != nil
    check cu.type_registry.descriptors.len == cu.type_descriptors.len

  test "stream parse finalizer accepts representative typed source":
    var stream = new_string_stream(typed_source_fixture())
    let cu = compiler.parse_and_compile(stream, TestSourcePath)
    check cu.type_registry != nil
    check cu.type_registry.descriptors.len == cu.type_descriptors.len

  test "repl parse finalizer accepts representative typed source":
    let tracker = new_scope_tracker()
    let cu = compiler.parse_and_compile_repl("""
      (fn repl_inc [x: Int] -> Int
        (+ x 1))
      (repl_inc 1)
    """, TestSourcePath, tracker)
    check cu.type_registry != nil
    check cu.type_registry.descriptors.len == cu.type_descriptors.len

  test "low-level eager compile finalizer accepts representative typed source":
    let nodes = parser.read_all(typed_source_fixture())
    let cu = compiler.compile(nodes, eager_functions = true)
    check cu.type_registry != nil
    check cu.type_registry.descriptors.len == cu.type_descriptors.len

  test "compile_init finalization rejects invalid inherited descriptor metadata":
    let fixture = new_metadata_fixture()
    var applied_desc = fixture.cu.type_descriptors[fixture.applied_id.int]
    applied_desc.args[0] = 4321'i32
    fixture.cu.type_descriptors[fixture.applied_id.int] = applied_desc

    proc action() =
      discard compiler.compile_init(1.to_value(), module_path = TestSourcePath,
        inherited_type_descriptors = fixture.cu.type_descriptors)

    expect_compile_metadata_error(action, [
      "phase=init compile",
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.applied_id & "].args[0]",
      "invalid TypeId=4321",
      "descriptor count=" & $fixture.cu.type_descriptors.len
    ])

  test "function body finalization rejects invalid matcher descriptor metadata":
    let fixture = new_metadata_fixture()
    var descs = fixture.cu.type_descriptors
    var applied_desc = descs[fixture.applied_id.int]
    applied_desc.args[0] = 765'i32
    descs[fixture.applied_id.int] = applied_desc
    let fn_obj = to_function(read_one_with_test_source("(fn broken [] 1)"), descs,
      module_path = TestSourcePath)
    fn_obj.scope_tracker = new_scope_tracker()

    proc action() =
      compiler.compile(fn_obj, eager_functions = false)

    expect_compile_metadata_error(action, [
      "phase=function body compile",
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.applied_id & "].args[0]",
      "invalid TypeId=765",
      "descriptor count=" & $descs.len
    ])

  test "block body finalization rejects invalid matcher descriptor metadata":
    let fixture = new_metadata_fixture()
    var descs = fixture.cu.type_descriptors
    var applied_desc = descs[fixture.applied_id.int]
    applied_desc.args[0] = 876'i32
    descs[fixture.applied_id.int] = applied_desc
    let block_obj = to_block(read_one_with_test_source("(block [] 1)"))
    block_obj.scope_tracker = new_scope_tracker()
    block_obj.matcher.type_descriptors = descs

    proc action() =
      compiler.compile(block_obj, eager_functions = false)

    expect_compile_metadata_error(action, [
      "phase=block body compile",
      "owner/path=" & fixture.module_path & "/type_descriptors[" & $fixture.applied_id & "].args[0]",
      "invalid TypeId=876",
      "descriptor count=" & $descs.len
    ])

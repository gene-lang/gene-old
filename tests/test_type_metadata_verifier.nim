import unittest, strutils, tables

import ../src/gene/types except Exception

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

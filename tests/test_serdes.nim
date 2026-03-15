import strutils, tables
import unittest

import gene/serdes
import gene/types except Exception
import gene/vm
import gene/vm/module

import ./helpers

proc reset_module_cache() =
  ModuleCache = initTable[string, Namespace]()
  ModuleLoadState = initTable[string, bool]()
  ModuleLoadStack = @[]

test_serdes """
  1
""", 1

test_serdes """
  "abc"
""", "abc"

test_serdes """
  [1 2]
""", @[1, 2]

test_serdes """
  {^a 1}
""", new_map_value({"a".to_key(): new_gene_int(1)}.to_table())

test "Serdes: frozen maps preserve immutable flag":
  init_all()
  init_serdes()
  let value = VM.exec("#{^a 1}", "serdes_frozen_map_source")
  check value.kind == VkMap
  check map_is_frozen(value)
  let serialized = serialize(value).to_s()
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkMap
  check map_is_frozen(roundtripped)
  check map_data(roundtripped)["a".to_key()] == 1.to_value()

test "Serdes: frozen genes preserve immutable flag":
  init_all()
  init_serdes()
  let value = VM.exec("#(1 ^a 2 3)", "serdes_frozen_gene_source")
  check value.kind == VkGene
  check gene_is_frozen(value)
  let serialized = serialize(value).to_s()
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkGene
  check gene_is_frozen(roundtripped)
  check roundtripped.gene.type == 1.to_value()
  check roundtripped.gene.props["a".to_key()] == 2.to_value()
  check roundtripped.gene.children == @[3.to_value()]

test_serdes """
  `(a ^a 2 3 4)
""", proc(r: Value) =
  check r.gene_type == new_gene_symbol("a")
  check r.gene_props == {"a": new_gene_int(2)}.toTable
  check r.gene_children == @[3.to_value(), 4.to_value()]

test "Serdes: class refs use typed module paths and auto-import":
  init_all()
  init_serdes()
  let klass = VM.exec(cleanup("""
    (import ExportedThing from "tests/fixtures/serdes_objects")
    ExportedThing
  """), "serdes_class_source")
  let serialized = serialize(klass).to_s()
  check serialized.contains("ClassRef")
  check serialized.contains("^module")
  check serialized.contains("^path")

  reset_module_cache()
  discard VM.exec("1", "serdes_other_module")
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkClass
  check roundtripped.ref.class.name == "ExportedThing"

test "Serdes: nested function refs roundtrip through typed refs":
  init_all()
  init_serdes()
  let fn_val = VM.exec(cleanup("""
    (import n/f from "tests/fixtures/mod1")
    f
  """), "serdes_fn_source")
  let serialized = serialize(fn_val).to_s()
  check serialized.contains("FunctionRef")
  check serialized.contains("n/f")

  reset_module_cache()
  discard VM.exec("1", "serdes_other_module")
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkFunction
  check VM.exec_function(roundtripped, @[7.to_value()]) == 7.to_value()

test "Serdes: imported aliases keep canonical source paths":
  init_all()
  init_serdes()
  let values = VM.exec(cleanup("""
    (import ExportedThing:Thing make_exported:factory Status:State from "tests/fixtures/serdes_objects")
    [Thing factory State/ok]
  """), "serdes_alias_source")
  check values.kind == VkArray

  let class_ser = serialize(values[0]).to_s()
  check class_ser.contains("ClassRef")
  check class_ser.contains("ExportedThing")
  check not class_ser.contains("\"Thing\"")

  let fn_ser = serialize(values[1]).to_s()
  check fn_ser.contains("FunctionRef")
  check fn_ser.contains("make_exported")
  check not fn_ser.contains("\"factory\"")

  let enum_ser = serialize(values[2]).to_s()
  check enum_ser.contains("EnumRef")
  check enum_ser.contains("Status/ok")

test "Serdes: exported instances preserve identity via InstanceRef":
  init_all()
  init_serdes()
  let instance = VM.exec(cleanup("""
    (import DEFAULT_THING from "tests/fixtures/serdes_objects")
    DEFAULT_THING
  """), "serdes_instance_ref_source")
  let serialized = serialize(instance).to_s()
  check serialized.contains("InstanceRef")

  reset_module_cache()
  discard VM.exec("1", "serdes_other_module")
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkInstance
  check instance_props(roundtripped)["name".to_key()] == "default".to_value()

test "Serdes: anonymous instances snapshot state and use .deserialize hook":
  init_all()
  init_serdes()
  let instance = VM.exec(cleanup("""
    (import ExportedThing from "tests/fixtures/serdes_objects")
    (var item (new ExportedThing "hammer"))
    item
  """), "serdes_instance_value_source")
  let serialized = serialize(instance).to_s()
  check serialized.contains("(Instance ")
  check serialized.contains("ClassRef")

  reset_module_cache()
  discard VM.exec("1", "serdes_other_module")
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkInstance
  check instance_props(roundtripped)["name".to_key()] == "hammer".to_value()
  check instance_props(roundtripped)["restored".to_key()] == TRUE

test "Serdes: enum members use EnumRef and auto-import":
  init_all()
  init_serdes()
  let member = VM.exec(cleanup("""
    (import Status from "tests/fixtures/serdes_objects")
    Status/ok
  """), "serdes_enum_source")
  let serialized = serialize(member).to_s()
  check serialized.contains("EnumRef")
  check serialized.contains("Status/ok")

  reset_module_cache()
  discard VM.exec("1", "serdes_other_module")
  let roundtripped = deserialize(serialized)
  check roundtripped.kind == VkEnumMember
  check roundtripped.ref.enum_member.name == "ok"

test "Serdes: exported refs reserialize stably and snapshots normalize once":
  init_all()
  init_serdes()
  let refs = VM.exec(cleanup("""
    (import ExportedThing make_exported DEFAULT_THING Status from "tests/fixtures/serdes_objects")
    [ExportedThing make_exported DEFAULT_THING Status/ok]
  """), "serdes_stable_source")
  check refs.kind == VkArray

  for item in array_data(refs):
    let first = serialize(item).to_s()
    let second = serialize(deserialize(first)).to_s()
    check second == first

  let anon = VM.exec(cleanup("""
    (import ExportedThing from "tests/fixtures/serdes_objects")
    (new ExportedThing "hammer")
  """), "serdes_snapshot_stable_source")
  let first = serialize(anon).to_s()
  let second = serialize(deserialize(first)).to_s()
  let third = serialize(deserialize(second)).to_s()
  check second != first
  check third == second

test "Serdes: anonymous closures are rejected":
  init_all()
  init_serdes()
  let fn_val = VM.exec(cleanup("""
    (var captured 1)
    (var f (fn [] captured))
    f
  """), "serdes_closure_source")
  var raised = false
  try:
    discard serialize(fn_val)
  except CatchableError:
    raised = true
  check raised

test "Serdes: futures are rejected":
  init_all()
  init_serdes()
  let future_val = VM.exec(cleanup("""
    (async 1)
  """), "serdes_future_source")
  check future_val.kind == VkFuture
  var raised = false
  try:
    discard serialize(future_val)
  except CatchableError:
    raised = true
  check raised

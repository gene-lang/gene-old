import unittest
import strutils
import std/tables
import ../helpers
import gene/types except Exception
import gene/vm

proc map_size(v: Value): int =
  result = 0
  for _, _ in map_data(v):
    result.inc()

test_vm """
  ({^a 1 ^b 2} .size)
""", 2

test_vm """
  ({} .empty?)
""", true

test_vm """
  ({^a 1} .not_empty?)
""", true

test_vm """
  (fn toValue [k v] v)
  ({} .map toValue)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 0

test_vm """
  (fn toKey [k v] k)
  ({^a 1 ^b 2} .map toKey)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 2
  check map_data(result)["a".to_key()] == "a".to_value()
  check map_data(result)["b".to_key()] == "b".to_value()

test_vm """
  (fn toValue [k v] v)
  ({^a 1 ^b 2} .map toValue)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 2
  check map_data(result)["a".to_key()] == 1.to_value()
  check map_data(result)["b".to_key()] == 2.to_value()

test_vm """
  (#{^a 1} .immutable?)
""", true

test_vm """
  ({^a 1} .immutable?)
""", false

suite "Immutable map guards":
  init_all()

  test "set rejects immutable maps":
    var raised = false
    try:
      discard VM.exec("(var m #{^a 1}) (m .set \"a\" 2)", "immutable_map_set.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable map")
      check e.msg.contains("set item on")
    check raised

  test "property assignment rejects immutable maps":
    var raised = false
    try:
      discard VM.exec("(var m #{^a 1}) (m/a = 2)", "immutable_map_assign.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable map")
      check e.msg.contains("set item on")
    check raised

  test "del rejects immutable maps":
    var raised = false
    try:
      discard VM.exec("(var m #{^a 1}) (m .del \"a\")", "immutable_map_del.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable map")
      check e.msg.contains("delete from")
    check raised

  test "merge rejects immutable maps":
    var raised = false
    try:
      discard VM.exec("(var m #{^a 1}) (m .merge {^b 2})", "immutable_map_merge.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable map")
      check e.msg.contains("merge into")
    check raised

  test "clear rejects immutable maps":
    var raised = false
    try:
      discard VM.exec("(var m #{^a 1}) (m .clear)", "immutable_map_clear.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable map")
      check e.msg.contains("clear")
    check raised

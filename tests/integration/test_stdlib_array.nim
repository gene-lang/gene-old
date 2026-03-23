import unittest
import strutils
import std/tables
import ../helpers
import gene/types except Exception
import gene/vm

test_vm """
  ([1 2] .size)
""", 2

test_vm """
  ([] .empty?)
""", true

test_vm """
  ([1 2] .not_empty?)
""", true

test_vm """
  ([1 2] ./0)
""", 1

test_vm """
  (var v [1 2])
  (v .set 0 3)
  v
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  check array_data(result)[1] == 2.to_value()

test_vm """
  ([1 2] .add 3)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 3
  check array_data(result)[0] == 1.to_value()
  check array_data(result)[1] == 2.to_value()
  check array_data(result)[2] == 3.to_value()

test_vm """
  ([1 2] .del 0)
""", 1

test_vm """
  (fn inc [i] (i + 1))
  ([1 2] .map inc)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 2.to_value()
  check array_data(result)[1] == 3.to_value()

test_vm """
  ([1 2 3 4] .take 2)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 1.to_value()
  check array_data(result)[1] == 2.to_value()

test_vm """
  ([1 2 3 4] .skip 2)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  check array_data(result)[1] == 4.to_value()

test_vm """
  ([1 2 3] .find (fn [x] (x > 1)))
""", 2

test_vm """
  ([1 2 3] .any (fn [x] (x > 2)))
""", TRUE

test_vm """
  ([1 2 3] .all (fn [x] (x > 0)))
""", TRUE

test_vm """
  ([1 2 3] .zip [4 5])
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0].kind == VkArray
  check array_data(result)[1].kind == VkArray
  check array_data(array_data(result)[0])[0] == 1.to_value()
  check array_data(array_data(result)[0])[1] == 4.to_value()
  check array_data(array_data(result)[1])[0] == 2.to_value()
  check array_data(array_data(result)[1])[1] == 5.to_value()

test_vm """
  ([["a" 1] ["b" 2]] .to_map)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_data(result)["a".to_key()] == 1.to_value()
  check map_data(result)["b".to_key()] == 2.to_value()

test_vm """
  (var xs [1 2])
  (var n (xs .push 3))
  [n xs]
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  let xs = array_data(result)[1]
  check xs.kind == VkArray
  check array_data(xs).len == 3
  check array_data(xs)[2] == 3.to_value()

test_vm """
  (var xs [1 2 3])
  (var last (xs .pop))
  [last xs]
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  let xs = array_data(result)[1]
  check xs.kind == VkArray
  check array_data(xs).len == 2

suite "Immutable array guards":
  init_all()

  test "add rejects immutable arrays":
    var raised = false
    try:
      discard VM.exec("(var xs #[1 2]) (xs .add 3)", "immutable_array_add.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable array")
      check e.msg.contains("append to")
    check raised

  test "push rejects immutable arrays":
    var raised = false
    try:
      discard VM.exec("(var xs #[1 2]) (xs .push 3)", "immutable_array_push.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable array")
      check e.msg.contains("push to")
    check raised

  test "index assignment rejects immutable arrays":
    var raised = false
    try:
      discard VM.exec("(var xs #[1 2]) (xs/0 = 9)", "immutable_array_assign.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable array")
      check e.msg.contains("set item on")
    check raised

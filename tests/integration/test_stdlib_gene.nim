import unittest
import strutils
import tables
import ../helpers
import gene/types except Exception
import gene/vm

test_vm """
  (var g `(1 ^a 2 3 4))
  (g .type)
""", 1.to_value()

test_vm """
  (var g `(1 ^a 2 3 4))
  (g .props)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_data(result).len == 1
  check map_data(result)["a".to_key()] == 2.to_value()

test_vm """
(var g `(1 ^a 2 3 4))
(g .children)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  check array_data(result)[1] == 4.to_value()

test_vm """
  (#(1 ^a 2 3) .immutable?)
""", true

test_vm """
  ((_ 1 2) .immutable?)
""", false

test_vm """
  (var g #(1 ^a 2 3))
  [g/a (g .get_child 0) (g .immutable?)]
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result)[0] == 2.to_value()
  check array_data(result)[1] == 3.to_value()
  check array_data(result)[2] == TRUE

suite "Immutable gene guards":
  init_all()

  test "set rejects immutable genes":
    var raised = false
    try:
      discard VM.exec("(var g #(1 ^a 2 3)) (g .set \"a\" 4)", "immutable_gene_set.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable gene")
      check e.msg.contains("set property on")
    check raised

  test "property assignment rejects immutable genes":
    var raised = false
    try:
      discard VM.exec("(var g #(1 ^a 2 3)) (g/a = 4)", "immutable_gene_assign.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable gene")
      check e.msg.contains("set property on")
    check raised

  test "child assignment rejects immutable genes":
    var raised = false
    try:
      discard VM.exec("(var g #(1 2 3)) (g/0 = 4)", "immutable_gene_child_assign.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable gene")
      check e.msg.contains("set child on")
    check raised

  test "add_child rejects immutable genes":
    var raised = false
    try:
      discard VM.exec("(var g #(1 2 3)) (g .add_child 4)", "immutable_gene_add_child.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable gene")
      check e.msg.contains("append child to")
    check raised

  test "set_genetype rejects immutable genes":
    var raised = false
    try:
      discard VM.exec("(var g #(1 2 3)) (g .set_genetype 9)", "immutable_gene_set_type.gene")
    except CatchableError as e:
      raised = true
      check e.msg.contains("immutable gene")
      check e.msg.contains("set type on")
    check raised

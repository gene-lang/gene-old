import unittest, tables, strutils

import helpers
import ../src/gene/types except Exception
import ../src/gene/compiler
import ../src/gene/vm
from ../src/gene/parser import read

proc manual_cu(instructions: seq[Instruction]): CompilationUnit =
  let cu = compile(@[read("nil")])
  cu.instructions = instructions
  cu.instruction_traces = newSeq[SourceTrace](instructions.len)
  cu

proc new_manual_vm(cu: CompilationUnit): ptr VirtualMachine =
  let vm = new_vm_ptr()
  vm.frame = new_frame()
  vm.frame.stack_index = 0
  vm.frame.scope = new_scope(new_scope_tracker())
  vm.frame.ns = App.app.gene_ns.ref.ns
  vm.cu = cu
  vm.pc = 0
  vm

proc expect_frozen_write(
  target: Value,
  op_name: string,
  instructions: seq[Instruction],
  expected_kind = VkVoid
) =
  setDeepFrozen(target)
  let kind = if expected_kind == VkVoid: target.kind else: expected_kind
  let cu = manual_cu(instructions)
  let vm = new_manual_vm(cu)
  defer:
    free_vm_ptr(vm)

  vm.frame.push(target)

  var caught = false
  try:
    discard vm.exec()
    fail()
  except CatchableError as err:
    caught = true
    check err.msg.contains("cannot mutate deep-frozen " & $kind & " via " & op_name)

  check caught

suite "Phase 1 deep-frozen write guards":
  test "raise_frozen_write populates typed payload":
    let target = new_map_value()

    var caught = false
    try:
      raise_frozen_write("IkSetMember", target)
      fail()
    except FrozenWriteError as err:
      caught = true
      check err.target_kind == VkMap
      check err.op == "IkSetMember"

    check caught

  test "all guarded mutation opcode paths raise FrozenWriteError":
    init_all()

    block:
      let target = new_map_value()
      expect_frozen_write(target, "IkSetMember", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 1.to_value()),
        Instruction(kind: IkSetMember, arg0: "name".to_key().to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkSetMember", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 2.to_value()),
        Instruction(kind: IkSetMember, arg0: "prop".to_key().to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_instance_value(nil)
      expect_frozen_write(target, "IkSetMember", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 3.to_value()),
        Instruction(kind: IkSetMember, arg0: "field".to_key().to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_map_value()
      expect_frozen_write(target, "IkSetMemberDynamic", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: "name".to_value()),
        Instruction(kind: IkPushValue, arg0: 4.to_value()),
        Instruction(kind: IkSetMemberDynamic),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_instance_value(nil)
      expect_frozen_write(target, "IkSetMemberDynamic", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: "field".to_value()),
        Instruction(kind: IkPushValue, arg0: 5.to_value()),
        Instruction(kind: IkSetMemberDynamic),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      target.gene.children.add(1.to_value())
      expect_frozen_write(target, "IkSetMemberDynamic", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 0.to_value()),
        Instruction(kind: IkPushValue, arg0: 6.to_value()),
        Instruction(kind: IkSetMemberDynamic),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_array_value(1.to_value())
      expect_frozen_write(target, "IkSetMemberDynamic", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 0.to_value()),
        Instruction(kind: IkPushValue, arg0: 7.to_value()),
        Instruction(kind: IkSetMemberDynamic),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_array_value(1.to_value())
      expect_frozen_write(target, "IkSetChild", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 8.to_value()),
        Instruction(kind: IkSetChild, arg0: 0.to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      target.gene.children.add(1.to_value())
      expect_frozen_write(target, "IkSetChild", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 9.to_value()),
        Instruction(kind: IkSetChild, arg0: 0.to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_map_value()
      expect_frozen_write(target, "IkMapSetProp", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 10.to_value()),
        Instruction(kind: IkMapSetProp, arg0: "a".to_key().to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_map_value()
      expect_frozen_write(target, "IkMapSetPropValue", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkMapSetPropValue, arg0: "b".to_key().to_value(), arg1: 11),
        Instruction(kind: IkEnd),
      ])

    block:
      let target = new_map_value()
      let spread = new_map_value({"c".to_key(): 12.to_value()}.toTable())
      expect_frozen_write(target, "IkMapSpread", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: spread),
        Instruction(kind: IkMapSpread),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneSetType", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: "Other".to_symbol_value()),
        Instruction(kind: IkGeneSetType),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneSetProp", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 13.to_value()),
        Instruction(kind: IkGeneSetProp, arg0: "p".to_key().to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneAddChild", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 14.to_value()),
        Instruction(kind: IkGeneAddChild),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneAdd", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: 15.to_value()),
        Instruction(kind: IkGeneAdd),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      let spread = new_array_value(16.to_value())
      expect_frozen_write(target, "IkGeneAddSpread", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: spread),
        Instruction(kind: IkGeneAddSpread),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneAddChildValue", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkGeneAddChildValue, arg0: 17.to_value()),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      expect_frozen_write(target, "IkGeneSetPropValue", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkGeneSetPropValue, arg0: "q".to_key().to_value(), arg1: 18),
        Instruction(kind: IkEnd),
      ])

    block:
      var target = new_gene_value("Widget".to_symbol_value())
      let spread = new_map_value({"r".to_key(): 19.to_value()}.toTable())
      expect_frozen_write(target, "IkGenePropsSpread", @[
        Instruction(kind: IkStart),
        Instruction(kind: IkPushValue, arg0: spread),
        Instruction(kind: IkGenePropsSpread),
        Instruction(kind: IkEnd),
      ])

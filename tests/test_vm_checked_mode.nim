import unittest, strutils

import helpers
import ../src/gene/types except Exception
import ../src/gene/compiler
import ../src/gene/vm
from ../src/gene/parser import read

var base_vm: ptr VirtualMachine

proc manual_cu(instructions: seq[Instruction]): CompilationUnit =
  let cu = compile(@[read("nil")])
  cu.instructions = instructions
  cu.instruction_traces = newSeq[SourceTrace](instructions.len)
  cu

proc new_checked_vm(instructions: seq[Instruction]): ptr VirtualMachine =
  init_all()
  if base_vm == nil:
    base_vm = VM
  let cu = manual_cu(instructions)
  result = new_vm_ptr()
  result.checked_vm = true
  result.frame = new_frame()
  result.frame.stack_index = 0
  result.frame.scope = new_scope(new_scope_tracker())
  result.frame.ns = App.app.gene_ns.ref.ns
  result.cu = cu
  result.pc = 0
  VM = result

proc expect_checked_failure(vm: ptr VirtualMachine, parts: openArray[string]) =
  defer:
    if VM == vm:
      VM = base_vm
    free_vm_ptr(vm)
  var caught = false
  try:
    discard vm.exec()
    fail()
  except CatchableError as err:
    caught = true
    checkpoint err.msg
    for part in parts:
      check err.msg.contains(part)
  check caught

proc expect_checked_handler_failure(vm: ptr VirtualMachine, inst: Instruction, parts: openArray[string]) =
  defer:
    if VM == vm:
      VM = base_vm
    free_vm_ptr(vm)
  var caught = false
  try:
    vm.check_exception_handlers(inst, require_current_exception = true)
    fail()
  except CatchableError as err:
    caught = true
    checkpoint err.msg
    for part in parts:
      check err.msg.contains(part)
  check caught

suite "checked VM mode":
  test "checked vm is disabled by default":
    init_all()
    check not VM.checked_vm
    check VM.exec("1", "checked_default") == 1.to_value()

  test "checked vm reports stack underflow before dispatch":
    let vm = new_checked_vm(@[
      Instruction(kind: IkPop),
      Instruction(kind: IkEnd),
    ])
    expect_checked_failure(vm, ["VM invariant failed", "pc=0", "IkPop", "stack"])

  test "checked vm reports invalid jump target":
    let vm = new_checked_vm(@[
      Instruction(kind: IkJump, arg0: 99.to_value()),
      Instruction(kind: IkEnd),
    ])
    expect_checked_failure(vm, ["VM invariant failed", "pc=0", "IkJump", "operand"])

  test "checked vm reports frame and scope boundary failures":
    block:
      let vm = new_checked_vm(@[
        Instruction(kind: IkStart),
        Instruction(kind: IkEnd),
      ])
      vm.frame = nil
      expect_checked_failure(vm, ["VM invariant failed", "pc=0", "IkStart", "frame"])

    block:
      let vm = new_checked_vm(@[
        Instruction(kind: IkVarResolve, arg0: 0.to_value()),
        Instruction(kind: IkEnd),
      ])
      vm.frame.scope = nil
      expect_checked_failure(vm, ["VM invariant failed", "pc=0", "IkVarResolve", "scope"])

  test "checked vm leaves normal execution unchanged when disabled":
    init_all()
    VM.checked_vm = false
    check VM.exec("(do (var x 1) (x + 2))", "checked_disabled") == 3.to_value()

  test "checked vm reports inherited scope chain breakage":
    let vm = new_checked_vm(@[
      Instruction(kind: IkVarResolveInherited, arg0: 0.to_value(), arg1: 1),
      Instruction(kind: IkEnd),
    ])
    expect_checked_failure(vm, ["VM invariant failed", "pc=0", "IkVarResolveInherited", "scope"])

  test "checked vm reports exception handler shape failures":
    let vm = new_checked_vm(@[
      Instruction(kind: IkThrow),
      Instruction(kind: IkEnd),
    ])
    vm.current_exception = "boom".to_value()
    vm.exception_handlers.add(ExceptionHandler(
      catch_pc: 1,
      finally_pc: -1,
      frame: nil,
      scope: vm.frame.scope,
      cu: vm.cu,
      in_finally: false
    ))
    expect_checked_handler_failure(vm, Instruction(kind: IkThrow), ["VM invariant failed", "pc=0", "IkThrow", "exception"])

## Optional VM invariant checks.
## Included from vm.nim — shares its scope.

proc vm_checks_compiled*(): bool =
  when defined(geneVmChecks):
    true
  else:
    false

proc require_checked_vm_available*() =
  when defined(geneVmChecks):
    discard
  else:
    raise new_exception(types.Exception, "checked VM mode requires building with -d:geneVmChecks")

template checked_vm_enabled*(self: ptr VirtualMachine): bool =
  when defined(geneVmChecks):
    self != nil and self.checked_vm
  else:
    false

proc vm_invariant_failure*(self: ptr VirtualMachine, inst: Instruction, boundary, detail: string) =
  let pc_text = if self == nil: "pc=<nil>" else: "pc=" & $self.pc
  raise new_exception(types.Exception,
    "VM invariant failed: " & boundary & " " & pc_text &
    " kind=" & $inst.kind & " detail=" & detail)

proc checked_pc_in_range(self: ptr VirtualMachine, inst: Instruction, pc: int, boundary: string) =
  if self == nil or self.cu == nil:
    self.vm_invariant_failure(inst, boundary, "missing compilation unit")
  if pc < 0 or pc >= self.cu.instructions.len:
    self.vm_invariant_failure(inst, boundary,
      "target pc out of range: " & $pc & " instructions=" & $self.cu.instructions.len)

proc checked_exception_pc_sentinel(pc: int): bool {.inline.} =
  pc == CATCH_PC_ASYNC_BLOCK or pc == CATCH_PC_ASYNC_FUNCTION

proc checked_arg0_int(self: ptr VirtualMachine, inst: Instruction, boundary: string): int =
  if inst.arg0.kind != VkInt:
    self.vm_invariant_failure(inst, boundary, "arg0 expected int, got " & $inst.arg0.kind)
  inst.arg0.int64.int

proc checked_scope_at_depth(self: ptr VirtualMachine, inst: Instruction, depth: int): Scope =
  if depth < 0:
    self.vm_invariant_failure(inst, "scope", "negative inherited parent depth: " & $depth)
  if self.frame == nil or self.frame.scope == nil:
    self.vm_invariant_failure(inst, "scope", "missing frame scope")

  result = self.frame.scope
  for _ in 0..<depth:
    if result.parent == nil:
      self.vm_invariant_failure(inst, "scope", "parent chain shorter than depth " & $depth)
    result = result.parent

proc checked_local_index(self: ptr VirtualMachine, inst: Instruction, inherited: bool) =
  let index = self.checked_arg0_int(inst, "operand")
  if index < 0:
    self.vm_invariant_failure(inst, "operand", "negative local index: " & $index)
  let depth = if inherited: inst.arg1.int else: 0
  let scope = self.checked_scope_at_depth(inst, depth)
  case inst.kind
  of IkVarResolve, IkVarResolveInherited, IkVarAssign, IkVarAssignInherited,
     IkGetLocal, IkSetLocal, IkAddLocal, IkIncLocal, IkDecLocal:
    if index >= scope.members.len:
      self.vm_invariant_failure(inst, "scope",
        "local index " & $index & " outside scope members=" & $scope.members.len)
  else:
    discard

proc checked_instruction_operands(self: ptr VirtualMachine, inst: Instruction) =
  case inst.kind
  of IkJump, IkJumpIfFalse, IkContinue, IkBreak, IkRepeatInit, IkRepeatDecCheck:
    let target = self.checked_arg0_int(inst, "operand")
    if target >= 0:
      self.checked_pc_in_range(inst, target, "operand")
  of IkJumpIfMatchSuccess:
    if inst.arg1 >= 0:
      self.checked_pc_in_range(inst, inst.arg1.int, "operand")
  of IkTryStart:
    let catch_pc = self.checked_arg0_int(inst, "exception")
    if not checked_exception_pc_sentinel(catch_pc):
      self.checked_pc_in_range(inst, catch_pc, "exception")
    if inst.arg1 != 0 and not checked_exception_pc_sentinel(inst.arg1.int):
      self.checked_pc_in_range(inst, inst.arg1.int, "exception")
  of IkVar, IkVarValue, IkVarResolve, IkVarAssign, IkGetLocal, IkSetLocal,
     IkAddLocal, IkIncLocal, IkDecLocal:
    self.checked_local_index(inst, false)
  of IkVarResolveInherited, IkVarAssignInherited:
    self.checked_local_index(inst, true)
  else:
    discard

proc checked_frame_state(self: ptr VirtualMachine, inst: Instruction) =
  if inst.kind in {IkNoop, IkData}:
    return
  if self.frame == nil:
    self.vm_invariant_failure(inst, "frame", "missing current frame")
  if self.frame.ref_count <= 0:
    self.vm_invariant_failure(inst, "refcount", "frame ref_count <= 0")
  if self.frame.stack_index > self.frame.stack.len.uint16:
    self.vm_invariant_failure(inst, "stack", "stack index exceeds frame stack length")
  if self.frame.scope != nil and self.frame.scope.ref_count <= 0:
    self.vm_invariant_failure(inst, "refcount", "scope ref_count <= 0")

proc check_exception_handlers*(self: ptr VirtualMachine, inst: Instruction, require_current_exception = false) =
  when defined(geneVmChecks):
    if not self.checked_vm_enabled:
      return
    if require_current_exception and self.current_exception == NIL:
      self.vm_invariant_failure(inst, "exception", "current_exception is nil during exception dispatch")
    for handler in self.exception_handlers:
      if handler.frame == nil:
        self.vm_invariant_failure(inst, "exception", "handler frame is nil")
      if handler.frame.ref_count <= 0:
        self.vm_invariant_failure(inst, "refcount", "handler frame ref_count <= 0")
      if handler.cu == nil:
        self.vm_invariant_failure(inst, "exception", "handler compilation unit is nil")
      if not checked_exception_pc_sentinel(handler.catch_pc):
        self.checked_pc_in_range(inst, handler.catch_pc, "exception")
      if handler.finally_pc >= 0:
        self.checked_pc_in_range(inst, handler.finally_pc, "exception")
      if handler.scope != nil and handler.scope.ref_count <= 0:
        self.vm_invariant_failure(inst, "refcount", "handler scope ref_count <= 0")

proc check_before_instruction*(self: ptr VirtualMachine, inst: Instruction) =
  when defined(geneVmChecks):
    if not self.checked_vm_enabled:
      return
    if self == nil:
      raise new_exception(types.Exception, "VM invariant failed: vm pc=<nil> kind=" & $inst.kind & " detail=missing VM")
    if self.cu == nil:
      self.vm_invariant_failure(inst, "frame", "missing compilation unit")
    self.checked_pc_in_range(inst, self.pc, "operand")
    if self.cu.instruction_traces.len > 0 and self.cu.instruction_traces.len < self.cu.instructions.len:
      self.vm_invariant_failure(inst, "operand", "instruction traces shorter than instructions")
    self.checked_frame_state(inst)
    if self.frame != nil:
      let effect = instruction_stack_effect(inst)
      if self.frame.stack_index.int < effect.min_pops:
        self.vm_invariant_failure(inst, "stack",
          "stack underflow: need " & $effect.min_pops & " have " & $self.frame.stack_index)
      if effect.kind == SekFixed and effect.pushes > 0:
        let projected = self.frame.stack_index.int - effect.min_pops + effect.pushes
        if projected > self.frame.stack.len:
          self.vm_invariant_failure(inst, "stack", "stack overflow projection: " & $projected)
    self.checked_instruction_operands(inst)
    self.check_exception_handlers(inst)

proc check_after_instruction*(self: ptr VirtualMachine, inst: Instruction, before_stack: uint16) =
  when defined(geneVmChecks):
    if not self.checked_vm_enabled:
      return
    discard before_stack
    self.checked_frame_state(inst)

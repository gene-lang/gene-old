import strformat

import ./type_defs
import ./core

var LABEL_COUNTER {.threadvar.}: int16

proc to_hex(i: int32): string {.inline.} =
  fmt"{i:04X}"

#################### COMPILER ####################

proc to_value*(self: ScopeTracker): Value =
  let r = new_ref(VkScopeTracker)
  r.scope_tracker = self
  result = r.to_ref_value()

proc new_compilation_unit*(): CompilationUnit =
  LABEL_COUNTER = 0
  CompilationUnit(
    id: new_id(),
    type_check: true,
    trace_root: nil,
    instruction_traces: @[],
    inline_caches: @[],
    module_exports: @[],
    module_imports: @[],
    module_types: @[],
    type_descriptors: builtin_type_descs(),
  )

proc add_instruction*(self: CompilationUnit, instr: Instruction, trace: SourceTrace = nil) =
  if self.instruction_traces.len < self.instructions.len:
    self.instruction_traces.setLen(self.instructions.len)
  self.instructions.add(instr)
  self.instruction_traces.add(trace)

proc ensure_trace_capacity*(self: CompilationUnit) =
  if self.instruction_traces.len < self.instructions.len:
    self.instruction_traces.setLen(self.instructions.len)

proc replace_traces_range*(self: CompilationUnit, start_pos, end_pos: int, replacement_count: int) =
  if self.instruction_traces.len < self.instructions.len:
    self.instruction_traces.setLen(self.instructions.len)
  let clamped_start = max(0, min(start_pos, self.instruction_traces.len))
  let clamped_end = max(clamped_start, min(end_pos, self.instruction_traces.len - 1))
  if clamped_start <= clamped_end:
    let remove_count = clamped_end - clamped_start + 1
    for _ in 0..<remove_count:
      self.instruction_traces.delete(clamped_start)
  if replacement_count > 0:
    let insert_pos = min(clamped_start, self.instruction_traces.len)
    for _ in 0..<replacement_count:
      if insert_pos >= self.instruction_traces.len:
        self.instruction_traces.add(nil)
      else:
        self.instruction_traces.insert(nil, insert_pos)

proc `$`*(self: Instruction): string =
  case self.kind
    of IkPushValue,
      IkVar, IkVarResolve, IkVarAssign,
      IkAddValue, IkVarAddValue, IkVarSubValue, IkVarMulValue, IkVarDivValue,
      IkIncVar, IkDecVar,
      IkLtValue, IkVarLtValue, IkVarLeValue, IkVarGtValue, IkVarGeValue, IkVarEqValue,
      IkMapSetProp, IkMapSetPropValue,
      IkResolveSymbol, IkResolveMethod,
      IkExport,
      IkSetMember, IkGetMember, IkGetMemberOrNil, IkGetMemberDefault,
      IkSetChild, IkGetChild,
      IkTailCall:
      if self.label.int > 0:
        result = fmt"{self.label.int32.to_hex()} {($self.kind)[2..^1]:<20} {$self.arg0}"
      else:
        result = fmt"         {($self.kind)[2..^1]:<20} {$self.arg0}"
    of IkJump, IkJumpIfFalse, IkContinue, IkBreak:
      let target_label = self.arg0.int64.Label
      if self.label.int > 0:
        result = fmt"{self.label.int32.to_hex()} {($self.kind)[2..^1]:<20} {target_label.int:04X}"
      else:
        result = fmt"         {($self.kind)[2..^1]:<20} {target_label.int:04X}"
    of IkJumpIfMatchSuccess:
      let target_label = self.arg1.int64.Label
      if self.label.int > 0:
        result = fmt"{self.label.int32.to_hex()} {($self.kind)[2..^1]:<20} {$self.arg0} {target_label.int:04X}"
      else:
        result = fmt"         {($self.kind)[2..^1]:<20} {$self.arg0} {target_label.int:04X}"
    of IkCallSuperMethod, IkCallSuperMethodMacro, IkCallSuperCtor, IkCallSuperCtorMacro:
      if self.label.int > 0:
        result = fmt"{self.label.int32.to_hex()} {($self.kind)[2..^1]:<20} {$self.arg0} {self.arg1}"
      else:
        result = fmt"         {($self.kind)[2..^1]:<20} {$self.arg0} {self.arg1}"
    of IkVarResolveInherited, IkVarAssignInherited:
      result = fmt"         {($self.kind)[2..^1]:<20} {$self.arg0} {self.arg1}"

    else:
      if self.label.int > 0:
        result = fmt"{self.label.int32.to_hex()} {($self.kind)[2..^1]}"
      else:
        result = fmt"         {($self.kind)[2..^1]}"

proc `$`*(self: seq[Instruction]): string =
  var i = 0
  while i < self.len:
    let instr = self[i]
    result &= fmt"{i:03} {instr}" & "\n"
    case instr.kind:
      of IkFunction:
        i.inc()
      else:
        i.inc()

proc `$`*(self: CompilationUnit): string =
  "CompilationUnit " & $(cast[uint64](self.id)) & "\n" & $self.instructions

proc new_label*(): Label =
  LABEL_COUNTER.inc()
  if LABEL_COUNTER == 0:
    LABEL_COUNTER.inc()
  result = LABEL_COUNTER

proc find_label*(self: CompilationUnit, label: Label): int =
  var i = 0
  while i < self.instructions.len:
    let inst = self.instructions[i]
    if inst.label == label:
      while self.instructions[i].kind == IkNoop:
        i.inc()
      return i
    i.inc()
  not_allowed("Label not found: " & $label)

proc find_loop_start*(self: CompilationUnit, pos: int): int =
  var pos = pos
  while pos > 0:
    pos.dec()
    if self.instructions[pos].kind == IkLoopStart:
      return pos
  not_allowed("Loop start not found")

proc find_loop_end*(self: CompilationUnit, pos: int): int =
  var pos = pos
  while pos < self.instructions.len - 1:
    pos.inc()
    if self.instructions[pos].kind == IkLoopEnd:
      return pos
  not_allowed("Loop end not found")

proc scope_tracker*(self: Compiler): ScopeTracker =
  if self.scope_trackers.len > 0:
    return self.scope_trackers[^1]

#################### Instruction #################

converter to_value*(i: Instruction): Value =
  let r = new_ref(VkInstruction)
  r.instr = i
  result = r.to_ref_value()

proc new_instr*(kind: InstructionKind): Instruction =
  Instruction(
    kind: kind,
  )

proc new_instr*(kind: InstructionKind, arg0: Value): Instruction =
  Instruction(
    kind: kind,
    arg0: arg0,
  )

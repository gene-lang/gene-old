## Optimization passes for compiled bytecode.
## Includes noop elimination, peephole optimization, jump resolution,
## and chunk replacement.

import ../types

when not defined(release):
  import ../logging_core
  const CompilerOptimizeLogger = "gene/compiler/optimize"

proc update_jumps*(self: CompilationUnit) =
  # echo "update_jumps called, instruction count: ", self.instructions.len
  for i in 0..<self.instructions.len:
    let inst = self.instructions[i]
    case inst.kind
      of IkJump, IkJumpIfFalse, IkContinue, IkBreak, IkGeneStartDefault, IkRepeatInit, IkRepeatDecCheck:
        # Special case: -1 means no loop (for break/continue outside loops)
        if inst.kind in {IkBreak, IkContinue} and inst.arg0.int64 == -1:
          # Keep -1 as is for runtime checking
          discard
        else:
          # Labels are stored as int16 values converted to Value
          # Extract the int value and cast to Label (int16)
          # Extract the label from the NaN-boxed value
          # The label was stored as int16, so we need to extract just the low 16 bits
          when not defined(release):
            if inst.arg0.kind != VkInt:
              log_message(
                LlError,
                CompilerOptimizeLogger,
                "inst " & $i & " (" & $inst.kind & ") arg0 is not an int: " &
                  $inst.arg0 & " kind: " & $inst.arg0.kind
              )
          let label = (inst.arg0.int64.int and 0xFFFF).int16.Label
          let new_pc = self.find_label(label)
          # if inst.kind == IkGeneStartDefault:
          #   echo "  GeneStartDefault at ", i, ": label ", label, " -> PC ", new_pc
          self.instructions[i].arg0 = new_pc.to_value()
      of IkTryStart:
        # IkTryStart has arg0 for catch PC and optional arg1 for finally PC
        when not defined(release):
          if inst.arg0.kind != VkInt:
            log_message(
              LlError,
              CompilerOptimizeLogger,
              "inst " & $i & " (" & $inst.kind & ") arg0 is not an int: " &
                $inst.arg0 & " kind: " & $inst.arg0.kind
            )
        let catch_label = (inst.arg0.int64.int and 0xFFFF).int16.Label
        let catch_pc = self.find_label(catch_label)
        self.instructions[i].arg0 = catch_pc.to_value()

        # Handle finally PC if present
        if inst.arg1 != 0:
          let finally_pc = self.find_label(inst.arg1.Label)
          self.instructions[i].arg1 = finally_pc.int32
      of IkJumpIfMatchSuccess:
        self.instructions[i].arg1 = self.find_label(inst.arg1.Label).int32
      else:
        discard

# Merge IkNoop instructions with following instructions before jump resolution
proc peephole_optimize*(self: CompilationUnit) =
  # Apply peephole optimizations to convert common patterns to superinstructions
  self.ensure_trace_capacity()
  let old_traces = self.instruction_traces
  var new_instructions: seq[Instruction] = @[]
  var new_traces: seq[SourceTrace] = @[]
  var i = 0

  while i < self.instructions.len:
    let inst = self.instructions[i]
    let trace = if i < old_traces.len: old_traces[i] else: nil

    # Check for common patterns and replace with superinstructions
    if i + 2 < self.instructions.len:
      let next1 = self.instructions[i + 1]
      let next2 = self.instructions[i + 2]

      # Pattern: VAR_RESOLVE; ADD; VAR_ASSIGN -> IkAddLocal
      if inst.kind == IkVarResolve and next1.kind == IkAdd and next2.kind == IkVarAssign:
        if inst.arg0 == next2.arg0:  # Same variable
          new_instructions.add(Instruction(
            kind: IkAddLocal,
            arg0: inst.arg0,
            label: inst.label
          ))
          new_traces.add(trace)
          i += 3
          continue

    if i + 1 < self.instructions.len:
      let next1 = self.instructions[i + 1]

      # Pattern: INC_VAR (VAR_RESOLVE; ADD 1; VAR_ASSIGN)
      if inst.kind == IkVarResolve and next1.kind == IkAddValue:
        if i + 2 < self.instructions.len and self.instructions[i + 2].kind == IkVarAssign:
          if next1.arg0.kind == VkInt and next1.arg0.int64 == 1:
            new_instructions.add(Instruction(
              kind: IkIncLocal,
              arg0: inst.arg0,
              label: inst.label
            ))
            new_traces.add(trace)
            i += 3
            continue

      # Pattern: PUSH const; UNIFIEDCALL0; POP -> IkPushCallPop
      if inst.kind == IkPushValue and inst.arg0.kind == VkNativeFn and next1.kind == IkUnifiedCall0:
        if i + 2 < self.instructions.len and self.instructions[i + 2].kind == IkPop:
          new_instructions.add(Instruction(
            kind: IkPushCallPop,
            arg0: inst.arg0,
            label: inst.label
          ))
          new_traces.add(trace)
          i += 3
          continue

      # Pattern: RETURN NIL
      if inst.kind == IkPushNil and next1.kind == IkEnd:
        new_instructions.add(Instruction(
          kind: IkReturnNil,
          label: inst.label
        ))
        new_traces.add(trace)
        i += 2
        continue

    # No pattern matched, keep original instruction
    new_instructions.add(inst)
    new_traces.add(trace)
    i += 1

  self.instructions = new_instructions
  self.instruction_traces = new_traces

proc optimize_noops*(self: CompilationUnit) =
  # Move labels from Noop instructions to the next real instruction
  # This must be done BEFORE jump resolution
  self.ensure_trace_capacity()
  let old_traces = self.instruction_traces
  var new_instructions: seq[Instruction] = @[]
  var new_traces: seq[SourceTrace] = @[]
  var pending_labels: seq[Label] = @[]
  var removed_count = 0

  for i, inst in self.instructions:
    let trace = if i < old_traces.len: old_traces[i] else: nil
    if inst.kind == IkNoop:
      if inst.label != 0:
        pending_labels.add(inst.label)
        removed_count.inc()
      elif inst.arg0.kind != VkNil:
        var modified_inst = inst
        if pending_labels.len > 0 and inst.label == 0:
          modified_inst.label = pending_labels[0]
          pending_labels.delete(0)
        new_instructions.add(modified_inst)
        new_traces.add(trace)
      else:
        removed_count.inc()
    else:
      var modified_inst = inst
      if pending_labels.len > 0:
        if inst.label == 0:
          modified_inst.label = pending_labels[0]
          if pending_labels.len > 1:
            for j in 1..<pending_labels.len:
              new_instructions.add(Instruction(kind: IkNoop, label: pending_labels[j]))
              new_traces.add(nil)
        else:
          for label in pending_labels:
            new_instructions.add(Instruction(kind: IkNoop, label: label))
            new_traces.add(nil)
        pending_labels = @[]
      new_instructions.add(modified_inst)
      new_traces.add(trace)

  for label in pending_labels:
    new_instructions.add(Instruction(kind: IkNoop, label: label))
    new_traces.add(nil)

  self.instructions = new_instructions
  self.instruction_traces = new_traces

proc replace_chunk*(self: var CompilationUnit, start_pos: int, end_pos: int, replacement: sink seq[Instruction]) =
  let replacement_count = replacement.len
  self.replace_traces_range(start_pos, end_pos, replacement_count)
  self.instructions[start_pos..end_pos] = replacement

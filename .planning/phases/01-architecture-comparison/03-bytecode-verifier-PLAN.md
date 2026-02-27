---
phase: 01-architecture-comparison
plan: 03
type: execute
wave: 2
depends_on:
  - "01"
files_modified:
  - src/gene/vm/verifier.nim
  - src/gene/compiler.nim
  - src/gene/gir.nim
  - tests/test_vm_neg.nim
autonomous: true
requirements:
  - VERIFY-01

must_haves:
  truths:
    - "Deliberately malformed bytecode (stack underflow path) is caught by the verifier before exec"
    - "All normally compiled programs pass verification without error"
    - "The verifier is called automatically after compile_init and after load_gir"
    - "Verification errors produce structured diagnostic envelopes (via make_diagnostic_message from plan 01)"
    - "The verifier catches at least: invalid jump targets pointing outside instruction array bounds, and stack depth going negative on any path"
  artifacts:
    - path: "src/gene/vm/verifier.nim"
      provides: "verify_compilation_unit proc returning VerifyResult"
      exports: ["VerifyResult", "verify_compilation_unit"]
    - path: "src/gene/compiler.nim"
      provides: "Calls verify_compilation_unit after compilation"
      contains: "verify_compilation_unit"
    - path: "src/gene/gir.nim"
      provides: "Calls verify_compilation_unit after load_gir"
      contains: "verify_compilation_unit"
    - path: "tests/test_vm_neg.nim"
      provides: "Tests for verifier catching bad bytecode"
      contains: "GENE.VERIFY"
  key_links:
    - from: "src/gene/compiler.nim"
      to: "src/gene/vm/verifier.nim"
      via: "compile_init calls verify_compilation_unit on the result"
      pattern: "verify_compilation_unit"
    - from: "src/gene/gir.nim"
      to: "src/gene/vm/verifier.nim"
      via: "load_gir calls verify_compilation_unit after deserializing"
      pattern: "verify_compilation_unit"
---

<objective>
Build a bytecode verifier for gene-old's CompilationUnit that performs stack-depth analysis and jump-target validation, then wire it into the compile and GIR load paths.

Purpose: Catches compiler bugs before they cause silent corruption or hard-to-debug runtime crashes. Addresses the "high regression risk in core execution paths" concern from CONCERNS.md. The verifier is also a safety prerequisite before any future instruction set changes (plans 4-6). Verification errors emit structured diagnostic envelopes from plan 01.

Output: New src/gene/vm/verifier.nim; compiler.nim and gir.nim call verify_compilation_unit; test_vm_neg.nim has new tests asserting bad bytecode is caught.

Note: Plan 03 depends on plan 01 (wave 2) because it uses make_diagnostic_message for structured error output.
</objective>

<execution_context>
@/Users/gcao/.claude/get-shit-done/workflows/execute-plan.md
@/Users/gcao/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@/Users/gcao/gene-workspace/gene-old/.planning/codebase/ARCHITECTURE.md

<interfaces>
<!-- Key types and contracts the executor needs. Extracted from codebase. -->

From src/gene/types/type_defs.nim (CompilationUnit):
```nim
type
  CompilationUnit* = ref object
    id*: ...
    instructions*: seq[Instruction]
    instruction_traces*: seq[SourceTrace]
    ...
```

From src/gene/types/type_defs.nim (Instruction):
```nim
type
  Instruction* = object
    kind*: InstructionKind
    label*: Label
    arg0*: Value
    arg1*: Value
```

InstructionKind enum (partial, key items for stack model):
- Stack push (+1): IkPushValue, IkPushNil, IkDup, IkDup2 (+2), IkDupSecond, IkOver, IkLen, IkSelf, IkGetMember, IkGetMemberOrNil, IkGetMemberDefault, IkGetChild, IkVarResolve, IkVarValue
- Stack pop (-1): IkPop, IkThrow, IkNeg, IkNot
- Stack neutral (0): IkNoop, IkScopeStart, IkScopeEnd, IkJump, IkLoopStart, IkLoopEnd
- Stack pop 2 push 1 (-1): IkAdd, IkSub, IkMul, IkDiv, IkMod, IkPow, IkLt, IkLe, IkGt, IkGe, IkEq, IkNe, IkAnd, IkOr, IkSetMember, IkSetChild
- Jump instructions: IkJump, IkJumpIfFalse (arg0 is the target Label)
- Terminal instructions: IkReturn, IkReturnNil, IkReturnTrue, IkReturnFalse

From src/gene/types/instructions.nim (find_label):
```nim
proc find_label*(self: CompilationUnit, label: Label): int =
  # returns instruction index for a given label
```

From gene/src/air_verify.nim (reference verifier pattern):
```nim
proc stackDelta(inst: AirInst): int = ...  # +1/-1/0 per instruction
proc verifyJumpTargets(fn, fnIdx, issues) = ...  # checks targets in-bounds
proc verifyStackDepths(fn, fnIdx, issues) = ...  # BFS/linear walk checking depth >= 0
```

From src/gene/compiler.nim (compile_init, the main compile entry point):
```nim
proc compile_init*(code: Value): CompilationUnit = ...
# Called by commands/run.nim, commands/eval.nim, VM thread handler
```

From src/gene/gir.nim (load_gir):
```nim
proc load_gir*(path: string): CompilationUnit = ...
# Called by run command's cache path
```
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Implement verifier.nim with stack-depth and jump-target checks</name>
  <files>src/gene/vm/verifier.nim</files>
  <action>
Create `src/gene/vm/verifier.nim` as a standalone importable module. Both `compiler.nim` and `gir.nim` need to `import` it independently (they are not in the vm.nim include chain), so verifier.nim must be a proper module with its own imports — not relying on being included from vm.nim.

At the top of the file add:
```nim
import ../types
```
Adjust the relative path as needed depending on where verifier.nim sits relative to the types module. Confirm the correct path by checking how other standalone modules under `src/gene/vm/` import types.

**Type definitions:**

```nim
type
  VerifyIssue* = object
    kind*: string       ## Diagnostic code e.g. "GENE.VERIFY.JUMP_TARGET"
    message*: string    ## Human-readable description
    ip*: int            ## Instruction index where issue was found (-1 if unknown)

  VerifyResult* = object
    ok*: bool
    issues*: seq[VerifyIssue]
```

**Stack delta function:**

```nim
proc stack_delta(inst: Instruction): int =
  case inst.kind
  # Stack producers (+1):
  of IkPushValue, IkPushNil, IkDup, IkDupSecond, IkOver, IkLen, IkSelf,
     IkGetMember, IkGetMemberOrNil, IkGetMemberDefault, IkGetChild,
     IkVarResolve, IkVarValue, IkGetLocal, IkResolveSymbol, IkGetClass,
     IkIsInstance, IkTypeOf, IkCreateRange, IkCreateEnum:
    1
  of IkDup2:
    2
  # Stack consumers (-1):
  of IkPop, IkNeg, IkNot:
    -1
  # Binary ops (pop 2, push 1 = net -1):
  of IkAdd, IkAddValue, IkSub, IkSubValue, IkMul, IkDiv, IkMod, IkPow,
     IkLt, IkLtValue, IkLe, IkGt, IkGe, IkEq, IkNe, IkAnd, IkOr,
     IkSetMember, IkSetChild, IkMapSetProp, IkMapSetPropValue:
    -1
  # Var ops: pop 0 push 1:
  of IkVar, IkVarAssign:
    0
  # Control flow: neutral:
  of IkNoop, IkScopeStart, IkScopeEnd, IkJump, IkLoopStart, IkLoopEnd,
     IkContinue, IkBreak, IkReturn, IkReturnNil, IkReturnTrue, IkReturnFalse,
     IkExport, IkImport, IkTryStart, IkTryEnd, IkCatchStart, IkCatchEnd,
     IkFinally, IkFinallyEnd, IkThrow, IkStart, IkEnd:
    0
  # Default: unknown instruction, treat as neutral to avoid false positives:
  else:
    0
```

Note: This is an approximation — IkCall, IkFunction, and complex instructions are hard to model without knowing arity. Treat them as neutral (0) to avoid false positives. The verifier catches only clear-cut stack corruption, not semantic errors.

**Jump target validator:**

```nim
proc verify_jump_targets(cu: CompilationUnit; result: var VerifyResult) =
  for ip, inst in cu.instructions:
    if inst.kind in {IkJump, IkJumpIfFalse, IkContinue, IkBreak}:
      let target_label = inst.arg0.int64.Label
      # find_label raises if not found; catch it
      try:
        let target_ip = cu.find_label(target_label)
        if target_ip < 0 or target_ip >= cu.instructions.len:
          result.issues.add(VerifyIssue(
            kind: "GENE.VERIFY.JUMP_TARGET",
            message: "Jump at ip=" & $ip & " targets out-of-range ip=" & $target_ip,
            ip: ip
          ))
      except:
        result.issues.add(VerifyIssue(
          kind: "GENE.VERIFY.JUMP_LABEL_MISSING",
          message: "Jump at ip=" & $ip & " references unknown label",
          ip: ip
        ))
```

**Stack depth validator (linear walk, no full CFG):**

```nim
proc verify_stack_depths(cu: CompilationUnit; result: var VerifyResult) =
  var depth = 0
  for ip, inst in cu.instructions:
    let delta = stack_delta(inst)
    depth += delta
    if depth < 0:
      result.issues.add(VerifyIssue(
        kind: "GENE.VERIFY.STACK_UNDERFLOW",
        message: "Stack depth went negative (" & $depth & ") at ip=" & $ip & " (" & $inst.kind & ")",
        ip: ip
      ))
      depth = 0  # reset to continue checking remainder
```

Note: A linear walk does not model all control flow paths (joins after jumps). This catches obvious underflows. A full CFG analysis can be added later as the instruction set stabilizes. Accept false negatives in exchange for no false positives.

**Main entry point:**

```nim
proc verify_compilation_unit*(cu: CompilationUnit): VerifyResult =
  result.ok = true
  result.issues = @[]
  if cu.isNil or cu.instructions.len == 0:
    return
  verify_jump_targets(cu, result)
  verify_stack_depths(cu, result)
  result.ok = result.issues.len == 0
```
  </action>
  <verify>nim c --mm:orc -c src/gene/vm/verifier.nim 2>&1 | head -20</verify>
  <done>verifier.nim compiles cleanly as a standalone module; exports VerifyResult and verify_compilation_unit.</done>
</task>

<task type="auto">
  <name>Task 2: Wire verifier into compiler and GIR load, add negative tests</name>
  <files>
    src/gene/compiler.nim
    src/gene/gir.nim
    tests/test_vm_neg.nim
  </files>
  <action>
**Step 1: Wire verifier into compiler.nim.**

Find `proc compile_init` in `src/gene/compiler.nim`. After it produces the `CompilationUnit` and before returning it, add a verification step:

```nim
import ./vm/verifier  # add to imports at top of compiler.nim

# At the end of compile_init, before return:
when not defined(GENE_NO_VERIFY):
  let vr = verify_compilation_unit(cu)
  if not vr.ok:
    var diag_parts: seq[string]
    for issue in vr.issues:
      diag_parts.add(issue.kind & ": " & issue.message)
    raise new_exception(types.Exception,
      make_diagnostic_message(
        "GENE.VERIFY.FAILED",
        "Bytecode verification failed: " & diag_parts.join("; "),
        stage = "compile"
      )
    )
```

Note: `make_diagnostic_message` comes from diagnostics.nim (plan 01, which is a prerequisite — depends_on: ["01"]). The `when not defined(GENE_NO_VERIFY)` guard allows disabling verification in tests that intentionally produce bad bytecode for other reasons.

**Step 2: Wire verifier into gir.nim.**

Find `proc load_gir` in `src/gene/gir.nim`. After the CompilationUnit is deserialized and before returning, add:

```nim
import ./vm/verifier  # add to imports at top of gir.nim

# At end of load_gir, before return:
when not defined(GENE_NO_VERIFY):
  let vr = verify_compilation_unit(result)
  if not vr.ok:
    var msg_parts: seq[string]
    for issue in vr.issues:
      msg_parts.add(issue.kind & ": " & issue.message)
    raise new_exception(types.Exception,
      "GIR verification failed (file: " & path & "): " & msg_parts.join("; ")
    )
```

This ensures stale or corrupt GIR files are caught before execution.

**Step 3: Add tests to tests/test_vm_neg.nim.**

Open `tests/test_vm_neg.nim` (it already exists - check its current contents first).

Add tests that:
1. Build a `CompilationUnit` manually with a known bad jump target and verify the verifier catches it:

```nim
import std/json
import ../src/gene/types except Exception
import ../src/gene/vm
import ../src/gene/vm/verifier

test "verifier catches out-of-range jump target":
  let cu = new_compilation_unit()
  # Add a jump instruction pointing to label 9999 (no such label)
  let label = 9999.Label
  cu.instructions.add(new_instr(IkJump, label.to_value()))
  cu.instructions.add(new_instr(IkEnd))
  let vr = verify_compilation_unit(cu)
  check not vr.ok
  check vr.issues.len > 0
  check vr.issues[0].kind.contains("GENE.VERIFY")

test "verifier passes for valid empty compilation unit":
  let cu = new_compilation_unit()
  cu.instructions.add(new_instr(IkStart))
  cu.instructions.add(new_instr(IkPushNil))
  cu.instructions.add(new_instr(IkReturn))
  cu.instructions.add(new_instr(IkEnd))
  let vr = verify_compilation_unit(cu)
  check vr.ok

test "verifier catches stack underflow":
  let cu = new_compilation_unit()
  cu.instructions.add(new_instr(IkStart))
  # Pop with nothing on stack
  cu.instructions.add(new_instr(IkPop))
  cu.instructions.add(new_instr(IkEnd))
  let vr = verify_compilation_unit(cu)
  check not vr.ok
  check vr.issues.len > 0
  check vr.issues[0].kind == "GENE.VERIFY.STACK_UNDERFLOW"
```

Adjust the test helpers as needed. Check whether `new_compilation_unit`, `new_instr`, and `Label` are accessible from the test. Look at how `tests/test_opcode_dispatch.nim` builds compilation units manually for reference.

**Step 4: Add test_vm_neg.nim to gene.nimble test task.**

Open `gene.nimble` and add:
```nim
exec "nim c -r tests/test_vm_neg.nim"
```
to the `task test` block (before the end).

**Step 5: Full test suite regression check.**

Run `nim c -r tests/test_basic.nim` to confirm compilation still works for valid programs. If the verifier triggers false positives on valid programs, add the offending instruction kinds to the neutral (0 delta) list in verifier.nim.
  </action>
  <verify>nim c -r tests/test_vm_neg.nim 2>&1 | tail -20</verify>
  <done>
    - test_vm_neg.nim passes with all three new verifier tests
    - nim c -r tests/test_basic.nim passes (no false positives from verifier on valid programs)
    - verify_compilation_unit is called from compiler.nim and gir.nim
    - gene.nimble test task includes test_vm_neg.nim
  </done>
</task>

</tasks>

<verification>
Run from /Users/gcao/gene-workspace/gene-old:
1. `nim c -r tests/test_vm_neg.nim` - All 3 new verifier tests pass
2. `nim c -r tests/test_basic.nim` - No regressions (verifier passes valid programs)
3. `nim c -r tests/test_exception.nim` - No regressions
4. `nim c -r tests/test_cli_gir.nim` - GIR load path still works (verifier passes cached GIR)
5. `grep -n "verify_compilation_unit" src/gene/compiler.nim` - Shows wire-in location
6. `grep -n "verify_compilation_unit" src/gene/gir.nim` - Shows wire-in location
</verification>

<success_criteria>
- verifier.nim exists with verify_compilation_unit, VerifyResult, VerifyIssue
- stack_delta covers all key InstructionKind values with 0 as safe default for unknowns
- Bad jump targets (unknown labels) are caught with GENE.VERIFY.JUMP_LABEL_MISSING
- Stack underflow paths are caught with GENE.VERIFY.STACK_UNDERFLOW
- compiler.nim calls verify_compilation_unit after compilation (wrapped in when not defined(GENE_NO_VERIFY))
- gir.nim calls verify_compilation_unit after load_gir
- test_vm_neg.nim has passing tests for each check type
- test_basic.nim passes without false positive verification failures
</success_criteria>

<output>
After completion, create `/Users/gcao/gene-workspace/gene-old/.planning/phases/01-architecture-comparison/01-03-SUMMARY.md`
</output>

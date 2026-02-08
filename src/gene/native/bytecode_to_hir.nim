## Bytecode to HIR Conversion
##
## Converts Gene bytecode (CompilationUnit) to HIR for native code generation.
## Currently focused on typed functions like fib(n: Int) -> Int.
##
## Strategy:
## 1. Simulate bytecode execution on an abstract stack
## 2. Track which HIR register holds each stack slot
## 3. Convert each bytecode instruction to equivalent HIR operations
## 4. Handle control flow by creating basic blocks at branch targets

import std/[tables, strformat, strutils, sequtils]
import ../types
import ../types/core
import ./hir
import ./trampoline

type
  ## Tracks the abstract stack during conversion
  StackSlot = object
    reg: HirReg
    typ: HirType
    fnName: string
    callable: Value

  ## Conversion context
  ConversionContext = ref object
    builder: HirBuilder
    cu: CompilationUnit
    fn: Function
    fnName: string
    paramTypes: seq[tuple[name: string, typ: HirType]]
    returnType: HirType
    ns: Namespace
    scopeTracker: ScopeTracker

    # Map variable index -> HIR type (from parameter annotations)
    varTypes: Table[int32, HirType]

    # Abstract stack simulation
    stack: seq[StackSlot]

    # Map bytecode PC -> HIR block (for jump targets)
    pcToBlock: Table[int, HirBlockId]

    # Track which blocks we've already emitted
    emittedBlocks: Table[int, bool]

    # Pending blocks to process (PC values)
    pendingBlocks: seq[int]

    # Call descriptor table (deduplicated)
    descriptors: seq[CallDescriptor]
    descriptorMap: Table[string, int32]

# ==================== Type Mapping ====================

proc typeIdToHir(tid: TypeId): HirType =
  ## Convert TypeId to HIR type
  case tid
  of BUILTIN_TYPE_INT_ID: HtI64
  of BUILTIN_TYPE_FLOAT_ID: HtF64
  of BUILTIN_TYPE_BOOL_ID: HtBool
  else: HtValue

proc typeIdToCallArg(tid: TypeId, outType: var CallArgType): bool =
  case tid
  of BUILTIN_TYPE_INT_ID:
    outType = CatInt64
    return true
  of BUILTIN_TYPE_FLOAT_ID:
    outType = CatFloat64
    return true
  else:
    return false

proc typeIdToCallReturn(tid: TypeId, outType: var CallReturnType): bool =
  case tid
  of BUILTIN_TYPE_INT_ID:
    outType = CrtInt64
    return true
  of BUILTIN_TYPE_FLOAT_ID:
    outType = CrtFloat64
    return true
  else:
    return false

proc signatureFromMatcher(matcher: RootMatcher, dropFirst: bool,
                           argTypes: var seq[CallArgType],
                           returnType: var CallReturnType): bool =
  if matcher.is_nil or not matcher.has_type_annotations:
    return false
  if matcher.return_type_id == NO_TYPE_ID:
    return false
  let start = if dropFirst: 1 else: 0
  if dropFirst and matcher.children.len == 0:
    return false
  for i in start..<matcher.children.len:
    let param = matcher.children[i]
    if param.type_id == NO_TYPE_ID:
      return false
    var argType: CallArgType
    if not typeIdToCallArg(param.type_id, argType):
      return false
    argTypes.add(argType)
  if not typeIdToCallReturn(matcher.return_type_id, returnType):
    return false
  true

proc callableSignature(callable: Value,
                       argTypes: var seq[CallArgType],
                       returnType: var CallReturnType): bool =
  case callable.kind
  of VkFunction:
    let f = callable.ref.fn
    return signatureFromMatcher(f.matcher, false, argTypes, returnType)
  of VkBoundMethod:
    let bm = callable.ref.bound_method
    let target = bm.method.callable
    case target.kind
    of VkFunction:
      let f = target.ref.fn
      return signatureFromMatcher(f.matcher, true, argTypes, returnType)
    of VkNativeFn:
      var sig: NativeFnSig
      if not lookup_native_sig(target.ref.native_fn, sig):
        return false
      if sig.argTypes.len == 0:
        return false
      for i in 1..<sig.argTypes.len:
        argTypes.add(sig.argTypes[i])
      returnType = sig.returnType
      return true
    else:
      return false
  of VkNativeFn:
    var sig: NativeFnSig
    if not lookup_native_sig(callable.ref.native_fn, sig):
      return false
    argTypes = sig.argTypes
    returnType = sig.returnType
    return true
  else:
    return false

proc descriptorKey(callable: Value, argTypes: seq[CallArgType], returnType: CallReturnType): string =
  result = $(cast[uint64](callable)) & ":" & $returnType & ":"
  for t in argTypes:
    result &= $t & ","

proc getDescriptorIndex(ctx: ConversionContext, callable: Value,
                         argTypes: seq[CallArgType], returnType: CallReturnType): int32 =
  let key = descriptorKey(callable, argTypes, returnType)
  if key in ctx.descriptorMap:
    return ctx.descriptorMap[key]
  let idx = ctx.descriptors.len.int32
  ctx.descriptors.add(CallDescriptor(callable: callable, argTypes: argTypes, returnType: returnType))
  retain(callable)
  ctx.descriptorMap[key] = idx
  idx

# ==================== Stack Operations ====================

proc push(ctx: ConversionContext, reg: HirReg, typ: HirType, fnName: string = "", callable: Value = NIL) =
  ctx.stack.add(StackSlot(reg: reg, typ: typ, fnName: fnName, callable: callable))

proc pop(ctx: ConversionContext): StackSlot =
  if ctx.stack.len == 0:
    raise newException(ValueError, "Stack underflow during HIR conversion")
  result = ctx.stack.pop()

proc peek(ctx: ConversionContext): StackSlot =
  if ctx.stack.len == 0:
    raise newException(ValueError, "Stack empty during HIR conversion")
  result = ctx.stack[^1]

proc resolveSymbol(ctx: ConversionContext, name: string): Value =
  let key = name.to_key()
  if ctx.scopeTracker != nil:
    let found = ctx.scopeTracker.locate(key)
    if found.local_index >= 0:
      return NIL
  if ctx.ns != nil and ctx.ns.members.hasKey(key):
    return ctx.ns.members[key]
  NIL

proc inheritedVarName(tracker: ScopeTracker, parentDepth: int32, index: int32): string =
  var scope = tracker
  var depth = parentDepth
  while depth > 0 and scope != nil:
    scope = scope.parent
    depth.dec()
  if scope == nil:
    return ""
  for key, idx in scope.mappings:
    if idx == index.int16:
      return get_symbol(key.symbol_index)
  ""

# ==================== Block Management ====================

proc getOrCreateBlock(ctx: ConversionContext, pc: int, name: string): HirBlockId =
  if pc in ctx.pcToBlock:
    return ctx.pcToBlock[pc]
  let blockId = ctx.builder.newBlock(name)
  ctx.pcToBlock[pc] = blockId
  result = blockId

proc scheduleBlock(ctx: ConversionContext, pc: int) =
  if pc notin ctx.emittedBlocks:
    ctx.pendingBlocks.add(pc)

# ==================== Type-aware Helpers ====================

proc varType(ctx: ConversionContext, varIdx: int32): HirType =
  ## Look up the HIR type of a variable by index
  if ctx.varTypes.hasKey(varIdx):
    return ctx.varTypes[varIdx]
  HtI64  # fallback

proc emitConst(ctx: ConversionContext, val: Value, typ: HirType): HirReg =
  ## Emit a constant matching the expected type
  case typ
  of HtF64:
    ctx.builder.emitConstF64(val.to_float())
  else:
    ctx.builder.emitConstI64(val.to_int())

proc emitAdd(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitAddF64(left, right)
  else: ctx.builder.emitAddI64(left, right)

proc emitSub(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitSubF64(left, right)
  else: ctx.builder.emitSubI64(left, right)

proc emitMul(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitMulF64(left, right)
  else: ctx.builder.emitMulI64(left, right)

proc emitDiv(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitDivF64(left, right)
  else: ctx.builder.emitDivI64(left, right)

proc emitNeg(ctx: ConversionContext, value: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitNegF64(value)
  else: ctx.builder.emitNegI64(value)

proc emitLe(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitLeF64(left, right)
  else: ctx.builder.emitLeI64(left, right)

proc emitLt(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitLtF64(left, right)
  else: ctx.builder.emitLtI64(left, right)

proc emitGt(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitGtF64(left, right)
  else: ctx.builder.emitGtI64(left, right)

proc emitGe(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitGeF64(left, right)
  else: ctx.builder.emitGeI64(left, right)

proc emitEq(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitEqF64(left, right)
  else: ctx.builder.emitEqI64(left, right)

proc emitNe(ctx: ConversionContext, left, right: HirReg, typ: HirType): HirReg =
  if typ == HtF64: ctx.builder.emitNeF64(left, right)
  else: ctx.builder.emitNeI64(left, right)

proc emitCall(ctx: ConversionContext, fnSlot: StackSlot, args: seq[StackSlot]) =
  if fnSlot.fnName.len > 0 and fnSlot.fnName == ctx.fnName:
    let regs = args.mapIt(it.reg)
    let resultReg = ctx.builder.emitCall(fnSlot.fnName, regs, ctx.returnType)
    ctx.push(resultReg, ctx.returnType)
    return

  var callable = fnSlot.callable
  if callable == NIL and fnSlot.fnName.len > 0:
    callable = ctx.resolveSymbol(fnSlot.fnName)
  if callable == NIL:
    raise newException(ValueError, "Unresolvable call target: " & fnSlot.fnName)

  var argTypes: seq[CallArgType] = @[]
  var returnType: CallReturnType
  if not callableSignature(callable, argTypes, returnType):
    raise newException(ValueError, "Call target not eligible for native call: " & $callable.kind)
  if argTypes.len != args.len:
    raise newException(ValueError, "Argument count mismatch for native call")
  for i in 0..<args.len:
    case argTypes[i]
    of CatInt64:
      if args[i].typ != HtI64:
        raise newException(ValueError, "Argument type mismatch for native call")
    of CatFloat64:
      if args[i].typ != HtF64:
        raise newException(ValueError, "Argument type mismatch for native call")

  let retType = case returnType
    of CrtFloat64: HtF64
    of CrtInt64: HtI64
    of CrtValue: HtValue
  let descIdx = ctx.getDescriptorIndex(callable, argTypes, returnType)
  let resultReg = ctx.builder.emitCallVM(descIdx, args.mapIt(it.reg), retType)
  ctx.push(resultReg, retType)

# ==================== Instruction Conversion ====================

proc convertInstruction(ctx: ConversionContext, pc: var int): bool =
  ## Convert one bytecode instruction. Returns false if block ends.
  let inst = ctx.cu.instructions[pc]

  case inst.kind
  of IkStart:
    discard

  of IkJumpIfMatchSuccess:
    let target = inst.arg1.int
    pc = target - 1

  of IkThrow:
    discard

  of IkVarAddValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitAdd(paramReg, constReg, vt)
    ctx.push(resultReg, vt)
    pc += 1

  of IkVarLeValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitLe(paramReg, constReg, vt)
    ctx.push(resultReg, HtBool)
    pc += 1

  of IkVarLtValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitLt(paramReg, constReg, vt)
    ctx.push(resultReg, HtBool)
    pc += 1

  of IkVarGtValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitGt(paramReg, constReg, vt)
    ctx.push(resultReg, HtBool)
    pc += 1

  of IkVarGeValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitGe(paramReg, constReg, vt)
    ctx.push(resultReg, HtBool)
    pc += 1

  of IkVarEqValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitEq(paramReg, constReg, vt)
    ctx.push(resultReg, HtBool)
    pc += 1

  of IkVarSubValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitSub(paramReg, constReg, vt)
    ctx.push(resultReg, vt)
    pc += 1

  of IkVarMulValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitMul(paramReg, constReg, vt)
    ctx.push(resultReg, vt)
    pc += 1

  of IkVarDivValue:
    let varIdx = inst.arg0.int64.int
    let dataInst = ctx.cu.instructions[pc + 1]
    let vt = ctx.varType(varIdx.int32)
    let paramReg = newHirReg(varIdx.int32)
    let constReg = ctx.emitConst(dataInst.arg0, vt)
    let resultReg = ctx.emitDiv(paramReg, constReg, vt)
    ctx.push(resultReg, vt)
    pc += 1

  of IkData:
    discard

  of IkJumpIfFalse:
    let target = inst.arg0.int64.int
    let cond = ctx.pop()
    let thenBlock = ctx.getOrCreateBlock(pc + 1, fmt"then_{pc + 1}")
    let elseBlock = ctx.getOrCreateBlock(target, fmt"else_{target}")
    ctx.builder.emitBr(cond.reg, thenBlock, elseBlock)
    ctx.scheduleBlock(pc + 1)
    ctx.scheduleBlock(target)
    return false

  of IkVarResolve:
    let varIdx = inst.arg0.int64.int
    let paramReg = newHirReg(varIdx.int32)
    let vt = ctx.varType(varIdx.int32)
    ctx.push(paramReg, vt)

  of IkVarResolveInherited:
    let varIdx = inst.arg0.int64.int32
    let parentDepth = inst.arg1.int32
    let name = inheritedVarName(ctx.scopeTracker, parentDepth, varIdx)
    if name.len == 0:
      raise newException(ValueError, "Unresolvable inherited variable")
    if name == ctx.fnName:
      ctx.push(newHirReg(-1), HtValue, name)
    else:
      raise newException(ValueError, "Unsupported inherited variable access: " & name)

  of IkJump:
    let target = inst.arg0.int64.int
    let targetBlock = ctx.getOrCreateBlock(target, fmt"block_{target}")
    ctx.builder.emitJump(targetBlock)
    ctx.scheduleBlock(target)
    return false

  of IkResolveSymbol:
    let name = inst.arg0.str
    let callable = ctx.resolveSymbol(name)
    ctx.push(newHirReg(-1), HtValue, name, callable)

  of IkUnifiedCall0:
    let fnSlot = ctx.pop()
    ctx.emitCall(fnSlot, @[])

  of IkUnifiedCall1:
    let arg = ctx.pop()
    let fnSlot = ctx.pop()
    ctx.emitCall(fnSlot, @[arg])

  of IkUnifiedCall:
    let count = inst.arg1.int
    var args = newSeq[StackSlot](count)
    for i in countdown(count - 1, 0):
      args[i] = ctx.pop()
    let fnSlot = ctx.pop()
    ctx.emitCall(fnSlot, args)

  of IkAdd:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitAdd(left.reg, right.reg, t)
    ctx.push(resultReg, t)

  of IkAddValue:
    let left = ctx.pop()
    let t = left.typ
    let constReg = ctx.emitConst(inst.arg0, t)
    let resultReg = ctx.emitAdd(left.reg, constReg, t)
    ctx.push(resultReg, t)

  of IkSub:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitSub(left.reg, right.reg, t)
    ctx.push(resultReg, t)

  of IkSubValue:
    let left = ctx.pop()
    let t = left.typ
    let constReg = ctx.emitConst(inst.arg0, t)
    let resultReg = ctx.emitSub(left.reg, constReg, t)
    ctx.push(resultReg, t)

  of IkMul:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitMul(left.reg, right.reg, t)
    ctx.push(resultReg, t)

  of IkDiv:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitDiv(left.reg, right.reg, t)
    ctx.push(resultReg, t)

  of IkNeg:
    let value = ctx.pop()
    let resultReg = ctx.emitNeg(value.reg, value.typ)
    ctx.push(resultReg, value.typ)

  of IkLt:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitLt(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkLtValue:
    let left = ctx.pop()
    let t = left.typ
    let constReg = ctx.emitConst(inst.arg0, t)
    let resultReg = ctx.emitLt(left.reg, constReg, t)
    ctx.push(resultReg, HtBool)

  of IkLe:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitLe(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkGt:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitGt(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkGe:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitGe(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkEq:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitEq(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkNe:
    let right = ctx.pop()
    let left = ctx.pop()
    let t = if left.typ == HtF64 or right.typ == HtF64: HtF64 else: HtI64
    let resultReg = ctx.emitNe(left.reg, right.reg, t)
    ctx.push(resultReg, HtBool)

  of IkPop:
    if ctx.stack.len > 0:
      discard ctx.pop()

  of IkPushValue:
    let val = inst.arg0
    if val.kind == VkInt:
      let constReg = ctx.builder.emitConstI64(val.to_int())
      ctx.push(constReg, HtI64)
    elif val.kind == VkFloat:
      let constReg = ctx.builder.emitConstF64(val.to_float())
      ctx.push(constReg, HtF64)
    elif val == NIL:
      let constReg = ctx.builder.emitConstI64(0)
      ctx.push(constReg, HtI64)
    else:
      ctx.push(newHirReg(-1), HtValue)

  of IkScopeEnd:
    discard

  of IkEnd:
    if ctx.stack.len > 0:
      let retVal = ctx.pop()
      ctx.builder.emitRet(retVal.reg)
    return false

  else:
    raise newException(ValueError, fmt"Unsupported bytecode instruction: {inst.kind}")

  result = true

# ==================== Block Processing ====================

proc processBlock(ctx: ConversionContext, startPc: int) =
  ## Process a basic block starting at the given PC
  if startPc in ctx.emittedBlocks:
    return
  ctx.emittedBlocks[startPc] = true

  # Get or create the block
  let blockId = ctx.getOrCreateBlock(startPc, fmt"block_{startPc}")
  ctx.builder.setCurrentBlock(blockId)

  var pc = startPc
  while pc < ctx.cu.instructions.len:
    if not ctx.convertInstruction(pc):
      break  # Block ended (branch, jump, or return)
    pc += 1

# ==================== Main Conversion ====================

proc extractFunctionInfo(cu: CompilationUnit): tuple[name: string, params: seq[tuple[name: string, typ: HirType]], retType: HirType] =
  ## Extract function name and parameter types from CompilationUnit
  result.name = "unknown"
  result.params = @[]
  result.retType = HtI64  # Default to Int

  if cu.matcher != nil:
    # Use explicit return type annotation if available
    if cu.matcher.return_type_id != NO_TYPE_ID:
      result.retType = typeIdToHir(cu.matcher.return_type_id)

    for child in cu.matcher.children:
      let paramName = cast[Value](child.name_key).str()
      let paramType = if child.type_id != NO_TYPE_ID:
        typeIdToHir(child.type_id)
      else:
        HtValue
      result.params.add((name: paramName, typ: paramType))

    # If no explicit return type, infer from parameter types
    # (all-float params → float return; otherwise int)
    if cu.matcher.return_type_id == NO_TYPE_ID and result.params.len > 0:
      var allFloat = true
      for p in result.params:
        if p.typ != HtF64:
          allFloat = false
          break
      if allFloat:
        result.retType = HtF64

proc isNativeEligible*(cu: CompilationUnit, fn: Function): bool

proc bytecodeToHir*(cu: CompilationUnit, fn: Function): HirFunction =
  ## Convert a CompilationUnit to HIR
  ##
  ## Parameters:
  ##   cu: The compiled bytecode
  ##   fnName: Function name (for recursive calls)
  ##
  ## Returns:
  ##   HirFunction ready for native code generation

  let info = extractFunctionInfo(cu)
  let actualName = if fn != nil and fn.name.len > 0: fn.name else: info.name

  # Determine return type (default to Int for now)
  let returnType = info.retType

  # Create builder
  let builder = newHirBuilder(actualName, returnType)

  # Add parameters
  for param in info.params:
    discard builder.addParam(param.name, param.typ)

  # Build variable type map from parameters
  var varTypes = initTable[int32, HirType]()
  for i, param in info.params:
    varTypes[i.int32] = param.typ

  # Create conversion context
  let ctx = ConversionContext(
    builder: builder,
    cu: cu,
    fn: fn,
    fnName: actualName,
    paramTypes: info.params,
    returnType: returnType,
    ns: if fn != nil: fn.ns else: nil,
    scopeTracker: if fn != nil: fn.scope_tracker else: nil,
    varTypes: varTypes,
    stack: @[],
    pcToBlock: initTable[int, HirBlockId](),
    emittedBlocks: initTable[int, bool](),
    pendingBlocks: @[],
    descriptors: @[],
    descriptorMap: initTable[string, int32]()
  )

  # Create entry block and start processing
  let entryBlock = builder.newBlock("entry")
  ctx.pcToBlock[0] = entryBlock
  ctx.pendingBlocks.add(0)

  # Process all reachable blocks
  while ctx.pendingBlocks.len > 0:
    let pc = ctx.pendingBlocks.pop()
    ctx.processBlock(pc)

  result = builder.finalize()
  result.isNativeEligible = true
  result.callDescriptors = ctx.descriptors

# ==================== Eligibility Check ====================

proc isNativeEligible*(cu: CompilationUnit, fn: Function): bool =
  ## Check if a CompilationUnit can be converted to native code
  ## Requires:
  ## - All parameters have type annotations
  ## - Types are primitive (Int or Float)

  if cu.matcher == nil:
    return false

  if not cu.matcher.has_type_annotations:
    return false

  for child in cu.matcher.children:
    if child.type_id == NO_TYPE_ID:
      return false
    let hirType = typeIdToHir(child.type_id)
    if hirType notin {HtI64, HtF64}:
      return false  # Non-primitive type

  for inst in cu.instructions:
    case inst.kind
    of IkVarResolve, IkVarAddValue, IkVarSubValue, IkVarMulValue, IkVarDivValue,
         IkVarLtValue, IkVarLeValue, IkVarGtValue, IkVarGeValue, IkVarEqValue:
      if inst.arg1.int64 != 0:
        return false
    of IkVarResolveInherited:
      if fn == nil or fn.scope_tracker == nil or fn.name.len == 0:
        return false
      let varIdx = inst.arg0.int64.int32
      let parentDepth = inst.arg1.int32
      let name = inheritedVarName(fn.scope_tracker, parentDepth, varIdx)
      if name.len == 0 or name != fn.name:
        return false
    of IkAddValue, IkSubValue, IkLtValue:
      if inst.arg0.kind notin {VkInt, VkFloat}:
        return false
    of IkPushValue:
      if inst.arg0.kind notin {VkInt, VkFloat}:
        return false
    of IkData:
      if inst.arg0.kind notin {VkInt, VkFloat}:
        return false
    of IkResolveSymbol, IkUnifiedCall0, IkUnifiedCall1, IkUnifiedCall:
      discard
    of IkStart, IkJumpIfFalse, IkJump, IkJumpIfMatchSuccess,
       IkAdd, IkSub, IkMul, IkDiv, IkNeg,
       IkLt, IkLe, IkGt, IkGe, IkEq, IkNe,
       IkPop, IkScopeEnd, IkEnd, IkReturn, IkThrow:
      discard
    else:
      return false

  # Ensure call targets are resolvable and typed
  try:
    let hir = bytecodeToHir(cu, fn)
    release_descriptors(hir.callDescriptors)
  except CatchableError:
    return false
  return true

proc isNativeEligible*(cu: CompilationUnit, fnName: string = ""): bool =
  var stub: Function = nil
  if cu.matcher != nil:
    stub = Function(name: fnName, matcher: cu.matcher)
  return isNativeEligible(cu, stub)

proc bytecodeToHir*(cu: CompilationUnit, fnName: string = "fn"): HirFunction =
  var stub: Function = nil
  if cu.matcher != nil:
    stub = Function(name: fnName, matcher: cu.matcher)
  result = bytecodeToHir(cu, stub)

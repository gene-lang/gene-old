import std/[sets]
import ./ir

type
  AirVerifyError* = object of CatchableError

proc isJumpLike(op: AirOpcode): bool =
  op in {OpJump, OpBrTrue, OpBrFalse}

proc stackDelta(inst: AirInst): int =
  case inst.op
  of OpNop, OpTryBegin, OpTryEnd, OpCatchBegin, OpCatchEnd, OpFinallyBegin, OpFinallyEnd,
     OpArrEnd, OpMapEnd, OpGeneEnd, OpClassExtends, OpCapEnter, OpCapExit, OpCheckpointHint,
     OpNsEnter, OpNsExit, OpJump, OpDetSeed, OpTraceEmit, OpAuditEmit, OpDiagEmit,
     OpCallerEval, OpRangeNew, OpEnumNew, OpEnumAdd, OpAsyncBegin, OpCapAssert:
    0

  of OpConst, OpConstNil, OpConstTrue, OpConstFalse, OpDup, OpOver, OpLoadLocal, OpLoadUpvalue,
     OpLoadGlobal, OpLoadSelf, OpLoadSuper, OpFnNew, OpClosureNew, OpFutureWrap, OpAwait,
     OpResume, OpArrNew, OpMapNew, OpGeneNew, OpClassNew, OpImport, OpGetMember, OpGetMemberNil,
     OpGetChild, OpTypeof, OpIsType, OpIterInit, OpToolPrep, OpDetRand, OpDetNow, OpTaskScopeEnter:
    1

  of OpPop, OpThrow, OpRethrow, OpNeg, OpLogNot:
    -1
  of OpSwap, OpStateSave, OpStateRestore, OpTaskJoin, OpTaskCancel, OpIterHasNext, OpIterNext,
     OpAsyncEnd, OpBrTrue, OpBrFalse, OpYield:
    0
  of OpStoreLocal, OpStoreUpvalue, OpStoreGlobal:
    0
  of OpAdd, OpSub, OpMul, OpDiv, OpMod, OpPow, OpCmpEq, OpCmpNe, OpCmpLt, OpCmpLe, OpCmpGt,
     OpCmpGe, OpLogAnd, OpLogOr, OpSetMember, OpMapSet, OpMapSetDynamic, OpGeneSetType,
     OpGeneSetProp, OpGeneSetPropDynamic, OpGeneAddChild, OpQuotaSet, OpQuotaCheck, OpTaskDeadline,
     OpGetMemberDefault, OpGetMemberDynamic, OpGetChildDynamic:
    -1
  of OpMapSpread, OpArrSpread, OpGeneAddSpread:
    -1
  of OpSetMemberDynamic:
    -2

  of OpCall, OpCallDynamic, OpTailCall, OpCallMacro:
    -int(inst.c)
  of OpCallKw:
    -int(inst.c) - 1
  of OpCallMethod:
    -int(inst.c)
  of OpCallMethodKw:
    -int(inst.c) - 1
  of OpCallSuper:
    1 - int(inst.c)
  of OpCallSuperKw:
    -int(inst.c)
  of OpThreadSpawn, OpTaskSpawn:
    -int(inst.c)
  of OpToolCall:
    -1
  of OpToolAwait, OpToolResultUnwrap, OpToolRetry:
    0

  of OpReturn:
    0

  of OpMethodDef, OpCtorDef, OpPropDef, OpDecoratorApply, OpInterceptEnter, OpInterceptExit:
    0

  of OpExport, OpHalt:
    0
  else:
    0

proc verifyJumpTargets(fn: AirFunction; fnIdx: int; issues: var seq[string]) =
  for ip, inst in fn.code:
    if isJumpLike(inst.op):
      let tgt = int(inst.b)
      if tgt < 0 or tgt >= fn.code.len:
        issues.add("AIR.VERIFY.JUMP_TARGET: fn=" & $fnIdx & " ip=" & $ip & " target=" & $tgt)
    elif inst.op == OpTryBegin:
      let catchIp = int(inst.b)
      if catchIp < 0 or catchIp >= fn.code.len:
        issues.add("AIR.VERIFY.TRY_TARGET: fn=" & $fnIdx & " ip=" & $ip & " target=" & $catchIp)

proc verifyStackEffects(fn: AirFunction; fnIdx: int; issues: var seq[string]) =
  if fn.code.len == 0:
    return
  for inst in fn.code:
    if inst.op in {OpTryBegin, OpTryEnd, OpCatchBegin, OpCatchEnd, OpFinallyBegin, OpFinallyEnd, OpThrow, OpRethrow}:
      # Exception edges need full handler-aware dataflow; defer for now.
      return

  var seen = initHashSet[string]()
  var queue: seq[tuple[pc: int, depth: int]] = @[(0, 0)]

  while queue.len > 0:
    let state = queue[^1]
    queue.setLen(queue.len - 1)
    let pc = state.pc
    let inDepth = state.depth
    let sig = $pc & ":" & $inDepth
    if sig in seen:
      continue
    seen.incl(sig)

    let inst = fn.code[pc]
    let outDepth = inDepth + stackDelta(inst)
    if outDepth < 0:
      issues.add("AIR.VERIFY.STACK_UNDERFLOW: fn=" & $fnIdx & " ip=" & $pc)
      continue

    var succs: seq[int] = @[]
    case inst.op
    of OpJump:
      succs.add(int(inst.b))
    of OpBrTrue, OpBrFalse:
      succs.add(int(inst.b))
      if pc + 1 < fn.code.len:
        succs.add(pc + 1)
    of OpReturn, OpThrow, OpRethrow, OpHalt:
      discard
    else:
      if pc + 1 < fn.code.len:
        succs.add(pc + 1)

    for s in succs:
      if s < 0 or s >= fn.code.len:
        issues.add("AIR.VERIFY.CFG_TARGET: fn=" & $fnIdx & " ip=" & $pc & " target=" & $s)
        continue
      if outDepth > fn.code.len * 8:
        # Avoid runaway depth growth on malformed loops.
        continue
      queue.add((s, outDepth))

proc verifyCapabilitySafety(m: AirModule; issues: var seq[string]) =
  for fnIdx, fn in m.functions:
    for ip, inst in fn.code:
      case inst.op
      of OpCapEnter:
        let idx = int(inst.b)
        if idx < 0 or idx >= m.effects.len:
          issues.add("AIR.VERIFY.CAP_EFFECT_INDEX: fn=" & $fnIdx & " ip=" & $ip & " effect=" & $idx)
      of OpToolPrep:
        let idx = int(inst.b)
        if idx < 0 or idx >= m.toolSchemas.len:
          issues.add("AIR.VERIFY.TOOL_SCHEMA_INDEX: fn=" & $fnIdx & " ip=" & $ip & " schema=" & $idx)
      else:
        discard

proc verifyAirModule*(m: AirModule): seq[string] =
  if m == nil:
    result.add("AIR.VERIFY.MODULE_NIL")
    return
  for i, fn in m.functions:
    verifyJumpTargets(fn, i, result)
    verifyStackEffects(fn, i, result)
  verifyCapabilitySafety(m, result)

proc requireValidAirModule*(m: AirModule) =
  let issues = verifyAirModule(m)
  if issues.len == 0:
    return
  raise newException(AirVerifyError, issues[0])

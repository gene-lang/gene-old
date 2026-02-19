import std/[tables, strutils, times, math, sets]
import ./types
import ./ir

type
  VmRuntimeError* = object of CatchableError

  VmThrow* = ref object of CatchableError
    value*: Value

  NativeProc* = proc(args: seq[Value]): Value {.nimcall.}

  NativeEntry* = object
    name*: string
    arity*: int
    caps*: seq[string]
    isMacro*: bool
    callback*: NativeProc

  ExceptionHandler = object
    catchIp: int
    stackDepth: int

  FrameCtx = object
    fnMeta: AirFunction
    fnObj: FunctionObj
    ip: int
    stack: seq[Value]
    locals: seq[Value]
    selfVal: Value
    upvalues: OrderedTable[string, Value]
    handlers: seq[ExceptionHandler]

  Vm* = object
    module*: AirModule
    globals*: OrderedTable[int, Value]
    natives*: OrderedTable[int, NativeEntry]
    deterministic*: bool
    rngState*: uint64
    diagnostics*: seq[string]
    capabilityStack*: seq[HashSet[string]]

proc newVm*(): Vm =
  Vm(
    module: nil,
    globals: initOrderedTable[int, Value](),
    natives: initOrderedTable[int, NativeEntry](),
    deterministic: false,
    rngState: 0x9E3779B97F4A7C15'u64,
    diagnostics: @[],
    capabilityStack: @[]
  )

proc raiseVmValue(err: Value) {.noreturn.} =
  let ex = VmThrow(msg: err.toDebugString(), value: err)
  raise ex

proc popValue(frame: var FrameCtx): Value =
  if frame.stack.len == 0:
    return valueNil()
  result = frame.stack[^1]
  frame.stack.setLen(frame.stack.len - 1)

proc peekValue(frame: FrameCtx; depth = 0): Value =
  let idx = frame.stack.len - 1 - depth
  if idx < 0 or idx >= frame.stack.len:
    return valueNil()
  frame.stack[idx]

proc pushValue(frame: var FrameCtx; v: Value) =
  frame.stack.add(v)

proc popArgs(frame: var FrameCtx; argc: int): seq[Value] =
  result = newSeq[Value](argc)
  for i in countdown(argc - 1, 0):
    result[i] = popValue(frame)

proc getGlobal(vm: Vm; symId: int): Value =
  if vm.globals.hasKey(symId):
    return vm.globals[symId]
  valueNil()

proc setGlobal(vm: var Vm; symId: int; value: Value) =
  vm.globals[symId] = value

proc instantiateFunctionValue(vm: var Vm; fnIdx: int; frame: FrameCtx): Value =
  if vm.module == nil or fnIdx < 0 or fnIdx >= vm.module.functions.len:
    return valueNil()

  let fnMeta = vm.module.functions[fnIdx]
  let fnVal = newFunctionValue(fnMeta.name, fnIdx, fnMeta.arity)
  let fnObj = asFunctionObj(fnVal)

  for p in fnMeta.params:
    fnObj.paramNames.add(p.name)
    fnObj.paramTypes.add(p.typeAnn)

  for flag in fnMeta.flags:
    case flag
    of FFlagAsync:
      fnObj.flags.incl(FfAsync)
    of FFlagGenerator:
      fnObj.flags.incl(FfGenerator)
    of FFlagMacroLike:
      fnObj.flags.incl(FfMacroLike)
    of FFlagMethod:
      fnObj.flags.incl(FfMethod)
    of FFlagHasTry:
      discard

  for symId in fnMeta.upvalueSymbols:
    let name = symbolName(symId)
    if name.len == 0:
      continue
    fnObj.upvalueNames.add(name)
    if frame.upvalues.hasKey(name):
      fnObj.upvalues[name] = frame.upvalues[name]
    else:
      var found = false
      if frame.fnMeta != nil:
        for slot, localSymId in frame.fnMeta.localSymbols:
          if localSymId == symId and slot < frame.locals.len:
            fnObj.upvalues[name] = frame.locals[slot]
            found = true
            break
      if not found:
        let g = getGlobal(vm, symId)
        fnObj.upvalues[name] = g

  fnVal

proc invokeValue(vm: var Vm; callee: Value; args: seq[Value]; selfValue: Value = valueNil()): Value

proc asIntDefault(v: Value; defaultVal: int): int =
  if isInt(v):
    return int(asInt(v))
  if isNumber(v):
    return int(asFloat(v))
  defaultVal

proc iteratorNew(iterable: Value): Value =
  let it = newMapValue()
  mapSet(it, newStringValue("__index"), valueInt(0))
  mapSet(it, newStringValue("__data"), iterable)

  let arr = asArrayObj(iterable)
  if arr != nil:
    mapSet(it, newStringValue("__kind"), newStringValue("array"))
    return it

  let m = asMapObj(iterable)
  if m != nil:
    mapSet(it, newStringValue("__kind"), newStringValue("map"))
    var keys: seq[Value] = @[]
    for k in m.entries.keys:
      keys.add(newKeywordValue(k))
    mapSet(it, newStringValue("__keys"), newArrayValue(keys))
    return it

  let s = asStringObj(iterable)
  if s != nil:
    mapSet(it, newStringValue("__kind"), newStringValue("string"))
    return it

  mapSet(it, newStringValue("__kind"), newStringValue("empty"))
  it

proc iteratorHasNext(it: Value): bool =
  let kind = mapGet(it, newStringValue("__kind")).asString()
  let idx = asIntDefault(mapGet(it, newStringValue("__index")), 0)

  case kind
  of "array":
    let data = mapGet(it, newStringValue("__data"))
    let arr = asArrayObj(data)
    arr != nil and idx < arr.items.len
  of "map":
    let keys = asArrayObj(mapGet(it, newStringValue("__keys")))
    keys != nil and idx < keys.items.len
  of "string":
    let s = asStringObj(mapGet(it, newStringValue("__data")))
    s != nil and idx < s.value.len
  else:
    false

proc iteratorNext(it: Value): Value =
  let kind = mapGet(it, newStringValue("__kind")).asString()
  let idx = asIntDefault(mapGet(it, newStringValue("__index")), 0)
  mapSet(it, newStringValue("__index"), valueInt(idx + 1))

  case kind
  of "array":
    let data = mapGet(it, newStringValue("__data"))
    let arr = asArrayObj(data)
    if arr == nil or idx < 0 or idx >= arr.items.len:
      return valueNil()
    arr.items[idx]
  of "map":
    let keys = asArrayObj(mapGet(it, newStringValue("__keys")))
    if keys == nil or idx < 0 or idx >= keys.items.len:
      return valueNil()
    let key = keys.items[idx]
    let data = mapGet(it, newStringValue("__data"))
    mapGet(data, key)
  of "string":
    let s = asStringObj(mapGet(it, newStringValue("__data")))
    if s == nil or idx < 0 or idx >= s.value.len:
      return valueNil()
    newStringValue($s.value[idx])
  else:
    valueNil()

proc xorshift64(state: var uint64): uint64 =
  var x = state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  state = x
  x

proc hasCapability(vm: Vm; cap: string): bool =
  if vm.capabilityStack.len == 0:
    return true
  cap in vm.capabilityStack[^1]

proc executeFunction(vm: var Vm; fnObj: FunctionObj; args: seq[Value]; selfValue: Value = valueNil()): Value =
  if vm.module == nil:
    return valueNil()
  if fnObj.fnIndex < 0 or fnObj.fnIndex >= vm.module.functions.len:
    raise newException(VmRuntimeError, "invalid function index")

  let fnMeta = vm.module.functions[fnObj.fnIndex]
  var frame = FrameCtx(
    fnMeta: fnMeta,
    fnObj: fnObj,
    ip: 0,
    stack: @[],
    locals: newSeq[Value](max(fnMeta.localCount, args.len)),
    selfVal: selfValue,
    upvalues: initOrderedTable[string, Value](),
    handlers: @[]
  )

  for i in 0..<frame.locals.len:
    frame.locals[i] = valueNil()

  for i in 0..<min(args.len, frame.locals.len):
    frame.locals[i] = args[i]

  for name in fnObj.upvalueNames:
    if fnObj.upvalues.hasKey(name):
      frame.upvalues[name] = fnObj.upvalues[name]

  template handleThrow(thrown: Value): untyped =
    if frame.handlers.len > 0:
      let h = frame.handlers[^1]
      frame.handlers.setLen(frame.handlers.len - 1)
      frame.stack.setLen(h.stackDepth)
      frame.stack.add(thrown)
      frame.ip = h.catchIp
      continue
    else:
      raiseVmValue(thrown)

  while frame.ip < fnMeta.code.len:
    let inst = fnMeta.code[frame.ip]
    inc(frame.ip)

    try:
      case inst.op
      of OpNop:
        discard
      of OpConst:
        let idx = int(inst.b)
        if idx < 0 or idx >= vm.module.constants.len:
          pushValue(frame, valueNil())
        else:
          pushValue(frame, vm.module.constants[idx])
      of OpConstNil:
        pushValue(frame, valueNil())
      of OpConstTrue:
        pushValue(frame, valueBool(true))
      of OpConstFalse:
        pushValue(frame, valueBool(false))
      of OpPop:
        discard popValue(frame)
      of OpDup:
        pushValue(frame, peekValue(frame))
      of OpSwap:
        let a = popValue(frame)
        let b = popValue(frame)
        pushValue(frame, a)
        pushValue(frame, b)
      of OpOver:
        pushValue(frame, peekValue(frame, 1))

      of OpLoadLocal:
        let idx = int(inst.b)
        if idx >= 0 and idx < frame.locals.len:
          pushValue(frame, frame.locals[idx])
        else:
          pushValue(frame, valueNil())
      of OpStoreLocal:
        let idx = int(inst.b)
        let v = popValue(frame)
        if idx >= 0:
          if idx >= frame.locals.len:
            frame.locals.setLen(idx + 1)
          frame.locals[idx] = v
        pushValue(frame, v)

      of OpLoadUpvalue:
        let idx = int(inst.b)
        if idx >= 0 and idx < fnMeta.upvalueSymbols.len:
          let name = symbolName(fnMeta.upvalueSymbols[idx])
          if frame.upvalues.hasKey(name):
            pushValue(frame, frame.upvalues[name])
          else:
            pushValue(frame, valueNil())
        else:
          pushValue(frame, valueNil())
      of OpStoreUpvalue:
        let idx = int(inst.b)
        let v = popValue(frame)
        if idx >= 0 and idx < fnMeta.upvalueSymbols.len:
          let name = symbolName(fnMeta.upvalueSymbols[idx])
          frame.upvalues[name] = v
        pushValue(frame, v)

      of OpLoadGlobal:
        pushValue(frame, getGlobal(vm, int(inst.b)))
      of OpStoreGlobal:
        let v = popValue(frame)
        setGlobal(vm, int(inst.b), v)
        pushValue(frame, v)

      of OpLoadSelf:
        pushValue(frame, frame.selfVal)
      of OpLoadSuper:
        let instObj = asInstanceObj(frame.selfVal)
        if instObj == nil:
          pushValue(frame, valueNil())
        else:
          let cls = asClassObj(instObj.cls)
          if cls != nil:
            pushValue(frame, cls.superClass)
          else:
            pushValue(frame, valueNil())

      of OpAdd:
        let b = popValue(frame)
        let a = popValue(frame)
        if (isInt(a) or isNumber(a)) and (isInt(b) or isNumber(b)):
          if isInt(a) and isInt(b):
            pushValue(frame, valueInt(asInt(a) + asInt(b)))
          else:
            pushValue(frame, valueFloat(asFloat(a) + asFloat(b)))
        else:
          pushValue(frame, newStringValue(a.toDebugString() & b.toDebugString()))
      of OpSub:
        let b = popValue(frame)
        let a = popValue(frame)
        if isInt(a) and isInt(b):
          pushValue(frame, valueInt(asInt(a) - asInt(b)))
        else:
          pushValue(frame, valueFloat(asFloat(a) - asFloat(b)))
      of OpMul:
        let b = popValue(frame)
        let a = popValue(frame)
        if isInt(a) and isInt(b):
          pushValue(frame, valueInt(asInt(a) * asInt(b)))
        else:
          pushValue(frame, valueFloat(asFloat(a) * asFloat(b)))
      of OpDiv:
        let b = popValue(frame)
        let a = popValue(frame)
        let denom = asFloat(b)
        if denom == 0.0:
          handleThrow(newErrorValue("division by zero"))
        else:
          pushValue(frame, valueFloat(asFloat(a) / denom))
      of OpMod:
        let b = popValue(frame)
        let a = popValue(frame)
        let rhs = asInt(b)
        if rhs == 0:
          handleThrow(newErrorValue("mod by zero"))
        else:
          pushValue(frame, valueInt(asInt(a) mod rhs))
      of OpPow:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueFloat(pow(asFloat(a), asFloat(b))))
      of OpNeg:
        let a = popValue(frame)
        if isInt(a):
          pushValue(frame, valueInt(-asInt(a)))
        else:
          pushValue(frame, valueFloat(-asFloat(a)))

      of OpCmpEq:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(valueEq(a, b)))
      of OpCmpNe:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(not valueEq(a, b)))
      of OpCmpLt:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(asFloat(a) < asFloat(b)))
      of OpCmpLe:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(asFloat(a) <= asFloat(b)))
      of OpCmpGt:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(asFloat(a) > asFloat(b)))
      of OpCmpGe:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(asFloat(a) >= asFloat(b)))
      of OpLogAnd:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(isTruthy(a) and isTruthy(b)))
      of OpLogOr:
        let b = popValue(frame)
        let a = popValue(frame)
        pushValue(frame, valueBool(isTruthy(a) or isTruthy(b)))
      of OpLogNot:
        let a = popValue(frame)
        pushValue(frame, valueBool(not isTruthy(a)))

      of OpJump:
        frame.ip = int(inst.b)
      of OpBrTrue:
        let cond = popValue(frame)
        if isTruthy(cond):
          frame.ip = int(inst.b)
      of OpBrFalse:
        let cond = popValue(frame)
        if not isTruthy(cond):
          frame.ip = int(inst.b)

      of OpReturn:
        if frame.stack.len > 0:
          return popValue(frame)
        return valueNil()

      of OpTryBegin:
        frame.handlers.add(ExceptionHandler(catchIp: int(inst.b), stackDepth: frame.stack.len))
      of OpTryEnd:
        if frame.handlers.len > 0:
          frame.handlers.setLen(frame.handlers.len - 1)
      of OpCatchBegin, OpCatchEnd, OpFinallyBegin, OpFinallyEnd:
        discard
      of OpThrow:
        let err = popValue(frame)
        handleThrow(err)
      of OpRethrow:
        let err = popValue(frame)
        handleThrow(err)

      of OpFnNew, OpClosureNew:
        let fnVal = instantiateFunctionValue(vm, int(inst.b), frame)
        pushValue(frame, fnVal)

      of OpCall, OpCallDynamic, OpTailCall:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let callee = popValue(frame)
        let callResult = invokeValue(vm, callee, args)
        pushValue(frame, callResult)

      of OpCallMacro:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let callee = popValue(frame)
        let callResult = invokeValue(vm, callee, args)
        pushValue(frame, callResult)

      of OpCallMethod, OpCallMethodKw:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let receiver = popValue(frame)
        let methodName = symbolName(int(inst.b))
        var methodValue = getMember(receiver, methodName)

        if isNil(methodValue):
          let sid = internSymbol(methodName)
          if vm.globals.hasKey(sid):
            var methodArgs: seq[Value] = @[receiver]
            for a in args:
              methodArgs.add(a)
            let callResult = invokeValue(vm, vm.globals[sid], methodArgs, receiver)
            pushValue(frame, callResult)
          elif argc == 0:
            pushValue(frame, getMember(receiver, methodName))
          else:
            handleThrow(newErrorValue("method not found: " & methodName))
        else:
          let callResult = invokeValue(vm, methodValue, args, receiver)
          pushValue(frame, callResult)

      of OpCallSuper, OpCallSuperKw:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let methodName = symbolName(int(inst.b))

        let instObj = asInstanceObj(frame.selfVal)
        if instObj == nil:
          handleThrow(newErrorValue("super call without instance"))
        let cls = asClassObj(instObj.cls)
        if cls == nil:
          handleThrow(newErrorValue("super call on invalid class"))
        let superCls = asClassObj(cls.superClass)
        if superCls == nil:
          handleThrow(newErrorValue("super class not found"))

        if not superCls.methods.hasKey(methodName):
          handleThrow(newErrorValue("super method missing: " & methodName))
        let callResult = invokeValue(vm, superCls.methods[methodName], args, frame.selfVal)
        pushValue(frame, callResult)

      of OpCallerEval:
        pushValue(frame, valueNil())

      of OpYield:
        if frame.stack.len > 0:
          return popValue(frame)
        return valueNil()
      of OpResume:
        let genVal = popValue(frame)
        let gen = asGeneratorObj(genVal)
        if gen == nil:
          pushValue(frame, valueNil())
        elif gen.state == GsDone:
          pushValue(frame, gen.lastValue)
        else:
          let fnVal = gen.fnValue
          let fnObj = asFunctionObj(fnVal)
          if fnObj == nil:
            pushValue(frame, valueNil())
          else:
            gen.state = GsRunning
            let resumed = executeFunction(vm, fnObj, gen.args)
            gen.lastValue = resumed
            gen.state = GsDone
            pushValue(frame, resumed)

      of OpArrNew:
        pushValue(frame, newArrayValue())
      of OpArrPush:
        let v = popValue(frame)
        let arrVal = peekValue(frame)
        let arrObj = asArrayObj(arrVal)
        if arrObj != nil:
          arrObj.items.add(v)
      of OpArrSpread:
        let spread = popValue(frame)
        let target = peekValue(frame)
        let tArr = asArrayObj(target)
        let sArr = asArrayObj(spread)
        if tArr != nil and sArr != nil:
          for item in sArr.items:
            tArr.items.add(item)
      of OpArrEnd:
        discard

      of OpMapNew:
        pushValue(frame, newMapValue())
      of OpMapSet:
        let val = popValue(frame)
        let mapVal = peekValue(frame)
        mapSet(mapVal, valueSymbolId(int(inst.b)), val)
      of OpMapSetDynamic:
        let val = popValue(frame)
        let key = popValue(frame)
        let mapVal = peekValue(frame)
        mapSet(mapVal, key, val)
      of OpMapSpread:
        let spread = popValue(frame)
        let target = peekValue(frame)
        let tMap = asMapObj(target)
        let sMap = asMapObj(spread)
        if tMap != nil and sMap != nil:
          for k, v in sMap.entries:
            tMap.entries[k] = v
      of OpMapEnd:
        discard

      of OpGeneNew:
        pushValue(frame, newGeneValue(valueNil()))
      of OpGeneSetType:
        let t = popValue(frame)
        let g = asGeneObj(peekValue(frame))
        if g != nil:
          g.geneType = t
      of OpGeneSetProp:
        let v = popValue(frame)
        let g = asGeneObj(peekValue(frame))
        if g != nil:
          g.props[symbolName(int(inst.b))] = v
      of OpGeneSetPropDynamic:
        let v = popValue(frame)
        let k = popValue(frame)
        let g = asGeneObj(peekValue(frame))
        if g != nil:
          g.props[keyFromValue(k)] = v
      of OpGeneAddChild:
        let child = popValue(frame)
        let g = asGeneObj(peekValue(frame))
        if g != nil:
          g.children.add(child)
      of OpGeneAddSpread:
        let spread = popValue(frame)
        let childArr = asArrayObj(spread)
        let g = asGeneObj(peekValue(frame))
        if g != nil and childArr != nil:
          for child in childArr.items:
            g.children.add(child)
      of OpGeneEnd:
        discard

      of OpClassNew:
        pushValue(frame, newClassValue(symbolName(int(inst.b))))
      of OpClassExtends:
        let base = popValue(frame)
        let cls = asClassObj(peekValue(frame))
        if cls != nil:
          cls.superClass = base
      of OpMethodDef:
        let topVal = peekValue(frame)
        if asFunctionObj(topVal) != nil or asNativeFunctionObj(topVal) != nil:
          discard popValue(frame)
        let cls = asClassObj(peekValue(frame))
        if cls != nil:
          let fnVal = instantiateFunctionValue(vm, int(inst.c), frame)
          cls.methods[symbolName(int(inst.b))] = fnVal
      of OpCtorDef:
        let topVal = peekValue(frame)
        if asFunctionObj(topVal) != nil or asNativeFunctionObj(topVal) != nil:
          discard popValue(frame)
        let cls = asClassObj(peekValue(frame))
        if cls != nil:
          let fnVal = instantiateFunctionValue(vm, int(inst.b), frame)
          cls.ctor = fnVal
      of OpPropDef, OpDecoratorApply, OpInterceptEnter, OpInterceptExit:
        discard

      of OpImport:
        pushValue(frame, valueNil())
      of OpExport:
        discard
      of OpNsEnter, OpNsExit:
        discard

      of OpGetMember:
        let target = popValue(frame)
        pushValue(frame, getMember(target, symbolName(int(inst.b))))
      of OpGetMemberNil:
        let target = popValue(frame)
        if isNil(target):
          pushValue(frame, valueNil())
        else:
          pushValue(frame, getMember(target, symbolName(int(inst.b))))
      of OpGetMemberDefault:
        let fallback = popValue(frame)
        let target = popValue(frame)
        let got = getMember(target, symbolName(int(inst.b)))
        if isNil(got):
          pushValue(frame, fallback)
        else:
          pushValue(frame, got)
      of OpGetMemberDynamic:
        let key = popValue(frame)
        let target = popValue(frame)
        pushValue(frame, getMember(target, keyFromValue(key)))
      of OpSetMember:
        let val = popValue(frame)
        let target = popValue(frame)
        setMember(target, symbolName(int(inst.b)), val)
        pushValue(frame, val)
      of OpSetMemberDynamic:
        let val = popValue(frame)
        let key = popValue(frame)
        let target = popValue(frame)
        setMember(target, keyFromValue(key), val)
        pushValue(frame, val)
      of OpGetChild:
        let target = popValue(frame)
        let idx = int(inst.b)
        let arr = asArrayObj(target)
        if arr != nil:
          pushValue(frame, arrayGet(target, idx))
        else:
          let gene = asGeneObj(target)
          if gene != nil and idx >= 0 and idx < gene.children.len:
            pushValue(frame, gene.children[idx])
          else:
            pushValue(frame, mapGet(target, valueInt(idx)))
      of OpGetChildDynamic:
        let key = popValue(frame)
        let target = popValue(frame)
        if isInt(key):
          pushValue(frame, arrayGet(target, int(asInt(key))))
        else:
          pushValue(frame, mapGet(target, key))

      of OpAsyncBegin:
        discard
      of OpAsyncEnd:
        if frame.stack.len > 0:
          let v = popValue(frame)
          pushValue(frame, newFutureResolvedValue(v))
        else:
          pushValue(frame, newFutureResolvedValue(valueNil()))
      of OpAwait:
        let v = popValue(frame)
        let fut = asFutureObj(v)
        if fut == nil:
          pushValue(frame, v)
        else:
          case fut.state
          of FsResolved:
            pushValue(frame, fut.value)
          of FsRejected:
            handleThrow(fut.error)
          of FsPending:
            pushValue(frame, valueNil())
      of OpFutureWrap:
        let v = popValue(frame)
        pushValue(frame, newFutureResolvedValue(v))

      of OpThreadSpawn, OpTaskScopeEnter, OpTaskSpawn, OpTaskJoin, OpTaskCancel, OpTaskDeadline:
        pushValue(frame, valueNil())

      of OpCapEnter:
        var caps = initHashSet[string]()
        let idx = int(inst.b)
        if idx >= 0 and idx < vm.module.effects.len:
          for cap in vm.module.effects[idx].capabilities:
            caps.incl(cap)
        vm.capabilityStack.add(caps)
      of OpCapExit:
        if vm.capabilityStack.len > 0:
          vm.capabilityStack.setLen(vm.capabilityStack.len - 1)
      of OpCapAssert:
        let capName = symbolName(int(inst.b))
        if not hasCapability(vm, capName):
          handleThrow(newErrorValue("capability denied: " & capName))
      of OpQuotaSet, OpQuotaCheck, OpCheckpointHint, OpStateSave, OpStateRestore:
        discard

      of OpToolPrep:
        pushValue(frame, valueInt(inst.b.int))
      of OpToolCall:
        let req = popValue(frame)
        discard req
        pushValue(frame, newFutureRejectedValue(newErrorValue("tool runtime not configured")))
      of OpToolAwait:
        let future = popValue(frame)
        let fut = asFutureObj(future)
        if fut != nil and fut.state == FsResolved:
          pushValue(frame, fut.value)
        elif fut != nil and fut.state == FsRejected:
          handleThrow(fut.error)
        else:
          pushValue(frame, valueNil())
      of OpToolResultUnwrap:
        discard
      of OpToolRetry:
        discard

      of OpDetSeed:
        vm.rngState = uint64(inst.b) xor (uint64(inst.c) shl 32)
      of OpDetRand:
        let rnd = xorshift64(vm.rngState)
        pushValue(frame, valueInt(int64(rnd and 0x7FFFFFFF'u64)))
      of OpDetNow:
        if vm.deterministic:
          pushValue(frame, valueInt(int64(vm.rngState and 0x7FFFFFFF'u64)))
        else:
          pushValue(frame, valueInt(getTime().toUnix()))
      of OpTraceEmit:
        vm.diagnostics.add("trace event " & $inst.b)
      of OpAuditEmit:
        vm.diagnostics.add("audit event " & $inst.b)
      of OpDiagEmit:
        vm.diagnostics.add("diag code " & $inst.b)

      of OpTypeof:
        let v = popValue(frame)
        pushValue(frame, valueSymbol(inferTypeName(v).toLowerAscii()))
      of OpIsType:
        let v = popValue(frame)
        let expected = symbolName(int(inst.b))
        pushValue(frame, valueBool(expectType(v, expected)))
      of OpRangeNew, OpEnumNew, OpEnumAdd:
        pushValue(frame, valueNil())

      of OpIterInit:
        let iterable = popValue(frame)
        pushValue(frame, iteratorNew(iterable))
      of OpIterHasNext:
        let it = popValue(frame)
        pushValue(frame, valueBool(iteratorHasNext(it)))
      of OpIterNext:
        let it = popValue(frame)
        pushValue(frame, iteratorNext(it))

      of OpHalt:
        if frame.stack.len > 0:
          return popValue(frame)
        return valueNil()
      else:
        # Unimplemented AIR opcodes are currently treated as no-ops.
        discard

    except VmThrow as thrown:
      handleThrow(thrown.value)

  if frame.stack.len > 0:
    popValue(frame)
  else:
    valueNil()

proc invokeValue(vm: var Vm; callee: Value; args: seq[Value]; selfValue: Value = valueNil()): Value =
  if isNil(callee):
    raiseVmValue(newErrorValue("attempted to call nil"))

  if isSymbol(callee):
    let sid = asSymbolId(callee)
    if vm.globals.hasKey(sid):
      return invokeValue(vm, vm.globals[sid], args, selfValue)
    raiseVmValue(newErrorValue("unknown callable symbol: " & asSymbolName(callee)))

  let nativeObj = asNativeFunctionObj(callee)
  if nativeObj != nil:
    let sid = internSymbol(nativeObj.name)
    if not vm.natives.hasKey(sid):
      raiseVmValue(newErrorValue("native not registered: " & nativeObj.name))
    let entry = vm.natives[sid]
    if entry.arity >= 0 and args.len != entry.arity:
      raiseVmValue(newErrorValue("native arity mismatch for " & entry.name))
    return entry.callback(args)

  let fnObj = asFunctionObj(callee)
  if fnObj != nil:
    if fnObj.arity >= 0 and args.len != fnObj.arity:
      raiseVmValue(newErrorValue("function arity mismatch: expected " & $fnObj.arity & " got " & $args.len))

    for i, paramType in fnObj.paramTypes:
      if i < args.len and paramType.len > 0 and not expectType(args[i], paramType):
        raiseVmValue(newErrorValue("type mismatch for parameter " & fnObj.paramNames[i] & ": expected " & paramType & " got " & inferTypeName(args[i])))

    if FfGenerator in fnObj.flags:
      return newGeneratorValue(callee, args)

    return executeFunction(vm, fnObj, args, selfValue)

  let cls = asClassObj(callee)
  if cls != nil:
    let instance = newInstanceValue(callee)
    if not isNil(cls.ctor):
      discard invokeValue(vm, cls.ctor, args, instance)
    return instance

  raiseVmValue(newErrorValue("value is not callable: " & callee.toDebugString()))

proc registerNative*(vm: var Vm; name: string; arity: int; fn: NativeProc; caps: seq[string] = @[]; isMacro = false) =
  let sid = internSymbol(name)
  vm.natives[sid] = NativeEntry(
    name: name,
    arity: arity,
    caps: caps,
    isMacro: isMacro,
    callback: fn
  )
  vm.globals[sid] = newNativeFunctionValue(name, arity)

proc runModule*(vm: var Vm; module: AirModule): Value =
  vm.module = module
  if vm.module == nil or vm.module.mainFn < 0 or vm.module.mainFn >= vm.module.functions.len:
    return valueNil()

  let mainMeta = vm.module.functions[vm.module.mainFn]
  let mainVal = newFunctionValue(mainMeta.name, vm.module.mainFn, mainMeta.arity)
  let mainObj = asFunctionObj(mainVal)
  for p in mainMeta.params:
    mainObj.paramNames.add(p.name)
    mainObj.paramTypes.add(p.typeAnn)

  try:
    executeFunction(vm, mainObj, @[])
  except VmThrow as thrown:
    raise newException(VmRuntimeError, "uncaught error: " & thrown.value.toDebugString())

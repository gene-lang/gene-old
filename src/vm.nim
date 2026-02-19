import std/[tables, strutils, times, math, sets, json, hashes, os, sequtils]
import ./types
import ./ir
import ./parser
import ./compiler

type
  VmRuntimeError* = object of CatchableError

  VmThrow* = ref object of CatchableError
    value*: Value

  NativeProc* = proc(vm: var Vm; args: seq[Value]): Value {.nimcall.}

  TaskState* = enum
    TsReady
    TsRunning
    TsDone
    TsCancelled
    TsFailed

  TaskNode* = ref object
    id*: int
    parent*: int
    children*: seq[int]
    state*: TaskState
    deadlineUnix*: int64
    cancelToken*: uint64
    result*: Value
    error*: Value
    fnValue*: Value
    args*: seq[Value]

  ToolCallRequest* = object
    toolName*: string
    args*: Value
    idempotencyKey*: string
    retryPolicy*: string
    maxAttempts*: int
    attempt*: int
    timeoutMs*: int
    schemaId*: int

  ToolCallResult* = object
    ok*: bool
    value*: Value
    error*: Value

  ToolHandler* = proc(vm: var Vm; req: ToolCallRequest): ToolCallResult {.nimcall.}

  ToolRegistration* = object
    schema*: ToolSchema
    handler*: ToolHandler

  VmQuotaKind* = enum
    QkCpuSteps
    QkHeapObjects
    QkWallClockMs
    QkToolCalls

  VmQuotaConfig* = object
    cpuStepLimit*: int64
    heapObjectLimit*: int64
    wallClockMsLimit*: int64
    toolCallLimit*: int64

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
    loadedModules*: seq[AirModule]
    globals*: OrderedTable[int, Value]
    natives*: OrderedTable[int, NativeEntry]
    tasks*: OrderedTable[int, TaskNode]
    taskScopeStack*: seq[int]
    currentTaskId*: int
    nextTaskId*: int
    checkpointSlots*: OrderedTable[int, seq[byte]]
    toolRegistry*: OrderedTable[string, ToolRegistration]
    toolIdempotencyCache*: OrderedTable[string, Value]
    preparedToolSchemaId*: int
    pendingToolTicket*: int
    nextToolTicket*: int
    quota*: VmQuotaConfig
    cpuStepsUsed*: int64
    toolCallsUsed*: int64
    startedAtMs*: int64
    rootCapabilities*: HashSet[string]
    deterministic*: bool
    rngState*: uint64
    diagnostics*: seq[string]
    capabilityStack*: seq[HashSet[string]]
    namespaceStack*: seq[Value]
    moduleCache*: OrderedTable[string, Value]
    moduleLoading*: HashSet[string]

proc newVm*(): Vm =
  Vm(
    module: nil,
    loadedModules: @[],
    globals: initOrderedTable[int, Value](),
    natives: initOrderedTable[int, NativeEntry](),
    tasks: initOrderedTable[int, TaskNode](),
    taskScopeStack: @[],
    currentTaskId: 0,
    nextTaskId: 1,
    checkpointSlots: initOrderedTable[int, seq[byte]](),
    toolRegistry: initOrderedTable[string, ToolRegistration](),
    toolIdempotencyCache: initOrderedTable[string, Value](),
    preparedToolSchemaId: -1,
    pendingToolTicket: -1,
    nextToolTicket: 1,
    quota: VmQuotaConfig(
      cpuStepLimit: -1,
      heapObjectLimit: -1,
      wallClockMsLimit: -1,
      toolCallLimit: -1
    ),
    cpuStepsUsed: 0,
    toolCallsUsed: 0,
    startedAtMs: epochTime().int64 * 1000,
    rootCapabilities: initHashSet[string](),
    deterministic: false,
    rngState: 0x9E3779B97F4A7C15'u64,
    diagnostics: @[],
    capabilityStack: @[],
    namespaceStack: @[],
    moduleCache: initOrderedTable[string, Value](),
    moduleLoading: initHashSet[string]()
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

proc setScopedGlobal(vm: var Vm; symId: int; value: Value) =
  if vm.namespaceStack.len > 0:
    let nsMap = asMapObj(vm.namespaceStack[^1])
    if nsMap != nil:
      nsMap.entries[symbolName(symId)] = value
      return
  setGlobal(vm, symId, value)

proc ensureLoadedModule(vm: var Vm; module: AirModule): int =
  if module == nil:
    return -1
  for i, existing in vm.loadedModules:
    if existing == module:
      return i
  let idx = vm.loadedModules.len
  vm.loadedModules.add(module)
  idx

proc getConstPath(module: AirModule; idx: int): string =
  if module == nil or idx < 0 or idx >= module.constants.len:
    return ""

  let v = module.constants[idx]
  let sObj = asStringObj(v)
  if sObj != nil:
    return sObj.value

  if isSymbol(v):
    return asSymbolName(v)

  v.asString()

proc resolveImportPath(baseSourcePath, requested: string): string =
  if requested.len == 0:
    return ""

  var baseDir = getCurrentDir()
  if baseSourcePath.len > 0 and not baseSourcePath.startsWith("<"):
    let parts = splitFile(baseSourcePath)
    if parts.dir.len > 0:
      baseDir = parts.dir

  var candidate = requested
  if not isAbsolute(requested):
    candidate = baseDir / requested

  var candidates: seq[string] = @[candidate]
  if splitFile(candidate).ext.len == 0:
    candidates.add(candidate & ".gene")
    candidates.add(candidate / "index.gene")

  for c in candidates:
    if fileExists(c):
      return absolutePath(c)

  absolutePath(candidates[0])

proc executeFunction(
  vm: var Vm;
  fnObj: FunctionObj;
  args: seq[Value];
  selfValue: Value = valueNil();
  resumeGen: GeneratorObj = nil
): Value

proc runImportedModule(vm: var Vm; modulePath: string): Value =
  if modulePath.len == 0:
    raiseVmValue(newErrorValue("invalid import path"))

  if vm.moduleCache.hasKey(modulePath):
    return vm.moduleCache[modulePath]

  if modulePath in vm.moduleLoading:
    raiseVmValue(newErrorValue("circular import: " & modulePath))

  if not fileExists(modulePath):
    raiseVmValue(newErrorValue("import not found: " & modulePath))

  vm.moduleLoading.incl(modulePath)
  let nsValue = newMapValue()
  vm.moduleCache[modulePath] = nsValue

  try:
    let src = readFile(modulePath)
    let ast = parseProgram(src, modulePath)
    let importedModule = compileProgram(ast, modulePath)

    let prevModule = vm.module
    let prevNsDepth = vm.namespaceStack.len
    vm.module = importedModule
    vm.namespaceStack.add(nsValue)

    try:
      if importedModule.mainFn >= 0 and importedModule.mainFn < importedModule.functions.len:
        let importedModuleId = ensureLoadedModule(vm, importedModule)
        let mainMeta = importedModule.functions[importedModule.mainFn]
        let mainVal = newFunctionValue(mainMeta.name, importedModule.mainFn, mainMeta.arity, importedModuleId)
        let mainObj = asFunctionObj(mainVal)
        for p in mainMeta.params:
          mainObj.paramNames.add(p.name)
          mainObj.paramTypes.add(p.typeAnn)
        discard executeFunction(vm, mainObj, @[])
    finally:
      vm.module = prevModule
      vm.namespaceStack.setLen(prevNsDepth)

    vm.moduleLoading.excl(modulePath)
    nsValue
  except VmThrow:
    vm.moduleLoading.excl(modulePath)
    vm.moduleCache.del(modulePath)
    raise
  except CatchableError as ex:
    vm.moduleLoading.excl(modulePath)
    vm.moduleCache.del(modulePath)
    raiseVmValue(newErrorValue("import failed: " & ex.msg))

proc setQuotaLimit*(vm: var Vm; kind: VmQuotaKind; value: int64) =
  case kind
  of QkCpuSteps:
    vm.quota.cpuStepLimit = value
  of QkHeapObjects:
    vm.quota.heapObjectLimit = value
  of QkWallClockMs:
    vm.quota.wallClockMsLimit = value
  of QkToolCalls:
    vm.quota.toolCallLimit = value

proc grantCapability*(vm: var Vm; cap: string) =
  vm.rootCapabilities.incl(cap)

proc revokeCapability*(vm: var Vm; cap: string) =
  if cap in vm.rootCapabilities:
    vm.rootCapabilities.excl(cap)

proc clearCapabilities*(vm: var Vm) =
  vm.rootCapabilities.clear()

proc instantiateFunctionValue(vm: var Vm; fnIdx: int; frame: FrameCtx): Value =
  if vm.module == nil or fnIdx < 0 or fnIdx >= vm.module.functions.len:
    return valueNil()

  let moduleId = ensureLoadedModule(vm, vm.module)
  let fnMeta = vm.module.functions[fnIdx]
  let fnVal = newFunctionValue(fnMeta.name, fnIdx, fnMeta.arity, moduleId)
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

proc invokeValue(vm: var Vm; callee: Value; args: seq[Value]; selfValue: Value = valueNil(); kwargs: Value = valueNil()): Value
proc kwargsHasEntries(kwargs: Value): bool

proc asIntDefault(v: Value; defaultVal: int): int =
  if isInt(v):
    return int(asInt(v))
  if isNumber(v):
    return int(asFloat(v))
  defaultVal

proc resumeValue*(vm: var Vm; value: Value): Value

proc invokeArrayMethod(vm: var Vm; receiver: Value; methodName: string; args: seq[Value]; kwargs: Value): tuple[handled: bool, value: Value] =
  let arr = asArrayObj(receiver)
  if arr == nil:
    return (false, valueNil())

  if methodName notin ["push", "pop", "map", "filter", "reduce"]:
    return (false, valueNil())

  if kwargsHasEntries(kwargs):
    raiseVmValue(newErrorValue("array method ." & methodName & " does not accept keyword arguments"))

  case methodName
  of "push":
    for a in args:
      arr.items.add(a)
    (true, valueInt(arr.items.len))
  of "pop":
    if arr.items.len == 0:
      (true, valueNil())
    else:
      let popped = arr.items[^1]
      arr.items.setLen(arr.items.len - 1)
      (true, popped)
  of "map":
    if args.len < 1:
      raiseVmValue(newErrorValue("array .map requires a callback"))
    var mapped: seq[Value] = @[]
    for item in arr.items:
      mapped.add(invokeValue(vm, args[0], @[item], receiver))
    (true, newArrayValue(mapped))
  of "filter":
    if args.len < 1:
      raiseVmValue(newErrorValue("array .filter requires a callback"))
    var filtered: seq[Value] = @[]
    for item in arr.items:
      if isTruthy(invokeValue(vm, args[0], @[item], receiver)):
        filtered.add(item)
    (true, newArrayValue(filtered))
  of "reduce":
    if args.len < 2:
      raiseVmValue(newErrorValue("array .reduce requires initial value and callback"))
    var acc = args[0]
    let fn = args[1]
    for item in arr.items:
      acc = invokeValue(vm, fn, @[acc, item], receiver)
    (true, acc)
  else:
    (false, valueNil())

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

  let g = asGeneratorObj(iterable)
  if g != nil:
    mapSet(it, newStringValue("__kind"), newStringValue("generator"))
    mapSet(it, newStringValue("__has_buffer"), valueBool(false))
    mapSet(it, newStringValue("__buffer"), valueNil())
    return it

  mapSet(it, newStringValue("__kind"), newStringValue("empty"))
  it

proc iteratorHasNext(vm: var Vm; it: Value): bool =
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
  of "generator":
    if isBool(mapGet(it, newStringValue("__has_buffer"))) and asBool(mapGet(it, newStringValue("__has_buffer"))):
      return true
    let gval = mapGet(it, newStringValue("__data"))
    let g = asGeneratorObj(gval)
    if g == nil or g.finished or g.state == GsDone:
      return false
    let nextValue = resumeValue(vm, gval)
    if (isNil(nextValue) and (g.finished or g.state == GsDone)):
      return false
    mapSet(it, newStringValue("__buffer"), nextValue)
    mapSet(it, newStringValue("__has_buffer"), valueBool(true))
    true
  else:
    false

proc iteratorNext(vm: var Vm; it: Value): Value =
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
  of "generator":
    if isBool(mapGet(it, newStringValue("__has_buffer"))) and asBool(mapGet(it, newStringValue("__has_buffer"))):
      let buffered = mapGet(it, newStringValue("__buffer"))
      mapSet(it, newStringValue("__has_buffer"), valueBool(false))
      mapSet(it, newStringValue("__buffer"), valueNil())
      return buffered
    let gval = mapGet(it, newStringValue("__data"))
    resumeValue(vm, gval)
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
  if cap.len == 0:
    return true

  var activeCaps = vm.rootCapabilities
  if vm.capabilityStack.len > 0:
    activeCaps = vm.capabilityStack[^1]

  if cap in activeCaps:
    return true

  # Prefix-style wildcard support: cap.tool.call:* grants all tool calls.
  let wildIdx = cap.rfind(':')
  if wildIdx >= 0:
    let wildcard = cap[0..wildIdx] & "*"
    if wildcard in activeCaps:
      return true

  false

proc nowMs(): int64 =
  epochTime().int64 * 1000

proc checkQuota(vm: var Vm) =
  inc(vm.cpuStepsUsed)
  if vm.quota.cpuStepLimit >= 0 and vm.cpuStepsUsed > vm.quota.cpuStepLimit:
    vm.quota.cpuStepLimit = vm.cpuStepsUsed + 64
    raiseVmValue(newErrorValue("quota exceeded: cpu steps"))

  if vm.quota.heapObjectLimit >= 0 and heapObjectCount().int64 > vm.quota.heapObjectLimit:
    vm.quota.heapObjectLimit = heapObjectCount().int64 + 64
    raiseVmValue(newErrorValue("quota exceeded: heap objects"))

  if vm.quota.wallClockMsLimit >= 0:
    let elapsed = nowMs() - vm.startedAtMs
    if elapsed > vm.quota.wallClockMsLimit:
      vm.quota.wallClockMsLimit = elapsed + 64
      raiseVmValue(newErrorValue("quota exceeded: wall clock"))

proc encodeHandlers(frame: FrameCtx; catchIps: var seq[int]; depths: var seq[int]) =
  catchIps = @[]
  depths = @[]
  for h in frame.handlers:
    catchIps.add(h.catchIp)
    depths.add(h.stackDepth)

proc decodeHandlers(catchIps: seq[int]; depths: seq[int]): seq[ExceptionHandler] =
  result = @[]
  let n = min(catchIps.len, depths.len)
  for i in 0..<n:
    result.add(ExceptionHandler(catchIp: catchIps[i], stackDepth: depths[i]))

proc makeFrameFromGenerator(vm: var Vm; gen: GeneratorObj): FrameCtx =
  let fnObj = asFunctionObj(gen.fnValue)
  if fnObj == nil or vm.module == nil or fnObj.fnIndex < 0 or fnObj.fnIndex >= vm.module.functions.len:
    return FrameCtx(
      fnMeta: nil,
      fnObj: nil,
      ip: 0,
      stack: @[],
      locals: @[],
      selfVal: valueNil(),
      upvalues: initOrderedTable[string, Value](),
      handlers: @[]
    )

  let fnMeta = vm.module.functions[fnObj.fnIndex]
  result = FrameCtx(
    fnMeta: fnMeta,
    fnObj: fnObj,
    ip: gen.ip,
    stack: gen.stack,
    locals: gen.locals,
    selfVal: gen.selfVal,
    upvalues: initOrderedTable[string, Value](),
    handlers: decodeHandlers(gen.handlerCatchIps, gen.handlerStackDepths)
  )

  for k, v in gen.upvalues:
    result.upvalues[k] = v

proc persistFrameToGenerator(gen: GeneratorObj; frame: FrameCtx) =
  if gen == nil:
    return
  gen.ip = frame.ip
  gen.stack = frame.stack
  gen.locals = frame.locals
  gen.selfVal = frame.selfVal
  gen.upvalues = initOrderedTable[string, Value]()
  for k, v in frame.upvalues:
    gen.upvalues[k] = v
  encodeHandlers(frame, gen.handlerCatchIps, gen.handlerStackDepths)

proc requireCapability(vm: Vm; cap: string; context: string) =
  if cap.len == 0:
    return
  if not hasCapability(vm, cap):
    raiseVmValue(newErrorValue("capability denied (" & context & "): " & cap))

proc parseQuotaKind(value: Value): VmQuotaKind =
  let s = value.asString().toLowerAscii()
  case s
  of "cpu", "steps", "cpusteps":
    QkCpuSteps
  of "heap", "memory", "heapobjects":
    QkHeapObjects
  of "time", "wall", "wallclock":
    QkWallClockMs
  of "tool", "toolcalls":
    QkToolCalls
  else:
    QkCpuSteps

proc quotaCurrent(vm: Vm; kind: VmQuotaKind): int64 =
  case kind
  of QkCpuSteps:
    vm.cpuStepsUsed
  of QkHeapObjects:
    heapObjectCount().int64
  of QkWallClockMs:
    nowMs() - vm.startedAtMs
  of QkToolCalls:
    vm.toolCallsUsed

proc quotaLimit(vm: Vm; kind: VmQuotaKind): int64 =
  case kind
  of QkCpuSteps:
    vm.quota.cpuStepLimit
  of QkHeapObjects:
    vm.quota.heapObjectLimit
  of QkWallClockMs:
    vm.quota.wallClockMsLimit
  of QkToolCalls:
    vm.quota.toolCallLimit

proc newTaskNode(vm: var Vm; parent: int; fnValue: Value; args: seq[Value]): TaskNode =
  let id = vm.nextTaskId
  inc(vm.nextTaskId)
  result = TaskNode(
    id: id,
    parent: parent,
    children: @[],
    state: TsReady,
    deadlineUnix: -1,
    cancelToken: cast[uint64](id) xor vm.rngState,
    result: valueNil(),
    error: valueNil(),
    fnValue: fnValue,
    args: args
  )
  vm.tasks[id] = result
  if parent > 0 and vm.tasks.hasKey(parent):
    vm.tasks[parent].children.add(id)

proc currentSupervisor(vm: Vm): int =
  if vm.taskScopeStack.len > 0:
    vm.taskScopeStack[^1]
  else:
    vm.currentTaskId

proc cancelTaskRecursive(vm: var Vm; taskId: int) =
  if not vm.tasks.hasKey(taskId):
    return
  let task = vm.tasks[taskId]
  if task.state in {TsDone, TsFailed, TsCancelled}:
    return
  task.state = TsCancelled
  task.error = newErrorValue("task cancelled")
  for childId in task.children:
    cancelTaskRecursive(vm, childId)

proc runTaskNow(vm: var Vm; task: TaskNode) =
  if task == nil:
    return
  if task.state == TsCancelled:
    return
  if task.deadlineUnix >= 0 and nowMs() > task.deadlineUnix:
    task.state = TsCancelled
    task.error = newErrorValue("task deadline exceeded")
    return

  task.state = TsRunning
  let previousTaskId = vm.currentTaskId
  vm.currentTaskId = task.id
  try:
    task.result = invokeValue(vm, task.fnValue, task.args)
    if task.state != TsCancelled:
      task.state = TsDone
  except VmThrow as thrown:
    task.state = TsFailed
    task.error = thrown.value
  finally:
    vm.currentTaskId = previousTaskId

proc joinTask(vm: var Vm; taskId: int): Value =
  if taskId <= 0 or not vm.tasks.hasKey(taskId):
    return valueNil()
  let task = vm.tasks[taskId]
  if task.state == TsReady:
    if isNil(task.fnValue):
      var last = valueNil()
      for childId in task.children:
        last = joinTask(vm, childId)
      task.result = last
      task.state = TsDone
    else:
      runTaskNow(vm, task)
  case task.state
  of TsDone:
    task.result
  of TsCancelled:
    raiseVmValue(task.error)
  of TsFailed:
    raiseVmValue(task.error)
  of TsReady, TsRunning:
    valueNil()

proc registerTool*(vm: var Vm; schema: ToolSchema; handler: ToolHandler) =
  vm.toolRegistry[schema.name] = ToolRegistration(schema: schema, handler: handler)

proc parseRetryCount(policy: string): int =
  let normalized = policy.strip().toLowerAscii()
  if normalized.len == 0:
    return 0
  if normalized.startsWith("retries:"):
    try:
      return parseInt(normalized.split(':')[1].strip())
    except ValueError:
      return 0
  try:
    parseInt(normalized)
  except ValueError:
    0

proc validateToolArgs(schema: ToolSchema; args: Value): string =
  let request = schema.requestSchema.strip()
  if request.len == 0:
    return ""
  let mapArgs = asMapObj(args)
  if mapArgs == nil:
    return "tool args must be a map"

  let normalized = request.toLowerAscii()
  if normalized.startsWith("required:"):
    let fields = normalized["required:".len .. ^1].split(',')
    for f in fields:
      let name = f.strip()
      if name.len == 0:
        continue
      if not mapArgs.entries.hasKey(name):
        return "missing required tool arg: " & name
  ""

proc buildToolIdempotencyKey(toolName: string; args: Value): string =
  toolName & "#" & $hash(args.toDebugString())

proc attachToolFutureMeta(futureVal: Value; schemaId: int; args: Value; idempotencyKey: string): Value =
  let fut = asFutureObj(futureVal)
  if fut != nil:
    fut.toolSchemaId = schemaId
    fut.toolArgs = args
    fut.toolIdempotencyKey = idempotencyKey
  futureVal

proc executeToolCall(vm: var Vm; schemaId: int; args: Value): Value =
  if vm.module == nil or schemaId < 0 or schemaId >= vm.module.toolSchemas.len:
    return attachToolFutureMeta(newFutureRejectedValue(newErrorValue("invalid tool schema id")), schemaId, args, "")

  let moduleSchema = vm.module.toolSchemas[schemaId]
  let registration =
    if vm.toolRegistry.hasKey(moduleSchema.name):
      vm.toolRegistry[moduleSchema.name]
    else:
      ToolRegistration(schema: moduleSchema, handler: nil)
  let schema = registration.schema

  let cap = if schema.requiredCap.len > 0: schema.requiredCap else: "cap.tool.call:" & schema.name
  requireCapability(vm, cap, "tool.call")

  let validationErr = validateToolArgs(schema, args)
  if validationErr.len > 0:
    return attachToolFutureMeta(newFutureRejectedValue(newErrorValue(validationErr)), schemaId, args, "")

  if vm.quota.toolCallLimit >= 0 and vm.toolCallsUsed >= vm.quota.toolCallLimit:
    return attachToolFutureMeta(newFutureRejectedValue(newErrorValue("quota exceeded: tool calls")), schemaId, args, "")

  if registration.handler == nil:
    return attachToolFutureMeta(newFutureRejectedValue(newErrorValue("tool handler not registered: " & schema.name)), schemaId, args, "")

  var idemKey = ""
  let argMap = asMapObj(args)
  if argMap != nil and argMap.entries.hasKey("idempotency_key"):
    idemKey = argMap.entries["idempotency_key"].asString()
  if idemKey.len == 0:
    idemKey = buildToolIdempotencyKey(schema.name, args)

  if vm.toolIdempotencyCache.hasKey(idemKey):
    return attachToolFutureMeta(newFutureResolvedValue(vm.toolIdempotencyCache[idemKey]), schemaId, args, idemKey)

  var req = ToolCallRequest(
    toolName: schema.name,
    args: args,
    idempotencyKey: idemKey,
    retryPolicy: schema.retryPolicy,
    maxAttempts: max(1, parseRetryCount(schema.retryPolicy) + 1),
    attempt: 0,
    timeoutMs: schema.timeoutMs,
    schemaId: schemaId
  )

  var lastErr = valueNil()
  for attempt in 1..req.maxAttempts:
    req.attempt = attempt
    inc(vm.toolCallsUsed)
    let res = registration.handler(vm, req)
    if res.ok:
      vm.toolIdempotencyCache[idemKey] = res.value
      return attachToolFutureMeta(newFutureResolvedValue(res.value), schemaId, args, idemKey)
    lastErr = if isNil(res.error): newErrorValue("tool call failed") else: res.error

  attachToolFutureMeta(newFutureRejectedValue(lastErr), schemaId, args, idemKey)

type
  ObjEncodeCtx = object
    objToId: Table[pointer, int]
    objects: seq[JsonNode]

  ObjDecodeCtx = object
    objects: seq[HeapObject]
    nodes: seq[JsonNode]

proc encodeValue(v: Value; ctx: var ObjEncodeCtx): JsonNode
proc decodeValue(vm: var Vm; node: JsonNode; ctx: var ObjDecodeCtx): Value

proc encodeObject(obj: HeapObject; ctx: var ObjEncodeCtx): int =
  if obj == nil:
    return -1
  let p = cast[pointer](obj)
  if ctx.objToId.hasKey(p):
    return ctx.objToId[p]

  let id = ctx.objects.len
  ctx.objToId[p] = id
  var entry = %*{
    "id": id,
    "kind": $obj.kind
  }
  ctx.objects.add(entry)

  case obj.kind
  of HkString:
    entry["value"] = %asStringObj(valueFromPtr(obj)).value
  of HkKeyword:
    entry["name"] = %asKeywordObj(valueFromPtr(obj)).name
  of HkArray:
    var items = newJArray()
    for it in asArrayObj(valueFromPtr(obj)).items:
      items.add(encodeValue(it, ctx))
    entry["items"] = items
  of HkMap:
    var m = newJObject()
    for k, v in asMapObj(valueFromPtr(obj)).entries:
      m[k] = encodeValue(v, ctx)
    entry["entries"] = m
  of HkGene:
    let g = asGeneObj(valueFromPtr(obj))
    entry["geneType"] = encodeValue(g.geneType, ctx)
    var props = newJObject()
    for k, v in g.props:
      props[k] = encodeValue(v, ctx)
    entry["props"] = props
    var children = newJArray()
    for child in g.children:
      children.add(encodeValue(child, ctx))
    entry["children"] = children
  of HkFunction:
    let fn = asFunctionObj(valueFromPtr(obj))
    entry["name"] = %fn.name
    entry["fnIndex"] = %fn.fnIndex
    entry["moduleId"] = %fn.moduleId
    entry["arity"] = %fn.arity
    entry["paramNames"] = %fn.paramNames
    entry["paramTypes"] = %fn.paramTypes
    entry["upvalueNames"] = %fn.upvalueNames
    var ups = newJObject()
    for k, v in fn.upvalues:
      ups[k] = encodeValue(v, ctx)
    entry["upvalues"] = ups
    var flags = newJArray()
    for fl in fn.flags:
      flags.add(%($fl))
    entry["flags"] = flags
  of HkNativeFn:
    let n = asNativeFunctionObj(valueFromPtr(obj))
    entry["name"] = %n.name
    entry["arity"] = %n.arity
  of HkClass:
    let cls = asClassObj(valueFromPtr(obj))
    entry["name"] = %cls.name
    entry["superClass"] = encodeValue(cls.superClass, ctx)
    entry["ctor"] = encodeValue(cls.ctor, ctx)
    var methods = newJObject()
    for k, v in cls.methods:
      methods[k] = encodeValue(v, ctx)
    entry["methods"] = methods
  of HkInstance:
    let inst = asInstanceObj(valueFromPtr(obj))
    entry["cls"] = encodeValue(inst.cls, ctx)
    var fields = newJObject()
    for k, v in inst.fields:
      fields[k] = encodeValue(v, ctx)
    entry["fields"] = fields
  of HkFuture:
    let fut = asFutureObj(valueFromPtr(obj))
    entry["state"] = %($fut.state)
    entry["value"] = encodeValue(fut.value, ctx)
    entry["error"] = encodeValue(fut.error, ctx)
    entry["toolSchemaId"] = %fut.toolSchemaId
    entry["toolArgs"] = encodeValue(fut.toolArgs, ctx)
    entry["toolIdempotencyKey"] = %fut.toolIdempotencyKey
  of HkGenerator:
    let g = asGeneratorObj(valueFromPtr(obj))
    entry["state"] = %($g.state)
    entry["fnValue"] = encodeValue(g.fnValue, ctx)
    entry["args"] = %g.args.mapIt(encodeValue(it, ctx))
    entry["lastValue"] = encodeValue(g.lastValue, ctx)
    entry["started"] = %g.started
    entry["finished"] = %g.finished
    entry["fnIndex"] = %g.fnIndex
    entry["ip"] = %g.ip
    entry["stack"] = %g.stack.mapIt(encodeValue(it, ctx))
    entry["locals"] = %g.locals.mapIt(encodeValue(it, ctx))
    var ups = newJObject()
    for k, v in g.upvalues:
      ups[k] = encodeValue(v, ctx)
    entry["upvalues"] = ups
    entry["handlerCatchIps"] = %g.handlerCatchIps
    entry["handlerStackDepths"] = %g.handlerStackDepths
    entry["selfVal"] = encodeValue(g.selfVal, ctx)
  of HkError:
    let e = asErrorObj(valueFromPtr(obj))
    entry["message"] = %e.message

  ctx.objects[id] = entry
  id

proc encodeValue(v: Value; ctx: var ObjEncodeCtx): JsonNode =
  case valueKind(v)
  of VkNil:
    %*{"t": "nil"}
  of VkBool:
    %*{"t": "bool", "v": asBool(v)}
  of VkInt:
    %*{"t": "int", "v": asInt(v)}
  of VkNumber:
    %*{"t": "num", "v": asFloat(v)}
  of VkSymbol:
    %*{"t": "sym", "v": asSymbolName(v)}
  of VkPointer:
    let id = encodeObject(asHeapObject(v), ctx)
    %*{"t": "obj", "id": id}
  of VkUnknown:
    %*{"t": "nil"}

proc decodeObject(vm: var Vm; idx: int; ctx: var ObjDecodeCtx): HeapObject =
  if idx < 0 or idx >= ctx.objects.len:
    return nil
  ctx.objects[idx]

proc initPlaceholder(kindName: string): HeapObject =
  case kindName
  of $HkString:
    StringObj(kind: HkString, value: "")
  of $HkKeyword:
    KeywordObj(kind: HkKeyword, name: "")
  of $HkArray:
    ArrayObj(kind: HkArray, items: @[])
  of $HkMap:
    MapObj(kind: HkMap, entries: initOrderedTable[string, Value]())
  of $HkGene:
    GeneObj(kind: HkGene, geneType: valueNil(), props: initOrderedTable[string, Value](), children: @[])
  of $HkFunction:
    FunctionObj(
      kind: HkFunction,
      name: "",
      fnIndex: -1,
      moduleId: -1,
      arity: 0,
      paramNames: @[],
      paramTypes: @[],
      upvalueNames: @[],
      upvalues: initOrderedTable[string, Value](),
      flags: {}
    )
  of $HkNativeFn:
    NativeFnObj(kind: HkNativeFn, name: "", arity: 0)
  of $HkClass:
    ClassObj(kind: HkClass, name: "", superClass: valueNil(), methods: initOrderedTable[string, Value](), ctor: valueNil())
  of $HkInstance:
    InstanceObj(kind: HkInstance, cls: valueNil(), fields: initOrderedTable[string, Value]())
  of $HkFuture:
    FutureObj(
      kind: HkFuture,
      state: FsPending,
      value: valueNil(),
      error: valueNil(),
      toolSchemaId: -1,
      toolArgs: valueNil(),
      toolIdempotencyKey: ""
    )
  of $HkGenerator:
    GeneratorObj(
      kind: HkGenerator,
      state: GsPending,
      fnValue: valueNil(),
      args: @[],
      lastValue: valueNil(),
      started: false,
      finished: false,
      fnIndex: -1,
      ip: 0,
      stack: @[],
      locals: @[],
      upvalues: initOrderedTable[string, Value](),
      handlerCatchIps: @[],
      handlerStackDepths: @[],
      selfVal: valueNil()
    )
  of $HkError:
    ErrorObj(kind: HkError, message: "")
  else:
    nil

proc decodeValue(vm: var Vm; node: JsonNode; ctx: var ObjDecodeCtx): Value =
  let t = node["t"].getStr()
  case t
  of "nil":
    valueNil()
  of "bool":
    valueBool(node["v"].getBool())
  of "int":
    valueInt(node["v"].getBiggestInt())
  of "num":
    valueFloat(node["v"].getFloat())
  of "sym":
    valueSymbol(node["v"].getStr())
  of "obj":
    let id = node["id"].getInt()
    let obj = decodeObject(vm, id, ctx)
    if obj == nil: valueNil() else: valueFromPtr(obj)
  else:
    valueNil()

proc decodeAllObjects(vm: var Vm; ctx: var ObjDecodeCtx) =
  ctx.objects = newSeq[HeapObject](ctx.nodes.len)
  for i, node in ctx.nodes:
    let placeholder = initPlaceholder(node["kind"].getStr())
    ctx.objects[i] = placeholder
    if placeholder != nil:
      retainHeapObject(placeholder)

  for i, node in ctx.nodes:
    let obj = ctx.objects[i]
    if obj == nil:
      continue
    case obj.kind
    of HkString:
      StringObj(obj).value = node["value"].getStr()
    of HkKeyword:
      KeywordObj(obj).name = node["name"].getStr()
    of HkArray:
      var items: seq[Value] = @[]
      for it in node["items"]:
        items.add(decodeValue(vm, it, ctx))
      ArrayObj(obj).items = items
    of HkMap:
      MapObj(obj).entries = initOrderedTable[string, Value]()
      for k, v in node["entries"]:
        MapObj(obj).entries[k] = decodeValue(vm, v, ctx)
    of HkGene:
      let g = GeneObj(obj)
      g.geneType = decodeValue(vm, node["geneType"], ctx)
      g.props = initOrderedTable[string, Value]()
      for k, v in node["props"]:
        g.props[k] = decodeValue(vm, v, ctx)
      g.children = @[]
      for child in node["children"]:
        g.children.add(decodeValue(vm, child, ctx))
    of HkFunction:
      let fn = FunctionObj(obj)
      fn.name = node["name"].getStr()
      fn.fnIndex = node["fnIndex"].getInt()
      fn.moduleId = if node.hasKey("moduleId"): node["moduleId"].getInt() else: -1
      fn.arity = node["arity"].getInt()
      fn.paramNames = @[]
      for p in node["paramNames"]:
        fn.paramNames.add(p.getStr())
      fn.paramTypes = @[]
      for p in node["paramTypes"]:
        fn.paramTypes.add(p.getStr())
      fn.upvalueNames = @[]
      for p in node["upvalueNames"]:
        fn.upvalueNames.add(p.getStr())
      fn.upvalues = initOrderedTable[string, Value]()
      for k, v in node["upvalues"]:
        fn.upvalues[k] = decodeValue(vm, v, ctx)
      fn.flags = {}
      for fl in node["flags"]:
        let s = fl.getStr()
        case s
        of $FfAsync: fn.flags.incl(FfAsync)
        of $FfGenerator: fn.flags.incl(FfGenerator)
        of $FfMacroLike: fn.flags.incl(FfMacroLike)
        of $FfMethod: fn.flags.incl(FfMethod)
        else: discard
    of HkNativeFn:
      NativeFnObj(obj).name = node["name"].getStr()
      NativeFnObj(obj).arity = node["arity"].getInt()
    of HkClass:
      let cls = ClassObj(obj)
      cls.name = node["name"].getStr()
      cls.superClass = decodeValue(vm, node["superClass"], ctx)
      cls.ctor = decodeValue(vm, node["ctor"], ctx)
      cls.methods = initOrderedTable[string, Value]()
      for k, v in node["methods"]:
        cls.methods[k] = decodeValue(vm, v, ctx)
    of HkInstance:
      let inst = InstanceObj(obj)
      inst.cls = decodeValue(vm, node["cls"], ctx)
      inst.fields = initOrderedTable[string, Value]()
      for k, v in node["fields"]:
        inst.fields[k] = decodeValue(vm, v, ctx)
    of HkFuture:
      let fut = FutureObj(obj)
      let st = node["state"].getStr()
      case st
      of $FsPending: fut.state = FsPending
      of $FsResolved: fut.state = FsResolved
      of $FsRejected: fut.state = FsRejected
      else: fut.state = FsPending
      fut.value = decodeValue(vm, node["value"], ctx)
      fut.error = decodeValue(vm, node["error"], ctx)
      fut.toolSchemaId = if node.hasKey("toolSchemaId"): node["toolSchemaId"].getInt() else: -1
      fut.toolArgs = if node.hasKey("toolArgs"): decodeValue(vm, node["toolArgs"], ctx) else: valueNil()
      fut.toolIdempotencyKey = if node.hasKey("toolIdempotencyKey"): node["toolIdempotencyKey"].getStr() else: ""
    of HkGenerator:
      let g = GeneratorObj(obj)
      let st = node["state"].getStr()
      case st
      of $GsPending: g.state = GsPending
      of $GsRunning: g.state = GsRunning
      of $GsSuspended: g.state = GsSuspended
      of $GsDone: g.state = GsDone
      else: g.state = GsPending
      g.fnValue = decodeValue(vm, node["fnValue"], ctx)
      g.args = @[]
      for it in node["args"]:
        g.args.add(decodeValue(vm, it, ctx))
      g.lastValue = decodeValue(vm, node["lastValue"], ctx)
      g.started = node["started"].getBool()
      g.finished = node["finished"].getBool()
      g.fnIndex = node["fnIndex"].getInt()
      g.ip = node["ip"].getInt()
      g.stack = @[]
      for it in node["stack"]:
        g.stack.add(decodeValue(vm, it, ctx))
      g.locals = @[]
      for it in node["locals"]:
        g.locals.add(decodeValue(vm, it, ctx))
      g.upvalues = initOrderedTable[string, Value]()
      for k, v in node["upvalues"]:
        g.upvalues[k] = decodeValue(vm, v, ctx)
      g.handlerCatchIps = @[]
      for x in node["handlerCatchIps"]:
        g.handlerCatchIps.add(x.getInt())
      g.handlerStackDepths = @[]
      for x in node["handlerStackDepths"]:
        g.handlerStackDepths.add(x.getInt())
      g.selfVal = decodeValue(vm, node["selfVal"], ctx)
    of HkError:
      ErrorObj(obj).message = node["message"].getStr()

proc frameToJson(frame: FrameCtx; ctx: var ObjEncodeCtx): JsonNode =
  var node = newJObject()
  node["fnIndex"] = %(if frame.fnObj != nil: frame.fnObj.fnIndex else: -1)
  node["ip"] = %frame.ip
  node["selfVal"] = encodeValue(frame.selfVal, ctx)
  node["stack"] = %frame.stack.mapIt(encodeValue(it, ctx))
  node["locals"] = %frame.locals.mapIt(encodeValue(it, ctx))
  var ups = newJObject()
  for k, v in frame.upvalues:
    ups[k] = encodeValue(v, ctx)
  node["upvalues"] = ups
  var cips: seq[int] = @[]
  var depths: seq[int] = @[]
  encodeHandlers(frame, cips, depths)
  node["handlerCatchIps"] = %cips
  node["handlerStackDepths"] = %depths
  node

proc hydrateFunctionValue(vm: var Vm; fnIndex: int): Value =
  if vm.module == nil or fnIndex < 0 or fnIndex >= vm.module.functions.len:
    return valueNil()
  let meta = vm.module.functions[fnIndex]
  let moduleId = ensureLoadedModule(vm, vm.module)
  let fnVal = newFunctionValue(meta.name, fnIndex, meta.arity, moduleId)
  let fnObj = asFunctionObj(fnVal)
  if fnObj != nil:
    for p in meta.params:
      fnObj.paramNames.add(p.name)
      fnObj.paramTypes.add(p.typeAnn)
  fnVal

proc jsonToFrame(vm: var Vm; node: JsonNode; ctx: var ObjDecodeCtx): FrameCtx =
  let fnIndex = node["fnIndex"].getInt()
  let fnVal = hydrateFunctionValue(vm, fnIndex)
  let fnObj = asFunctionObj(fnVal)
  result = FrameCtx(
    fnMeta: (if vm.module != nil and fnIndex >= 0 and fnIndex < vm.module.functions.len: vm.module.functions[fnIndex] else: nil),
    fnObj: fnObj,
    ip: node["ip"].getInt(),
    stack: @[],
    locals: @[],
    selfVal: decodeValue(vm, node["selfVal"], ctx),
    upvalues: initOrderedTable[string, Value](),
    handlers: @[]
  )
  for it in node["stack"]:
    result.stack.add(decodeValue(vm, it, ctx))
  for it in node["locals"]:
    result.locals.add(decodeValue(vm, it, ctx))
  for k, v in node["upvalues"]:
    result.upvalues[k] = decodeValue(vm, v, ctx)
  var cips: seq[int] = @[]
  for x in node["handlerCatchIps"]:
    cips.add(x.getInt())
  var depths: seq[int] = @[]
  for x in node["handlerStackDepths"]:
    depths.add(x.getInt())
  result.handlers = decodeHandlers(cips, depths)

proc checkpointToBytes(vm: Vm; frame: FrameCtx): seq[byte] =
  var ctx = ObjEncodeCtx(objToId: initTable[pointer, int](), objects: @[])
  var root = newJObject()
  root["version"] = %1
  root["deterministic"] = %vm.deterministic
  root["rngState"] = %($vm.rngState)
  root["cpuStepsUsed"] = %vm.cpuStepsUsed
  root["toolCallsUsed"] = %vm.toolCallsUsed
  root["startedAtMs"] = %vm.startedAtMs
  root["quota"] = %*{
    "cpu": vm.quota.cpuStepLimit,
    "heap": vm.quota.heapObjectLimit,
    "time": vm.quota.wallClockMsLimit,
    "tool": vm.quota.toolCallLimit
  }
  var globalsJson = newJObject()
  for sid, value in vm.globals:
    globalsJson[symbolName(sid)] = encodeValue(value, ctx)
  root["globals"] = globalsJson

  var rootCaps = newJArray()
  for cap in vm.rootCapabilities:
    rootCaps.add(%cap)
  root["rootCapabilities"] = rootCaps

  var capStack = newJArray()
  for capSet in vm.capabilityStack:
    var setNode = newJArray()
    for cap in capSet:
      setNode.add(%cap)
    capStack.add(setNode)
  root["capabilityStack"] = capStack

  var tasksJson = newJArray()
  for id, task in vm.tasks:
    var t = newJObject()
    t["id"] = %id
    t["parent"] = %task.parent
    t["children"] = %task.children
    t["state"] = %($task.state)
    t["deadlineUnix"] = %task.deadlineUnix
    t["cancelToken"] = %($task.cancelToken)
    t["result"] = encodeValue(task.result, ctx)
    t["error"] = encodeValue(task.error, ctx)
    t["fnValue"] = encodeValue(task.fnValue, ctx)
    t["args"] = %task.args.mapIt(encodeValue(it, ctx))
    tasksJson.add(t)
  root["tasks"] = tasksJson
  root["taskScopeStack"] = %vm.taskScopeStack
  root["currentTaskId"] = %vm.currentTaskId
  root["nextTaskId"] = %vm.nextTaskId

  root["frame"] = frameToJson(frame, ctx)
  root["objects"] = %ctx.objects

  let payload = $root
  result = @['G'.byte, 'C'.byte, 'H'.byte, 'K'.byte, 1.byte]
  for ch in payload:
    result.add(byte(ch.ord))

proc restoreFromBytes(vm: var Vm; data: openArray[byte]; frame: var FrameCtx): bool =
  if data.len < 5:
    return false
  if char(data[0]) != 'G' or char(data[1]) != 'C' or char(data[2]) != 'H' or char(data[3]) != 'K':
    return false

  var payload = newString(data.len - 5)
  for i in 5..<data.len:
    payload[i - 5] = char(data[i])

  let root = parseJson(payload)
  var decodeCtx = ObjDecodeCtx(nodes: @[], objects: @[])
  for node in root["objects"]:
    decodeCtx.nodes.add(node)
  decodeAllObjects(vm, decodeCtx)

  vm.globals = initOrderedTable[int, Value]()
  for k, v in root["globals"]:
    vm.globals[internSymbol(k)] = decodeValue(vm, v, decodeCtx)

  vm.rootCapabilities = initHashSet[string]()
  for cap in root["rootCapabilities"]:
    vm.rootCapabilities.incl(cap.getStr())

  vm.capabilityStack = @[]
  for setNode in root["capabilityStack"]:
    var hs = initHashSet[string]()
    for cap in setNode:
      hs.incl(cap.getStr())
    vm.capabilityStack.add(hs)

  vm.tasks = initOrderedTable[int, TaskNode]()
  for t in root["tasks"]:
    let task = TaskNode(
      id: t["id"].getInt(),
      parent: t["parent"].getInt(),
      children: @[],
      state: TsReady,
      deadlineUnix: t["deadlineUnix"].getBiggestInt(),
      cancelToken: parseUInt(t["cancelToken"].getStr()),
      result: decodeValue(vm, t["result"], decodeCtx),
      error: decodeValue(vm, t["error"], decodeCtx),
      fnValue: decodeValue(vm, t["fnValue"], decodeCtx),
      args: @[]
    )
    for c in t["children"]:
      task.children.add(c.getInt())
    for a in t["args"]:
      task.args.add(decodeValue(vm, a, decodeCtx))
    let st = t["state"].getStr()
    case st
    of $TsReady: task.state = TsReady
    of $TsRunning: task.state = TsRunning
    of $TsDone: task.state = TsDone
    of $TsCancelled: task.state = TsCancelled
    of $TsFailed: task.state = TsFailed
    else: task.state = TsReady
    vm.tasks[task.id] = task

  vm.taskScopeStack = @[]
  for x in root["taskScopeStack"]:
    vm.taskScopeStack.add(x.getInt())
  vm.currentTaskId = root["currentTaskId"].getInt()
  vm.nextTaskId = root["nextTaskId"].getInt()

  vm.deterministic = root["deterministic"].getBool()
  vm.rngState = parseUInt(root["rngState"].getStr())
  vm.cpuStepsUsed = root["cpuStepsUsed"].getBiggestInt()
  vm.toolCallsUsed = root["toolCallsUsed"].getBiggestInt()
  vm.startedAtMs = root["startedAtMs"].getBiggestInt()
  vm.quota.cpuStepLimit = root["quota"]["cpu"].getBiggestInt()
  vm.quota.heapObjectLimit = root["quota"]["heap"].getBiggestInt()
  vm.quota.wallClockMsLimit = root["quota"]["time"].getBiggestInt()
  vm.quota.toolCallLimit = root["quota"]["tool"].getBiggestInt()

  frame = jsonToFrame(vm, root["frame"], decodeCtx)
  true

proc saveCheckpointToFile*(vm: Vm; path: string; frame: FrameCtx) =
  let bytes = checkpointToBytes(vm, frame)
  var content = newString(bytes.len)
  for i, b in bytes:
    content[i] = char(b)
  writeFile(path, content)

proc loadCheckpointFromFile*(vm: var Vm; path: string; frame: var FrameCtx): bool =
  if not fileExists(path):
    return false
  let content = readFile(path)
  var bytes = newSeq[byte](content.len)
  for i, ch in content:
    bytes[i] = byte(ord(ch))
  restoreFromBytes(vm, bytes, frame)

proc saveVmCheckpoint*(vm: Vm; path: string) =
  var emptyFrame = FrameCtx(
    fnMeta: nil,
    fnObj: nil,
    ip: 0,
    stack: @[],
    locals: @[],
    selfVal: valueNil(),
    upvalues: initOrderedTable[string, Value](),
    handlers: @[]
  )
  saveCheckpointToFile(vm, path, emptyFrame)

proc loadVmCheckpoint*(vm: var Vm; path: string): bool =
  var frame: FrameCtx
  loadCheckpointFromFile(vm, path, frame)

proc executeFunction(
  vm: var Vm;
  fnObj: FunctionObj;
  args: seq[Value];
  selfValue: Value = valueNil();
  resumeGen: GeneratorObj = nil
): Value =
  var targetModule = vm.module
  if fnObj != nil and fnObj.moduleId >= 0 and fnObj.moduleId < vm.loadedModules.len:
    targetModule = vm.loadedModules[fnObj.moduleId]

  if targetModule == nil:
    return valueNil()

  let prevModule = vm.module
  vm.module = targetModule
  defer:
    vm.module = prevModule

  if fnObj.fnIndex < 0 or fnObj.fnIndex >= targetModule.functions.len:
    raise newException(VmRuntimeError, "invalid function index")

  let fnMeta = targetModule.functions[fnObj.fnIndex]
  var frame: FrameCtx
  if resumeGen != nil and resumeGen.started:
    frame = makeFrameFromGenerator(vm, resumeGen)
  else:
    frame = FrameCtx(
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

    if resumeGen != nil:
      resumeGen.started = true
      resumeGen.finished = false
      resumeGen.fnIndex = fnObj.fnIndex
      resumeGen.selfVal = selfValue

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
      checkQuota(vm)
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
        let sid = int(inst.b)
        if vm.namespaceStack.len > 0:
          let nsMap = asMapObj(vm.namespaceStack[^1])
          let key = symbolName(sid)
          if nsMap != nil and nsMap.entries.hasKey(key):
            pushValue(frame, nsMap.entries[key])
          else:
            pushValue(frame, getGlobal(vm, sid))
        else:
          pushValue(frame, getGlobal(vm, sid))
      of OpStoreGlobal:
        let v = popValue(frame)
        setScopedGlobal(vm, int(inst.b), v)
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
          pushValue(frame, newStringValue(a.asString() & b.asString()))
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
        if isInt(a) and isInt(b) and asInt(b) >= 0:
          var base = asInt(a)
          var exp = asInt(b)
          var acc = 1'i64
          while exp > 0:
            if (exp and 1) == 1:
              acc = acc * base
            base = base * base
            exp = exp shr 1
          pushValue(frame, valueInt(acc))
        else:
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
        let retVal = if frame.stack.len > 0: popValue(frame) else: valueNil()
        if resumeGen != nil:
          resumeGen.lastValue = retVal
          resumeGen.finished = true
          resumeGen.state = GsDone
          resumeGen.ip = frame.ip
          resumeGen.stack = @[]
        return retVal

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

      of OpCallKw:
        let argc = int(inst.c)
        let kwargs = popValue(frame)
        let args = popArgs(frame, argc)
        let callee = popValue(frame)
        let callResult = invokeValue(vm, callee, args, valueNil(), kwargs)
        pushValue(frame, callResult)

      of OpCallMacro:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let callee = popValue(frame)
        let callResult = invokeValue(vm, callee, args)
        pushValue(frame, callResult)

      of OpCallMethod:
        let argc = int(inst.c)
        let args = popArgs(frame, argc)
        let receiver = popValue(frame)
        let methodName = symbolName(int(inst.b))
        let arrayMethod = invokeArrayMethod(vm, receiver, methodName, args, valueNil())
        if arrayMethod.handled:
          pushValue(frame, arrayMethod.value)
          continue
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

      of OpCallMethodKw:
        let argc = int(inst.c)
        let kwargs = popValue(frame)
        let args = popArgs(frame, argc)
        let receiver = popValue(frame)
        let methodName = symbolName(int(inst.b))
        let arrayMethod = invokeArrayMethod(vm, receiver, methodName, args, kwargs)
        if arrayMethod.handled:
          pushValue(frame, arrayMethod.value)
          continue
        var methodValue = getMember(receiver, methodName)

        if isNil(methodValue):
          let sid = internSymbol(methodName)
          if vm.globals.hasKey(sid):
            var methodArgs: seq[Value] = @[receiver]
            for a in args:
              methodArgs.add(a)
            let callResult = invokeValue(vm, vm.globals[sid], methodArgs, receiver, kwargs)
            pushValue(frame, callResult)
          elif argc == 0 and not kwargsHasEntries(kwargs):
            pushValue(frame, getMember(receiver, methodName))
          else:
            handleThrow(newErrorValue("method not found: " & methodName))
        else:
          let callResult = invokeValue(vm, methodValue, args, receiver, kwargs)
          pushValue(frame, callResult)

      of OpCallSuper:
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

      of OpCallSuperKw:
        let argc = int(inst.c)
        let kwargs = popValue(frame)
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
        let callResult = invokeValue(vm, superCls.methods[methodName], args, frame.selfVal, kwargs)
        pushValue(frame, callResult)

      of OpCallerEval:
        pushValue(frame, valueNil())

      of OpYield:
        let yielded = if frame.stack.len > 0: popValue(frame) else: valueNil()
        if resumeGen != nil:
          resumeGen.lastValue = yielded
          resumeGen.state = GsSuspended
          resumeGen.finished = false
          persistFrameToGenerator(resumeGen, frame)
        return yielded
      of OpResume:
        let genVal = popValue(frame)
        pushValue(frame, resumeValue(vm, genVal))

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
        let aliasSid = int(inst.b)
        var modVal = valueNil()

        if inst.mode == 1:
          let requested = getConstPath(vm.module, int(inst.c))
          let baseSource = if vm.module != nil: vm.module.sourcePath else: ""
          let resolved = resolveImportPath(baseSource, requested)
          modVal = runImportedModule(vm, resolved)
        else:
          modVal = getGlobal(vm, aliasSid)
          if asMapObj(modVal) == nil:
            modVal = newMapValue()

        setScopedGlobal(vm, aliasSid, modVal)
        pushValue(frame, modVal)
      of OpExport:
        discard
      of OpNsEnter:
        let sid = int(inst.b)
        let nsName = symbolName(sid)
        var nsVal = valueNil()

        if vm.namespaceStack.len == 0:
          nsVal = getGlobal(vm, sid)
          if asMapObj(nsVal) == nil:
            nsVal = newMapValue()
            setGlobal(vm, sid, nsVal)
        else:
          let parent = asMapObj(vm.namespaceStack[^1])
          if parent != nil and parent.entries.hasKey(nsName):
            nsVal = parent.entries[nsName]
          if asMapObj(nsVal) == nil:
            nsVal = newMapValue()
            if parent != nil:
              parent.entries[nsName] = nsVal

        vm.namespaceStack.add(nsVal)
      of OpNsExit:
        if vm.namespaceStack.len > 0:
          vm.namespaceStack.setLen(vm.namespaceStack.len - 1)

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

      of OpThreadSpawn:
        requireCapability(vm, "cap.thread.spawn", "thread.spawn")
        pushValue(frame, valueNil())
      of OpTaskScopeEnter:
        requireCapability(vm, "cap.thread.spawn", "task.scope")
        let parent = currentSupervisor(vm)
        let scope = newTaskNode(vm, parent, valueNil(), @[])
        vm.taskScopeStack.add(scope.id)
        pushValue(frame, valueInt(scope.id))
      of OpTaskSpawn:
        requireCapability(vm, "cap.thread.spawn", "task.spawn")
        let argc = int(inst.c)
        let taskArgs = popArgs(frame, argc)
        let fnValue = popValue(frame)
        let parent = currentSupervisor(vm)
        let task = newTaskNode(vm, parent, fnValue, taskArgs)
        pushValue(frame, valueInt(task.id))
      of OpTaskJoin:
        if frame.stack.len > 0:
          let taskIdVal = popValue(frame)
          let taskId = if isInt(taskIdVal): int(asInt(taskIdVal)) else: -1
          if taskId > 0:
            pushValue(frame, joinTask(vm, taskId))
          else:
            let scopeId = if vm.taskScopeStack.len > 0: vm.taskScopeStack[^1] else: -1
            var last = valueNil()
            if scopeId > 0 and vm.tasks.hasKey(scopeId):
              for childId in vm.tasks[scopeId].children:
                last = joinTask(vm, childId)
            pushValue(frame, last)
            if vm.taskScopeStack.len > 0:
              vm.taskScopeStack.setLen(vm.taskScopeStack.len - 1)
        else:
          pushValue(frame, valueNil())
      of OpTaskCancel:
        requireCapability(vm, "cap.thread.spawn", "task.cancel")
        let taskIdVal = popValue(frame)
        let taskId = if isInt(taskIdVal): int(asInt(taskIdVal)) else: -1
        if taskId > 0:
          cancelTaskRecursive(vm, taskId)
        pushValue(frame, valueNil())
      of OpTaskDeadline:
        let deadlineVal = popValue(frame)
        let taskIdVal = popValue(frame)
        let taskId = if isInt(taskIdVal): int(asInt(taskIdVal)) else: -1
        let deltaMs = if isInt(deadlineVal): asInt(deadlineVal) else: 0
        if taskId > 0 and vm.tasks.hasKey(taskId):
          vm.tasks[taskId].deadlineUnix = nowMs() + deltaMs
        pushValue(frame, valueNil())

      of OpCapEnter:
        var caps = initHashSet[string]()
        let idx = int(inst.b)
        if idx >= 0 and idx < vm.module.effects.len:
          for cap in vm.module.effects[idx].capabilities:
            caps.incl(cap)
        if vm.capabilityStack.len == 0:
          for cap in vm.rootCapabilities:
            caps.incl(cap)
        else:
          for cap in vm.capabilityStack[^1]:
            caps.incl(cap)
        vm.capabilityStack.add(caps)
      of OpCapExit:
        if vm.capabilityStack.len > 0:
          vm.capabilityStack.setLen(vm.capabilityStack.len - 1)
      of OpCapAssert:
        let capName = symbolName(int(inst.b))
        if not hasCapability(vm, capName):
          handleThrow(newErrorValue("capability denied: " & capName))
      of OpQuotaSet:
        let amount = popValue(frame)
        let kindVal = popValue(frame)
        let kind = parseQuotaKind(kindVal)
        var limitValue: int64
        if isInt(amount):
          limitValue = asInt(amount)
        else:
          try:
            limitValue = parseInt(amount.asString()).int64
          except ValueError:
            limitValue = -1
        setQuotaLimit(vm, kind, limitValue)
        pushValue(frame, valueNil())
      of OpQuotaCheck:
        let amount = popValue(frame)
        let kindVal = popValue(frame)
        let kind = parseQuotaKind(kindVal)
        let required = if isInt(amount): asInt(amount) else: 0
        let limit = quotaLimit(vm, kind)
        if limit >= 0 and quotaCurrent(vm, kind) + required > limit:
          handleThrow(newErrorValue("quota check failed"))
        pushValue(frame, valueBool(true))
      of OpCheckpointHint:
        vm.diagnostics.add("checkpoint hint at ip=" & $(frame.ip - 1))
      of OpStateSave:
        let slotVal = popValue(frame)
        let slot = if isInt(slotVal): int(asInt(slotVal)) else: 0
        vm.checkpointSlots[slot] = checkpointToBytes(vm, frame)
        pushValue(frame, valueInt(slot))
      of OpStateRestore:
        let slotVal = popValue(frame)
        let slot = if isInt(slotVal): int(asInt(slotVal)) else: -1
        if slot >= 0 and vm.checkpointSlots.hasKey(slot):
          var restoredFrame: FrameCtx
          if restoreFromBytes(vm, vm.checkpointSlots[slot], restoredFrame):
            let resumeIp = frame.ip
            frame = restoredFrame
            frame.ip = resumeIp
            pushValue(frame, valueInt(slot))
          else:
            handleThrow(newErrorValue("checkpoint restore failed"))
        else:
          handleThrow(newErrorValue("checkpoint slot not found"))

      of OpToolPrep:
        vm.preparedToolSchemaId = int(inst.b)
        pushValue(frame, valueInt(inst.b.int))
      of OpToolCall:
        let req = popValue(frame)
        var schemaId = vm.preparedToolSchemaId
        if frame.stack.len > 0 and isInt(peekValue(frame)):
          let tokenId = int(asInt(popValue(frame)))
          if schemaId < 0:
            schemaId = tokenId
        vm.preparedToolSchemaId = -1
        pushValue(frame, executeToolCall(vm, schemaId, req))
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
        let future = popValue(frame)
        let fut = asFutureObj(future)
        if fut == nil:
          pushValue(frame, future)
        elif fut.state == FsResolved:
          pushValue(frame, fut.value)
        elif fut.state == FsRejected:
          handleThrow(fut.error)
        else:
          pushValue(frame, valueNil())
      of OpToolRetry:
        let future = popValue(frame)
        let fut = asFutureObj(future)
        if fut == nil:
          pushValue(frame, future)
        else:
          let schemaId = fut.toolSchemaId
          if schemaId < 0:
            handleThrow(newErrorValue("tool retry without schema metadata"))
          else:
            pushValue(frame, executeToolCall(vm, schemaId, fut.toolArgs))

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
        pushValue(frame, valueBool(iteratorHasNext(vm, it)))
      of OpIterNext:
        let it = popValue(frame)
        pushValue(frame, iteratorNext(vm, it))

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
    let outValue = popValue(frame)
    if resumeGen != nil:
      resumeGen.lastValue = outValue
      resumeGen.finished = true
      resumeGen.state = GsDone
    outValue
  else:
    if resumeGen != nil:
      resumeGen.finished = true
      resumeGen.state = GsDone
    valueNil()

proc resumeValue*(vm: var Vm; value: Value): Value =
  let gen = asGeneratorObj(value)
  if gen == nil:
    return value

  if gen.finished or gen.state == GsDone:
    return gen.lastValue

  let fnObj = asFunctionObj(gen.fnValue)
  if fnObj == nil:
    return valueNil()

  gen.state = GsRunning
  let outValue = executeFunction(vm, fnObj, gen.args, gen.selfVal, gen)

  if gen.state == GsRunning:
    gen.state = GsDone
    gen.finished = true
    gen.lastValue = outValue
    return valueNil()

  outValue

proc kwargsHasEntries(kwargs: Value): bool =
  let m = asMapObj(kwargs)
  m != nil and len(m.entries) > 0

proc remainingRequiredPositional(params: seq[AirParam]; startIdx: int): int =
  for i in startIdx..<params.len:
    if (not params[i].isKeyword) and (not params[i].hasDefault) and (not params[i].isVariadic):
      inc(result)

proc bindFunctionArgs(fnMeta: AirFunction; args: seq[Value]; kwargs: Value): seq[Value] =
  var kwEntries = initOrderedTable[string, Value]()
  let kwMap = asMapObj(kwargs)
  if kwMap != nil:
    for k, v in kwMap.entries:
      kwEntries[k] = v

  var keywordNames = initHashSet[string]()
  var maxPositional = 0
  for param in fnMeta.params:
    if param.isKeyword:
      keywordNames.incl(param.name)
    elif not param.isVariadic:
      inc(maxPositional)

  for k in kwEntries.keys:
    if k notin keywordNames:
      raiseVmValue(newErrorValue("unknown keyword argument: ^" & k))

  result = newSeq[Value](fnMeta.params.len)
  for i in 0..<result.len:
    result[i] = valueNil()

  var posIdx = 0
  for idx, param in fnMeta.params:
    if param.isKeyword:
      continue

    if param.isVariadic:
      var rest: seq[Value] = @[]
      while posIdx < args.len:
        rest.add(args[posIdx])
        inc(posIdx)
      result[idx] = newArrayValue(rest)
      continue

    let requiredAfter = remainingRequiredPositional(fnMeta.params, idx + 1)
    let available = args.len - posIdx

    if param.hasDefault:
      if available > requiredAfter:
        result[idx] = args[posIdx]
        inc(posIdx)
      else:
        result[idx] = param.defaultValue
    else:
      if available > requiredAfter:
        result[idx] = args[posIdx]
        inc(posIdx)
      else:
        raiseVmValue(newErrorValue("missing required argument: " & param.name))

  if posIdx < args.len:
    raiseVmValue(newErrorValue("too many positional arguments: expected at most " & $maxPositional & " got " & $args.len))

  for idx, param in fnMeta.params:
    if not param.isKeyword:
      continue
    if kwEntries.hasKey(param.name):
      result[idx] = kwEntries[param.name]
    elif param.hasDefault:
      result[idx] = param.defaultValue
    else:
      raiseVmValue(newErrorValue("missing required keyword argument: ^" & param.name))

proc invokeValue(vm: var Vm; callee: Value; args: seq[Value]; selfValue: Value = valueNil(); kwargs: Value = valueNil()): Value =
  if isNil(callee):
    raiseVmValue(newErrorValue("attempted to call nil"))

  if isSymbol(callee):
    let sid = asSymbolId(callee)
    if vm.globals.hasKey(sid):
      return invokeValue(vm, vm.globals[sid], args, selfValue, kwargs)
    raiseVmValue(newErrorValue("unknown callable symbol: " & asSymbolName(callee)))

  let nativeObj = asNativeFunctionObj(callee)
  if nativeObj != nil:
    if kwargsHasEntries(kwargs):
      raiseVmValue(newErrorValue("native functions do not accept keyword arguments: " & nativeObj.name))
    let sid = internSymbol(nativeObj.name)
    if not vm.natives.hasKey(sid):
      raiseVmValue(newErrorValue("native not registered: " & nativeObj.name))
    let entry = vm.natives[sid]
    if entry.arity >= 0 and args.len != entry.arity:
      raiseVmValue(newErrorValue("native arity mismatch for " & entry.name))
    if entry.caps.len > 0:
      for cap in entry.caps:
        if not hasCapability(vm, cap):
          raiseVmValue(newErrorValue("capability denied for native " & entry.name & ": " & cap))
    return entry.callback(vm, args)

  let fnObj = asFunctionObj(callee)
  if fnObj != nil:
    var fnModule = vm.module
    if fnObj.moduleId >= 0 and fnObj.moduleId < vm.loadedModules.len:
      fnModule = vm.loadedModules[fnObj.moduleId]

    if fnModule == nil or fnObj.fnIndex < 0 or fnObj.fnIndex >= fnModule.functions.len:
      raiseVmValue(newErrorValue("invalid function metadata"))

    let fnMeta = fnModule.functions[fnObj.fnIndex]
    let boundArgs = bindFunctionArgs(fnMeta, args, kwargs)

    for i, paramType in fnObj.paramTypes:
      if i < boundArgs.len and paramType.len > 0 and not expectType(boundArgs[i], paramType):
        raiseVmValue(newErrorValue("type mismatch for parameter " & fnObj.paramNames[i] & ": expected " & paramType & " got " & inferTypeName(boundArgs[i])))

    if FfGenerator in fnObj.flags:
      let genVal = newGeneratorValue(callee, boundArgs)
      let gen = asGeneratorObj(genVal)
      if gen != nil:
        gen.selfVal = selfValue
        gen.fnIndex = fnObj.fnIndex
        for name in fnObj.upvalueNames:
          if fnObj.upvalues.hasKey(name):
            gen.upvalues[name] = fnObj.upvalues[name]
      return genVal

    return executeFunction(vm, fnObj, boundArgs, selfValue)

  let cls = asClassObj(callee)
  if cls != nil:
    let instance = newInstanceValue(callee)
    if not isNil(cls.ctor):
      discard invokeValue(vm, cls.ctor, args, instance, kwargs)
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

  vm.startedAtMs = nowMs()
  vm.cpuStepsUsed = 0
  vm.toolCallsUsed = 0
  vm.preparedToolSchemaId = -1
  vm.tasks = initOrderedTable[int, TaskNode]()
  vm.tasks[0] = TaskNode(
    id: 0,
    parent: -1,
    children: @[],
    state: TsRunning,
    deadlineUnix: -1,
    cancelToken: 0,
    result: valueNil(),
    error: valueNil(),
    fnValue: valueNil(),
    args: @[]
  )
  vm.currentTaskId = 0
  vm.nextTaskId = 1
  vm.taskScopeStack = @[]
  vm.namespaceStack = @[]

  let mainModuleId = ensureLoadedModule(vm, vm.module)
  let mainMeta = vm.module.functions[vm.module.mainFn]
  let mainVal = newFunctionValue(mainMeta.name, vm.module.mainFn, mainMeta.arity, mainModuleId)
  let mainObj = asFunctionObj(mainVal)
  for p in mainMeta.params:
    mainObj.paramNames.add(p.name)
    mainObj.paramTypes.add(p.typeAnn)

  try:
    executeFunction(vm, mainObj, @[])
  except VmThrow as thrown:
    raise newException(VmRuntimeError, "uncaught error: " & thrown.value.toDebugString())

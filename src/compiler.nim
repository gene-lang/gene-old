import std/[strutils, tables, os]
import ./types
import ./parser
import ./ir

type
  CompileError* = object of CatchableError

  ValueScopeKind = enum
    VskLocal
    VskUpvalue
    VskGlobal

  LocalBinding = object
    slot: int
    symId: int
    typeAnn: string

  LoopContext = ref object
    startIp: int
    continueIp: int
    breakPatches: seq[int]

  FnContext = ref object
    m: AirModule
    fn: AirFunction
    parent: FnContext
    locals: OrderedTable[string, LocalBinding]
    upvalues: OrderedTable[string, int]
    loops: seq[LoopContext]
    isTopLevel: bool

proc fail(node: AstNode; msg: string): ref CompileError =
  new(result)
  result.msg = "compile error at " & $node.line & ":" & $node.col & " - " & msg

proc mkSymbol(line, col: int; text: string): AstNode =
  AstNode(kind: AkSymbol, line: line, col: col, text: text)

proc runtimeSym(m: AirModule; name: string): int =
  discard m.internSymbol(name)
  internSymbol(name)

proc ensureToolSchema(m: AirModule; toolName: string): int =
  for i, schema in m.toolSchemas:
    if schema.name == toolName:
      return i

  m.toolSchemas.add(ToolSchema(
    name: toolName,
    requestSchema: "",
    responseSchema: "",
    timeoutMs: 30000,
    retryPolicy: "retries:0",
    requiredCap: "cap.tool.call:" & toolName
  ))
  m.toolSchemas.high

proc parseIntMaybe(s: string; outVal: var int): bool =
  try:
    outVal = parseInt(s)
    true
  except ValueError:
    false

proc emit(ctx: FnContext; op: AirOpcode; mode: uint8 = 0; a: uint8 = 0; b: uint32 = 0; c: uint32 = 0; d: uint32 = 0): int {.discardable.} =
  ctx.fn.emit(newInst(op, mode, a, b, c, d))

proc emitConst(ctx: FnContext; v: Value): int {.discardable.} =
  let idx = ctx.m.addConstant(v)
  ctx.emit(OpConst, b = idx.uint32)

proc declareLocal(ctx: FnContext; name: string; typeAnn = ""): int =
  let slot = ctx.fn.localCount
  inc(ctx.fn.localCount)
  let symId = runtimeSym(ctx.m, name)
  ctx.fn.ensureLocalSymbolCapacity(slot)
  ctx.fn.localSymbols[slot] = symId
  ctx.locals[name] = LocalBinding(slot: slot, symId: symId, typeAnn: typeAnn)
  slot

proc resolveVar(ctx: FnContext; name: string): tuple[kind: ValueScopeKind, idx: int] =
  if ctx.locals.hasKey(name):
    return (VskLocal, ctx.locals[name].slot)

  var probe = ctx.parent
  while probe != nil:
    if probe.locals.hasKey(name):
      if not ctx.upvalues.hasKey(name):
        let upIdx = ctx.fn.upvalueSymbols.len
        ctx.upvalues[name] = upIdx
        ctx.fn.upvalueSymbols.add(runtimeSym(ctx.m, name))
      return (VskUpvalue, ctx.upvalues[name])
    probe = probe.parent

  (VskGlobal, runtimeSym(ctx.m, name))

proc compileExpr(ctx: FnContext; node: AstNode)

proc parseTypedName(node: AstNode; fallbackType = ""): tuple[name: string, typeAnn: string] =
  if node.kind != AkSymbol:
    return ("", fallbackType)

  let raw = node.text
  if raw.endsWith(":"):
    return (raw[0..^2], fallbackType)

  let idx = raw.find(':')
  if idx > 0:
    return (raw[0..<idx], raw[idx + 1 .. ^1])

  (raw, fallbackType)

proc compileSymbolLookup(ctx: FnContext; sym: string)

proc splitPath(symbolText: string): seq[string] =
  symbolText.split('/')

proc compilePathLookup(ctx: FnContext; symbolText: string) =
  let parts = splitPath(symbolText)
  if parts.len == 0:
    ctx.emit(OpConstNil)
    return

  if symbolText.startsWith("/"):
    ctx.emit(OpLoadSelf)
  else:
    compileSymbolLookup(ctx, parts[0])

  let start = if symbolText.startsWith("/"): 1 else: 1
  for i in start..<parts.len:
    let segment = parts[i]
    if segment.len == 0:
      continue

    var idx: int
    if parseIntMaybe(segment, idx):
      ctx.emit(OpGetChild, b = idx.uint32)
    elif segment.startsWith(".") and segment.len > 1:
      let sid = runtimeSym(ctx.m, segment[1..^1])
      ctx.emit(OpGetMember, b = sid.uint32)
    else:
      let sid = runtimeSym(ctx.m, segment)
      ctx.emit(OpGetMember, b = sid.uint32)

proc compileSymbolLookup(ctx: FnContext; sym: string) =
  if sym == "$program":
    discard ctx.emitConst(newStringValue("gene"))
    return

  if sym.startsWith("$env/") and sym.len > 5:
    let envName = sym[5..^1]
    discard ctx.emitConst(newStringValue(getEnv(envName, "")))
    return

  if sym.contains('/'):
    compilePathLookup(ctx, sym)
    return

  let resolved = resolveVar(ctx, sym)
  case resolved.kind
  of VskLocal:
    ctx.emit(OpLoadLocal, b = resolved.idx.uint32)
  of VskUpvalue:
    ctx.emit(OpLoadUpvalue, b = resolved.idx.uint32)
  of VskGlobal:
    ctx.emit(OpLoadGlobal, b = resolved.idx.uint32)

proc compileLValueStore(ctx: FnContext; lhs: AstNode; valueExpr: AstNode; compoundOp = "") =
  if lhs.kind != AkSymbol:
    raise fail(lhs, "assignment target must be a symbol or path")

  let target = lhs.text

  if target.contains('/'):
    let parts = splitPath(target)
    if parts.len < 2:
      raise fail(lhs, "invalid path assignment")

    if target.startsWith("/"):
      ctx.emit(OpLoadSelf)
    else:
      compileSymbolLookup(ctx, parts[0])

    let start = 1
    for i in start..<(parts.len - 1):
      let seg = parts[i]
      if seg.len == 0:
        continue
      var idx: int
      if parseIntMaybe(seg, idx):
        ctx.emit(OpGetChild, b = idx.uint32)
      else:
        let sid = runtimeSym(ctx.m, seg)
        ctx.emit(OpGetMember, b = sid.uint32)

    if compoundOp.len > 0:
      let lastSeg = parts[^1]
      var tmpIdx: int
      if parseIntMaybe(lastSeg, tmpIdx):
        ctx.emit(OpGetChild, b = tmpIdx.uint32)
      else:
        let sid = runtimeSym(ctx.m, lastSeg)
        ctx.emit(OpGetMember, b = sid.uint32)

      compileExpr(ctx, valueExpr)
      case compoundOp
      of "+": ctx.emit(OpAdd)
      of "-": ctx.emit(OpSub)
      of "*": ctx.emit(OpMul)
      of "/": ctx.emit(OpDiv)
      of "%": ctx.emit(OpMod)
      else: discard
    else:
      compileExpr(ctx, valueExpr)

    let leaf = parts[^1]
    var leafIdx: int
    if parseIntMaybe(leaf, leafIdx):
      discard ctx.emitConst(valueInt(leafIdx))
      ctx.emit(OpSetMemberDynamic)
    else:
      let sid = runtimeSym(ctx.m, leaf)
      ctx.emit(OpSetMember, b = sid.uint32)

    return

  let resolved = resolveVar(ctx, target)

  if compoundOp.len > 0:
    case resolved.kind
    of VskLocal:
      ctx.emit(OpLoadLocal, b = resolved.idx.uint32)
    of VskUpvalue:
      ctx.emit(OpLoadUpvalue, b = resolved.idx.uint32)
    of VskGlobal:
      ctx.emit(OpLoadGlobal, b = resolved.idx.uint32)

    compileExpr(ctx, valueExpr)
    case compoundOp
    of "+": ctx.emit(OpAdd)
    of "-": ctx.emit(OpSub)
    of "*": ctx.emit(OpMul)
    of "/": ctx.emit(OpDiv)
    of "%": ctx.emit(OpMod)
    else: discard
  else:
    compileExpr(ctx, valueExpr)

  case resolved.kind
  of VskLocal:
    ctx.emit(OpStoreLocal, b = resolved.idx.uint32)
  of VskUpvalue:
    ctx.emit(OpStoreUpvalue, b = resolved.idx.uint32)
  of VskGlobal:
    ctx.emit(OpStoreGlobal, b = resolved.idx.uint32)

proc isHeadSymbol(node: AstNode; text: string): bool =
  node.kind == AkSymbol and node.text == text

proc parseParams(arrayNode: AstNode): seq[AirParam] =
  if arrayNode == nil:
    return @[]

  if arrayNode.kind == AkSymbol and arrayNode.text == "_":
    return @[]

  if arrayNode.kind != AkArray:
    return @[]

  var i = 0
  while i < arrayNode.items.len:
    let item = arrayNode.items[i]
    if item.kind != AkSymbol:
      inc(i)
      continue

    var (name, ann) = parseTypedName(item)
    if name.len == 0:
      inc(i)
      continue

    if ann.len == 0 and item.text.endsWith(":") and i + 1 < arrayNode.items.len and arrayNode.items[i + 1].kind == AkSymbol:
      ann = arrayNode.items[i + 1].text
      inc(i)

    result.add(AirParam(name: name, typeAnn: ann))
    inc(i)

proc compileBodyExprs(ctx: FnContext; nodes: seq[AstNode]) =
  if nodes.len == 0:
    ctx.emit(OpConstNil)
    return

  for i, n in nodes:
    compileExpr(ctx, n)
    if i < nodes.high:
      ctx.emit(OpPop)

proc compileFunctionForm(ctx: FnContext; node: AstNode; forceMethod = false; forcedName = ""; bindNamed = true): string =
  let items = node.items
  var idx = 1
  var fnName = forcedName
  var named = fnName.len > 0

  if not named and idx < items.len and items[idx].kind == AkSymbol and items[idx].text != "[" and items[idx].text != "_" and items[idx].text != "->":
    if idx + 1 < items.len and (items[idx + 1].kind == AkArray or (items[idx + 1].kind == AkSymbol and items[idx + 1].text == "_")):
      fnName = items[idx].text
      named = true
      inc(idx)

  var paramsNode: AstNode = nil
  if idx < items.len:
    paramsNode = items[idx]
    inc(idx)

  var retType = ""
  if idx + 1 < items.len and isHeadSymbol(items[idx], "->") and items[idx + 1].kind == AkSymbol:
    retType = items[idx + 1].text
    inc(idx, 2)

  let body = if idx < items.len: items[idx..^1] else: @[]

  let params = parseParams(paramsNode)
  if fnName.len == 0:
    fnName = "<lambda>"

  let fn = newAirFunction(fnName, params.len)
  fn.params = params
  if forceMethod:
    fn.flags.incl(FFlagMethod)
  if fnName.endsWith("!"):
    fn.flags.incl(FFlagMacroLike)

  var child = FnContext(
    m: ctx.m,
    fn: fn,
    parent: ctx,
    locals: initOrderedTable[string, LocalBinding](),
    upvalues: initOrderedTable[string, int](),
    loops: @[],
    isTopLevel: false
  )

  for param in params:
    let slot = declareLocal(child, param.name, param.typeAnn)
    child.fn.localSymbols[slot] = runtimeSym(child.m, param.name)

  compileBodyExprs(child, body)
  child.emit(OpReturn)

  let fnIdx = child.m.addFunction(fn)
  let op = if child.fn.upvalueSymbols.len > 0: OpClosureNew else: OpFnNew
  ctx.emit(op, b = fnIdx.uint32)

  if named and bindNamed:
    let sid = runtimeSym(ctx.m, fnName)
    if ctx.isTopLevel:
      ctx.emit(OpStoreGlobal, b = sid.uint32)
    else:
      if not ctx.locals.hasKey(fnName):
        discard declareLocal(ctx, fnName)
      let slot = ctx.locals[fnName].slot
      ctx.emit(OpStoreLocal, b = slot.uint32)

  # Return type annotation is currently tracked in diagnostics for gradual typing.
  if retType.len > 0:
    ctx.m.diagnostics.add("fn " & fnName & " annotated return type: " & retType)

  fnName

proc compileIfForm(ctx: FnContext; node: AstNode) =
  let items = node.items
  if items.len < 3:
    raise fail(node, "if requires a condition and then branch")

  var branchEndPatches: seq[int] = @[]
  var i = 1

  while i < items.len:
    if isHeadSymbol(items[i], "else"):
      if i + 1 < items.len:
        compileExpr(ctx, items[i + 1])
      else:
        ctx.emit(OpConstNil)
      break

    if isHeadSymbol(items[i], "elif"):
      if i + 2 >= items.len:
        raise fail(node, "elif requires condition and branch")

      compileExpr(ctx, items[i + 1])
      let brFalse = ctx.emit(OpBrFalse, b = 0)
      compileExpr(ctx, items[i + 2])
      branchEndPatches.add(ctx.emit(OpJump, b = 0))
      ctx.fn.patchB(brFalse, ctx.fn.code.len)
      i = i + 3
      continue

    if i + 1 >= items.len:
      raise fail(node, "if branch missing body")

    compileExpr(ctx, items[i])
    let brFalse = ctx.emit(OpBrFalse, b = 0)
    compileExpr(ctx, items[i + 1])
    branchEndPatches.add(ctx.emit(OpJump, b = 0))
    ctx.fn.patchB(brFalse, ctx.fn.code.len)
    i = i + 2

  if i >= items.len:
    ctx.emit(OpConstNil)

  let endPc = ctx.fn.code.len
  for patch in branchEndPatches:
    ctx.fn.patchB(patch, endPc)

proc compileLoopForm(ctx: FnContext; node: AstNode) =
  if node.items.len < 2:
    ctx.emit(OpConstNil)
    return

  let loopCtx = LoopContext(startIp: ctx.fn.code.len, continueIp: -1, breakPatches: @[])
  ctx.loops.add(loopCtx)

  for i in 1..<node.items.len:
    compileExpr(ctx, node.items[i])
    if i < node.items.high:
      ctx.emit(OpPop)

  loopCtx.continueIp = loopCtx.startIp
  ctx.emit(OpJump, b = loopCtx.startIp.uint32)

  let endPc = ctx.fn.code.len
  for ip in loopCtx.breakPatches:
    ctx.fn.patchB(ip, endPc)

  discard ctx.loops.pop()
  ctx.emit(OpConstNil)

proc compileForForm(ctx: FnContext; node: AstNode) =
  let items = node.items
  if items.len < 5:
    raise fail(node, "for form requires: (for name in iterable body...)")

  if items[1].kind != AkSymbol or not isHeadSymbol(items[2], "in"):
    raise fail(node, "for form must be (for <symbol> in <expr> ...)")

  let varName = items[1].text
  compileExpr(ctx, items[3])
  ctx.emit(OpIterInit)

  let iterSlot = declareLocal(ctx, "__iter_" & $node.line & "_" & $node.col)
  ctx.emit(OpStoreLocal, b = iterSlot.uint32)

  var targetSlot = -1
  var targetGlobal = -1
  if ctx.isTopLevel:
    targetGlobal = runtimeSym(ctx.m, varName)
  else:
    targetSlot = declareLocal(ctx, varName)

  let loopCtx = LoopContext(startIp: ctx.fn.code.len, continueIp: -1, breakPatches: @[])
  ctx.loops.add(loopCtx)

  ctx.emit(OpLoadLocal, b = iterSlot.uint32)
  ctx.emit(OpIterHasNext)
  let brEnd = ctx.emit(OpBrFalse, b = 0)

  ctx.emit(OpLoadLocal, b = iterSlot.uint32)
  ctx.emit(OpIterNext)
  if ctx.isTopLevel:
    ctx.emit(OpStoreGlobal, b = targetGlobal.uint32)
  else:
    ctx.emit(OpStoreLocal, b = targetSlot.uint32)

  for i in 4..<items.len:
    compileExpr(ctx, items[i])
    if i < items.high:
      ctx.emit(OpPop)

  loopCtx.continueIp = loopCtx.startIp
  ctx.emit(OpJump, b = loopCtx.startIp.uint32)

  let endPc = ctx.fn.code.len
  ctx.fn.patchB(brEnd, endPc)
  for ip in loopCtx.breakPatches:
    ctx.fn.patchB(ip, endPc)
  discard ctx.loops.pop()

  ctx.emit(OpConstNil)

proc compileTryForm(ctx: FnContext; node: AstNode) =
  let items = node.items
  var catchIdx = -1
  var finallyIdx = -1

  for i in 1..<items.len:
    if catchIdx < 0 and isHeadSymbol(items[i], "catch"):
      catchIdx = i
    elif finallyIdx < 0 and isHeadSymbol(items[i], "finally"):
      finallyIdx = i

  let bodyEnd = if catchIdx >= 0: catchIdx elif finallyIdx >= 0: finallyIdx else: items.len
  let tryBegin = ctx.emit(OpTryBegin, b = 0)
  for i in 1..<bodyEnd:
    compileExpr(ctx, items[i])
    if i < bodyEnd - 1:
      ctx.emit(OpPop)
  ctx.emit(OpTryEnd)

  let jumpAfter = ctx.emit(OpJump, b = 0)

  if catchIdx >= 0:
    let catchPc = ctx.fn.code.len
    ctx.fn.patchB(tryBegin, catchPc)

    ctx.emit(OpCatchBegin)
    var catchBodyStart = catchIdx + 1
    if catchBodyStart < items.len and items[catchBodyStart].kind == AkSymbol:
      let catcher = items[catchBodyStart].text
      if catcher != "*":
        if ctx.isTopLevel:
          let sid = runtimeSym(ctx.m, catcher)
          ctx.emit(OpStoreGlobal, b = sid.uint32)
        else:
          if not ctx.locals.hasKey(catcher):
            discard declareLocal(ctx, catcher)
          ctx.emit(OpStoreLocal, b = ctx.locals[catcher].slot.uint32)
      inc(catchBodyStart)

    let catchBodyEnd = if finallyIdx >= 0: finallyIdx else: items.len
    if catchBodyStart >= catchBodyEnd:
      ctx.emit(OpConstNil)
    else:
      for i in catchBodyStart..<catchBodyEnd:
        compileExpr(ctx, items[i])
        if i < catchBodyEnd - 1:
          ctx.emit(OpPop)
    ctx.emit(OpCatchEnd)

  if finallyIdx >= 0:
    ctx.emit(OpFinallyBegin)
    let start = finallyIdx + 1
    if start >= items.len:
      ctx.emit(OpConstNil)
    else:
      for i in start..<items.len:
        compileExpr(ctx, items[i])
        if i < items.high:
          ctx.emit(OpPop)
    ctx.emit(OpFinallyEnd)

  ctx.fn.patchB(jumpAfter, ctx.fn.code.len)

proc compileClassForm(ctx: FnContext; node: AstNode) =
  let items = node.items
  if items.len < 2 or items[1].kind != AkSymbol:
    raise fail(node, "class form requires a class name")

  let className = items[1].text
  let classSym = runtimeSym(ctx.m, className)
  ctx.emit(OpClassNew, b = classSym.uint32)

  var idx = 2
  if idx + 1 < items.len and isHeadSymbol(items[idx], "<"):
    compileExpr(ctx, items[idx + 1])
    ctx.emit(OpClassExtends)
    inc(idx, 2)

  while idx < items.len:
    let member = items[idx]
    if member.kind == AkList and member.items.len > 0 and member.items[0].kind == AkSymbol:
      let head = member.items[0].text
      if head == "ctor" or head == "ctor!":
        var ctorNode = AstNode(kind: AkList, line: member.line, col: member.col, items: @[])
        ctorNode.items.add(mkSymbol(member.line, member.col, "fn"))
        if member.items.len >= 2:
          ctorNode.items.add(member.items[1])
        for i in 2..<member.items.len:
          ctorNode.items.add(member.items[i])
        discard compileFunctionForm(ctx, ctorNode, forceMethod = true, forcedName = className & "::ctor", bindNamed = false)
        let fnIdx = ctx.m.functions.high
        ctx.emit(OpCtorDef, b = fnIdx.uint32)
      elif head == "method" or head == "method!":
        if member.items.len < 3 or member.items[1].kind != AkSymbol:
          raise fail(member, "method requires a name and args")
        let methodName = member.items[1].text

        var methodNode = AstNode(kind: AkList, line: member.line, col: member.col, items: @[])
        methodNode.items.add(mkSymbol(member.line, member.col, "fn"))
        methodNode.items.add(member.items[2])
        for i in 3..<member.items.len:
          methodNode.items.add(member.items[i])

        discard compileFunctionForm(ctx, methodNode, forceMethod = true, forcedName = className & "::" & methodName, bindNamed = false)
        let fnIdx = ctx.m.functions.high
        let sid = runtimeSym(ctx.m, methodName)
        ctx.emit(OpMethodDef, b = sid.uint32, c = fnIdx.uint32)
      elif head == "class":
        compileClassForm(ctx, member)
        ctx.emit(OpPop)
      else:
        compileExpr(ctx, member)
        ctx.emit(OpPop)
    else:
      compileExpr(ctx, member)
      ctx.emit(OpPop)
    inc(idx)

  if ctx.isTopLevel:
    ctx.emit(OpStoreGlobal, b = classSym.uint32)
  else:
    if not ctx.locals.hasKey(className):
      discard declareLocal(ctx, className)
    ctx.emit(OpStoreLocal, b = ctx.locals[className].slot.uint32)

proc compileArrayLiteral(ctx: FnContext; node: AstNode) =
  ctx.emit(OpArrNew)
  for item in node.items:
    if item.kind == AkSymbol and item.text.endsWith("...") and item.text.len > 3:
      var spreadSym = mkSymbol(item.line, item.col, item.text[0..^4])
      compileExpr(ctx, spreadSym)
      ctx.emit(OpArrSpread)
    else:
      compileExpr(ctx, item)
      ctx.emit(OpArrPush)
  ctx.emit(OpArrEnd)

proc compileMapLiteral(ctx: FnContext; node: AstNode) =
  ctx.emit(OpMapNew)
  for entry in node.entries:
    if entry.key.kind == AkKeyword:
      compileExpr(ctx, entry.value)
      let sid = runtimeSym(ctx.m, entry.key.text)
      ctx.emit(OpMapSet, b = sid.uint32)
    else:
      compileExpr(ctx, entry.key)
      compileExpr(ctx, entry.value)
      ctx.emit(OpMapSetDynamic)
  ctx.emit(OpMapEnd)

proc compileInterpolatedString(ctx: FnContext; node: AstNode) =
  if node.parts.len == 0:
    discard ctx.emitConst(newStringValue(""))
    return

  compileExpr(ctx, node.parts[0])
  for i in 1..<node.parts.len:
    compileExpr(ctx, node.parts[i])
    ctx.emit(OpAdd)

proc compileCall(ctx: FnContext; node: AstNode) =
  let items = node.items
  if items.len == 0:
    ctx.emit(OpConstNil)
    return

  if items.len >= 2 and items[1].kind == AkSymbol and items[1].text.startsWith("."):
    compileExpr(ctx, items[0])
    let methodName = items[1].text[1..^1]
    for i in 2..<items.len:
      compileExpr(ctx, items[i])
    let sid = runtimeSym(ctx.m, methodName)
    if items[0].kind == AkSymbol and items[0].text == "super":
      ctx.emit(OpCallSuper, c = (items.len - 2).uint32, b = sid.uint32)
    else:
      ctx.emit(OpCallMethod, c = (items.len - 2).uint32, b = sid.uint32)
    return

  if items[0].kind == AkSymbol and items[0].text.endsWith("!"):
    compileExpr(ctx, items[0])
    for i in 1..<items.len:
      discard ctx.emitConst(quotedAstToValue(items[i]))
    ctx.emit(OpCallMacro, c = (items.len - 1).uint32)
    return

  let opSym = if items[0].kind == AkSymbol: items[0].text else: ""
  if items.len == 3 and opSym in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||"]:
    compileExpr(ctx, items[1])
    compileExpr(ctx, items[2])
    case opSym
    of "+": ctx.emit(OpAdd)
    of "-": ctx.emit(OpSub)
    of "*": ctx.emit(OpMul)
    of "/": ctx.emit(OpDiv)
    of "%": ctx.emit(OpMod)
    of "==": ctx.emit(OpCmpEq)
    of "!=": ctx.emit(OpCmpNe)
    of "<": ctx.emit(OpCmpLt)
    of "<=": ctx.emit(OpCmpLe)
    of ">": ctx.emit(OpCmpGt)
    of ">=": ctx.emit(OpCmpGe)
    of "&&": ctx.emit(OpLogAnd)
    of "||": ctx.emit(OpLogOr)
    else: discard
    return

  if items.len == 2 and opSym == "!":
    compileExpr(ctx, items[1])
    ctx.emit(OpLogNot)
    return

  if items.len == 2 and opSym == "typeof":
    compileExpr(ctx, items[1])
    ctx.emit(OpTypeof)
    return

  if opSym == "new" and items.len >= 2:
    compileExpr(ctx, items[1])
    for i in 2..<items.len:
      compileExpr(ctx, items[i])
    ctx.emit(OpCall, c = (items.len - 2).uint32)
    return

  compileExpr(ctx, items[0])
  for i in 1..<items.len:
    compileExpr(ctx, items[i])

  ctx.emit(OpCall, c = (items.len - 1).uint32)

proc compileSpecialForm(ctx: FnContext; node: AstNode): bool =
  if node.kind != AkList or node.items.len == 0 or node.items[0].kind != AkSymbol:
    return false

  let items = node.items
  let head = items[0].text

  case head
  of "do":
    compileBodyExprs(ctx, items[1..^1])
    true
  of "quote":
    if items.len > 1:
      discard ctx.emitConst(quotedAstToValue(items[1]))
    else:
      ctx.emit(OpConstNil)
    true
  of "var":
    if items.len < 2:
      raise fail(node, "var requires a symbol")
    let (name, ann) = parseTypedName(items[1])
    if name.len == 0:
      raise fail(items[1], "invalid var name")

    if items.len >= 3:
      compileExpr(ctx, items[2])
    else:
      ctx.emit(OpConstNil)

    if ctx.isTopLevel:
      let sid = runtimeSym(ctx.m, name)
      ctx.emit(OpStoreGlobal, b = sid.uint32)
    else:
      if not ctx.locals.hasKey(name):
        discard declareLocal(ctx, name, ann)
      ctx.emit(OpStoreLocal, b = ctx.locals[name].slot.uint32)
    true
  of "if":
    compileIfForm(ctx, node)
    true
  of "loop":
    compileLoopForm(ctx, node)
    true
  of "for":
    compileForForm(ctx, node)
    true
  of "break":
    if ctx.loops.len == 0:
      raise fail(node, "break used outside loop")
    let patch = ctx.emit(OpJump, b = 0)
    ctx.loops[^1].breakPatches.add(patch)
    ctx.emit(OpConstNil)
    true
  of "continue":
    if ctx.loops.len == 0:
      raise fail(node, "continue used outside loop")
    let tgt = if ctx.loops[^1].continueIp >= 0: ctx.loops[^1].continueIp else: ctx.loops[^1].startIp
    ctx.emit(OpJump, b = tgt.uint32)
    ctx.emit(OpConstNil)
    true
  of "fn":
    discard compileFunctionForm(ctx, node)
    true
  of "return":
    if items.len > 1:
      compileExpr(ctx, items[1])
    else:
      ctx.emit(OpConstNil)
    ctx.emit(OpReturn)
    true
  of "class":
    compileClassForm(ctx, node)
    true
  of "try":
    compileTryForm(ctx, node)
    true
  of "throw":
    if items.len > 1:
      compileExpr(ctx, items[1])
    else:
      ctx.emit(OpConstNil)
    ctx.emit(OpThrow)
    true
  of "async":
    ctx.emit(OpAsyncBegin)
    compileBodyExprs(ctx, items[1..^1])
    ctx.emit(OpAsyncEnd)
    true
  of "await":
    if items.len > 1:
      compileExpr(ctx, items[1])
    else:
      ctx.emit(OpConstNil)
    ctx.emit(OpAwait)
    true
  of "yield":
    ctx.fn.flags.incl(FFlagGenerator)
    if items.len > 1:
      compileExpr(ctx, items[1])
    else:
      ctx.emit(OpConstNil)
    ctx.emit(OpYield)
    true
  of "resume":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpResume)
    else:
      ctx.emit(OpConstNil)
    true
  of "import":
    if items.len > 1 and items[1].kind == AkSymbol:
      let sid = runtimeSym(ctx.m, items[1].text)
      ctx.emit(OpImport, b = sid.uint32)
    else:
      ctx.emit(OpConstNil)
    true
  of "module":
    if items.len > 1 and items[1].kind == AkSymbol:
      let sid = runtimeSym(ctx.m, items[1].text)
      ctx.emit(OpNsEnter, b = sid.uint32)
      for i in 2..<items.len:
        compileExpr(ctx, items[i])
        if i < items.high:
          ctx.emit(OpPop)
      ctx.emit(OpNsExit)
    else:
      compileBodyExprs(ctx, items[1..^1])
    true
  of "capabilities":
    if items.len > 1 and items[1].kind == AkArray:
      var caps: seq[string] = @[]
      for capNode in items[1].items:
        if capNode.kind == AkSymbol:
          caps.add(capNode.text)
      ctx.m.effects.add(EffectProfile(name: "block@" & $node.line & ":" & $node.col, capabilities: caps))
      let effId = ctx.m.effects.high
      ctx.emit(OpCapEnter, b = effId.uint32)
      if items.len > 2:
        compileBodyExprs(ctx, items[2..^1])
      else:
        ctx.emit(OpConstNil)
      ctx.emit(OpCapExit)
    else:
      ctx.emit(OpConstNil)
    true
  of "cap_assert":
    if items.len > 1 and items[1].kind == AkSymbol:
      let sid = runtimeSym(ctx.m, items[1].text)
      ctx.emit(OpCapAssert, b = sid.uint32)
    else:
      ctx.emit(OpConstNil)
    true
  of "quota_set":
    if items.len > 2:
      compileExpr(ctx, items[1])
      compileExpr(ctx, items[2])
      ctx.emit(OpQuotaSet)
    else:
      ctx.emit(OpConstNil)
    true
  of "quota_check":
    if items.len > 2:
      compileExpr(ctx, items[1])
      compileExpr(ctx, items[2])
      ctx.emit(OpQuotaCheck)
    else:
      ctx.emit(OpConstNil)
    true
  of "checkpoint":
    ctx.emit(OpCheckpointHint)
    ctx.emit(OpConstNil)
    true
  of "state_save":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpStateSave)
    else:
      ctx.emit(OpConstNil)
    true
  of "state_restore":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpStateRestore)
    else:
      ctx.emit(OpConstNil)
    true
  of "task_scope":
    let scopeSlot = declareLocal(ctx, "__task_scope_" & $node.line & "_" & $node.col)
    ctx.emit(OpTaskScopeEnter)
    ctx.emit(OpStoreLocal, b = scopeSlot.uint32)
    ctx.emit(OpPop)
    if items.len > 1:
      compileBodyExprs(ctx, items[1..^1])
    else:
      ctx.emit(OpConstNil)
    ctx.emit(OpPop)
    ctx.emit(OpLoadLocal, b = scopeSlot.uint32)
    ctx.emit(OpTaskJoin)
    true
  of "task_spawn":
    if items.len < 2:
      ctx.emit(OpConstNil)
    else:
      compileExpr(ctx, items[1])
      for i in 2..<items.len:
        compileExpr(ctx, items[i])
      ctx.emit(OpTaskSpawn, c = max(items.len - 2, 0).uint32)
    true
  of "task_join":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpTaskJoin)
    else:
      ctx.emit(OpConstNil)
    true
  of "task_cancel":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpTaskCancel)
    else:
      ctx.emit(OpConstNil)
    true
  of "task_deadline":
    if items.len > 2:
      compileExpr(ctx, items[1])
      compileExpr(ctx, items[2])
      ctx.emit(OpTaskDeadline)
    else:
      ctx.emit(OpConstNil)
    true
  of "tool_call":
    if items.len > 2 and items[1].kind == AkSymbol:
      let schemaId = ensureToolSchema(ctx.m, items[1].text)
      ctx.emit(OpToolPrep, b = schemaId.uint32)
      compileExpr(ctx, items[2])
      ctx.emit(OpToolCall)
    else:
      ctx.emit(OpConstNil)
    true
  of "tool_await":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpToolAwait)
    else:
      ctx.emit(OpConstNil)
    true
  of "tool_unwrap":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpToolResultUnwrap)
    else:
      ctx.emit(OpConstNil)
    true
  of "tool_retry":
    if items.len > 1:
      compileExpr(ctx, items[1])
      ctx.emit(OpToolRetry)
    else:
      ctx.emit(OpConstNil)
    true
  else:
    false

proc compileExpr(ctx: FnContext; node: AstNode) =
  case node.kind
  of AkNil:
    ctx.emit(OpConstNil)
  of AkBool:
    if node.boolVal: ctx.emit(OpConstTrue) else: ctx.emit(OpConstFalse)
  of AkInt:
    discard ctx.emitConst(valueInt(node.intVal))
  of AkFloat:
    discard ctx.emitConst(valueFloat(node.floatVal))
  of AkString:
    discard ctx.emitConst(newStringValue(node.text))
  of AkSymbol:
    compileSymbolLookup(ctx, node.text)
  of AkKeyword:
    discard ctx.emitConst(newKeywordValue(node.text))
  of AkQuote:
    discard ctx.emitConst(quotedAstToValue(node.quoted))
  of AkArray:
    compileArrayLiteral(ctx, node)
  of AkMap:
    compileMapLiteral(ctx, node)
  of AkInterpolatedString:
    compileInterpolatedString(ctx, node)
  of AkList:
    if node.items.len >= 3 and node.items[0].kind == AkSymbol and node.items[1].kind == AkSymbol:
      let op = node.items[1].text
      if op == "=":
        compileLValueStore(ctx, node.items[0], node.items[2])
        return
      if op == "+=":
        compileLValueStore(ctx, node.items[0], node.items[2], "+")
        return
      if op == "-=":
        compileLValueStore(ctx, node.items[0], node.items[2], "-")
        return
      if op == "*=":
        compileLValueStore(ctx, node.items[0], node.items[2], "*")
        return
      if op == "/=":
        compileLValueStore(ctx, node.items[0], node.items[2], "/")
        return

    if node.items.len == 3 and node.items[1].kind == AkSymbol:
      let infix = node.items[1].text
      if infix in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||"]:
        compileExpr(ctx, node.items[0])
        compileExpr(ctx, node.items[2])
        case infix
        of "+": ctx.emit(OpAdd)
        of "-": ctx.emit(OpSub)
        of "*": ctx.emit(OpMul)
        of "/": ctx.emit(OpDiv)
        of "%": ctx.emit(OpMod)
        of "==": ctx.emit(OpCmpEq)
        of "!=": ctx.emit(OpCmpNe)
        of "<": ctx.emit(OpCmpLt)
        of "<=": ctx.emit(OpCmpLe)
        of ">": ctx.emit(OpCmpGt)
        of ">=": ctx.emit(OpCmpGe)
        of "&&": ctx.emit(OpLogAnd)
        of "||": ctx.emit(OpLogOr)
        else: discard
        return

    if compileSpecialForm(ctx, node):
      return

    compileCall(ctx, node)

proc newFnContext(m: AirModule; fn: AirFunction; parent: FnContext; isTopLevel: bool): FnContext =
  FnContext(
    m: m,
    fn: fn,
    parent: parent,
    locals: initOrderedTable[string, LocalBinding](),
    upvalues: initOrderedTable[string, int](),
    loops: @[],
    isTopLevel: isTopLevel
  )

proc compileProgram*(program: Program; sourcePath = "<memory>"): AirModule =
  result = newAirModule(sourcePath)
  let mainFn = newAirFunction("__main__", 0)
  discard result.addFunction(mainFn)
  result.mainFn = 0

  var ctx = newFnContext(result, mainFn, nil, true)

  if program.exprs.len == 0:
    ctx.emit(OpConstNil)
    ctx.emit(OpReturn)
    return

  for i, expr in program.exprs:
    compileExpr(ctx, expr)
    if i < program.exprs.high:
      ctx.emit(OpPop)

  ctx.emit(OpReturn)

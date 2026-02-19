import std/[math, strutils, tables, sequtils]

const
  QNaNMask* = 0x7FF8000000000000'u64
  SignBit* = 0x8000000000000000'u64
  TagShift = 48
  TagMask = 0x0007000000000000'u64
  PayloadMask* = 0x0000FFFFFFFFFFFF'u64
  PtrPayloadMask* = PayloadMask

type
  Value* {.bycopy.} = object
    raw*: uint64

  ValueKind* = enum
    VkNumber
    VkNil
    VkBool
    VkInt
    VkSymbol
    VkPointer
    VkUnknown

  ImmediateTag = enum
    ItNil = 0
    ItBool = 1
    ItInt = 2
    ItSymbol = 3

  HeapKind* = enum
    HkString
    HkKeyword
    HkArray
    HkMap
    HkGene
    HkFunction
    HkNativeFn
    HkClass
    HkInstance
    HkFuture
    HkGenerator
    HkError

  HeapObject* = ref object of RootObj
    kind*: HeapKind

  StringObj* = ref object of HeapObject
    value*: string

  KeywordObj* = ref object of HeapObject
    name*: string

  ArrayObj* = ref object of HeapObject
    items*: seq[Value]

  MapObj* = ref object of HeapObject
    entries*: OrderedTable[string, Value]

  GeneObj* = ref object of HeapObject
    geneType*: Value
    props*: OrderedTable[string, Value]
    children*: seq[Value]

  FunctionFlag* = enum
    FfAsync
    FfGenerator
    FfMacroLike
    FfMethod

  FunctionObj* = ref object of HeapObject
    name*: string
    fnIndex*: int
    moduleId*: int
    arity*: int
    paramNames*: seq[string]
    paramTypes*: seq[string]
    upvalueNames*: seq[string]
    upvalues*: OrderedTable[string, Value]
    flags*: set[FunctionFlag]

  NativeFnObj* = ref object of HeapObject
    name*: string
    arity*: int

  ClassObj* = ref object of HeapObject
    name*: string
    superClass*: Value
    methods*: OrderedTable[string, Value]
    ctor*: Value

  InstanceObj* = ref object of HeapObject
    cls*: Value
    fields*: OrderedTable[string, Value]

  FutureState* = enum
    FsPending
    FsResolved
    FsRejected

  FutureObj* = ref object of HeapObject
    state*: FutureState
    value*: Value
    error*: Value
    toolSchemaId*: int
    toolArgs*: Value
    toolIdempotencyKey*: string

  GeneratorState* = enum
    GsPending
    GsRunning
    GsSuspended
    GsDone

  GeneratorObj* = ref object of HeapObject
    state*: GeneratorState
    fnValue*: Value
    args*: seq[Value]
    lastValue*: Value
    started*: bool
    finished*: bool
    fnIndex*: int
    ip*: int
    stack*: seq[Value]
    locals*: seq[Value]
    upvalues*: OrderedTable[string, Value]
    handlerCatchIps*: seq[int]
    handlerStackDepths*: seq[int]
    selfVal*: Value

  ErrorObj* = ref object of HeapObject
    message*: string

var
  gHeapRoots {.threadvar.}: seq[HeapObject]
  gSymbols {.threadvar.}: seq[string]
  gSymbolIndex {.threadvar.}: Table[string, int]

proc initRuntimeTables() =
  if gSymbolIndex.len == 0 and gSymbols.len == 0:
    gSymbolIndex = initTable[string, int]()
    gSymbols = @[]

proc retainRoot[T: HeapObject](obj: T): T =
  gHeapRoots.add(obj)
  result = obj

proc retainHeapObject*(obj: HeapObject) =
  gHeapRoots.add(obj)

proc heapObjectCount*(): int =
  gHeapRoots.len

proc packImmediate(tag: ImmediateTag; payload: uint64): Value {.inline.} =
  Value(raw: QNaNMask or (uint64(tag) shl TagShift) or (payload and PayloadMask))

proc valueFromPtr*(obj: HeapObject): Value {.inline.} =
  let rawPtr = cast[uint64](cast[pointer](obj))
  Value(raw: SignBit or QNaNMask or (rawPtr and PtrPayloadMask))

proc valueNil*(): Value {.inline.} =
  packImmediate(ItNil, 0)

proc valueBool*(b: bool): Value {.inline.} =
  packImmediate(ItBool, (if b: 1'u64 else: 0'u64))

proc valueInt*(i: int64): Value {.inline.} =
  packImmediate(ItInt, cast[uint64](i) and PayloadMask)

proc valueSymbolId*(id: int): Value {.inline.} =
  packImmediate(ItSymbol, uint64(id))

proc valueFloat*(x: float64): Value {.inline.} =
  Value(raw: cast[uint64](x))

proc valueKind*(v: Value): ValueKind {.inline.} =
  let isNanTagged = (v.raw and QNaNMask) == QNaNMask
  if not isNanTagged:
    return VkNumber
  if (v.raw and (QNaNMask or SignBit)) == (QNaNMask or SignBit):
    return VkPointer
  let tag = ImmediateTag((v.raw and TagMask) shr TagShift)
  case tag
  of ItNil: VkNil
  of ItBool: VkBool
  of ItInt: VkInt
  of ItSymbol: VkSymbol

proc isNumber*(v: Value): bool {.inline.} = valueKind(v) == VkNumber
proc isNil*(v: Value): bool {.inline.} = valueKind(v) == VkNil
proc isBool*(v: Value): bool {.inline.} = valueKind(v) == VkBool
proc isInt*(v: Value): bool {.inline.} = valueKind(v) == VkInt
proc isSymbol*(v: Value): bool {.inline.} = valueKind(v) == VkSymbol
proc isPointer*(v: Value): bool {.inline.} = valueKind(v) == VkPointer

proc asBool*(v: Value): bool =
  if not isBool(v):
    return false
  (v.raw and PayloadMask) != 0

proc asInt*(v: Value): int64 =
  if not isInt(v):
    return 0
  var payload = int64(v.raw and PayloadMask)
  if (payload and (1'i64 shl 47)) != 0:
    payload = payload or (not int64(PayloadMask))
  payload

proc asFloat*(v: Value): float64 =
  case valueKind(v)
  of VkNumber:
    cast[float64](v.raw)
  of VkInt:
    asInt(v).float64
  of VkBool:
    (if asBool(v): 1.0 else: 0.0)
  else:
    0.0

proc asSymbolId*(v: Value): int =
  if not isSymbol(v):
    return -1
  int(v.raw and PayloadMask)

proc asHeapObject*(v: Value): HeapObject =
  if not isPointer(v):
    return nil
  let ptrRaw = v.raw and PtrPayloadMask
  cast[HeapObject](cast[pointer](ptrRaw))

proc isTruthy*(v: Value): bool =
  case valueKind(v)
  of VkNil:
    false
  of VkBool:
    asBool(v)
  of VkInt:
    asInt(v) != 0
  of VkNumber:
    let n = asFloat(v)
    (not n.isNaN) and n != 0.0
  else:
    true

proc internSymbol*(name: string): int =
  initRuntimeTables()
  if gSymbolIndex.hasKey(name):
    return gSymbolIndex[name]
  let id = gSymbols.len
  gSymbols.add(name)
  gSymbolIndex[name] = id
  id

proc symbolName*(id: int): string =
  if id < 0 or id >= gSymbols.len:
    return ""
  gSymbols[id]

proc valueSymbol*(name: string): Value =
  valueSymbolId(internSymbol(name))

proc asSymbolName*(v: Value): string =
  if not isSymbol(v):
    return ""
  symbolName(asSymbolId(v))

proc isKeyword*(v: Value): bool =
  if not isPointer(v):
    return false
  let obj = asHeapObject(v)
  obj != nil and obj.kind == HkKeyword

proc newStringValue*(s: string): Value =
  let obj = retainRoot(StringObj(kind: HkString, value: s))
  valueFromPtr(obj)

proc newKeywordValue*(name: string): Value =
  let obj = retainRoot(KeywordObj(kind: HkKeyword, name: name))
  valueFromPtr(obj)

proc newArrayValue*(items: openArray[Value] = []): Value =
  let obj = retainRoot(ArrayObj(kind: HkArray, items: @items))
  valueFromPtr(obj)

proc newMapValue*(): Value =
  let obj = retainRoot(MapObj(kind: HkMap, entries: initOrderedTable[string, Value]()))
  valueFromPtr(obj)

proc newGeneValue*(geneType: Value): Value =
  let obj = retainRoot(GeneObj(
    kind: HkGene,
    geneType: geneType,
    props: initOrderedTable[string, Value](),
    children: @[]
  ))
  valueFromPtr(obj)

proc newFunctionValue*(name: string; fnIndex: int; arity: int; moduleId = -1): Value =
  let obj = retainRoot(FunctionObj(
    kind: HkFunction,
    name: name,
    fnIndex: fnIndex,
    moduleId: moduleId,
    arity: arity,
    paramNames: @[],
    paramTypes: @[],
    upvalueNames: @[],
    upvalues: initOrderedTable[string, Value](),
    flags: {}
  ))
  valueFromPtr(obj)

proc newNativeFunctionValue*(name: string; arity: int): Value =
  let obj = retainRoot(NativeFnObj(kind: HkNativeFn, name: name, arity: arity))
  valueFromPtr(obj)

proc newClassValue*(name: string): Value =
  let obj = retainRoot(ClassObj(
    kind: HkClass,
    name: name,
    superClass: valueNil(),
    methods: initOrderedTable[string, Value](),
    ctor: valueNil()
  ))
  valueFromPtr(obj)

proc newInstanceValue*(cls: Value): Value =
  let obj = retainRoot(InstanceObj(kind: HkInstance, cls: cls, fields: initOrderedTable[string, Value]()))
  valueFromPtr(obj)

proc newFutureResolvedValue*(value: Value): Value =
  let obj = retainRoot(FutureObj(
    kind: HkFuture,
    state: FsResolved,
    value: value,
    error: valueNil(),
    toolSchemaId: -1,
    toolArgs: valueNil(),
    toolIdempotencyKey: ""
  ))
  valueFromPtr(obj)

proc newFutureRejectedValue*(err: Value): Value =
  let obj = retainRoot(FutureObj(
    kind: HkFuture,
    state: FsRejected,
    value: valueNil(),
    error: err,
    toolSchemaId: -1,
    toolArgs: valueNil(),
    toolIdempotencyKey: ""
  ))
  valueFromPtr(obj)

proc newGeneratorValue*(fnValue: Value; args: seq[Value]): Value =
  let obj = retainRoot(GeneratorObj(
    kind: HkGenerator,
    state: GsPending,
    fnValue: fnValue,
    args: args,
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
  ))
  valueFromPtr(obj)

proc newErrorValue*(msg: string): Value =
  let obj = retainRoot(ErrorObj(kind: HkError, message: msg))
  valueFromPtr(obj)

proc asStringObj*(v: Value): StringObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkString:
    return nil
  StringObj(obj)

proc asKeywordObj*(v: Value): KeywordObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkKeyword:
    return nil
  KeywordObj(obj)

proc asArrayObj*(v: Value): ArrayObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkArray:
    return nil
  ArrayObj(obj)

proc asMapObj*(v: Value): MapObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkMap:
    return nil
  MapObj(obj)

proc asGeneObj*(v: Value): GeneObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkGene:
    return nil
  GeneObj(obj)

proc asFunctionObj*(v: Value): FunctionObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkFunction:
    return nil
  FunctionObj(obj)

proc asNativeFunctionObj*(v: Value): NativeFnObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkNativeFn:
    return nil
  NativeFnObj(obj)

proc asClassObj*(v: Value): ClassObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkClass:
    return nil
  ClassObj(obj)

proc asInstanceObj*(v: Value): InstanceObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkInstance:
    return nil
  InstanceObj(obj)

proc asFutureObj*(v: Value): FutureObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkFuture:
    return nil
  FutureObj(obj)

proc asGeneratorObj*(v: Value): GeneratorObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkGenerator:
    return nil
  GeneratorObj(obj)

proc asErrorObj*(v: Value): ErrorObj =
  let obj = asHeapObject(v)
  if obj == nil or obj.kind != HkError:
    return nil
  ErrorObj(obj)

proc toDebugString*(v: Value; maxDepth = 4): string

proc keyFromValue*(key: Value): string =
  case valueKind(key)
  of VkSymbol:
    asSymbolName(key)
  of VkInt:
    $asInt(key)
  of VkNumber:
    $asFloat(key)
  of VkPointer:
    let obj = asHeapObject(key)
    if obj == nil:
      ""
    elif obj.kind == HkString:
      asStringObj(key).value
    elif obj.kind == HkKeyword:
      asKeywordObj(key).name
    else:
      key.toDebugString()
  else:
    key.toDebugString()

proc mapGet*(mapValue: Value; key: Value): Value =
  let mapObj = asMapObj(mapValue)
  if mapObj == nil:
    return valueNil()
  let k = keyFromValue(key)
  if mapObj.entries.hasKey(k):
    return mapObj.entries[k]
  valueNil()

proc mapSet*(mapValue: Value; key: Value; val: Value) =
  let mapObj = asMapObj(mapValue)
  if mapObj == nil:
    return
  mapObj.entries[keyFromValue(key)] = val

proc arrayGet*(arrayValue: Value; idx: int): Value =
  let arr = asArrayObj(arrayValue)
  if arr == nil or idx < 0 or idx >= arr.items.len:
    return valueNil()
  arr.items[idx]

proc arraySet*(arrayValue: Value; idx: int; val: Value) =
  let arr = asArrayObj(arrayValue)
  if arr == nil:
    return
  if idx < 0:
    return
  if idx >= arr.items.len:
    arr.items.setLen(idx + 1)
  arr.items[idx] = val

proc addGeneChild*(geneValue: Value; child: Value) =
  let g = asGeneObj(geneValue)
  if g != nil:
    g.children.add(child)

proc setGeneProp*(geneValue: Value; key: string; val: Value) =
  let g = asGeneObj(geneValue)
  if g != nil:
    g.props[key] = val

proc getMember*(target: Value; name: string): Value =
  case valueKind(target)
  of VkPointer:
    let obj = asHeapObject(target)
    if obj == nil:
      return valueNil()
    case obj.kind
    of HkString:
      let s = asStringObj(target).value
      case name
      of "length": valueInt(s.len)
      else: valueNil()
    of HkArray:
      let arr = asArrayObj(target)
      if name == "length":
        valueInt(arr.items.len)
      else:
        try:
          let idx = parseInt(name)
          arrayGet(target, idx)
        except ValueError:
          valueNil()
    of HkMap:
      let mapObj = asMapObj(target)
      if mapObj.entries.hasKey(name):
        mapObj.entries[name]
      else:
        valueNil()
    of HkGene:
      let g = asGeneObj(target)
      case name
      of "type": g.geneType
      of "props":
        var m = newMapValue()
        for k, v in g.props:
          mapSet(m, newKeywordValue(k), v)
        m
      of "children":
        newArrayValue(g.children)
      else:
        if g.props.hasKey(name): g.props[name] else: valueNil()
    of HkClass:
      let cls = asClassObj(target)
      if cls.methods.hasKey(name):
        cls.methods[name]
      else:
        valueNil()
    of HkInstance:
      let inst = asInstanceObj(target)
      if inst.fields.hasKey(name):
        inst.fields[name]
      else:
        let cls = asClassObj(inst.cls)
        if cls != nil and cls.methods.hasKey(name):
          cls.methods[name]
        else:
          valueNil()
    of HkFunction:
      let fnObj = asFunctionObj(target)
      case name
      of "name": newStringValue(fnObj.name)
      of "arity": valueInt(fnObj.arity)
      else: valueNil()
    of HkNativeFn:
      let native = asNativeFunctionObj(target)
      case name
      of "name": newStringValue(native.name)
      of "arity": valueInt(native.arity)
      else: valueNil()
    of HkFuture:
      let f = asFutureObj(target)
      case name
      of "state": newStringValue($f.state)
      of "value": f.value
      else: valueNil()
    of HkGenerator:
      let g = asGeneratorObj(target)
      case name
      of "state": newStringValue($g.state)
      of "last": g.lastValue
      of "done": valueBool(g.finished or g.state == GsDone)
      of "ip": valueInt(g.ip)
      else: valueNil()
    of HkKeyword:
      if name == "name": newStringValue(asKeywordObj(target).name) else: valueNil()
    of HkError:
      if name == "message": newStringValue(asErrorObj(target).message) else: valueNil()
  of VkSymbol:
    if name == "name": newStringValue(asSymbolName(target)) else: valueNil()
  else:
    valueNil()

proc setMember*(target: Value; name: string; val: Value) =
  case valueKind(target)
  of VkPointer:
    let obj = asHeapObject(target)
    if obj == nil:
      return
    case obj.kind
    of HkMap:
      asMapObj(target).entries[name] = val
    of HkGene:
      asGeneObj(target).props[name] = val
    of HkInstance:
      asInstanceObj(target).fields[name] = val
    of HkClass:
      asClassObj(target).methods[name] = val
    of HkArray:
      try:
        let idx = parseInt(name)
        arraySet(target, idx, val)
      except ValueError:
        discard
    else:
      discard
  else:
    discard

proc inferTypeName*(v: Value): string =
  case valueKind(v)
  of VkNil: "Nil"
  of VkBool: "Bool"
  of VkInt: "Int"
  of VkNumber: "Float"
  of VkSymbol: "Symbol"
  of VkPointer:
    let obj = asHeapObject(v)
    if obj == nil:
      "Pointer"
    else:
      case obj.kind
      of HkString: "String"
      of HkKeyword: "Keyword"
      of HkArray: "Array"
      of HkMap: "Map"
      of HkGene: "Gene"
      of HkFunction: "Function"
      of HkNativeFn: "NativeFn"
      of HkClass: "Class"
      of HkInstance: "Instance"
      of HkFuture: "Future"
      of HkGenerator: "Generator"
      of HkError: "Error"
  of VkUnknown: "Unknown"

proc valueEq*(a, b: Value): bool =
  if a.raw == b.raw:
    return true

  let ka = valueKind(a)
  let kb = valueKind(b)
  if (ka == VkNumber or ka == VkInt) and (kb == VkNumber or kb == VkInt):
    return asFloat(a) == asFloat(b)

  if ka == VkPointer and kb == VkPointer:
    let ao = asHeapObject(a)
    let bo = asHeapObject(b)
    if ao == nil or bo == nil:
      return false
    if ao.kind != bo.kind:
      return false
    case ao.kind
    of HkString:
      return asStringObj(a).value == asStringObj(b).value
    of HkKeyword:
      return asKeywordObj(a).name == asKeywordObj(b).name
    else:
      return cast[pointer](ao) == cast[pointer](bo)

  false

proc debugObj(v: Value; depth: int): string =
  if depth <= 0:
    return "..."

  let obj = asHeapObject(v)
  if obj == nil:
    return "<nil-pointer>"

  case obj.kind
  of HkString:
    "\"" & asStringObj(v).value & "\""
  of HkKeyword:
    "^" & asKeywordObj(v).name
  of HkArray:
    let arr = asArrayObj(v)
    "[" & arr.items.mapIt(toDebugString(it, depth - 1)).join(" ") & "]"
  of HkMap:
    let mapObj = asMapObj(v)
    var parts: seq[string] = @[]
    for k, val in mapObj.entries:
      parts.add("^" & k & " " & toDebugString(val, depth - 1))
    "{" & parts.join(" ") & "}"
  of HkGene:
    let g = asGeneObj(v)
    var parts: seq[string] = @[]
    parts.add(toDebugString(g.geneType, depth - 1))
    for k, val in g.props:
      parts.add("^" & k)
      parts.add(toDebugString(val, depth - 1))
    for child in g.children:
      parts.add(toDebugString(child, depth - 1))
    "(" & parts.join(" ") & ")"
  of HkFunction:
    let fnObj = asFunctionObj(v)
    "<fn " & fnObj.name & "/" & $fnObj.arity & ">"
  of HkNativeFn:
    let native = asNativeFunctionObj(v)
    "<native " & native.name & "/" & $native.arity & ">"
  of HkClass:
    let cls = asClassObj(v)
    "<class " & cls.name & ">"
  of HkInstance:
    let inst = asInstanceObj(v)
    let cls = asClassObj(inst.cls)
    let name = if cls == nil: "<unknown>" else: cls.name
    "<instance " & name & ">"
  of HkFuture:
    let f = asFutureObj(v)
    "<future " & $f.state & ">"
  of HkGenerator:
    let g = asGeneratorObj(v)
    "<generator " & $g.state & ">"
  of HkError:
    "<error \"" & asErrorObj(v).message & "\">"

proc toDebugString*(v: Value; maxDepth = 4): string =
  case valueKind(v)
  of VkNil:
    "nil"
  of VkBool:
    if asBool(v): "true" else: "false"
  of VkInt:
    $asInt(v)
  of VkNumber:
    let n = asFloat(v)
    if n.isNaN: "nan" else: $n
  of VkSymbol:
    "`" & asSymbolName(v)
  of VkPointer:
    debugObj(v, maxDepth)
  of VkUnknown:
    "<unknown>"

proc asString*(v: Value): string =
  case valueKind(v)
  of VkPointer:
    let obj = asHeapObject(v)
    if obj != nil and obj.kind == HkString:
      return asStringObj(v).value
    return toDebugString(v)
  of VkSymbol:
    asSymbolName(v)
  else:
    toDebugString(v)

proc expectType*(value: Value; annotation: string): bool =
  if annotation.len == 0 or annotation == "Any":
    return true
  let actual = inferTypeName(value)
  case annotation
  of "Number":
    actual == "Int" or actual == "Float"
  else:
    actual == annotation

proc toGeneValue*(typeName: string; props: openArray[(string, Value)]; children: openArray[Value]): Value =
  let g = newGeneValue(valueSymbol(typeName))
  for (k, v) in props:
    setGeneProp(g, k, v)
  for child in children:
    addGeneChild(g, child)
  g

const
  VNil* = Value(raw: QNaNMask or (uint64(ItNil) shl TagShift))
  VTrue* = Value(raw: QNaNMask or (uint64(ItBool) shl TagShift) or 1'u64)
  VFalse* = Value(raw: QNaNMask or (uint64(ItBool) shl TagShift))

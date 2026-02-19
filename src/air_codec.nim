import std/[tables]
import ./types
import ./ir

type
  AirCodecError* = object of CatchableError

  SectionBlob = object
    id: array[4, char]
    payload: seq[byte]

  Reader = object
    data: seq[byte]
    pos: int

const
  AirMagic = ['G', 'A', 'I', 'R']
  AirVersion = 1'u16

proc fail(msg: string): ref AirCodecError =
  new(result)
  result.msg = msg

proc asBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc writeU8(outBuf: var seq[byte]; v: uint8) =
  outBuf.add(v)

proc writeU16(outBuf: var seq[byte]; v: uint16) =
  outBuf.add(byte(v and 0xFF))
  outBuf.add(byte((v shr 8) and 0xFF))

proc writeU32(outBuf: var seq[byte]; v: uint32) =
  outBuf.add(byte(v and 0xFF))
  outBuf.add(byte((v shr 8) and 0xFF))
  outBuf.add(byte((v shr 16) and 0xFF))
  outBuf.add(byte((v shr 24) and 0xFF))

proc writeU64(outBuf: var seq[byte]; v: uint64) =
  for shift in [0'u8, 8, 16, 24, 32, 40, 48, 56]:
    outBuf.add(byte((v shr shift) and 0xFF))

proc writeI32(outBuf: var seq[byte]; v: int32) =
  writeU32(outBuf, cast[uint32](v))

proc writeI64(outBuf: var seq[byte]; v: int64) =
  writeU64(outBuf, cast[uint64](v))

proc writeF64(outBuf: var seq[byte]; v: float64) =
  var raw: uint64
  copyMem(addr raw, unsafeAddr v, sizeof(raw))
  writeU64(outBuf, raw)

proc writeString(outBuf: var seq[byte]; s: string) =
  writeU32(outBuf, s.len.uint32)
  if s.len > 0:
    let raw = asBytes(s)
    outBuf.add(raw)

proc readU8(r: var Reader): uint8 =
  if r.pos + 1 > r.data.len:
    raise fail("unexpected EOF (u8)")
  result = uint8(r.data[r.pos])
  inc(r.pos)

proc readU16(r: var Reader): uint16 =
  if r.pos + 2 > r.data.len:
    raise fail("unexpected EOF (u16)")
  result = uint16(r.data[r.pos]) or
    (uint16(r.data[r.pos + 1]) shl 8)
  inc(r.pos, 2)

proc readU32(r: var Reader): uint32 =
  if r.pos + 4 > r.data.len:
    raise fail("unexpected EOF (u32)")
  result = uint32(r.data[r.pos]) or
    (uint32(r.data[r.pos + 1]) shl 8) or
    (uint32(r.data[r.pos + 2]) shl 16) or
    (uint32(r.data[r.pos + 3]) shl 24)
  inc(r.pos, 4)

proc readU64(r: var Reader): uint64 =
  if r.pos + 8 > r.data.len:
    raise fail("unexpected EOF (u64)")
  for i in 0..7:
    result = result or (uint64(r.data[r.pos + i]) shl (8 * i))
  inc(r.pos, 8)

proc readI32(r: var Reader): int32 =
  cast[int32](readU32(r))

proc readI64(r: var Reader): int64 =
  cast[int64](readU64(r))

proc readF64(r: var Reader): float64 =
  let raw = readU64(r)
  copyMem(addr result, unsafeAddr raw, sizeof(raw))

proc readString(r: var Reader): string =
  let n = int(readU32(r))
  if n < 0 or r.pos + n > r.data.len:
    raise fail("invalid string length")
  if n == 0:
    return ""
  result = bytesToString(r.data.toOpenArray(r.pos, r.pos + n - 1))
  inc(r.pos, n)

proc symbolLocalIndex(m: AirModule; runtimeSid: int): uint32 =
  let name = symbolName(runtimeSid)
  if name.len == 0:
    return 0'u32
  m.internSymbol(name).uint32

proc runtimeSymbolFromLocal(m: AirModule; localIdx: uint32): int =
  let idx = int(localIdx)
  if idx < 0 or idx >= m.symbols.len:
    return internSymbol("")
  internSymbol(m.symbols[idx])

proc hasSymbolOperandInB(op: AirOpcode): bool =
  op in {
    OpLoadGlobal, OpStoreGlobal, OpCallMethod, OpCallMethodKw,
    OpCallSuper, OpCallSuperKw, OpMapSet, OpGeneSetProp, OpClassNew,
    OpMethodDef, OpPropDef, OpImport, OpExport, OpNsEnter,
    OpGetMember, OpGetMemberNil, OpGetMemberDefault, OpSetMember,
    OpCapAssert
  }

proc normalizeInstForEncode(m: AirModule; inst: AirInst): AirInst =
  result = inst
  if hasSymbolOperandInB(inst.op):
    result.b = symbolLocalIndex(m, int(inst.b))

proc denormalizeInstForDecode(m: AirModule; inst: AirInst): AirInst =
  result = inst
  if hasSymbolOperandInB(inst.op):
    result.b = runtimeSymbolFromLocal(m, inst.b).uint32

proc encodeValue(outBuf: var seq[byte]; v: Value)

proc encodeMap(outBuf: var seq[byte]; m: MapObj) =
  writeU32(outBuf, m.entries.len.uint32)
  for k, val in m.entries:
    writeString(outBuf, k)
    encodeValue(outBuf, val)

proc encodeArray(outBuf: var seq[byte]; arr: ArrayObj) =
  writeU32(outBuf, arr.items.len.uint32)
  for it in arr.items:
    encodeValue(outBuf, it)

proc encodeGene(outBuf: var seq[byte]; g: GeneObj) =
  encodeValue(outBuf, g.geneType)
  writeU32(outBuf, g.props.len.uint32)
  for k, val in g.props:
    writeString(outBuf, k)
    encodeValue(outBuf, val)
  writeU32(outBuf, g.children.len.uint32)
  for child in g.children:
    encodeValue(outBuf, child)

proc encodeValue(outBuf: var seq[byte]; v: Value) =
  case valueKind(v)
  of VkNil:
    writeU8(outBuf, 0)
  of VkBool:
    writeU8(outBuf, 1)
    writeU8(outBuf, if asBool(v): 1 else: 0)
  of VkInt:
    writeU8(outBuf, 2)
    writeI64(outBuf, asInt(v))
  of VkNumber:
    writeU8(outBuf, 3)
    writeF64(outBuf, asFloat(v))
  of VkSymbol:
    writeU8(outBuf, 4)
    writeString(outBuf, asSymbolName(v))
  of VkPointer:
    let obj = asHeapObject(v)
    if obj == nil:
      writeU8(outBuf, 0)
    else:
      case obj.kind
      of HkString:
        writeU8(outBuf, 5)
        writeString(outBuf, asStringObj(v).value)
      of HkKeyword:
        writeU8(outBuf, 6)
        writeString(outBuf, asKeywordObj(v).name)
      of HkArray:
        writeU8(outBuf, 7)
        encodeArray(outBuf, asArrayObj(v))
      of HkMap:
        writeU8(outBuf, 8)
        encodeMap(outBuf, asMapObj(v))
      of HkGene:
        writeU8(outBuf, 9)
        encodeGene(outBuf, asGeneObj(v))
      else:
        # Constants should avoid runtime-only pointer objects.
        writeU8(outBuf, 0)
  of VkUnknown:
    writeU8(outBuf, 0)

proc decodeValue(r: var Reader): Value

proc decodeArray(r: var Reader): Value =
  let n = int(readU32(r))
  var items: seq[Value] = @[]
  items.setLen(n)
  for i in 0..<n:
    items[i] = decodeValue(r)
  newArrayValue(items)

proc decodeMap(r: var Reader): Value =
  let n = int(readU32(r))
  let outMap = newMapValue()
  let mapObj = asMapObj(outMap)
  for _ in 0..<n:
    let k = readString(r)
    let v = decodeValue(r)
    mapObj.entries[k] = v
  outMap

proc decodeGene(r: var Reader): Value =
  let geneType = decodeValue(r)
  let outGene = newGeneValue(geneType)
  let g = asGeneObj(outGene)
  let propCount = int(readU32(r))
  for _ in 0..<propCount:
    let k = readString(r)
    g.props[k] = decodeValue(r)
  let childCount = int(readU32(r))
  for _ in 0..<childCount:
    g.children.add(decodeValue(r))
  outGene

proc decodeValue(r: var Reader): Value =
  let tag = readU8(r)
  case tag
  of 0:
    valueNil()
  of 1:
    valueBool(readU8(r) != 0)
  of 2:
    valueInt(readI64(r))
  of 3:
    valueFloat(readF64(r))
  of 4:
    valueSymbol(readString(r))
  of 5:
    newStringValue(readString(r))
  of 6:
    newKeywordValue(readString(r))
  of 7:
    decodeArray(r)
  of 8:
    decodeMap(r)
  of 9:
    decodeGene(r)
  else:
    valueNil()

proc fnFlagsToBits(flags: set[ir.FunctionFlag]): uint32 =
  if ir.FFlagAsync in flags: result = result or (1'u32 shl 0)
  if ir.FFlagGenerator in flags: result = result or (1'u32 shl 1)
  if ir.FFlagMacroLike in flags: result = result or (1'u32 shl 2)
  if ir.FFlagMethod in flags: result = result or (1'u32 shl 3)
  if ir.FFlagHasTry in flags: result = result or (1'u32 shl 4)
  if ir.FFlagAbstract in flags: result = result or (1'u32 shl 5)

proc bitsToFnFlags(bits: uint32): set[ir.FunctionFlag] =
  if (bits and (1'u32 shl 0)) != 0: result.incl(ir.FFlagAsync)
  if (bits and (1'u32 shl 1)) != 0: result.incl(ir.FFlagGenerator)
  if (bits and (1'u32 shl 2)) != 0: result.incl(ir.FFlagMacroLike)
  if (bits and (1'u32 shl 3)) != 0: result.incl(ir.FFlagMethod)
  if (bits and (1'u32 shl 4)) != 0: result.incl(ir.FFlagHasTry)
  if (bits and (1'u32 shl 5)) != 0: result.incl(ir.FFlagAbstract)

proc sectionId(s: string): array[4, char] =
  if s.len != 4:
    raise fail("invalid section id: " & s)
  [s[0], s[1], s[2], s[3]]

proc encodeAirModule*(m: AirModule): seq[byte] =
  var strsSec: seq[byte] = @[]
  writeU32(strsSec, m.strings.len.uint32)
  for s in m.strings:
    writeString(strsSec, s)

  var symsSec: seq[byte] = @[]
  writeU32(symsSec, m.symbols.len.uint32)
  for s in m.symbols:
    writeString(symsSec, s)

  var cnstSec: seq[byte] = @[]
  writeU32(cnstSec, m.constants.len.uint32)
  for c in m.constants:
    encodeValue(cnstSec, c)

  var typeSec: seq[byte] = @[]
  writeU32(typeSec, 0'u32)

  var efftSec: seq[byte] = @[]
  writeU32(efftSec, m.effects.len.uint32)
  for eff in m.effects:
    writeString(efftSec, eff.name)
    writeU32(efftSec, eff.capabilities.len.uint32)
    for cap in eff.capabilities:
      writeString(efftSec, cap)

  var toolSec: seq[byte] = @[]
  writeU32(toolSec, m.toolSchemas.len.uint32)
  for ts in m.toolSchemas:
    writeString(toolSec, ts.name)
    writeString(toolSec, ts.requestSchema)
    writeString(toolSec, ts.responseSchema)
    writeI32(toolSec, ts.timeoutMs.int32)
    writeString(toolSec, ts.retryPolicy)
    writeString(toolSec, ts.requiredCap)

  var codeSec: seq[byte] = @[]
  var codeCount = 0'u32
  for fn in m.functions:
    codeCount += fn.code.len.uint32
  writeU32(codeSec, codeCount)

  var funcSec: seq[byte] = @[]
  writeU32(funcSec, m.functions.len.uint32)
  var pcCursor = 0'u32

  for fn in m.functions:
    writeString(funcSec, fn.name)
    writeU32(funcSec, fnFlagsToBits(fn.flags))
    writeU32(funcSec, fn.arity.uint32)

    writeU32(funcSec, fn.params.len.uint32)
    for p in fn.params:
      writeString(funcSec, p.name)
      writeString(funcSec, p.typeAnn)
      var pFlags = 0'u8
      if p.isKeyword: pFlags = pFlags or 0x1'u8
      if p.isVariadic: pFlags = pFlags or 0x2'u8
      if p.hasDefault: pFlags = pFlags or 0x4'u8
      writeU8(funcSec, pFlags)
      if p.hasDefault:
        encodeValue(funcSec, p.defaultValue)

    writeU32(funcSec, fn.localCount.uint32)

    writeU32(funcSec, fn.localSymbols.len.uint32)
    for sid in fn.localSymbols:
      writeU32(funcSec, symbolLocalIndex(m, sid))

    writeU32(funcSec, fn.upvalueSymbols.len.uint32)
    for sid in fn.upvalueSymbols:
      writeU32(funcSec, symbolLocalIndex(m, sid))

    writeI32(funcSec, fn.effectProfileId.int32)
    writeI32(funcSec, fn.capabilityProfileId.int32)
    writeI32(funcSec, fn.matcherRef.int32)

    writeU32(funcSec, pcCursor)
    writeU32(funcSec, fn.code.len.uint32)

    for rawInst in fn.code:
      let inst = normalizeInstForEncode(m, rawInst)
      writeU16(codeSec, uint16(ord(inst.op)))
      writeU8(codeSec, inst.mode)
      writeU8(codeSec, inst.a)
      writeU32(codeSec, inst.b)
      writeU32(codeSec, inst.c)
      writeU32(codeSec, inst.d)

    pcCursor += fn.code.len.uint32

  var bmapSec: seq[byte] = @[]
  writeU32(bmapSec, 0'u32)

  var dbugSec: seq[byte] = @[]
  writeString(dbugSec, m.sourcePath)
  writeI32(dbugSec, m.mainFn.int32)
  writeU32(dbugSec, m.diagnostics.len.uint32)
  for d in m.diagnostics:
    writeString(dbugSec, d)

  let sections = @[
    SectionBlob(id: sectionId("STRS"), payload: strsSec),
    SectionBlob(id: sectionId("SYMS"), payload: symsSec),
    SectionBlob(id: sectionId("CNST"), payload: cnstSec),
    SectionBlob(id: sectionId("TYPE"), payload: typeSec),
    SectionBlob(id: sectionId("EFFT"), payload: efftSec),
    SectionBlob(id: sectionId("TOOL"), payload: toolSec),
    SectionBlob(id: sectionId("FUNC"), payload: funcSec),
    SectionBlob(id: sectionId("CODE"), payload: codeSec),
    SectionBlob(id: sectionId("BMAP"), payload: bmapSec),
    SectionBlob(id: sectionId("DBUG"), payload: dbugSec)
  ]

  let headerSize = 12
  let dirSize = sections.len * 12
  var cursor = uint32(headerSize + dirSize)

  result = @[]
  for ch in AirMagic:
    result.add(byte(ch))
  writeU16(result, AirVersion)
  writeU16(result, 0'u16)
  writeU16(result, sections.len.uint16)
  writeU16(result, 0'u16)

  for sec in sections:
    for ch in sec.id:
      result.add(byte(ch))
    writeU32(result, cursor)
    writeU32(result, sec.payload.len.uint32)
    cursor += sec.payload.len.uint32

  for sec in sections:
    result.add(sec.payload)

proc decodeAirModule*(dataIn: openArray[byte]): AirModule =
  var r = Reader(data: @dataIn, pos: 0)

  if r.data.len < 12:
    raise fail("invalid AIR blob: too small")
  if r.data[0] != byte(AirMagic[0]) or r.data[1] != byte(AirMagic[1]) or
     r.data[2] != byte(AirMagic[2]) or r.data[3] != byte(AirMagic[3]):
    raise fail("invalid AIR magic")

  r.pos = 4
  let version = readU16(r)
  if version != AirVersion:
    raise fail("unsupported AIR version: " & $version)
  discard readU16(r) # flags
  let sectionCount = int(readU16(r))
  discard readU16(r) # reserved

  var sections = initOrderedTable[string, tuple[offset: int, size: int]]()
  for _ in 0..<sectionCount:
    if r.pos + 12 > r.data.len:
      raise fail("invalid section directory")
    let id = bytesToString(r.data.toOpenArray(r.pos, r.pos + 3))
    inc(r.pos, 4)
    let off = int(readU32(r))
    let sz = int(readU32(r))
    if off < 0 or sz < 0 or off + sz > r.data.len:
      raise fail("invalid section range: " & id)
    sections[id] = (off, sz)

  proc sectionReader(id: string): Reader =
    if not sections.hasKey(id):
      return Reader(data: @[], pos: 0)
    let sec = sections[id]
    if sec.size == 0:
      return Reader(data: @[], pos: 0)
    Reader(data: @(r.data.toOpenArray(sec.offset, sec.offset + sec.size - 1)), pos: 0)

  result = newAirModule()

  block decodeStrs:
    var rs = sectionReader("STRS")
    if rs.data.len > 0:
      let n = int(readU32(rs))
      result.strings = @[]
      result.strings.setLen(n)
      for i in 0..<n:
        result.strings[i] = readString(rs)

  block decodeSyms:
    var rs = sectionReader("SYMS")
    if rs.data.len > 0:
      let n = int(readU32(rs))
      result.symbols = @[]
      result.symbols.setLen(n)
      for i in 0..<n:
        result.symbols[i] = readString(rs)

  block decodeConsts:
    var rc = sectionReader("CNST")
    if rc.data.len > 0:
      let n = int(readU32(rc))
      result.constants = @[]
      result.constants.setLen(n)
      for i in 0..<n:
        result.constants[i] = decodeValue(rc)

  block decodeEffects:
    var re = sectionReader("EFFT")
    if re.data.len > 0:
      let n = int(readU32(re))
      result.effects = @[]
      result.effects.setLen(n)
      for i in 0..<n:
        result.effects[i].name = readString(re)
        let capN = int(readU32(re))
        result.effects[i].capabilities = @[]
        result.effects[i].capabilities.setLen(capN)
        for j in 0..<capN:
          result.effects[i].capabilities[j] = readString(re)

  block decodeTools:
    var rt = sectionReader("TOOL")
    if rt.data.len > 0:
      let n = int(readU32(rt))
      result.toolSchemas = @[]
      result.toolSchemas.setLen(n)
      for i in 0..<n:
        result.toolSchemas[i].name = readString(rt)
        result.toolSchemas[i].requestSchema = readString(rt)
        result.toolSchemas[i].responseSchema = readString(rt)
        result.toolSchemas[i].timeoutMs = int(readI32(rt))
        result.toolSchemas[i].retryPolicy = readString(rt)
        result.toolSchemas[i].requiredCap = readString(rt)

  var allCode: seq[AirInst] = @[]
  block decodeCode:
    var rc = sectionReader("CODE")
    if rc.data.len > 0:
      let n = int(readU32(rc))
      allCode = @[]
      allCode.setLen(n)
      for i in 0..<n:
        let opRaw = int(readU16(rc))
        if opRaw < 0 or opRaw > ord(high(AirOpcode)):
          raise fail("invalid opcode in CODE section")
        allCode[i] = AirInst(
          op: AirOpcode(opRaw),
          mode: readU8(rc),
          a: readU8(rc),
          b: readU32(rc),
          c: readU32(rc),
          d: readU32(rc)
        )

  block decodeFuncs:
    var rf = sectionReader("FUNC")
    if rf.data.len > 0:
      let n = int(readU32(rf))
      result.functions = @[]
      result.functions.setLen(n)
      for i in 0..<n:
        let fnName = readString(rf)
        let flagBits = readU32(rf)
        let arity = readU32(rf)
        let fn = newAirFunction(fnName, int(arity))
        fn.flags = bitsToFnFlags(flagBits)

        let pN = int(readU32(rf))
        fn.params = @[]
        fn.params.setLen(pN)
        for p in 0..<pN:
          fn.params[p].name = readString(rf)
          fn.params[p].typeAnn = readString(rf)
          let pFlags = readU8(rf)
          fn.params[p].isKeyword = (pFlags and 0x1) != 0
          fn.params[p].isVariadic = (pFlags and 0x2) != 0
          fn.params[p].hasDefault = (pFlags and 0x4) != 0
          if fn.params[p].hasDefault:
            fn.params[p].defaultValue = decodeValue(rf)
          else:
            fn.params[p].defaultValue = valueNil()

        fn.localCount = int(readU32(rf))

        let localSymN = int(readU32(rf))
        fn.localSymbols = @[]
        fn.localSymbols.setLen(localSymN)
        for ls in 0..<localSymN:
          fn.localSymbols[ls] = runtimeSymbolFromLocal(result, readU32(rf))

        let upN = int(readU32(rf))
        fn.upvalueSymbols = @[]
        fn.upvalueSymbols.setLen(upN)
        for us in 0..<upN:
          fn.upvalueSymbols[us] = runtimeSymbolFromLocal(result, readU32(rf))

        fn.effectProfileId = int(readI32(rf))
        fn.capabilityProfileId = int(readI32(rf))
        fn.matcherRef = int(readI32(rf))

        let codeStart = int(readU32(rf))
        let codeLen = int(readU32(rf))
        if codeStart < 0 or codeLen < 0 or codeStart + codeLen > allCode.len:
          raise fail("invalid function code range")
        fn.code = @[]
        fn.code.setLen(codeLen)
        for k in 0..<codeLen:
          fn.code[k] = denormalizeInstForDecode(result, allCode[codeStart + k])

        result.functions[i] = fn

  block decodeDebug:
    var rd = sectionReader("DBUG")
    if rd.data.len > 0:
      result.sourcePath = readString(rd)
      result.mainFn = int(readI32(rd))
      let dn = int(readU32(rd))
      result.diagnostics = @[]
      result.diagnostics.setLen(dn)
      for i in 0..<dn:
        result.diagnostics[i] = readString(rd)

proc writeAirModule*(m: AirModule; path: string) =
  let raw = encodeAirModule(m)
  var s = newString(raw.len)
  if raw.len > 0:
    copyMem(addr s[0], unsafeAddr raw[0], raw.len)
  writeFile(path, s)

proc readAirModule*(path: string): AirModule =
  let content = readFile(path)
  decodeAirModule(asBytes(content))

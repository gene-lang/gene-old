import std/[strutils, parseutils, sequtils, tables]
import ./types

type
  ParseError* = object of CatchableError

  AstKind* = enum
    AkNil
    AkBool
    AkInt
    AkFloat
    AkString
    AkInterpolatedString
    AkSymbol
    AkKeyword
    AkList
    AkArray
    AkMap
    AkQuote

  MapEntry* = object
    key*: AstNode
    value*: AstNode

  AstNode* = ref object
    line*: int
    col*: int
    case kind*: AstKind
    of AkBool:
      boolVal*: bool
    of AkInt:
      intVal*: int64
    of AkFloat:
      floatVal*: float64
    of AkString, AkSymbol, AkKeyword:
      text*: string
    of AkInterpolatedString:
      parts*: seq[AstNode]
    of AkList, AkArray:
      items*: seq[AstNode]
    of AkMap:
      entries*: seq[MapEntry]
    of AkQuote:
      quoted*: AstNode
    of AkNil:
      discard

  Program* = ref object
    filename*: string
    exprs*: seq[AstNode]

  Reader = object
    source: string
    filename: string
    pos: int
    line: int
    col: int

  KeywordImplicit = enum
    KiNone
    KiTrue
    KiNil

  KeywordPattern = object
    root: string
    path: seq[string]
    implicit: KeywordImplicit
    hasPath: bool

proc newNode(kind: AstKind; line, col: int): AstNode =
  AstNode(kind: kind, line: line, col: col)

proc parseProgram*(source: string; filename = "<memory>"): Program

proc initReader(source, filename: string): Reader =
  Reader(source: source, filename: filename, pos: 0, line: 1, col: 1)

proc atEnd(r: Reader): bool {.inline.} =
  r.pos >= r.source.len

proc peek(r: Reader; offset = 0): char {.inline.} =
  let idx = r.pos + offset
  if idx < 0 or idx >= r.source.len:
    '\0'
  else:
    r.source[idx]

proc advance(r: var Reader): char =
  if r.atEnd:
    return '\0'
  result = r.source[r.pos]
  inc(r.pos)
  if result == '\n':
    inc(r.line)
    r.col = 1
  else:
    inc(r.col)

proc fail(r: Reader; msg: string): ref ParseError =
  new(result)
  result.msg = r.filename & ":" & $r.line & ":" & $r.col & ": " & msg

proc isDelimiter(ch: char): bool {.inline.} =
  ch == '\0' or ch.isSpaceAscii or ch in {'(', ')', '[', ']', '{', '}', '"', '\'', '`', ';', '#'}

proc skipWhitespaceAndComments(r: var Reader) =
  while true:
    while r.peek().isSpaceAscii:
      discard r.advance()

    if r.peek() == '#' and r.peek(1) != '@':
      while not r.atEnd and r.peek() != '\n':
        discard r.advance()
      continue

    break

proc parseExpr(r: var Reader): AstNode

proc mkKeywordNode(line, col: int; name: string): AstNode =
  result = newNode(AkKeyword, line, col)
  result.text = name

proc mkBoolNode(line, col: int; value: bool): AstNode =
  result = newNode(AkBool, line, col)
  result.boolVal = value

proc mkNilNode(line, col: int): AstNode =
  newNode(AkNil, line, col)

proc splitKeywordParts(raw: string): seq[string] =
  var start = 0
  for i, ch in raw:
    if ch == '^':
      result.add(raw[start..<i])
      start = i + 1
  if start <= raw.high:
    result.add(raw[start..^1])
  else:
    result.add("")

proc analyzeKeywordPattern(r: Reader; key: AstNode): KeywordPattern =
  let raw = key.text
  if raw.len == 0:
    raise r.fail("keyword requires a name after '^'")

  if raw[0] == '^':
    if raw.len == 1:
      raise r.fail("invalid keyword shorthand '^^' without a name")
    return KeywordPattern(root: raw[1..^1], path: @[], implicit: KiTrue, hasPath: false)

  if raw[0] == '!':
    if raw.len == 1:
      raise r.fail("invalid keyword shorthand '^!' without a name")
    return KeywordPattern(root: raw[1..^1], path: @[], implicit: KiNil, hasPath: false)

  if raw.find('^') < 0:
    return KeywordPattern(root: raw, path: @[], implicit: KiNone, hasPath: false)

  let parts = splitKeywordParts(raw)
  if parts.len < 2 or parts[0].len == 0:
    raise r.fail("invalid nested keyword '" & raw & "'")

  result = KeywordPattern(root: parts[0], path: @[], implicit: KiNone, hasPath: true)
  var i = 1
  while i < parts.len:
    let seg = parts[i]
    if seg.len == 0:
      if i + 1 >= parts.len or i + 1 != parts.high:
        raise r.fail("invalid nested keyword shorthand '" & raw & "'")
      var terminal = parts[i + 1]
      if terminal.len == 0:
        raise r.fail("invalid nested keyword shorthand '" & raw & "'")
      if terminal[0] == '!':
        if terminal.len == 1:
          raise r.fail("invalid nested keyword shorthand '" & raw & "'")
        terminal = terminal[1..^1]
        result.implicit = KiNil
      else:
        result.implicit = KiTrue
      result.path.add(terminal)
      i = parts.len
      continue

    var name = seg
    if name[0] == '!':
      if i != parts.high:
        raise r.fail("nil shorthand can only appear at the final nested key in '" & raw & "'")
      if name.len == 1:
        raise r.fail("invalid nested keyword shorthand '" & raw & "'")
      name = name[1..^1]
      result.implicit = KiNil
      result.path.add(name)
      i = parts.len
      continue

    result.path.add(name)
    inc(i)

  if result.path.len == 0:
    raise r.fail("invalid nested keyword '" & raw & "'")

proc buildNestedKeywordMap(path: seq[string]; terminal: AstNode; line, col: int): AstNode =
  if path.len == 0:
    return terminal

  var current = terminal
  for idx in countdown(path.high, 0):
    var m = newNode(AkMap, line, col)
    m.entries = @[]
    m.entries.add(MapEntry(
      key: mkKeywordNode(line, col, path[idx]),
      value: current
    ))
    current = m
  current

proc expandListKeywordShorthands(r: Reader; items: seq[AstNode]): seq[AstNode] =
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind != AkKeyword:
      result.add(item)
      inc(i)
      continue

    let pattern = analyzeKeywordPattern(r, item)
    let rootKey = mkKeywordNode(item.line, item.col, pattern.root)

    if pattern.hasPath:
      var terminal: AstNode
      case pattern.implicit
      of KiTrue:
        terminal = mkBoolNode(item.line, item.col, true)
      of KiNil:
        terminal = mkNilNode(item.line, item.col)
      of KiNone:
        if i + 1 >= items.len:
          raise r.fail("nested keyword '^" & item.text & "' requires a value")
        terminal = items[i + 1]
        inc(i)

      result.add(rootKey)
      result.add(buildNestedKeywordMap(pattern.path, terminal, item.line, item.col))
      inc(i)
      continue

    result.add(rootKey)
    case pattern.implicit
    of KiTrue:
      result.add(mkBoolNode(item.line, item.col, true))
    of KiNil:
      result.add(mkNilNode(item.line, item.col))
    of KiNone:
      discard
    inc(i)

proc parseParserMacro(r: var Reader): AstNode =
  let line = r.line
  let col = r.col
  discard r.advance() # #
  discard r.advance() # @

  skipWhitespaceAndComments(r)
  if r.atEnd:
    raise r.fail("#@ parser macro requires a target expression")
  let callee = parseExpr(r)

  skipWhitespaceAndComments(r)
  if r.atEnd or r.peek() in {')', ']', '}', ';'}:
    raise r.fail("#@ parser macro requires one argument expression")
  let arg = parseExpr(r)

  var n = newNode(AkList, line, col)
  n.items = @[callee, arg]
  n

proc parseInterpolation(content: string; filename: string; line, col: int): AstNode =
  let p = parseProgram(content, filename & "#interp")
  if p.exprs.len == 0:
    return newNode(AkNil, line, col)
  if p.exprs.len == 1:
    return p.exprs[0]

  # Multiple interpolation expressions become a synthetic `(do ...)` list.
  var doList = newNode(AkList, line, col)
  doList.items = @[newNode(AkSymbol, line, col)]
  doList.items[0].text = "do"
  for expr in p.exprs:
    doList.items.add(expr)
  doList

proc readString(r: var Reader): AstNode =
  let line = r.line
  let col = r.col
  discard r.advance() # opening quote

  var literal = ""
  var parts: seq[AstNode] = @[]

  template flushLiteral() =
    if literal.len > 0:
      var lit = newNode(AkString, line, col)
      lit.text = literal
      parts.add(lit)
      literal.setLen(0)

  template parseInterpolationChunk(label: string) =
    discard r.advance() # consume '{'
    flushLiteral()

    var depth = 1
    var exprBuf = ""
    var inString = false
    var escaped = false

    while true:
      if r.atEnd:
        raise r.fail("unterminated " & label & "{...} interpolation")
      let c = r.advance()
      if inString:
        exprBuf.add(c)
        if escaped:
          escaped = false
        elif c == '\\':
          escaped = true
        elif c == '"':
          inString = false
        continue

      case c
      of '"':
        inString = true
        exprBuf.add(c)
      of '{':
        inc(depth)
        exprBuf.add(c)
      of '}':
        dec(depth)
        if depth == 0:
          break
        exprBuf.add(c)
      else:
        exprBuf.add(c)

    let parsed = parseInterpolation(exprBuf, r.filename, line, col)
    parts.add(parsed)

  while true:
    if r.atEnd:
      raise r.fail("unterminated string literal")

    let ch = r.advance()
    case ch
    of '"':
      break
    of '\\':
      let esc = r.advance()
      case esc
      of 'n': literal.add('\n')
      of 'r': literal.add('\r')
      of 't': literal.add('\t')
      of '"': literal.add('"')
      of '\\': literal.add('\\')
      else:
        literal.add(esc)
    of '$':
      if r.peek() == '{':
        parseInterpolationChunk("$")
      else:
        literal.add(ch)
    of '#':
      if r.peek() == '{':
        parseInterpolationChunk("#")
      else:
        literal.add(ch)
    else:
      literal.add(ch)

  if parts.len == 0:
    var s = newNode(AkString, line, col)
    s.text = literal
    return s

  flushLiteral()
  var n = newNode(AkInterpolatedString, line, col)
  n.parts = parts
  n

proc readAtomToken(r: var Reader): string =
  var tok = ""
  while true:
    let c = r.peek()
    if isDelimiter(c):
      break
    tok.add(r.advance())
  tok

proc parseAtom(r: var Reader): AstNode =
  let line = r.line
  let col = r.col
  let token = readAtomToken(r)

  if token.len == 0:
    raise r.fail("unexpected token")

  if token == "nil":
    return newNode(AkNil, line, col)
  if token == "true" or token == "false":
    var b = newNode(AkBool, line, col)
    b.boolVal = token == "true"
    return b

  var iVal: int64
  if parseBiggestInt(token, iVal) == token.len:
    var n = newNode(AkInt, line, col)
    n.intVal = iVal
    return n

  var fVal: float
  if parseFloat(token, fVal) == token.len and token.contains('.'):
    var f = newNode(AkFloat, line, col)
    f.floatVal = fVal
    return f

  var s = newNode(AkSymbol, line, col)
  s.text = token
  s

proc parseListLike(r: var Reader; closing: char; kind: AstKind): AstNode =
  let line = r.line
  let col = r.col
  discard r.advance() # opening

  if kind == AkMap:
    var m = newNode(AkMap, line, col)
    m.entries = @[]
    skipWhitespaceAndComments(r)
    while not r.atEnd and r.peek() != closing:
      let key = parseExpr(r)
      if key.kind == AkKeyword:
        let pattern = analyzeKeywordPattern(r, key)
        let rootKey = mkKeywordNode(key.line, key.col, pattern.root)

        if pattern.hasPath:
          var terminal: AstNode
          case pattern.implicit
          of KiTrue:
            terminal = mkBoolNode(key.line, key.col, true)
          of KiNil:
            terminal = mkNilNode(key.line, key.col)
          of KiNone:
            skipWhitespaceAndComments(r)
            if r.atEnd or r.peek() == closing:
              raise r.fail("map key '^" & key.text & "' without value")
            terminal = parseExpr(r)
          m.entries.add(MapEntry(
            key: rootKey,
            value: buildNestedKeywordMap(pattern.path, terminal, key.line, key.col)
          ))
        else:
          case pattern.implicit
          of KiTrue:
            m.entries.add(MapEntry(key: rootKey, value: mkBoolNode(key.line, key.col, true)))
          of KiNil:
            m.entries.add(MapEntry(key: rootKey, value: mkNilNode(key.line, key.col)))
          of KiNone:
            skipWhitespaceAndComments(r)
            if r.atEnd or r.peek() == closing:
              raise r.fail("map key without value")
            let val = parseExpr(r)
            m.entries.add(MapEntry(key: rootKey, value: val))
      else:
        skipWhitespaceAndComments(r)
        if r.atEnd or r.peek() == closing:
          raise r.fail("map key without value")
        let val = parseExpr(r)
        m.entries.add(MapEntry(key: key, value: val))
      skipWhitespaceAndComments(r)

    if r.peek() != closing:
      raise r.fail("expected '" & $closing & "' to close map")
    discard r.advance()
    return m

  if kind == AkList:
    var segments: seq[seq[AstNode]] = @[@[]]
    var sawSemicolon = false

    skipWhitespaceAndComments(r)
    while not r.atEnd and r.peek() != closing:
      if r.peek() == ';':
        sawSemicolon = true
        if segments.len == 0 or segments[^1].len == 0:
          raise r.fail("empty expression segment in ';' chain")
        discard r.advance()
        segments.add(@[])
        skipWhitespaceAndComments(r)
        continue

      segments[^1].add(parseExpr(r))
      skipWhitespaceAndComments(r)

    if r.peek() != closing:
      raise r.fail("expected '" & $closing & "'")
    discard r.advance()

    if segments.len == 0 or segments[^1].len == 0 and sawSemicolon:
      raise r.fail("empty expression segment in ';' chain")

    var normalized: seq[seq[AstNode]] = @[]
    for seg in segments:
      normalized.add(expandListKeywordShorthands(r, seg))

    if not sawSemicolon:
      var node = newNode(AkList, line, col)
      node.items = normalized[0]
      return node

    if normalized[0].len == 0:
      raise r.fail("empty expression segment in ';' chain")

    var chain: AstNode
    if normalized[0].len == 1:
      if normalized[0][0].kind == AkList:
        chain = normalized[0][0]
      else:
        chain = newNode(AkList, line, col)
        chain.items = @[normalized[0][0]]
    else:
      chain = newNode(AkList, line, col)
      chain.items = normalized[0]

    for i in 1..<normalized.len:
      if normalized[i].len == 0:
        raise r.fail("empty expression segment in ';' chain")
      var step = newNode(AkList, line, col)
      step.items = @[chain]
      for n in normalized[i]:
        step.items.add(n)
      chain = step
    return chain

  var node = newNode(kind, line, col)
  node.items = @[]

  skipWhitespaceAndComments(r)
  while not r.atEnd and r.peek() != closing:
    node.items.add(parseExpr(r))
    skipWhitespaceAndComments(r)

  if r.peek() != closing:
    raise r.fail("expected '" & $closing & "'")
  discard r.advance()
  node

proc parseKeyword(r: var Reader): AstNode =
  let line = r.line
  let col = r.col
  discard r.advance() # ^
  let token = readAtomToken(r)
  if token.len == 0:
    raise r.fail("keyword requires a name after '^'")
  var key = newNode(AkKeyword, line, col)
  key.text = token
  key

proc parseQuote(r: var Reader): AstNode =
  let line = r.line
  let col = r.col
  discard r.advance()
  skipWhitespaceAndComments(r)
  var q = newNode(AkQuote, line, col)
  q.quoted = parseExpr(r)
  q

proc parseExpr(r: var Reader): AstNode =
  skipWhitespaceAndComments(r)
  if r.atEnd:
    return nil

  case r.peek()
  of '(':
    parseListLike(r, ')', AkList)
  of '[':
    parseListLike(r, ']', AkArray)
  of '{':
    parseListLike(r, '}', AkMap)
  of '#':
    if r.peek(1) == '@':
      parseParserMacro(r)
    else:
      raise r.fail("unexpected '#' token")
  of '"':
    readString(r)
  of '^':
    parseKeyword(r)
  of '\'', '`':
    parseQuote(r)
  else:
    parseAtom(r)

proc parseProgram*(source: string; filename = "<memory>"): Program =
  var reader = initReader(source, filename)
  result = Program(filename: filename, exprs: @[])

  while true:
    skipWhitespaceAndComments(reader)
    if reader.atEnd:
      break
    let expr = parseExpr(reader)
    if expr != nil:
      result.exprs.add(expr)

proc parseOne*(source: string; filename = "<memory>"): AstNode =
  let p = parseProgram(source, filename)
  if p.exprs.len == 0:
    return newNode(AkNil, 1, 1)
  p.exprs[0]

proc astToString*(n: AstNode): string

proc astToStringList(items: seq[AstNode]; openCh, closeCh: string): string =
  openCh & items.mapIt(astToString(it)).join(" ") & closeCh

proc astToString*(n: AstNode): string =
  case n.kind
  of AkNil:
    "nil"
  of AkBool:
    if n.boolVal: "true" else: "false"
  of AkInt:
    $n.intVal
  of AkFloat:
    $n.floatVal
  of AkString:
    "\"" & n.text & "\""
  of AkSymbol:
    n.text
  of AkKeyword:
    "^" & n.text
  of AkQuote:
    "`" & astToString(n.quoted)
  of AkInterpolatedString:
    "\"" & n.parts.mapIt(astToString(it)).join(" ") & "\""
  of AkList:
    astToStringList(n.items, "(", ")")
  of AkArray:
    astToStringList(n.items, "[", "]")
  of AkMap:
    var parts: seq[string] = @[]
    for entry in n.entries:
      parts.add(astToString(entry.key))
      parts.add(astToString(entry.value))
    "{" & parts.join(" ") & "}"

proc quotedAstToValue*(node: AstNode): Value

proc quotedMapToValue(entries: seq[MapEntry]): Value =
  let mapVal = newMapValue()
  for entry in entries:
    let keyVal = quotedAstToValue(entry.key)
    let valVal = quotedAstToValue(entry.value)
    mapSet(mapVal, keyVal, valVal)
  mapVal

proc quotedListToGeneValue(items: seq[AstNode]): Value =
  if items.len == 0:
    return newGeneValue(valueSymbol("list"))

  var geneType = quotedAstToValue(items[0])
  let g = newGeneValue(geneType)

  var i = 1
  while i < items.len:
    let node = items[i]
    if node.kind == AkKeyword and i + 1 < items.len:
      setGeneProp(g, node.text, quotedAstToValue(items[i + 1]))
      inc(i, 2)
    else:
      addGeneChild(g, quotedAstToValue(node))
      inc(i)
  g

proc quotedAstToValue*(node: AstNode): Value =
  case node.kind
  of AkNil:
    valueNil()
  of AkBool:
    valueBool(node.boolVal)
  of AkInt:
    valueInt(node.intVal)
  of AkFloat:
    valueFloat(node.floatVal)
  of AkString:
    newStringValue(node.text)
  of AkSymbol:
    valueSymbol(node.text)
  of AkKeyword:
    newKeywordValue(node.text)
  of AkQuote:
    quotedAstToValue(node.quoted)
  of AkArray:
    var values: seq[Value] = @[]
    for item in node.items:
      values.add(quotedAstToValue(item))
    newArrayValue(values)
  of AkMap:
    quotedMapToValue(node.entries)
  of AkList:
    quotedListToGeneValue(node.items)
  of AkInterpolatedString:
    # Quoted interpolation stays as a Gene form: (str_interp ...)
    let g = newGeneValue(valueSymbol("str_interp"))
    for part in node.parts:
      addGeneChild(g, quotedAstToValue(part))
    g

# Credit:
# The parser and basic data types are built on top of EDN Parser[1] that is
# created by Roland Sadowski.
# 1. https://github.com/rosado/edn.nim

import lexbase, streams, strutils, unicode, tables, sets, times, nre, base64

import ./types

type
  ParseError* = object of CatchableError
  ParseEofError* = object of ParseError

  ParseMode* = enum
    PmDefault
    PmDocument
    PmStream
    PmFirst
    PmPackage
    PmArchive

  ParseOptions* {.acyclic.} = ref object
    parent*: ParseOptions
    data*: Table[string, Value]
    units*: Table[string, Value]

  Parser* = object of BaseLexer
    options*: ParseOptions
    filename*: string
    str*: string
    num_with_units*: seq[(TokenKind, string, string)] # token kind + number + unit
    # document*: Document
    token_kind*: TokenKind
    error*: ParseErrorKind
    # references*: References
    document_props_done*: bool  # flag to tell whether we have read document properties
    trace_root*: SourceTrace
    trace_stack*: seq[SourceTrace]

  TokenKind* = enum
    TkError
    TkEof
    TkString
    TkInt
    TkFloat
    TkNumberWithUnit
    TkDate
    TkDateTime
    TkTime

  ParseErrorKind* = enum
    ErrNone
    ErrInvalidToken
    ErrEofExpected
    ErrQuoteExpected
    ErrRegexEndExpected

  ParseInfo* = tuple[line, col: int]

  # ParseScope* = ref object
  #   parent*: ParseScope
  #   mappings*: Table[Key, Value]

  # ParseFunction* = proc(self: var Parser, scope: ParseScope, props: Table[Key, Value], children: seq[Value]): Value

  # ParseHandlerType* = enum
  #   PhDefault
  #   PhNativeFn

  # ParseHandler* = ref object of CustomValue
  #   is_macro*: bool  # if true, do not evaluate arguments before calling function
  #   case `type`*: ParseHandlerType
  #   of PhNativeFn:
  #     native_fn: ParseFunction
  #   else:
  #     scope*: ParseScope
  #     args*: seq[Value]
  #     body*: seq[Value]

  MacroReader = proc(p: var Parser): Value {.gcsafe.}
  MacroArray = array[char, MacroReader]

  MapKind = enum
    MkMap
    MkGene
    MkDocument

  PropState = enum
    PropKey
    PropValue

  DelimitedListResult = object
    list: seq[Value]
    map: Table[Key, Value]
    is_semicolon_chain: bool          # True when (a; b; c) syntax was used
    segments: seq[seq[Value]]         # Semicolon-separated segments
    segment_props: seq[Table[Key, Value]]  # Props for each segment

  Handler = proc(self: var Parser, input: Value): Value {.gcsafe.}

  StreamHandler = proc(value: Value)

  ParserConfig* = ref object
    initialized*: bool
    default_units*: Table[string, Value]
    hex_table*: Table[char, uint8]
    date_format*: TimeFormat
    datetime_format*: TimeFormat
    macros*: MacroArray
    dispatch_macros*: MacroArray
    handlers*: Table[Key, Handler]

const non_constituents: seq[char] = @[]

# Global parser configuration - thread-local for safety
var parser_config {.threadvar.}: ParserConfig

# Backward compatibility aliases
template INITIALIZED(): bool = parser_config.initialized
template DEFAULT_UNITS(): Table[string, Value] = parser_config.default_units
template HEX(): Table[char, uint8] = parser_config.hex_table
template DATE_FORMAT(): TimeFormat = parser_config.date_format
template DATETIME_FORMAT(): TimeFormat = parser_config.datetime_format
template macros(): MacroArray = parser_config.macros
template dispatch_macros(): MacroArray = parser_config.dispatch_macros
template handlers(): Table[Key, Handler] = parser_config.handlers

#################### Interfaces ##################

proc init*() {.gcsafe.}
proc keys*(self: ParseOptions): HashSet[string]
proc `[]`*(self: ParseOptions, name: string): Value
proc unit_keys*(self: ParseOptions): HashSet[string]
proc `unit`*(self: ParseOptions, name: string): Value
proc read*(self: var Parser): Value {.gcsafe.}
proc skip_comment(self: var Parser)
proc skip_block_comment(self: var Parser) {.gcsafe.}
proc skip_ws(self: var Parser) {.gcsafe.}
proc read_map(self: var Parser, mode: MapKind): Table[Key, Value] {.gcsafe.}

#################### Implementations #############

converter to_int(c: char): int = result = ord(c)

#################### ParseOptions ################

proc default_options*(): ParseOptions =
  result = ParseOptions()
  for k, v in DEFAULT_UNITS:
    result.units[k] = v

proc new_options*(prototype: ParseOptions): ParseOptions =
  result = ParseOptions()
  for k in prototype.keys().items:
    result.data[k] = prototype[k]
  for k in prototype.unit_keys.items:
    result.units[k] = prototype.unit(k)

proc extend*(self: ParseOptions): ParseOptions =
  ParseOptions(
    parent: self,
    data: init_table[string, Value](),
    units: init_table[string, Value](),
  )

proc keys*(self: ParseOptions): HashSet[string] =
  result = init_hash_set[string]()
  for k in self.data.keys:
    result.incl(k)
  for k in self.parent.keys():
    result.incl(k)

proc `[]`*(self: ParseOptions, name: string): Value =
  if self.data.has_key(name):
    return self.data[name]
  elif not self.parent.is_nil:
    return self.parent[name]
  else:
    return NIL

proc `[]=`*(self: ParseOptions, name: string, value: Value) =
  self.data[name] = value

proc unit_keys*(self: ParseOptions): HashSet[string] =
  result = init_hash_set[string]()
  for k in self.units.keys:
    result.incl(k)
  for k in self.parent.unit_keys():
    result.incl(k)

proc `unit`*(self: ParseOptions, name: string): Value =
  if self.units.has_key(name):
    return self.units[name]
  elif not self.parent.is_nil:
    return self.parent.unit(name)
  else:
    return NIL

#################### Parser ######################

proc new_parser*(options: ParseOptions): Parser =
  if parser_config == nil or not parser_config.initialized:
    init()

  return Parser(
    # document: Document(),
    options: new_options(options),
    # references: References(),
    trace_stack: @[],
  )

proc new_parser*(): Parser =
  if parser_config == nil or not parser_config.initialized:
    init()

  return Parser(
    # document: Document(),
    options: default_options(),
    # references: References(),
    trace_stack: @[],
  )

proc non_constituent(c: char): bool =
  result = non_constituents.contains(c)

proc is_macro(c: char): bool =
  result = c.to_int < macros.len and macros[c] != nil

proc is_terminating_macro(c: char): bool =
  result = c != '#' and c != '\'' and is_macro(c)

proc get_macro(ch: char): MacroReader =
  result = macros[ch]

### === ERROR HANDLING UTILS ===

proc err_info(self: Parser): ParseInfo =
  # get_col_number returns 0-indexed, convert to 1-indexed for display
  result = (self.line_number, self.get_col_number(self.bufpos) + 1)

proc format_position(self: Parser): string =
  let info = err_info(self)
  if self.filename.len > 0:
    return self.filename & ":" & $info.line & ":" & $info.col
  $info.line & ":" & $info.col

proc current_trace(self: Parser): SourceTrace =
  if self.trace_stack.len == 0:
    return nil
  self.trace_stack[^1]

proc push_trace(self: var Parser, trace: SourceTrace) =
  if trace.is_nil:
    return
  self.trace_stack.add(trace)

proc leave_trace(self: var Parser) =
  if self.trace_stack.len > 0:
    # Keep the root trace (index 0) intact so we always have a parent context
    if self.trace_stack.len > 1:
      self.trace_stack.setLen(self.trace_stack.len - 1)
  else:
    discard

### === MACRO READERS ===

proc handle_hex_char(c: char, x: var int): bool =
  result = true
  case c
  of '0'..'9': x = (x shl 4) or (ord(c) - ord('0'))
  of 'a'..'f': x = (x shl 4) or (ord(c) - ord('a') + 10)
  of 'A'..'F': x = (x shl 4) or (ord(c) - ord('A') + 10)
  else: result = false

proc parse_escaped_utf16(buf: cstring, pos: var int): int =
  result = 0
  for _ in 0..3:
    if handle_hex_char(buf[pos], result):
      inc(pos)
    else:
      return -1

proc parse_string(self: var Parser, start: char, triple_mode: bool = false): TokenKind =
  result = TkString
  self.str = ""
  var pos = self.bufpos
  while true:
    case self.buf[pos]
    of '\0':
      self.error = ErrQuoteExpected
      break
    of '\'':
      if self.buf[pos] == start:
        inc(pos)
        break
      else:
        add(self.str, self.buf[pos])
        inc(pos)
    of '#':
      if start == '#' and self.buf[pos + 1] in ['<', '{', '[', '(']:
        break
      else:
        add(self.str, self.buf[pos])
        inc(pos)
    of '"':
      if triple_mode:
        if self.buf[pos + 1] == '"' and self.buf[pos + 2] == '"':
          pos = pos + 3
          self.str = self.str.replace(re"^\s*\n", "\n").replace(re"\n\s*$", "\n")
          break
        else:
          inc(pos)
          add(self.str, '"')
      elif self.buf[pos] == start or start == '#':
        inc(pos)
        break
      else:
        add(self.str, self.buf[pos])
        inc(pos)
    of '\\':
      if start == '\'':
        add(self.str, self.buf[pos])
        inc(pos)
      else:
        case self.buf[pos+1]
        of 'b':
          add(self.str, '\b')
          inc(pos, 2)
        of 'f':
          add(self.str, '\b')
          inc(pos, 2)
        of 'n':
          add(self.str, '\L')
          inc(pos, 2)
        of 'r':
          add(self.str, '\C')
          inc(pos, 2)
        of 't':
          add(self.str, '\t')
          inc(pos, 2)
        of 'u':
          inc(pos, 2)
          var r = parse_escaped_utf16(cstring(self.buf), pos)
          if r < 0:
            self.error = ErrInvalidToken
            break
          # deal with surrogates
          if (r and 0xfc00) == 0xd800:
            if self.buf[pos] & self.buf[pos + 1] != "\\u":
              self.error = ErrInvalidToken
              break
            inc(pos, 2)
            var s = parse_escaped_utf16(cstring(self.buf), pos)
            if (s and 0xfc00) == 0xdc00 and s > 0:
              r = 0x10000 + (((r - 0xd800) shl 10) or (s - 0xdc00))
            else:
              self.error = ErrInvalidToken
              break
          add(self.str, toUTF8(Rune(r)))
        else:
          add(self.str, self.buf[pos+1])
          inc(pos, 2)
    of '\c':
      pos = lexbase.handleCR(self, pos)
      add(self.str, '\c')
    of '\L':
      pos = lexbase.handleLF(self, pos)
      add(self.str, '\L')
    else:
      add(self.str, self.buf[pos])
      inc(pos)
  self.bufpos = pos

proc read_string(self: var Parser, start: char): Value =
  if start == '"' and self.buf[self.bufpos] == '"' and self.buf[self.bufpos + 1] == '"':
    self.bufpos += 2
    discard self.parse_string(start, true)
  else:
    discard self.parse_string(start)
  if self.error != ErrNone:
    raise new_exception(ParseError, "read_string failure: " & $self.error)
  result = self.str
  self.str = ""

# read_string1 removed - ' is now used for character literals, not strings

proc read_string2(self: var Parser): Value =
  self.read_string('"')

proc read_quoted(self: var Parser): Value =
  let r = new_ref(VkQuote)
  r.quote = self.read()
  result = r.to_ref_value()

proc read_string_interpolation(self: var Parser): Value {.gcsafe.} =
  var gene = new_gene("#Str".to_symbol_value())
  var triple_mode = false
  if self.buf[self.bufpos] == '"' and self.buf[self.bufpos + 1] == '"':
    self.bufpos += 2
    triple_mode = true

  var all_are_strings = true
  while true:
    if self.buf[self.bufpos] == '#':
      self.bufpos.inc()
      case self.buf[self.bufpos]:
      of '<':
        self.bufpos.inc()
        self.skip_block_comment()
        continue

      of '{':
        self.bufpos.inc()
        self.skip_ws()
        if self.buf[self.bufpos] == '^':
          let r = new_map_value()
          map_data(r) = self.read_map(MkMap)
          gene.children.add(r)
          all_are_strings = false
        else:
          let v = self.read()
          if v.kind != VkString:
            all_are_strings = false
          gene.children.add(v)
          self.skip_ws()
          self.bufpos.inc()
        continue

      of '(', '[':
        let v = self.read()
        gene.children.add(v)
        if v.kind != VkString:
          all_are_strings = false
        continue

      else:
        discard

    discard self.parse_string('#', triple_mode)
    if self.error != ErrNone:
      raise new_exception(ParseError, "read_string_interpolation failure: " & $self.error)
    gene.children.add(self.str)
    self.str = ""
    if self.buf[self.bufpos - 1] == '"':
      break

  if all_are_strings:
    var s = ""
    for v in gene.children:
      s.add(v.str)
    return s
  else:
    return gene.to_gene_value()

proc read_unquoted(self: var Parser): Value =
  # Standalone '%' and '%=' are operators, not unquote markers.
  let ch = self.buf[self.bufpos]
  if ch == '=':
    self.bufpos.inc()
    return "%=".to_symbol_value()
  if ch == EndOfFile or ch in {' ', '\t', '\L', '\c', ')', ']', '}'}:
    return "%".to_symbol_value()

  # Special logic for %_
  var unquote_discard = false
  if self.buf[self.bufpos] == '_':
    self.bufpos.inc()
    unquote_discard = true
  let r = new_ref(VkUnquote)
  r.unquote = self.read()
  r.unquote_discard = unquote_discard
  result = r.to_ref_value()

proc skip_block_comment(self: var Parser) {.gcsafe.} =
  # Block comments: #< ... ># (can span multiple lines)
  # Also supports nested: #<< ... >># etc.
  var pos = self.bufpos
  var prev_char: char = '\0'
  
  while pos < self.buf.len:
    let ch = self.buf[pos]
    case ch
    of '\L':
      # Track newlines for correct line numbers after block comment
      pos = lexbase.handleLF(self, pos)
      prev_char = '\L'
      continue
    of '\c':
      pos = lexbase.handleCR(self, pos)
      prev_char = '\c'
      continue
    of '#':
      # Check for end of block comment: >#
      if prev_char == '>' and pos >= 2:
        # Make sure it's not >>>#
        if self.buf[pos-2] != '>':
          inc(pos)
          break
      inc(pos)
      prev_char = '#'
    of EndOfFile:
      break
    else:
      prev_char = ch
      inc(pos)
  
  self.bufpos = pos
  self.str = ""

proc skip_comment(self: var Parser) =
  var pos = self.bufpos
  while true:
    case self.buf[pos]
    of '\L':
      pos = lexbase.handleLF(self, pos)
      break
    of '\c':
      pos = lexbase.handleCR(self, pos)
      break
    of EndOfFile:
      break
    else:
      inc(pos)
  self.bufpos = pos

proc read_token(self: var Parser, lead_constituent: bool, chars_allowed: openarray[char]): string =
  var pos = self.bufpos
  var ch: char

  # Check buffer bounds
  if pos >= self.buf.len:
    return ""

  ch = self.buf[pos]
  if lead_constituent and non_constituent(ch):
    raise new_exception(ParseError, "Invalid leading character " & ch)

  # Build token incrementally to handle tokens of any length
  result = ""

  while pos < self.buf.len:
    ch = self.buf[pos]

    if ch == '\\':
      # Handle escape sequence
      inc(pos)
      if pos < self.buf.len:
        ch = self.buf[pos]
        if ch != EndOfFile:
          # Preserve escaped slash markers (\/) so symbol parsing can
          # distinguish literal slash from complex-symbol separators.
          if ch == '/':
            result.add('\\')
          result.add(ch)
          inc(pos)
        else:
          break
      else:
        break
    elif ch == EndOfFile or is_space_ascii(ch) or ch == ',' or ch == ';' or (is_terminating_macro(ch) and ch notin chars_allowed):
      # Token ends (semicolon terminates tokens for chaining syntax)
      break
    elif non_constituent(ch):
      raise new_exception(ParseError, "Invalid constituent character: " & ch)
    else:
      result.add(ch)
      inc(pos)

  self.bufpos = pos

proc read_token(self: var Parser, lead_constituent: bool): string =
  return self.read_token(lead_constituent, [':'])

proc unescape_escaped_slashes(s: string): string =
  if '\\' notin s:
    return s

  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '/':
      result.add('/')
      i += 2
    else:
      result.add(s[i])
      inc(i)

proc read_character(self: var Parser): Value =
  # New character literal syntax: 'a' or '\n' 
  # Note: bufpos is already positioned after the opening ' by the macro system
  
  if self.buf[self.bufpos] == EndOfFile:
    raise new_exception(ParseError, "EOF while reading character literal")
  
  var ch = self.buf[self.bufpos]
  var result_char: char
  
  if ch == '\\':
    # Escape sequence: '\n', '\t', etc.
    inc(self.bufpos)
    if self.buf[self.bufpos] == EndOfFile:
      raise new_exception(ParseError, "EOF after backslash in character literal")
    
    let escaped = self.buf[self.bufpos] 
    case escaped:
    of 'n':
      result_char = '\n'
    of 't':
      result_char = '\t'
    of 'r':
      result_char = '\r'
    of 'b':
      result_char = '\b'
    of 'f':
      result_char = '\f'
    of '\\':
      result_char = '\\'
    of '\'':
      result_char = '\''
    of '"':
      result_char = '"'
    else:
      # For other characters, use them literally (e.g., '\a' -> 'a')
      result_char = escaped
    inc(self.bufpos)
  else:
    # Single character: 'a', 'b', etc.
    result_char = ch
    inc(self.bufpos)
  
  # Expect closing '
  let closing_char = self.buf[self.bufpos]
  if closing_char != '\'':
    raise new_exception(ParseError, "Expected closing ' in character literal, got: " & $closing_char & " (ord: " & $closing_char.ord & ")")
  inc(self.bufpos)  # Skip closing '
  
  return result_char

# Character parsing removed - use 'a' syntax instead

proc skip_ws(self: var Parser) {.gcsafe.} =
  # Optimized: fast path for common whitespace characters
  var pos = self.bufpos

  # Fast batch processing of simple whitespace
  while pos < self.buf.len:
    let ch = self.buf[pos]
    case ch
    of ' ', '\t', ',':
      inc(pos)
    of '\c':
      # Handle CR and keep lineStart in sync for column tracking
      pos = lexbase.handleCR(self, pos)
    of '\L':
      # Handle LF and keep lineStart in sync for column tracking
      pos = lexbase.handleLF(self, pos)
    of '#':
      # Comments need special handling
      self.bufpos = pos
      if pos + 1 < self.buf.len:
        case self.buf[pos + 1]:
        of ' ', '!', '#', '\r', '\n':
          self.skip_comment()
          pos = self.bufpos
        of '<':
          self.skip_block_comment()
          pos = self.bufpos
        else:
          break
      else:
        break
    else:
      break

  self.bufpos = pos

proc match_symbol(s: string): Value =
  if s == "/":
    return s.to_symbol_value()

  if '/' notin s:
    return s.to_symbol_value()

  # Fast path for common complex symbols with no escapes.
  if '\\' notin s:
    return s.split('/').to_complex_symbol()

  # Split on unescaped '/' only; keep escaped slashes as literal chars.
  var parts: seq[string] = @[]
  var part = ""
  var has_separator = false
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '/':
      part.add('/')
      i += 2
    elif s[i] == '/':
      has_separator = true
      parts.add(part)
      part = ""
      inc(i)
    else:
      part.add(s[i])
      inc(i)

  if not has_separator:
    return part.to_symbol_value()

  parts.add(part)
  return parts.to_complex_symbol()

proc interpret_token(token: string): Value =
  case token
  of "nil":
    return NIL
  of "void":
    return VOID
  of "true":
    return TRUE
  of "false":
    return FALSE
  of "not_found":
    return NOT_FOUND
  else:
    return match_symbol(token)

proc read_gene_type(self: var Parser): Value =
  result = NIL
  var delimiter = ')'
  # the bufpos should be already be past the opening paren etc.
  while true:
    self.skip_ws()
    var pos = self.bufpos
    let ch = self.buf[pos]
    if ch == EndOfFile:
      let msg = "EOF while reading list $# $# $#"
      raise new_exception(ParseError, format(msg, delimiter, self.filename, self.line_number))

    if ch == delimiter:
      # Do not increase position because we need to read other components in
      # inc(pos)
      # p.bufpos = pos
      break

    if is_macro(ch):
      let m = get_macro(ch)
      inc(pos)
      self.bufpos = pos
      result = m(self)
      # if result != nil:
      #   break
    else:
      result = self.read()
      # if result != nil:
      #   break
    break

proc to_keys(self: string): seq[string] =
  # let parts = self.split("^")
  # return parts
  var pos = 0
  var key = ""
  var last: char = EndOfFile
  while pos < self.len:
    var ch = self[pos]
    if ch == '^' and last != '^':
      result.add(key)
      key = ""
    else:
      key.add(ch)
    last = ch
    pos.inc

  result.add(key)

proc read_map(self: var Parser, mode: MapKind): Table[Key, Value] {.gcsafe.} =
  var ch: char
  var key: string
  var state = PropState.PropKey

  result = init_table[Key, Value]()
  var map = result.addr

  while true:
    self.skip_ws()
    ch = self.buf[self.bufpos]
    if ch == EndOfFile:
      if mode == MkDocument:
        return result
      else:
        raise new_exception(ParseError, "EOF while reading ")
    elif ch == ']' or (mode == MkGene and ch == '}') or (mode == MkMap and ch == ')'):
      raise new_exception(ParseError, "Unmatched delimiter: " & $self.buf[self.bufpos] & " at " & self.format_position())

    case state:
    of PropKey:
      if ch == '^':
        self.bufPos.inc()
        if self.buf[self.bufPos] == '^':
          self.bufPos.inc()
          key = unescape_escaped_slashes(self.read_token(false))
          result[key.to_key()] = TRUE
        elif self.buf[self.bufPos] == '!':
          self.bufPos.inc()
          key = unescape_escaped_slashes(self.read_token(false))
          result[key.to_key()] = NIL
        else:
          key = unescape_escaped_slashes(self.read_token(false))
          if key.contains('^'):
            let parts = key.to_keys()
            map = result.addr
            for part in parts[0..^2]:
              let key = part.to_key()
              if map[].has_key(key):
                let r = map[][key]
                map = map_data(r).addr
              else:
                var m = new_map_value()
                map[][key] = m
                map = map_data(m).addr
            key = parts[^1]
            case key[0]:
            of '^':
              map[][key[1..^1].to_key()] = TRUE
              continue
            of '!':
              map[][key[1..^1].to_key()] = FALSE
              continue
            else:
              discard
          state = PropState.PropValue
      elif mode == MkGene or mode == MkDocument:
        # Do not consume ')'
        # if ch == ')':
        #   self.bufPos.inc()
        return
      elif ch == '}':
        self.bufPos.inc()
        return
      else:
        raise new_exception(ParseError, "Expect key at " & $self.bufpos & " but found " & self.buf[self.bufpos])

    of PropState.PropValue:
      if ch == EndOfFile or ch == '^':
        raise new_exception(ParseError, "Expect value for " & key)
      elif mode == MkGene:
        if ch == ')':
          raise new_exception(ParseError, "Expect value for " & key)
      elif ch == '}':
        raise new_exception(ParseError, "Expect value for " & key)
      state = PropState.PropKey

      var value = self.read()
      if map[].has_key(key.to_key()):
        raise new_exception(ParseError, "Bad input at " & $self.bufpos & " (conflict with property shortcut found earlier.)")
        # if value.kind == VkMap:
        #   for k, v in value.map:
        #     map[][key].map[k] = v
        # else:
        #   raise new_exception(ParseError, "Bad input: mixing map with non-map")
      else:
        map[][key.to_key()] = value

      map = result.addr

proc read_delimited_list(self: var Parser, delimiter: char, is_recursive: bool): DelimitedListResult {.gcsafe.} =
  # the bufpos should be already be past the opening paren etc.
  var list: seq[Value] = @[]
  var in_gene = delimiter == ')'
  var map_found = false
  var count = 0
  
  # For semicolon chaining: track segments separated by ';'
  # Each segment becomes (prev_segment current_items...)
  var has_semicolons = false
  var segments: seq[seq[Value]] = @[@[]]  # Start with one empty segment
  var segment_props: seq[Table[Key, Value]] = @[initTable[Key, Value]()]
  
  while true:
    self.skip_ws()
    var pos = self.bufpos

    # Check buffer bounds
    if pos >= self.buf.len:
      let msg = "EOF while reading list $# $# $#"
      raise new_exception(ParseError, format(msg, delimiter, self.filename, self.line_number))

    let ch = self.buf[pos]
    if ch == EndOfFile:
      let msg = "EOF while reading list $# $# $#"
      raise new_exception(ParseError, format(msg, delimiter, self.filename, self.line_number))

    if in_gene and ch == '^':
      if map_found:
        let msg = "properties found in wrong place while reading list $# $# $#"
        raise new_exception(ParseError, format(msg, delimiter, self.filename, self.line_number))
      else:
        map_found = true
        let props = self.read_map(MkGene)
        # Add props to current segment
        for k, v in props:
          segment_props[^1][k] = v
        continue

    if ch == delimiter:
      inc(pos)
      self.bufpos = pos
      break
    
    # Handle semicolon for chaining: (a; b; c) = (((a) b) c)
    if in_gene and ch == ';':
      inc(pos)
      self.bufpos = pos
      has_semicolons = true
      # Start a new segment
      segments.add(@[])
      segment_props.add(initTable[Key, Value]())
      map_found = false  # Reset for new segment
      continue

    if is_macro(ch):
      let m = get_macro(ch)
      inc(pos)
      self.bufpos = pos
      let node = m(self)
      if node != PARSER_IGNORE:
        inc(count)
        if self.options["debug"]: echo $node, "\n"
        segments[^1].add(node)
    else:
      let node = self.read()
      if node != PARSER_IGNORE:
        inc(count)
        if self.options["debug"]: echo $node, "\n"
        segments[^1].add(node)

  # Return segments for semicolon chains, let caller handle chaining
  if has_semicolons:
    result.list = @[]
    result.is_semicolon_chain = true
    result.segments = segments
    result.segment_props = segment_props
  else:
    # No semicolons - return normal list from first (only) segment
    result.list = segments[0]
    result.map = segment_props[0]

proc add_line_col(self: var Parser, gene: ptr Gene, start_pos: int) =
  if gene.is_nil:
    return

  let parent_trace = self.current_trace()
  # get_col_number returns 0-indexed column, convert to 1-indexed for display
  var column =
    if start_pos >= 0:
      self.get_col_number(start_pos) + 1
    else:
      self.get_col_number(self.bufpos) + 1

  if column < 1:
    column = 1

  let line = self.line_number
  let trace = new_source_trace(self.filename, line, column)

  if not parent_trace.is_nil:
    attach_child(parent_trace, trace)
  else:
    self.trace_root = trace

  gene.trace = trace
  self.push_trace(trace)

proc read_gene(self: var Parser): Value {.gcsafe.} =
  var gene = new_gene()
  #echo "line ", getCurrentLine(p), "lineno: ", p.line_number, " col: ", getColNumber(p, p.bufpos)
  #echo $get_current_line(p) & " LINENO(" & $p.line_number & ")"
  let start_pos = (if self.bufpos > 0: self.bufpos - 1 else: 0)
  self.add_line_col(gene, start_pos)
  defer: self.leave_trace()
  gene.type = self.read_gene_type()
  var result_list = self.read_delimited_list(')', true)
  
  # Handle semicolon chaining: (a; b; c) = (((a) b) c)
  if result_list.is_semicolon_chain:
    # gene.type contains the first element (e.g., 'a')
    # result_list.segments contains segments after gene.type:
    #   segments[0] = [] (empty, before first ;)
    #   segments[1] = [b] (after first ;)
    #   segments[2] = [c] (after second ;)
    # We build: (((gene.type) segments[1]...) segments[2]...) ...
    
    let segments = result_list.segments
    let segment_props = result_list.segment_props
    
    # Start with gene.type wrapped in a gene: (gene.type)
    var current_gene: Value
    if segments.len > 0 and segments[0].len > 0:
      # First segment has content - build (gene.type segment[0]...)
      let g = new_gene(gene.type)
      for item in segments[0]:
        g.children.add(item)
      for k, v in segment_props[0]:
        g.props[k] = v
      current_gene = g.to_gene_value()
    else:
      # First segment is empty - just wrap gene.type: (gene.type)
      current_gene = new_gene(gene.type).to_gene_value()
    
    # Process remaining segments
    for i in 1..<segments.len:
      let segment = segments[i]
      let seg_props = segment_props[i]
      # Wrap current_gene as type, add segment items as children
      let g = new_gene(current_gene)
      for item in segment:
        g.children.add(item)
      for k, v in seg_props:
        g.props[k] = v
      current_gene = g.to_gene_value()
    
    result = current_gene
    return result
  
  gene.props = result_list.map
  gene.children = result_list.list
  if not gene.type.is_nil() and gene.type.kind == VkSymbol:
    let key = gene.type.str.to_key()
    if handlers.has_key(key):
      let handler = handlers[key]
      result = gene.to_gene_value()
      return handler(self, result)

  result = gene.to_gene_value()

proc read_map(self: var Parser): Value {.gcsafe.} =
  let r = new_map_value()
  map_data(r) = self.read_map(MkMap)
  result = r

proc read_array(self: var Parser): Value {.gcsafe.} =
  var r = new_array_value()
  array_data(r) = self.read_delimited_list(']', true).list
  result = r

proc read_stream(self: var Parser): Value {.gcsafe.} =
  let r = new_ref(VkStream)
  let list_result = self.read_delimited_list(']', true)
  r.stream = list_result.list
  r.stream_index = 0
  r.stream_ended = false
  result = r.to_ref_value()

proc is_regex_terminator(ch: char): bool {.inline.} =
  ch == '\0' or ch in {' ', '\t', '\c', '\L', ')', ']', '}', ';', ','}

proc parse_regex_segment(self: var Parser, pos: var int, seg: var string) =
  while true:
    case self.buf[pos]
    of '\0':
      raise new_exception(ParseError, "EOF while reading regex literal")
    of '/':
      inc(pos)
      break
    of '\\':
      case self.buf[pos + 1]
      of '\\', '/':
        seg.add(self.buf[pos + 1])
        inc(pos, 2)
      else:
        seg.add('\\')
        inc(pos)
    of '\c':
      pos = lexbase.handleCR(self, pos)
      seg.add('\c')
    of '\L':
      pos = lexbase.handleLF(self, pos)
      seg.add('\L')
    else:
      seg.add(self.buf[pos])
      inc(pos)

proc read_regex(self: var Parser): Value =
  var pos = self.bufpos
  var pattern = ""
  var replacement = ""
  var flags: uint8 = 0'u8
  var has_replacement = false

  parse_regex_segment(self, pos, pattern)

  # Check if there's another delimiter (replacement segment) before terminator
  block:
    var scan = pos
    var found_delim = false
    var saw_non_flag = false
    while true:
      let ch = self.buf[scan]
      if ch == '\0' or ch in {' ', '\t', '\c', '\L'}:
        break
      if ch == '\\':
        saw_non_flag = true
        if self.buf[scan + 1] == '\0':
          break
        scan += 2
        continue
      if ch == '/':
        found_delim = true
        break
      if ch in {')', ']', '}', ';', ','}:
        if not saw_non_flag:
          break
        inc(scan)
        continue
      if ch in {'i', 'm'} and not saw_non_flag:
        inc(scan)
        continue
      saw_non_flag = true
      inc(scan)
    if found_delim:
      parse_regex_segment(self, pos, replacement)
      has_replacement = true

  while true:
    let ch = self.buf[pos]
    if is_regex_terminator(ch):
      break
    case ch
    of 'i':
      flags = flags or REGEX_FLAG_IGNORE_CASE
    of 'm':
      flags = flags or REGEX_FLAG_MULTILINE
    else:
      raise new_exception(ParseError, "Invalid regex flag: " & $ch)
    inc(pos)

  self.bufpos = pos
  result = new_regex_value(pattern, flags, replacement, has_replacement)
  # var pos = self.bufpos
  # var flags: set[RegexFlag]
  # while true:
  #   case self.buf[pos]
  #   of '\0':
  #     self.error = ErrRegexEndExpected
  #   of '/':
  #     inc(pos)
  #     if self.buf[pos] == 'i':
  #       inc(pos)
  #       flags.incl(RfIgnoreCase)
  #       if self.buf[pos] == 'm':
  #         inc(pos)
  #         flags.incl(RfMultiLine)
  #     elif self.buf[pos] == 'm':
  #       inc(pos)
  #       flags.incl(RfMultiLine)
  #       if self.buf[pos] == 'i':
  #         inc(pos)
  #         flags.incl(RfIgnoreCase)
  #     break
  #   of '\\':
  #     case self.buf[pos+1]
  #     of '\\', '/':
  #       add(self.str, self.buf[pos+1])
  #       inc(pos, 2)
  #     of 'b':
  #       add(self.str, '\b')
  #       inc(pos, 2)
  #     of 'f':
  #       add(self.str, '\b')
  #       inc(pos, 2)
  #     of 'n':
  #       add(self.str, '\L')
  #       inc(pos, 2)
  #     of 'r':
  #       add(self.str, '\C')
  #       inc(pos, 2)
  #     of 't':
  #       add(self.str, '\t')
  #       inc(pos, 2)
  #     of 'u':
  #       inc(pos, 2)
  #       var r = parse_escaped_utf16(self.buf, pos)
  #       if r < 0:
  #         self.error = ErrInvalidToken
  #         break
  #       # deal with surrogates
  #       if (r and 0xfc00) == 0xd800:
  #         if self.buf[pos] & self.buf[pos + 1] != "\\u":
  #           self.error = ErrInvalidToken
  #           break
  #         inc(pos, 2)
  #         var s = parse_escaped_utf16(self.buf, pos)
  #         if (s and 0xfc00) == 0xdc00 and s > 0:
  #           r = 0x10000 + (((r - 0xd800) shl 10) or (s - 0xdc00))
  #         else:
  #           self.error = ErrInvalidToken
  #           break
  #       add(self.str, toUTF8(Rune(r)))
  #     else:
  #       # don't bother with the Error
  #       add(self.str, self.buf[pos])
  #       inc(pos)
  #   of '\c':
  #     pos = lexbase.handleCR(self, pos)
  #     add(self.str, '\c')
  #   of '\L':
  #     pos = lexbase.handleLF(self, pos)
  #     add(self.str, '\L')
  #   else:
  #     add(self.str, self.buf[pos])
  #     inc(pos)
  # self.bufpos = pos
  # result = new_gene_regex(self.str, flags)

proc read_unmatched_delimiter(self: var Parser): Value =
  raise new_exception(ParseError, "Unmatched delimiter: " & $self.buf[self.bufpos] & " at " & self.format_position())

proc read_decorator(self: var Parser): Value =
  let gene = new_gene(self.read())
  gene.children.add(self.read())
  result = gene.to_gene_value()

proc read_dispatch(self: var Parser): Value =
  let ch = self.buf[self.bufpos]
  let m = dispatch_macros[ch]
  if m == nil:
    self.bufpos -= 1
    var token = self.read_token(false)
    result = interpret_token(token)
  else:
    self.bufpos += 1
    result = m(self)

proc init_macro_array() =
  macros['\''] = read_character  # ' for character literals like 'a' or '\n'
  macros['"'] = read_string2     # " for strings
  macros['`'] = read_quoted
  # macros['\\'] removed - no longer support \a syntax
  macros['%'] = read_unquoted
  macros['#'] = read_dispatch
  macros['('] = read_gene
  macros['{'] = read_map
  macros['['] = read_array
  macros[')'] = read_unmatched_delimiter
  macros[']'] = read_unmatched_delimiter
  macros['}'] = read_unmatched_delimiter

proc init_dispatch_macro_array() =
  dispatch_macros['['] = read_stream
  dispatch_macros['/'] = read_regex
  dispatch_macros['@'] = read_decorator
  dispatch_macros['"'] = read_string_interpolation

proc init_handlers() =
  discard

proc init*() =
  if parser_config != nil and parser_config.initialized:
    return

  # Create new parser configuration
  parser_config = ParserConfig(
    initialized: true,
    default_units: {
      "m": 60.to_value(),       # m  = minute
      "s": 1.to_value(),        # s  = second (default)
      "ms": 0.001.to_value(),   # ms = millisecond
      "ns": 1e-9.to_value(),    # ns = nanosecond
    }.to_table(),
    hex_table: {
      '0': 0u8, '1': 1u8, '2': 2u8, '3': 3u8, '4': 4u8,
      '5': 5u8, '6': 6u8, '7': 7u8, '8': 8u8, '9': 9u8,
      'a': 10u8, 'b': 11u8, 'c': 12u8, 'd': 13u8, 'e': 14u8, 'f': 15u8,
      'A': 10u8, 'B': 11u8, 'C': 12u8, 'D': 13u8, 'E': 14u8, 'F': 15u8,
    }.to_table(),
    date_format: init_time_format("yyyy-MM-dd"),
    datetime_format: init_time_format("yyyy-MM-dd'T'HH:mm:sszzz"),
    handlers: initTable[Key, Handler]()
  )

  init_macro_array()
  init_dispatch_macro_array()
  init_handlers()

proc open*(self: var Parser, input: Stream, filename: string) =
  # Use a larger buffer size (1MB) to handle long tokens without buffer overflow
  # The buffer will grow automatically if needed
  lexbase.open(self, input, bufLen = 1024 * 1024)
  self.filename = filename
  self.str = ""
  self.trace_root = new_source_trace(filename, 1, 1)
  self.trace_stack.setLen(0)
  self.trace_stack.add(self.trace_root)

proc open*(self: var Parser, input: Stream) =
  self.open(input, "<input>")

proc open*(self: var Parser, code: string, filename: string) =
  self.open(new_string_stream(code), filename)

proc open*(self: var Parser, code: string) =
  self.open(new_string_stream(code), "<input>")

proc close*(self: var Parser) {.inline.} =
  lexbase.close(self)

proc parse_bin(self: var Parser): Value =
  var bytes: seq[uint8] = @[]
  var byte: uint8 = 0
  var size: uint = 0
  while self.buf[self.bufpos] in ['0', '1', '~']:
    if self.buf[self.bufpos] == '~':
      self.bufpos += 1
      self.skip_ws()
      continue

    size += 1
    byte = byte.shl(1)
    if self.buf[self.bufpos] == '1':
      byte = byte.or(1)
    if size mod 8 == 0:
      bytes.add(byte)
      byte = 0
    self.bufpos += 1
  if size mod 8 != 0:
    # Add last partial byte
    bytes.add(byte)

  if size == 0:
    not_allowed("parse_bin: input length is zero.")
  elif size <= 8:
    todo()
    # return Value(
    #   kind: VkByte,
    #   byte: bytes[0],
    #   byte_bit_size: size,
    # )
  else:
    todo()
    # return Value(
    #   kind: VkBin,
    #   bin: bytes,
    #   bin_bit_size: size,
    # )

proc parse_hex(self: var Parser): Value =
  var bytes: seq[uint8] = @[]
  var byte: uint8 = 0
  var size: uint = 0
  var ch = self.buf[self.bufpos]
  while ch in '0'..'9' or ch in 'A'..'F' or ch in 'a'..'f' or ch == '~':
    if ch == '~':
      self.bufpos += 1
      self.skip_ws()
      ch = self.buf[self.bufpos]
      continue

    size += 4
    byte = byte.shl(4)
    byte += HEX[ch]
    if size mod 8 == 0:
      bytes.add(byte)
      byte = 0
    self.bufpos += 1
    ch = self.buf[self.bufpos]
  if size mod 8 != 0:
    # Add last partial byte
    bytes.add(byte)

  if size == 0:
    not_allowed("parse_bin: input length is zero.")
  elif size <= 8:
    todo()
    # return Value(
    #   kind: VkByte,
    #   byte: bytes[0],
    #   byte_bit_size: size,
    # )
  else:
    todo()
    # return Value(
    #   kind: VkBin,
    #   bin: bytes,
    #   bin_bit_size: size,
    # )

proc add(self: var seq[uint8], str: string) =
  for c in str:
    self.add(uint8(c))

proc parse_base64(self: var Parser): Value =
  var bytes: seq[uint8] = @[]
  var ch = self.buf[self.bufpos]
  var s = ""
  while ch in '0'..'9' or ch in 'A'..'Z' or ch in 'a'..'z' or ch in ['+', '/', '=', '~']:
    if ch == '~':
      self.bufpos += 1
      self.skip_ws()
      ch = self.buf[self.bufpos]
      continue

    s &= ch
    self.bufpos += 1
    ch = self.buf[self.bufpos]
    if s.len == 4:
      echo s
      bytes.add(decode(s))
      s = ""

  if s.len > 0:
    bytes.add(decode(s))

  todo()
  # return Value(
  #   kind: VkBin,
  #   bin: bytes,
  #   bin_bit_size: uint(bytes.len * 8),
  # )

proc parse_number(self: var Parser): TokenKind =
  result = TokenKind.TkEof
  var pos = self.bufpos
  if (self.buf[pos] == '-') or (self.buf[pos] == '+'):
    add(self.str, self.buf[pos])
    inc(pos)
  if self.buf[pos] == '.':
    add(self.str, "0.")
    inc(pos)
    result = TkFloat
  else:
    result = TkInt
    while self.buf[pos] in Digits:
      add(self.str, self.buf[pos])
      inc(pos)
    if self.buf[pos] == '.':
      add(self.str, '.')
      inc(pos)
      result = TkFloat
  # digits after the dot
  while self.buf[pos] in Digits:
    add(self.str, self.buf[pos])
    inc(pos)
  if self.buf[pos] in {'E', 'e'}:
    add(self.str, self.buf[pos])
    inc(pos)
    result = TkFloat
    if self.buf[pos] in {'+', '-'}:
      add(self.str, self.buf[pos])
      inc(pos)
    while self.buf[pos] in Digits:
      add(self.str, self.buf[pos])
      inc(pos)
  elif self.buf[pos] in {'a' .. 'z', 'A' .. 'Z'}:
    var num = self.str
    self.str = ""
    self.bufpos = pos
    var unit = ""
    while true:
      add(unit, self.buf[pos])
      inc(pos)
      if self.buf[pos] notin {'a' .. 'z', 'A' .. 'Z'}:
        break
    self.bufpos = pos
    self.num_with_units.add((result, num, unit))
    if self.buf[pos] in {'.', '0' .. '9'}: # handle something like 1m30s
      discard self.parse_number()
    result = TkNumberWithUnit
  self.bufpos = pos

proc read_number(self: var Parser): Value =
  set_len(self.str, 0)  # Only clear str when parsing numbers
  if self.buf[self.bufpos] == '0':
    let ch = self.buf[self.bufpos + 1]
    case ch:
    of '!':
      self.bufpos += 2
      return self.parse_bin()
    of '*':
      self.bufpos += 2
      return self.parse_hex()
    of '#':
      self.bufpos += 2
      return self.parse_base64()
    else:
      discard

  var num_result = self.parse_number()
  case num_result
  of TkEof:
    raise new_exception(ParseError, "EOF while reading")
  of TkInt:
    var c = self.buf[self.bufpos]
    case c:
    of '-':
      var s = self.str & self.read_token(false, [':'])
      if s.contains(':'):
        # var date = parse(s, DATETIME_FORMAT, utc())
        # result = new_gene_datetime(date)
        todo("datetime")
      else:
        # var date = parse(s, DATE_FORMAT, utc())
        # result = new_gene_date(date)
        todo("date")
    of ':':
      # var s = self.str & self.read_token(false, [':'])
      # var parts = s.split(":")
      # var hour = parts[0].parse_int()
      # var min = parts[1].parse_int()
      # var sec = parts[2].parse_int()
      # result = new_gene_time(hour, min, sec)
      todo("time")
    of '/':
      if not isDigit(self.buf[self.bufpos+1]):
        let e = err_info(self)
        raise new_exception(ParseError, "Error reading a ratio: " & $e)
      try:
        discard parse_biggest_int(self.str)  # numerator - will be used when ratio is implemented
      except ValueError as e:
        raise new_exception(ParseError, e.msg)
      inc(self.bufpos)
      self.str = ""
      var denom_tok = parse_number(self)
      if denom_tok == TkInt:
        # var denom = parse_biggest_int(self.str)
        # result = new_gene_ratio(numerator.int, denom.int)
        todo("ratio")
      else:
        raise new_exception(ParseError, "Error reading a ratio: " & self.str)
    else:
      try:
        let parsed_int = parse_biggest_int(self.str)
        result = parsed_int.to_value()
      except ValueError as e:
        raise new_exception(ParseError, e.msg)
  of TkFloat:
    result = parse_float(self.str)
  of TkError:
    raise new_exception(ParseError, "Error reading a number: " & self.str)
  of TkNumberWithUnit:
    todo("number with unit")
    # result = new_gene_int()
    # for (kind, num, unit) in self.num_with_units:
    #   var unit_base = self.options.units[unit]
    #   if kind == TkInt:
    #     if result.kind == VkInt:
    #       if unit_base.kind == VkInt:
    #         result.int += num.parse_int() * unit_base.int.int()
    #       else:
    #         result = new_gene_float(result.int.to_float())
    #         result.float += num.parse_int().to_float() * unit_base.float
    #     else:
    #       result.float += num.parse_int().to_float() * unit_base.float
    #   else:
    #     if result.kind == VkInt:
    #       result = new_gene_float(result.int.to_float())
    #     if unit_base.kind == VkInt:
    #       result.float += num.parse_float() * unit_base.int.to_float()
    #     else:
    #       result.float += num.parse_float() * unit_base.float
  else:
    raise new_exception(ParseError, "Error reading a number (?): " & self.str)

proc read*(self: var Parser): Value =
  # Optimized: only clear str when actually needed (for number parsing)
  self.skip_ws()
  let ch = self.buf[self.bufpos]
  var token: string
  case ch
  of EndOfFile:
    # get_col_number returns 0-indexed, convert to 1-indexed for display
    let position = (self.line_number, self.get_col_number(self.bufpos) + 1)
    raise new_exception(ParseEofError, "EOF while reading " & $position)
  of '0'..'9':
    return read_number(self)
  elif is_macro(ch):
    let m = macros[ch] # save line:col metadata here?
    inc(self.bufpos)
    result = m(self)
    if result == PARSER_IGNORE:
      result = self.read()
    return result
  elif ch in ['+', '-']:
    if isDigit(self.buf[self.bufpos + 1]):
      return self.read_number()
    else:
      token = self.read_token(false)
      result = interpret_token(token)
      if result == PARSER_IGNORE:
        result = self.read()
      return result
  else:
    token = self.read_token(true)
    result = interpret_token(token)
    if result == PARSER_IGNORE:
      result = self.read()

# proc read_document_properties(self: var Parser) =
#   if self.document_props_done:
#     return
proc read*(self: var Parser, s: Stream, filename: string): Value =
  self.open(s, filename)
  defer: self.close()
  result = self.read()

proc read*(self: var Parser, buffer: string): Value =
  var s = new_string_stream(buffer)
  self.open(s, "<input>")
  defer: self.close()
  result = self.read()

proc read_all*(self: var Parser, buffer: string): seq[Value] =
  var s = new_string_stream(buffer)
  self.open(s, "<input>")
  defer: self.close()
  var node = self.read()
  while true:
    if node != PARSER_IGNORE:
      result.add(node)
    self.skip_ws()
    if self.buf[self.bufpos] == EndOfFile:
      break
    else:
      node = self.read()

proc read_stream*(self: var Parser, buffer: string, stream_handler: StreamHandler) =
  var s = new_string_stream(buffer)
  self.open(s, "<input>")
  defer: self.close()
  var node = self.read()
  while true:
    if not node.is_nil:
      stream_handler(node)
    try:
      node = self.read()
    except ParseEofError:
      break

proc read*(s: Stream, filename: string): Value =
  var parser = new_parser()
  return parser.read(s, filename)

proc read*(buffer: string): Value =
  var parser = new_parser()
  return parser.read(buffer)

proc read_all*(buffer: string): seq[Value] =
  var parser = new_parser()
  return parser.read_all(buffer)

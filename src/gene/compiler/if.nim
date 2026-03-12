import tables

import ../types

const COND_KEY* = "cond"
const THEN_KEY* = "then"
const ELIF_KEY* = "elif"
const ELSE_KEY* = "else"
const INDEX_KEY* = "index"
const TOTAL_KEY* = "total"

type
  IfState = enum
    IsIf, IsIfCond, IsIfLogic,
    IsElif, IsElifCond, IsElifLogic,
    IsIfNot, IsElifNot,
    IsElse,

proc normalize_if*(self: ptr Gene) =
  # TODO: return a tuple to be used by the translator
  if self.props.has_key("cond".to_key()):
    return
  let `type` = self.type
  if `type` == "if".to_symbol_value():
    # Store if/elif/else block
    var logic: seq[Value]
    var elifs: seq[Value]

    var state = IsIf
    proc handler(input: Value) =
      case state:
      of IsIf:
        if input == nil:
          not_allowed("if: missing condition")
        elif input == "not".to_symbol_value():
          state = IsIfNot
        else:
          self.props["cond".to_key()] = input
          state = IsIfCond
      of IsIfNot:
        let g = new_gene("not".to_symbol_value())
        g.children.add(input)
        self.props["cond".to_key()] = g.to_gene_value()
        state = IsIfCond
      of IsIfCond:
        state = IsIfLogic
        logic = @[]
        if input == nil:
          not_allowed("if: missing body after condition")
        elif input == "else".to_symbol_value():
          state = IsElse
          logic = @[]
        elif input != "then".to_symbol_value():
          logic.add(input)
      of IsIfLogic:
        if input == nil:
          self.props["then".to_key()] = new_stream_value(logic)
        elif input == "elif".to_symbol_value():
          self.props["then".to_key()] = new_stream_value(logic)
          state = IsElif
        elif input == "else".to_symbol_value():
          self.props["then".to_key()] = new_stream_value(logic)
          state = IsElse
          logic = @[]
        else:
          logic.add(input)
      of IsElif:
        if input == nil:
          not_allowed("elif: missing condition")
        elif input == "not".to_symbol_value():
          state = IsElifNot
        else:
          elifs.add(input)
          state = IsElifCond
      of IsElifNot:
        let g = new_gene("not".to_symbol_value())
        g.children.add(input)
        elifs.add(g.to_gene_value())
        state = IsElifCond
      of IsElifCond:
        state = IsElifLogic
        logic = @[]
        if input == nil:
          not_allowed("elif: missing body after condition")
        elif input != "then".to_symbol_value():
          logic.add(input)
      of IsElifLogic:
        if input == nil:
          elifs.add(new_stream_value(logic))
          self.props["elif".to_key()] = new_array_value(elifs)
        elif input == "elif".to_symbol_value():
          elifs.add(new_stream_value(logic))
          self.props["elif".to_key()] = new_array_value(elifs)
          state = IsElif
        elif input == "else".to_symbol_value():
          elifs.add(new_stream_value(logic))
          self.props["elif".to_key()] = new_array_value(elifs)
          state = IsElse
          logic = @[]
        else:
          logic.add(input)
      of IsElse:
        if input == nil:
          self.props["else".to_key()] = new_stream_value(logic)
        else:
          logic.add(input)

    for item in self.children:
      handler(item)
    handler(nil)

    # Add empty blocks when they are missing
    if not self.props.has_key("then".to_key()):
      self.props["then".to_key()] = new_stream_value()
    if not self.props.has_key("else".to_key()):
      self.props["else".to_key()] = new_stream_value()

    if self.props["then".to_key()].ref.stream.len == 0:
      self.props["then".to_key()].ref.stream.add(NIL)
    if self.props["else".to_key()].ref.stream.len == 0:
      self.props["else".to_key()].ref.stream.add(NIL)

    self.children.reset  # Clear our gene_children as it's not needed any more

proc normalize_ifel*(self: ptr Gene) =
  ## Normalize (ifel cond then_expr [else_expr]) into the same props format as if.
  ## Unlike `if`, this form accepts exactly one or two branch expressions.
  if self.props.has_key("cond".to_key()):
    return
  if self.type != "ifel".to_symbol_value():
    return

  case self.children.len
  of 0:
    not_allowed("ifel: missing condition")
  of 1:
    not_allowed("ifel: missing body after condition")
  of 2, 3:
    discard
  else:
    not_allowed("ifel: expected condition, then expression, and optional else expression")

  self.props["cond".to_key()] = self.children[0]
  self.props["then".to_key()] = new_stream_value(@[self.children[1]])
  if self.children.len == 3:
    self.props["else".to_key()] = new_stream_value(@[self.children[2]])
  else:
    self.props["else".to_key()] = new_stream_value(@[NIL])

  self.children.reset

proc normalize_if_not*(self: ptr Gene) =
  ## Normalize (if_not cond body...) into the same props format as if,
  ## wrapping the condition with (not ...).
  ## No elif or else branches are supported.
  if self.props.has_key("cond".to_key()):
    return

  type IfNotState = enum
    Cond, CondDone, Body

  var state = Cond
  var body: seq[Value]

  proc handler(input: Value) =
    case state:
    of Cond:
      if input == nil:
        not_allowed("if_not: missing condition")
      else:
        # Wrap condition with (not ...)
        let g = new_gene("not".to_symbol_value())
        g.children.add(input)
        self.props["cond".to_key()] = g.to_gene_value()
        state = CondDone
    of CondDone:
      state = Body
      body = @[]
      if input == nil:
        not_allowed("if_not: missing body after condition")
      elif input == "elif".to_symbol_value() or input == "elif_not".to_symbol_value():
        not_allowed("if_not: elif branches are not supported; use if ... elif ... or nest if_not")
      elif input == "else".to_symbol_value():
        not_allowed("if_not: else branches are not supported; use if ... else ... or nest if_not")
      elif input != "then".to_symbol_value():
        body.add(input)
    of Body:
      if input == nil:
        discard
      elif input == "elif".to_symbol_value() or input == "elif_not".to_symbol_value():
        not_allowed("if_not: elif branches are not supported; use if ... elif ... or nest if_not")
      elif input == "else".to_symbol_value():
        not_allowed("if_not: else branches are not supported; use if ... else ... or nest if_not")
      else:
        body.add(input)

  for item in self.children:
    handler(item)
  handler(nil)

  self.props["then".to_key()] = new_stream_value(body)
  self.props["else".to_key()] = new_stream_value()

  if self.props["then".to_key()].ref.stream.len == 0:
    self.props["then".to_key()].ref.stream.add(NIL)
  if self.props["else".to_key()].ref.stream.len == 0:
    self.props["else".to_key()].ref.stream.add(NIL)

  self.children.reset

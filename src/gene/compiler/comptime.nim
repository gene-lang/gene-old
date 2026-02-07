## Compile-time evaluation for (comptime ...) blocks.
## Expands comptime expressions during compilation, before code generation.

import tables, os, strutils

import ../types
from "../compiler/if" import normalize_if

type
  # Lightweight compile-time evaluator used to expand (comptime ...) blocks.
  ComptimeEnv* = object
    vars*: Table[string, Value]

  ComptimeResult* = object
    value*: Value
    emitted*: seq[Value]

proc merge_emitted(dest: var seq[Value], src: seq[Value]) {.inline.} =
  if src.len > 0:
    dest.add(src)

proc new_comptime_env*(): ComptimeEnv =
  ComptimeEnv(vars: initTable[string, Value]())

proc is_comptime_node*(v: Value): bool =
  if v.kind != VkGene or v.gene == nil:
    return false
  let gt = v.gene.`type`
  gt.kind == VkSymbol and gt.str == "comptime"

proc is_module_def_node*(v: Value): bool =
  if v.kind != VkGene or v.gene == nil:
    return false
  let gt = v.gene.`type`
  if gt.kind != VkSymbol:
    return false
  case gt.str:
  of "fn", "class", "ns", "enum", "type", "object", "import", "interface", "comptime":
    return true
  else:
    return false

proc eval_comptime_expr(expr: Value, env: var ComptimeEnv): ComptimeResult

proc eval_comptime_stream(stream_val: Value, env: var ComptimeEnv): ComptimeResult =
  result.value = NIL
  case stream_val.kind
  of VkStream:
    for item in stream_val.ref.stream:
      let r = eval_comptime_expr(item, env)
      merge_emitted(result.emitted, r.emitted)
      result.value = r.value
  else:
    result = eval_comptime_expr(stream_val, env)

proc comptime_add(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) + to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) + to_float(b)).to_value()
  not_allowed("comptime: + expects numbers")

proc comptime_sub(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) - to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) - to_float(b)).to_value()
  not_allowed("comptime: - expects numbers")

proc comptime_mul(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) * to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) * to_float(b)).to_value()
  not_allowed("comptime: * expects numbers")

proc comptime_div(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a).float64 / to_int(b).float64).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) / to_float(b)).to_value()
  not_allowed("comptime: / expects numbers")

proc comptime_concat(a, b: Value): Value =
  if a.kind == VkString and b.kind == VkString:
    return new_str_value(a.str & b.str)
  not_allowed("comptime: ++ expects two strings")

proc comptime_compare(op: string, a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    let ai = to_int(a)
    let bi = to_int(b)
    case op
    of "<": return (ai < bi).to_value()
    of "<=": return (ai <= bi).to_value()
    of ">": return (ai > bi).to_value()
    of ">=": return (ai >= bi).to_value()
    else: discard
  if is_float(a) or is_float(b):
    let af = to_float(a)
    let bf = to_float(b)
    case op
    of "<": return (af < bf).to_value()
    of "<=": return (af <= bf).to_value()
    of ">": return (af > bf).to_value()
    of ">=": return (af >= bf).to_value()
    else: discard
  if a.kind == VkString and b.kind == VkString:
    case op
    of "<": return (a.str < b.str).to_value()
    of "<=": return (a.str <= b.str).to_value()
    of ">": return (a.str > b.str).to_value()
    of ">=": return (a.str >= b.str).to_value()
    else: discard
  not_allowed("comptime: comparison expects numbers or strings")

proc eval_comptime_operator(op: string, args: seq[Value], env: var ComptimeEnv): ComptimeResult =
  case op
  of "=":
    if args.len != 2:
      not_allowed("comptime: = expects exactly 2 arguments")
    if args[0].kind != VkSymbol:
      not_allowed("comptime: assignment expects a symbol on the left")
    let r = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, r.emitted)
    env.vars[args[0].str] = r.value
    result.value = r.value
    return
  of "+=", "-=":
    if args.len != 2 or args[0].kind != VkSymbol:
      not_allowed("comptime: compound assignment expects a symbol and a value")
    let current =
      if env.vars.hasKey(args[0].str): env.vars[args[0].str]
      else: NIL
    let rhs = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, rhs.emitted)
    let new_val =
      if op == "+=": comptime_add(current, rhs.value)
      else: comptime_sub(current, rhs.value)
    env.vars[args[0].str] = new_val
    result.value = new_val
    return
  of "&&", "||":
    if args.len != 2:
      not_allowed("comptime: logical operator expects 2 arguments")
    let left = eval_comptime_expr(args[0], env)
    merge_emitted(result.emitted, left.emitted)
    if op == "&&":
      if not to_bool(left.value):
        result.value = FALSE
        return
    else:
      if to_bool(left.value):
        result.value = TRUE
        return
    let right = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, right.emitted)
    result.value = (right.value != FALSE and right.value != NIL).to_value()
    return
  else:
    discard

  if args.len == 0:
    not_allowed("comptime: operator expects arguments")

  # Evaluate arguments before applying operator
  var values: seq[Value] = @[]
  for arg in args:
    let r = eval_comptime_expr(arg, env)
    merge_emitted(result.emitted, r.emitted)
    values.add(r.value)

  case op
  of "+":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_add(acc, values[i])
    result.value = acc
  of "-":
    if values.len == 1:
      if is_small_int(values[0]):
        result.value = (-to_int(values[0])).to_value()
      elif is_float(values[0]):
        result.value = (-to_float(values[0])).to_value()
      else:
        not_allowed("comptime: unary - expects number")
    else:
      var acc = values[0]
      for i in 1..<values.len:
        acc = comptime_sub(acc, values[i])
      result.value = acc
  of "*":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_mul(acc, values[i])
    result.value = acc
  of "/":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_div(acc, values[i])
    result.value = acc
  of "++":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_concat(acc, values[i])
    result.value = acc
  of "==":
    if values.len != 2:
      not_allowed("comptime: == expects exactly 2 arguments")
    result.value = (values[0] == values[1]).to_value()
  of "!=":
    if values.len != 2:
      not_allowed("comptime: != expects exactly 2 arguments")
    result.value = (values[0] != values[1]).to_value()
  of "<", "<=", ">", ">=":
    if values.len != 2:
      not_allowed("comptime: comparison expects exactly 2 arguments")
    result.value = comptime_compare(op, values[0], values[1])
  else:
    not_allowed("comptime: unsupported operator " & op)

proc eval_comptime_var(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  if gene.children.len == 0:
    result.value = NIL
    return
  var name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    not_allowed("comptime: var expects a symbol name")
  var name = name_val.str
  var value_index = 1
  if name.endsWith(":"):
    name = name[0..^2]
    if gene.children.len > 1:
      value_index = 2
  if gene.children.len > value_index:
    let r = eval_comptime_expr(gene.children[value_index], env)
    merge_emitted(result.emitted, r.emitted)
    env.vars[name] = r.value
    result.value = r.value
  else:
    env.vars[name] = NIL
    result.value = NIL

proc eval_comptime_if(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  normalize_if(gene)
  let cond_val = gene.props.get_or_default("cond".to_key(), NIL)
  let cond_res = eval_comptime_expr(cond_val, env)
  merge_emitted(result.emitted, cond_res.emitted)

  if cond_res.value:
    let then_stream = gene.props.get_or_default("then".to_key(), NIL)
    let then_res = eval_comptime_stream(then_stream, env)
    merge_emitted(result.emitted, then_res.emitted)
    result.value = then_res.value
    return

  if gene.props.hasKey("elif".to_key()):
    let elifs = array_data(gene.props["elif".to_key()])
    var i = 0
    while i + 1 < elifs.len:
      let elif_cond = eval_comptime_expr(elifs[i], env)
      merge_emitted(result.emitted, elif_cond.emitted)
      if elif_cond.value:
        let elif_body = eval_comptime_stream(elifs[i + 1], env)
        merge_emitted(result.emitted, elif_body.emitted)
        result.value = elif_body.value
        return
      i += 2

  let else_stream = gene.props.get_or_default("else".to_key(), NIL)
  let else_res = eval_comptime_stream(else_stream, env)
  merge_emitted(result.emitted, else_res.emitted)
  result.value = else_res.value

proc eval_comptime_env_call(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  if gene.children.len == 0:
    not_allowed("comptime: $env/get_env expects at least 1 argument")
  let name_res = eval_comptime_expr(gene.children[0], env)
  merge_emitted(result.emitted, name_res.emitted)
  let name =
    if name_res.value.kind == VkString:
      name_res.value.str
    elif name_res.value.kind == VkSymbol:
      name_res.value.str
    else:
      not_allowed("comptime: $env/get_env expects a string or symbol")
      ""
  let value = getEnv(name, "")
  if value == "":
    if gene.children.len > 1:
      let default_res = eval_comptime_expr(gene.children[1], env)
      merge_emitted(result.emitted, default_res.emitted)
      result.value = default_res.value
    else:
      result.value = NIL
  else:
    result.value = value.to_value()

proc eval_comptime_expr(expr: Value, env: var ComptimeEnv): ComptimeResult =
  case expr.kind
  of VkNil, VkVoid, VkBool, VkInt, VkFloat, VkChar, VkBytes, VkString, VkRegex, VkRange:
    result.value = expr
  of VkSymbol:
    if env.vars.hasKey(expr.str):
      result.value = env.vars[expr.str]
    else:
      not_allowed("comptime: unknown variable " & expr.str)
  of VkComplexSymbol:
    result.value = expr
  of VkQuote:
    result.value = expr.ref.quote
  of VkUnquote:
    if expr.ref.unquote_discard:
      let r = eval_comptime_expr(expr.ref.unquote, env)
      merge_emitted(result.emitted, r.emitted)
      result.value = NIL
    else:
      result = eval_comptime_expr(expr.ref.unquote, env)
  of VkArray:
    let out_val = new_array_value()
    for item in array_data(expr):
      let r = eval_comptime_expr(item, env)
      merge_emitted(result.emitted, r.emitted)
      array_data(out_val).add(r.value)
    result.value = out_val
  of VkMap:
    let out_val = new_map_value()
    for k, v in map_data(expr):
      let r = eval_comptime_expr(v, env)
      merge_emitted(result.emitted, r.emitted)
      map_data(out_val)[k] = r.value
    result.value = out_val
  of VkGene:
    let gene = expr.gene
    if gene == nil:
      result.value = NIL
      return

    # Infix notation: (x + y) => type=x, children=[+, y]
    if gene.children.len >= 1 and gene.children[0].kind == VkSymbol:
      let op = gene.children[0].str
      if op in ["+", "-", "*", "/", "%", "**", "./", "<", "<=", ">", ">=", "==", "!=", "&&", "||", "++", "=", "+=", "-="]:
        if gene.`type`.kind != VkSymbol or gene.`type`.str notin ["var", "if", "fn", "do", "loop", "while", "for", "ns", "class", "try", "throw", "import", "export", "interface", "comptime", "type", "object", "$", ".", "->", "@"]:
          let args = @[gene.`type`] & gene.children[1..^1]
          result = eval_comptime_operator(op, args, env)
          return

    if gene.`type`.kind == VkSymbol:
      case gene.`type`.str
      of "var":
        result = eval_comptime_var(gene, env)
        return
      of "do":
        if gene.children.len == 0:
          result.value = NIL
          return
        var last: ComptimeResult
        for child in gene.children:
          let r = eval_comptime_expr(child, env)
          merge_emitted(result.emitted, r.emitted)
          last = r
        result.value = last.value
        return
      of "if":
        result = eval_comptime_if(gene, env)
        return
      of "not":
        if gene.children.len != 1:
          not_allowed("comptime: not expects exactly 1 argument")
        let r = eval_comptime_expr(gene.children[0], env)
        merge_emitted(result.emitted, r.emitted)
        result.value = (not to_bool(r.value)).to_value()
        return
      of "comptime":
        for child in gene.children:
          let r = eval_comptime_expr(child, env)
          merge_emitted(result.emitted, r.emitted)
        result.value = NIL
        return
      of "$env", "get_env":
        result = eval_comptime_env_call(gene, env)
        return
      of "+", "-", "*", "/", "++", "==", "!=", "<", "<=", ">", ">=", "&&", "||":
        result = eval_comptime_operator(gene.`type`.str, gene.children, env)
        return
      else:
        discard

    if is_module_def_node(expr) and gene.`type`.kind == VkSymbol and gene.`type`.str != "comptime":
      result.emitted.add(expr)
      result.value = NIL
      return

    not_allowed("comptime: unsupported expression")
  else:
    result.value = expr

proc eval_comptime_block*(node: Value, env: var ComptimeEnv): seq[Value] =
  if node.kind != VkGene or node.gene == nil:
    return @[]
  for child in node.gene.children:
    let r = eval_comptime_expr(child, env)
    merge_emitted(result, r.emitted)

proc expand_comptime_nodes*(nodes: seq[Value], env: var ComptimeEnv): seq[Value] =
  for node in nodes:
    if is_comptime_node(node):
      let emitted = eval_comptime_block(node, env)
      if emitted.len > 0:
        result.add(expand_comptime_nodes(emitted, env))
    else:
      result.add(node)

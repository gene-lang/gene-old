import algorithm, tables, strutils, os

import ./types
import ./gir

# Case expression keys (same as in compiler/case.nim)
const CASE_TARGET_KEY = "case_target"
const CASE_WHEN_KEY = "case_when"
const CASE_ELSE_KEY = "case_else"

# Simple static type checker for Gene AST.
# This is intentionally conservative: Any is treated as the top type.

type
  TypeKind* = enum
    TkAny,
    TkNamed,
    TkApplied,
    TkUnion,
    TkFn,
    TkVar

  ParamType* = object
    kind*: CallableParamKind
    keyword_name*: string
    typ*: TypeExpr

  ParameterDecl = object
    binding_name*: string
    kind*: CallableParamKind
    keyword_name*: string
    typ*: TypeExpr

  TypeExpr* = ref object
    case kind*: TypeKind
    of TkAny:
      discard
    of TkNamed:
      name*: string
    of TkApplied:
      ctor*: string
      args*: seq[TypeExpr]
    of TkUnion:
      members*: seq[TypeExpr]
    of TkFn:
      params*: seq[ParamType]
      ret*: TypeExpr
      receiver*: TypeExpr
      effects*: seq[string]
    of TkVar:
      id*: int

  ClassInfo* = ref object
    name*: string
    parent*: string
    fields*: Table[string, TypeExpr]
    methods*: Table[string, TypeExpr]
    ctor_type*: TypeExpr
    interfaces*: seq[string]

  InterfaceInfo* = ref object
    name*: string
    fields*: Table[string, TypeExpr]
    methods*: Table[string, TypeExpr]

  AdtVariant = object
    name*: string
    field_count*: int
    param_index*: int  # -1 when no param binding
    fields*: seq[string]
    field_types*: seq[TypeExpr]
    field_param_indices*: seq[int]

  AdtDef = ref object
    name*: string
    params*: seq[string]
    variants*: Table[string, AdtVariant]
    variant_order*: seq[string]

  AdtVariantCandidate = object
    adt*: AdtDef
    variant*: AdtVariant

  AdtPatternResolution = object
    matched*: bool
    adt*: AdtDef
    variant*: AdtVariant
    bindings*: seq[string]

  ImportTypeItem = object
    path: seq[string]
    alias: string

  TypeChecker* = ref object
    strict*: bool
    module_filename*: string
    module_path*: string
    next_var_id*: int
    subs*: Table[int, TypeExpr]
    scopes*: seq[Table[string, TypeExpr]]
    types*: Table[string, TypeExpr]
    adts*: Table[string, AdtDef]
    classes*: Table[string, ClassInfo]
    interfaces*: Table[string, InterfaceInfo]
    current_return*: TypeExpr
    current_class*: string
    init_self_stack*: seq[TypeExpr]
    effect_stack*: seq[seq[string]]
    type_param_scopes*: seq[Table[string, TypeExpr]]
    type_descs*: seq[TypeDesc]
    type_desc_index*: Table[string, TypeId]
    warnings*: seq[string]

let ANY_TYPE = TypeExpr(kind: TkAny)

proc array_type_of(elem: TypeExpr): TypeExpr {.inline.} =
  TypeExpr(kind: TkApplied, ctor: "Array", args: @[if elem == nil: ANY_TYPE else: elem])

proc rest_source_type(t: TypeExpr): TypeExpr {.inline.} =
  if t != nil and t.kind == TkApplied and t.ctor == "Array" and t.args.len > 0:
    return t.args[0]
  if t == nil:
    return ANY_TYPE
  t

const BUILTIN_TYPE_NAMES = [
  "Any", "Self", "Int", "Float", "Bool", "String", "Nil", "Void", "Symbol",
  "Array", "Map", "HashMap", "HashSet", "Result", "Option", "Tuple",
  "Module", "Namespace", "Class"
]

proc is_reserved_value_name(name: string): bool {.inline.} =
  name == "self"

proc is_reserved_type_name(name: string): bool {.inline.} =
  name == "Self"

proc ensure_user_value_name(name: string, context: string) =
  if is_reserved_value_name(name):
    raise new_exception(types.Exception, "Reserved identifier '" & name & "' cannot be used for " & context)

proc ensure_user_type_name(name: string, context: string) =
  if is_reserved_type_name(name):
    raise new_exception(types.Exception, "Reserved type name '" & name & "' cannot be used for " & context)

proc effective_type(t: TypeExpr): TypeExpr {.inline.} =
  if t == nil: ANY_TYPE else: t

proc map_value_type_of(value_type: TypeExpr): TypeExpr {.inline.} =
  TypeExpr(kind: TkApplied, ctor: "Map", args: @[ANY_TYPE, effective_type(value_type)])

proc param_binding_type(param: ParameterDecl): TypeExpr {.inline.} =
  case param.kind
  of CpkPositional, CpkKeyword:
    effective_type(param.typ)
  of CpkPositionalRest:
    array_type_of(param.typ)
  of CpkKeywordRest:
    map_value_type_of(param.typ)

proc public_param(param: ParameterDecl): ParamType {.inline.} =
  ParamType(
    kind: param.kind,
    keyword_name: if param.kind == CpkKeyword: param.keyword_name else: "",
    typ: effective_type(param.typ)
  )

proc positional_rest_source_type(t: TypeExpr): TypeExpr {.inline.} =
  if t == nil:
    return ANY_TYPE
  t

proc is_builtin_type_name(name: string): bool {.inline.} =
  for n in BUILTIN_TYPE_NAMES:
    if n == name:
      return true
  return false

proc is_known_type_name(self: TypeChecker, name: string): bool {.inline.} =
  if is_builtin_type_name(name):
    return true
  if self.types.hasKey(name):
    return true
  if self.classes.hasKey(name):
    return true
  if self.interfaces.hasKey(name):
    return true
  return false

proc key_to_string(key: Key): string {.inline.} =
  try:
    result = cast[Value](key).str
  except CatchableError:
    result = "<keyword>"

proc effects_to_string(effects: seq[string]): string =
  if effects.len == 0:
    return "[]"
  "[" & effects.join(" ") & "]"

proc effects_compatible(expected: seq[string], actual: seq[string]): bool =
  if expected.len == 0:
    return actual.len == 0
  if actual.len == 0:
    return true
  for eff in actual:
    var found = false
    for allowed in expected:
      if allowed == eff:
        found = true
        break
    if not found:
      return false
  return true

proc ensure_effects_allowed(self: TypeChecker, required: seq[string], context: string) =
  if required.len == 0:
    return
  if self.effect_stack.len == 0:
    return
  let allowed = self.effect_stack[^1]
  for eff in required:
    var ok = false
    for allow in allowed:
      if allow == eff:
        ok = true
        break
    if not ok:
      raise new_exception(types.Exception, "Effect error: " & eff & " not allowed in " & context)

proc register_builtin_adts(self: TypeChecker)

proc new_type_checker*(strict: bool = true, module_filename: string = ""): TypeChecker =
  result = TypeChecker(
    strict: strict,
    module_filename: module_filename,
    module_path: module_path_from_source(module_filename),
    next_var_id: 0,
    subs: initTable[int, TypeExpr](),
    scopes: @[initTable[string, TypeExpr]()],
    types: initTable[string, TypeExpr](),
    adts: initTable[string, AdtDef](),
    classes: initTable[string, ClassInfo](),
    interfaces: initTable[string, InterfaceInfo](),
    current_return: ANY_TYPE,
    current_class: "",
    init_self_stack: @[],
    effect_stack: @[],
    type_param_scopes: @[],
    type_descs: builtin_type_descs(),
    type_desc_index: initTable[string, TypeId](),
    warnings: @[]
  )
  ensure_type_desc_index(result.type_descs, result.type_desc_index)
  result.register_builtin_adts()

proc type_descriptors*(self: TypeChecker): seq[TypeDesc] =
  if self == nil:
    return @[]
  result = self.type_descs

proc warn(self: TypeChecker, msg: string) =
  ## In strict mode, raise an error. In gradual mode, record a warning.
  if self.strict:
    raise new_exception(types.Exception, msg)
  self.warnings.add(msg)

proc flush_warnings*(self: TypeChecker): seq[string] =
  ## Return and clear accumulated warnings.
  result = self.warnings
  self.warnings = @[]

proc add_adt(self: TypeChecker, name: string, params: seq[string], variants: seq[AdtVariant]) =
  var def = AdtDef(
    name: name,
    params: params,
    variants: initTable[string, AdtVariant](),
    variant_order: @[]
  )
  for variant in variants:
    def.variants[variant.name] = variant
    def.variant_order.add(variant.name)
  self.adts[name] = def
  if not self.types.hasKey(name):
    self.types[name] = TypeExpr(kind: TkNamed, name: name)

proc register_builtin_adts(self: TypeChecker) =
  let result_t = TypeExpr(kind: TkNamed, name: "T")
  let result_e = TypeExpr(kind: TkNamed, name: "E")
  let option_t = TypeExpr(kind: TkNamed, name: "T")
  self.add_adt("Result", @["T", "E"], @[
    AdtVariant(name: "Ok", field_count: 1, param_index: 0, fields: @["value"], field_types: @[result_t], field_param_indices: @[0]),
    AdtVariant(name: "Err", field_count: 1, param_index: 1, fields: @["error"], field_types: @[result_e], field_param_indices: @[1])
  ])
  self.add_adt("Option", @["T"], @[
    AdtVariant(name: "Some", field_count: 1, param_index: 0, fields: @["value"], field_types: @[option_t], field_param_indices: @[0]),
    AdtVariant(name: "None", field_count: 0, param_index: -1, fields: @[], field_types: @[], field_param_indices: @[])
  ])

proc fresh_var(self: TypeChecker): TypeExpr =
  let id = self.next_var_id
  self.next_var_id.inc
  result = TypeExpr(kind: TkVar, id: id)

proc resolve(self: TypeChecker, t: TypeExpr): TypeExpr
proc resolve_self(self: TypeChecker, t: TypeExpr): TypeExpr

proc lookup_type_param(self: TypeChecker, name: string): TypeExpr =
  if self == nil or name.len == 0 or self.type_param_scopes.len == 0:
    return nil
  for i in countdown(self.type_param_scopes.len - 1, 0):
    if self.type_param_scopes[i].hasKey(name):
      return self.type_param_scopes[i][name]
  nil

proc push_type_param_scope(self: TypeChecker, params: seq[string]) =
  var scope = initTable[string, TypeExpr]()
  for name in params:
    ensure_user_type_name(name, "type parameter")
    if scope.hasKey(name):
      raise new_exception(types.Exception, "Duplicate type parameter: " & name)
    scope[name] = self.fresh_var()
  self.type_param_scopes.add(scope)

proc pop_type_param_scope(self: TypeChecker) =
  if self == nil or self.type_param_scopes.len == 0:
    return
  discard self.type_param_scopes.pop()

proc instantiate_type_vars(self: TypeChecker, t: TypeExpr): TypeExpr =
  var replacements = initTable[int, TypeExpr]()

  proc clone(node: TypeExpr): TypeExpr =
    let rt = self.resolve_self(self.resolve(node))
    if rt == nil:
      return nil
    case rt.kind
    of TkAny:
      ANY_TYPE
    of TkNamed:
      TypeExpr(kind: TkNamed, name: rt.name)
    of TkApplied:
      var args: seq[TypeExpr] = @[]
      for arg in rt.args:
        args.add(clone(arg))
      TypeExpr(kind: TkApplied, ctor: rt.ctor, args: args)
    of TkUnion:
      var members: seq[TypeExpr] = @[]
      for member in rt.members:
        members.add(clone(member))
      TypeExpr(kind: TkUnion, members: members)
    of TkFn:
      var params: seq[ParamType] = @[]
      for param in rt.params:
        params.add(ParamType(kind: param.kind, keyword_name: param.keyword_name, typ: clone(param.typ)))
      TypeExpr(
        kind: TkFn,
        params: params,
        ret: clone(rt.ret),
        receiver: clone(rt.receiver),
        effects: rt.effects
      )
    of TkVar:
      if replacements.hasKey(rt.id):
        return replacements[rt.id]
      let fresh = self.fresh_var()
      replacements[rt.id] = fresh
      fresh

  clone(t)

proc resolve(self: TypeChecker, t: TypeExpr): TypeExpr =
  if t == nil:
    return ANY_TYPE
  if t.kind == TkVar and self.subs.hasKey(t.id):
    return self.resolve(self.subs[t.id])
  result = t

proc type_to_string(t: TypeExpr): string

proc occurs(self: TypeChecker, id: int, t: TypeExpr): bool =
  let rt = self.resolve(t)
  case rt.kind
  of TkVar:
    return rt.id == id
  of TkApplied:
    for a in rt.args:
      if self.occurs(id, a):
        return true
  of TkUnion:
    for m in rt.members:
      if self.occurs(id, m):
        return true
  of TkFn:
    for p in rt.params:
      if self.occurs(id, p.typ):
        return true
    if self.occurs(id, rt.ret):
      return true
    if rt.receiver != nil and self.occurs(id, rt.receiver):
      return true
  else:
    discard
  return false

proc unify(self: TypeChecker, a: TypeExpr, b: TypeExpr, context: string) =
  let ta = self.resolve(a)
  let tb = self.resolve(b)
  if ta == tb:
    return
  if ta.kind == TkAny or tb.kind == TkAny:
    return
  if ta.kind == TkVar:
    if self.occurs(ta.id, tb):
      raise new_exception(types.Exception, "Type error: recursive type in " & context)
    self.subs[ta.id] = tb
    return
  if tb.kind == TkVar:
    if self.occurs(tb.id, ta):
      raise new_exception(types.Exception, "Type error: recursive type in " & context)
    self.subs[tb.id] = ta
    return
  if ta.kind == TkUnion or tb.kind == TkUnion:
    if ta.kind == TkUnion and tb.kind == TkUnion:
      # Union to union: each member of tb must be in ta
      for mb in tb.members:
        var found = false
        for ma in ta.members:
          try:
            self.unify(ma, mb, context)
            found = true
            break
          except CatchableError:
            discard
        if not found:
          raise new_exception(types.Exception, "Type error: expected one of " & type_to_string(ta) & ", got " & type_to_string(tb) & " in " & context)
      return
    if ta.kind == TkUnion:
      # Non-union to union: tb must match at least one member
      var ok = false
      for m in ta.members:
        try:
          self.unify(m, tb, context)
          ok = true
          break
        except CatchableError:
          discard
      if not ok:
        raise new_exception(types.Exception, "Type error: expected one of " & type_to_string(ta) & ", got " & type_to_string(tb) & " in " & context)
      return
    # ta is non-union, tb is union: ta must match at least one member
    var ok = false
    for m in tb.members:
      try:
        self.unify(ta, m, context)
        ok = true
        break
      except CatchableError:
        discard
    if not ok:
      raise new_exception(types.Exception, "Type error: expected one of " & type_to_string(tb) & ", got " & type_to_string(ta) & " in " & context)
    return
  if ta.kind != tb.kind:
    raise new_exception(types.Exception, "Type error: expected " & type_to_string(ta) & ", got " & type_to_string(tb) & " in " & context)
  case ta.kind
  of TkNamed:
    if ta.name != tb.name:
      # For user-defined class types, allow subtype relationships at compile-time
      # (actual validation happens at runtime with inheritance check)
      # Only fail for built-in type mismatches
      if is_builtin_type_name(ta.name) and is_builtin_type_name(tb.name):
        raise new_exception(types.Exception, "Type error: expected " & ta.name & ", got " & tb.name & " in " & context)
      # For user-defined classes, defer to runtime type checking (gradual typing)
  of TkApplied:
    if ta.ctor != tb.ctor or ta.args.len != tb.args.len:
      raise new_exception(types.Exception, "Type error: expected " & type_to_string(ta) & ", got " & type_to_string(tb) & " in " & context)
    for i in 0..<ta.args.len:
      self.unify(ta.args[i], tb.args[i], context)
  of TkUnion:
    discard
  of TkFn:
    if ta.params.len != tb.params.len:
      raise new_exception(types.Exception, "Type error: function arity mismatch in " & context)
    for i in 0..<ta.params.len:
      if ta.params[i].kind != tb.params[i].kind:
        raise new_exception(types.Exception, "Type error: function parameter kind mismatch in " & context)
      if ta.params[i].keyword_name != tb.params[i].keyword_name:
        raise new_exception(types.Exception, "Type error: function keyword parameter mismatch in " & context)
      self.unify(ta.params[i].typ, tb.params[i].typ, context)
    self.unify(ta.ret, tb.ret, context)
    if ta.receiver != nil and tb.receiver != nil:
      self.unify(ta.receiver, tb.receiver, context)
    if not effects_compatible(ta.effects, tb.effects):
      raise new_exception(types.Exception, "Type error: effect mismatch (expected " & effects_to_string(ta.effects) & ", got " & effects_to_string(tb.effects) & ") in " & context)
  of TkAny, TkVar:
    discard

proc type_to_string(t: TypeExpr): string =
  if t == nil:
    return "Any"
  let rt = t
  case rt.kind
  of TkAny:
    return "Any"
  of TkNamed:
    return rt.name
  of TkApplied:
    var parts: seq[string] = @[rt.ctor]
    for a in rt.args:
      parts.add(type_to_string(a))
    return "(" & parts.join(" ") & ")"
  of TkUnion:
    var parts: seq[string] = @[]
    for m in rt.members:
      parts.add(type_to_string(m))
    return "(" & parts.join(" | ") & ")"
  of TkFn:
    var params: seq[string] = @[]
    for p in rt.params:
      let printed_type =
        if p.kind == CpkPositionalRest: positional_rest_source_type(p.typ)
        else: p.typ
      case p.kind
      of CpkPositional:
        params.add(type_to_string(printed_type))
      of CpkPositionalRest:
        params.add(type_to_string(printed_type) & " ...")
      of CpkKeyword:
        params.add("^" & p.keyword_name & " " & type_to_string(printed_type))
      of CpkKeywordRest:
        params.add("^... " & type_to_string(printed_type))
    var effects = ""
    if rt.effects.len > 0:
      effects = " ! [" & rt.effects.join(" ") & "]"
    let args =
      if params.len > 0: " [" & params.join(" ") & "]"
      else: ""
    return "(Fn" & args & " -> " & type_to_string(rt.ret) & effects & ")"
  of TkVar:
    return "T" & $rt.id

proc intern_type_desc(self: TypeChecker, t: TypeExpr): TypeId =
  if t == nil:
    return NO_TYPE_ID
  let rt = self.resolve_self(self.resolve(t))
  case rt.kind
  of TkAny:
    return BUILTIN_TYPE_ANY_ID
  of TkNamed:
    let builtin_id = lookup_builtin_type(rt.name)
    if builtin_id != NO_TYPE_ID:
      return builtin_id
    return intern_type_desc(self.type_descs,
      TypeDesc(module_path: self.module_path, kind: TdkNamed, name: rt.name), self.type_desc_index)
  of TkApplied:
    var args: seq[TypeId] = @[]
    for arg in rt.args:
      args.add(self.intern_type_desc(arg))
    return intern_type_desc(self.type_descs,
      TypeDesc(module_path: self.module_path, kind: TdkApplied, ctor: rt.ctor, args: args), self.type_desc_index)
  of TkUnion:
    var members: seq[TypeId] = @[]
    for member in rt.members:
      members.add(self.intern_type_desc(member))
    return intern_type_desc(self.type_descs,
      TypeDesc(module_path: self.module_path, kind: TdkUnion, members: members), self.type_desc_index)
  of TkFn:
    var params: seq[CallableParamDesc] = @[]
    for param in rt.params:
      params.add(CallableParamDesc(
        kind: param.kind,
        keyword_name: param.keyword_name,
        type_id: self.intern_type_desc(param.typ)
      ))
    return intern_type_desc(self.type_descs, TypeDesc(
      module_path: self.module_path,
      kind: TdkFn,
      params: params,
      ret: self.intern_type_desc(rt.ret),
      effects: rt.effects
    ), self.type_desc_index)
  of TkVar:
    return intern_type_desc(self.type_descs,
      TypeDesc(module_path: self.module_path, kind: TdkVar, var_id: rt.id.int32), self.type_desc_index)

proc push_scope(self: TypeChecker) =
  self.scopes.add(initTable[string, TypeExpr]())

proc pop_scope(self: TypeChecker) =
  if self.scopes.len > 1:
    discard self.scopes.pop()

proc define_internal(self: TypeChecker, name: string, t: TypeExpr) =
  if name.len == 0 or name == "_":
    return
  self.scopes[^1][name] = t

proc define(self: TypeChecker, name: string, t: TypeExpr) =
  if name.len == 0 or name == "_":
    return
  self.define_internal(name, t)

proc lookup(self: TypeChecker, name: string): TypeExpr =
  for i in countdown(self.scopes.len - 1, 0):
    if self.scopes[i].hasKey(name):
      return self.scopes[i][name]
  return nil

proc current_init_self(self: TypeChecker): TypeExpr =
  if self.init_self_stack.len > 0:
    return self.init_self_stack[^1]
  return nil

proc get_class_info(self: TypeChecker, name: string): ClassInfo =
  if self.classes.hasKey(name):
    return self.classes[name]
  return nil

proc get_interface_info(self: TypeChecker, name: string): InterfaceInfo =
  if self.interfaces.hasKey(name):
    return self.interfaces[name]
  return nil

proc find_method(self: TypeChecker, cls: ClassInfo, method_name: string): TypeExpr =
  var current = cls
  var visited = initTable[string, bool]()
  while current != nil:
    if visited.hasKey(current.name):
      break
    visited[current.name] = true
    if current.methods.hasKey(method_name):
      return current.methods[method_name]
    if current.parent.len == 0:
      break
    current = self.get_class_info(current.parent)
  return nil

proc find_field(self: TypeChecker, cls: ClassInfo, field_name: string): TypeExpr =
  var current = cls
  var visited = initTable[string, bool]()
  while current != nil:
    if visited.hasKey(current.name):
      break
    visited[current.name] = true
    if current.fields.hasKey(field_name):
      return current.fields[field_name]
    if current.parent.len == 0:
      break
    current = self.get_class_info(current.parent)
  return nil

proc parse_type_expr(self: TypeChecker, v: Value): TypeExpr
proc check_expr(self: TypeChecker, v: Value): TypeExpr

proc signature_compatible(self: TypeChecker, actual: TypeExpr, expected: TypeExpr): bool =
  if actual == nil or expected == nil:
    return false
  try:
    self.unify(self.instantiate_type_vars(actual), self.instantiate_type_vars(expected), "interface conformance")
    return true
  except CatchableError:
    return false

proc parse_interface_list(self: TypeChecker, value: Value): seq[string] =
  case value.kind
  of VkSymbol:
    ensure_user_type_name(value.str, "interface name")
    result.add(value.str)
  of VkArray:
    for item in array_data(value):
      if item.kind != VkSymbol:
        raise new_exception(types.Exception, "implements expects interface symbols")
      ensure_user_type_name(item.str, "interface name")
      result.add(item.str)
  else:
    raise new_exception(types.Exception, "implements expects an interface symbol or array of interface symbols")

proc parse_class_header(self: TypeChecker, gene: ptr Gene): tuple[parent_name: string, interfaces: seq[string], body_start: int] =
  result.body_start = 1
  while result.body_start < gene.children.len:
    let child = gene.children[result.body_start]
    if child.kind == VkSymbol and child.str == "<":
      if result.body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing superclass after <")
      let parent_val = gene.children[result.body_start + 1]
      if parent_val.kind != VkSymbol:
        raise new_exception(types.Exception, "Invalid superclass")
      result.parent_name = parent_val.str
      discard self.parse_type_expr(parent_val)
      result.body_start += 2
      continue
    if child.kind == VkSymbol and child.str == "implements":
      if result.body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing interface list after implements")
      for name in self.parse_interface_list(gene.children[result.body_start + 1]):
        result.interfaces.add(name)
      result.body_start += 2
      continue
    break

proc check_interface_conformance(self: TypeChecker, cls: ClassInfo, interface_name: string) =
  let iface = self.get_interface_info(interface_name)
  if iface == nil:
    raise new_exception(types.Exception, "Unknown interface: " & interface_name)

  for field_name, field_type in iface.fields:
    let actual = self.find_field(cls, field_name)
    if actual == nil:
      raise new_exception(types.Exception, "Type error: class " & cls.name & " does not implement field " & field_name & " required by interface " & interface_name)
    if not self.signature_compatible(actual, field_type):
      raise new_exception(types.Exception, "Type error: field " & field_name & " on " & cls.name & " is incompatible with interface " & interface_name)

  for method_name, method_type in iface.methods:
    let actual = self.find_method(cls, method_name)
    if actual == nil:
      raise new_exception(types.Exception, "Type error: class " & cls.name & " does not implement method " & method_name & " required by interface " & interface_name)
    if not self.signature_compatible(actual, method_type):
      raise new_exception(types.Exception, "Type error: method " & method_name & " on " & cls.name & " is incompatible with interface " & interface_name)

proc register_imported_type(self: TypeChecker, name: string, force: bool = false) =
  if name.len == 0:
    return
  if name.contains("/") or name.contains("."):
    return
  if force or name[0].isUpperAscii:
    if not self.types.hasKey(name) and not self.classes.hasKey(name):
      self.types[name] = TypeExpr(kind: TkNamed, name: name)

proc collect_import_types(self: TypeChecker, v: Value) =
  case v.kind
  of VkSymbol:
    self.register_imported_type(v.str)
  of VkComplexSymbol:
    let parts = v.ref.csymbol
    if parts.len > 0:
      self.register_imported_type(parts[^1])
  of VkArray:
    for item in array_data(v):
      self.collect_import_types(item)
  of VkGene:
    if v.gene != nil:
      self.collect_import_types(v.gene.`type`)
      for child in v.gene.children:
        self.collect_import_types(child)
  else:
    discard

proc normalize_import_path(parts: seq[string]): seq[string] =
  for part in parts:
    if part.len == 0 or part == "$ns":
      continue
    result.add(part)

proc split_import_path(path: string): seq[string] =
  if path == "*":
    return @["*"]
  if path.contains("/"):
    return normalize_import_path(path.split("/"))
  if path.len > 0 and path != "$ns":
    return @[path]
  return @[]

proc add_import_type_item(items: var seq[ImportTypeItem], name: string, alias: string = "") =
  if name.len == 0:
    return
  let path = split_import_path(name)
  if path.len == 0:
    return
  items.add(ImportTypeItem(path: path, alias: alias))

proc parse_import_symbol(items: var seq[ImportTypeItem], token: string, prefix: string = "") =
  if token.len == 0:
    return

  var name = token
  var alias = ""
  let colon_pos = token.find(':')
  if colon_pos > 0 and colon_pos < token.len - 1:
    name = token[0..<colon_pos]
    alias = token[colon_pos + 1..^1]

  var full_name = name
  if prefix.len > 0 and name != "*":
    full_name = prefix & "/" & name
  add_import_type_item(items, full_name, alias)

proc parse_import_group_item(items: var seq[ImportTypeItem], prefix: string, item: Value) =
  case item.kind
  of VkSymbol:
    parse_import_symbol(items, item.str, prefix)
  of VkGene:
    let sub = item.gene
    if sub != nil and sub.`type`.kind == VkSymbol and sub.children.len == 1 and sub.children[0].kind == VkSymbol:
      parse_import_symbol(items, sub.`type`.str & ":" & sub.children[0].str, prefix)
  else:
    discard

proc collect_import_items(gene: ptr Gene): seq[ImportTypeItem] =
  if gene == nil:
    return @[]

  var i = 0
  while i < gene.children.len:
    let child = gene.children[i]

    if child.kind == VkSymbol and (child.str == "from" or child.str == "of"):
      if i + 1 < gene.children.len:
        i += 2
      else:
        i.inc()
      continue

    case child.kind
    of VkSymbol:
      parse_import_symbol(result, child.str)
    of VkComplexSymbol:
      let parts = child.ref.csymbol
      if parts.len >= 2 and parts[^1] == "" and i + 1 < gene.children.len and gene.children[i + 1].kind == VkArray:
        let prefix = normalize_import_path(parts[0..^2]).join("/")
        i.inc()
        for item in array_data(gene.children[i]):
          parse_import_group_item(result, prefix, item)
      else:
        let full = normalize_import_path(parts).join("/")
        parse_import_symbol(result, full)
    of VkGene:
      let g = child.gene
      if g == nil:
        discard
      elif g.`type`.kind == VkComplexSymbol:
        let parts = g.`type`.ref.csymbol
        if parts.len >= 2 and parts[^1] == "":
          let prefix = normalize_import_path(parts[0..^2]).join("/")
          for item in g.children:
            parse_import_group_item(result, prefix, item)
        else:
          let full = normalize_import_path(parts).join("/")
          parse_import_symbol(result, full)
      elif g.`type`.kind == VkSymbol and g.children.len == 1 and g.children[0].kind == VkSymbol:
        parse_import_symbol(result, g.`type`.str & ":" & g.children[0].str)
    else:
      discard

    i.inc()

proc import_module_path(gene: ptr Gene): string =
  if gene == nil:
    return ""
  var i = 0
  while i + 1 < gene.children.len:
    let child = gene.children[i]
    if child.kind == VkSymbol and child.str == "from":
      let next = gene.children[i + 1]
      if next.kind == VkString:
        return next.str
    i.inc()
  return ""

proc import_base_dir(self: TypeChecker): string =
  if self.module_filename.len > 0 and not self.module_filename.startsWith("<"):
    return parentDir(absolutePath(self.module_filename))
  return getCurrentDir()

proc add_unique_path(paths: var seq[string], candidate: string) =
  if candidate.len == 0:
    return
  let normalized = absolutePath(candidate)
  for path in paths:
    if path == normalized:
      return
  paths.add(normalized)

proc resolve_import_gir_path(self: TypeChecker, module_path: string): string =
  if module_path.len == 0:
    return ""

  var candidates: seq[string] = @[]
  if module_path.isAbsolute:
    add_unique_path(candidates, module_path)
  else:
    add_unique_path(candidates, joinPath(self.import_base_dir(), module_path))
    add_unique_path(candidates, module_path)

  for candidate in candidates:
    if candidate.endsWith(".gir"):
      if fileExists(candidate):
        return candidate
      continue

    if fileExists(candidate):
      if candidate.endsWith(".gene"):
        let gir_path = get_gir_path(candidate, "build")
        if fileExists(gir_path):
          return gir_path
      else:
        let gir_direct = candidate & ".gir"
        if fileExists(gir_direct):
          return gir_direct
        let source = candidate & ".gene"
        if fileExists(source):
          let gir_path = get_gir_path(source, "build")
          if fileExists(gir_path):
            return gir_path
    else:
      let gir_direct = candidate & ".gir"
      if fileExists(gir_direct):
        return gir_direct
      let source = candidate & ".gene"
      if fileExists(source):
        let gir_path = get_gir_path(source, "build")
        if fileExists(gir_path):
          return gir_path
  return ""

proc is_importable_module_type(node: ModuleTypeNode): bool =
  if node == nil:
    return false
  node.kind in {MtkClass, MtkEnum, MtkInterface, MtkAlias, MtkObject}

proc find_module_type_node(nodes: seq[ModuleTypeNode], path: seq[string]): ModuleTypeNode =
  if path.len == 0:
    return nil

  var current_nodes = nodes
  var current: ModuleTypeNode = nil
  for part in path:
    current = nil
    for node in current_nodes:
      if node != nil and node.name == part:
        current = node
        break
    if current == nil:
      return nil
    current_nodes = current.children
  return current

proc register_imported_types_from_module(self: TypeChecker, module_types: seq[ModuleTypeNode], items: seq[ImportTypeItem]) =
  if module_types.len == 0 or items.len == 0:
    return

  for item in items:
    if item.path.len == 1 and item.path[0] == "*":
      for node in module_types:
        if is_importable_module_type(node):
          let imported_name = if item.alias.len > 0: item.alias else: node.name
          self.register_imported_type(imported_name, force = true)
      continue

    let node = find_module_type_node(module_types, item.path)
    if node != nil and is_importable_module_type(node):
      let imported_name = if item.alias.len > 0: item.alias else: item.path[^1]
      self.register_imported_type(imported_name, force = true)

proc gir_cache_reads_enabled_for_typechecker(): bool =
  App == NIL or App.kind != VkApplication or App.app.gir_cache_reads_enabled

proc check_import(self: TypeChecker, gene: ptr Gene): TypeExpr =
  let module_path = import_module_path(gene)
  if module_path.len > 0:
    let items = collect_import_items(gene)
    if items.len > 0 and gir_cache_reads_enabled_for_typechecker():
      let gir_path = self.resolve_import_gir_path(module_path)
      if gir_path.len > 0:
        try:
          let imported = load_gir(gir_path)
          if imported != nil and imported.module_types.len > 0:
            self.register_imported_types_from_module(imported.module_types, items)
        except CatchableError:
          discard

  # Keep the legacy heuristic fallback so type-checking still works when
  # imported GIR metadata is not available yet.
  for child in gene.children:
    self.collect_import_types(child)
  return ANY_TYPE

proc check_export(self: TypeChecker, gene: ptr Gene): TypeExpr =
  return ANY_TYPE

proc is_union_gene(gene: ptr Gene): bool =
  if gene == nil:
    return false
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
    return true
  for child in gene.children:
    if child.kind == VkSymbol and child.str == "|":
      return true
  return false

proc legacy_adt_declaration_message*(sig: Value): string =
  ## Public helper for the compiler/type-checker boundary.  The enum-backed
  ## ADT bridge remains internal metadata; user-facing `(type (Result T E) ...)`
  ## declarations now receive a migration diagnostic instead of registering a
  ## legacy Gene-expression ADT.
  var name = ""
  var params: seq[string] = @[]
  var malformed_head = true

  if sig.kind == VkGene and sig.gene != nil:
    let sig_gene = sig.gene
    if sig_gene.`type`.kind == VkSymbol and sig_gene.`type`.str.len > 0:
      name = sig_gene.`type`.str
      malformed_head = false
      for child in sig_gene.children:
        if child.kind == VkSymbol and child.str.len > 0:
          params.add(child.str)
        else:
          malformed_head = true

  let suggestion_name = if name.len > 0: name else: "Name"
  var suggestion = "(enum " & suggestion_name
  if params.len > 0:
    suggestion &= ":" & params.join(":")
  elif name.len == 0 or malformed_head:
    suggestion &= ":T"
  suggestion &= " ...)"

  var prefix = "legacy ADT declaration"
  if name.len > 0:
    prefix &= " for " & name
  if malformed_head:
    return prefix & " has an invalid generic head; use enum declarations such as " & suggestion
  prefix & " is no longer supported; use enum declarations such as " & suggestion

proc reject_legacy_adt_declaration(self: TypeChecker, sig: Value) =
  self.warn(legacy_adt_declaration_message(sig))

proc parse_enum_declaration_name(raw_name: string): tuple[base_name: string, type_params: seq[string]] =
  let parsed = split_generic_definition_name(raw_name)
  if raw_name.contains(":") and (parsed.base_name == raw_name or parsed.type_params.len == 0):
    raise new_exception(types.Exception, "enum generic declaration '" & raw_name & "' has invalid generic parameter syntax")
  result.base_name = parsed.base_name
  result.type_params = parsed.type_params
  if result.base_name.len == 0:
    raise new_exception(types.Exception, "enum name must not be empty")

  var seen_params = initTable[string, bool]()
  for param in result.type_params:
    ensure_user_type_name(param, "enum generic parameter")
    if seen_params.hasKey(param):
      raise new_exception(types.Exception, "enum " & result.base_name & " has duplicate generic parameter " & param)
    seen_params[param] = true

proc enum_type_annotation_valid(v: Value): bool =
  case v.kind
  of VkSymbol, VkString:
    return v.str.len > 0 and not v.str.endsWith(":")
  of VkGene:
    return v.gene != nil and (v.gene.`type`.kind == VkSymbol or v.gene.`type`.kind == VkString)
  else:
    return false

proc enum_param_index(params: seq[string], type_node: Value): int =
  if type_node.kind != VkSymbol:
    return -1
  for i, param in params:
    if param == type_node.str:
      return i
  -1

proc parse_enum_variant_fields(self: TypeChecker, enum_name: string, variant_gene: ptr Gene,
                               type_params: seq[string]): tuple[fields: seq[string], field_types: seq[TypeExpr], field_param_indices: seq[int], param_index: int] =
  let variant_name = variant_gene.`type`.str
  result.param_index = -1
  if variant_gene.props.len > 0:
    raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " field declarations must be positional, not properties")

  var seen_fields = initTable[string, bool]()
  var field_param_indices: seq[int] = @[]
  var i = 0
  while i < variant_gene.children.len:
    let child = variant_gene.children[i]
    if child.kind != VkSymbol:
      raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " field must be a symbol")

    let token = child.str
    var field_name = token
    var field_type = ANY_TYPE
    var field_param_index = -1

    if token.endsWith(":"):
      field_name = token[0..^2]
      if field_name.len == 0:
        raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " has an empty field name")
      if i + 1 >= variant_gene.children.len:
        raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " field " & field_name & " is missing a type after ':'")
      let type_node = variant_gene.children[i + 1]
      if type_node.kind == VkSymbol and type_node.str.endsWith(":"):
        raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " field " & field_name & " is missing a type after ':'")
      if not enum_type_annotation_valid(type_node):
        raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " field " & field_name & " has an invalid type annotation")
      field_param_index = enum_param_index(type_params, type_node)
      field_type = self.parse_type_expr(type_node)
      i += 2
    else:
      i.inc()

    if seen_fields.hasKey(field_name):
      raise new_exception(types.Exception, "enum variant " & enum_name & "/" & variant_name & " has duplicate field " & field_name)
    seen_fields[field_name] = true
    result.fields.add(field_name)
    result.field_types.add(field_type)
    result.field_param_indices.add(field_param_index)
    field_param_indices.add(field_param_index)

  if result.fields.len == 1 and field_param_indices.len == 1:
    result.param_index = field_param_indices[0]

proc check_enum(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len < 1:
    raise new_exception(types.Exception, "enum expects at least a name")

  let name_node = gene.children[0]
  if name_node.kind != VkSymbol:
    raise new_exception(types.Exception, "enum name must be a symbol")

  let parsed_name = parse_enum_declaration_name(name_node.str)
  let enum_name = parsed_name.base_name
  let type_params = parsed_name.type_params
  ensure_user_type_name(enum_name, "enum")

  let enum_type = TypeExpr(kind: TkNamed, name: enum_name)
  self.types[enum_name] = enum_type
  discard self.intern_type_desc(enum_type)

  if type_params.len > 0:
    self.push_type_param_scope(type_params)
  defer:
    if type_params.len > 0:
      self.pop_type_param_scope()

  var variants: seq[AdtVariant] = @[]
  var seen_variants = initTable[string, bool]()

  proc add_variant(variant: AdtVariant) =
    if seen_variants.hasKey(variant.name):
      raise new_exception(types.Exception, "enum " & enum_name & " has duplicate variant " & variant.name)
    seen_variants[variant.name] = true
    variants.add(variant)

  if gene.props.hasKey("values".to_key()):
    let values_array = gene.props["values".to_key()]
    if values_array.kind != VkArray:
      raise new_exception(types.Exception, "enum ^values must be an array")
    for member in array_data(values_array):
      if member.kind != VkSymbol:
        raise new_exception(types.Exception, "enum ^values member must be a symbol")
      add_variant(AdtVariant(name: member.str, field_count: 0, param_index: -1, fields: @[], field_types: @[]))
  else:
    for i in 1..<gene.children.len:
      let member = gene.children[i]
      if member.kind == VkSymbol:
        add_variant(AdtVariant(name: member.str, field_count: 0, param_index: -1, fields: @[], field_types: @[]))
      elif member.kind == VkGene and member.gene != nil:
        let variant_gene = member.gene
        if variant_gene.`type`.kind != VkSymbol:
          raise new_exception(types.Exception, "enum data variant name must be a symbol")
        let parsed_fields = self.parse_enum_variant_fields(enum_name, variant_gene, type_params)
        add_variant(AdtVariant(
          name: variant_gene.`type`.str,
          field_count: parsed_fields.fields.len,
          param_index: parsed_fields.param_index,
          fields: parsed_fields.fields,
          field_types: parsed_fields.field_types,
          field_param_indices: parsed_fields.field_param_indices))
      else:
        raise new_exception(types.Exception, "enum member must be a symbol or data variant (Name field1 field2)")

  self.add_adt(enum_name, type_params, variants)
  return enum_type

proc parse_fn_params(self: TypeChecker, v: Value): seq[ParamType] =
  if v.kind != VkArray:
    return @[]
  let items = array_data(v)
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind == VkSymbol and item.str == "...":
      raise new_exception(types.Exception, "Invalid Fn type: rest marker must follow a parameter type")
    if item.kind == VkSymbol and item.str.startsWith("^"):
      let label = item.str[1..^1]
      if i + 1 >= items.len:
        raise new_exception(types.Exception, "Invalid Fn type: missing type for " & item.str)
      let t = self.parse_type_expr(items[i + 1])
      i += 2
      if label == "...":
        result.add(ParamType(kind: CpkKeywordRest, keyword_name: "", typ: t))
      else:
        if i < items.len and items[i].kind == VkSymbol and items[i].str == "...":
          i += 1
          result.add(ParamType(kind: CpkKeywordRest, keyword_name: "", typ: t))
        else:
          result.add(ParamType(kind: CpkKeyword, keyword_name: label, typ: t))
    else:
      var type_expr = item
      var kind = CpkPositional
      if item.kind == VkSymbol and item.str.endsWith("...") and item.str.len > 3:
        type_expr = item.str[0..^4].to_symbol_value()
        kind = CpkPositionalRest
      let t = self.parse_type_expr(type_expr)
      i += 1
      if i < items.len and items[i].kind == VkSymbol and items[i].str == "...":
        if kind == CpkPositionalRest:
          raise new_exception(types.Exception, "Invalid Fn type: duplicate rest marker")
        kind = CpkPositionalRest
        i += 1
      result.add(ParamType(kind: kind, keyword_name: "", typ: t))

proc parse_effect_list(self: TypeChecker, v: Value): seq[string] =
  if v.kind != VkArray:
    raise new_exception(types.Exception, "Invalid effect list: expected array")
  var seen = initTable[string, bool]()
  for item in array_data(v):
    if item.kind in {VkSymbol, VkString}:
      let name = item.str
      if name.len == 0:
        continue
      if not seen.hasKey(name):
        seen[name] = true
        result.add(name)
    else:
      raise new_exception(types.Exception, "Invalid effect name: " & $item.kind)

proc parse_union(self: TypeChecker, gene: ptr Gene): TypeExpr =
  var parts: seq[TypeExpr] = @[]
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
    for child in gene.children:
      parts.add(self.parse_type_expr(child))
  else:
    parts.add(self.parse_type_expr(gene.`type`))
    var i = 0
    while i < gene.children.len:
      let child = gene.children[i]
      if child.kind == VkSymbol and child.str == "|":
        if i + 1 >= gene.children.len:
          raise new_exception(types.Exception, "Invalid union type: trailing '|'")
        parts.add(self.parse_type_expr(gene.children[i + 1]))
        i += 2
      else:
        i += 1
  return TypeExpr(kind: TkUnion, members: parts)

proc parse_type_expr(self: TypeChecker, v: Value): TypeExpr =
  case v.kind
  of VkSymbol:
    let name = v.str
    if name == "Any":
      return ANY_TYPE
    if name == "Self":
      if self.current_class.len == 0:
        raise new_exception(types.Exception, "Invalid contextual type: Self is only available inside class scope")
      return TypeExpr(kind: TkNamed, name: "Self")
    let type_param = self.lookup_type_param(name)
    if type_param != nil:
      return type_param
    if self.types.hasKey(name):
      return self.types[name]
    if self.classes.hasKey(name):
      return TypeExpr(kind: TkNamed, name: name)
    if self.strict and not is_known_type_name(self, name):
      raise new_exception(types.Exception, "Unknown type: " & name)
    return TypeExpr(kind: TkNamed, name: name)
  of VkGene:
    let gene = v.gene
    if gene == nil:
      return ANY_TYPE
    if gene.`type`.kind == VkSymbol and gene.`type`.str in ["Fn", "Method"]:
      var idx = 0
      var params: seq[ParamType] = @[]
      var ret = ANY_TYPE
      var effects: seq[string] = @[]
      if idx < gene.children.len and gene.children[idx].kind == VkArray:
        params = self.parse_fn_params(gene.children[idx])
        idx += 1
      if idx < gene.children.len and gene.children[idx].kind == VkSymbol and gene.children[idx].str == "->":
        if idx + 1 >= gene.children.len:
          raise new_exception(types.Exception, "Invalid Fn type: missing return type after ->")
        ret = self.parse_type_expr(gene.children[idx + 1])
        idx += 2
      elif idx < gene.children.len and not (gene.children[idx].kind == VkSymbol and gene.children[idx].str == "!"):
        ret = self.parse_type_expr(gene.children[idx])
        idx += 1
      if idx < gene.children.len:
        let maybe_bang = gene.children[idx]
        if maybe_bang.kind == VkSymbol and maybe_bang.str == "!":
          if idx + 1 >= gene.children.len:
            raise new_exception(types.Exception, "Invalid Fn type: missing effects after !")
          effects = self.parse_effect_list(gene.children[idx + 1])
          idx += 2
          if idx < gene.children.len:
            raise new_exception(types.Exception, "Invalid Fn type: unexpected extra elements")
        else:
          raise new_exception(types.Exception, "Invalid Fn type: unexpected element " & $maybe_bang.kind)
      return TypeExpr(kind: TkFn, params: params, ret: ret, receiver: nil, effects: effects)
    if is_union_gene(gene):
      return self.parse_union(gene)
    # Generic constructor: (Array T)
    if gene.`type`.kind == VkSymbol:
      let ctor_name = gene.`type`.str
      if self.strict and not is_known_type_name(self, ctor_name):
        raise new_exception(types.Exception, "Unknown type: " & ctor_name)
      var args: seq[TypeExpr] = @[]
      for child in gene.children:
        args.add(self.parse_type_expr(child))
      return TypeExpr(kind: TkApplied, ctor: ctor_name, args: args)
    return ANY_TYPE
  else:
    raise new_exception(types.Exception, "Invalid type expression: " & $v.kind)

proc parse_param_annotations(self: TypeChecker, args: Value,
                             allow_reserved_self = false): seq[ParameterDecl] =
  var items: seq[Value] = @[]
  case args.kind
  of VkArray:
    items = array_data(args)
  of VkSymbol:
    items = @[args]
  of VkComplexSymbol:
    items = @[args]
  else:
    return @[]

  var params: seq[ParameterDecl] = @[]
  var positional_rest_count = 0
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind == VkSymbol and item.str == "=":
      # Skip default value
      i += 2
      continue
    if item.kind == VkSymbol:
      if item.str == "...":
        raise new_exception(types.Exception, "Positional rest must follow a named parameter")
      var raw = item.str
      var keyword_name = ""
      var typ: TypeExpr = nil
      var name = ""
      var is_rest = false
      var has_type = false
      if raw.endsWith(":"):
        has_type = true
        raw = raw[0..^2]
      if raw.endsWith("..."):
        is_rest = true
        raw = raw[0..^4]
      if i + 1 < items.len and items[i + 1].kind == VkSymbol and items[i + 1].str == "...":
        if is_rest:
          raise new_exception(types.Exception, "Duplicate rest marker for parameter " & raw)
        is_rest = true
        i += 1
      name = raw
      if name.startsWith("^"):
        if name.len >= 2 and (name[1] == '^' or name[1] == '!'):
          keyword_name = name[2..^1]
        else:
          keyword_name = name[1..^1]
        name = keyword_name
      if name.len > 0 and name != "_" and not (allow_reserved_self and name == "self"):
        ensure_user_value_name(name, "parameter")
      if is_rest and (name.len == 0 or name == "_"):
        raise new_exception(types.Exception, "Positional rest must bind to a named parameter")
      if has_type:
        if i + 1 >= items.len:
          raise new_exception(types.Exception, "Missing type for parameter " & name)
        typ = self.parse_type_expr(items[i + 1])
        i += 1
      var kind = CpkPositional
      if keyword_name.len > 0:
        kind = if is_rest: CpkKeywordRest else: CpkKeyword
      elif is_rest:
        kind = CpkPositionalRest
      if kind == CpkPositionalRest:
        positional_rest_count += 1
        if positional_rest_count > 1:
          raise new_exception(types.Exception, "Only one positional rest parameter is allowed")
      params.add(ParameterDecl(binding_name: name, kind: kind, keyword_name: keyword_name, typ: typ))
      i += 1
    elif item.kind == VkComplexSymbol:
      if item.ref.csymbol.len < 2:
        i += 1
        continue
      # Shorthand property parameter syntax, e.g. /x or /x...
      if item.ref.csymbol[0] == "":
        var name = item.ref.csymbol[1]
        var typ: TypeExpr = nil
        var is_rest = false
        if name.endsWith("..."):
          is_rest = true
          name = name[0..^4]
        elif i + 1 < items.len and items[i + 1].kind == VkSymbol and items[i + 1].str == "...":
          is_rest = true
          i += 1
        if is_rest:
          positional_rest_count += 1
          if positional_rest_count > 1:
            raise new_exception(types.Exception, "Only one positional rest parameter is allowed")
        if name.len > 0 and name != "_" and not (allow_reserved_self and name == "self"):
          ensure_user_value_name(name, "parameter")
        params.add(ParameterDecl(
          binding_name: name,
          kind: if is_rest: CpkPositionalRest else: CpkPositional,
          keyword_name: "",
          typ: typ
        ))
      i += 1
    elif item.kind == VkArray:
      # Destructuring not typed yet
      params.add(ParameterDecl(binding_name: "_", kind: CpkPositional, keyword_name: "", typ: nil))
      i += 1
    else:
      i += 1
  return params

proc rest_param_index(params: seq[ParamType]): int =
  for i, param in params:
    if param.kind == CpkPositionalRest:
      return i
  return -1

proc rest_element_type(self: TypeChecker, param: ParamType): TypeExpr =
  self.resolve(effective_type(param.typ))

proc check_expected_arg(self: TypeChecker, expected: TypeExpr, arg: Value, context: string) =
  let arg_type = self.check_expr(arg)
  if self.strict:
    self.unify(expected, arg_type, context)
  else:
    try:
      self.unify(expected, arg_type, context)
    except CatchableError as e:
      self.warn("Warning: " & e.msg)

proc adt_variant_qualified_name(adt: AdtDef, variant: AdtVariant): string =
  if adt == nil:
    return variant.name
  adt.name & "/" & variant.name

proc adt_pattern_binding_message(adt: AdtDef, variant: AdtVariant, got: int): string =
  let expected = variant.field_count
  let field_names = if expected > 0 and variant.fields.len > 0: " (" & variant.fields.join(", ") & ")" else: ""
  "variant " & adt_variant_qualified_name(adt, variant) & " pattern expects " &
    $expected & " binding(s)" & field_names & ", got " & $got

proc sorted_adt_names(self: TypeChecker): seq[string] =
  for name in self.adts.keys:
    result.add(name)
  result.sort()

proc builtin_adt_name_for_variant(ctor: string): string =
  if ctor == "Ok" or ctor == "Err":
    return "Result"
  if ctor == "Some" or ctor == "None":
    return "Option"
  ""

proc adt_variant_candidates_by_name(self: TypeChecker, ctor: string): seq[AdtVariantCandidate] =
  for adt_name in self.sorted_adt_names():
    let adt = self.adts[adt_name]
    if adt.variants.hasKey(ctor):
      result.add(AdtVariantCandidate(adt: adt, variant: adt.variants[ctor]))

proc find_qualified_adt_variant(self: TypeChecker, adt_name: string, ctor: string): tuple[adt: AdtDef, variant: AdtVariant, found: bool] =
  if self.adts.hasKey(adt_name):
    let adt = self.adts[adt_name]
    if adt.variants.hasKey(ctor):
      return (adt, adt.variants[ctor], true)
  return (nil, AdtVariant(), false)

proc find_adt_variant(self: TypeChecker, ctor: string): tuple[adt: AdtDef, variant: AdtVariant, found: bool] =
  let builtin_adt_name = builtin_adt_name_for_variant(ctor)
  if builtin_adt_name.len > 0:
    let builtin = self.find_qualified_adt_variant(builtin_adt_name, ctor)
    if builtin.found:
      return builtin

  let candidates = self.adt_variant_candidates_by_name(ctor)
  if candidates.len > 0:
    return (candidates[0].adt, candidates[0].variant, true)
  return (nil, AdtVariant(), false)

proc static_adt_name_for_type(self: TypeChecker, typ: TypeExpr): string =
  let rt = self.resolve_self(self.resolve(typ))
  if rt == nil:
    return ""
  case rt.kind
  of TkNamed:
    if self.adts.hasKey(rt.name):
      return rt.name
  of TkApplied:
    if self.adts.hasKey(rt.ctor):
      return rt.ctor
  else:
    discard
  ""

proc substitute_adt_type_params(self: TypeChecker, scrutinee_type: TypeExpr, adt: AdtDef, declared: TypeExpr): TypeExpr =
  if declared == nil:
    return ANY_TYPE
  let rt = self.resolve_self(self.resolve(scrutinee_type))
  var param_types = initTable[string, TypeExpr]()
  if adt != nil and rt != nil and rt.kind == TkApplied and rt.ctor == adt.name:
    for i, param_name in adt.params:
      if i < rt.args.len:
        param_types[param_name] = rt.args[i]

  proc clone(node: TypeExpr): TypeExpr =
    let rn = self.resolve_self(self.resolve(node))
    if rn == nil:
      return ANY_TYPE
    case rn.kind
    of TkAny:
      ANY_TYPE
    of TkNamed:
      if param_types.hasKey(rn.name):
        param_types[rn.name]
      else:
        TypeExpr(kind: TkNamed, name: rn.name)
    of TkApplied:
      var args: seq[TypeExpr] = @[]
      for arg in rn.args:
        args.add(clone(arg))
      TypeExpr(kind: TkApplied, ctor: rn.ctor, args: args)
    of TkUnion:
      var members: seq[TypeExpr] = @[]
      for member in rn.members:
        members.add(clone(member))
      TypeExpr(kind: TkUnion, members: members)
    of TkFn:
      var params: seq[ParamType] = @[]
      for param in rn.params:
        params.add(ParamType(kind: param.kind, keyword_name: param.keyword_name, typ: clone(param.typ)))
      TypeExpr(kind: TkFn, params: params, ret: clone(rn.ret), receiver: clone(rn.receiver), effects: rn.effects)
    of TkVar:
      rn

  clone(declared)

proc adt_field_binding_type(self: TypeChecker, scrutinee_type: TypeExpr, adt: AdtDef, variant: AdtVariant, field_index: int): TypeExpr =
  let rt = self.resolve_self(self.resolve(scrutinee_type))
  if rt != nil and rt.kind == TkApplied:
    if field_index < variant.field_param_indices.len:
      let param_index = variant.field_param_indices[field_index]
      if param_index >= 0 and param_index < rt.args.len:
        return rt.args[param_index]
    elif field_index == 0 and variant.param_index >= 0 and variant.param_index < rt.args.len:
      return rt.args[variant.param_index]

  if field_index < variant.field_types.len:
    return self.substitute_adt_type_params(scrutinee_type, adt, variant.field_types[field_index])
  return ANY_TYPE

proc check_adt_ctor(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene == nil or gene.`type`.kind != VkSymbol:
    return nil
  let ctor = gene.`type`.str
  let (adt, variant, found) = self.find_adt_variant(ctor)
  if not found:
    return nil

  var args: seq[TypeExpr] = @[]
  if adt.params.len > 0:
    args = newSeq[TypeExpr](adt.params.len)
    for i in 0..<adt.params.len:
      args[i] = ANY_TYPE

  if variant.param_index >= 0 and variant.param_index < args.len:
    var payload: Value = NIL
    var found_payload = false
    if gene.children.len > 0:
      payload = gene.children[0]
      found_payload = true
    elif variant.fields.len == 1:
      let field_key = variant.fields[0].to_key()
      if gene.props.hasKey(field_key):
        payload = gene.props[field_key]
        found_payload = true
    if found_payload:
      let inner_type = self.check_expr(payload)
      args[variant.param_index] = inner_type

  if adt.params.len > 0:
    return TypeExpr(kind: TkApplied, ctor: adt.name, args: args)
  return TypeExpr(kind: TkNamed, name: adt.name)

proc resolve_self(self: TypeChecker, t: TypeExpr): TypeExpr =
  let rt = self.resolve(t)
  if rt.kind == TkNamed and rt.name == "Self" and self.current_class.len > 0:
    return TypeExpr(kind: TkNamed, name: self.current_class)
  return rt

proc check_call(self: TypeChecker, callee_type: TypeExpr, args: seq[Value], props: Table[Key, Value], context: string): TypeExpr =
  var ct = self.resolve(callee_type)
  if ct != nil and ct.kind == TkFn:
    ct = self.instantiate_type_vars(ct)
  if ct == nil or ct.kind == TkAny:
    return ANY_TYPE
  # Allow calling type variables (unknown types) - they might be callable
  if ct.kind == TkVar:
    # Type-check arguments but don't enforce
    for arg in args:
      discard self.check_expr(arg)
    for k, v in props:
      discard self.check_expr(v)
    return ANY_TYPE
  # Allow calling named types (class instances) - they might have a call method
  # Also allow calling applied types (Array, Map, etc.) - they have methods
  if ct.kind in {TkNamed, TkApplied}:
    # Type-check arguments but don't enforce
    for arg in args:
      discard self.check_expr(arg)
    for k, v in props:
      discard self.check_expr(v)
    return ANY_TYPE
  if ct.kind != TkFn:
    raise new_exception(types.Exception, "Type error: calling non-function in " & context)
  self.ensure_effects_allowed(ct.effects, context)
  # Split params into positional, fixed keyword, and keyword-rest
  var pos_params: seq[ParamType] = @[]
  var kw_params = initTable[string, ParamType]()
  var kw_rest = ParamType(kind: CpkKeywordRest, keyword_name: "", typ: ANY_TYPE)
  var has_kw_rest = false
  for p in ct.params:
    case p.kind
    of CpkPositional, CpkPositionalRest:
      pos_params.add(p)
    of CpkKeyword:
      kw_params[p.keyword_name] = p
    of CpkKeywordRest:
      kw_rest = p
      has_kw_rest = true

  let pos_count = args.len
  let rest_index = rest_param_index(pos_params)
  if rest_index < 0 and pos_count > pos_params.len:
    raise new_exception(types.Exception,
      "Type error: too many positional arguments in " & context &
      " (expected " & $pos_params.len & ", got " & $pos_count & ")")

  if rest_index < 0:
    let check_count = min(pos_count, pos_params.len)
    for i in 0..<check_count:
      self.check_expected_arg(pos_params[i].typ, args[i], context)
  else:
    let prefix_count = rest_index
    let suffix_count = pos_params.len - rest_index - 1
    let prefix_check_count = min(pos_count, prefix_count)
    for i in 0..<prefix_check_count:
      self.check_expected_arg(pos_params[i].typ, args[i], context)

    let available_suffix = min(suffix_count, max(0, pos_count - prefix_count))
    if available_suffix > 0:
      let suffix_param_start = pos_params.len - available_suffix
      let suffix_arg_start = pos_count - available_suffix
      for i in 0..<available_suffix:
        self.check_expected_arg(pos_params[suffix_param_start + i].typ, args[suffix_arg_start + i], context)

    let rest_start = min(prefix_count, pos_count)
    let rest_end = pos_count - available_suffix
    if rest_end > rest_start:
      let elem_type = self.rest_element_type(pos_params[rest_index])
      for i in rest_start..<rest_end:
        self.check_expected_arg(elem_type, args[i], context)

  # Keyword args - be lenient since Gene's keyword syntax is complex (^^, ^!, etc.)
  for k, v in props:
    let key_name = key_to_string(k)
    if key_name.startsWith("..."):
      discard self.check_expr(v)
    elif kw_params.hasKey(key_name):
      let arg_type = self.check_expr(v)
      if self.strict:
        self.unify(kw_params[key_name].typ, arg_type, context)
      else:
        try:
          self.unify(kw_params[key_name].typ, arg_type, context)
        except CatchableError as e:
          self.warn("Warning: " & e.msg)
    elif has_kw_rest:
      self.check_expected_arg(kw_rest.typ, v, context)
    else:
      if self.strict:
        raise new_exception(types.Exception, "Type error: unexpected keyword argument '" & key_name & "' in " & context)
      else:
        self.warn("Warning: Type error: unexpected keyword argument '" & key_name & "' in " & context)
  return self.resolve_self(ct.ret)

proc bind_receiver_type(self: TypeChecker, t: TypeExpr, recv_type: TypeExpr): TypeExpr =
  let rt = self.resolve(t)
  if rt == nil:
    return ANY_TYPE
  case rt.kind
  of TkAny:
    ANY_TYPE
  of TkNamed:
    if rt.name == "Self": self.resolve(recv_type) else: TypeExpr(kind: TkNamed, name: rt.name)
  of TkApplied:
    var args: seq[TypeExpr] = @[]
    for arg in rt.args:
      args.add(self.bind_receiver_type(arg, recv_type))
    TypeExpr(kind: TkApplied, ctor: rt.ctor, args: args)
  of TkUnion:
    var members: seq[TypeExpr] = @[]
    for member in rt.members:
      members.add(self.bind_receiver_type(member, recv_type))
    TypeExpr(kind: TkUnion, members: members)
  of TkFn:
    var params: seq[ParamType] = @[]
    for param in rt.params:
      params.add(ParamType(
        kind: param.kind,
        keyword_name: param.keyword_name,
        typ: self.bind_receiver_type(param.typ, recv_type)
      ))
    TypeExpr(
      kind: TkFn,
      params: params,
      ret: self.bind_receiver_type(rt.ret, recv_type),
      receiver: if rt.receiver != nil: self.bind_receiver_type(rt.receiver, recv_type) else: nil,
      effects: rt.effects
    )
  of TkVar:
    TypeExpr(kind: TkVar, id: rt.id)

proc native_type_from_class_value(self: TypeChecker, class_value: Value): TypeExpr =
  if class_value == NIL or class_value.kind != VkClass:
    return ANY_TYPE
  let cls = class_value.ref.class
  if cls.is_nil or cls.name.len == 0:
    return ANY_TYPE
  if cls.name == "Array":
    return TypeExpr(kind: TkApplied, ctor: "Array", args: @[ANY_TYPE])
  if cls.name == "Map":
    return TypeExpr(kind: TkApplied, ctor: "Map", args: @[ANY_TYPE, ANY_TYPE])
  if cls.name == "HashMap":
    return TypeExpr(kind: TkApplied, ctor: "HashMap", args: @[ANY_TYPE, ANY_TYPE])
  if cls.name == "HashSet":
    return TypeExpr(kind: TkApplied, ctor: "HashSet", args: @[ANY_TYPE])
  if cls.name == "Option":
    return TypeExpr(kind: TkApplied, ctor: "Option", args: @[ANY_TYPE])
  if cls.name == "Result":
    return TypeExpr(kind: TkApplied, ctor: "Result", args: @[ANY_TYPE, ANY_TYPE])
  return TypeExpr(kind: TkNamed, name: cls.name)

proc class_matches_expected(actual_class: Class, expected_class: Class): bool =
  if actual_class.is_nil or expected_class.is_nil:
    return false
  var current = actual_class
  while current != nil:
    if current == expected_class:
      return true
    current = current.parent
  return false

proc runtime_class_for_type(self: TypeChecker, recv_type: TypeExpr): Class =
  let rt = self.resolve(recv_type)
  var class_name = ""
  case rt.kind
  of TkNamed:
    class_name = rt.name
  of TkApplied:
    class_name = rt.ctor
  else:
    return nil

  if class_name.len == 0:
    return nil
  if App.kind != VkApplication:
    return nil

  let class_key = class_name.to_key()
  if App.app.gene_ns.kind == VkNamespace and App.app.gene_ns.ns.hasKey(class_key):
    let class_value = App.app.gene_ns.ns[class_key]
    if class_value.kind == VkClass:
      return class_value.ref.class
  if App.app.global_ns.kind == VkNamespace and App.app.global_ns.ns.hasKey(class_key):
    let class_value = App.app.global_ns.ns[class_key]
    if class_value.kind == VkClass:
      return class_value.ref.class
  return nil

proc check_native_method_call(self: TypeChecker, recv_type: TypeExpr, method_name: string,
                              args: seq[Value], props: Table[Key, Value], context: string): TypeExpr =
  let runtime_class = self.runtime_class_for_type(recv_type)
  if runtime_class.is_nil:
    return ANY_TYPE

  let runtime_method = runtime_class.get_method(method_name)
  if runtime_method.is_nil:
    return ANY_TYPE

  if runtime_method.native_param_types.len == 0 and runtime_method.native_return_type == NIL:
    return ANY_TYPE

  let expected_count = runtime_method.native_param_types.len
  if args.len < expected_count:
    let msg = "Type error: too few positional arguments for " & runtime_class.name & "." &
      method_name & " (expected " & $expected_count & ", got " & $args.len & ") in " & context
    if self.strict:
      raise new_exception(types.Exception, msg)
    else:
      self.warn("Warning: " & msg)
  elif args.len > expected_count:
    let msg = "Type error: too many positional arguments for " & runtime_class.name & "." &
      method_name & " (expected " & $expected_count & ", got " & $args.len & ") in " & context
    if self.strict:
      raise new_exception(types.Exception, msg)
    else:
      self.warn("Warning: " & msg)

  let check_count = min(args.len, expected_count)
  for i in 0..<check_count:
    let arg_type = self.check_expr(args[i])
    let param = runtime_method.native_param_types[i]
    let expected_class_value = param[1]
    if expected_class_value == NIL:
      continue
    let expected_class = if expected_class_value.kind == VkClass: expected_class_value.ref.class else: nil
    let actual_class = self.runtime_class_for_type(arg_type)
    let arg_context = context & " " & runtime_class.name & "." & method_name & " arg '" & param[0] & "'"
    if not expected_class.is_nil and not actual_class.is_nil:
      if not class_matches_expected(actual_class, expected_class):
        let msg = "Type error: expected " & expected_class.name & ", got " & actual_class.name & " in " & arg_context
        if self.strict:
          raise new_exception(types.Exception, msg)
        else:
          self.warn("Warning: " & msg)
    else:
      let expected_type = self.native_type_from_class_value(expected_class_value)
      if self.strict:
        self.unify(expected_type, arg_type, arg_context)
      else:
        try:
          self.unify(expected_type, arg_type, arg_context)
        except CatchableError as e:
          self.warn("Warning: " & e.msg)

  for _, value in props:
    discard self.check_expr(value)

  if runtime_method.native_return_type == NIL:
    return ANY_TYPE
  return self.resolve_self(self.native_type_from_class_value(runtime_method.native_return_type))

proc check_method_call(self: TypeChecker, recv_type: TypeExpr, method_name: string, args: seq[Value], props: Table[Key, Value], context: string): TypeExpr =
  if method_name.ends_with("!"):
    raise new_exception(types.Exception, "Type error: macro-like class methods are not supported; use a regular method or a standalone fn!")
  let rt = self.resolve(recv_type)
  if rt == nil or rt.kind == TkAny:
    return ANY_TYPE
  if rt.kind == TkNamed and self.classes.hasKey(rt.name):
    let cls = self.classes[rt.name]
    let mt = self.find_method(cls, method_name)
    if mt == nil:
      if self.find_method(cls, "on_method_missing") != nil:
        return ANY_TYPE
      raise new_exception(types.Exception, "Type error: unknown method " & method_name & " on " & rt.name)
    let fn_t = self.resolve(mt)
    if fn_t.kind != TkFn:
      return ANY_TYPE
    return self.check_call(self.bind_receiver_type(fn_t, rt), args, props, context)
  return self.check_native_method_call(rt, method_name, args, props, context)

proc check_super_call(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if self.current_class.len == 0:
    raise new_exception(types.Exception, "Type error: super used outside of a class")
  let cls = self.get_class_info(self.current_class)
  if cls == nil or cls.parent.len == 0:
    raise new_exception(types.Exception, "Type error: super has no superclass in " & self.current_class)
  let parent_cls = self.get_class_info(cls.parent)
  if parent_cls == nil:
    raise new_exception(types.Exception, "Type error: unknown superclass " & cls.parent)
  if gene.children.len == 0:
    raise new_exception(types.Exception, "Type error: super requires a member")
  let member = gene.children[0]
  if member.kind != VkSymbol or not member.str.startsWith("."):
    raise new_exception(types.Exception, "Type error: super requires a dotted member (e.g. .m or .ctor)")
  let member_name = member.str[1..^1]
  if member_name.ends_with("!"):
    if member_name == "ctor!":
      raise new_exception(types.Exception, "Type error: macro-like super constructors are not supported; use .ctor")
    raise new_exception(types.Exception, "Type error: macro-like super methods are not supported")
  let is_ctor = member_name == "ctor"
  let args = if gene.children.len > 1: gene.children[1..^1] else: @[]
  if is_ctor:
    if parent_cls.ctor_type != nil:
      discard self.check_call(parent_cls.ctor_type, args, gene.props, "super ctor")
    return ANY_TYPE
  let mt = self.find_method(parent_cls, member_name)
  if mt == nil:
    raise new_exception(types.Exception, "Type error: unknown super method " & member_name & " on " & parent_cls.name)
  let fn_t = self.resolve(mt)
  if fn_t.kind != TkFn:
    return ANY_TYPE
  let recv_type = TypeExpr(kind: TkNamed, name: self.current_class)
  return self.check_call(self.bind_receiver_type(fn_t, recv_type), args, gene.props, "super " & member_name)

proc define_pattern_bindings(self: TypeChecker, pattern: Value, value_type: TypeExpr) =
  case pattern.kind
  of VkSymbol:
    let name = pattern.str
    if name.len > 0 and name != "_":
      ensure_user_value_name(name, "binding")
      self.define(name, value_type)
  of VkArray:
    var elem_type = ANY_TYPE
    var prop_value_type = ANY_TYPE
    let resolved = self.resolve(value_type)
    if resolved != nil and resolved.kind == TkApplied:
      if resolved.ctor == "Array" and resolved.args.len > 0:
        elem_type = resolved.args[0]
      elif resolved.ctor == "Map" and resolved.args.len > 1:
        prop_value_type = resolved.args[1]

    let matcher = new_arg_matcher(pattern)
    for child in matcher.children:
      var bind_name = ""
      try:
        bind_name = cast[Value](child.name_key).str
      except CatchableError:
        bind_name = ""
      if bind_name.len == 0 or bind_name == "_":
        continue
      ensure_user_value_name(bind_name, "binding")

      if child.kind == MatchProp or child.is_prop:
        if child.is_splat:
          self.define(bind_name, TypeExpr(kind: TkApplied, ctor: "Map", args: @[ANY_TYPE, prop_value_type]))
        else:
          self.define(bind_name, prop_value_type)
      else:
        if child.is_splat:
          self.define(bind_name, TypeExpr(kind: TkApplied, ctor: "Array", args: @[elem_type]))
        else:
          self.define(bind_name, elem_type)
  of VkMap:
    var map_value_type = ANY_TYPE
    let resolved = self.resolve(value_type)
    if resolved != nil and resolved.kind == TkApplied and resolved.ctor == "Map" and resolved.args.len > 1:
      map_value_type = resolved.args[1]
    for _, item in map_data(pattern).pairs:
      if item.kind != VkSymbol:
        continue
      var name = item.str
      if name.startsWith("^"):
        if name.len <= 1:
          continue
        name = name[1..^1]
      if name.len > 0 and name != "_":
        self.define(name, map_value_type)
  else:
    discard

proc check_var(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    return ANY_TYPE

  var pattern = gene.children[0]
  var name = ""
  var annotated: TypeExpr = nil
  var value_index = 1

  if pattern.kind == VkSymbol:
    name = pattern.str
    if name.endsWith(":"):
      name = name[0..^2]
      pattern = name.to_symbol_value()
      if gene.children.len > 1:
        annotated = self.parse_type_expr(gene.children[1])
        value_index = 2

  var value_type = ANY_TYPE
  if gene.children.len > value_index:
    value_type = self.check_expr(gene.children[value_index])

  # Destructuring var binds names from pattern and yields nil.
  if pattern.kind in {VkArray, VkMap}:
    self.define_pattern_bindings(pattern, value_type)
    return TypeExpr(kind: TkNamed, name: "Nil")

  if pattern.kind != VkSymbol:
    return ANY_TYPE

  ensure_user_value_name(name, "variable")

  if annotated != nil:
    if gene.children.len > value_index:
      if self.strict:
        self.unify(annotated, value_type, "var " & name)
      else:
        try:
          self.unify(annotated, value_type, "var " & name)
        except CatchableError as e:
          self.warn("Warning: " & e.msg)
    self.define(name, annotated)
    return annotated

  if gene.children.len > value_index:
    self.define(name, value_type)
    return value_type

  self.define(name, ANY_TYPE)
  return ANY_TYPE

proc extract_type_guard(self: TypeChecker, cond: Value): tuple[name: string, guarded_type: TypeExpr, found: bool, negated: bool] =
  ## Detect simple type guard patterns like:
  ##   (x .is Int)
  ##   (x is Int)
  ##   (not (x .is Int))
  ##   (x == nil)
  ##   (x != nil)
  if cond.kind != VkGene or cond.gene == nil:
    return ("", nil, false, false)
  let gene = cond.gene
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "not" and gene.children.len > 0:
    let inner = self.extract_type_guard(gene.children[0])
    if inner.found:
      return (inner.name, inner.guarded_type, true, not inner.negated)
    return ("", nil, false, false)

  if gene.children.len >= 2 and gene.children[0].kind == VkSymbol and gene.children[0].str in ["==", "!="]:
    let op = gene.children[0].str
    let left = gene.`type`
    let right = gene.children[1]
    if left.kind == VkSymbol and left.str.len > 0 and left.str != "_" and right == NIL:
      return (left.str, TypeExpr(kind: TkNamed, name: "Nil"), true, op == "!=")
    if right.kind == VkSymbol and right.str.len > 0 and right.str != "_" and left == NIL:
      return (right.str, TypeExpr(kind: TkNamed, name: "Nil"), true, op == "!=")

  let recv = gene.`type`
  if recv.kind != VkSymbol:
    return ("", nil, false, false)
  let name = recv.str
  if name.len == 0 or name == "_":
    return ("", nil, false, false)
  if gene.children.len < 2:
    return ("", nil, false, false)

  let guard_sym = gene.children[0]
  if guard_sym.kind == VkSymbol and (guard_sym.str == ".is" or guard_sym.str == "is"):
    let narrowed = self.parse_type_expr(gene.children[1])
    return (name, narrowed, true, false)
  return ("", nil, false, false)

proc same_type(self: TypeChecker, a: TypeExpr, b: TypeExpr): bool =
  let ra = self.resolve_self(self.resolve(a))
  let rb = self.resolve_self(self.resolve(b))
  if ra == nil or rb == nil:
    return false
  let aid = self.intern_type_desc(ra)
  let bid = self.intern_type_desc(rb)
  if aid != NO_TYPE_ID and bid != NO_TYPE_ID:
    return aid == bid
  return type_to_string(ra) == type_to_string(rb)

proc type_is_adt(self: TypeChecker, typ: TypeExpr, adt_name: string): bool =
  if adt_name.len == 0:
    return false
  let rt = self.resolve_self(self.resolve(typ))
  case rt.kind
  of TkApplied:
    return rt.ctor == adt_name
  of TkNamed:
    return rt.name == adt_name
  else:
    return false

proc narrow_type_to_adt(self: TypeChecker, original: TypeExpr, adt_name: string): TypeExpr =
  let ro = self.resolve_self(self.resolve(original))
  if ro == nil or adt_name.len == 0:
    return original

  if ro.kind == TkUnion:
    var keep: seq[TypeExpr] = @[]
    for member in ro.members:
      if self.type_is_adt(member, adt_name):
        keep.add(self.resolve_self(self.resolve(member)))
    if keep.len == 0:
      return ro
    if keep.len == 1:
      return keep[0]
    return TypeExpr(kind: TkUnion, members: keep)

  if self.type_is_adt(ro, adt_name):
    return ro
  return ro

proc subtract_adt_type(self: TypeChecker, original: TypeExpr, adt_name: string): TypeExpr =
  let ro = self.resolve_self(self.resolve(original))
  if ro == nil or adt_name.len == 0:
    return original

  if ro.kind == TkUnion:
    var keep: seq[TypeExpr] = @[]
    for member in ro.members:
      if not self.type_is_adt(member, adt_name):
        keep.add(self.resolve_self(self.resolve(member)))
    if keep.len == 0:
      return ANY_TYPE
    if keep.len == 1:
      return keep[0]
    return TypeExpr(kind: TkUnion, members: keep)

  if self.type_is_adt(ro, adt_name):
    return ANY_TYPE
  return ro

proc is_simple_qualified_adt_pattern_head(v: Value): bool =
  if v.kind != VkComplexSymbol or v.ref == nil:
    return false
  let parts = v.ref.csymbol
  parts.len == 2 and parts[0].len > 0 and parts[1].len > 0 and
    not parts[0].startsWith(".") and not parts[1].startsWith(".")

proc qualified_adt_pattern_name(v: Value): string =
  let parts = v.ref.csymbol
  parts[0] & "/" & parts[1]

proc resolve_adt_pattern(self: TypeChecker, pattern: Value, scrutinee_type: TypeExpr): AdtPatternResolution =
  var head = NIL
  case pattern.kind
  of VkSymbol, VkComplexSymbol:
    head = pattern
  of VkGene:
    if pattern.gene == nil:
      return
    head = pattern.gene.`type`
    for child in pattern.gene.children:
      if child.kind != VkSymbol:
        let label =
          if head.kind == VkComplexSymbol and head.is_simple_qualified_adt_pattern_head(): head.qualified_adt_pattern_name()
          elif head.kind == VkSymbol: head.str
          else: $head
        self.warn("enum pattern " & label & " binding must be a symbol")
        return
      result.bindings.add(child.str)
  else:
    return

  if head.kind == VkComplexSymbol and head.is_simple_qualified_adt_pattern_head():
    let parts = head.ref.csymbol
    let qualified_name = head.qualified_adt_pattern_name()
    let resolved = self.find_qualified_adt_variant(parts[0], parts[1])
    if not resolved.found:
      self.warn("enum pattern " & qualified_name & " references unknown enum or variant")
      return
    result.matched = true
    result.adt = resolved.adt
    result.variant = resolved.variant
  elif head.kind == VkSymbol:
    let ctor = head.str
    if ctor.len == 0 or ctor == "_":
      return

    let scrutinee_adt_name = self.static_adt_name_for_type(scrutinee_type)
    if scrutinee_adt_name.len > 0:
      let resolved = self.find_qualified_adt_variant(scrutinee_adt_name, ctor)
      if resolved.found:
        result.matched = true
        result.adt = resolved.adt
        result.variant = resolved.variant
      else:
        return
    else:
      let builtin_adt_name = builtin_adt_name_for_variant(ctor)
      if builtin_adt_name.len > 0:
        let builtin = self.find_qualified_adt_variant(builtin_adt_name, ctor)
        if builtin.found:
          result.matched = true
          result.adt = builtin.adt
          result.variant = builtin.variant
      if not result.matched:
        let candidates = self.adt_variant_candidates_by_name(ctor)
        if candidates.len == 1:
          result.matched = true
          result.adt = candidates[0].adt
          result.variant = candidates[0].variant
        elif candidates.len > 1:
          var qualified: seq[string] = @[]
          for candidate in candidates:
            qualified.add(adt_variant_qualified_name(candidate.adt, candidate.variant))
          self.warn("variant " & ctor & " is ambiguous; use " & qualified.join(" or "))
          return
  else:
    return

  if result.matched and result.bindings.len != result.variant.field_count:
    self.warn(adt_pattern_binding_message(result.adt, result.variant, result.bindings.len))

proc add_unique_string(items: var seq[string], value: string) =
  if value.len == 0:
    return
  for existing in items:
    if existing == value:
      return
  items.add(value)

proc subtract_narrowed_type(self: TypeChecker, original: TypeExpr, removed: TypeExpr): TypeExpr =
  ## Compute a conservative else-branch type after removing a narrowed member.
  ## If subtraction is unclear, keep the original type (gradual-safe fallback).
  let ro = self.resolve(original)
  let rr = self.resolve(removed)
  if ro == nil or rr == nil:
    return original

  if ro.kind == TkUnion:
    var keep: seq[TypeExpr] = @[]
    for member in ro.members:
      let rm = self.resolve(member)
      if rm == nil:
        keep.add(member)
      elif not self.same_type(rm, rr):
        keep.add(rm)
    if keep.len == 0:
      return ANY_TYPE
    if keep.len == 1:
      return keep[0]
    return TypeExpr(kind: TkUnion, members: keep)

  if self.same_type(ro, rr):
    return ANY_TYPE

  return ro

proc check_conditional_branches(self: TypeChecker, cond: Value,
                                then_expr: Value, has_else: bool,
                                else_expr: Value): TypeExpr =
  discard self.check_expr(cond)
  # Allow any truthy/falsy value in conditions (runtime to_bool handles coercion)

  let guard = self.extract_type_guard(cond)
  let has_guard = guard.found
  let original_guard_type = if has_guard: self.lookup(guard.name) else: nil

  self.push_scope()
  if has_guard:
    let narrowed =
      if guard.negated and original_guard_type != nil:
        self.subtract_narrowed_type(original_guard_type, guard.guarded_type)
      else:
        guard.guarded_type
    self.define(guard.name, narrowed)
  let then_type = self.check_expr(then_expr)
  self.pop_scope()

  if has_else:
    self.push_scope()
    if has_guard:
      let narrowed_else =
        if guard.negated:
          guard.guarded_type
        elif original_guard_type != nil:
          self.subtract_narrowed_type(original_guard_type, guard.guarded_type)
        else:
          nil
      if narrowed_else != nil:
        self.define(guard.name, narrowed_else)
    let else_type = self.check_expr(else_expr)
    self.pop_scope()
    try:
      self.unify(then_type, else_type, "if")
      return then_type
    except CatchableError:
      return TypeExpr(kind: TkUnion, members: @[then_type, else_type])
  return then_type

proc check_if(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len < 2:
    return ANY_TYPE

  let cond = gene.children[0]
  var then_items: seq[Value] = @[]
  var else_items: seq[Value] = @[]
  var in_else = false

  for i in 1..<gene.children.len:
    let item = gene.children[i]
    if item.kind == VkSymbol:
      let kw = item.str
      if kw == "then":
        continue
      if kw == "else":
        in_else = true
        continue
    if in_else:
      else_items.add(item)
    else:
      then_items.add(item)

  proc branch_expr(items: seq[Value]): Value =
    if items.len == 0:
      return NIL
    if items.len == 1:
      return items[0]
    let g = new_gene("do".to_symbol_value())
    for item in items:
      g.children.add(item)
    return g.to_gene_value()

  if then_items.len == 0:
    then_items.add(NIL)

  let then_expr = branch_expr(then_items)
  let has_else = else_items.len > 0
  let else_expr = if has_else: branch_expr(else_items) else: NIL

  self.check_conditional_branches(cond, then_expr, has_else, else_expr)

proc check_ifel(self: TypeChecker, gene: ptr Gene): TypeExpr =
  case gene.children.len
  of 0:
    not_allowed("ifel: missing condition")
  of 1:
    not_allowed("ifel: missing body after condition")
  of 2, 3:
    discard
  else:
    not_allowed("ifel: expected condition, then expression, and optional else expression")

  let cond = gene.children[0]
  let then_expr = gene.children[1]
  let has_else = gene.children.len == 3
  let else_expr = if has_else: gene.children[2] else: NIL

  self.check_conditional_branches(cond, then_expr, has_else, else_expr)

proc is_infix_special_form(expr_type: Value): bool {.inline.} =
  expr_type.kind == VkSymbol and expr_type.str in [
    "var", "if", "ifel", "fn", "do", "loop", "while", "for", "ns", "class",
    "try", "throw", "import", "export", "interface", "implement", "field", "comptime", "type", "enum",
    "object", "$", ".", "->", "@"
  ]

proc check_do(self: TypeChecker, gene: ptr Gene): TypeExpr =
  var last: TypeExpr = ANY_TYPE
  for child in gene.children:
    last = self.check_expr(child)
  return last

proc check_return(self: TypeChecker, gene: ptr Gene): TypeExpr =
  let ret_type =
    if gene.children.len > 0:
      self.check_expr(gene.children[0])
    else:
      TypeExpr(kind: TkNamed, name: "Nil")
  if self.current_return != nil:
    if self.strict:
      self.unify(self.current_return, ret_type, "return")
    else:
      try:
        self.unify(self.current_return, ret_type, "return")
      except CatchableError as e:
        self.warn("Warning: " & e.msg)
  return ret_type

proc check_case(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check case expression: (case x when (Ok v) body1 when None body2)
  ## Supports normalized form in props and direct source form in children.

  let target_key = CASE_TARGET_KEY.to_key()
  let when_key = CASE_WHEN_KEY.to_key()
  let else_key = CASE_ELSE_KEY.to_key()

  var target = NIL
  var when_pairs: seq[tuple[pattern: Value, body: Value]] = @[]
  var else_body = NIL
  var has_explicit_else = false
  var has_catch_all = false

  proc branch_expr(items: seq[Value]): Value =
    if items.len == 0:
      return NIL
    if items.len == 1:
      return items[0]
    let g = new_gene("do".to_symbol_value())
    for item in items:
      g.children.add(item)
    return g.to_gene_value()

  proc body_expr(value: Value): Value =
    if value.kind == VkStream and value.ref != nil:
      return branch_expr(value.ref.stream)
    return value

  proc is_normalized_default_else(value: Value): bool =
    if value == NIL:
      return true
    if value.kind == VkStream and value.ref != nil:
      let items = value.ref.stream
      return items.len == 1 and items[0] == NIL
    return false

  proc is_wildcard_pattern(value: Value): bool =
    value.kind == VkSymbol and value.str == "_"

  if gene.props.hasKey(target_key):
    target = gene.props[target_key]
    let whens = gene.props.getOrDefault(when_key, NIL)
    if whens.kind == VkArray:
      let arr = array_data(whens)
      var i = 0
      while i + 1 < arr.len:
        when_pairs.add((arr[i], body_expr(arr[i + 1])))
        i += 2
    let raw_else = gene.props.getOrDefault(else_key, NIL)
    else_body = body_expr(raw_else)
    has_explicit_else = not is_normalized_default_else(raw_else)
  elif gene.children.len > 0:
    target = gene.children[0]
    var i = 1
    while i < gene.children.len:
      let token = gene.children[i]
      if token.kind == VkSymbol and token.str == "when":
        if i + 1 >= gene.children.len:
          break
        let when_value = gene.children[i + 1]
        i += 2
        var body_items: seq[Value] = @[]
        while i < gene.children.len:
          let next = gene.children[i]
          if next.kind == VkSymbol and (next.str == "when" or next.str == "else"):
            break
          body_items.add(next)
          i.inc()
        when_pairs.add((when_value, branch_expr(body_items)))
        continue
      if token.kind == VkSymbol and token.str == "else":
        has_explicit_else = true
        i.inc()
        var else_items: seq[Value] = @[]
        while i < gene.children.len:
          else_items.add(gene.children[i])
          i.inc()
        else_body = branch_expr(else_items)
        break
      i.inc()

  if target == NIL:
    return ANY_TYPE

  let scrutinee_type = self.check_expr(target)
  let scrutinee_adt_name = self.static_adt_name_for_type(scrutinee_type)
  let scrutinee_name =
    if target.kind == VkSymbol and target.str != "_":
      target.str
    else:
      ""
  var matched_adt_names: seq[string] = @[]
  var covered_variants = initTable[string, bool]()
  var result_type: TypeExpr = nil

  for pair in when_pairs:
    let when_value = pair.pattern
    let when_body = pair.body
    var adt_pattern = AdtPatternResolution()

    if is_wildcard_pattern(when_value):
      has_catch_all = true
    else:
      adt_pattern = self.resolve_adt_pattern(when_value, scrutinee_type)

    if adt_pattern.matched:
      add_unique_string(matched_adt_names, adt_pattern.adt.name)
      if scrutinee_adt_name.len > 0 and adt_pattern.adt.name == scrutinee_adt_name:
        covered_variants[adt_pattern.variant.name] = true

    self.push_scope()
    if adt_pattern.matched and scrutinee_name.len > 0:
      self.define(scrutinee_name, self.narrow_type_to_adt(scrutinee_type, adt_pattern.adt.name))

    if adt_pattern.matched:
      for binding_index, bound_name in adt_pattern.bindings:
        if bound_name.len == 0 or bound_name == "_":
          continue
        ensure_user_value_name(bound_name, "case pattern binding")
        let bound_type = self.adt_field_binding_type(scrutinee_type, adt_pattern.adt, adt_pattern.variant, binding_index)
        self.define(bound_name, bound_type)

    let body_type = self.check_expr(when_body)
    self.pop_scope()

    if result_type == nil:
      result_type = body_type
    else:
      try:
        self.unify(result_type, body_type, "case")
      except CatchableError:
        result_type = TypeExpr(kind: TkUnion, members: @[result_type, body_type])

  # Process else clause only when the source contained an explicit catch-all.
  # Normalized compiler forms synthesize an implicit nil else; that must not
  # suppress enum exhaustiveness diagnostics in the type checker.
  if has_explicit_else:
    self.push_scope()
    if scrutinee_name.len > 0 and matched_adt_names.len > 0:
      var remaining = scrutinee_type
      for adt_name in matched_adt_names:
        remaining = self.subtract_adt_type(remaining, adt_name)
      self.define(scrutinee_name, remaining)
    let else_type = self.check_expr(else_body)
    self.pop_scope()
    if result_type == nil:
      result_type = else_type
    else:
      try:
        self.unify(result_type, else_type, "case else")
      except CatchableError:
        result_type = TypeExpr(kind: TkUnion, members: @[result_type, else_type])

  if scrutinee_adt_name.len > 0 and not has_explicit_else and not has_catch_all:
    let adt = self.adts[scrutinee_adt_name]
    var missing: seq[string] = @[]
    for variant_name in adt.variant_order:
      if not covered_variants.hasKey(variant_name):
        missing.add(variant_name)
    if missing.len > 0:
      self.warn("non-exhaustive case over " & scrutinee_adt_name & "; missing variants: " & missing.join(", "))

  if result_type == nil:
    return ANY_TYPE
  return result_type

proc check_for(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check for loop:
  ##   (for x in collection body...)
  ##   (for i x in collection body...)
  ##   (for k [a b] in collection body...)
  if gene.children.len < 3:
    return ANY_TYPE

  # Find the 'in' keyword position
  var in_pos = -1
  for i in 0..<min(gene.children.len, 4):
    if gene.children[i].kind == VkSymbol and gene.children[i].str == "in":
      in_pos = i
      break

  if in_pos < 1 or in_pos + 1 >= gene.children.len:
    return ANY_TYPE

  proc report_for_type_error(msg: string) =
    let full = "Type error: " & msg
    if self.strict:
      raise new_exception(types.Exception, full)
    self.warn("Warning: " & full)

  var index_name = ""
  var value_pattern: Value = NIL

  case in_pos
  of 1:
    # (for x in ...) or (for [a b] in ...) or (for {^x x} in ...)
    let var_node = gene.children[0]
    case var_node.kind
    of VkSymbol:
      value_pattern = var_node
    of VkArray, VkMap:
      value_pattern = var_node
    else:
      report_for_type_error("for loop variable must be a symbol or destructuring pattern")
      return ANY_TYPE
  of 2:
    # (for i x in ...) or (for k [a b] in ...)
    let key_node = gene.children[0]
    let val_node = gene.children[1]
    if key_node.kind != VkSymbol:
      report_for_type_error("for loop index/key binding must be a symbol")
      return ANY_TYPE
    if val_node.kind notin {VkSymbol, VkArray, VkMap}:
      report_for_type_error("for loop value binding must be a symbol or destructuring pattern")
      return ANY_TYPE
    index_name = key_node.str
    value_pattern = val_node
  else:
    return ANY_TYPE

  let collection = gene.children[in_pos + 1]
  let body_start = in_pos + 2
  let collection_type = self.check_expr(collection)

  self.push_scope()

  # Infer element type from collection
  let ct = self.resolve(collection_type)
  var elem_type = ANY_TYPE
  var key_type = TypeExpr(kind: TkNamed, name: "Int")
  if ct.kind == TkApplied:
    if ct.ctor == "Array" and ct.args.len > 0:
      elem_type = ct.args[0]
    elif ct.ctor == "Map" and ct.args.len > 1:
      key_type = ct.args[0]
      elem_type = ct.args[1]
    elif ct.ctor == "HashMap" and ct.args.len > 1:
      key_type = ct.args[0]
      elem_type = ct.args[1]
    elif ct.ctor == "HashSet" and ct.args.len > 0:
      elem_type = ct.args[0]

  if index_name.len > 0 and index_name != "_":
    self.define(index_name, key_type)

  case value_pattern.kind
  of VkSymbol:
    let var_name = value_pattern.str
    if var_name != "_":
      self.define(var_name, elem_type)
  of VkArray, VkMap:
    self.define_pattern_bindings(value_pattern, elem_type)
  else:
    discard

  # Check body
  for i in body_start..<gene.children.len:
    discard self.check_expr(gene.children[i])

  self.pop_scope()
  return TypeExpr(kind: TkNamed, name: "Nil")

proc check_while(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check while loop: (while cond body...)
  if gene.children.len < 1:
    return ANY_TYPE

  let cond_type = self.check_expr(gene.children[0])
  if cond_type.kind != TkAny:
    self.unify(TypeExpr(kind: TkNamed, name: "Bool"), cond_type, "while condition")

  self.push_scope()
  for i in 1..<gene.children.len:
    discard self.check_expr(gene.children[i])
  self.pop_scope()

  return TypeExpr(kind: TkNamed, name: "Nil")

proc check_loop(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check loop: (loop body...)
  ## Loop can return a value via (break value)
  self.push_scope()
  for child in gene.children:
    discard self.check_expr(child)
  self.pop_scope()
  # Loop returns Any since break can return any value
  return ANY_TYPE

proc check_try(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check try/catch/finally:
  ## (try body... catch pattern handler... catch pattern handler... finally ...)
  var try_type: TypeExpr = ANY_TYPE
  var catch_types: seq[TypeExpr] = @[]

  var first_handler_idx = gene.children.len
  for i, child in gene.children:
    if child.kind == VkSymbol and (child.str == "catch" or child.str == "finally"):
      first_handler_idx = i
      break

  if first_handler_idx > 0:
    for i in 0..<first_handler_idx:
      try_type = self.check_expr(gene.children[i])

  var i = first_handler_idx
  while i < gene.children.len:
    let child = gene.children[i]
    if child.kind == VkSymbol and child.str == "catch":
      inc i
      if i >= gene.children.len:
        break

      let pattern = gene.children[i]
      inc i
      let body_start = i
      while i < gene.children.len:
        let candidate = gene.children[i]
        if candidate.kind == VkSymbol and (candidate.str == "catch" or candidate.str == "finally"):
          break
        inc i

      self.push_scope()
      self.define("$ex", ANY_TYPE)

      if pattern.kind == VkSymbol:
        let name = pattern.str
        if name.len > 0 and name != "*" and name != "_" and name[0].isLowerAscii():
          self.define(name, ANY_TYPE)
      elif pattern.kind in {VkArray, VkMap}:
        self.define_pattern_bindings(pattern, ANY_TYPE)
      else:
        discard self.check_expr(pattern)

      var clause_type: TypeExpr = TypeExpr(kind: TkNamed, name: "Nil")
      for j in body_start..<i:
        clause_type = self.check_expr(gene.children[j])
      self.pop_scope()
      catch_types.add(clause_type)
    elif child.kind == VkSymbol and child.str == "finally":
      inc i
      self.push_scope()
      while i < gene.children.len:
        discard self.check_expr(gene.children[i])
        inc i
      self.pop_scope()
    else:
      inc i

  for ct in catch_types:
    try:
      self.unify(try_type, ct, "try/catch")
    except CatchableError:
      try_type = TypeExpr(kind: TkUnion, members: @[try_type, ct])

  return try_type

proc check_question_op(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check ? operator for Result/Option propagation
  ## (expr)? extracts Ok/Some value or returns early with Err/None
  if gene.children.len == 0:
    return ANY_TYPE

  let inner_type = self.check_expr(gene.children[0])
  let rt = self.resolve(inner_type)

  # For Result[T, E], returns T (or propagates Err[E])
  # For Option[T], returns T (or propagates None)
  if rt.kind == TkApplied:
    if rt.ctor == "Result" and rt.args.len >= 1:
      return rt.args[0]
    elif rt.ctor == "Option" and rt.args.len >= 1:
      return rt.args[0]

  return ANY_TYPE

proc check_infix(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    return ANY_TYPE
  let op = gene.children[0]
  if op.kind != VkSymbol:
    return ANY_TYPE

  if op.str == "?":
    # Postfix ? for error propagation: (expr ?)
    if gene.children.len != 1:
      return ANY_TYPE
    let left_type = self.check_expr(gene.`type`)
    let rt = self.resolve(left_type)
    if rt.kind == TkApplied:
      if rt.ctor == "Result" and rt.args.len >= 1:
        return rt.args[0]
      elif rt.ctor == "Option" and rt.args.len >= 1:
        return rt.args[0]
    return ANY_TYPE

  if gene.children.len < 2:
    return ANY_TYPE

  if op.str == "=" and gene.`type`.kind in {VkArray, VkMap}:
    let msg = "Type error: destructuring assignment has been removed; use (var pattern value)"
    if self.strict:
      raise new_exception(types.Exception, msg)
    self.warn("Warning: " & msg)
    discard self.check_expr(gene.children[1])
    return ANY_TYPE

  let left_type = self.check_expr(gene.`type`)
  let right_type = self.check_expr(gene.children[1])
  case op.str
  of "+", "-", "*", "/", "%":
    # numeric only (Int/Float)
    let left_res = self.resolve(left_type)
    let right_res = self.resolve(right_type)
    let want_float =
      (left_res.kind == TkNamed and left_res.name == "Float") or
      (right_res.kind == TkNamed and right_res.name == "Float")
    if want_float:
      if left_type.kind != TkAny:
        if self.strict:
          self.unify(TypeExpr(kind: TkNamed, name: "Float"), left_type, op.str)
        else:
          try: self.unify(TypeExpr(kind: TkNamed, name: "Float"), left_type, op.str)
          except CatchableError as e: self.warn("Warning: " & e.msg)
      if right_type.kind != TkAny:
        if self.strict:
          self.unify(TypeExpr(kind: TkNamed, name: "Float"), right_type, op.str)
        else:
          try: self.unify(TypeExpr(kind: TkNamed, name: "Float"), right_type, op.str)
          except CatchableError as e: self.warn("Warning: " & e.msg)
      return TypeExpr(kind: TkNamed, name: "Float")
    if left_type.kind != TkAny:
      if self.strict:
        self.unify(TypeExpr(kind: TkNamed, name: "Int"), left_type, op.str)
      else:
        try: self.unify(TypeExpr(kind: TkNamed, name: "Int"), left_type, op.str)
        except CatchableError as e: self.warn("Warning: " & e.msg)
    if right_type.kind != TkAny:
      if self.strict:
        self.unify(TypeExpr(kind: TkNamed, name: "Int"), right_type, op.str)
      else:
        try: self.unify(TypeExpr(kind: TkNamed, name: "Int"), right_type, op.str)
        except CatchableError as e: self.warn("Warning: " & e.msg)
    return TypeExpr(kind: TkNamed, name: "Int")
  of "++":
    if left_type.kind != TkAny:
      if self.strict:
        self.unify(TypeExpr(kind: TkNamed, name: "String"), left_type, "++")
      else:
        try: self.unify(TypeExpr(kind: TkNamed, name: "String"), left_type, "++")
        except CatchableError as e: self.warn("Warning: " & e.msg)
    if right_type.kind != TkAny:
      if self.strict:
        self.unify(TypeExpr(kind: TkNamed, name: "String"), right_type, "++")
      else:
        try: self.unify(TypeExpr(kind: TkNamed, name: "String"), right_type, "++")
        except CatchableError as e: self.warn("Warning: " & e.msg)
    return TypeExpr(kind: TkNamed, name: "String")
  of "==", "!=", "<", "<=", ">", ">=":
    return TypeExpr(kind: TkNamed, name: "Bool")
  of "&&", "||":
    return TypeExpr(kind: TkNamed, name: "Bool")
  of "=":
    # Assignment
    if self.strict:
      self.unify(left_type, right_type, "=")
    else:
      try:
        self.unify(left_type, right_type, "=")
      except CatchableError as e:
        self.warn("Warning: " & e.msg)
    return left_type
  of "+=", "-=", "*=", "/=", "%=":
    # Compound assignment - type is same as left operand
    return left_type
  of "is":
    # (x is Type) returns Bool
    return TypeExpr(kind: TkNamed, name: "Bool")
  else:
    return ANY_TYPE

proc check_fn(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    return ANY_TYPE
  var name = "<unnamed>"
  var type_params: seq[string] = @[]
  var args_val: Value = NIL
  var body_start = 1
  let first = gene.children[0]
  if first.kind == VkArray:
    args_val = first
    body_start = 1
  elif first.kind in {VkSymbol, VkString}:
    let parsed_name = split_generic_definition_name(first.str)
    name = parsed_name.base_name
    ensure_user_value_name(name, "function")
    type_params = parsed_name.type_params
    if gene.children.len < 2:
      return ANY_TYPE
    args_val = gene.children[1]
    body_start = 2
  elif first.kind == VkComplexSymbol:
    let parts = first.ref.csymbol
    if parts.len > 0:
      name = parts[^1]
      ensure_user_value_name(name, "function")
    if gene.children.len < 2:
      return ANY_TYPE
    args_val = gene.children[1]
    body_start = 2
  else:
    return ANY_TYPE

  if type_params.len > 0:
    self.push_type_param_scope(type_params)
    defer: self.pop_type_param_scope()

  # Handle optional return type: (-> Type)
  var return_type: TypeExpr = ANY_TYPE
  if body_start < gene.children.len:
    let maybe_arrow = gene.children[body_start]
    if maybe_arrow.kind == VkSymbol and maybe_arrow.str == "->":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing return type after ->")
      return_type = self.parse_type_expr(gene.children[body_start + 1])
      body_start += 2

  # Handle optional effects: (! [Effect ...])
  var effects: seq[string] = @[]
  if body_start < gene.children.len:
    let maybe_bang = gene.children[body_start]
    if maybe_bang.kind == VkSymbol and maybe_bang.str == "!":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing effects list after !")
      effects = self.parse_effect_list(gene.children[body_start + 1])
      body_start += 2

  let params = self.parse_param_annotations(args_val, allow_reserved_self = name == "__init__")
  var fn_params: seq[ParamType] = @[]
  for param in params:
    fn_params.add(public_param(param))

  # Build function type and define in OUTER scope first
  let fn_type = TypeExpr(kind: TkFn, params: fn_params, ret: return_type, receiver: nil, effects: effects)
  if name.len > 0 and name != "<unnamed>":
    self.define(name, fn_type)

  # Now push scope for function body and define parameters
  self.push_scope()
  if name == "__init__":
    let init_self = self.current_init_self()
    let self_type = if init_self != nil: init_self else: TypeExpr(kind: TkNamed, name: "Module")
    self.define_internal("self", self_type)
  for param in params:
    if param.binding_name.len > 0 and param.binding_name != "_":
      self.define(param.binding_name, param_binding_type(param))

  # Also define function name in inner scope for recursion
  if name.len > 0 and name != "<unnamed>":
    self.define(name, fn_type)

  let saved_return = self.current_return
  self.current_return = return_type
  self.effect_stack.add(effects)
  defer:
    discard self.effect_stack.pop()
  var last: TypeExpr = TypeExpr(kind: TkNamed, name: "Nil")
  for i in body_start..<gene.children.len:
    last = self.check_expr(gene.children[i])
  # If no explicit return type, allow inferred last expr
  if return_type != ANY_TYPE and return_type != nil:
    if self.strict:
      self.unify(return_type, last, "fn " & name)
    else:
      try:
        self.unify(return_type, last, "fn " & name)
      except CatchableError as e:
        self.warn("Warning: " & e.msg)
  self.current_return = saved_return
  self.pop_scope()
  return fn_type

proc check_block(self: TypeChecker, gene: ptr Gene): TypeExpr =
  ## Type check a block expression: (block [params] body...)
  var body_start = 0
  var args_val: Value = NIL

  # Check if first child is an array (parameters)
  if gene.children.len > 0 and gene.children[0].kind == VkArray:
    args_val = gene.children[0]
    body_start = 1

  let params = self.parse_param_annotations(args_val)
  var fn_params: seq[ParamType] = @[]

  for param in params:
    fn_params.add(public_param(param))

  # Push scope for block body and define parameters
  self.push_scope()
  for param in params:
    if param.binding_name.len > 0 and param.binding_name != "_":
      self.define(param.binding_name, param_binding_type(param))

  # Type-check body
  let effects: seq[string] = @[]
  self.effect_stack.add(effects)
  defer:
    discard self.effect_stack.pop()
  var last: TypeExpr = TypeExpr(kind: TkNamed, name: "Nil")
  for i in body_start..<gene.children.len:
    last = self.check_expr(gene.children[i])

  self.pop_scope()

  # Block returns a function type
  return TypeExpr(kind: TkFn, params: fn_params, ret: last, receiver: nil, effects: effects)

proc check_ctor(self: TypeChecker, gene: ptr Gene, class_name: string, cls: ClassInfo): TypeExpr =
  if gene.type.kind == VkSymbol and gene.type.str == "ctor!":
    raise new_exception(types.Exception, "Macro-like constructors are not supported; use (ctor [args] ...)")
  if gene.children.len == 0:
    return ANY_TYPE
  let args_val = gene.children[0]
  if args_val.kind != VkArray:
    raise new_exception(types.Exception, "Constructor requires an array argument list; use [] for no arguments")
  var body_start = 1
  var return_type: TypeExpr = TypeExpr(kind: TkNamed, name: class_name)
  if body_start < gene.children.len:
    let maybe_arrow = gene.children[body_start]
    if maybe_arrow.kind == VkSymbol and maybe_arrow.str == "->":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing return type after ->")
      return_type = self.parse_type_expr(gene.children[body_start + 1])
      body_start += 2

  # Optional effects for constructors
  var effects: seq[string] = @[]
  if body_start < gene.children.len:
    let maybe_bang = gene.children[body_start]
    if maybe_bang.kind == VkSymbol and maybe_bang.str == "!":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing effects list after !")
      effects = self.parse_effect_list(gene.children[body_start + 1])
      body_start += 2

  let saved_class = self.current_class
  self.current_class = class_name
  defer: self.current_class = saved_class
  let params = self.parse_param_annotations(args_val)
  var fn_params: seq[ParamType] = @[]
  self.push_scope()
  for param in params:
    fn_params.add(public_param(param))
    if param.binding_name.len > 0 and param.binding_name != "_":
      self.define(param.binding_name, param_binding_type(param))

  let fn_type = TypeExpr(kind: TkFn, params: fn_params, ret: return_type, receiver: nil, effects: effects)
  cls.ctor_type = fn_type

  let saved_return = self.current_return
  self.current_return = return_type
  self.effect_stack.add(effects)
  defer:
    discard self.effect_stack.pop()
  var last: TypeExpr = TypeExpr(kind: TkNamed, name: "Nil")
  for i in body_start..<gene.children.len:
    last = self.check_expr(gene.children[i])
  if return_type != ANY_TYPE and return_type != nil:
    if self.strict:
      self.unify(return_type, last, "ctor " & class_name)
    else:
      try:
        self.unify(return_type, last, "ctor " & class_name)
      except CatchableError as e:
        self.warn("Warning: " & e.msg)
  self.current_return = saved_return
  self.pop_scope()
  return fn_type

proc check_field_decl(self: TypeChecker, gene: ptr Gene, fields: var Table[string, TypeExpr]) =
  if gene.children.len == 0:
    raise new_exception(types.Exception, "field requires a name and type")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    raise new_exception(types.Exception, "field name must be a symbol")
  var field_name = name_val.str
  if field_name.endsWith(":"):
    field_name = field_name[0..^2]
  ensure_user_value_name(field_name, "field")
  let field_type =
    if gene.children.len > 1: self.parse_type_expr(gene.children[1])
    else: ANY_TYPE
  fields[field_name] = field_type

proc check_prop_decl(self: TypeChecker, gene: ptr Gene, fields: var Table[string, TypeExpr]) =
  if gene.children.len == 0:
    raise new_exception(types.Exception, "prop requires a name")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    raise new_exception(types.Exception, "prop name must be a symbol")

  var field_name = name_val.str
  var field_type: TypeExpr = ANY_TYPE
  if field_name.endsWith(":"):
    field_name = field_name[0..^2]
    if gene.children.len > 1:
      field_type = self.parse_type_expr(gene.children[1])
  elif gene.children.len > 1:
    field_type = self.parse_type_expr(gene.children[1])

  ensure_user_value_name(field_name, "field")
  fields[field_name] = field_type

proc check_method(self: TypeChecker, gene: ptr Gene, class_name: string, cls: ClassInfo): TypeExpr =
  if gene.children.len < 2:
    return ANY_TYPE
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    return ANY_TYPE
  let parsed_name = split_generic_definition_name(name_val.str)
  let method_name = parsed_name.base_name
  ensure_user_value_name(method_name, "method")
  if method_name.ends_with("!"):
    raise new_exception(types.Exception, "Macro-like class methods are not supported; use (method name [args] ...)")
  let type_params = parsed_name.type_params
  let args_val = gene.children[1]
  if args_val.kind != VkArray:
    raise new_exception(types.Exception, "Method requires an array argument list; use [] for no arguments")
  var body_start = 2
  if type_params.len > 0:
    self.push_type_param_scope(type_params)
    defer: self.pop_type_param_scope()
  let saved_class = self.current_class
  self.current_class = class_name
  defer: self.current_class = saved_class
  var return_type: TypeExpr = ANY_TYPE
  if body_start < gene.children.len:
    let maybe_arrow = gene.children[body_start]
    if maybe_arrow.kind == VkSymbol and maybe_arrow.str == "->":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing return type after ->")
      return_type = self.parse_type_expr(gene.children[body_start + 1])
      body_start += 2

  # Optional effects for methods
  var effects: seq[string] = @[]
  if body_start < gene.children.len:
    let maybe_bang = gene.children[body_start]
    if maybe_bang.kind == VkSymbol and maybe_bang.str == "!":
      if body_start + 1 >= gene.children.len:
        raise new_exception(types.Exception, "Missing effects list after !")
      effects = self.parse_effect_list(gene.children[body_start + 1])
      body_start += 2

  let params = self.parse_param_annotations(args_val)
  for param in params:
    if param.binding_name == "_" or param.binding_name.len == 0:
      raise new_exception(types.Exception, "method parameters must be named")
    if param.typ == nil and param.binding_name.len > 0 and param.binding_name[0].isUpperAscii:
      raise new_exception(types.Exception, "method parameters must use names; omitted types default to Any")
  var fn_params: seq[ParamType] = @[]
  self.push_scope()
  self.define_internal("self", TypeExpr(kind: TkNamed, name: class_name))
  for param in params:
    fn_params.add(public_param(param))
    if param.binding_name.len > 0 and param.binding_name != "_":
      self.define(param.binding_name, param_binding_type(param))

  let fn_type = TypeExpr(
    kind: TkFn,
    params: fn_params,
    ret: return_type,
    receiver: TypeExpr(kind: TkNamed, name: "Self"),
    effects: effects
  )
  cls.methods[method_name] = fn_type

  let has_body = body_start < gene.children.len
  if not has_body:
    self.pop_scope()
    return fn_type

  let saved_return = self.current_return
  self.current_return = return_type
  self.effect_stack.add(effects)
  defer:
    discard self.effect_stack.pop()
  var last: TypeExpr = TypeExpr(kind: TkNamed, name: "Nil")
  for i in body_start..<gene.children.len:
    last = self.check_expr(gene.children[i])
  if return_type != ANY_TYPE and return_type != nil:
    if self.strict:
      self.unify(return_type, last, "method " & class_name & "." & method_name)
    else:
      try:
        self.unify(return_type, last, "method " & class_name & "." & method_name)
      except CatchableError as e:
        self.warn("Warning: " & e.msg)
  self.current_return = saved_return
  self.pop_scope()
  return fn_type

proc check_interface(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    raise new_exception(types.Exception, "interface requires a name")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    raise new_exception(types.Exception, "interface name must be a symbol")
  let interface_name = name_val.str
  ensure_user_type_name(interface_name, "interface")
  var iface = InterfaceInfo(
    name: interface_name,
    fields: initTable[string, TypeExpr](),
    methods: initTable[string, TypeExpr]()
  )
  self.interfaces[interface_name] = iface

  let saved_class = self.current_class
  self.current_class = interface_name
  defer: self.current_class = saved_class

  for i in 1..<gene.children.len:
    let child = gene.children[i]
    if child.kind != VkGene or child.gene == nil or child.gene.`type`.kind != VkSymbol:
      raise new_exception(types.Exception, "interface body only supports field and method declarations")
    case child.gene.`type`.str
    of "field":
      self.check_field_decl(child.gene, iface.fields)
    of "method":
      if child.gene.children.len < 2:
        raise new_exception(types.Exception, "interface method requires a name and parameter list")
      let method_name_val = child.gene.children[0]
      if method_name_val.kind != VkSymbol:
        raise new_exception(types.Exception, "interface method name must be a symbol")
      let method_name = split_generic_definition_name(method_name_val.str).base_name
      let temp_class = ClassInfo(name: interface_name, parent: "", fields: iface.fields, methods: iface.methods, ctor_type: nil, interfaces: @[])
      let method_type = self.check_method(child.gene, interface_name, temp_class)
      if child.gene.children.len > 0:
        var idx = 2
        if idx < child.gene.children.len and child.gene.children[idx].kind == VkSymbol and child.gene.children[idx].str == "->":
          idx += 2
        if idx < child.gene.children.len and child.gene.children[idx].kind == VkSymbol and child.gene.children[idx].str == "!":
          idx += 2
        if idx < child.gene.children.len:
          raise new_exception(types.Exception, "interface methods cannot have a body")
      iface.methods[method_name] = method_type
    of "prop":
      self.warn("Warning: interface prop is deprecated; use field")
      self.check_prop_decl(child.gene, iface.fields)
    else:
      raise new_exception(types.Exception, "unsupported interface member: " & child.gene.`type`.str)

  return TypeExpr(kind: TkNamed, name: interface_name)

proc check_class(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    return ANY_TYPE
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    return ANY_TYPE
  let class_name = name_val.str
  ensure_user_type_name(class_name, "class")
  # Ensure every class declaration gets a stable descriptor entry.
  discard self.intern_type_desc(TypeExpr(kind: TkNamed, name: class_name))
  let saved_class = self.current_class
  self.current_class = class_name
  defer: self.current_class = saved_class
  let header = self.parse_class_header(gene)
  let body_start = header.body_start
  let parent_name = header.parent_name

  var cls = ClassInfo(
    name: class_name,
    parent: parent_name,
    fields: initTable[string, TypeExpr](),
    methods: initTable[string, TypeExpr](),
    interfaces: header.interfaces
  )

  # ^fields is optional - parse if provided
  if gene.props.hasKey("fields".to_key()):
    let fields_val = gene.props["fields".to_key()]
    if fields_val.kind == VkMap:
      for k, v in map_data(fields_val):
        let key_name = key_to_string(k)
        ensure_user_value_name(key_name, "field")
        let t = self.parse_type_expr(v)
        cls.fields[key_name] = t

  self.classes[class_name] = cls

  var init_items: seq[Value] = @[]
  for i in body_start..<gene.children.len:
    let child = gene.children[i]
    if child.kind == VkGene and child.gene != nil and child.gene.`type`.kind == VkSymbol:
      let k = child.gene.`type`.str
      if k == "method":
        discard self.check_method(child.gene, class_name, cls)
      elif k == "field":
        self.check_field_decl(child.gene, cls.fields)
      elif k == "on_method_missing":
        var lowered = new_gene("method".to_symbol_value())
        lowered.children.add("on_method_missing".to_symbol_value())
        for grandchild in child.gene.children:
          lowered.children.add(grandchild)
        discard self.check_method(lowered, class_name, cls)
      elif k == "ctor":
        discard self.check_ctor(child.gene, class_name, cls)
      elif k == "ctor!":
        raise new_exception(types.Exception, "Macro-like constructors are not supported; use (ctor [args] ...)")
      elif k == "implement":
        raise new_exception(types.Exception, "Classes must declare interfaces in the header with implements")
      elif k == "prop":
        self.warn("Warning: prop is deprecated; use field")
        self.check_prop_decl(child.gene, cls.fields)
      else:
        init_items.add(child)
    else:
      init_items.add(child)

  if init_items.len > 0:
    let class_self = TypeExpr(kind: TkNamed, name: "Class")
    self.push_scope()
    self.define_internal("self", class_self)
    self.init_self_stack.add(class_self)
    for item in init_items:
      discard self.check_expr(item)
    discard self.init_self_stack.pop()
    self.pop_scope()

  for interface_name in cls.interfaces:
    self.check_interface_conformance(cls, interface_name)

  return TypeExpr(kind: TkNamed, name: class_name)

proc check_ns(self: TypeChecker, gene: ptr Gene): TypeExpr =
  if gene.children.len == 0:
    return ANY_TYPE
  let name_val = gene.children[0]
  var ns_name = ""
  case name_val.kind
  of VkSymbol, VkString:
    ns_name = name_val.str
  of VkComplexSymbol:
    let parts = name_val.ref.csymbol
    if parts.len > 0:
      ns_name = parts[^1]
  else:
    discard

  let ns_type = TypeExpr(kind: TkNamed, name: "Namespace")
  if ns_name.len > 0:
    ensure_user_value_name(ns_name, "namespace")
    self.define(ns_name, ns_type)

  if gene.children.len > 1:
    self.push_scope()
    self.define_internal("self", ns_type)
    self.init_self_stack.add(ns_type)
    for i in 1..<gene.children.len:
      discard self.check_expr(gene.children[i])
    discard self.init_self_stack.pop()
    self.pop_scope()
  return ns_type

proc check_symbol(self: TypeChecker, sym: Value): TypeExpr =
  if sym.kind != VkSymbol:
    return ANY_TYPE
  let name = sym.str
  if name.len > 1 and name[0] == '/':
    let field_name = name[1..^1]
    var self_type = self.lookup("self")
    if self_type == nil:
      self_type = self.current_init_self()
    if self_type == nil and self.current_class.len > 0:
      self_type = TypeExpr(kind: TkNamed, name: self.current_class)
    let rt = self.resolve(self_type)
    if rt != nil and rt.kind == TkNamed and self.classes.hasKey(rt.name):
      let cls = self.classes[rt.name]
      let ft = self.find_field(cls, field_name)
      if ft != nil:
        return ft
      if cls.fields.len > 0:
        raise new_exception(types.Exception, "Unknown field: " & field_name & " on class " & rt.name)
    return ANY_TYPE
  if name == "self" and self.current_class.len > 0:
    return TypeExpr(kind: TkNamed, name: self.current_class)
  let t = self.lookup(name)
  if t != nil:
    return t
  return ANY_TYPE

proc check_complex_symbol(self: TypeChecker, sym: Value): TypeExpr =
  if sym.kind != VkComplexSymbol:
    return ANY_TYPE
  let parts = sym.ref.csymbol
  if parts.len == 0:
    return ANY_TYPE
  for part in parts:
    if part.startsWith("<") or part.startsWith(".<"):
      return ANY_TYPE
  var base_name = parts[0]
  if base_name == "":
    base_name = "self"
  var base_type = self.lookup(base_name)
  if base_type == nil and base_name == "self":
    base_type = self.current_init_self()
  if base_type == nil and base_name == "self" and self.current_class.len > 0:
    base_type = TypeExpr(kind: TkNamed, name: self.current_class)
  if parts.len == 2 and parts[1].startsWith("."):
    let method_name = parts[1][1..^1]
    return self.check_method_call(base_type, method_name, @[], initTable[Key, Value](), "method " & method_name)
  if parts.len == 2 and not parts[1].startsWith("."):
    let field_name = parts[1]
    let rt = self.resolve(base_type)
    if rt.kind == TkNamed and self.classes.hasKey(rt.name):
      let cls = self.classes[rt.name]
      let ft = self.find_field(cls, field_name)
      if ft != nil:
        return ft
      # If class declared fields with ^fields, accessing undeclared field is an error
      if cls.fields.len > 0:
        raise new_exception(types.Exception, "Unknown field: " & field_name & " on class " & rt.name)
      # Class has no declared fields - Gene allows dynamic fields, return Any
      return ANY_TYPE
  return ANY_TYPE

proc infer_map_value_type(self: TypeChecker, map_value: Value): TypeExpr =
  var inferred: TypeExpr = nil
  for _, item in map_data(map_value):
    let item_type = self.resolve(self.check_expr(item))
    if inferred == nil:
      inferred = item_type
    elif item_type.kind == TkVar or inferred.kind == TkVar:
      # Avoid over-constraining unresolved type variables in map literals.
      inferred = ANY_TYPE
    else:
      try:
        self.unify(inferred, item_type, "map")
      except CatchableError:
        inferred = ANY_TYPE

  if inferred == nil:
    return ANY_TYPE
  inferred

proc infer_hash_map_value_type(self: TypeChecker, hash_map_value: Value): TypeExpr =
  var inferred: TypeExpr = nil
  var i = 1
  let items = hash_map_items(hash_map_value)
  while i < items.len:
    let item_type = self.resolve(self.check_expr(items[i]))
    if inferred == nil:
      inferred = item_type
    elif item_type.kind == TkVar or inferred.kind == TkVar:
      inferred = ANY_TYPE
    else:
      try:
        self.unify(inferred, item_type, "hash_map")
      except CatchableError:
        inferred = ANY_TYPE
    i += 2

  if inferred == nil:
    return ANY_TYPE
  inferred

proc check_expr(self: TypeChecker, v: Value): TypeExpr =
  case v.kind
  of VkNil:
    return TypeExpr(kind: TkNamed, name: "Nil")
  of VkInt:
    return TypeExpr(kind: TkNamed, name: "Int")
  of VkFloat:
    return TypeExpr(kind: TkNamed, name: "Float")
  of VkBool:
    return TypeExpr(kind: TkNamed, name: "Bool")
  of VkString:
    return TypeExpr(kind: TkNamed, name: "String")
  of VkSymbol:
    return self.check_symbol(v)
  of VkComplexSymbol:
    return self.check_complex_symbol(v)
  of VkArray:
    # Infer array element type - be lenient with type variables to avoid
    # over-constraining (e.g., [x y] shouldn't force x and y to be same type)
    var elem_type: TypeExpr = nil
    for item in array_data(v):
      let t = self.check_expr(item)
      let rt = self.resolve(t)
      if elem_type == nil:
        elem_type = rt
      elif rt.kind == TkVar or elem_type.kind == TkVar:
        # Don't unify type variables - use Any to avoid over-constraining
        elem_type = ANY_TYPE
      else:
        try:
          self.unify(elem_type, rt, "array")
        except CatchableError:
          elem_type = ANY_TYPE
    if elem_type == nil:
      elem_type = ANY_TYPE
    return TypeExpr(kind: TkApplied, ctor: "Array", args: @[elem_type])
  of VkMap:
    let value_type = self.infer_map_value_type(v)
    return TypeExpr(kind: TkApplied, ctor: "Map", args: @[TypeExpr(kind: TkNamed, name: "Symbol"), value_type])
  of VkHashMap:
    let value_type = self.infer_hash_map_value_type(v)
    return TypeExpr(kind: TkApplied, ctor: "HashMap", args: @[ANY_TYPE, value_type])
  of VkGene:
    let gene = v.gene
    if gene == nil:
      return ANY_TYPE
    # Handle selectors early - they use special syntax with * and **
    if gene.`type`.kind == VkSymbol and gene.`type`.str == "@":
      return ANY_TYPE
    # Infix operators
    if not is_infix_special_form(gene.`type`) and
       gene.children.len > 0 and gene.children[0].kind == VkSymbol:
      let op = gene.children[0].str
      if op in ["=", "+", "-", "*", "/", "%", "++", "==", "!=", "<", "<=", ">", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "?", "is"]:
        return self.check_infix(gene)
      if op == ".":
        discard self.check_expr(gene.`type`)
        if gene.children.len > 1:
          for child in gene.children[1..^1]:
            discard self.check_expr(child)
        for _, value in gene.props:
          discard self.check_expr(value)
        return ANY_TYPE
      if gene.children[0].str.startsWith("."):
        let method_name = gene.children[0].str[1..^1]
        if method_name.startsWith("<"):
          discard self.check_expr(gene.`type`)
          return ANY_TYPE
        let args = if gene.children.len > 1: gene.children[1..^1] else: @[]
        return self.check_method_call(self.check_expr(gene.`type`), method_name, args, gene.props, "method " & method_name)

    if gene.`type`.kind == VkSymbol:
      case gene.`type`.str
      of "var":
        return self.check_var(gene)
      of "fn":
        return self.check_fn(gene)
      of "block":
        return self.check_block(gene)
      of "class":
        return self.check_class(gene)
      of "ns":
        return self.check_ns(gene)
      of "interface":
        return self.check_interface(gene)
      of "implement":
        return ANY_TYPE
      of "import":
        return self.check_import(gene)
      of "export":
        return self.check_export(gene)
      of "if":
        return self.check_if(gene)
      of "ifel":
        return self.check_ifel(gene)
      of "do":
        return self.check_do(gene)
      of "comptime":
        for child in gene.children:
          discard self.check_expr(child)
        return TypeExpr(kind: TkNamed, name: "Nil")
      of "return":
        return self.check_return(gene)
      of "super":
        return self.check_super_call(gene)
      of "new":
        if gene.children.len == 0:
          return ANY_TYPE
        let class_val = gene.children[0]
        if class_val.kind == VkSymbol and self.classes.hasKey(class_val.str):
          let cls = self.classes[class_val.str]
          if cls.ctor_type != nil:
            let args = if gene.children.len > 1: gene.children[1..^1] else: @[]
            discard self.check_call(cls.ctor_type, args, gene.props, "new")
          return TypeExpr(kind: TkNamed, name: class_val.str)
        return ANY_TYPE
      of "new!":
        raise new_exception(types.Exception, "Type error: macro-like constructors are not supported; use (new Class ...)")
      of "type":
        if gene.children.len >= 2 and gene.children[0].kind == VkSymbol:
          let alias_name = gene.children[0].str
          ensure_user_type_name(alias_name, "type alias")
          let alias_type = self.parse_type_expr(gene.children[1])
          self.types[alias_name] = alias_type
        elif gene.children.len >= 1 and gene.children[0].kind == VkGene:
          self.reject_legacy_adt_declaration(gene.children[0])
        elif gene.children.len >= 1 and gene.children[0].kind != VkSymbol:
          self.warn("type alias name must be a symbol; legacy ADT declaration heads are no longer supported; use (type Name Expr) or enum declarations such as (enum Name:T ...)")
        return ANY_TYPE
      of "enum":
        return self.check_enum(gene)
      of "case":
        return self.check_case(gene)
      of "for":
        return self.check_for(gene)
      of "while":
        return self.check_while(gene)
      of "loop":
        return self.check_loop(gene)
      of "break":
        # break can have an optional value
        if gene.children.len > 0:
          return self.check_expr(gene.children[0])
        return ANY_TYPE
      of "continue":
        return ANY_TYPE
      of "typeof":
        if gene.children.len > 0:
          discard self.check_expr(gene.children[0])
        return TypeExpr(kind: TkNamed, name: "String")
      of "try":
        return self.check_try(gene)
      of "Ok", "Err", "Some", "None":
        let ctor_type = self.check_adt_ctor(gene)
        if ctor_type != nil:
          return ctor_type
        return ANY_TYPE
      of "?":
        # ? operator for Result/Option propagation
        return self.check_question_op(gene)
      # Note: "@" (selectors) is handled early before infix operator check
      else:
        discard

    # Function call
    let callee_type = self.check_expr(gene.`type`)
    return self.check_call(callee_type, gene.children, gene.props, "call")
  else:
    return ANY_TYPE

proc type_check_node*(self: TypeChecker, node: Value) =
  if node == NIL:
    return
  discard self.check_expr(node)

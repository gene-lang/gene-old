## Pattern Matching: Matcher, RootMatcher, parse, type resolution
## (intern_type_desc, resolve_type_value_to_id).
## Included from core.nim — shares its scope.

#################### Pattern Matching ############

proc new_arg_matcher*(): RootMatcher =
  result = RootMatcher(
    mode: MatchArguments,
    type_check: true,
    return_type_id: NO_TYPE_ID,
    type_aliases: initTable[string, TypeId](),
  )

proc new_matcher*(root: RootMatcher, kind: MatcherKind): Matcher =
  result = Matcher(
    root: root,
    kind: kind,
    default_value: PLACEHOLDER, # PLACEHOLDER marks "no default" (distinct from explicit nil)
    type_id: NO_TYPE_ID,
  )

proc is_empty*(self: RootMatcher): bool =
  self.children.len == 0

proc has_default*(self: Matcher): bool {.inline.} =
  self.default_value.kind != VkPlaceholder

proc required*(self: Matcher): bool =
  # A parameter is required if it has no default and is not a splat parameter.
  # Properties without defaults are required too.
  return (not self.is_splat) and (not self.has_default())

proc check_hint*(self: RootMatcher) =
  if self.children.len == 0:
    self.hint_mode = MhNone
  else:
    self.hint_mode = MhSimpleData
    for item in self.children:
      if item.kind != MatchData or not item.required:
        self.hint_mode = MhDefault
        return

# proc hint*(self: RootMatcher): MatchingHint =
#   if self.children.len == 0:
#     result.mode = MhNone
#   else:
#     result.mode = MhSimpleData
#     for item in self.children:
#       if item.kind != MatchData or not item.required:
#         result.mode = MhDefault
#         return

# proc new_matched_field*(name: string, value: Value): MatchedField =
#   result = MatchedField(
#     name: name,
#     value: value,
#   )

proc props*(self: seq[Matcher]): HashSet[Key] =
  for m in self:
    if m.kind == MatchProp and not m.is_splat:
      result.incl(m.name_key)

proc prop_splat*(self: seq[Matcher]): Key =
  for m in self:
    if m.kind == MatchProp and m.is_splat:
      return m.name_key

proc has_positional_splat(self: seq[Matcher]): bool =
  for m in self:
    if m.is_splat and not (m.kind == MatchProp or m.is_prop):
      return true
  return false

proc can_apply_postfix_splat(m: Matcher): bool {.inline.} =
  m != nil and m.kind == MatchData and not m.is_prop and not m.is_splat and
    m.children.len == 0 and cast[int64](m.name_key) != 0

proc parse*(self: RootMatcher, v: Value)

proc calc_next*(self: Matcher) =
  var last: Matcher = nil
  for m in self.children.mitems:
    m.calc_next()
    if m.kind in @[MatchData, MatchLiteral]:
      if last != nil:
        last.next = m
      last = m

proc calc_next*(self: RootMatcher) =
  var last: Matcher = nil
  for m in self.children.mitems:
    m.calc_next()
    if m.kind in @[MatchData, MatchLiteral]:
      if last != nil:
        last.next = m
      last = m

proc calc_min_left*(self: Matcher) =
  {.push checks: off}
  var min_left = 0
  var i = self.children.len
  while i > 0:
    i -= 1
    let m = self.children[i]
    m.calc_min_left()
    m.min_left = min_left
    if m.required:
      min_left += 1
  {.pop.}

proc calc_min_left*(self: RootMatcher) =
  {.push checks: off}
  var min_left = 0
  var i = self.children.len
  while i > 0:
    i -= 1
    let m = self.children[i]
    m.calc_min_left()
    m.min_left = min_left
    if m.required:
      min_left += 1
  {.pop.}

proc parse(self: RootMatcher, group: var seq[Matcher], v: Value) =
  {.push checks: off}
  case v.kind:
    of VkSymbol:
      if v.str == "...":
        not_allowed("Positional rest must follow a named parameter")
      if v.str[0] == '^':
        let m = new_matcher(self, MatchProp)
        if v.str.ends_with("..."):
          m.is_splat = true
          m.name_key = v.str[1..^4].to_key()
          m.is_prop = true
        else:
          m.name_key = v.str[1..^1].to_key()
          m.is_prop = true
        group.add(m)
      else:
        let m = new_matcher(self, MatchData)
        group.add(m)
        if v.str != "_":
          if v.str.ends_with("..."):
            if v.str.len <= 3 or v.str[0..^4] == "_" or group.has_positional_splat():
              not_allowed("Only one named positional rest parameter is allowed")
            m.is_splat = true
            if v.str[0] == '^':
              m.name_key = v.str[1..^4].to_key()
              m.is_prop = true
            else:
              m.name_key = v.str[0..^4].to_key()
          else:
            if v.str[0] == '^':
              m.name_key = v.str[1..^1].to_key()
              m.is_prop = true
            else:
              m.name_key = v.str.to_key()
    of VkComplexSymbol:
      if v.ref.csymbol[0] == "^":
        todo("parse " & $v)
      else:
        var m = new_matcher(self, MatchData)
        group.add(m)
        m.is_prop = true
        let name = v.ref.csymbol[1]
        if name.ends_with("..."):
          m.is_splat = true
          m.name_key = name[0..^4].to_key()
        else:
          m.name_key = name.to_key()
    of VkArray:
      var i = 0
      let arr = array_data(v)
      while i < arr.len:
        let item = arr[i]
        if item.kind == VkSymbol and item.str == "...":
          if group.len == 0 or not can_apply_postfix_splat(group[^1]):
            not_allowed("Positional rest must follow a named parameter")
          if group.has_positional_splat():
            not_allowed("Only one named positional rest parameter is allowed")
          group[^1].is_splat = true
          i += 1
          continue
        i += 1
        if item.kind == VkArray:
          let m = new_matcher(self, MatchData)
          group.add(m)
          self.parse(m.children, item)
        else:
          self.parse(group, item)
          if i < arr.len and arr[i] == "=".to_symbol_value():
            i += 1
            let last_matcher = group[^1]
            let value = arr[i]
            i += 1
            last_matcher.default_value = value
    of VkQuote:
      todo($VkQuote)
      # var m = new_matcher(self, MatchLiteral)
      # m.literal = v.quote
      # m.name = "<literal>"
      # group.add(m)
    else:
      todo("parse " & $v.kind)
  {.pop.}

proc parse*(self: RootMatcher, v: Value) =
  if v == nil or v == to_symbol_value("_"):
    return
  self.parse(self.children, v)
  self.calc_min_left()
  self.calc_next()

proc new_arg_matcher*(value: Value): RootMatcher =
  result = new_arg_matcher()
  result.parse(value)
  result.check_hint()

proc is_union_gene(gene: ptr Gene): bool =
  if gene == nil:
    return false
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
    return true
  for child in gene.children:
    if child.kind == VkSymbol and child.str == "|":
      return true
  return false

proc union_members(v: Value): seq[Value] =
  if v.kind == VkGene and v.gene != nil and is_union_gene(v.gene):
    let gene = v.gene
    if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
      return gene.children
    result.add(gene.`type`)
    var i = 0
    while i < gene.children.len:
      let child = gene.children[i]
      if child.kind == VkSymbol and child.str == "|":
        if i + 1 < gene.children.len:
          result.add(gene.children[i + 1])
        i += 2
      else:
        i += 1
    return result
  result = @[v]

proc type_expr_to_string*(v: Value): string =
  case v.kind
  of VkSymbol:
    return v.str
  of VkString:
    return v.str
  of VkGene:
    let gene = v.gene
    if gene == nil:
      return "Any"
    if gene.`type`.kind == VkSymbol and gene.`type`.str in ["Fn", "Method"]:
      var params: seq[string] = @[]
      var idx = 0
      if gene.children.len > 0 and gene.children[0].kind == VkArray:
        let items = array_data(gene.children[0])
        var i = 0
        while i < items.len:
          let item = items[i]
          if item.kind == VkSymbol and item.str == "...":
            params.add("...")
            i += 1
            continue
          if item.kind == VkSymbol and item.str.startsWith("^"):
            let label = item.str[1..^1]
            if i + 1 < items.len:
              if label == "...":
                params.add("^... " & type_expr_to_string(items[i + 1]))
              else:
                params.add("^" & label & " " & type_expr_to_string(items[i + 1]))
              i += 2
            else:
              if label == "...":
                params.add("^... Any")
              else:
                params.add("^" & label & " Any")
              i += 1
          else:
            var text = type_expr_to_string(item)
            if item.kind == VkSymbol and item.str.endsWith("...") and item.str.len > 3:
              text = type_expr_to_string(item.str[0..^4].to_symbol_value()) & " ..."
            elif i + 1 < items.len and items[i + 1].kind == VkSymbol and items[i + 1].str == "...":
              text &= " ..."
              i += 1
            params.add(text)
            i += 1
        idx = 1
      let ret =
        if idx < gene.children.len and gene.children[idx].kind == VkSymbol and gene.children[idx].str == "->" and idx + 1 < gene.children.len:
          idx += 2
          type_expr_to_string(gene.children[idx - 1])
        elif idx < gene.children.len and not (gene.children[idx].kind == VkSymbol and gene.children[idx].str == "!"):
          idx += 1
          type_expr_to_string(gene.children[idx - 1])
        else:
          "Any"
      var effects: seq[string] = @[]
      if idx < gene.children.len:
        let maybe_bang = gene.children[idx]
        if maybe_bang.kind == VkSymbol and maybe_bang.str == "!" and idx + 1 < gene.children.len:
          let effect_list = gene.children[idx + 1]
          if effect_list.kind == VkArray:
            for eff in array_data(effect_list):
              effects.add(type_expr_to_string(eff))
      let effect_suffix =
        if effects.len > 0: " ! [" & effects.join(" ") & "]" else: ""
      let args =
        if params.len > 0: " [" & params.join(" ") & "]"
        else: ""
      return "(Fn" & args & " -> " & ret & effect_suffix & ")"
    if is_union_gene(gene):
      var parts: seq[string] = @[]
      for member in union_members(v):
        parts.add(type_expr_to_string(member))
      return "(" & parts.join(" | ") & ")"
    if gene.`type`.kind == VkSymbol:
      var parts: seq[string] = @[gene.`type`.str]
      for child in gene.children:
        parts.add(type_expr_to_string(child))
      return "(" & parts.join(" ") & ")"
    return "Any"
  else:
    return "Any"

proc resolve_type_value_to_id_with_index*(v: Value, type_descs: var seq[TypeDesc],
                                        type_desc_index: var Table[string, TypeId],
                                        type_aliases: Table[string, TypeId],
                                        type_vars: Table[string, TypeId],
                                        module_path: string): TypeId {.gcsafe.} =
  ## Resolve a Gene AST type expression to a TypeId, interning into type_descs.
  ## Handles: symbols (Int), applied types (Array Int), unions (Int | String), Fn types.
  ## Checks type_aliases for user-defined type aliases (e.g., UserId → Int | String).
  case v.kind
  of VkSymbol:
    let builtin_id = lookup_builtin_type(v.str)
    if builtin_id != NO_TYPE_ID:
      return builtin_id
    if type_vars.hasKey(v.str):
      return type_vars[v.str]
    # Check type aliases
    if type_aliases.hasKey(v.str):
      return type_aliases[v.str]
    # Unknown named type (user class etc) - intern it
    return intern_type_desc(type_descs,
      TypeDesc(module_path: module_path, kind: TdkNamed, name: v.str), type_desc_index)
  of VkString:
    let builtin_id = lookup_builtin_type(v.str)
    if builtin_id != NO_TYPE_ID:
      return builtin_id
    if type_vars.hasKey(v.str):
      return type_vars[v.str]
    if type_aliases.hasKey(v.str):
      return type_aliases[v.str]
    return intern_type_desc(type_descs,
      TypeDesc(module_path: module_path, kind: TdkNamed, name: v.str), type_desc_index)
  of VkGene:
    let gene = v.gene
    if gene == nil:
      return BUILTIN_TYPE_ANY_ID
    # Handle callable type: (Fn [Int] -> String)
    if gene.`type`.kind == VkSymbol and gene.`type`.str in ["Fn", "Method"]:
      var params: seq[CallableParamDesc] = @[]
      var idx = 0
      if gene.children.len > 0 and gene.children[0].kind == VkArray:
        let items = array_data(gene.children[0])
        var i = 0
        while i < items.len:
          let item = items[i]
          var kind = CpkPositional
          var param_type_id = BUILTIN_TYPE_ANY_ID
          if item.kind == VkSymbol and item.str == "...":
            not_allowed("Fn type rest marker must follow a parameter type")
          if item.kind == VkSymbol and item.str.startsWith("^"):
            let label = item.str[1..^1]
            if i + 1 < items.len:
              param_type_id = resolve_type_value_to_id_with_index(items[i + 1], type_descs, type_desc_index, type_aliases, type_vars, module_path)
              i += 2
            else:
              param_type_id = BUILTIN_TYPE_ANY_ID
              i += 1
            if label == "...":
              params.add(CallableParamDesc(kind: CpkKeywordRest, keyword_name: "", type_id: param_type_id))
            else:
              params.add(CallableParamDesc(kind: CpkKeyword, keyword_name: label, type_id: param_type_id))
            continue
          else:
            var param_item = item
            if item.kind == VkSymbol and item.str.endsWith("...") and item.str.len > 3:
              param_item = item.str[0..^4].to_symbol_value()
              kind = CpkPositionalRest
            param_type_id = resolve_type_value_to_id_with_index(param_item, type_descs, type_desc_index, type_aliases, type_vars, module_path)
            i += 1
          if i < items.len and items[i].kind == VkSymbol and items[i].str == "...":
            if kind == CpkPositionalRest:
              not_allowed("Fn type parameter has duplicate rest marker")
            kind = CpkPositionalRest
            i += 1
          params.add(CallableParamDesc(kind: kind, keyword_name: "", type_id: param_type_id))
        idx = 1
      let ret =
        if idx < gene.children.len and gene.children[idx].kind == VkSymbol and gene.children[idx].str == "->" and idx + 1 < gene.children.len:
          idx += 2
          resolve_type_value_to_id_with_index(gene.children[idx - 1], type_descs, type_desc_index, type_aliases, type_vars, module_path)
        elif idx < gene.children.len and not (gene.children[idx].kind == VkSymbol and gene.children[idx].str == "!"):
          idx += 1
          resolve_type_value_to_id_with_index(gene.children[idx - 1], type_descs, type_desc_index, type_aliases, type_vars, module_path)
        else:
          BUILTIN_TYPE_ANY_ID
      var effects: seq[string] = @[]
      if idx < gene.children.len:
        let maybe_bang = gene.children[idx]
        if maybe_bang.kind == VkSymbol and maybe_bang.str == "!" and idx + 1 < gene.children.len:
          let effect_list = gene.children[idx + 1]
          if effect_list.kind == VkArray:
            for eff in array_data(effect_list):
              if eff.kind == VkSymbol:
                effects.add(eff.str)
      return intern_type_desc(type_descs,
        TypeDesc(module_path: module_path, kind: TdkFn, params: params, ret: ret, effects: effects), type_desc_index)
    # Handle union type: (Int | String)
    if is_union_gene(gene):
      var members: seq[TypeId] = @[]
      for member in union_members(v):
        members.add(resolve_type_value_to_id_with_index(member, type_descs, type_desc_index, type_aliases, type_vars, module_path))
      return intern_type_desc(type_descs,
        TypeDesc(module_path: module_path, kind: TdkUnion, members: members), type_desc_index)
    # Handle applied type: (Array Int)
    if gene.`type`.kind == VkSymbol:
      let ctor = gene.`type`.str
      var args: seq[TypeId] = @[]
      for child in gene.children:
        args.add(resolve_type_value_to_id_with_index(child, type_descs, type_desc_index, type_aliases, type_vars, module_path))
      return intern_type_desc(type_descs,
        TypeDesc(module_path: module_path, kind: TdkApplied, ctor: ctor, args: args), type_desc_index)
    return BUILTIN_TYPE_ANY_ID
  else:
    return BUILTIN_TYPE_ANY_ID

proc resolve_type_value_to_id*(v: Value, type_descs: var seq[TypeDesc],
                              type_aliases: Table[string, TypeId] = initTable[string, TypeId](),
                              module_path = ""): TypeId {.gcsafe.} =
  var type_desc_index = initTable[string, TypeId]()
  ensure_type_desc_index(type_descs, type_desc_index)
  resolve_type_value_to_id_with_index(v, type_descs, type_desc_index, type_aliases,
    initTable[string, TypeId](), module_path)

## Enum operations
## Included from core.nim — shares its scope.

proc copy_enum_type_descs(type_descs: seq[TypeDesc]): seq[TypeDesc] =
  if type_descs.len == 0:
    return @[]
  result = newSeqOfCap[TypeDesc](type_descs.len)
  for desc in type_descs:
    result.add(desc)

proc new_enum*(name: string, type_params: seq[string] = @[], field_type_descs: seq[TypeDesc] = @[]): EnumDef =
  return EnumDef(
    name: name,
    type_params: type_params,
    members: initTable[string, EnumMember](),
    field_type_descs: copy_enum_type_descs(field_type_descs),
  )

proc new_enum_member*(parent: Value, name: string, value: int,
                      fields: seq[string] = @[],
                      field_type_ids: seq[TypeId] = @[],
                      field_type_descs: seq[TypeDesc] = @[]): EnumMember =
  return EnumMember(
    parent: parent,
    name: name,
    value: value,
    fields: fields,
    field_type_ids: field_type_ids,
    field_type_descs: copy_enum_type_descs(field_type_descs),
  )

proc to_value*(e: EnumDef): Value =
  let r = new_ref(VkEnum)
  r.enum_def = e
  return r.to_ref_value()

proc to_value*(m: EnumMember): Value =
  let r = new_ref(VkEnumMember)
  r.enum_member = m
  return r.to_ref_value()

proc add_member*(self: Value, name: string, value: int, fields: seq[string] = @[],
                 field_type_ids: seq[TypeId] = @[],
                 field_type_descs: seq[TypeDesc] = @[]) =
  if self.kind != VkEnum:
    not_allowed("add_member can only be called on enums")
  var member_type_ids = field_type_ids
  if member_type_ids.len == 0 and fields.len > 0:
    member_type_ids = newSeq[TypeId](fields.len)
    for i in 0..<member_type_ids.len:
      member_type_ids[i] = NO_TYPE_ID
  let descs =
    if field_type_descs.len > 0:
      field_type_descs
    else:
      self.ref.enum_def.field_type_descs
  let member = new_enum_member(self, name, value, fields, member_type_ids, descs)
  self.ref.enum_def.members[name] = member

proc new_enum_value*(variant: Value, data: seq[Value]): Value =
  let r = new_ref(VkEnumValue)
  r.ev_variant = variant
  r.ev_data = data
  return r.to_ref_value()

proc `[]`*(self: Value, name: string): Value =
  if self.kind != VkEnum:
    not_allowed("enum member access can only be used on enums")
  if name in self.ref.enum_def.members:
    return self.ref.enum_def.members[name].to_value()
  else:
    not_allowed("enum " & self.ref.enum_def.name & " has no member " & name)
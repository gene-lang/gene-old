## Fail-closed descriptor metadata verifier.
##
## This module intentionally validates TypeId edges and registry parity with
## explicit range/key checks. It must not repair, canonicalize, or rebuild the
## CompilationUnit's own registry.

import tables

import ./type_defs

const
  TypeMetadataInvalidMarker* = "GENE_TYPE_METADATA_INVALID"

type
  MetadataVerificationContext = object
    phase: string
    source_path: string
    descriptor_count: int
    module_path: string

proc display_source_path(path: string): string {.inline.} =
  if path.len == 0: "<none>" else: path

proc display_owner_path(path: string): string {.inline.} =
  if path.len == 0: "<root>" else: path

proc descriptor_owner_path(type_id: TypeId, desc: TypeDesc, fallback_module_path: string): string =
  let owner = canonical_type_owner_path(desc, fallback_module_path)
  let module_part = if owner.len == 0: "<local>" else: owner
  module_part & "/type_descriptors[" & $type_id & "]"

proc raise_metadata_invalid(ctx: MetadataVerificationContext, owner_path: string,
                            invalid_type_id: TypeId, detail: string) {.noreturn.} =
  raise new_exception(type_defs.Exception,
    TypeMetadataInvalidMarker &
    ": phase=" & ctx.phase &
    "; owner/path=" & display_owner_path(owner_path) &
    "; invalid TypeId=" & $invalid_type_id &
    "; descriptor count=" & $ctx.descriptor_count &
    "; descriptor-table length=" & $ctx.descriptor_count &
    "; source path=" & display_source_path(ctx.source_path) &
    "; detail=" & detail)

proc validate_type_id_edge(ctx: MetadataVerificationContext, owner_path: string,
                           type_id: TypeId, allow_no_type_id = false) =
  if type_id == NO_TYPE_ID:
    if allow_no_type_id:
      return
    raise_metadata_invalid(ctx, owner_path, type_id,
      "NO_TYPE_ID is not valid for this descriptor graph edge")
  if type_id < 0'i32 or type_id.int >= ctx.descriptor_count:
    raise_metadata_invalid(ctx, owner_path, type_id,
      "TypeId is outside the descriptor table")

proc validate_descriptor_graph(ctx: MetadataVerificationContext,
                               descriptors: seq[TypeDesc]) =
  for i, desc in descriptors:
    let type_id = i.TypeId
    let base_owner = descriptor_owner_path(type_id, desc, ctx.module_path)
    case desc.kind
    of TdkApplied:
      for arg_index, arg_id in desc.args:
        validate_type_id_edge(ctx, base_owner & ".args[" & $arg_index & "]", arg_id)
    of TdkUnion:
      for member_index, member_id in desc.members:
        validate_type_id_edge(ctx, base_owner & ".members[" & $member_index & "]", member_id)
    of TdkFn:
      for param_index, param in desc.params:
        # Callable descriptors may carry NO_TYPE_ID for intentionally untyped
        # callable references; every concrete TypeId must still be in-range.
        validate_type_id_edge(ctx,
          base_owner & ".params[" & $param_index & "].type_id",
          param.type_id,
          allow_no_type_id = true)
      validate_type_id_edge(ctx, base_owner & ".ret", desc.ret,
        allow_no_type_id = true)
    else:
      discard

proc resolved_registry_module_path(descriptors: seq[TypeDesc], module_path: string): string =
  result = module_path
  for desc in descriptors:
    if desc.module_path != BUILTIN_TYPE_MODULE_PATH and desc.module_path != "":
      return desc.module_path

proc add_expected_kind_index(registry: ModuleTypeRegistry, type_id: TypeId,
                             desc: TypeDesc) =
  case desc.kind
  of TdkAny:
    registry.builtin_types["Any"] = type_id
  of TdkNamed:
    if lookup_builtin_type(desc.name) != NO_TYPE_ID and desc.module_path == BUILTIN_TYPE_MODULE_PATH:
      registry.builtin_types[desc.name] = type_id
    else:
      registry.named_types[descriptor_registry_key(desc)] = type_id
  of TdkApplied:
    registry.applied_types[descriptor_registry_key(desc)] = type_id
  of TdkUnion:
    registry.union_types[descriptor_registry_key(desc)] = type_id
  of TdkFn:
    registry.function_types[descriptor_registry_key(desc)] = type_id
  of TdkVar:
    discard

proc expected_registry_for(descriptors: seq[TypeDesc], module_path: string): ModuleTypeRegistry =
  let expected_module_path = resolved_registry_module_path(descriptors, module_path)
  result = new_module_type_registry(expected_module_path)
  for i, desc in descriptors:
    let type_id = i.TypeId
    let canonical = canonicalize_type_desc_owner(desc, expected_module_path)
    result.descriptors[type_id] = canonical
    if result.module_path.len == 0:
      let owner = canonical.module_path
      if owner.len > 0 and owner != BUILTIN_TYPE_MODULE_PATH:
        result.module_path = owner
    add_expected_kind_index(result, type_id, canonical)

proc callable_params_equal(a, b: CallableParamDesc): bool {.inline.} =
  a.kind == b.kind and a.keyword_name == b.keyword_name and a.type_id == b.type_id

proc type_descs_equal(a, b: TypeDesc): bool =
  if a.module_path != b.module_path or a.kind != b.kind:
    return false
  case a.kind
  of TdkAny:
    true
  of TdkNamed:
    a.name == b.name
  of TdkApplied:
    a.ctor == b.ctor and a.args == b.args
  of TdkUnion:
    a.members == b.members
  of TdkFn:
    if a.ret != b.ret or a.effects != b.effects or a.params.len != b.params.len:
      return false
    for i in 0..<a.params.len:
      if not callable_params_equal(a.params[i], b.params[i]):
        return false
    true
  of TdkVar:
    a.var_id == b.var_id

proc validate_registry_descriptors(ctx: MetadataVerificationContext,
                                   actual: ModuleTypeRegistry,
                                   expected: ModuleTypeRegistry) =
  for type_id, expected_desc in expected.descriptors:
    let owner_path = "type_registry.descriptors[" & $type_id & "]"
    if not actual.descriptors.hasKey(type_id):
      raise_metadata_invalid(ctx, owner_path, type_id,
        "registry descriptor entry is missing")
    let actual_desc = actual.descriptors[type_id]
    if not type_descs_equal(actual_desc, expected_desc):
      raise_metadata_invalid(ctx, owner_path, type_id,
        "registry descriptor mismatch: expected kind=" & $expected_desc.kind &
        ", actual kind=" & $actual_desc.kind)

  for type_id, _ in actual.descriptors:
    if not expected.descriptors.hasKey(type_id):
      raise_metadata_invalid(ctx, "type_registry.descriptors[" & $type_id & "]",
        type_id, "registry descriptor entry is unexpected")

proc validate_type_id_index(ctx: MetadataVerificationContext, index_name: string,
                            actual: OrderedTable[string, TypeId],
                            expected: OrderedTable[string, TypeId]) =
  for key, expected_id in expected:
    let owner_path = "type_registry." & index_name & "[" & key & "]"
    if not actual.hasKey(key):
      raise_metadata_invalid(ctx, owner_path, expected_id,
        "registry kind index entry is missing")
    let actual_id = actual[key]
    if actual_id != expected_id:
      raise_metadata_invalid(ctx, owner_path, actual_id,
        "registry kind index points at stale TypeId; expected " & $expected_id)

  for key, actual_id in actual:
    if not expected.hasKey(key):
      raise_metadata_invalid(ctx,
        "type_registry." & index_name & "[" & key & "]",
        actual_id, "registry kind index entry is unexpected")

proc validate_registry_parity(ctx: MetadataVerificationContext,
                              registry: ModuleTypeRegistry,
                              expected: ModuleTypeRegistry) =
  if registry.module_path != expected.module_path:
    raise_metadata_invalid(ctx, "type_registry.module_path", NO_TYPE_ID,
      "registry module_path mismatch: expected '" & expected.module_path &
      "', actual '" & registry.module_path & "'")

  validate_registry_descriptors(ctx, registry, expected)
  validate_type_id_index(ctx, "builtin_types", registry.builtin_types, expected.builtin_types)
  validate_type_id_index(ctx, "named_types", registry.named_types, expected.named_types)
  validate_type_id_index(ctx, "applied_types", registry.applied_types, expected.applied_types)
  validate_type_id_index(ctx, "union_types", registry.union_types, expected.union_types)
  validate_type_id_index(ctx, "function_types", registry.function_types, expected.function_types)

proc verify_type_metadata*(cu: CompilationUnit, phase = "source compile", source_path = "") =
  ## Verify descriptor graph closure and type registry parity for a completed CU.
  ## Raises gene/types.Exception with GENE_TYPE_METADATA_INVALID on the first
  ## invalid owner/path and never mutates cu or cu.type_registry.
  if cu == nil:
    let ctx = MetadataVerificationContext(
      phase: phase,
      source_path: source_path,
      descriptor_count: 0,
      module_path: "")
    raise_metadata_invalid(ctx, "compilation_unit", NO_TYPE_ID,
      "compilation unit is nil")

  let module_path = resolved_registry_module_path(cu.type_descriptors, cu.module_path)
  let ctx = MetadataVerificationContext(
    phase: phase,
    source_path: source_path,
    descriptor_count: cu.type_descriptors.len,
    module_path: module_path)

  validate_descriptor_graph(ctx, cu.type_descriptors)

  if cu.type_registry == nil:
    raise_metadata_invalid(ctx, "type_registry", NO_TYPE_ID,
      "type_registry is nil at metadata verification boundary")

  let expected = expected_registry_for(cu.type_descriptors, cu.module_path)
  validate_registry_parity(ctx, cu.type_registry, expected)

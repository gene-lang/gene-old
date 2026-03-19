import tables, strutils, os

import ../gene/types
import ../gene/logging_core
import ../gene/vm/extension_abi

var logger_class_global: Class
var host_log_message_cb: GeneHostLogFn = nil

proc value_to_log_part(value: Value): string =
  case value.kind
  of VkString:
    value.str
  else:
    value.str_no_quotes()

proc collect_message(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, start_idx: int): string =
  let pos_count = get_positional_count(arg_count, has_keyword_args)
  if pos_count <= start_idx:
    return ""
  result = ""
  for i in start_idx..<pos_count:
    if i > start_idx:
      result &= " "
    result &= value_to_log_part(get_positional_arg(args, i, has_keyword_args))

proc logger_log(level: LogLevel, vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "Logger method requires self")
  let self_val = get_positional_arg(args, 0, has_keyword_args)
  if self_val.kind != VkInstance:
    raise new_exception(types.Exception, "Logger methods must be called on an instance")
  let name_key = "name".to_key()
  let name_val = instance_props(self_val).getOrDefault(name_key, NIL)
  let logger_name =
    if name_val.kind in {VkString, VkSymbol}:
      name_val.str
    else:
      "unknown"
  let message = collect_message(args, arg_count, has_keyword_args, 1)
  if host_log_message_cb != nil:
    host_log_message_cb(int32(level), logger_name.cstring, message.cstring)
  else:
    log_message(level, logger_name, message)
  NIL

proc logger_info(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  logger_log(LlInfo, vm, args, arg_count, has_keyword_args)

proc logger_warn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  logger_log(LlWarn, vm, args, arg_count, has_keyword_args)

proc logger_error(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  logger_log(LlError, vm, args, arg_count, has_keyword_args)

proc logger_debug(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  logger_log(LlDebug, vm, args, arg_count, has_keyword_args)

proc logger_trace(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  logger_log(LlTrace, vm, args, arg_count, has_keyword_args)

proc looks_like_module_path(name: string): bool =
  if name.len == 0:
    return false
  let lower = name.toLowerAscii()
  if lower.endsWith(".gene") or lower.endsWith(".gir"):
    return true
  if name.isAbsolute:
    return true
  false

proc normalize_logger_path(path: string): string =
  if path.len == 0:
    return ""
  var normalized = path.replace('\\', '/')
  if normalized.isAbsolute:
    try:
      normalized = relativePath(normalized, getCurrentDir())
    except OSError:
      discard
  normalized

proc join_logger_parts(parts: seq[string]): string =
  var trimmed: seq[string] = @[]
  for part in parts:
    if part.len > 0:
      trimmed.add(part)
  if trimmed.len == 0:
    return "unknown"
  trimmed.join("/")

proc module_path_from_namespace(ns: Namespace): string =
  var current = ns
  let key = "__module_name__".to_key()
  while current != nil:
    if current.members.hasKey(key):
      let value = current.members[key]
      if value.kind == VkString:
        return value.str
    if current.name.len > 0 and current.name != "<root>" and looks_like_module_path(current.name):
      return current.name
    current = current.parent
  ""

proc fallback_module_path(vm: ptr VirtualMachine): string =
  if vm == nil or vm.frame == nil:
    return ""
  if vm.frame.caller_frame != nil and vm.frame.caller_frame.ns != nil:
    let name = module_path_from_namespace(vm.frame.caller_frame.ns)
    if name.len > 0:
      return name
  if vm.frame.ns != nil and vm.frame.ns.parent != nil:
    let name = module_path_from_namespace(vm.frame.ns.parent)
    if name.len > 0:
      return name
  if App != NIL and App.kind == VkApplication and App.app.gene_ns.kind == VkNamespace:
    let key = "main_module".to_key()
    if App.app.gene_ns.ref.ns.members.hasKey(key):
      let value = App.app.gene_ns.ref.ns.members[key]
      if value.kind == VkString:
        return value.str
  ""

proc derive_logger_name(vm: ptr VirtualMachine, target: Value): string {.gcsafe.} =
  {.cast(gcsafe).}:
    case target.kind
    of VkString, VkSymbol:
      return target.str
    else:
      discard

    if vm != nil and App != NIL and App.kind == VkApplication:
      let target_class = get_class(target)
      if target_class != nil:
        let to_s_method = target_class.get_method("to_s")
        if to_s_method != nil and to_s_method.callable.kind == VkNativeFn:
          let rendered = call_native_fn(to_s_method.callable.ref.native_fn, vm, @[target])
          case rendered.kind
          of VkString, VkSymbol:
            return rendered.str
          else:
            return rendered.str_no_quotes()

    return target.str_no_quotes()

proc should_prefix_logger_name(name: string): bool =
  if name.len == 0:
    return true
  if name.contains("/"):
    return false
  if looks_like_module_path(name):
    return false
  true

proc finalize_logger_name(name: string, fallback_module: string): string =
  let normalized_name = normalize_logger_path(name)
  let normalized_fallback = normalize_logger_path(fallback_module)
  if normalized_name.len == 0:
    if normalized_fallback.len > 0:
      return normalized_fallback
    return "unknown"
  if normalized_fallback.len > 0 and should_prefix_logger_name(normalized_name):
    return join_logger_parts(@[normalized_fallback, normalized_name])
  normalized_name

proc logger_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if get_positional_count(arg_count, has_keyword_args) < 1:
      raise new_exception(types.Exception, "Logger requires a value")
    let target = get_positional_arg(args, 0, has_keyword_args)
    let logger_name = finalize_logger_name(derive_logger_name(vm, target), fallback_module_path(vm))
    let instance = new_instance_value(logger_class_global)
    let name_key = "name".to_key()
    instance_props(instance)[name_key] = logger_name.to_value()
    return instance

proc init_logging_module*() =
  VmCreatedCallbacks.add proc() =
    if App == NIL or App.kind != VkApplication:
      return
    if App.app.genex_ns == NIL:
      return

    {.cast(gcsafe).}:
      logger_class_global = new_class("Logger")
      logger_class_global.def_native_constructor(logger_constructor)
      logger_class_global.def_native_method("info", logger_info)
      logger_class_global.def_native_method("warn", logger_warn)
      logger_class_global.def_native_method("error", logger_error)
      logger_class_global.def_native_method("debug", logger_debug)
      logger_class_global.def_native_method("trace", logger_trace)

    let logger_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      logger_class_ref.class = logger_class_global

    let logging_ns = new_namespace("logging")
    logging_ns["Logger".to_key()] = logger_class_ref.to_ref_value()
    App.app.genex_ns.ref.ns["logging".to_key()] = logging_ns.to_value()

init_logging_module()

proc init*(vm: ptr VirtualMachine): Namespace {.gcsafe.} =
  discard vm
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let logging_val = App.app.genex_ns.ref.ns.members.getOrDefault("logging".to_key(), NIL)
  if logging_val.kind == VkNamespace:
    return logging_val.ref.ns
  return nil

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host == nil:
    return int32(GeneExtErr)
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return int32(GeneExtAbiMismatch)
  let vm = apply_extension_host_context(host)
  host_log_message_cb = host.log_message_fn
  run_extension_vm_created_callbacks()
  let ns = init(vm)
  if host.result_namespace != nil:
    host.result_namespace[] = ns
  if ns == nil:
    return int32(GeneExtErr)
  int32(GeneExtOk)

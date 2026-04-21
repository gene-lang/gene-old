when not defined(gene_wasm):
  import strutils, os, tables, times

import ../types
import ../logging_core
when defined(gene_wasm):
  import ../wasm_host_abi

when not defined(gene_wasm):
  import ../serdes
  import dynlib
  import ./extension_abi
  import ./actor
  import ./thread
  import ./llm_host_abi

  const VmExtensionLogger = "gene/vm/extension"

  when defined(posix):
    # Use dlopen with RTLD_GLOBAL on POSIX systems
    # This makes symbols from the main executable available to the loaded library
    const RTLD_NOW = 2
    const RTLD_GLOBAL = 256  # 0x100

    when defined(macosx):
      # On macOS, dlopen is in libSystem
      proc dlopen(filename: cstring, flag: cint): pointer {.importc.}
      proc dlsym(handle: pointer, symbol: cstring): pointer {.importc.}
      proc dlclose(handle: pointer): cint {.importc.}
      proc dlerror(): cstring {.importc.}
    else:
      # On Linux, dlopen is in libdl
      proc dlopen(filename: cstring, flag: cint): pointer {.importc, dynlib: "libdl.so(|.2|.1)".}
      proc dlsym(handle: pointer, symbol: cstring): pointer {.importc, dynlib: "libdl.so(|.2|.1)".}
      proc dlclose(handle: pointer): cint {.importc, dynlib: "libdl.so(|.2|.1)".}
      proc dlerror(): cstring {.importc, dynlib: "libdl.so(|.2|.1)".}

    proc loadLibGlobal(path: cstring): LibHandle =
      ## Load library with RTLD_GLOBAL so it can see symbols from main executable
      let handle = dlopen(path, RTLD_NOW or RTLD_GLOBAL)
      if handle == nil:
        let err = dlerror()
        log_message(LlDebug, VmExtensionLogger, "dlopen error: " & (if err != nil: $err else: "unknown"))
        return nil
      return cast[LibHandle](handle)

proc infer_extension_name(path: string): string =
  var name = splitFile(path).name
  if name.startsWith("lib") and name.len > 3:
    name = name[3..^1]
  name

proc lookup_genex_namespace(name: string): Namespace =
  if name.len == 0:
    return nil
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let existing = App.app.genex_ns.ref.ns.members.getOrDefault(name.to_key(), NIL)
  if existing.kind == VkNamespace:
    return existing.ref.ns
  nil

proc run_vm_created_callbacks(start_idx: int) =
  ## Run any VM-created callbacks added after `start_idx`.
  var i = start_idx
  while i < VmCreatedCallbacks.len:
    VmCreatedCallbacks[i]()
    inc i

proc host_log_message_bridge(level: int32, logger_name: cstring, message: cstring) {.cdecl, gcsafe.} =
  let log_level = case level
    of int32(LlError): LlError
    of int32(LlWarn): LlWarn
    of int32(LlInfo): LlInfo
    of int32(LlDebug): LlDebug
    of int32(LlTrace): LlTrace
    else: LlInfo
  let logger_name_str = if logger_name == nil: "" else: $logger_name
  let message_str = if message == nil: "" else: $message
  log_message(log_level, logger_name_str, message_str)

type
  HostSchedulerCallbackEntry = object
    callback: GeneHostSchedulerTickFn
    callback_user_data: pointer

  RegisteredExtensionPort* = ref object
    name*: string
    kind*: ExtensionPortKind
    handler*: Value
    init_state*: Value
    pool_size*: int
    handles*: seq[Value]

  LlmHostBridge = ref object
    handle: LibHandle
    abi_version_fn: GeneLlmHostAbiVersionFn
    load_model_fn: GeneLlmHostLoadModelFn
    new_session_fn: GeneLlmHostNewSessionFn
    infer_fn: GeneLlmHostInferFn
    close_model_fn: GeneLlmHostCloseModelFn
    close_session_fn: GeneLlmHostCloseSessionFn
    free_cstring_fn: GeneLlmHostFreeCStringFn
    model_class: Class
    session_class: Class
    actor_handle: Value

var host_scheduler_callback_entries: seq[HostSchedulerCallbackEntry] = @[]
var host_scheduler_dispatcher_registered = false
var registered_extension_ports*: Table[string, RegisteredExtensionPort] = initTable[string, RegisteredExtensionPort]()
var llm_host_bridge: LlmHostBridge = nil

proc current_llm_bridge(): LlmHostBridge {.gcsafe.} =
  {.cast(gcsafe).}:
    llm_host_bridge

proc resolve_extension_symbol[T](handle: LibHandle, symbol_name: string): T =
  if handle.isNil:
    return cast[T](nil)
  cast[T](handle.symAddr(symbol_name))

proc llm_take_cstring(p: cstring): string {.gcsafe.} =
  if p == nil:
    return ""
  result = $p
  var free_fn: GeneLlmHostFreeCStringFn = nil
  {.cast(gcsafe).}:
    if llm_host_bridge != nil:
      free_fn = llm_host_bridge.free_cstring_fn
  if free_fn != nil:
    free_fn(p)

proc llm_expect_map_arg(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool,
                        positional_index: int, context: string): Value =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < positional_index:
    return NIL
  let value = get_positional_arg(args, positional_index - 1, has_keyword_args)
  if value == NIL:
    return NIL
  if value.kind != VkMap:
    raise new_exception(types.Exception, context & " options must be a map")
  value

proc llm_serialize_options(value: Value): string {.gcsafe.} =
  if value == NIL:
    return ""
  {.cast(gcsafe).}:
    serialize_literal(value).to_s()

proc llm_model_id_key(): Key = "__model_id__".to_key()
proc llm_session_id_key(): Key = "__session_id__".to_key()

proc llm_model_id(value: Value, context: string): int64 =
  if value.kind != VkInstance:
    raise new_exception(types.Exception, context & " requires an LLM model instance")
  if value.instance_class == nil or value.instance_class.name != "Model":
    raise new_exception(types.Exception, context & " requires an LLM model instance")
  let id_val = instance_props(value).getOrDefault(llm_model_id_key(), NIL)
  if id_val.kind != VkInt:
    raise new_exception(types.Exception, context & " model id is missing")
  id_val.to_int()

proc llm_session_id(value: Value, context: string): int64 =
  if value.kind != VkInstance:
    raise new_exception(types.Exception, context & " requires an LLM session instance")
  if value.instance_class == nil or value.instance_class.name != "Session":
    raise new_exception(types.Exception, context & " requires an LLM session instance")
  let id_val = instance_props(value).getOrDefault(llm_session_id_key(), NIL)
  if id_val.kind != VkInt:
    raise new_exception(types.Exception, context & " session id is missing")
  id_val.to_int()

proc new_llm_model_instance(id: int64): Value =
  var cls: Class = nil
  {.cast(gcsafe).}:
    cls = llm_host_bridge.model_class
  let inst = new_instance_value(cls)
  instance_props(inst)[llm_model_id_key()] = id.to_value()
  inst

proc new_llm_session_instance(id: int64): Value =
  var cls: Class = nil
  {.cast(gcsafe).}:
    cls = llm_host_bridge.session_class
  let inst = new_instance_value(cls)
  instance_props(inst)[llm_session_id_key()] = id.to_value()
  inst

proc llm_raise_bridge_error(message: string, fallback: string) {.noreturn.} =
  if message.len > 0:
    raise new_exception(types.Exception, message)
  raise new_exception(types.Exception, fallback)

proc llm_load_model_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                           has_keyword_args: bool): Value {.gcsafe.}
proc llm_model_new_session_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                  has_keyword_args: bool): Value {.gcsafe.}
proc llm_session_infer_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                              has_keyword_args: bool): Value {.gcsafe.}
proc llm_model_close_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                            has_keyword_args: bool): Value {.gcsafe.}
proc llm_session_close_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                              has_keyword_args: bool): Value {.gcsafe.}

proc ensure_llm_host_classes(ext_ns: Namespace) =
  if llm_host_bridge == nil:
    return
  if llm_host_bridge.model_class == nil:
    let model_class = new_class("Model")
    if App.app.object_class.kind == VkClass:
      model_class.parent = App.app.object_class.ref.class
    model_class.def_native_method("new_session", llm_model_new_session_native)
    model_class.def_native_method("close", llm_model_close_native)
    llm_host_bridge.model_class = model_class
  if llm_host_bridge.session_class == nil:
    let session_class = new_class("Session")
    if App.app.object_class.kind == VkClass:
      session_class.parent = App.app.object_class.ref.class
    session_class.def_native_method("infer", llm_session_infer_native)
    session_class.def_native_method("close", llm_session_close_native)
    llm_host_bridge.session_class = session_class

  let model_class_ref = new_ref(VkClass)
  model_class_ref.class = llm_host_bridge.model_class
  let session_class_ref = new_ref(VkClass)
  session_class_ref.class = llm_host_bridge.session_class
  let load_fn = new_ref(VkNativeFn)
  load_fn.native_fn = llm_load_model_native

  ext_ns["Model".to_key()] = model_class_ref.to_ref_value()
  ext_ns["Session".to_key()] = session_class_ref.to_ref_value()
  ext_ns["load_model".to_key()] = load_fn.to_ref_value()

proc install_llm_host_bridge(ext_ns: Namespace, handle: LibHandle) =
  if handle.isNil or ext_ns == nil:
    return

  let abi_version_fn = resolve_extension_symbol[GeneLlmHostAbiVersionFn](handle, "gene_llm_host_abi_version")
  if abi_version_fn == nil:
    return
  if abi_version_fn() != GENE_LLM_HOST_ABI_VERSION:
    raise new_exception(types.Exception, "[GENE.EXT.ABI_MISMATCH] Unsupported LLM host bridge ABI")

  let bridge = LlmHostBridge(
    handle: handle,
    abi_version_fn: abi_version_fn,
    load_model_fn: resolve_extension_symbol[GeneLlmHostLoadModelFn](handle, "gene_llm_host_load_model"),
    new_session_fn: resolve_extension_symbol[GeneLlmHostNewSessionFn](handle, "gene_llm_host_new_session"),
    infer_fn: resolve_extension_symbol[GeneLlmHostInferFn](handle, "gene_llm_host_infer"),
    close_model_fn: resolve_extension_symbol[GeneLlmHostCloseModelFn](handle, "gene_llm_host_close_model"),
    close_session_fn: resolve_extension_symbol[GeneLlmHostCloseSessionFn](handle, "gene_llm_host_close_session"),
    free_cstring_fn: resolve_extension_symbol[GeneLlmHostFreeCStringFn](handle, "gene_llm_host_free_cstring"),
    actor_handle: NIL
  )
  if bridge.load_model_fn == nil or bridge.new_session_fn == nil or bridge.infer_fn == nil or
     bridge.close_model_fn == nil or bridge.close_session_fn == nil or bridge.free_cstring_fn == nil:
    raise new_exception(types.Exception, "[GENE.EXT.SYMBOL_MISSING] Incomplete LLM host bridge symbols")

  llm_host_bridge = bridge
  ensure_llm_host_classes(ext_ns)

proc llm_bridge_poll_reply(vm: ptr VirtualMachine, future_value: Value, context: string): Value {.gcsafe.} =
  let deadline = epochTime() + 10.0
  let future_obj = future_value.ref.future
  while future_obj.state == FsPending and epochTime() < deadline:
    vm.event_loop_counter = 100
    {.cast(gcsafe).}:
      vm_poll_event_loop(vm)
    sleep(10)

  case future_obj.state
  of FsSuccess:
    return future_obj.value
  of FsFailure:
    let err = future_obj.value
    if err.kind == VkInstance:
      let msg = instance_props(err).getOrDefault("message".to_key(), NIL)
      if msg.kind == VkString:
        llm_raise_bridge_error(msg.str, context & " failed")
    elif err.kind == VkString:
      llm_raise_bridge_error(err.str, context & " failed")
    llm_raise_bridge_error(context & " failed", context & " failed")
  of FsCancelled:
    llm_raise_bridge_error("Future cancelled", context & " cancelled")
  of FsPending:
    llm_raise_bridge_error(context & " timed out", context & " timed out")

proc llm_bridge_request_actor_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                     has_keyword_args: bool): Value {.gcsafe.} =
  discard arg_count
  let ctx = get_positional_arg(args, 0, has_keyword_args)
  let msg = get_positional_arg(args, 1, has_keyword_args)
  let bridge = current_llm_bridge()
  if bridge == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  if msg.kind != VkMap:
    raise new_exception(types.Exception, "LLM actor request requires a message map")

  let op_val = map_data(msg).getOrDefault("op".to_key(), NIL)
  if op_val.kind != VkString:
    raise new_exception(types.Exception, "LLM actor request requires an op")

  let opts = map_data(msg).getOrDefault("options".to_key(), NIL)
  let options_ser = llm_serialize_options(opts)

  case op_val.str
  of "load_model":
    let path_val = map_data(msg).getOrDefault("path".to_key(), NIL)
    if path_val.kind != VkString:
      raise new_exception(types.Exception, "LLM load_model requires a path")
    var model_id: int64 = 0
    var err: cstring = nil
    let status = bridge.load_model_fn(path_val.str.cstring,
      if options_ser.len > 0: options_ser.cstring else: nil,
      addr model_id, addr err)
    let err_msg = llm_take_cstring(err)
    if status != int32(GlhsOk):
      llm_raise_bridge_error(err_msg, "genex/llm/load_model failed")
    actor_reply_for_test(ctx, new_map_value({"model_id".to_key(): model_id.to_value()}.toTable()))
  of "new_session":
    let model_id_val = map_data(msg).getOrDefault("model_id".to_key(), NIL)
    if model_id_val.kind != VkInt:
      raise new_exception(types.Exception, "LLM new_session requires model_id")
    var session_id: int64 = 0
    var err: cstring = nil
    let status = bridge.new_session_fn(model_id_val.to_int(),
      if options_ser.len > 0: options_ser.cstring else: nil,
      addr session_id, addr err)
    let err_msg = llm_take_cstring(err)
    if status != int32(GlhsOk):
      llm_raise_bridge_error(err_msg, "Model.new_session failed")
    actor_reply_for_test(ctx, new_map_value({"session_id".to_key(): session_id.to_value()}.toTable()))
  of "infer":
    let session_id_val = map_data(msg).getOrDefault("session_id".to_key(), NIL)
    let prompt_val = map_data(msg).getOrDefault("prompt".to_key(), NIL)
    if session_id_val.kind != VkInt or prompt_val.kind != VkString:
      raise new_exception(types.Exception, "LLM infer requires session_id and prompt")
    var result_ser: cstring = nil
    var err: cstring = nil
    let status = bridge.infer_fn(session_id_val.to_int(), prompt_val.str.cstring,
      if options_ser.len > 0: options_ser.cstring else: nil,
      addr result_ser, addr err)
    let err_msg = llm_take_cstring(err)
    if status != int32(GlhsOk):
      llm_raise_bridge_error(err_msg, "Session.infer failed")
    if result_ser == nil:
      llm_raise_bridge_error("", "Session.infer returned no payload")
    let payload = llm_take_cstring(result_ser)
    actor_reply_for_test(ctx, deserialize_literal(payload))
  of "close_model":
    let model_id_val = map_data(msg).getOrDefault("model_id".to_key(), NIL)
    if model_id_val.kind != VkInt:
      raise new_exception(types.Exception, "LLM close_model requires model_id")
    var err: cstring = nil
    let status = bridge.close_model_fn(model_id_val.to_int(), addr err)
    let err_msg = llm_take_cstring(err)
    if status != int32(GlhsOk):
      llm_raise_bridge_error(err_msg, "Model.close failed")
    actor_reply_for_test(ctx, "ok".to_symbol_value())
  of "close_session":
    let session_id_val = map_data(msg).getOrDefault("session_id".to_key(), NIL)
    if session_id_val.kind != VkInt:
      raise new_exception(types.Exception, "LLM close_session requires session_id")
    var err: cstring = nil
    let status = bridge.close_session_fn(session_id_val.to_int(), addr err)
    let err_msg = llm_take_cstring(err)
    if status != int32(GlhsOk):
      llm_raise_bridge_error(err_msg, "Session.close failed")
    actor_reply_for_test(ctx, "ok".to_symbol_value())
  else:
    raise new_exception(types.Exception, "Unknown LLM actor op: " & op_val.str)

  NIL

proc ensure_llm_host_actor(vm: ptr VirtualMachine): Value =
  let bridge = current_llm_bridge()
  if bridge == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  if bridge.actor_handle.kind == VkActor:
    return bridge.actor_handle

  if THREAD_DATA[0].channel == nil:
    init_thread_pool()
  if not actor_runtime_active():
    init_actor_runtime()
    actor_enable_for_test(1)

  let actor = actor_spawn_value(NativeFn(llm_bridge_request_actor_native).to_value(), NIL)
  bridge.actor_handle = actor
  return actor

proc llm_load_model_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                           has_keyword_args: bool): Value {.gcsafe.} =
  if current_llm_bridge() == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "genex/llm/load_model requires a file path")
  let path_val = get_positional_arg(args, 0, has_keyword_args)
  if path_val.kind != VkString:
    raise new_exception(types.Exception, "Model path must be a string")
  let opts = llm_expect_map_arg(args, arg_count, has_keyword_args, 2, "load_model")
  var actor = NIL
  {.cast(gcsafe).}:
    actor = ensure_llm_host_actor(vm)
  let msg = new_map_value()
  map_data(msg)["op".to_key()] = "load_model".to_value()
  map_data(msg)["path".to_key()] = path_val
  if opts != NIL:
    map_data(msg)["options".to_key()] = opts
  var future = NIL
  {.cast(gcsafe).}:
    future = actor_send_value(vm, actor, msg, true)
  let reply = llm_bridge_poll_reply(vm, future, "genex/llm/load_model")
  new_llm_model_instance(map_data(reply)["model_id".to_key()].to_int())

proc llm_model_new_session_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                  has_keyword_args: bool): Value {.gcsafe.} =
  if current_llm_bridge() == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  let model_id = llm_model_id(get_positional_arg(args, 0, has_keyword_args), "Model.new_session")
  let opts = llm_expect_map_arg(args, arg_count, has_keyword_args, 2, "new_session")
  var actor = NIL
  {.cast(gcsafe).}:
    actor = ensure_llm_host_actor(vm)
  let msg = new_map_value()
  map_data(msg)["op".to_key()] = "new_session".to_value()
  map_data(msg)["model_id".to_key()] = model_id.to_value()
  if opts != NIL:
    map_data(msg)["options".to_key()] = opts
  var future = NIL
  {.cast(gcsafe).}:
    future = actor_send_value(vm, actor, msg, true)
  let reply = llm_bridge_poll_reply(vm, future, "Model.new_session")
  new_llm_session_instance(map_data(reply)["session_id".to_key()].to_int())

proc llm_session_infer_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                              has_keyword_args: bool): Value {.gcsafe.} =
  if current_llm_bridge() == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  if get_positional_count(arg_count, has_keyword_args) < 2:
    raise new_exception(types.Exception, "Session.infer requires self and a prompt string")
  let session_id = llm_session_id(get_positional_arg(args, 0, has_keyword_args), "Session.infer")
  let prompt_val = get_positional_arg(args, 1, has_keyword_args)
  if prompt_val.kind != VkString:
    raise new_exception(types.Exception, "Session.infer prompt must be a string")
  let opts = llm_expect_map_arg(args, arg_count, has_keyword_args, 3, "infer")
  var actor = NIL
  {.cast(gcsafe).}:
    actor = ensure_llm_host_actor(vm)
  let msg = new_map_value()
  map_data(msg)["op".to_key()] = "infer".to_value()
  map_data(msg)["session_id".to_key()] = session_id.to_value()
  map_data(msg)["prompt".to_key()] = prompt_val
  if opts != NIL:
    map_data(msg)["options".to_key()] = opts
  var future = NIL
  {.cast(gcsafe).}:
    future = actor_send_value(vm, actor, msg, true)
  llm_bridge_poll_reply(vm, future, "Session.infer")

proc llm_model_close_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                            has_keyword_args: bool): Value {.gcsafe.} =
  discard arg_count
  if current_llm_bridge() == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  let model_id = llm_model_id(get_positional_arg(args, 0, has_keyword_args), "Model.close")
  var actor = NIL
  {.cast(gcsafe).}:
    actor = ensure_llm_host_actor(vm)
  let msg = new_map_value()
  map_data(msg)["op".to_key()] = "close_model".to_value()
  map_data(msg)["model_id".to_key()] = model_id.to_value()
  var future = NIL
  {.cast(gcsafe).}:
    future = actor_send_value(vm, actor, msg, true)
  discard llm_bridge_poll_reply(vm, future, "Model.close")
  NIL

proc llm_session_close_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                              has_keyword_args: bool): Value {.gcsafe.} =
  discard arg_count
  if current_llm_bridge() == nil:
    raise new_exception(types.Exception, "LLM host bridge is not installed")
  let session_id = llm_session_id(get_positional_arg(args, 0, has_keyword_args), "Session.close")
  var actor = NIL
  {.cast(gcsafe).}:
    actor = ensure_llm_host_actor(vm)
  let msg = new_map_value()
  map_data(msg)["op".to_key()] = "close_session".to_value()
  map_data(msg)["session_id".to_key()] = session_id.to_value()
  var future = NIL
  {.cast(gcsafe).}:
    future = actor_send_value(vm, actor, msg, true)
  discard llm_bridge_poll_reply(vm, future, "Session.close")
  NIL

proc host_scheduler_dispatcher(vm: ptr VirtualMachine) {.gcsafe.} =
  {.cast(gcsafe).}:
    let vm_user_data = cast[pointer](vm)
    for entry in host_scheduler_callback_entries:
      if entry.callback != nil:
        entry.callback(vm_user_data, entry.callback_user_data)

proc host_register_scheduler_callback_bridge(callback: GeneHostSchedulerTickFn, callback_user_data: pointer): int32 {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    if callback == nil:
      return int32(GeneExtErr)
    host_scheduler_callback_entries.add(
      HostSchedulerCallbackEntry(callback: callback, callback_user_data: callback_user_data)
    )
    if not host_scheduler_dispatcher_registered:
      host_scheduler_dispatcher_registered = true
      register_scheduler_callback(host_scheduler_dispatcher)
    int32(GeneExtOk)

proc clone_extension_port_state(init_state: Value): Value =
  if init_state == NIL:
    return NIL
  prepare_actor_payload_for_send(init_state).value

proc register_extension_port_runtime*(name: string, kind: ExtensionPortKind,
                                      handler: Value, init_state: Value = NIL,
                                      pool_size = 1): Value =
  if name.len == 0:
    raise new_exception(types.Exception, "extension port name cannot be empty")
  if handler.kind notin {VkFunction, VkNativeFn, VkBlock}:
    raise new_exception(types.Exception, "extension port handler must be callable")
  if kind != EpkFactory and not actor_runtime_active():
    raise new_exception(types.Exception, "extension ports require the actor runtime to be enabled")
  if registered_extension_ports.hasKey(name):
    raise new_exception(types.Exception, "extension port already registered: " & name)

  let reg = RegisteredExtensionPort(
    name: name,
    kind: kind,
    handler: handler,
    init_state: init_state,
    pool_size: max(1, pool_size),
    handles: @[]
  )
  registered_extension_ports[name] = reg

  case kind
  of EpkSingleton:
    let actor = actor_spawn_value(handler, init_state)
    reg.handles = @[actor]
    actor
  of EpkPool:
    let handles = new_array_value()
    for i in 0..<reg.pool_size:
      let state_val =
        if i == 0: init_state
        else: clone_extension_port_state(init_state)
      let actor = actor_spawn_value(handler, state_val)
      reg.handles.add(actor)
      array_data(handles).add(actor)
    handles
  of EpkFactory:
    NIL

proc spawn_registered_extension_factory_port*(name: string, init_state: Value = NIL): Value =
  if not registered_extension_ports.hasKey(name):
    raise new_exception(types.Exception, "extension port factory not found: " & name)
  let reg = registered_extension_ports[name]
  if reg.kind != EpkFactory:
    raise new_exception(types.Exception, "extension port is not a factory: " & name)
  if not actor_runtime_active():
    raise new_exception(types.Exception, "extension ports require the actor runtime to be enabled")
  let state_val =
    if init_state != NIL: init_state
    else: reg.init_state
  actor_spawn_value(reg.handler, state_val)

proc clear_registered_extension_ports_for_test*() =
  registered_extension_ports.clear()

proc host_register_port_bridge*(name: cstring, kind: int32, pool_size: int32,
                                handler: Value, init_state: Value,
                                out_handle: ptr Value): int32 {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    if name == nil:
      return int32(GeneExtErr)
    try:
      let port_kind =
        case kind
        of int32(EpkSingleton.ord): EpkSingleton
        of int32(EpkPool.ord): EpkPool
        of int32(EpkFactory.ord): EpkFactory
        else: return int32(GeneExtErr)
      let handle = register_extension_port_runtime($name, port_kind, handler, init_state, max(1, int(pool_size)))
      if out_handle != nil:
        out_handle[] = handle
      int32(GeneExtOk)
    except CatchableError:
      int32(GeneExtErr)

proc host_call_port_bridge*(port_handle: Value, msg: Value, timeout_ms: int32,
                            out_value: ptr Value): int32 {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    if VM == nil:
      return int32(GeneExtErr)
    try:
      let future = actor_send_value(VM, port_handle, msg, true)
      let deadline = epochTime() + (float(timeout_ms) / 1000.0)
      let future_obj = future.ref.future
      while future_obj.state == FsPending and epochTime() < deadline:
        VM.event_loop_counter = 100
        vm_poll_event_loop(VM)
        sleep(10)

      if future_obj.state != FsSuccess:
        return int32(GeneExtErr)
      if out_value != nil:
        out_value[] = future_obj.value
      int32(GeneExtOk)
    except CatchableError:
      int32(GeneExtErr)

proc load_extension*(vm: ptr VirtualMachine, path: string): Namespace =
  ## Load a dynamic library extension and return its namespace
  when defined(gene_wasm):
    discard vm
    discard path
    raise_wasm_unsupported("dynamic_extension_loading")
  else:
    var lib_path = path

    # Try adding extension suffix if not present
    if not (path.endsWith(".so") or path.endsWith(".dll") or path.endsWith(".dylib")):
      when defined(windows):
        lib_path = path & ".dll"
      elif defined(macosx):
        lib_path = path & ".dylib"
      else:
        lib_path = path & ".so"

    let callback_base = VmCreatedCallbacks.len

    when defined(posix):
      # Use RTLD_GLOBAL on POSIX to make main executable symbols available
      let handle = loadLibGlobal(lib_path.cstring)
    else:
      let handle = loadLib(lib_path.cstring)

    if handle.isNil:
      raise new_exception(types.Exception, "[GENE.EXT.LOAD_FAILED] Failed to load extension: " & lib_path)

    # Some extension modules register with VmCreatedCallbacks at module load.
    # Run newly-added callbacks immediately when loading dynamically.
    run_vm_created_callbacks(callback_base)
    let post_load_callback_base = VmCreatedCallbacks.len

    let init_fn = cast[GeneExtensionInitFn](handle.symAddr("gene_init"))
    if init_fn == nil:
      raise new_exception(
        types.Exception,
        "[GENE.EXT.SYMBOL_MISSING] Required symbol 'gene_init' not found in extension: " & lib_path
      )

    var ext_ns: Namespace = nil
    var host = GeneHostAbi(
      abi_version: GENE_EXT_ABI_VERSION,
      user_data: cast[pointer](vm),
      app_value: App,
      symbols_data: if vm != nil and vm.symbols != nil: cast[pointer](vm.symbols) else: nil,
      log_message_fn: host_log_message_bridge,
      register_scheduler_callback_fn: host_register_scheduler_callback_bridge,
      register_port_fn: host_register_port_bridge,
      call_port_fn: host_call_port_bridge,
      result_namespace: addr ext_ns
    )

    let init_status = init_fn(addr host)

    # gene_init may also append VM-created callbacks (e.g. class registration hooks).
    run_vm_created_callbacks(post_load_callback_base)

    if init_status == int32(GeneExtAbiMismatch):
      raise new_exception(
        types.Exception,
        "[GENE.EXT.ABI_MISMATCH] Extension ABI mismatch for: " & lib_path
      )
    if init_status != int32(GeneExtOk):
      raise new_exception(
        types.Exception,
        "[GENE.EXT.INIT_FAILED] gene_init failed for extension: " & lib_path
      )

    if ext_ns == nil:
      ext_ns = lookup_genex_namespace(infer_extension_name(lib_path))
    if ext_ns == nil:
      raise new_exception(
        types.Exception,
        "[GENE.EXT.INIT_FAILED] Extension did not publish a namespace: " & lib_path
      )

    let ext_name = infer_extension_name(lib_path)
    if ext_ns.module == nil:
      ext_ns.module = Module(
        source_type: StFile,
        source: lib_path.to_value(),
        pkg: nil,
        name: ext_name,
        ns: ext_ns,
        handle: handle,
        props: initTable[Key, Value]()
      )
    else:
      ext_ns.module.handle = handle
      ext_ns.module.ns = ext_ns
      if ext_ns.module.name.len == 0:
        ext_ns.module.name = ext_name

    if ext_name == "llm":
      install_llm_host_bridge(ext_ns, handle)

    result = ext_ns


# No longer needed since we use deterministic hashing

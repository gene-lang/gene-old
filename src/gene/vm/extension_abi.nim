## Stable native extension ABI for gene-old.
##
## Extensions must export:
##   proc gene_init(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.}

import ../types
import ../logging_core

const
  GENE_EXT_ABI_VERSION* = 3'u32

type
  GeneExtStatus* = enum
    GeneExtOk = 0
    GeneExtErr = 1
    GeneExtAbiMismatch = 2

  GeneHostLogFn* = proc(level: int32, logger_name: cstring, message: cstring) {.cdecl, gcsafe.}
  GeneHostSchedulerTickFn* = proc(vm_user_data: pointer, callback_user_data: pointer) {.cdecl, gcsafe.}
  GeneHostRegisterSchedulerCallbackFn* = proc(callback: GeneHostSchedulerTickFn, callback_user_data: pointer): int32 {.cdecl, gcsafe.}
  GeneHostRegisterPortFn* = proc(name: cstring, kind: int32, pool_size: int32,
                                 handler: Value, init_state: Value,
                                 out_handle: ptr Value): int32 {.cdecl, gcsafe.}
  GeneHostCallPortFn* = proc(port_handle: Value, msg: Value, timeout_ms: int32,
                             out_value: ptr Value): int32 {.cdecl, gcsafe.}

  GeneHostAbi* {.bycopy.} = object
    abi_version*: uint32
    user_data*: pointer            ## host-owned context (ptr VirtualMachine)
    app_value*: Value
    symbols_data*: pointer         ## ptr ManagedSymbols
    log_message_fn*: GeneHostLogFn
    register_scheduler_callback_fn*: GeneHostRegisterSchedulerCallbackFn
    register_port_fn*: GeneHostRegisterPortFn
    call_port_fn*: GeneHostCallPortFn
    result_namespace*: ptr Namespace

  GeneExtensionInitFn* = proc(host: ptr GeneHostAbi): int32 {.cdecl.}

var extension_host_log_message_cb: GeneHostLogFn = nil

proc apply_extension_host_context*(host: ptr GeneHostAbi): ptr VirtualMachine =
  ## Synchronize extension-local globals with host runtime state.
  if host == nil:
    return nil
  let vm = cast[ptr VirtualMachine](host.user_data)
  if host.symbols_data != nil:
    SYMBOLS_SHARED = cast[ptr ManagedSymbols](host.symbols_data)
    SYMBOLS = SYMBOLS_SHARED[]
  if host.app_value != NIL:
    App = host.app_value
  extension_host_log_message_cb = host.log_message_fn
  vm

proc extension_log_enabled*(level: LogLevel, logger_name: string): bool {.gcsafe.} =
  if extension_host_log_message_cb != nil:
    return true
  log_enabled(level, logger_name)

proc extension_log_message*(level: LogLevel, logger_name, message: string) {.gcsafe.} =
  if extension_host_log_message_cb != nil:
    extension_host_log_message_cb(int32(level), logger_name.cstring, message.cstring)
  else:
    log_message(level, logger_name, message)

proc run_extension_vm_created_callbacks*() =
  ## Execute extension-local VM-created callbacks after host context is applied.
  for callback in VmCreatedCallbacks:
    callback()

proc register_extension_port*(host: ptr GeneHostAbi, name: string,
                              kind: ExtensionPortKind, handler: Value,
                              init_state: Value = NIL, pool_size = 1,
                              out_handle: ptr Value = nil): GeneExtStatus =
  if host == nil or host.register_port_fn == nil or name.len == 0:
    return GeneExtErr
  let status = host.register_port_fn(
    name.cstring,
    int32(kind.ord),
    int32(pool_size),
    handler,
    init_state,
    out_handle
  )
  cast[GeneExtStatus](status)

proc register_singleton_port*(host: ptr GeneHostAbi, name: string,
                              handler: Value, init_state: Value = NIL,
                              out_handle: ptr Value = nil): GeneExtStatus =
  register_extension_port(host, name, EpkSingleton, handler, init_state, 1, out_handle)

proc register_port_pool*(host: ptr GeneHostAbi, name: string, pool_size: int,
                         handler: Value, init_state: Value = NIL,
                         out_handle: ptr Value = nil): GeneExtStatus =
  register_extension_port(host, name, EpkPool, handler, init_state, pool_size, out_handle)

proc register_port_factory*(host: ptr GeneHostAbi, name: string,
                            handler: Value): GeneExtStatus =
  register_extension_port(host, name, EpkFactory, handler, NIL, 1, nil)

proc call_extension_port*(host: ptr GeneHostAbi, port_handle: Value, msg: Value,
                          timeout_ms = 2000): Value =
  if host == nil or host.call_port_fn == nil:
    return NIL
  var res = NIL
  let status = host.call_port_fn(port_handle, msg, int32(timeout_ms), addr res)
  if status != int32(GeneExtOk):
    return NIL
  res

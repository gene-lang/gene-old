{.push warning[ResultShadowed]: off, warning[UnreachableCode]: off, warning[UnusedImport]: off.}

import tables, strutils, strformat, algorithm, options, streams, locks
import times, os
import asyncdispatch  # For event loop polling in async support

import ./types
import ./logging_core
from ./types/runtime_types import
  validate_type,
  validate_or_coerce_type,
  emit_type_warning,
  is_compatible,
  runtime_type_name,
  new_runtime_type_object,
  new_runtime_type_value,
  is_runtime_type_value,
  runtime_type_payload,
  resolve_constructor,
  resolve_initializer,
  resolve_method
import ./compiler
from ./parser import read, read_all
import ./hash_map_support
import ./vm/args
import ./vm/module
import ./vm/utils
import ./vm/profile
export profile
import ./serdes
import ./wasm_host_abi
import ./native/runtime
import ./native/hir
import ./native/trampoline
const DEBUG_VM = false
const
  CATCH_PC_ASYNC_BLOCK = -2
  CATCH_PC_ASYNC_FUNCTION = -3
  EVENT_LOOP_POLL_INTERVAL = 100
  VmExecLogger = "gene/vm/exec"
  VmDispatchLogger = "gene/vm/dispatch"

template vm_log(level: LogLevel, logger_name: string, message: untyped) =
  if log_enabled(level, logger_name):
    log_message(level, logger_name, message)

template is_method_frame(f: Frame): bool =
  f.kind in {FkMethod, FkMacroMethod}

template is_function_like(kind: FrameKind): bool =
  kind in {FkFunction, FkMethod, FkMacroMethod}

template same_value_identity(a: Value, b: Value): bool =
  cast[uint64](a) == cast[uint64](b)

include ./vm/core_helpers
include ./vm/checks

import ./vm/arithmetic
import ./vm/generator
import ./vm/thread
import ./vm/actor
import ./vm/pubsub

# Forward declarations needed by vm/async and vm/native
proc exec*(self: ptr VirtualMachine): Value
proc exec_function*(self: ptr VirtualMachine, fn: Value, args: seq[Value]): Value
proc exec_method*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value]): Value
proc exec_method_kw*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)]): Value
proc exec_method_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], caller_context: Frame): Value
proc exec_method_kw_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)], caller_context: Frame): Value
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string
proc spawn_thread(code: Value, return_value: bool): Value
proc poll_event_loop*(self: ptr VirtualMachine)
proc run_module_init*(self: ptr VirtualMachine, module_ns: Namespace): tuple[ran: bool, value: Value]
proc exec_callable*(self: ptr VirtualMachine, callable: Value, args: seq[Value]): Value
proc exec_callable_with_self*(self: ptr VirtualMachine, callable: Value, self_value: Value, args: seq[Value]): Value
proc exec_continue*(self: ptr VirtualMachine): Value

# Forward declarations for adapter functions
proc exec_interface(vm: ptr VirtualMachine, name: Value)
proc exec_interface_method(vm: ptr VirtualMachine, name: Value)
proc exec_interface_prop(vm: ptr VirtualMachine, name: Value, readonly: bool)
proc exec_implement(vm: ptr VirtualMachine, interface_name: Value, is_external: bool, has_body: bool)
proc exec_implement_method(vm: ptr VirtualMachine, method_name: Value)
proc exec_implement_ctor(vm: ptr VirtualMachine)
proc exec_adapter(vm: ptr VirtualMachine, ctor_args: seq[Value] = @[], kw_pairs: seq[(Key, Value)] = @[])
proc adapter_get_member(vm: ptr VirtualMachine, adapter_val: Value, key: Key): Value
proc adapter_set_member(adapter: Adapter, key: Key, value: Value)
proc adapter_member_or_nil(vm: ptr VirtualMachine, adapter_val: Value, prop: Value): Value
proc dispatch_adapter_method(vm: ptr VirtualMachine, obj: Value, method_name: string, args: seq[Value]): Value
proc dispatch_adapter_method_kw(vm: ptr VirtualMachine, obj: Value, method_name: string, args: seq[Value], kw_pairs: seq[(Key, Value)]): Value
# Forward declarations for adapter internal functions
proc adapter_internal_get_member*(adapter_internal_val: Value, key: Key): Value
proc adapter_internal_set_member*(adapter_internal_val: Value, key: Key, value: Value)
proc adapter_internal_member_or_nil*(adapter_internal_val: Value, prop: Value): Value

include "./vm/native"

import ./vm/async
include ./vm/async_exec

when not defined(noExtensions):
  import ./vm/extension

include ./vm/exceptions
include ./vm/dispatch
include ./vm/vm_modules
include ./vm/exec
include ./vm/exec_support
include ./vm/adapter
include ./vm/entry
include ./vm/diagnostics
include ./vm/runtime_helpers

set_vm_exec_callable_hook(exec_callable)
set_vm_exec_callable_with_self_hook(exec_callable_with_self)
set_vm_poll_event_loop_hook(poll_event_loop)
set_serdes_module_loader_hook(proc(module_path: string): Namespace {.nimcall.} =
  ensure_runtime_module_loaded(VM, module_path)
)

include "./stdlib"

# Register default on_member_missing handler on genex namespace
# This replaces the hard-coded ensure_genex_extension checks in exec.nim
proc genex_extension_loader(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let name_val = get_positional_arg(args, 0, has_keyword_args)
    if name_val.kind != VkString and name_val.kind != VkSymbol:
      return NIL
    let part = name_val.str
    when not defined(noExtensions):
      return ensure_genex_extension(vm, part)
    else:
      return NIL

# Register via VmCreatedCallbacks so it runs after App is initialized
VmCreatedCallbacks.add proc() =
  if App != NIL and App.kind == VkApplication and App.app.genex_ns.kind == VkNamespace:
    let loader_ref = new_ref(VkNativeFn)
    loader_ref.native_fn = genex_extension_loader
    App.app.genex_ns.ref.ns.on_member_missing.add(loader_ref.to_ref_value())

{.pop.}

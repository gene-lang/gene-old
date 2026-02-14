{.push warning[ResultShadowed]: off, warning[UnreachableCode]: off, warning[UnusedImport]: off.}

import tables, strutils, strformat, algorithm, options, streams
import times, os
import asyncdispatch  # For event loop polling in async support

import ./types
from ./types/runtime_types import
  validate_type,
  validate_or_coerce_type,
  emit_type_warning,
  runtime_type_name,
  new_runtime_type_object,
  resolve_constructor,
  resolve_initializer,
  resolve_method
import ./compiler
from ./parser import read, read_all
import ./vm/args
import ./vm/module
import ./vm/utils
import ./vm/profile
export profile
import ./serdes
import ./native/runtime
import ./native/hir
import ./native/trampoline
const DEBUG_VM = false
const
  CATCH_PC_ASYNC_BLOCK = -2
  CATCH_PC_ASYNC_FUNCTION = -3
  EVENT_LOOP_POLL_INTERVAL = 100

template is_method_frame(f: Frame): bool =
  f.kind in {FkMethod, FkMacroMethod}

template is_function_like(kind: FrameKind): bool =
  kind in {FkFunction, FkMethod, FkMacroMethod}

template same_value_identity(a: Value, b: Value): bool =
  cast[uint64](a) == cast[uint64](b)

include ./vm/core_helpers

import ./vm/arithmetic
import ./vm/generator
import ./vm/thread

# Forward declarations needed by vm/async and vm/native
proc exec*(self: ptr VirtualMachine): Value
proc exec_function*(self: ptr VirtualMachine, fn: Value, args: seq[Value]): Value
proc exec_method*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value]): Value
proc exec_method_kw*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)]): Value
proc exec_method_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], caller_context: Frame): Value
proc exec_method_kw_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)], caller_context: Frame): Value
proc execute_future_callbacks*(self: ptr VirtualMachine, future_obj: FutureObj)
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string
proc spawn_thread(code: ptr Gene, return_value: bool): Value
proc poll_event_loop*(self: ptr VirtualMachine)
proc run_module_init*(self: ptr VirtualMachine, module_ns: Namespace): tuple[ran: bool, value: Value]
proc exec_callable*(self: ptr VirtualMachine, callable: Value, args: seq[Value]): Value
proc exec_continue*(self: ptr VirtualMachine): Value

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
include ./vm/entry
include ./vm/runtime_helpers

set_vm_exec_callable_hook(exec_callable)

include "./stdlib"

# Temporarily import http and sqlite modules until extension loading is fixed
when not defined(noExtensions):
  import "../genex/http"
  import "../genex/sqlite"
  import "../genex/html"
  import "../genex/logging"
  import "../genex/test"
  import "../genex/ai/bindings"
  when defined(geneLLM):
    import "../genex/llm"

{.pop.}

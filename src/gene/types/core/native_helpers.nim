## Native function argument helpers: get_positional_arg, get_keyword_arg,
## call_native_fn, and related converters.
## Included from core.nim — shares its scope.

#################### Native ######################

converter to_value*(f: NativeFn): Value {.inline.} =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  result = r.to_ref_value()

converter to_value*(t: type_defs.Thread): Value {.inline.} =
  let r = new_ref(VkThread)
  r.thread = t
  return r.to_ref_value()

converter to_value*(m: type_defs.ThreadMessage): Value {.inline.} =
  let r = new_ref(VkThreadMessage)
  r.thread_message = m
  return r.to_ref_value()

converter to_value*(a: type_defs.Actor): Value {.inline.} =
  let r = new_ref(VkActor)
  r.actor = a
  r.to_ref_value()

converter to_value*(ctx: type_defs.ActorContext): Value {.inline.} =
  let r = new_ref(VkActorContext)
  r.actor_context = ctx
  r.to_ref_value()

# Helper functions for new NativeFn signature
proc get_positional_arg*(args: ptr UncheckedArray[Value], index: int, has_keyword_args: bool): Value {.inline.} =
  ## Get positional argument (handles keyword offset automatically)
  let offset = if has_keyword_args: 1 else: 0
  return args[offset + index]

proc get_keyword_arg*(args: ptr UncheckedArray[Value], name: string): Value {.inline.} =
  ## Get keyword argument by name
  if args[0].kind == VkMap:
    return map_data(args[0]).get_or_default(name.to_key(), NIL)
  else:
    return NIL

proc has_keyword_arg*(args: ptr UncheckedArray[Value], name: string): bool {.inline.} =
  ## Check if keyword argument exists
  if args[0].kind == VkMap:
    return map_data(args[0]).hasKey(name.to_key())
  else:
    return false

proc get_positional_count*(arg_count: int, has_keyword_args: bool): int {.inline.} =
  ## Get the number of positional arguments
  if has_keyword_args: arg_count - 1 else: arg_count

# Helper functions specifically for native methods
proc get_self*(args: ptr UncheckedArray[Value], has_keyword_args: bool): Value {.inline.} =
  ## Get self object for native methods (always first positional argument)
  return get_positional_arg(args, 0, has_keyword_args)

proc get_method_arg*(args: ptr UncheckedArray[Value], index: int, has_keyword_args: bool): Value {.inline.} =
  ## Get method argument by index (index 0 = first argument after self)
  return get_positional_arg(args, index + 1, has_keyword_args)

proc get_method_arg_count*(arg_count: int, has_keyword_args: bool): int {.inline.} =
  ## Get the number of method arguments (excluding self)
  let positional_count = get_positional_count(arg_count, has_keyword_args)
  if positional_count > 0: positional_count - 1 else: 0

# Migration helpers
proc get_legacy_args*(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): seq[Value] =
  ## Helper to convert to seq[Value] for easier migration
  result = newSeq[Value]()
  let offset = if has_keyword_args: 1 else: 0
  for i in offset..<arg_count:
    result.add(args[i])

proc create_gene_args*(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  ## For functions that need Gene object temporarily during migration
  var gene_args = new_gene_value()
  let offset = if has_keyword_args: 1 else: 0
  for i in offset..<arg_count:
    gene_args.gene.children.add(args[i])
  return gene_args

# Helper for calling native functions with proper casting
proc call_native_fn*(fn: NativeFn, vm: ptr VirtualMachine, args: openArray[Value], has_keyword_args: bool = false): Value {.inline.} =
  ## Helper to call native function with proper array casting
  if args.len == 0:
    return fn(vm, nil, 0, has_keyword_args)
  else:
    return fn(vm, cast[ptr UncheckedArray[Value]](args[0].unsafeAddr), args.len, has_keyword_args)

type VmExecCallableHook* = proc(vm: ptr VirtualMachine, callable: Value, args: seq[Value]): Value {.nimcall.}
type VmExecCallableWithSelfHook* = proc(vm: ptr VirtualMachine, callable: Value, self_value: Value, args: seq[Value]): Value {.nimcall.}
type VmPollEventLoopHook* = proc(vm: ptr VirtualMachine) {.nimcall.}

var vm_exec_callable_hook*: VmExecCallableHook
var vm_exec_callable_with_self_hook*: VmExecCallableWithSelfHook
var vm_poll_event_loop_hook*: VmPollEventLoopHook

proc set_vm_exec_callable_hook*(hook: VmExecCallableHook) {.inline.} =
  vm_exec_callable_hook = hook

proc set_vm_exec_callable_with_self_hook*(hook: VmExecCallableWithSelfHook) {.inline.} =
  vm_exec_callable_with_self_hook = hook

proc set_vm_poll_event_loop_hook*(hook: VmPollEventLoopHook) {.inline.} =
  vm_poll_event_loop_hook = hook

proc vm_exec_callable*(vm: ptr VirtualMachine, callable: Value, args: seq[Value]): Value {.inline.} =
  if vm_exec_callable_hook.isNil:
    not_allowed("VM callable hook is not initialized")
  vm_exec_callable_hook(vm, callable, args)

proc vm_exec_callable_with_self*(vm: ptr VirtualMachine, callable: Value, self_value: Value, args: seq[Value]): Value {.inline.} =
  ## Call a callable with a self value for IkSelf, but only pass args to the matcher.
  if vm_exec_callable_with_self_hook.isNil:
    # Fall back to regular callable (self not set)
    return vm_exec_callable(vm, callable, args)
  vm_exec_callable_with_self_hook(vm, callable, self_value, args)

proc vm_poll_event_loop*(vm: ptr VirtualMachine) {.inline.} =
  if vm_poll_event_loop_hook.isNil:
    not_allowed("VM poll hook is not initialized")
  vm_poll_event_loop_hook(vm)

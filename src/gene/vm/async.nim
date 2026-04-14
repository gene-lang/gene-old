import ../types
import asyncdispatch  # For Future procs: finished, failed, read
import tables

# Note: execute_future_callbacks is implemented in vm.nim and imported there

proc new_async_error*(code: string, message: string, location: string = "async"): Value =
  ## Create a typed runtime error value for async/thread contract failures.
  if App == NIL or App.kind != VkApplication or App.app.exception_class.kind != VkClass:
    return (code & ": " & message).to_value()

  var props = initTable[Key, Value]()
  props["code".to_key()] = code.to_value()
  props["message".to_key()] = message.to_value()
  props["location".to_key()] = location.to_value()
  return new_instance_value(App.app.exception_class.ref.class, props)

# Update a future from its underlying Nim future
proc update_future_from_nim*(vm: ptr VirtualMachine, future_obj: FutureObj) {.gcsafe.} =
  ## Check if the underlying Nim future has completed and update Gene future state
  ## This should be called during event loop polling
  if future_obj.state != FsPending:
    return  # Already completed

  # Check Nim futures
  if future_obj.nim_future.isNil:
    return  # No Nim future to check

  if finished(future_obj.nim_future):
    # Nim future has completed - copy its result
    if failed(future_obj.nim_future):
      discard future_obj.fail(new_async_error("GENE.ASYNC.FAILURE", "Async operation failed", "nim_future"))
    else:
      discard future_obj.complete(read(future_obj.nim_future))

proc run_callback_now(vm: ptr VirtualMachine, callback: Value, arg: Value): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    try:
      discard vm_exec_callable(vm, callback, @[arg])
      return true
    except CatchableError:
      return false

proc future_state_name(state: FutureState): string {.inline.} =
  case state:
  of FsPending:
    "pending"
  of FsSuccess:
    "success"
  of FsFailure:
    "failure"
  of FsCancelled:
    "cancelled"

proc raise_future_already_terminal(op_name: string, state: FutureState) {.noreturn.} =
  let msg =
    "GENE.ASYNC.ALREADY_TERMINAL: cannot " & op_name &
    " a future in state " & future_state_name(state)
  raise new_exception(types.Exception, msg)

proc schedule_future_callbacks(vm: ptr VirtualMachine, future_obj: FutureObj) =
  ## Ensure callback execution happens on the next scheduler tick.
  var tracked = false
  for pending in vm.pending_futures:
    if pending == future_obj:
      tracked = true
      break
  if not tracked:
    vm.pending_futures.add(future_obj)
  vm.poll_enabled = true

proc execute_future_callbacks*(vm: ptr VirtualMachine, future_obj: FutureObj) {.gcsafe.} =
  ## Unified callback execution path for all future completion sources.
  if future_obj.state == FsSuccess:
    # Snapshot then clear to prevent re-entrant poll loops from re-invoking
    # the same callback list before this execution finishes.
    let callbacks = future_obj.success_callbacks
    future_obj.success_callbacks.setLen(0)
    for callback in callbacks:
      if not run_callback_now(vm, callback, future_obj.value):
        future_obj.state = FsFailure
        if vm.current_exception == NIL:
          future_obj.value = new_async_error("GENE.ASYNC.CALLBACK_FAILURE", "Future success callback failed", "callback")
        else:
          future_obj.value = vm.current_exception
        break

  elif future_obj.state in {FsFailure, FsCancelled}:
    # Snapshot then clear for the same re-entrancy reason as success path.
    let callbacks = future_obj.failure_callbacks
    future_obj.failure_callbacks.setLen(0)
    for callback in callbacks:
      if not run_callback_now(vm, callback, future_obj.value):
        if vm.current_exception != NIL:
          future_obj.value = vm.current_exception
        break

proc future_on_success(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # Extract future and callback from args
  if arg_count < 2:
    raise new_exception(types.Exception, "Future.on_success requires 2 arguments (self and callback)")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)
  let callback_arg = get_positional_arg(args, 1, has_keyword_args)

  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "on_success can only be called on a Future")

  # Validate callback is callable
  if callback_arg.kind notin {VkFunction, VkNativeFn, VkBlock}:
    raise new_exception(types.Exception, "on_success callback must be a function or block")

  let future_obj = future_arg.ref.future

  # Add callback
  if future_obj.state == FsPending:
    # Store callback for later execution when future completes
    future_obj.success_callbacks.add(callback_arg)
  elif future_obj.state == FsSuccess:
    # Late registration executes on the next scheduler tick for uniformity.
    future_obj.success_callbacks.add(callback_arg)
    schedule_future_callbacks(vm, future_obj)
  # If failed/cancelled, don't add to success callbacks.

  # Return the future for chaining
  return future_arg

proc future_on_failure(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # Extract future and callback from args
  if arg_count < 2:
    raise new_exception(types.Exception, "Future.on_failure requires 2 arguments (self and callback)")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)
  let callback_arg = get_positional_arg(args, 1, has_keyword_args)

  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "on_failure can only be called on a Future")

  # Validate callback is callable
  if callback_arg.kind notin {VkFunction, VkNativeFn, VkBlock}:
    raise new_exception(types.Exception, "on_failure callback must be a function or block")

  let future_obj = future_arg.ref.future

  # Add callback
  if future_obj.state == FsPending:
    # Store callback for later execution when future fails
    future_obj.failure_callbacks.add(callback_arg)
  elif future_obj.state in {FsFailure, FsCancelled}:
    # Late registration executes on the next scheduler tick for uniformity.
    future_obj.failure_callbacks.add(callback_arg)
    schedule_future_callbacks(vm, future_obj)
  # If succeeded, don't add to failure callbacks.

  # Return the future for chaining
  return future_arg

proc future_cancel(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # Cancel a future with optional reason payload.
  if arg_count < 1:
    raise new_exception(types.Exception, "Future.cancel requires a future")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)
  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "cancel can only be called on a Future")

  let reason_arg =
    if get_positional_count(arg_count, has_keyword_args) > 1:
      get_positional_arg(args, 1, has_keyword_args)
    else:
      new_async_error("GENE.ASYNC.CANCELLED", "Future cancelled", "cancel")

  let future_obj = future_arg.ref.future
  if not future_obj.cancel(reason_arg):
    raise_future_already_terminal("cancel", future_obj.state)
  execute_future_callbacks(vm, future_obj)
  return future_arg

proc future_fail(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # Fail a future with an error value (normalizes to Exception like throw does).
  if arg_count < 2:
    raise new_exception(types.Exception, "Future.fail requires a future and an error value")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)
  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "fail can only be called on a Future")

  let error_arg = get_positional_arg(args, 1, has_keyword_args)
  let error_val = normalize_exception(error_arg)

  let future_obj = future_arg.ref.future
  if not future_obj.fail(error_val):
    raise_future_already_terminal("fail", future_obj.state)
  execute_future_callbacks(vm, future_obj)
  return future_arg

proc future_state(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # Get the state of a future
  # When called as a method, args contains the future as the first child
  if arg_count == 0:
    raise new_exception(types.Exception, "Future.state requires a future object")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)

  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "state can only be called on a Future")

  let future_obj = future_arg.ref.future

  # Return state as a symbol
  case future_obj.state:
    of FsPending:
      return "pending".to_symbol_value()
    of FsSuccess:
      return "success".to_symbol_value()
    of FsFailure:
      return "failure".to_symbol_value()
    of FsCancelled:
      return "cancelled".to_symbol_value()

proc future_value(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # Get the value of a completed future
  # When called as a method, args contains the future as the first child
  if arg_count == 0:
    raise new_exception(types.Exception, "Future.value requires a future object")

  let future_arg = get_positional_arg(args, 0, has_keyword_args)

  if future_arg.kind != VkFuture:
    raise new_exception(types.Exception, "value can only be called on a Future")

  let future_obj = future_arg.ref.future

  # Return value if completed, NIL if pending
  if future_obj.state in {FsSuccess, FsFailure, FsCancelled}:
    return future_obj.value
  else:
    return NIL

# Initialize async support
proc init_async*() =
  VmCreatedCallbacks.add proc() =
    # Ensure App is initialized
    if App == NIL or App.kind != VkApplication:
      return

    # Native function to complete a future
    proc complete_future_fn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
      # complete_future(future, value) - completes the given future with the value
      if arg_count != 2:
        raise new_exception(types.Exception, "complete_future requires exactly 2 arguments (future and value)")

      let future_arg = get_positional_arg(args, 0, has_keyword_args)
      let value_arg = get_positional_arg(args, 1, has_keyword_args)

      if future_arg.kind != VkFuture:
        raise new_exception(types.Exception, "First argument must be a Future")

      let future_obj = future_arg.ref.future
      if not future_obj.complete(value_arg):
        raise_future_already_terminal("complete", future_obj.state)
      execute_future_callbacks(vm, future_obj)
      return NIL

    proc cancel_future_fn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
      # cancel_future(future, reason?) - cancels the given future
      if arg_count < 1:
        raise new_exception(types.Exception, "cancel_future requires at least 1 argument (future)")

      let future_arg = get_positional_arg(args, 0, has_keyword_args)
      if future_arg.kind != VkFuture:
        raise new_exception(types.Exception, "First argument must be a Future")

      let reason_arg =
        if get_positional_count(arg_count, has_keyword_args) > 1:
          get_positional_arg(args, 1, has_keyword_args)
        else:
          new_async_error("GENE.ASYNC.CANCELLED", "Future cancelled", "cancel_future")

      let future_obj = future_arg.ref.future
      if not future_obj.cancel(reason_arg):
        raise_future_already_terminal("cancel", future_obj.state)
      execute_future_callbacks(vm, future_obj)
      return NIL

    # Add to global namespace
    let complete_fn_ref = new_ref(VkNativeFn)
    complete_fn_ref.native_fn = complete_future_fn
    App.app.global_ns.ref.ns["complete_future".to_key()] = complete_fn_ref.to_ref_value()
    let cancel_fn_ref = new_ref(VkNativeFn)
    cancel_fn_ref.native_fn = cancel_future_fn
    App.app.global_ns.ref.ns["cancel_future".to_key()] = cancel_fn_ref.to_ref_value()

    # Create Future class
    let future_class = new_class("Future")
    # Don't set parent yet - will be set later when object_class is available

    # Add Future constructor
    proc future_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
      # Create a new Future instance
      let future_val = new_future_value()
      # If initial value is provided, complete the future immediately
      if arg_count > 0:
        let initial_value = get_positional_arg(args, 0, has_keyword_args)
        discard future_val.ref.future.complete(initial_value)
      return future_val

    future_class.def_native_constructor(future_constructor)

    # Add complete method
    proc future_complete(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
      # Complete the future with a value
      # When called as a method, args contains [future, value]
      if arg_count < 2:
        raise new_exception(types.Exception, "Future.complete requires a future and a value")

      let future_arg = get_positional_arg(args, 0, has_keyword_args)
      let value_arg = get_positional_arg(args, 1, has_keyword_args)

      if future_arg.kind != VkFuture:
        raise new_exception(types.Exception, "complete can only be called on a Future")

      let future_obj = future_arg.ref.future
      if not future_obj.complete(value_arg):
        raise_future_already_terminal("complete", future_obj.state)
      execute_future_callbacks(vm, future_obj)
      return NIL

    # Add Future methods
    future_class.def_native_method("complete", future_complete)
    future_class.def_native_method("fail", future_fail)
    future_class.def_native_method("cancel", future_cancel)
    future_class.def_native_method("on_success", future_on_success)
    future_class.def_native_method("on_failure", future_on_failure)
    future_class.def_native_method("state", future_state)
    future_class.def_native_method("value", future_value)

    # Store in Application
    let future_class_ref = new_ref(VkClass)
    future_class_ref.class = future_class
    App.app.future_class = future_class_ref.to_ref_value()

    # Add to gene namespace if it exists
    if App.app.gene_ns.kind == VkNamespace:
      App.app.gene_ns.ref.ns["Future".to_key()] = App.app.future_class

# Call init_async to register the callback
init_async()

import ../types
import asyncdispatch  # For Future procs: finished, failed, read

# Note: execute_future_callbacks is implemented in vm.nim and imported there

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
      # Future failed with exception
      # TODO: Wrap exception properly when exception handling is ready
      future_obj.state = FsFailure
      future_obj.value = new_str_value("Async operation failed")
    else:
      # Future succeeded
      future_obj.state = FsSuccess
      future_obj.value = read(future_obj.nim_future)

# Future methods
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
  if future_obj.state == FsSuccess:
    # Future already completed successfully - mark for immediate execution by adding to pending list
    # The callback will be executed on next poll (callbacks are always executed in poll loop)
    future_obj.success_callbacks.add(callback_arg)
    # Re-add future to pending list so callbacks get executed
    if vm.pending_futures.find(future_obj) < 0:
      vm.pending_futures.add(future_obj)
      vm.poll_enabled = true  # Ensure polling is enabled
  elif future_obj.state == FsPending:
    # Store callback for later execution when future completes
    future_obj.success_callbacks.add(callback_arg)
  # If failed, don't add to success callbacks

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
  if future_obj.state == FsFailure:
    # Future already failed - mark for immediate execution by adding to pending list
    # The callback will be executed on next poll (callbacks are always executed in poll loop)
    future_obj.failure_callbacks.add(callback_arg)
    # Re-add future to pending list so callbacks get executed
    if vm.pending_futures.find(future_obj) < 0:
      vm.pending_futures.add(future_obj)
      vm.poll_enabled = true  # Ensure polling is enabled
  elif future_obj.state == FsPending:
    # Store callback for later execution when future fails
    future_obj.failure_callbacks.add(callback_arg)
  # If succeeded, don't add to failure callbacks

  # Return the future for chaining
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
  if future_obj.state in {FsSuccess, FsFailure}:
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
      future_obj.complete(value_arg)
      return NIL

    # Add to global namespace
    let complete_fn_ref = new_ref(VkNativeFn)
    complete_fn_ref.native_fn = complete_future_fn
    App.app.global_ns.ref.ns["complete_future".to_key()] = complete_fn_ref.to_ref_value()

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
        future_val.ref.future.complete(initial_value)
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
      future_obj.complete(value_arg)
      return NIL

    # Add Future methods
    future_class.def_native_method("complete", future_complete)
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

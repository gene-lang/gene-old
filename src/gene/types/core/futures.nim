## FutureObj operations
## Included from core.nim — shares its scope.

#################### Future ######################

proc new_future*(): FutureObj =
  result = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil  # Synchronous future by default
  )

proc new_future*(nim_fut: Future[Value]): FutureObj =
  ## Create a FutureObj that wraps a Nim async future
  result = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nim_fut
  )

proc new_future_value*(): Value =
  let r = new_ref(VkFuture)
  r.future = new_future()
  return r.to_ref_value()

proc complete*(f: FutureObj, value: Value) =
  if f.state != FsPending:
    not_allowed("Future already completed")
  f.state = FsSuccess
  f.value = value
  # Execute success callbacks
  # Note: Callbacks are executed immediately when future completes
  # In real async, these would be scheduled on the event loop
  for callback in f.success_callbacks:
    if callback.kind == VkFunction:
      # Execute Gene function with value as argument
      # We need a VM instance to execute, but we don't have one here
      # This will be handled by update_from_nim_future which has VM access
      discard
    # For now, callbacks are stored but not executed here
    # They will be executed by update_from_nim_future or by explicit VM call

proc fail*(f: FutureObj, error: Value) =
  if f.state != FsPending:
    not_allowed("Future already completed")
  f.state = FsFailure
  f.value = error
  # Execute failure callbacks
  for callback in f.failure_callbacks:
    if callback.kind == VkFunction:
      # Execute Gene function with error as argument
      # We need a VM instance to execute, but we don't have one here
      # This will be handled by update_from_nim_future which has VM access
      discard
    # For now, callbacks are stored but not executed here
    # They will be executed by update_from_nim_future or by explicit VM call

proc update_from_nim_future*(f: FutureObj) =
  ## Check if the underlying Nim future has completed and update our state
  ## This should be called during event loop polling
  ## NOTE: This version doesn't execute callbacks - use update_future_from_nim in vm/async.nim for that
  if f.nim_future.isNil or f.state != FsPending:
    return  # No Nim future to check, or already completed

  if finished(f.nim_future):
    # Nim future has completed - copy its result
    if failed(f.nim_future):
      # Future failed with exception
      # TODO: Wrap exception properly when exception handling is ready
      f.state = FsFailure
      f.value = new_str_value("Async operation failed")
    else:
      # Future succeeded
      f.state = FsSuccess
      f.value = read(f.nim_future)

    # Execute appropriate callbacks
    if f.state == FsSuccess:
      for callback in f.success_callbacks:
        # TODO: Execute callback with value
        discard
    else:
      for callback in f.failure_callbacks:
        # TODO: Execute callback with error
        discard

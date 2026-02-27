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

proc is_terminal*(f: FutureObj): bool {.inline.} =
  f.state != FsPending

proc transition_to*(f: FutureObj, state: FutureState, payload: Value): bool =
  ## Deterministic lifecycle guard: only pending -> terminal is legal.
  if f.state != FsPending:
    return false
  f.state = state
  f.value = payload
  return true

proc complete*(f: FutureObj, value: Value): bool =
  result = f.transition_to(FsSuccess, value)
  # Callback execution is VM-mediated:
  # - vm/async.nim runs callbacks for explicit Future.complete calls.
  # - vm/async_exec.nim runs callbacks when polling async/thread futures.

proc fail*(f: FutureObj, error: Value): bool =
  result = f.transition_to(FsFailure, error)
  # Callback execution is VM-mediated (see complete()).

proc cancel*(f: FutureObj, reason: Value = NIL): bool =
  result = f.transition_to(FsCancelled, reason)

proc update_from_nim_future*(f: FutureObj) =
  ## Check if the underlying Nim future has completed and update our state
  ## This should be called during event loop polling
  ## NOTE: This updates state only. VM callback execution happens via
  ## update_future_from_nim/execute_future_callbacks in vm/async*.nim.
  if f.nim_future.isNil or f.state != FsPending:
    return  # No Nim future to check, or already completed

  if finished(f.nim_future):
    # Nim future has completed - copy its result
    if failed(f.nim_future):
      # Future failed with exception
      # TODO: Wrap exception properly when exception handling is ready
      discard f.fail(new_str_value("Async operation failed"))
    else:
      # Future succeeded
      discard f.complete(read(f.nim_future))

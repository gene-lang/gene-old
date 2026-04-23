when defined(gene_wasm):
  import ../types
  import ../wasm_host_abi

when defined(gene_wasm):
  var THREAD_CLASS_VALUE*: Value = NIL
  var THREAD_MESSAGE_CLASS_VALUE*: Value = NIL
  var next_message_id* {.threadvar.}: int

  proc next_thread_message_id*(): int =
    result = next_message_id
    next_message_id.inc()

  proc init_thread_pool*() =
    next_message_id = 0
    THREADS[0].id = 0
    THREADS[0].secret = 1
    THREADS[0].state = TsBusy
    THREADS[0].in_use = true

  proc get_free_thread*(): int =
    -1

  proc init_thread*(thread_id: int, parent_id: int = 0) =
    discard thread_id
    discard parent_id

  proc cleanup_thread*(thread_id: int) =
    discard thread_id

  proc reset_vm_state*() =
    if VM == nil:
      return

    VM.pc = 0
    VM.cu = nil
    VM.trace = false

    var current_frame = VM.frame
    while current_frame != nil:
      let caller = current_frame.caller_frame
      current_frame.free()
      current_frame = caller
    VM.frame = nil

    VM.exception_handlers.setLen(0)
    VM.current_exception = NIL
    VM.repl_exception = NIL
    VM.repl_on_error = false
    VM.repl_active = false
    VM.repl_skip_on_throw = false
    VM.repl_ran = false
    VM.repl_resume_value = NIL
    VM.current_generator = nil

  proc thread_unsupported(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    discard vm
    discard args
    discard arg_count
    discard has_keyword_args
    raise_wasm_unsupported("threads")

  proc init_thread_class*() =
    THREAD_CLASS_VALUE = NIL
    THREAD_MESSAGE_CLASS_VALUE = NIL
else:
  include ./thread_native

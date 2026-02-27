import os, times, tables

import ./type_defs
import ./core
import ./classes

proc refresh_env_map*()
proc set_program_args*(program: string, args: seq[string])

#################### VM ##########################

proc new_vm_ptr*(): ptr VirtualMachine =
  ## Allocate and initialize a new VM instance for the current thread.
  result = cast[ptr VirtualMachine](alloc0(sizeof(VirtualMachine)))
  result[].exec_depth = 0
  result[].exec_handler_base_stack = @[]
  result[].exception_handlers = @[]
  result[].current_exception = NIL
  result[].repl_exception = NIL
  result[].repl_on_error = false
  result[].repl_active = false
  result[].repl_skip_on_throw = false
  result[].repl_ran = false
  result[].repl_resume_value = NIL
  result[].symbols = addr SYMBOLS
  result[].poll_enabled = false
  result[].pending_futures = @[]
  result[].thread_futures = initTable[int, FutureObj]()
  result[].message_callbacks = @[]
  result[].aop_contexts = @[]
  result[].native_tier = NctNever
  result[].native_code = false
  result[].type_check = true
  result[].contracts_enabled = true
  result[].profile_data = initTable[string, FunctionProfile]()
  result[].profile_stack = @[]
  result[].thread_local_ns = nil
  result[].duration_start_us = 0.0

proc free_vm_ptr*(vm: ptr VirtualMachine) =
  ## Release a VM instance allocated by new_vm_ptr.
  if vm.is_nil:
    return
  # Return frames to the thread-local pool before dropping VM state.
  var current_frame = vm[].frame
  while current_frame != nil:
    let caller = current_frame.caller_frame
    current_frame.free()
    current_frame = caller
  vm[].frame = nil
  reset(vm[])
  dealloc(vm)

proc free_vm_ptr_fast*(vm: ptr VirtualMachine) =
  ## Release the VM container without walking nested ref-counted fields.
  ##
  ## This is useful for process teardown paths where the OS will reclaim
  ## remaining allocations and we want to avoid paying destructor costs.
  if vm.is_nil:
    return
  dealloc(vm)

proc init_app_and_vm*() =
  # Reset gene namespace initialization flag since we're creating a new App
  gene_namespace_initialized = false

  # Initialize as main thread (ID 0)
  current_thread_id = 0

  if VM != nil:
    free_vm_ptr(VM)
    VM = nil

  VM = new_vm_ptr()

  # Pre-allocate frame and scope pools
  if FRAMES.len == 0:
    FRAMES = newSeqOfCap[Frame](INITIAL_FRAME_POOL_SIZE)
    for i in 0..<INITIAL_FRAME_POOL_SIZE:
      FRAMES.add(cast[Frame](alloc0(sizeof(FrameObj))))
      FRAME_ALLOCS.inc()  # Count the pre-allocated frames

  let r = new_ref(VkApplication)
  r.app = new_app()
  r.app.global_ns = new_namespace("global").to_value()
  r.app.gene_ns   = new_namespace("gene"  ).to_value()
  r.app.genex_ns  = new_namespace("genex" ).to_value()
  App = r.to_ref_value()

  # Create built-in GeneException class
  # TODO: Rename to Exception once symbol collision is fixed
  let exception_class = new_class("GeneException")
  let exception_ref = new_ref(VkClass)
  exception_ref.class = exception_class
  let exception_class_val = exception_ref.to_ref_value()
  # Store in App for easy access
  App.app.exception_class = exception_class_val
  # Add to global namespace so it's accessible everywhere
  App.app.global_ns.ref.ns["GeneException".to_key()] = exception_class_val

  # Add genex to global namespace (similar to gene-new)
  App.app.global_ns.ref.ns["genex".to_key()] = App.app.genex_ns

  # Pre-populate genex with commonly used extensions
  # This creates the namespace entry but doesn't load the extension yet
  App.app.genex_ns.ref.ns["http".to_key()] = NIL

  # Add time namespace stub to prevent errors
  let time_ns = new_namespace("time")
  # Simple time function that returns current timestamp
  proc time_now(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    return epochTime().to_value()

  proc time_now_us(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    return (epochTime() * 1_000_000).to_value()

  var time_now_fn = new_ref(VkNativeFn)
  time_now_fn.native_fn = time_now
  time_ns["now".to_key()] = time_now_fn.to_ref_value()

  var time_now_us_fn = new_ref(VkNativeFn)
  time_now_us_fn.native_fn = time_now_us
  time_ns["now_us".to_key()] = time_now_us_fn.to_ref_value()
  App.app.global_ns.ref.ns["time".to_key()] = time_ns.to_value()
  # Also add to gene namespace for gene/time/now access
  App.app.gene_ns.ref.ns["time".to_key()] = time_ns.to_value()

  refresh_env_map()
  set_program_args("", @[])

  # Initialize thread-local namespace for main thread
  # This holds thread-specific variables like $thread and $main_thread
  VM.thread_local_ns = new_namespace("thread_local")

  # For main thread, $thread and $main_thread are the same
  let main_thread_ref = type_defs.Thread(
    id: 0,
    secret: THREADS[0].secret
  )
  VM.thread_local_ns["$thread".to_key()] = main_thread_ref.to_value()
  VM.thread_local_ns["$main_thread".to_key()] = main_thread_ref.to_value()
  VM.thread_local_ns["thread".to_key()] = main_thread_ref.to_value()
  VM.thread_local_ns["main_thread".to_key()] = main_thread_ref.to_value()

  for callback in VmCreatedCallbacks:
    callback()

#################### Helpers #####################

proc refresh_env_map*() =
  if App == NIL or App.kind != VkApplication:
    return
  var env_table = initTable[Key, Value]()
  for pair in envPairs():
    env_table[pair.key.to_key()] = pair.value.to_value()
  let env_value = new_map_value(env_table)
  App.app.gene_ns.ref.ns["env".to_key()] = env_value
  App.app.global_ns.ref.ns["env".to_key()] = env_value

proc set_program_args*(program: string, args: seq[string]) =
  if App == NIL or App.kind != VkApplication:
    init_app_and_vm()
    if App == NIL or App.kind != VkApplication:
      return
  App.app.args = args
  var arr_ref = new_array_value()
  for arg in args:
    array_data(arr_ref).add(arg.to_value())
  let program_value = program.to_value()
  App.app.gene_ns.ref.ns["args".to_key()] = arr_ref
  App.app.gene_ns.ref.ns["program".to_key()] = program_value
  App.app.global_ns.ref.ns["args".to_key()] = arr_ref
  App.app.global_ns.ref.ns["program".to_key()] = program_value

const SYM_UNDERSCORE* = SYMBOL_TAG or 0
const SYM_SELF* = SYMBOL_TAG or 1
const SYM_GENE* = SYMBOL_TAG or 2
const SYM_NS* = SYMBOL_TAG or 3
const SYM_CONTAINER* = SYMBOL_TAG or 4

proc init_values*() =
  SYMBOLS = ManagedSymbols()
  discard "_".to_symbol_value()
  discard "self".to_symbol_value()
  discard "gene".to_symbol_value()
  discard "container".to_symbol_value()

init_values()

#################### Exception Wrapping ####################

proc wrap_nim_exception*(ex: ref CatchableError, location: string = ""): Value =
  ## Wrap a Nim exception into a Gene exception instance with structured data.
  ## The instance has properties: message, nim_type, nim_stack, location
  let exception_class_val = App.app.exception_class
  if exception_class_val == NIL:
    # Fallback to string if exception class not initialized
    return ex.msg.to_value()

  let cls = core.`ref`(exception_class_val).class
  var props = initTable[Key, Value]()
  props["message".to_key()] = ex.msg.to_value()
  # Keep wrapping allocation-light to avoid cascading failures while handling
  # runtime exceptions raised from corrupted execution paths.
  props["nim_type".to_key()] = NIL
  props["nim_stack".to_key()] = NIL
  props["location".to_key()] = NIL

  result = new_instance_value(cls, props)

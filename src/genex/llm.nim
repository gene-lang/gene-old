import os, tables, osproc, strutils
import std/locks
import ../gene/types
import ../gene/vm/extension_abi
import ../gene/vm/llm_host_abi
import ../gene/serdes
when not defined(GENE_LLM_MOCK):
  import std/exitprocs
  import ../gene/vm

# Global registries for cross-thread access
# This allows worker threads to access models and create sessions
var global_model_registry* {.global.}: Value = NIL
var global_model_class* {.global.}: Class = nil
var global_session_class* {.global.}: Class = nil
var global_model_lock* {.global.}: Lock  # Protects access to global_model_registry
var global_llm_op_lock* {.global.}: Lock  # Serializes llama.cpp operations (not thread-safe)
var llm_extension_host* {.global.}: GeneHostAbi
var llm_extension_host_ready* {.global.}: bool
var llm_backend_model_handles* {.global.}: Table[system.int64, Value] = initTable[system.int64, Value]()
var llm_backend_session_handles* {.global.}: Table[system.int64, Value] = initTable[system.int64, Value]()
var llm_backend_next_model_id* {.global.}: system.int64 = 1
var llm_backend_next_session_id* {.global.}: system.int64 = 1

proc llm_host_vm(): ptr VirtualMachine =
  cast[ptr VirtualMachine](llm_extension_host.user_data)

proc llm_alloc_cstring_copy(s: string): cstring =
  let size = s.len + 1
  let raw = cast[cstring](allocShared0(size))
  if s.len > 0:
    copyMem(raw, s.cstring, s.len)
  raw

proc llm_set_error(out_error: ptr cstring, message: string) =
  if out_error != nil:
    out_error[] = llm_alloc_cstring_copy(message)

proc llm_clear_error(out_error: ptr cstring) =
  if out_error != nil:
    out_error[] = nil

proc llm_parse_options(options_ser: cstring): Value =
  if options_ser == nil:
    return NIL
  let text = $options_ser
  if text.len == 0:
    return NIL
  deserialize_literal(text)

proc llm_serialize_reply(value: Value): cstring =
  var text = ""
  {.cast(gcsafe).}:
    text = serialize_literal(value).to_s()
  llm_alloc_cstring_copy(text)

proc gene_llm_host_abi_version*(): uint32 {.cdecl, exportc, dynlib.} =
  GENE_LLM_HOST_ABI_VERSION

when defined(GENE_LLM_MOCK):
  type
    ModelState = ref object of CustomValue
      path: string
      context_len: int
      threads: int
      closed: bool
      open_sessions: int

    SessionState = ref object of CustomValue
      model: ModelState
      context_len: int
      temperature: float
      top_p: float
      top_k: int
      seed: int
      max_tokens: int
      closed: bool

  var
    model_class_global {.threadvar.}: Class
    session_class_global {.threadvar.}: Class

  proc expect_map(val: Value, context: string): Value =
    if val == NIL:
      return NIL
    if val.kind != VkMap:
      raise new_exception(types.Exception, context & " options must be a map")
    return val

  proc has_option(opts: Value, name: string): bool =
    if opts == NIL or opts.kind != VkMap:
      return false
    let key = name.to_key()
    map_data(opts).hasKey(key)

  proc get_int_option(opts: Value, name: string, default_value: int): int =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      let val = map_data(opts)[key]
      case val.kind
      of VkInt:
        return val.to_int()
      of VkFloat:
        return int(val.to_float())
      else:
        discard
    return default_value

  proc get_float_option(opts: Value, name: string, default_value: float): float =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      let val = map_data(opts)[key]
      case val.kind
      of VkFloat:
        return val.to_float()
      of VkInt:
        return float(val.to_int())
      else:
        discard
    return default_value

  proc get_bool_option(opts: Value, name: string, default_value: bool): bool =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      return map_data(opts)[key].to_bool()
    return default_value

  proc normalize_path(path: string): string =
    result = expandTilde(path)
    if result.len == 0:
      result = path

  proc mock_generate(prompt: string, max_tokens: int): (string, seq[string], bool) =
    var source = prompt.strip()
    if source.len == 0:
      source = "Hello from Gene"
    var tokens = source.splitWhitespace()
    if tokens.len == 0:
      tokens = @[source]
    let capped =
      if max_tokens <= 0:
        tokens
      else:
        tokens[0 ..< min(tokens.len, max_tokens)]
    let truncated = max_tokens > 0 and tokens.len > max_tokens
    let completion_text = capped.join(" ") & " [mock]"
    (completion_text, capped, truncated)

  proc build_completion_value(text: string, tokens: seq[string], finish_reason: string, latency_ms: int): Value =
    var map_table = initTable[Key, Value]()
    map_table["text".to_key()] = text.to_value()

    var token_array = new_array_value(@[])
    for token in tokens:
      array_data(token_array).add(token.to_value())
    map_table["tokens".to_key()] = token_array

    map_table["finish_reason".to_key()] = finish_reason.to_symbol_value()
    if latency_ms >= 0:
      map_table["latency_ms".to_key()] = latency_ms.to_value()

    new_map_value(map_table)

  proc cancellation_value(reason: string = ":cancelled"): Value =
    build_completion_value("", @[], reason, 0)

  proc expect_model(val: Value, context: string): ModelState =
    # Check by class name for cross-thread compatibility (model_class_global is threadvar)
    if val.kind != VkCustom:
      raise new_exception(types.Exception, context & " requires an LLM model instance")
    if val.ref.custom_class == nil or val.ref.custom_class.name != "Model":
      raise new_exception(types.Exception, context & " requires an LLM model instance")
    cast[ModelState](get_custom_data(val, "LLM model payload missing"))

  proc expect_session(val: Value, context: string): SessionState =
    # Check by class name for cross-thread compatibility (session_class_global is threadvar)
    if val.kind != VkCustom:
      raise new_exception(types.Exception, context & " requires an LLM session instance")
    if val.ref.custom_class == nil or val.ref.custom_class.name != "Session":
      raise new_exception(types.Exception, context & " requires an LLM session instance")
    cast[SessionState](get_custom_data(val, "LLM session payload missing"))

  proc new_model_value(state: ModelState): Value {.gcsafe.} =
    {.cast(gcsafe).}:
      let cls = if model_class_global != nil: model_class_global else: global_model_class
      new_custom_value(cls, state)

  proc new_session_value(state: SessionState): Value {.gcsafe.} =
    {.cast(gcsafe).}:
      let cls = if session_class_global != nil: session_class_global else: global_session_class
      new_custom_value(cls, state)

  proc ensure_model_open(state: ModelState) =
    if state.closed:
      raise new_exception(types.Exception, "LLM model has been closed")

  proc ensure_session_open(state: SessionState) =
    if state.closed:
      raise new_exception(types.Exception, "LLM session has been closed")

  proc cleanup_session(state: SessionState) =
    if state == nil or state.closed:
      return
    state.closed = true
    if state.model != nil and state.model.open_sessions > 0:
      state.model.open_sessions.dec()

  proc cleanup_model(state: ModelState) =
    if state == nil or state.closed:
      return
    state.closed = true


  proc vm_load_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "genex/llm/load_model requires a file path")

    let path_val = get_positional_arg(args, 0, has_keyword_args)
    if path_val.kind != VkString:
      raise new_exception(types.Exception, "Model path must be a string")

    let opts =
      if positional >= 2:
        expect_map(get_positional_arg(args, 1, has_keyword_args), "load_model")
      else:
        NIL

    let resolved_path = normalize_path(path_val.str)
    let allow_missing = get_bool_option(opts, "allow_missing", false)
    if not allow_missing and not fileExists(resolved_path):
      raise new_exception(types.Exception, "LLM model not found: " & resolved_path)

    let context_len = max(256, get_int_option(opts, "context", 2048))
    let threads = max(1, get_int_option(opts, "threads", countProcessors()))

    let state = ModelState(
      path: resolved_path,
      context_len: context_len,
      threads: threads
    )
    new_model_value(state)

  proc vm_model_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Model.close requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let state = expect_model(self_val, "Model.close")
    ensure_model_open(state)
    if state.open_sessions > 0:
      raise new_exception(types.Exception, "Cannot close model while sessions are active")
    cleanup_model(state)
    NIL

  proc vm_model_new_session(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Model.new_session requires self")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let model_state = expect_model(self_val, "Model.new_session")
    ensure_model_open(model_state)

    let opts =
      if positional >= 2:
        expect_map(get_positional_arg(args, 1, has_keyword_args), "new_session")
      else:
        NIL

    let context_len = get_int_option(opts, "context", model_state.context_len)
    let temperature = get_float_option(opts, "temperature", 0.7)
    let top_p = get_float_option(opts, "top_p", 0.9)
    let top_k = get_int_option(opts, "top_k", 40)
    let seed = get_int_option(opts, "seed", 42)
    let max_tokens = max(0, get_int_option(opts, "max_tokens", 256))

    let session_state = SessionState(
      model: model_state,
      context_len: context_len,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      seed: seed,
      max_tokens: max_tokens
    )
    model_state.open_sessions.inc()
    new_session_value(session_state)

  proc vm_session_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Session.close requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let session_state = expect_session(self_val, "Session.close")
    ensure_session_open(session_state)
    cleanup_session(session_state)
    NIL

  proc vm_session_infer(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 2:
      raise new_exception(types.Exception, "Session.infer requires self and a prompt string")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let session_state = expect_session(self_val, "Session.infer")
    ensure_session_open(session_state)

    let prompt_val = get_positional_arg(args, 1, has_keyword_args)
    if prompt_val.kind != VkString:
      raise new_exception(types.Exception, "Session.infer prompt must be a string")

    let opts =
      if positional >= 3:
        expect_map(get_positional_arg(args, 2, has_keyword_args), "infer")
      else:
        NIL

    var max_tokens = get_int_option(opts, "max_tokens", session_state.max_tokens)
    var temperature = get_float_option(opts, "temperature", session_state.temperature)
    if temperature <= 0:
      temperature = 0.7
    let timeout_provided = has_option(opts, "timeout") or has_option(opts, "timeout_ms")

    if timeout_provided:
      raise new_exception(types.Exception, "Session.infer timeout is not supported for local inference yet")

    if max_tokens <= 0:
      return cancellation_value()

    let (text, tokens, truncated) = mock_generate(prompt_val.str, max_tokens)
    let finish_reason =
      if truncated:
        ":length"
      else:
        ":stop"

    let latency_ms = max(1, prompt_val.str.len * 2)

    build_completion_value(text, tokens, finish_reason, latency_ms)

  # Register a model globally for cross-thread access
  proc vm_register_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "register_model requires a model")
    let model_val = get_positional_arg(args, 0, has_keyword_args)
    # Validate it's a model (will throw if not)
    discard expect_model(model_val, "register_model")
    {.cast(gcsafe).}:
      acquire(global_model_lock)
      global_model_registry = model_val
      release(global_model_lock)
    NIL

  # Get the globally registered model (for worker threads)
  proc vm_get_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(global_model_lock)
      let model_value = global_model_registry
      release(global_model_lock)
      model_value

  proc init_llm_module*() =
    VmCreatedCallbacks.add proc() =
      {.cast(gcsafe).}:
        # Initialize lock for thread-safe model registry access
        initLock(global_model_lock)
        
        if App == NIL or App.kind != VkApplication:
          return
        if App.app.genex_ns == NIL or App.app.genex_ns.kind != VkNamespace:
          return

        model_class_global = new_class("Model")
        if App.app.object_class.kind == VkClass:
          model_class_global.parent = App.app.object_class.ref.class
        model_class_global.def_native_method("new_session", vm_model_new_session)
        model_class_global.def_native_method("close", vm_model_close)
        # Set global for cross-thread access
        global_model_class = model_class_global

        session_class_global = new_class("Session")
        if App.app.object_class.kind == VkClass:
          session_class_global.parent = App.app.object_class.ref.class
        session_class_global.def_native_method("infer", vm_session_infer)
        session_class_global.def_native_method("close", vm_session_close)
        # Set global for cross-thread access
        global_session_class = session_class_global

        let llm_ns = new_ref(VkNamespace)
        llm_ns.ns = new_namespace("llm")

        let load_fn = new_ref(VkNativeFn)
        load_fn.native_fn = vm_load_model
        llm_ns.ns["load_model".to_key()] = load_fn.to_ref_value()

        let register_fn = new_ref(VkNativeFn)
        register_fn.native_fn = vm_register_model
        llm_ns.ns["register_model".to_key()] = register_fn.to_ref_value()

        let get_fn = new_ref(VkNativeFn)
        get_fn.native_fn = vm_get_model
        llm_ns.ns["get_model".to_key()] = get_fn.to_ref_value()

        let model_class_ref = new_ref(VkClass)
        model_class_ref.class = model_class_global
        llm_ns.ns["Model".to_key()] = model_class_ref.to_ref_value()

        let session_class_ref = new_ref(VkClass)
        session_class_ref.class = session_class_global
        llm_ns.ns["Session".to_key()] = session_class_ref.to_ref_value()

        App.app.genex_ns.ref.ns["llm".to_key()] = llm_ns.to_ref_value()

  init_llm_module()

else:
  const
    llmSourceDir = parentDir(currentSourcePath())
    projectDir = parentDir(parentDir(llmSourceDir))
    llamaIncludeDir = joinPath(projectDir, "tools/llama.cpp/include")
    ggmlIncludeDir = joinPath(projectDir, "tools/llama.cpp/ggml/include")
    shimIncludeDir = joinPath(projectDir, "src/genex/llm/shim")
    llamaBuildDir = joinPath(projectDir, "build/llama")

  static:
    {.passC: "-I" & llamaIncludeDir.}
    {.passC: "-I" & ggmlIncludeDir.}
    {.passC: "-I" & shimIncludeDir.}
    {.passL: "-L" & llamaBuildDir.}
    {.passL: "-L" & llamaBuildDir & "/ggml/src".}
    when defined(macosx):
      {.passL: "-L" & llamaBuildDir & "/ggml/src/ggml-blas".}
      {.passL: "-L" & llamaBuildDir & "/ggml/src/ggml-metal".}
    when defined(linux) and not defined(geneNoCuda):
      {.passL: "-L" & llamaBuildDir & "/ggml/src/ggml-cuda".}
      {.passL: "-L/usr/local/cuda/lib64".}
    {.passL: "-lgene_llm".}
    {.passL: "-lllama".}
    {.passL: "-lggml".}
    {.passL: "-lggml-base".}
    {.passL: "-lggml-cpu".}
    when defined(macosx):
      {.passL: "-lggml-blas".}
      {.passL: "-lggml-metal".}
      {.passL: "-framework Metal".}
      {.passL: "-framework Foundation".}
      {.passL: "-framework Accelerate".}
      {.passL: "-lc++".}
    when defined(linux):
      when not defined(geneNoCuda):
        {.passL: "-lggml-cuda".}
        {.passL: "-lcuda".}
        {.passL: "-lcudart".}
        {.passL: "-lcublas".}
        {.passL: "-lcublasLt".}
      {.passL: "-lstdc++".}
      {.passL: "-lgomp".}

  type
    GeneLlmModel {.importc: "struct gene_llm_model", header: "gene_llm.h".} = object
    GeneLlmSession {.importc: "struct gene_llm_session", header: "gene_llm.h".} = object

    GeneLlmStatus {.size: sizeof(cint).} = enum
      glsOk = 0
      glsError = 1

    GeneLlmFinishReason {.size: sizeof(cint).} = enum
      glfStop = 0
      glfLength = 1
      glfCancelled = 2
      glfError = 3

    GeneLlmModelOptions {.importc: "gene_llm_model_options", header: "gene_llm.h".} = object
      context_length*: cint
      threads*: cint
      gpu_layers*: cint
      use_mmap*: bool
      use_mlock*: bool

    GeneLlmSessionOptions {.importc: "gene_llm_session_options", header: "gene_llm.h".} = object
      context_length*: cint
      batch_size*: cint
      threads*: cint
      seed*: cint
      temperature*: cfloat
      top_p*: cfloat
      top_k*: cint
      max_tokens*: cint

    GeneLlmInferOptions {.importc: "gene_llm_infer_options", header: "gene_llm.h".} = object
      prompt*: cstring
      max_tokens*: cint
      temperature*: cfloat
      top_p*: cfloat
      top_k*: cint
      seed*: cint

    GeneLlmError {.importc: "gene_llm_error", header: "gene_llm.h".} = object
      code*: cint
      message*: array[512, char]

    GeneLlmCompletion {.importc: "gene_llm_completion", header: "gene_llm.h".} = object
      text*: cstring
      tokens*: ptr cstring
      token_count*: cint
      latency_ms*: cint
      finish_reason*: GeneLlmFinishReason

  proc gene_llm_backend_init() {.cdecl, importc: "gene_llm_backend_init", header: "gene_llm.h".}
  proc gene_llm_load_model(path: cstring, opts: ptr GeneLlmModelOptions, out_model: ptr ptr GeneLlmModel, err: ptr GeneLlmError): GeneLlmStatus {.cdecl, importc: "gene_llm_load_model", header: "gene_llm.h".}
  proc gene_llm_free_model(model: ptr GeneLlmModel) {.cdecl, importc: "gene_llm_free_model", header: "gene_llm.h".}
  proc gene_llm_new_session(model: ptr GeneLlmModel, opts: ptr GeneLlmSessionOptions, out_session: ptr ptr GeneLlmSession, err: ptr GeneLlmError): GeneLlmStatus {.cdecl, importc: "gene_llm_new_session", header: "gene_llm.h".}
  proc gene_llm_free_session(session: ptr GeneLlmSession) {.cdecl, importc: "gene_llm_free_session", header: "gene_llm.h".}
  proc gene_llm_infer(session: ptr GeneLlmSession, opts: ptr GeneLlmInferOptions, completion: ptr GeneLlmCompletion, err: ptr GeneLlmError): GeneLlmStatus {.cdecl, importc: "gene_llm_infer", header: "gene_llm.h".}
  proc gene_llm_free_completion(completion: ptr GeneLlmCompletion) {.cdecl, importc: "gene_llm_free_completion", header: "gene_llm.h".}

  # Streaming callback: returns 0 to continue, non-zero to stop
  type GeneLlmTokenCallback = proc(token: cstring, token_len: cint, user_data: pointer): cint {.cdecl.}
  proc gene_llm_infer_streaming(session: ptr GeneLlmSession, opts: ptr GeneLlmInferOptions, callback: GeneLlmTokenCallback, user_data: pointer, completion: ptr GeneLlmCompletion, err: ptr GeneLlmError): GeneLlmStatus {.cdecl, importc: "gene_llm_infer_streaming", header: "gene_llm.h".}

  type
    ModelState = ref object of CustomValue
      path: string
      handle: ptr GeneLlmModel
      context_len: int
      threads: int
      closed: bool
      open_sessions: int

    SessionState = ref object of CustomValue
      model: ModelState
      handle: ptr GeneLlmSession
      context_len: int
      temperature: float
      top_p: float
      top_k: int
      seed: int
      max_tokens: int
      closed: bool

  var
    model_class_global {.threadvar.}: Class
    session_class_global {.threadvar.}: Class
    backend_ready {.threadvar.}: bool
    tracked_models {.threadvar.}: seq[ModelState]
    tracked_sessions {.threadvar.}: seq[SessionState]

  proc ensure_backend() =
    if not backend_ready:
      gene_llm_backend_init()
      backend_ready = true

  proc track_model(state: ModelState) =
    tracked_models.add(state)

  proc untrack_model(state: ModelState) =
    for i in countdown(tracked_models.len - 1, 0):
      if tracked_models[i] == state:
        tracked_models.delete(i)
        break

  proc track_session(state: SessionState) =
    tracked_sessions.add(state)

  proc untrack_session(state: SessionState) =
    for i in countdown(tracked_sessions.len - 1, 0):
      if tracked_sessions[i] == state:
        tracked_sessions.delete(i)
        break

  proc expect_model(val: Value, context: string): ModelState =
    # Check by class name for cross-thread compatibility (model_class_global is threadvar)
    if val.kind != VkCustom:
      raise new_exception(types.Exception, context & " requires an LLM model instance")
    if val.ref.custom_class == nil or val.ref.custom_class.name != "Model":
      raise new_exception(types.Exception, context & " requires an LLM model instance")
    cast[ModelState](get_custom_data(val, "LLM model payload missing"))

  proc expect_session(val: Value, context: string): SessionState =
    # Check by class name for cross-thread compatibility (session_class_global is threadvar)
    if val.kind != VkCustom:
      raise new_exception(types.Exception, context & " requires an LLM session instance")
    if val.ref.custom_class == nil or val.ref.custom_class.name != "Session":
      raise new_exception(types.Exception, context & " requires an LLM session instance")
    cast[SessionState](get_custom_data(val, "LLM session payload missing"))

  proc new_model_value(state: ModelState): Value {.gcsafe.} =
    # Use threadvar class if available, fall back to global for worker threads
    {.cast(gcsafe).}:
      let cls = if model_class_global != nil: model_class_global else: global_model_class
      new_custom_value(cls, state)

  proc new_session_value(state: SessionState): Value {.gcsafe.} =
    # Use threadvar class if available, fall back to global for worker threads
    {.cast(gcsafe).}:
      let cls = if session_class_global != nil: session_class_global else: global_session_class
      new_custom_value(cls, state)

  proc ensure_model_open(state: ModelState) =
    if state.closed:
      raise new_exception(types.Exception, "LLM model has been closed")

  proc ensure_session_open(state: SessionState) =
    if state.closed:
      raise new_exception(types.Exception, "LLM session has been closed")

  proc expect_map(val: Value, context: string): Value =
    if val == NIL:
      return NIL
    if val.kind != VkMap:
      raise new_exception(types.Exception, context & " options must be a map")
    return val

  proc has_option(opts: Value, name: string): bool =
    if opts == NIL or opts.kind != VkMap:
      return false
    map_data(opts).hasKey(name.to_key())

  proc get_int_option(opts: Value, name: string, default_value: int): int =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      let val = map_data(opts)[key]
      case val.kind
      of VkInt:
        return val.to_int()
      of VkFloat:
        return int(val.to_float())
      else:
        discard
    return default_value

  proc get_float_option(opts: Value, name: string, default_value: float): float =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      let val = map_data(opts)[key]
      case val.kind
      of VkFloat:
        return val.to_float()
      of VkInt:
        return float(val.to_int())
      else:
        discard
    return default_value

  proc get_bool_option(opts: Value, name: string, default_value: bool): bool =
    if opts == NIL or opts.kind != VkMap:
      return default_value
    let key = name.to_key()
    if map_data(opts).hasKey(key):
      return map_data(opts)[key].to_bool()
    return default_value

  proc normalize_path(path: string): string =
    result = expandTilde(path)
    if result.len == 0:
      result = path

  proc error_string(err: GeneLlmError): string =
    var buffer = newStringOfCap(512)
    for ch in err.message:
      if ch == '\0':
        break
      buffer.add(ch)
    if buffer.len == 0:
      return "LLM backend error"
    buffer

  proc raise_backend_error(err: GeneLlmError) =
    raise new_exception(types.Exception, error_string(err))

  proc cleanup_session(state: SessionState) =
    if state == nil or state.closed:
      return
    state.closed = true
    if state.handle != nil:
      gene_llm_free_session(state.handle)
      state.handle = nil
    if state.model != nil and state.model.open_sessions > 0:
      state.model.open_sessions.dec()
    untrack_session(state)

  proc cleanup_model(state: ModelState) =
    if state == nil or state.closed:
      return
    state.closed = true
    if state.handle != nil:
      gene_llm_free_model(state.handle)
      state.handle = nil
    untrack_model(state)


  proc completion_to_value(completion: var GeneLlmCompletion): Value =
    var map_table = initTable[Key, Value]()
    let text_value = if completion.text == nil: "" else: $completion.text
    map_table["text".to_key()] = text_value.to_value()

    var token_array = new_array_value(@[])
    if completion.tokens != nil and completion.token_count > 0:
      for i in 0..<completion.token_count:
        let token_ptr = completion.tokens[i]
        if token_ptr != nil:
          array_data(token_array).add(($token_ptr).to_value())
        else:
          array_data(token_array).add("".to_value())
    map_table["tokens".to_key()] = token_array

    let finish_symbol =
      case completion.finish_reason
      of glfStop:
        ":stop"
      of glfLength:
        ":length"
      of glfCancelled:
        ":cancelled"
      of glfError:
        ":error"

    map_table["finish_reason".to_key()] = finish_symbol.to_symbol_value()
    map_table["latency_ms".to_key()] = completion.latency_ms.to_value()

    new_map_value(map_table)

  proc vm_load_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "genex/llm/load_model requires a file path")

    let path_val = get_positional_arg(args, 0, has_keyword_args)
    if path_val.kind != VkString:
      raise new_exception(types.Exception, "Model path must be a string")

    let opts =
      if positional >= 2:
        expect_map(get_positional_arg(args, 1, has_keyword_args), "load_model")
      else:
        NIL

    ensure_backend()

    let resolved_path = normalize_path(path_val.str)
    let allow_missing = get_bool_option(opts, "allow_missing", false)
    if not allow_missing and not fileExists(resolved_path):
      raise new_exception(types.Exception, "LLM model not found: " & resolved_path)

    var model_opts = GeneLlmModelOptions(
      context_length: cint(max(256, get_int_option(opts, "context", 2048))),
      threads: cint(max(1, get_int_option(opts, "threads", countProcessors()))),
      gpu_layers: cint(max(0, get_int_option(opts, "gpu_layers", 0))),
      use_mmap: not get_bool_option(opts, "disable_mmap", false),
      use_mlock: get_bool_option(opts, "mlock", false)
    )

    var err: GeneLlmError
    var handle: ptr GeneLlmModel
    let status = gene_llm_load_model(resolved_path.cstring, addr model_opts, addr handle, addr err)
    if status != glsOk or handle == nil:
      raise_backend_error(err)

    let state = ModelState(
      path: resolved_path,
      handle: handle,
      context_len: int(model_opts.context_length),
      threads: int(model_opts.threads)
    )
    track_model(state)
    new_model_value(state)

  proc vm_model_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Model.close requires self")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let state = expect_model(self_val, "Model.close")
    ensure_model_open(state)

    if state.open_sessions > 0:
      raise new_exception(types.Exception, "Cannot close model while sessions are active")

    cleanup_model(state)
    NIL

  proc vm_model_new_session(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Model.new_session requires self")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let model_state = expect_model(self_val, "Model.new_session")
    ensure_model_open(model_state)

    let opts =
      if positional >= 2:
        expect_map(get_positional_arg(args, 1, has_keyword_args), "new_session")
      else:
        NIL

    let ctx_len = get_int_option(opts, "context", model_state.context_len)
    var session_opts = GeneLlmSessionOptions(
      context_length: cint(ctx_len),
      batch_size: cint(get_int_option(opts, "batch", ctx_len)),  # Default batch to context length
      threads: cint(max(1, get_int_option(opts, "threads", model_state.threads))),
      seed: cint(get_int_option(opts, "seed", 42)),
      temperature: get_float_option(opts, "temperature", 0.7).cfloat,
      top_p: get_float_option(opts, "top_p", 0.9).cfloat,
      top_k: cint(get_int_option(opts, "top_k", 40)),
      max_tokens: cint(max(1, get_int_option(opts, "max_tokens", 256)))
    )

    var err: GeneLlmError
    var handle: ptr GeneLlmSession
    # Serialize llama.cpp operations - not thread-safe
    {.cast(gcsafe).}:
      acquire(global_llm_op_lock)
    try:
      let status = gene_llm_new_session(model_state.handle, addr session_opts, addr handle, addr err)
      if status != glsOk or handle == nil:
        {.cast(gcsafe).}:
          release(global_llm_op_lock)
        raise_backend_error(err)
    except:
      {.cast(gcsafe).}:
        release(global_llm_op_lock)
      raise
    {.cast(gcsafe).}:
      release(global_llm_op_lock)

    let session_state = SessionState(
      model: model_state,
      handle: handle,
      context_len: int(session_opts.context_length),
      temperature: cast[float](session_opts.temperature),
      top_p: cast[float](session_opts.top_p),
      top_k: int(session_opts.top_k),
      seed: int(session_opts.seed),
      max_tokens: int(session_opts.max_tokens)
    )
    model_state.open_sessions.inc()
    track_session(session_state)
    new_session_value(session_state)

  proc vm_session_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "Session.close requires self")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let state = expect_session(self_val, "Session.close")
    ensure_session_open(state)
    cleanup_session(state)
    NIL

  proc vm_session_infer(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 2:
      raise new_exception(types.Exception, "Session.infer requires self and a prompt string")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let session_state = expect_session(self_val, "Session.infer")
    ensure_session_open(session_state)

    let prompt_val = get_positional_arg(args, 1, has_keyword_args)
    if prompt_val.kind != VkString:
      raise new_exception(types.Exception, "Session.infer prompt must be a string")

    let opts =
      if positional >= 3:
        expect_map(get_positional_arg(args, 2, has_keyword_args), "infer")
      else:
        NIL

    if has_option(opts, "timeout") or has_option(opts, "timeout_ms"):
      raise new_exception(types.Exception, "Session.infer timeout is not supported for local inference yet")

    var infer_opts = GeneLlmInferOptions(
      prompt: prompt_val.str.cstring,
      max_tokens: cint(max(1, get_int_option(opts, "max_tokens", session_state.max_tokens))),
      temperature: get_float_option(opts, "temperature", session_state.temperature).cfloat,
      top_p: get_float_option(opts, "top_p", session_state.top_p).cfloat,
      top_k: cint(max(1, get_int_option(opts, "top_k", session_state.top_k))),
      seed: cint(get_int_option(opts, "seed", session_state.seed))
    )

    var completion: GeneLlmCompletion
    var err: GeneLlmError
    # Serialize llama.cpp operations - not thread-safe
    {.cast(gcsafe).}:
      acquire(global_llm_op_lock)
    try:
      let status = gene_llm_infer(session_state.handle, addr infer_opts, addr completion, addr err)
      if status != glsOk:
        {.cast(gcsafe).}:
          release(global_llm_op_lock)
        raise_backend_error(err)
    except:
      {.cast(gcsafe).}:
        release(global_llm_op_lock)
      raise
    {.cast(gcsafe).}:
      release(global_llm_op_lock)

    let result_value = completion_to_value(completion)
    gene_llm_free_completion(addr completion)
    result_value

  # Context for streaming callback
  type StreamCallbackContext = object
    vm: ptr VirtualMachine
    callback: Value
    cancelled: bool
    utf8_buffer: string  # Buffer for incomplete UTF-8 sequences

  # Find the boundary of complete UTF-8 characters in a byte sequence
  # Returns the number of bytes that form complete UTF-8 characters
  proc find_utf8_boundary(data: string): int =
    if data.len == 0:
      return 0

    # Start from the end and look for incomplete sequences
    var i = data.len - 1

    # Check if the last byte is a continuation byte (10xxxxxx)
    # or the start of a multi-byte sequence
    while i >= 0:
      let b = data[i].uint8
      if (b and 0xC0) != 0x80:
        # This is either ASCII or a lead byte
        if b < 0x80:
          # ASCII - complete
          return data.len
        elif (b and 0xE0) == 0xC0:
          # 2-byte sequence lead - need 1 more byte
          if data.len - i >= 2:
            return data.len
          else:
            return i
        elif (b and 0xF0) == 0xE0:
          # 3-byte sequence lead - need 2 more bytes
          if data.len - i >= 3:
            return data.len
          else:
            return i
        elif (b and 0xF8) == 0xF0:
          # 4-byte sequence lead - need 3 more bytes
          if data.len - i >= 4:
            return data.len
          else:
            return i
        else:
          # Invalid lead byte, treat as complete
          return data.len
      dec i

    # All continuation bytes with no lead - return all
    return data.len

  # C callback that invokes the Gene callback
  proc stream_token_callback(token: cstring, token_len: cint, user_data: pointer): cint {.cdecl.} =
    if user_data == nil:
      return 0
    let ctx = cast[ptr StreamCallbackContext](user_data)
    if ctx.cancelled:
      return 1

    # Append new bytes to buffer
    if token_len > 0:
      var bytes = newString(token_len)
      copyMem(addr bytes[0], token, token_len)
      ctx.utf8_buffer.add(bytes)

    # Find boundary of complete UTF-8 characters
    let boundary = find_utf8_boundary(ctx.utf8_buffer)
    if boundary == 0:
      # No complete characters yet, wait for more
      return 0

    # Extract complete characters to send
    let complete_str = ctx.utf8_buffer[0..<boundary]
    ctx.utf8_buffer = ctx.utf8_buffer[boundary..^1]

    let token_value = complete_str.to_value()
    {.cast(gcsafe).}:
      try:
        case ctx.callback.kind
        of VkFunction:
          discard ctx.vm.exec_function(ctx.callback, @[token_value])
        of VkNativeFn:
          discard call_native_fn(ctx.callback.ref.native_fn, ctx.vm, [token_value])
        else:
          discard ctx.vm.exec_callable(ctx.callback, @[token_value])
      except:
        ctx.cancelled = true
        return 1
    return 0

  proc vm_session_infer_streaming(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 3:
      raise new_exception(types.Exception, "Session.infer_streaming requires self, prompt, and callback")

    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let session_state = expect_session(self_val, "Session.infer_streaming")
    ensure_session_open(session_state)

    let prompt_val = get_positional_arg(args, 1, has_keyword_args)
    if prompt_val.kind != VkString:
      raise new_exception(types.Exception, "Session.infer_streaming prompt must be a string")

    let callback_val = get_positional_arg(args, 2, has_keyword_args)
    if callback_val.kind notin {VkFunction, VkNativeFn, VkBlock, VkBoundMethod, VkNativeMethod}:
      raise new_exception(types.Exception, "Session.infer_streaming callback must be a function")

    let opts =
      if positional >= 4:
        expect_map(get_positional_arg(args, 3, has_keyword_args), "infer_streaming")
      else:
        NIL

    if has_option(opts, "timeout") or has_option(opts, "timeout_ms"):
      raise new_exception(types.Exception, "Session.infer_streaming timeout is not supported for local inference yet")

    var infer_opts = GeneLlmInferOptions(
      prompt: prompt_val.str.cstring,
      max_tokens: cint(max(1, get_int_option(opts, "max_tokens", session_state.max_tokens))),
      temperature: get_float_option(opts, "temperature", session_state.temperature).cfloat,
      top_p: get_float_option(opts, "top_p", session_state.top_p).cfloat,
      top_k: cint(max(1, get_int_option(opts, "top_k", session_state.top_k))),
      seed: cint(get_int_option(opts, "seed", session_state.seed))
    )

    var ctx = StreamCallbackContext(
      vm: vm,
      callback: callback_val,
      cancelled: false,
      utf8_buffer: ""
    )

    var completion: GeneLlmCompletion
    var err: GeneLlmError
    # Serialize llama.cpp operations - not thread-safe
    {.cast(gcsafe).}:
      acquire(global_llm_op_lock)
    try:
      let status = gene_llm_infer_streaming(session_state.handle, addr infer_opts, stream_token_callback, addr ctx, addr completion, addr err)
      if status != glsOk:
        {.cast(gcsafe).}:
          release(global_llm_op_lock)
        raise_backend_error(err)
    except:
      {.cast(gcsafe).}:
        release(global_llm_op_lock)
      raise
    {.cast(gcsafe).}:
      release(global_llm_op_lock)

    # Flush any remaining buffered UTF-8 content
    if ctx.utf8_buffer.len > 0 and not ctx.cancelled:
      let token_value = ctx.utf8_buffer.to_value()
      {.cast(gcsafe).}:
        try:
          case ctx.callback.kind
          of VkFunction:
            discard vm.exec_function(ctx.callback, @[token_value])
          of VkNativeFn:
            discard call_native_fn(ctx.callback.ref.native_fn, vm, [token_value])
          else:
            discard vm.exec_callable(ctx.callback, @[token_value])
        except:
          discard  # Ignore errors during final flush

    let result_value = completion_to_value(completion)
    gene_llm_free_completion(addr completion)
    result_value

  # Register a model globally for cross-thread access
  proc vm_register_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 1:
      raise new_exception(types.Exception, "register_model requires a model")
    let model_val = get_positional_arg(args, 0, has_keyword_args)
    # Validate it's a model (will throw if not)
    discard expect_model(model_val, "register_model")
    {.cast(gcsafe).}:
      acquire(global_model_lock)
      global_model_registry = model_val
      release(global_model_lock)
    NIL

  # Get the globally registered model (for worker threads)
  proc vm_get_model(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(global_model_lock)
      let model_value = global_model_registry
      release(global_model_lock)
      model_value

  proc cleanup_llm_backend() {.noconv.} =
    for state in tracked_sessions:
      cleanup_session(state)
    tracked_sessions.setLen(0)
    for state in tracked_models:
      cleanup_model(state)
    tracked_models.setLen(0)

  addExitProc(cleanup_llm_backend)

  proc init_llm_module*() =
    VmCreatedCallbacks.add proc() =
      {.cast(gcsafe).}:
        ensure_backend()
        
        # Initialize locks for thread-safe access
        initLock(global_model_lock)
        initLock(global_llm_op_lock)

        if App == NIL or App.kind != VkApplication:
          return
        if App.app.genex_ns == NIL or App.app.genex_ns.kind != VkNamespace:
          return

        model_class_global = new_class("Model")
        if App.app.object_class.kind == VkClass:
          model_class_global.parent = App.app.object_class.ref.class
        model_class_global.def_native_method("new_session", vm_model_new_session)
        model_class_global.def_native_method("close", vm_model_close)
        # Set global for cross-thread access
        global_model_class = model_class_global

        session_class_global = new_class("Session")
        if App.app.object_class.kind == VkClass:
          session_class_global.parent = App.app.object_class.ref.class
        session_class_global.def_native_method("infer", vm_session_infer)
        session_class_global.def_native_method("infer_streaming", vm_session_infer_streaming)
        session_class_global.def_native_method("close", vm_session_close)
        # Set global for cross-thread access
        global_session_class = session_class_global

        let llm_ns = new_ref(VkNamespace)
        llm_ns.ns = new_namespace("llm")

        let load_fn = new_ref(VkNativeFn)
        load_fn.native_fn = vm_load_model
        llm_ns.ns["load_model".to_key()] = load_fn.to_ref_value()

        let register_fn = new_ref(VkNativeFn)
        register_fn.native_fn = vm_register_model
        llm_ns.ns["register_model".to_key()] = register_fn.to_ref_value()

        let get_fn = new_ref(VkNativeFn)
        get_fn.native_fn = vm_get_model
        llm_ns.ns["get_model".to_key()] = get_fn.to_ref_value()

        let model_class_ref = new_ref(VkClass)
        model_class_ref.class = model_class_global
        llm_ns.ns["Model".to_key()] = model_class_ref.to_ref_value()

        let session_class_ref = new_ref(VkClass)
        session_class_ref.class = session_class_global
        llm_ns.ns["Session".to_key()] = session_class_ref.to_ref_value()

        App.app.genex_ns.ref.ns["llm".to_key()] = llm_ns.to_ref_value()

  init_llm_module()

proc init*(vm: ptr VirtualMachine): Namespace {.gcsafe.} =
  discard vm
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let llm_val = App.app.genex_ns.ref.ns.members.getOrDefault("llm".to_key(), NIL)
  if llm_val.kind == VkNamespace:
    return llm_val.ref.ns
  return nil

proc gene_llm_host_load_model*(path: cstring, options_ser: cstring,
                               out_model_id: ptr int64, out_error: ptr cstring): int32 {.cdecl, exportc, dynlib.} =
  if not llm_extension_host_ready:
    llm_set_error(out_error, "LLM host bridge is not initialized")
    return int32(GlhsErr)
  try:
    llm_clear_error(out_error)
    if path == nil:
      llm_set_error(out_error, "Model path must be a string")
      return int32(GlhsErr)
    let options = llm_parse_options(options_ser)
    var args = @[($path).to_value()]
    if options != NIL:
      args.add(options)
    let model = call_native_fn(vm_load_model, llm_host_vm(), args)
    let id = llm_backend_next_model_id
    llm_backend_next_model_id.inc()
    llm_backend_model_handles[id] = model
    if out_model_id != nil:
      out_model_id[] = id
    int32(GlhsOk)
  except CatchableError as exc:
    llm_set_error(out_error, exc.msg)
    int32(GlhsErr)

proc gene_llm_host_new_session*(model_id: int64, options_ser: cstring,
                                out_session_id: ptr int64, out_error: ptr cstring): int32 {.cdecl, exportc, dynlib.} =
  if not llm_extension_host_ready:
    llm_set_error(out_error, "LLM host bridge is not initialized")
    return int32(GlhsErr)
  try:
    llm_clear_error(out_error)
    let model = llm_backend_model_handles.getOrDefault(model_id, NIL)
    if model == NIL:
      llm_set_error(out_error, "LLM model handle is no longer valid")
      return int32(GlhsErr)
    let options = llm_parse_options(options_ser)
    var args = @[model]
    if options != NIL:
      args.add(options)
    let session = call_native_fn(vm_model_new_session, llm_host_vm(), args)
    let id = llm_backend_next_session_id
    llm_backend_next_session_id.inc()
    llm_backend_session_handles[id] = session
    if out_session_id != nil:
      out_session_id[] = id
    int32(GlhsOk)
  except CatchableError as exc:
    llm_set_error(out_error, exc.msg)
    int32(GlhsErr)

proc gene_llm_host_infer*(session_id: int64, prompt: cstring, options_ser: cstring,
                          out_result_ser: ptr cstring, out_error: ptr cstring): int32 {.cdecl, exportc, dynlib.} =
  if not llm_extension_host_ready:
    llm_set_error(out_error, "LLM host bridge is not initialized")
    return int32(GlhsErr)
  try:
    llm_clear_error(out_error)
    if out_result_ser != nil:
      out_result_ser[] = nil
    if prompt == nil:
      llm_set_error(out_error, "Session.infer prompt must be a string")
      return int32(GlhsErr)
    let session = llm_backend_session_handles.getOrDefault(session_id, NIL)
    if session == NIL:
      llm_set_error(out_error, "LLM session handle is no longer valid")
      return int32(GlhsErr)
    let options = llm_parse_options(options_ser)
    var args = @[session, ($prompt).to_value()]
    if options != NIL:
      args.add(options)
    let reply = call_native_fn(vm_session_infer, llm_host_vm(), args)
    if out_result_ser != nil:
      out_result_ser[] = llm_serialize_reply(reply)
    int32(GlhsOk)
  except CatchableError as exc:
    llm_set_error(out_error, exc.msg)
    int32(GlhsErr)

proc gene_llm_host_close_model*(model_id: int64, out_error: ptr cstring): int32 {.cdecl, exportc, dynlib.} =
  if not llm_extension_host_ready:
    llm_set_error(out_error, "LLM host bridge is not initialized")
    return int32(GlhsErr)
  try:
    llm_clear_error(out_error)
    let model = llm_backend_model_handles.getOrDefault(model_id, NIL)
    if model == NIL:
      llm_set_error(out_error, "LLM model handle is no longer valid")
      return int32(GlhsErr)
    discard call_native_fn(vm_model_close, llm_host_vm(), @[model])
    llm_backend_model_handles.del(model_id)
    int32(GlhsOk)
  except CatchableError as exc:
    llm_set_error(out_error, exc.msg)
    int32(GlhsErr)

proc gene_llm_host_close_session*(session_id: int64, out_error: ptr cstring): int32 {.cdecl, exportc, dynlib.} =
  if not llm_extension_host_ready:
    llm_set_error(out_error, "LLM host bridge is not initialized")
    return int32(GlhsErr)
  try:
    llm_clear_error(out_error)
    let session = llm_backend_session_handles.getOrDefault(session_id, NIL)
    if session == NIL:
      llm_set_error(out_error, "LLM session handle is no longer valid")
      return int32(GlhsErr)
    discard call_native_fn(vm_session_close, llm_host_vm(), @[session])
    llm_backend_session_handles.del(session_id)
    int32(GlhsOk)
  except CatchableError as exc:
    llm_set_error(out_error, exc.msg)
    int32(GlhsErr)

proc gene_llm_host_free_cstring*(s: cstring) {.cdecl, exportc, dynlib.} =
  if s != nil:
    deallocShared(cast[pointer](s))

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host == nil:
    return int32(GeneExtErr)
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return int32(GeneExtAbiMismatch)
  llm_extension_host = host[]
  llm_extension_host_ready = true
  let vm = apply_extension_host_context(host)
  run_extension_vm_created_callbacks()
  let ns = init(vm)
  if host.result_namespace != nil:
    host.result_namespace[] = ns
  if ns == nil:
    return int32(GeneExtErr)
  int32(GeneExtOk)

## Gene VM bindings for OpenAI API
## Bridges the Nim OpenAI client to Gene's VM system

import tables, json, strutils
import asyncdispatch
import ../../gene/types
import ../../gene/vm
import ../../gene/vm/extension_abi
import openai_client, streaming, documents
import slack_socket_mode, control_slack, utils as ai_utils

var openai_client_class*: Class
var openai_error_class*: Class
var openai_clients: Table[system.int64, OpenAIConfig] = initTable[system.int64, OpenAIConfig]()
var next_client_id: system.int64 = 1

proc openai_client_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}

# Helper to convert Gene Value to JsonNode
proc geneValueToJson*(value: Value): JsonNode =
  case value.kind
  of VkNil:
    result = newJNull()
  of VkBool:
    result = %*value.to_bool
  of VkInt:
    result = %*value.int64.int
  of VkFloat:
    result = %*value.float
  of VkString:
    result = %*value.str
  of VkArray:
    var arr = newJArray()
    for item in array_data(value):
      arr.add(geneValueToJson(item))
    result = arr
  of VkMap:
    var obj = newJObject()
    for key, val in map_data(value):
      let symbol_value = cast[Value](key)
      obj[symbol_value.str] = geneValueToJson(val)
    result = obj
  of VkGene:
    # Handle Gene expressions by evaluating them first
    # For now, convert to string
    result = %*($value)
  else:
    result = %*($value)

# Helper to convert JsonNode to Gene Value
proc jsonToGeneValue*(json: JsonNode): Value =
  case json.kind
  of JNull:
    result = NIL
  of JBool:
    result = json.getBool.to_value
  of JInt:
    result = json.getInt.to_value
  of JFloat:
    result = json.getFloat.to_value
  of JString:
    result = json.getStr.to_value
  of JArray:
    var arr = newSeq[Value]()
    for item in json:
      arr.add(jsonToGeneValue(item))
    result = new_array_value(arr)
  of JObject:
    var map = initTable[Key, Value]()
    for key, value in json:
      map[key.to_key()] = jsonToGeneValue(value)
    result = new_map_value(map)

# Helper to create error objects
proc attach_error_class(instance: Value) {.gcsafe.} =
  {.cast(gcsafe).}:
    if not openai_error_class.isNil:
      instance_class(instance) = openai_error_class

proc new_error*(message: string): Value {.gcsafe.} =
  let error_class = block:
    {.cast(gcsafe).}:
      openai_error_class
  let error_obj = new_instance_value(error_class)
  attach_error_class(error_obj)
  instance_props(error_obj)["message".to_key()] = message.to_value
  instance_props(error_obj)["type".to_key()] = "error".to_value
  result = error_obj

proc openai_error_value*(err: OpenAIError): Value {.gcsafe.} =
  let error_class = block:
    {.cast(gcsafe).}:
      openai_error_class
  let error_obj = new_instance_value(error_class)
  attach_error_class(error_obj)
  instance_props(error_obj)["message".to_key()] = err.msg.to_value
  instance_props(error_obj)["status".to_key()] = err.status.to_value
  if err.provider_error.len > 0:
    instance_props(error_obj)["provider_error".to_key()] = err.provider_error.to_value
  if err.request_id.len > 0:
    instance_props(error_obj)["request_id".to_key()] = err.request_id.to_value
  if err.retry_after != 0:
    instance_props(error_obj)["retry_after".to_key()] = err.retry_after.to_value
  if err.metadata != nil:
    instance_props(error_obj)["metadata".to_key()] = jsonToGeneValue(err.metadata)
  result = error_obj

proc register_client(config: OpenAIConfig): Value =
  let client_id = next_client_id
  inc(next_client_id)
  openai_clients[client_id] = config

  let instance_class = block:
    {.cast(gcsafe).}:
      (
        if openai_client_class != nil:
          openai_client_class
        else:
          # Create a temporary class if the global one is not yet available
          var base_parent: Class = nil
          if App != nil and App.app.object_class.kind == VkClass:
            base_parent = App.app.object_class.ref.class
          new_class("OpenAIClient", base_parent)
      )
  let instance = new_instance_value(instance_class)

  instance_props(instance)["client_id".to_key()] = client_id.to_value
  instance_props(instance)["base_url".to_key()] = config.base_url.to_value
  instance_props(instance)["model".to_key()] = config.model.to_value

  result = instance

proc fetch_client_config(client_val: Value): tuple[config: OpenAIConfig, err: Value] =
  if client_val.kind != VkInstance:
    return (nil, new_error("Invalid OpenAI client"))

  if not instance_props(client_val).has_key("client_id".to_key()):
    return (nil, new_error("Invalid OpenAI client"))

  let client_id = instance_props(client_val)["client_id".to_key()].to_int()
  var cfg: OpenAIConfig = nil
  {.cast(gcsafe).}:
    if openai_clients.hasKey(client_id):
      cfg = openai_clients[client_id]

  if cfg.isNil:
    return (nil, new_error("OpenAI client not found"))

  (cfg, NIL)

# Native function: Create new OpenAI client
proc vm_openai_new_client*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var options: JsonNode = newJNull()

  if get_positional_count(arg_count, has_keyword_args) > 0:
    let options_val = get_positional_arg(args, 0, has_keyword_args)
    options = geneValueToJson(options_val)

  let config = buildOpenAIConfig(options)
  return register_client(config)

proc openai_client_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  var options: JsonNode = newJNull()
  if get_positional_count(arg_count, has_keyword_args) > 0:
    options = geneValueToJson(get_positional_arg(args, 0, has_keyword_args))

  let config = buildOpenAIConfig(options)
  {.cast(gcsafe).}:
    result = register_client(config)

proc openai_error_result(err: OpenAIError): Value =
  return openai_error_value(err)

proc call_openai_endpoint(config: OpenAIConfig, endpoint: string, payload: JsonNode): Value {.gcsafe.} =
  try:
    let response = performRequest(config, "POST", endpoint, payload)
    return jsonToGeneValue(response)
  except OpenAIError as e:
    return openai_error_value(e)

proc call_gene_callable(vm: ptr VirtualMachine, callable: Value, args: seq[Value]) {.gcsafe.} =
  case callable.kind
  of VkNativeFn:
    discard call_native_fn(callable.ref.native_fn, vm, args)
  of VkFunction:
    {.cast(gcsafe).}:
      discard vm.exec_function(callable, args)
  of VkClass:
    if callable.ref.class.methods.hasKey("call".to_key()):
      let call_method = callable.ref.class.methods["call".to_key()].callable
      var new_args = @[callable]
      new_args.add(args)
      call_gene_callable(vm, call_method, new_args)
  of VkInstance:
    let inst_class = instance_class(callable)
    if not inst_class.isNil and inst_class.methods.hasKey("call".to_key()):
      let call_method = inst_class.methods["call".to_key()].callable
      var new_args = @[callable]
      new_args.add(args)
      call_gene_callable(vm, call_method, new_args)
  else:
    discard

proc createGeneStreamHandler(vm: ptr VirtualMachine, callback: Value): StreamHandler =
  proc handler(event: StreamEvent) {.gcsafe.} =
    try:
      var map = initTable[Key, Value]()
      map["event".to_key()] = event.event.to_value
      map["done".to_key()] = event.done.to_value
      if event.data != nil:
        map["data".to_key()] = jsonToGeneValue(event.data)
      else:
        map["data".to_key()] = NIL
      let event_value = new_map_value(map)
      call_gene_callable(vm, callback, @[event_value])
    except system.Exception as e:
      when defined(debug):
        echo "DEBUG: Stream handler error: ", e.msg
  return handler

proc openai_error_to_s(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    return "OpenAIError".to_value()

  let self_val = get_positional_arg(args, 0, has_keyword_args)
  if self_val.kind != VkInstance:
    return "OpenAIError".to_value()

  let props = instance_props(self_val)
  let message_key = "message".to_key()
  var desc = "OpenAIError"
  if props.hasKey(message_key) and props[message_key].kind == VkString:
    desc &= ": " & props[message_key].str

  var details: seq[string] = @[]
  for key_name in ["status", "request_id", "provider_error"]:
    let k = key_name.to_key()
    if props.hasKey(k):
      details.add(key_name & "=" & $props[k])
  if props.hasKey("retry_after".to_key()):
    details.add("retry_after=" & $props["retry_after".to_key()])

  if details.len > 0:
    desc &= " (" & details.join(", ") & ")"

  return desc.to_value()

proc start_openai_stream(vm: ptr VirtualMachine, config: OpenAIConfig, options: JsonNode, handler: Value): Value =
  if handler.kind notin {VkNativeFn, VkFunction, VkClass, VkInstance}:
    return new_error("Callback must be callable")

  var stream_opts = if options.kind == JNull: %*{} else: options
  stream_opts["stream"] = %*true
  let payload = buildChatPayload(config, stream_opts)

  let future_val = new_future_value()
  let future_obj = future_val.ref.future

  try:
    let stream_handler = createGeneStreamHandler(vm, handler)
    performStreamingRequest(config, "/chat/completions", payload, stream_handler)
    discard future_obj.complete("streaming completed".to_value)
  except OpenAIError as e:
    discard future_obj.fail(openai_error_value(e))
  except system.Exception as e:
    discard future_obj.fail(new_error("OpenAI stream failed: " & e.msg))

  return future_val

# Native function: Chat completion
proc vm_openai_chat*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    return new_error("OpenAI chat requires client and options arguments")

  let client_val = get_positional_arg(args, 0, has_keyword_args)
  let options_val = get_positional_arg(args, 1, has_keyword_args)

  let (config, err) = fetch_client_config(client_val)
  if err != NIL:
    return err

  let options = geneValueToJson(options_val)
  let payload = buildChatPayload(config, options)
  return call_openai_endpoint(config, "/chat/completions", payload)

# Native function: Embeddings
proc vm_openai_embeddings*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    return new_error("OpenAI embeddings requires client and options arguments")

  let client_val = get_positional_arg(args, 0, has_keyword_args)
  let options_val = get_positional_arg(args, 1, has_keyword_args)

  let (config, err) = fetch_client_config(client_val)
  if err != NIL:
    return err

  let options = geneValueToJson(options_val)
  let payload = buildEmbeddingsPayload(config, options)
  return call_openai_endpoint(config, "/embeddings", payload)

# Native function: Responses (for structured outputs)
proc vm_openai_respond*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    return new_error("OpenAI respond requires client and options arguments")

  let client_val = get_positional_arg(args, 0, has_keyword_args)
  let options_val = get_positional_arg(args, 1, has_keyword_args)

  let (config, err) = fetch_client_config(client_val)
  if err != NIL:
    return err

  let options = geneValueToJson(options_val)
  let payload = buildResponsesPayload(config, options)
  return call_openai_endpoint(config, "/responses", payload)

# Native function: Stream chat completion (instance method)
proc vm_openai_client_stream*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    return new_error("OpenAI client stream requires self and callback arguments")

  let self_val = get_positional_arg(args, 0, has_keyword_args)
  let callback_val = get_positional_arg(args, 1, has_keyword_args)

  let (config, err) = fetch_client_config(self_val)
  if err != NIL:
    return err

  var options = %*{}
  if get_positional_count(arg_count, has_keyword_args) > 2:
    options = geneValueToJson(get_positional_arg(args, 2, has_keyword_args))

  return start_openai_stream(vm, config, options, callback_val)

# Native function: Stream chat completion (namespace/global)
proc vm_openai_stream*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 3:
    return new_error("OpenAI stream requires client, options, and handler arguments")

  let client_val = get_positional_arg(args, 0, has_keyword_args)
  let options_val = get_positional_arg(args, 1, has_keyword_args)
  let handler_val = get_positional_arg(args, 2, has_keyword_args)

  let (config, err) = fetch_client_config(client_val)
  if err != NIL:
    return err

  let options = geneValueToJson(options_val)
  return start_openai_stream(vm, config, options, handler_val)

# Native function: Chat completion as instance method
proc vm_openai_client_chat*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    return new_error("OpenAI client chat requires self argument")

  let self_val = get_positional_arg(args, 0, has_keyword_args)
  let (config, err) = fetch_client_config(self_val)
  if err != NIL:
    return err

  var options = %*{}
  if get_positional_count(arg_count, has_keyword_args) > 1:
    options = geneValueToJson(get_positional_arg(args, 1, has_keyword_args))

  let payload = buildChatPayload(config, options)
  return call_openai_endpoint(config, "/chat/completions", payload)

proc vm_openai_client_embeddings*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    return new_error("OpenAI client embeddings requires self argument")

  let self_val = get_positional_arg(args, 0, has_keyword_args)
  let (config, err) = fetch_client_config(self_val)
  if err != NIL:
    return err

  var options = %*{}
  if get_positional_count(arg_count, has_keyword_args) > 1:
    options = geneValueToJson(get_positional_arg(args, 1, has_keyword_args))

  let payload = buildEmbeddingsPayload(config, options)
  return call_openai_endpoint(config, "/embeddings", payload)

proc vm_openai_client_respond*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    return new_error("OpenAI client respond requires self argument")

  let self_val = get_positional_arg(args, 0, has_keyword_args)
  let (config, err) = fetch_client_config(self_val)
  if err != NIL:
    return err

  var options = %*{}
  if get_positional_count(arg_count, has_keyword_args) > 1:
    options = geneValueToJson(get_positional_arg(args, 1, has_keyword_args))

  let payload = buildResponsesPayload(config, options)
  return call_openai_endpoint(config, "/responses", payload)

proc attach_openai_client_class*(cls: Class) =
  openai_client_class = cls
  cls.def_native_constructor(openai_client_constructor)
  cls.def_native_method("chat", vm_openai_client_chat)
  cls.def_native_method("embeddings", vm_openai_client_embeddings)
  cls.def_native_method("respond", vm_openai_client_respond)
  cls.def_native_method("stream", vm_openai_client_stream)
  if openai_error_class.isNil:
    var parent_cls: Class = nil
    if App.app.object_class.kind == VkClass:
      parent_cls = App.app.object_class.ref.class
    openai_error_class = new_class("OpenAIError", parent_cls)
    openai_error_class.def_native_method("to_s", openai_error_to_s)

# ---------------------------------------------------------------------------
# Slack Socket Mode native binding
# ---------------------------------------------------------------------------

var slack_vm_global: ptr VirtualMachine = nil
var slack_callback_global: Value = NIL

proc execute_gene_callback(vm: ptr VirtualMachine, fn: Value, args: seq[Value]): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    case fn.kind
    of VkNativeFn:
      return call_native_fn(fn.ref.native_fn, vm, args)
    of VkFunction:
      return vm.exec_function(fn, args)
    else:
      echo "start_slack_socket_mode: callback is not callable (kind=", fn.kind, ")"
      return NIL

proc vm_start_slack_socket_mode*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 3:
    raise new_exception(types.Exception, "start_slack_socket_mode requires app_token, bot_token, and callback")

  let app_token_val = get_positional_arg(args, 0, has_keyword_args)
  let bot_token_val = get_positional_arg(args, 1, has_keyword_args)
  let callback_val = get_positional_arg(args, 2, has_keyword_args)

  if app_token_val.kind != VkString:
    raise new_exception(types.Exception, "start_slack_socket_mode: app_token must be a string")
  if bot_token_val.kind != VkString:
    raise new_exception(types.Exception, "start_slack_socket_mode: bot_token must be a string")
  if callback_val.kind notin {VkFunction, VkNativeFn}:
    raise new_exception(types.Exception, "start_slack_socket_mode: callback must be a function")

  let app_token = app_token_val.str
  let bot_token = bot_token_val.str

  # Store VM and callback for use inside the event handler closure
  {.cast(gcsafe).}:
    slack_vm_global = vm
    slack_callback_global = callback_val

  let slack_client = new_slack_client(bot_token)

  let event_handler: SocketModeEventHandler = proc(event_type: string; payload: JsonNode) {.gcsafe.} =
    if event_type != "events_api":
      return
    # Parse the Slack event into a CommandEnvelope
    var envelope: CommandEnvelope
    try:
      envelope = slack_event_to_command(payload)
    except CatchableError as e:
      echo "Socket Mode: skipping event: ", e.msg
      return

    # Call the Gene callback with (workspace_id, user_id, channel_id, text)
    var result: Value
    {.cast(gcsafe).}:
      let stored_vm = slack_vm_global
      let stored_cb = slack_callback_global
      try:
        result = execute_gene_callback(stored_vm, stored_cb, @[
          envelope.workspace_id.to_value,
          envelope.user_id.to_value,
          envelope.channel_id.to_value,
          envelope.text.to_value
        ])
      except CatchableError as e:
        echo "Socket Mode: agent error: ", e.msg
        return
      except system.Exception as e:
        echo "Socket Mode: agent error: ", e.msg
        return

    # Reply to Slack with the response field from the result
    if result.kind == VkMap:
      let response_key = "response".to_key()
      if map_data(result).hasKey(response_key):
        let response_val = map_data(result)[response_key]
        if response_val.kind == VkString and response_val.str.len > 0:
          let target = reply_target_from_envelope(envelope)
          let reply_result = slack_client.slack_reply(target, response_val.str)
          if not reply_result.ok:
            echo "Socket Mode: Slack reply failed: ", reply_result.error

  let client = new_slack_socket_mode(app_token, bot_token, event_handler)

  {.cast(gcsafe).}:
    asyncCheck client.start()
    # Give the event loop time to start the connection
    try:
      poll(100)
    except ValueError:
      discard

  echo "Slack Socket Mode client started"
  return NIL

# Initialize OpenAI classes and functions
proc init_openai_classes*() =
  VmCreatedCallbacks.add proc() {.gcsafe.} =
    if App == NIL or App.kind != VkApplication:
      return
    if App.app.global_ns == NIL or App.app.global_ns.kind != VkNamespace:
      return
    if App.app.genex_ns == NIL or App.app.genex_ns.kind != VkNamespace:
      return

    # Create OpenAI namespace
    let ai_ns = new_namespace("ai")

    # Create OpenAIClient class and attach native constructor/methods
    var base_parent: Class = nil
    if App.app.object_class.kind == VkClass:
      base_parent = App.app.object_class.ref.class
    let openai_client_class = new_class("OpenAIClient", base_parent)
    {.cast(gcsafe).}:
      attach_openai_client_class(openai_client_class)

    # Register OpenAI client constructor helper
    let global_ns = App.app.global_ns.ref.ns
    ai_ns["new_client".to_key()] = vm_openai_new_client.to_value()
    global_ns["openai_new_client".to_key()] = vm_openai_new_client.to_value()

    # Register the class in namespaces
    let openai_class_ref = new_ref(VkClass)
    openai_class_ref.class = openai_client_class
    let openai_class_value = openai_class_ref.to_ref_value()

    ai_ns["OpenAIClient".to_key()] = openai_class_value
    global_ns["OpenAIClient".to_key()] = openai_class_value

    {.cast(gcsafe).}:
      if not openai_error_class.isNil:
        let error_class_ref = new_ref(VkClass)
        error_class_ref.class = openai_error_class
        let error_class_value = error_class_ref.to_ref_value()
        ai_ns["OpenAIError".to_key()] = error_class_value
        global_ns["OpenAIError".to_key()] = error_class_value

    # Register the AI namespace in genex namespace
    App.app.genex_ns.ref.ns["ai".to_key()] = ai_ns.to_value()

    # Register convenience functions in ai namespace for direct access
    ai_ns["chat".to_key()] = vm_openai_chat.to_value()
    ai_ns["embeddings".to_key()] = vm_openai_embeddings.to_value()
    ai_ns["respond".to_key()] = vm_openai_respond.to_value()
    ai_ns["stream".to_key()] = vm_openai_stream.to_value()
    ai_ns["start_slack_socket_mode".to_key()] = vm_start_slack_socket_mode.to_value()

    let documents_ns = new_namespace("documents")
    documents_ns["extract_pdf".to_key()] = vm_ai_documents_extract_pdf.to_value()
    documents_ns["extract_image".to_key()] = vm_ai_documents_extract_image.to_value()
    documents_ns["chunk".to_key()] = vm_ai_documents_chunk.to_value()
    documents_ns["extract_and_chunk".to_key()] = vm_ai_documents_extract_and_chunk.to_value()
    documents_ns["save_upload".to_key()] = vm_ai_documents_save_upload.to_value()
    documents_ns["validate_upload".to_key()] = vm_ai_documents_validate_upload.to_value()
    documents_ns["extract_upload".to_key()] = vm_ai_documents_extract_upload.to_value()
    ai_ns["documents".to_key()] = documents_ns.to_value()

    global_ns["openai_chat".to_key()] = vm_openai_chat.to_value()
    global_ns["openai_embeddings".to_key()] = vm_openai_embeddings.to_value()
    global_ns["openai_respond".to_key()] = vm_openai_respond.to_value()
    global_ns["openai_stream".to_key()] = vm_openai_stream.to_value()

    # Slack Socket Mode
    global_ns["start_slack_socket_mode".to_key()] = vm_start_slack_socket_mode.to_value()

# Call init function
init_openai_classes()

proc init*(vm: ptr VirtualMachine): Namespace {.gcsafe.} =
  discard vm
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let ai_val = App.app.genex_ns.ref.ns.members.getOrDefault("ai".to_key(), NIL)
  if ai_val.kind == VkNamespace:
    return ai_val.ref.ns
  return nil

var ai_host_scheduler_registered = false

proc ai_scheduler_tick(vm_user_data: pointer, callback_user_data: pointer) {.cdecl, gcsafe.} =
  ## Called by the host's run_forever loop to pump the extension's async dispatcher.
  discard callback_user_data
  try:
    poll(0)
  except CatchableError:
    discard

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host == nil:
    return int32(GeneExtErr)
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return int32(GeneExtAbiMismatch)
  let vm = apply_extension_host_context(host)
  if host.register_scheduler_callback_fn != nil and not ai_host_scheduler_registered:
    if host.register_scheduler_callback_fn(ai_scheduler_tick, nil) != int32(GeneExtOk):
      return int32(GeneExtErr)
    ai_host_scheduler_registered = true
  run_extension_vm_created_callbacks()
  let ns = init(vm)
  if host.result_namespace != nil:
    host.result_namespace[] = ns
  if ns == nil:
    return int32(GeneExtErr)
  int32(GeneExtOk)

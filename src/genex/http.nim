{.push warning[IgnoredSymbolInjection]: off, warning[ResultShadowed]: off.}
import tables, strutils
import httpclient, uri
import std/json
import ../asynchttpserver
import asyncdispatch, asyncnet
import asyncfutures  # Import asyncfutures explicitly
import nativesockets, net
import cgi
import websocket as ws_module

include ../gene/extension/boilerplate
import ../gene/vm
import ../gene/vm/actor
import ../gene/vm/extension_abi
import ../gene/logging_core
import ../gene/serdes
# Explicitly alias to use asyncfutures.Future in this module (preserve generic)
type
  Future[T] {.used.} = asyncfutures.Future[T]

# ============ Actor-backed concurrent HTTP ownership ============

const MAX_HTTP_WORKERS = 8
const GenexHttpLogger = "genex/http"

template http_log(level: LogLevel, message: untyped) =
  if extension_log_enabled(level, GenexHttpLogger):
    extension_log_message(level, GenexHttpLogger, message)

var http_extension_host: GeneHostAbi
var http_extension_host_ready = false
var http_request_ports: Value = NIL
var http_request_port_count = 0
var next_http_port_idx = 0

# Global variables to store classes
var request_class_global: Class
var response_class_global: Class
var server_request_class_global: Class

var server_response_class_global: Class
var server_stream_class_global: Class
var ws_connection_class_global: Class

# WebSocket handler stored from ^websocket keyword arg
var ws_handler_global: Value = NIL
var ws_path_global: string = ""

# Concurrent mode flag
var concurrent_mode: bool = false

# Global HTTP server instance
var http_server: AsyncHttpServer
var server_handler: proc(req: Value): Value {.gcsafe.}
var http_host_scheduler_registered: bool = false
var gene_handler_global: Value = NIL
var gene_vm_global: ptr VirtualMachine = nil

# Forward declarations
proc request_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc request_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc response_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc response_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc vm_start_server(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc vm_respond(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc vm_respond_sse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc vm_redirect(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc server_stream_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc server_stream_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc ws_connection_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc ws_connection_recv(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc ws_connection_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc vm_ws_connect(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}
proc new_ws_connection_instance(ws: ws_module.WebSocket): Value {.gcsafe.}
proc execute_gene_function(vm: ptr VirtualMachine, fn: Value, args: seq[Value]): Value {.gcsafe.}
proc response_to_literal(resp: Value): Value {.gcsafe.}
proc literal_to_server_request(req_map: Value): Value {.gcsafe.}
proc literal_error_response(message: string): Value {.gcsafe.}
proc http_actor_handle_request(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}

proc parse_json_internal(node: json.JsonNode): Value {.gcsafe.}

proc headers_from_map(headers_val: Value): HttpHeaders =
  var headers = newHttpHeaders()
  if headers_val.kind == VkMap:
    for k, v in map_data(headers_val):
      let header_name = cast[Value](k).str
      case v.kind
      of VkString:
        headers[header_name] = v.str
      of VkArray:
        var values: seq[string] = @[]
        for item in array_data(v):
          case item.kind
          of VkString, VkSymbol:
            values.add(item.str)
          else:
            values.add($item)
        if values.len > 0:
          headers[header_name] = values
      else:
        headers[header_name] = $v
  headers

proc apply_default_sse_headers(headers: var HttpHeaders) =
  if not headers.hasKey("Content-Type"):
    headers["Content-Type"] = "text/event-stream"
  if not headers.hasKey("Cache-Control"):
    headers["Cache-Control"] = "no-cache"
  if not headers.hasKey("Connection"):
    headers["Connection"] = "keep-alive"
  if not headers.hasKey("X-Accel-Buffering"):
    headers["X-Accel-Buffering"] = "no"
  if not headers.hasKey("Transfer-Encoding") and not headers.hasKey("Content-Length"):
    headers["Transfer-Encoding"] = "chunked"

proc send_status_and_headers(client: AsyncSocket, status: string, headers: HttpHeaders) =
  var msg = "HTTP/1.1 " & status & "\c\L"
  for k, v in headers:
    msg.add(k & ": " & v & "\c\L")
  msg.add("\c\L")
  waitFor client.send(msg, {})

proc send_chunk(client: AsyncSocket, payload: string) =
  let size_hex = toHex(payload.len)
  let chunk = size_hex & "\c\L" & payload & "\c\L"
  waitFor client.send(chunk, {})

proc get_native_client(req_val: Value): AsyncSocket =
  if req_val.kind != VkInstance:
    raise new_exception(types.Exception, "respond_sse requires a ServerRequest instance")
  let ptr_val = instance_props(req_val).getOrDefault("__native_client".to_key(), NIL)
  if ptr_val.kind != VkPointer:
    raise new_exception(types.Exception, "respond_sse requires a live request (not available in concurrent mode)")
  let req_ptr = ptr_val.to_pointer()
  if req_ptr.is_nil:
    raise new_exception(types.Exception, "respond_sse request client pointer is nil")
  cast[AsyncSocket](req_ptr)

proc http_actor_method(vm: ptr VirtualMachine, actor_handle: Value, method_name: string,
                       args: seq[Value]): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if actor_handle.kind != VkActor:
      raise new_exception(types.Exception, "HTTP concurrent worker handle is not an actor")
    if App == NIL or App.kind != VkApplication or App.app.actor_class.kind != VkClass:
      raise new_exception(types.Exception, "HTTP concurrent mode requires gene/actor/enable first")
    let actor_class = App.app.actor_class.ref.class
    let key = method_name.to_key()
    if not actor_class.methods.hasKey(key):
      raise new_exception(types.Exception, "Actor method not available: " & method_name)
    let callable = actor_class.methods[key].callable
    case callable.kind
    of VkNativeFn:
      call_native_fn(callable.ref.native_fn, vm, @[actor_handle] & args)
    of VkNativeMethod:
      call_native_fn(callable.ref.native_method, vm, @[actor_handle] & args)
    else:
      vm.exec_method(callable, actor_handle, args)

proc ensure_http_request_ports(worker_count: int): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if http_request_ports.kind == VkArray:
      return http_request_ports
    if not http_extension_host_ready:
      raise new_exception(types.Exception, "HTTP extension host context is not initialized")

    let requested = min(max(1, worker_count), MAX_HTTP_WORKERS)
    var handle = NIL
    let status = register_port_pool(
      addr http_extension_host,
      "genex/http/request",
      requested,
      NativeFn(http_actor_handle_request).to_value(),
      NIL,
      addr handle
    )
    if status != GeneExtOk or handle.kind != VkArray:
      raise new_exception(types.Exception, "HTTP concurrent mode requires gene/actor/enable before start_server ^concurrent true")

    http_request_ports = handle
    http_request_port_count = array_data(handle).len
    next_http_port_idx = 0
    handle

proc dispatch_to_http_actor(vm: ptr VirtualMachine, request_data: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let ports = ensure_http_request_ports(if http_request_port_count > 0: http_request_port_count else: 1)
    if ports.kind != VkArray or array_data(ports).len == 0:
      raise new_exception(types.Exception, "HTTP concurrent worker ports are not available")
    let handles = array_data(ports)
    let actor_idx = next_http_port_idx mod handles.len
    next_http_port_idx.inc()
    http_actor_method(vm, handles[actor_idx], "send_expect_reply", @[request_data])

proc reset_http_concurrent_state_for_test*() {.gcsafe.} =
  {.cast(gcsafe).}:
    http_request_ports = NIL
    http_request_port_count = 0
    next_http_port_idx = 0
    concurrent_mode = false
    gene_handler_global = NIL
    gene_vm_global = nil

proc configure_http_handler_for_test*(vm: ptr VirtualMachine, handler: Value) {.gcsafe.} =
  {.cast(gcsafe).}:
    gene_vm_global = vm
    gene_handler_global = handler

proc ensure_http_request_ports_for_test*(worker_count: int): Value {.gcsafe.} =
  ensure_http_request_ports(worker_count)

proc dispatch_http_concurrent_request_for_test*(vm: ptr VirtualMachine, request_data: Value): Value {.gcsafe.} =
  dispatch_to_http_actor(vm, request_data)

proc parse_json*(json_str: string): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let json_node = json.parseJson(json_str)
    return parse_json_internal(json_node)

proc parse_json_internal(node: json.JsonNode): Value {.gcsafe.} =
  case node.kind:
  of json.JNull:
    return NIL
  of json.JBool:
    return to_value(node.bval)
  of json.JInt:
    return to_value(node.num)
  of json.JFloat:
    return to_value(node.fnum)
  of json.JString:
    return new_str_value(node.str)
  of json.JObject:
    var map_table = initTable[Key, Value]()
    for k, v in node.fields:
      map_table[to_key(k)] = parse_json_internal(v)
    result = new_map_value(map_table)
  of json.JArray:
    var arr: seq[Value] = @[]
    for elem in node.elems:
      arr.add(parse_json_internal(elem))
    result = new_array_value(arr)

proc to_json*(val: Value): string =
  case val.kind:
  of VkNil:
    return "null"
  of VkBool:
    return $val.to_bool
  of VkInt:
    return $val.to_int
  of VkFloat:
    return $val.to_float
  of VkString:
    return json.escapeJson(val.str)
  of VkArray:
    var items: seq[string] = @[]
    for item in array_data(val):
      items.add(to_json(item))
    return "[" & items.join(",") & "]"
  of VkMap:
    var items: seq[string] = @[]
    let r = val.ref
    for k, v in r.map:
      # Convert Key to symbol string
      let key_val = cast[Value](k)  # Key is a packed symbol value
      let key_str = if key_val.kind == VkSymbol:
        key_val.str
      else:
        "unknown_key"
      items.add("\"" & json.escapeJson(key_str) & "\":" & to_json(v))
    return "{" & items.join(",") & "}"
  else:
    return "null"

proc new_map_from_pairs(pairs: seq[(string, string)]): Value =
  var table = initTable[Key, Value]()
  for (k, v) in pairs:
    table[k.to_key()] = v.to_value()
  result = new_map_value(table)

proc parse_form_body(body: string): Value =
  var pairs: seq[(string, string)] = @[]
  for key, val in decodeData(body):
    pairs.add((key, val))
  if pairs.len == 0:
    return NIL
  new_map_from_pairs(pairs)

proc parse_body_params(body: string, content_type: string): Value =
  let trimmed = body.strip()
  if trimmed.len == 0:
    return NIL
  let normalized = content_type.toLowerAscii()
  if normalized.contains("application/json"):
    try:
      return parse_json(trimmed)
    except CatchableError:
      return NIL
  let is_form = normalized.contains("application/x-www-form-urlencoded") or
                (normalized.len == 0 and trimmed.contains("="))
  if is_form:
    return parse_form_body(trimmed)
  return NIL

proc server_request_get_prop(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, prop: Key): Value =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "ServerRequest method requires self")
  let self_val = get_positional_arg(args, 0, has_keyword_args)
  if self_val.kind != VkInstance:
    raise new_exception(types.Exception, "ServerRequest methods must be called on an instance")
  return instance_props(self_val).getOrDefault(prop, NIL)

proc server_request_path(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "path".to_key())

proc server_request_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "method".to_key())

proc server_request_url(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "url".to_key())

proc server_request_params(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "params".to_key())

proc server_request_headers(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "headers".to_key())

proc server_request_body(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "body".to_key())

proc server_request_body_params(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  server_request_get_prop(vm, args, arg_count, has_keyword_args, "body_params".to_key())

proc http_get*(url: string, headers: Table[string, string] = initTable[string, string]()): string =
  var client = newHttpClient()
  for k, v in headers:
    client.headers[k] = v
  result = client.getContent(url)
  client.close()

proc http_get_json*(url: string, headers: Table[string, string] = initTable[string, string]()): Value =
  let content = http_get(url, headers)
  return parse_json(content)

proc http_post*(url: string, body: string = "", headers: Table[string, string] = initTable[string, string]()): string =
  var client = newHttpClient()
  for k, v in headers:
    client.headers[k] = v
  result = client.postContent(url, body)
  client.close()

proc http_post_json*(url: string, body: Value, headers: Table[string, string] = initTable[string, string]()): Value =
  var hdrs = headers
  hdrs["Content-Type"] = "application/json"
  let json_body = to_json(body)
  let content = http_post(url, json_body, hdrs)
  return parse_json(content)

proc http_put*(url: string, body: string = "", headers: Table[string, string] = initTable[string, string]()): string =
  var client = newHttpClient()
  for k, v in headers:
    client.headers[k] = v
  result = client.request(url, HttpPut, body).body
  client.close()

proc http_delete*(url: string, headers: Table[string, string] = initTable[string, string]()): string =
  var client = newHttpClient()
  for k, v in headers:
    client.headers[k] = v
  result = client.request(url, HttpDelete).body
  client.close()

# Helper function that uses Request class for consistency
proc vm_http_get_helper(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # http_get(url, [headers]) -> Future[Response]
  if arg_count < 1:
    raise new_exception(types.Exception, "http_get requires at least a URL")

  let url = get_positional_arg(args, 0, has_keyword_args)
  var headers = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL

  # Create Request
  var req_args = @[url, "GET".to_value()]
  if headers != NIL:
    req_args.add(headers)

  let request = call_native_fn(request_constructor, vm, req_args)

  # Send request
  return call_native_fn(request_send, vm, @[request])

proc vm_http_post_helper(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # http_post(url, body, [headers]) -> Future[Response]
  if arg_count < 2:
    raise new_exception(types.Exception, "http_post requires URL and body")

  let url = get_positional_arg(args, 0, has_keyword_args)
  let body = get_positional_arg(args, 1, has_keyword_args)
  var headers = if arg_count > 2: get_positional_arg(args, 2, has_keyword_args) else: NIL

  # Create Request
  var req_args = @[url, "POST".to_value()]
  if headers != NIL:
    req_args.add(headers)
  else:
    let empty_map = new_map_value()
    map_data(empty_map) = Table[Key, Value]()
    req_args.add(empty_map)
  req_args.add(body)

  let request = call_native_fn(request_constructor, vm, req_args)

  # Send request
  return call_native_fn(request_send, vm, @[request])

# Native function wrappers for VM (backward compatibility)
proc vm_http_get(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_get requires at least 1 argument (url)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    var headers = initTable[string, string]()

    if arg_count > 1 and get_positional_arg(args, 1, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 1, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    let content = http_get(url, headers)
    return new_str_value(content)

proc vm_http_get_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_get_json requires at least 1 argument (url)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    var headers = initTable[string, string]()

    if arg_count > 1 and get_positional_arg(args, 1, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 1, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    return http_get_json(url, headers)

proc vm_http_post(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_post requires at least 1 argument (url)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    var body = ""
    var headers = initTable[string, string]()

    if arg_count > 1:
      let body_arg = get_positional_arg(args, 1, has_keyword_args)
      if body_arg.kind == VkString:
        body = body_arg.str
      elif body_arg.kind in {VkMap, VkArray}:
        body = to_json(body_arg)
        headers["Content-Type"] = "application/json"

    if arg_count > 2 and get_positional_arg(args, 2, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 2, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    let content = http_post(url, body, headers)
    return new_str_value(content)

proc vm_http_post_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 2:
      raise new_exception(types.Exception, "http_post_json requires at least 2 arguments (url, body)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    let body = get_positional_arg(args, 1, has_keyword_args)
    var headers = initTable[string, string]()

    if arg_count > 2 and get_positional_arg(args, 2, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 2, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    return http_post_json(url, body, headers)

proc vm_http_put(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_put requires at least 1 argument (url)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    var body = ""
    var headers = initTable[string, string]()

    if arg_count > 1 and get_positional_arg(args, 1, has_keyword_args).kind == VkString:
      body = get_positional_arg(args, 1, has_keyword_args).str

    if arg_count > 2 and get_positional_arg(args, 2, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 2, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    let content = http_put(url, body, headers)
    return new_str_value(content)

proc vm_http_delete(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_delete requires at least 1 argument (url)")

    let url = get_positional_arg(args, 0, has_keyword_args).str
    var headers = initTable[string, string]()

    if arg_count > 1 and get_positional_arg(args, 1, has_keyword_args).kind == VkMap:
      let r = get_positional_arg(args, 1, has_keyword_args).ref
      for k, v in r.map:
        if v.kind == VkString:
          headers[get_symbol(cast[int](k))] = v.str

    let content = http_delete(url, headers)
    return new_str_value(content)

proc vm_json_parse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "json_parse requires 1 argument (json_string)")

    let json_arg = get_positional_arg(args, 0, has_keyword_args)
    if json_arg.kind != VkString:
      raise new_exception(types.Exception, "json_parse requires a string argument")

    return parse_json(json_arg.str)

proc vm_json_stringify(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "json_stringify requires 1 argument")

    let json_str = to_json(get_positional_arg(args, 0, has_keyword_args))
    return new_ref_string_value(json_str)

proc http_scheduler_tick(vm_user_data: pointer, callback_user_data: pointer) {.cdecl, gcsafe.} =
  discard vm_user_data
  discard callback_user_data
  try:
    poll(0)
  except CatchableError:
    discard


proc init*(vm: ptr VirtualMachine): Namespace {.exportc, dynlib.} =
  discard vm
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let existing = App.app.genex_ns.ref.ns.members.getOrDefault("http".to_key(), NIL)
  if existing.kind == VkNamespace:
    return existing.ref.ns

  result = new_namespace("http")

  # HTTP functions
  var fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_get
  result["get".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_get_json
  result["get_json".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_post
  result["post".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_post_json
  result["post_json".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_put
  result["put".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_delete
  result["delete".to_key()] = fn.to_ref_value()

  # JSON functions
  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_json_parse
  result["json_parse".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_json_stringify
  result["json_stringify".to_key()] = fn.to_ref_value()

  # WebSocket client connect
  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_ws_connect
  result["ws_connect".to_key()] = fn.to_ref_value()

  # Global helper functions (also registered in global_ns by gene_init).
  # Exposing them here allows (import genex/http/start_server) etc.
  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_get_helper
  result["http_get".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_http_post_helper
  result["http_post".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_start_server
  result["start_server".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_respond
  result["respond".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_respond_sse
  result["respond_sse".to_key()] = fn.to_ref_value()

  fn = new_ref(VkNativeFn)
  fn.native_fn = vm_redirect
  result["redirect".to_key()] = fn.to_ref_value()

  App.app.genex_ns.ref.ns["http".to_key()] = result.to_value()

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host == nil:
    return int32(GeneExtErr)
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return int32(GeneExtAbiMismatch)
  let vm = apply_extension_host_context(host)
  http_extension_host = host[]
  http_extension_host_ready = true
  http_request_ports = NIL
  http_request_port_count = 0
  next_http_port_idx = 0
  if host.register_scheduler_callback_fn != nil and not http_host_scheduler_registered:
    if host.register_scheduler_callback_fn(http_scheduler_tick, nil) != int32(GeneExtOk):
      return int32(GeneExtErr)
    http_host_scheduler_registered = true
  run_extension_vm_created_callbacks()
  let ns = init(vm)
  if host.result_namespace != nil:
    host.result_namespace[] = ns
  if ns == nil:
    return int32(GeneExtErr)
  int32(GeneExtOk)

# Request constructor implementation
proc request_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # new Request(url, [method], [headers], [body])
  if arg_count < 1:
    raise new_exception(types.Exception, "Request requires at least a URL")

  let url = get_positional_arg(args, 0, has_keyword_args)
  if url.kind != VkString:
    raise new_exception(types.Exception, "URL must be a string")

  # Create Request instance
  let request_class = block:
    {.cast(gcsafe).}:
      request_class_global
  let instance = new_instance_value(request_class)

  # Set properties
  instance_props(instance)["url".to_key()] = url

  # Set method (default to GET)
  if arg_count > 1:
    instance_props(instance)["method".to_key()] = get_positional_arg(args, 1, has_keyword_args)
  else:
    instance_props(instance)["method".to_key()] = "GET".to_value()

  # Set headers (default to empty map)
  if arg_count > 2:
    instance_props(instance)["headers".to_key()] = get_positional_arg(args, 2, has_keyword_args)
  else:
    let empty_map = new_map_value()
    map_data(empty_map) = Table[Key, Value]()
    instance_props(instance)["headers".to_key()] = empty_map

  # Set body (default to nil)
  if arg_count > 3:
    instance_props(instance)["body".to_key()] = get_positional_arg(args, 3, has_keyword_args)
  else:
    instance_props(instance)["body".to_key()] = NIL

  return instance

# Request.send method - sends the request and returns a Future[Response]
proc request_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Request.send requires self")

  let request_obj = get_positional_arg(args, 0, has_keyword_args)
  if request_obj.kind != VkInstance:
    raise new_exception(types.Exception, "send can only be called on a Request instance")

  # Get request properties
  let url = instance_props(request_obj)["url".to_key()]
  let http_method = instance_props(request_obj)["method".to_key()]
  let headers = instance_props(request_obj)["headers".to_key()]
  let body = instance_props(request_obj)["body".to_key()]

  # Create HTTP client
  let client = newHttpClient()
  defer: client.close()

  # Set headers
  if headers.kind == VkMap:
    for k, v in map_data(headers):
      let header_name = cast[Value](k).str
      case v.kind
      of VkString:
        client.headers[header_name] = v.str
      of VkArray:
        var values: seq[string] = @[]
        for item in array_data(v):
          case item.kind
          of VkString, VkSymbol:
            values.add(item.str)
          else:
            values.add($item)
        if values.len > 0:
          client.headers[header_name] = values
      else:
        client.headers[header_name] = $v

  # Prepare body
  var bodyStr = ""
  if body.kind == VkString:
    bodyStr = body.str
  elif body.kind == VkMap:
    # Convert map to JSON
    var jsonObj = newJObject()
    for k, v in map_data(body):
      let key_str = cast[Value](k).str
      case v.kind:
      of VkString:
        jsonObj[key_str] = newJString(v.str)
      of VkInt:
        jsonObj[key_str] = newJInt(v.int64)
      of VkFloat:
        jsonObj[key_str] = newJFloat(v.float)
      of VkBool:
        jsonObj[key_str] = newJBool(v.bool)
      of VkNil:
        jsonObj[key_str] = newJNull()
      else:
        jsonObj[key_str] = newJString($v)
    bodyStr = $jsonObj
    client.headers["Content-Type"] = "application/json"

  # Send request based on method
  let methodStr = if http_method.kind == VkString: http_method.str.toUpperAscii() else: "GET"
  let response = case methodStr:
    of "GET":
      client.get(url.str)
    of "POST":
      client.post(url.str, body = bodyStr)
    of "PUT":
      client.request(url.str, httpMethod = HttpPut, body = bodyStr)
    of "DELETE":
      client.request(url.str, httpMethod = HttpDelete, body = bodyStr)
    of "PATCH":
      client.request(url.str, httpMethod = HttpPatch, body = bodyStr)
    of "HEAD":
      client.request(url.str, httpMethod = HttpHead)
    of "OPTIONS":
      client.request(url.str, httpMethod = HttpOptions)
    else:
      raise new_exception(types.Exception, "Unsupported HTTP method: " & methodStr)

  # Create Response instance
  let response_cls = block:
    {.cast(gcsafe).}:
      response_class_global
  let response_instance = new_instance_value(response_cls)
  instance_props(response_instance)["status".to_key()] = response.code.int.to_value()
  instance_props(response_instance)["body".to_key()] = response.body.to_value()

  # Convert headers to Gene map
  let headers_map = new_map_value()
  map_data(headers_map) = Table[Key, Value]()
  for k, v in response.headers.table:
    if v.len == 1:
      map_data(headers_map)[k.to_key()] = v[0].to_value()
    else:
      let values = new_array_value()
      for item in v:
        array_data(values).add(item.to_value())
      map_data(headers_map)[k.to_key()] = values
  instance_props(response_instance)["headers".to_key()] = headers_map

  # Create completed future with response
  let future = new_future_value()
  discard future.ref.future.complete(response_instance)
  return future

# Response constructor implementation
proc response_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # new Response(status, body, [headers])
  if arg_count < 2:
    raise new_exception(types.Exception, "Response requires status and body")

  let status = get_positional_arg(args, 0, has_keyword_args)
  let body = get_positional_arg(args, 1, has_keyword_args)

  # Create Response instance
  let response_cls = block:
    {.cast(gcsafe).}:
      response_class_global
  let instance = new_instance_value(response_cls)

  # Set properties
  instance_props(instance)["status".to_key()] = status
  instance_props(instance)["body".to_key()] = body

  # Set headers (default to empty map)
  if arg_count > 2:
    instance_props(instance)["headers".to_key()] = get_positional_arg(args, 2, has_keyword_args)
  else:
    let empty_map = new_map_value()
    map_data(empty_map) = Table[Key, Value]()
    instance_props(instance)["headers".to_key()] = empty_map

  return instance

# Response.json method - parses body as JSON
proc response_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Response.json requires self")

  let response_obj = get_positional_arg(args, 0, has_keyword_args)
  if response_obj.kind != VkInstance:
    raise new_exception(types.Exception, "json can only be called on a Response instance")

  let body = instance_props(response_obj)["body".to_key()]

  if body.kind != VkString:
    raise new_exception(types.Exception, "Response body must be a string to parse as JSON")

  # Parse JSON string into Gene map
  try:
    return parse_json(body.str)
  except JsonParsingError as e:
    raise new_exception(types.Exception, "Failed to parse JSON: " & e.msg)

proc init_http_classes*() =
  VmCreatedCallbacks.add proc() =
    # Ensure App is initialized
    if App == NIL or App.kind != VkApplication:
      return

    # Create Request class
    {.cast(gcsafe).}:
      request_class_global = new_class("Request")
      request_class_global.def_native_constructor(request_constructor)
      request_class_global.def_native_method("send", request_send)

    {.cast(gcsafe).}:
      server_request_class_global = new_class("ServerRequest")
      server_request_class_global.def_native_method("path", server_request_path)
      server_request_class_global.def_native_method("method", server_request_method)
      server_request_class_global.def_native_method("url", server_request_url)
      server_request_class_global.def_native_method("params", server_request_params)
      server_request_class_global.def_native_method("headers", server_request_headers)
      server_request_class_global.def_native_method("body", server_request_body)
      server_request_class_global.def_native_method("body_params", server_request_body_params)

    # Create Response class
    {.cast(gcsafe).}:
      response_class_global = new_class("Response")
      response_class_global.def_native_constructor(response_constructor)
      response_class_global.def_native_method("json", response_json)

    # Create ServerStream class
    {.cast(gcsafe).}:
      server_stream_class_global = new_class("ServerStream")
      server_stream_class_global.def_native_method("send", server_stream_send)
      server_stream_class_global.def_native_method("close", server_stream_close)

    # Create WsConnection class
    {.cast(gcsafe).}:
      ws_connection_class_global = new_class("WsConnection")
      ws_connection_class_global.def_native_method("send", ws_connection_send)
      ws_connection_class_global.def_native_method("recv", ws_connection_recv)
      ws_connection_class_global.def_native_method("close", ws_connection_close)

    # Store classes in gene namespace
    let request_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      request_class_ref.class = request_class_global
    let server_request_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      server_request_class_ref.class = server_request_class_global
    let response_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      response_class_ref.class = response_class_global
    let server_stream_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      server_stream_class_ref.class = server_stream_class_global
    let ws_connection_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      ws_connection_class_ref.class = ws_connection_class_global

    if App.app.gene_ns.kind == VkNamespace:
      App.app.gene_ns.ref.ns["Request".to_key()] = request_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["ServerRequest".to_key()] = server_request_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["Response".to_key()] = response_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["ServerStream".to_key()] = server_stream_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["WsConnection".to_key()] = ws_connection_class_ref.to_ref_value()

    # Add helper functions to global namespace
    let get_fn = new_ref(VkNativeFn)
    get_fn.native_fn = vm_http_get_helper
    App.app.global_ns.ref.ns["http_get".to_key()] = get_fn.to_ref_value()

    let post_fn = new_ref(VkNativeFn)
    post_fn.native_fn = vm_http_post_helper
    App.app.global_ns.ref.ns["http_post".to_key()] = post_fn.to_ref_value()

    # Add server functions to global namespace
    let start_server_fn = new_ref(VkNativeFn)
    start_server_fn.native_fn = vm_start_server
    App.app.global_ns.ref.ns["start_server".to_key()] = start_server_fn.to_ref_value()

    let respond_fn = new_ref(VkNativeFn)
    respond_fn.native_fn = vm_respond
    App.app.global_ns.ref.ns["respond".to_key()] = respond_fn.to_ref_value()

    let respond_sse_fn = new_ref(VkNativeFn)
    respond_sse_fn.native_fn = vm_respond_sse
    App.app.global_ns.ref.ns["respond_sse".to_key()] = respond_sse_fn.to_ref_value()

    let redirect_fn = new_ref(VkNativeFn)
    redirect_fn.native_fn = vm_redirect
    App.app.global_ns.ref.ns["redirect".to_key()] = redirect_fn.to_ref_value()

    # WebSocket client connect function
    let ws_connect_fn = new_ref(VkNativeFn)
    ws_connect_fn.native_fn = vm_ws_connect
    App.app.global_ns.ref.ns["ws_connect".to_key()] = ws_connect_fn.to_ref_value()

  # For dynamically loaded extensions, scheduler polling is bridged through
  # GeneHostAbi.register_scheduler_callback_fn in gene_init.

# Execute a Gene function in VM context
proc execute_gene_function(vm: ptr VirtualMachine, fn: Value, args: seq[Value]): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    case fn.kind:
    of VkNativeFn:
      return call_native_fn(fn.ref.native_fn, vm, args)
    of VkFunction:
      # Execute Gene function using the VM's exec_function method
      let result = vm.exec_function(fn, args)
      return result
    of VkClass:
      # If it's a class, try to call its `call` method
      if fn.ref.class.methods.contains("call".to_key()):
        let call_method = fn.ref.class.methods["call".to_key()].callable
        return execute_gene_function(vm, call_method, args)
      else:
        return NIL
    of VkInstance:
      # If it's an instance, try to call its `call` method
      let inst_class = instance_class(fn)
      if inst_class.methods.contains("call".to_key()):
        let call_method = inst_class.methods["call".to_key()].callable
        # Use exec_method to properly set up the scope with self bound
        # fn is the instance, args are the additional arguments
        let result = vm.exec_method(call_method, fn, args)
        return result
      else:
        return NIL
    else:
      return NIL

# Actor port handler for concurrent HTTP request execution
proc http_actor_handle_request(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if get_positional_count(arg_count, has_keyword_args) < 2:
      raise new_exception(types.Exception, "http_actor_handle_request requires context and request data")

    let ctx = get_positional_arg(args, 0, has_keyword_args)
    let req_data = get_positional_arg(args, 1, has_keyword_args)
    let state = get_positional_arg(args, 2, has_keyword_args)

    # Convert literal map back to ServerRequest instance
    let request = literal_to_server_request(req_data)

    try:
      let result = execute_gene_function(vm, gene_handler_global, @[request])
      let literal_result = response_to_literal(result)
      if not is_literal_value(literal_result):
        actor_reply_for_test(ctx, literal_error_response("Internal Server Error: response is not literal"))
      else:
        actor_reply_for_test(ctx, literal_result)
    except CatchableError as e:
      http_log(LlError, "Actor handler error: " & e.msg)
      actor_reply_for_test(ctx, literal_error_response("Internal Server Error: " & e.msg))
    state

# HTTP Server implementation
proc create_server_request(req: asynchttpserver.Request): Value =
  # Create ServerRequest instance
  let request_cls = block:
    {.cast(gcsafe).}:
      server_request_class_global
  let instance = new_instance_value(request_cls)

  # Set properties
  instance_props(instance)["method".to_key()] = ($req.reqMethod).to_value()
  instance_props(instance)["url".to_key()] = req.url.path.to_value()
  instance_props(instance)["path".to_key()] = req.url.path.to_value()

  # Parse query parameters
  let params_map = new_map_value()
  if req.url.query != "":
    for key, val in decodeData(req.url.query):
      map_data(params_map)[key.to_key()] = val.to_value()
  instance_props(instance)["params".to_key()] = params_map

  # Convert headers to Gene map
  let headers_map = new_map_value()
  for k, v in req.headers.table:
    if v.len == 1:
      map_data(headers_map)[k.to_key()] = v[0].to_value()
    else:
      let values = new_array_value()
      for item in v:
        array_data(values).add(item.to_value())
      map_data(headers_map)[k.to_key()] = values
  instance_props(instance)["headers".to_key()] = headers_map

  # Store body if present
  let body_content = req.body
  instance_props(instance)["body".to_key()] = body_content.to_value()

  # Store native client pointer for streaming responses (non-concurrent mode only)
  instance_props(instance)["__native_client".to_key()] = cast[pointer](req.client).to_value()

  var content_type = ""
  if req.headers.hasKey("Content-Type"):
    content_type = req.headers["Content-Type"]
  instance_props(instance)["body_params".to_key()] = parse_body_params(body_content, content_type)

  return instance

# Convert ServerRequest instance to a literal map for thread-safe spawning
proc server_request_to_literal(req: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let result = new_map_value()
    map_data(result) = Table[Key, Value]()

    # Copy all properties from instance to map
    for key in ["method", "path", "url", "body"]:
      let k = key.to_key()
      let val = instance_props(req).getOrDefault(k, NIL)
      map_data(result)[k] = val

    # Handle nested maps (params, headers, body_params) - need deep copy for thread safety
    for key in ["params", "headers", "body_params"]:
      let k = key.to_key()
      let val = instance_props(req).getOrDefault(k, NIL)
      if val.kind == VkMap:
        # Create a new map with the same contents
        let new_map = new_map_value()
        map_data(new_map) = Table[Key, Value]()
        for mk, mv in map_data(val):
          map_data(new_map)[mk] = mv
        map_data(result)[k] = new_map
      else:
        map_data(result)[k] = val

    return result

# Convert literal map back to ServerRequest instance (inverse of server_request_to_literal)
proc literal_to_server_request(req_map: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # Create a new ServerRequest instance
    let request_cls = block:
      {.cast(gcsafe).}:
        (if server_request_class_global != nil: server_request_class_global else: new_class("ServerRequest"))
    let instance = new_instance_value(request_cls)

    # Copy all properties from map to instance
    if req_map.kind == VkMap:
      for k, v in map_data(req_map):
        instance_props(instance)[k] = v

    return instance

# Convert response to a literal map for thread-safe transfer back from worker
proc response_to_literal(resp: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # If already a map, deep copy it for thread safety
    if resp.kind == VkMap:
      let result = new_map_value()
      map_data(result) = Table[Key, Value]()

      # Copy basic properties (status, body)
      for key in ["status", "body"]:
        let k = key.to_key()
        let val = map_data(resp).getOrDefault(k, NIL)
        # Deep copy strings to avoid sharing mutable data
        if val.kind == VkString:
          map_data(result)[k] = new_str_value(val.str)
        else:
          map_data(result)[k] = val

      # Deep copy headers map if present
      let headers_key = "headers".to_key()
      let headers_val = map_data(resp).getOrDefault(headers_key, NIL)
      if headers_val.kind == VkMap:
        let new_headers = new_map_value()
        map_data(new_headers) = Table[Key, Value]()
        for mk, mv in map_data(headers_val):
          if mv.kind == VkString:
            map_data(new_headers)[mk] = new_str_value(mv.str)
          else:
            map_data(new_headers)[mk] = mv
        map_data(result)[headers_key] = new_headers
      else:
        let empty_headers = new_map_value()
        map_data(empty_headers) = Table[Key, Value]()
        map_data(result)[headers_key] = empty_headers

      return result

    # If it's a ServerResponse instance, convert to map
    elif resp.kind == VkInstance:
      if server_stream_class_global != nil and instance_class(resp) == server_stream_class_global:
        return literal_error_response("ServerStream responses are not supported in concurrent mode")
      let result = new_map_value()
      map_data(result) = Table[Key, Value]()

      for key in ["status", "body"]:
        let k = key.to_key()
        let val = instance_props(resp).getOrDefault(k, NIL)
        if val.kind == VkString:
          map_data(result)[k] = new_str_value(val.str)
        else:
          map_data(result)[k] = val

      let headers_key = "headers".to_key()
      let headers_val = instance_props(resp).getOrDefault(headers_key, NIL)
      if headers_val.kind == VkMap:
        let new_headers = new_map_value()
        map_data(new_headers) = Table[Key, Value]()
        for mk, mv in map_data(headers_val):
          if mv.kind == VkString:
            map_data(new_headers)[mk] = new_str_value(mv.str)
          else:
            map_data(new_headers)[mk] = mv
        map_data(result)[headers_key] = new_headers
      else:
        let empty_headers = new_map_value()
        map_data(empty_headers) = Table[Key, Value]()
        map_data(result)[headers_key] = empty_headers

      return result

    # If it's a string, wrap it in a response map
    elif resp.kind == VkString:
      let result = new_map_value()
      map_data(result) = Table[Key, Value]()
      map_data(result)["status".to_key()] = 200.to_value()
      map_data(result)["body".to_key()] = new_str_value(resp.str)
      let empty_headers = new_map_value()
      map_data(empty_headers) = Table[Key, Value]()
      map_data(result)["headers".to_key()] = empty_headers
      return result

    # Default: return as-is (primitives like int/bool are safe)
    else:
      return resp

# Create a literal error response map for worker-safe replies
proc literal_error_response(message: string): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let result = new_map_value()
    map_data(result) = Table[Key, Value]()
    map_data(result)["status".to_key()] = 500.to_value()
    map_data(result)["body".to_key()] = message.to_value()
    let headers = new_map_value()
    map_data(headers) = Table[Key, Value]()
    map_data(result)["headers".to_key()] = headers
    return result

# Convert literal map response back to ServerResponse instance
proc literal_to_server_response(data: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let response_cls = (if server_response_class_global != nil: server_response_class_global else: new_class("ServerResponse"))
    let instance = new_instance_value(response_cls)

    if data.kind == VkMap:
      instance_props(instance)["status".to_key()] =
        map_data(data).getOrDefault("status".to_key(), 200.to_value())
      instance_props(instance)["body".to_key()] =
        map_data(data).getOrDefault("body".to_key(), "".to_value())
      instance_props(instance)["headers".to_key()] =
        map_data(data).getOrDefault("headers".to_key(), new_map_value())
    else:
      # If it's not a map, treat the whole value as the body
      instance_props(instance)["status".to_key()] = 200.to_value()
      if data.kind == VkString:
        instance_props(instance)["body".to_key()] = data
      else:
        instance_props(instance)["body".to_key()] = ($data).to_value()
      instance_props(instance)["headers".to_key()] = new_map_value()

    return instance

proc handle_request(req: asynchttpserver.Request) {.async, gcsafe.} =
  # Initial yield to allow other connections to be accepted
  await sleepAsync(1)

  {.cast(gcsafe).}:
    # --- WebSocket upgrade detection ---
    let is_ws_upgrade = req.headers.hasKey("Upgrade") and
                        req.headers["Upgrade"].toLowerAscii() == "websocket"

    if is_ws_upgrade and ws_handler_global.kind != VkNil:
      # Check path if one was configured
      let path_ok = ws_path_global.len == 0 or req.url.path == ws_path_global
      if path_ok:
        try:
          let ws = await ws_module.ws_accept(req.client, req.headers)
          let ws_instance = new_ws_connection_instance(ws)
          # Call the Gene WebSocket handler with the connection
          discard execute_gene_function(gene_vm_global, ws_handler_global, @[ws_instance])
        except CatchableError as e:
          http_log(LlError, "WebSocket upgrade error: " & e.msg)
        return
      else:
        # Path doesn't match — fall through to normal request handling
        discard

    # Convert async request to Gene request
    let gene_req = create_server_request(req)

    # Call the handler
    var response: Value = NIL

    # If we have a native handler, call it directly
    if server_handler != nil:
      try:
        response = server_handler(gene_req)
      except CatchableError as e:
        # Return 500 error on exception
        await req.respond(Http500, "Internal Server Error: " & e.msg)
        return
    # If we have a Gene function handler, add to pending requests
    elif gene_handler_global.kind != VkNil:
      # SSE handlers need the live socket/client pointer from the original
      # request object, which is not available in worker-thread literal dispatch.
      let accepts_sse = req.headers.hasKey("Accept") and req.headers["Accept"].toLowerAscii().contains("text/event-stream")
      let is_stream_path = req.url.path.toLowerAscii().endsWith("/stream")
      let needs_main_thread = accepts_sse or is_stream_path

      if concurrent_mode and http_request_ports.kind == VkArray and not needs_main_thread:
        # CONCURRENT MODE: dispatch request execution through actor-backed ports.
        let req_literal = server_request_to_literal(gene_req)

        # Dispatch to actor-backed worker and await the attached Nim future.
        var future: Value
        try:
          future = dispatch_to_http_actor(gene_vm_global, req_literal)
        except CatchableError as e:
          await req.respond(Http500, "Concurrent dispatch error: " & e.msg)
          return

        try:
          let nim_fut = future.ref.future.nim_future
          if nim_fut.isNil:
            raise new_exception(types.Exception, "Actor reply future is missing async bridge state")

          await sleepAsync(1)
          response = await nim_fut

          # Convert literal response map to instance if needed
          if response.kind == VkMap:
            response = literal_to_server_response(response)
        except CatchableError as e:
          http_log(LlError, "Concurrent actor error: " & e.msg)
          await req.respond(Http500, "Concurrent actor error: " & e.msg)
          return
      else:
        # NON-CONCURRENT MODE: execute the Gene handler inline.
        # This keeps request handling functional even when extension-local
        # scheduler callbacks are not wired into the host scheduler.
        try:
          response = execute_gene_function(gene_vm_global, gene_handler_global, @[gene_req])
        except CatchableError as e:
          await req.respond(Http500, "Internal Server Error: " & e.msg)
          return

    # Handle the response
    if response == NIL:
      # No response, return 404
      await req.respond(Http404, "Not Found")
    elif response.kind == VkString:
      await req.respond(Http200, response.str)
    elif response.kind == VkInstance:
      # If it's a ServerStream, streaming already handled
      if server_stream_class_global != nil and instance_class(response) == server_stream_class_global:
        return
      # Check if it's a ServerResponse
      let status_val = instance_props(response).getOrDefault("status".to_key(), 200.to_value())
      let body_val = instance_props(response).getOrDefault("body".to_key(), "".to_value())
      let headers_val = instance_props(response).getOrDefault("headers".to_key(), NIL)

      let status_code = if status_val.kind == VkInt:
        HttpCode(status_val.int64.int)
      else:
        Http200

      let body = if body_val.kind == VkString: body_val.str else: $body_val

      # Prepare headers
      var headers = newHttpHeaders()
      if headers_val.kind == VkMap:
        for k, v in map_data(headers_val):
          let header_name = cast[Value](k).str
          case v.kind
          of VkString:
            headers[header_name] = v.str
          of VkArray:
            var values: seq[string] = @[]
            for item in array_data(v):
              case item.kind
              of VkString, VkSymbol:
                values.add(item.str)
              else:
                values.add($item)
            if values.len > 0:
              headers[header_name] = values
          else:
            headers[header_name] = $v

      await req.respond(status_code, body, headers)
    else:
      # Unknown response type
      await req.respond(Http500, "Invalid response type: " & $response.kind)

# Start HTTP server
proc vm_start_server(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "start_server requires at least a port")

  let port_val = get_positional_arg(args, 0, has_keyword_args)
  let handler = if get_positional_count(arg_count, has_keyword_args) > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL

  let port = if port_val.kind == VkInt: port_val.int64.int else: 8080

  # Check for ^websocket keyword arg: {^path "/ws" ^handler ws_handler}
  {.cast(gcsafe).}:
    let ws_val = if has_keyword_args: get_keyword_arg(args, "websocket") else: NIL
    if ws_val.kind == VkMap:
      ws_path_global = ""
      ws_handler_global = NIL
      let path_val = map_data(ws_val).getOrDefault("path".to_key(), NIL)
      if path_val.kind == VkString:
        ws_path_global = path_val.str
      let handler_val = map_data(ws_val).getOrDefault("handler".to_key(), NIL)
      if handler_val.kind != VkNil:
        ws_handler_global = handler_val

  # Check for ^concurrent option and ^workers count
  {.cast(gcsafe).}:
    let concurrent_val = if has_keyword_args: get_keyword_arg(args, "concurrent") else: NIL
    concurrent_mode = concurrent_val != NIL and concurrent_val.to_bool()

    if concurrent_mode:
      # Get worker count (default to 4)
      let workers_val = if has_keyword_args: get_keyword_arg(args, "workers") else: NIL
      let worker_count = if workers_val.kind == VkInt: workers_val.int64.int else: 4

      http_log(LlDebug, "Concurrent mode enabled with " & $worker_count & " actor-backed HTTP workers")
      discard ensure_http_request_ports(worker_count)

  # Store the handler
  {.cast(gcsafe).}:
    # Store VM reference and handler for direct execution / actor-backed dispatch.
    gene_vm_global = vm
    gene_handler_global = handler

    # Check handler type and set up appropriate handler
    case handler.kind:
    of VkNativeFn:
      # Native function - can be called directly
      let stored_vm = vm
      let stored_handler = handler

      server_handler = proc(req: Value): Value {.gcsafe.} =
        return call_native_fn(stored_handler.ref.native_fn, stored_vm, [req])
    of VkFunction, VkClass, VkInstance:
      # Gene function/class/instance - use queue system
      server_handler = nil  # Don't use native handler, will use queue
    of VkNil:
      # No handler
      server_handler = nil
    else:
      # Other handler types - use queue system
      server_handler = nil

  # Create and start server
  {.cast(gcsafe).}:
    http_server = newAsyncHttpServer()
    asyncCheck http_server.serve(Port(port), handle_request)
    # Give the event loop time to bind the server socket
    try:
      poll(100)  # Wait up to 100ms for server to bind
    except ValueError:
      discard

  http_log(LlDebug, "HTTP server started on port " & $port)
  return NIL

# Create a response
proc vm_respond(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "respond requires at least status or body")

  var status = 200
  var body = ""
  var headers = new_map_value()

  # Parse arguments
  if arg_count == 1:
    let arg = get_positional_arg(args, 0, has_keyword_args)
    if arg.kind == VkInt:
      # Just status code
      status = arg.int64.int
    elif arg.kind == VkString:
      # Just body (200 OK)
      body = arg.str
      status = 200
    else:
      body = $arg
  elif arg_count >= 2:
    # Status and body
    let status_arg = get_positional_arg(args, 0, has_keyword_args)
    if status_arg.kind == VkInt:
      status = status_arg.int64.int
    let body_arg = get_positional_arg(args, 1, has_keyword_args)
    if body_arg.kind == VkString:
      body = body_arg.str
    else:
      body = $body_arg

    # Optional headers
  if arg_count > 2:
    let headers_arg = get_positional_arg(args, 2, has_keyword_args)
    if headers_arg.kind == VkMap:
      headers = headers_arg

  # Create ServerResponse instance
  let instance_class = block:
    {.cast(gcsafe).}:
      (if server_response_class_global != nil: server_response_class_global else: new_class("ServerResponse"))
  let instance = new_instance_value(instance_class)

  instance_props(instance)["status".to_key()] = status.to_value()
  instance_props(instance)["body".to_key()] = body.to_value()
  instance_props(instance)["headers".to_key()] = headers

  return instance

proc server_stream_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    raise new_exception(types.Exception, "ServerStream.send requires data")

  let stream_obj = get_positional_arg(args, 0, has_keyword_args)
  if stream_obj.kind != VkInstance:
    raise new_exception(types.Exception, "ServerStream.send must be called on a ServerStream instance")

  let data_val = get_positional_arg(args, 1, has_keyword_args)
  let payload = if data_val.kind == VkString: data_val.str else: $data_val

  let closed_val = instance_props(stream_obj).getOrDefault("closed".to_key(), FALSE)
  if closed_val == TRUE:
    return FALSE

  let req_ptr_val = instance_props(stream_obj).getOrDefault("__native_client".to_key(), NIL)
  if req_ptr_val.kind != VkPointer:
    return FALSE

  let client = cast[AsyncSocket](req_ptr_val.to_pointer())
  try:
    send_chunk(client, payload)
    return TRUE
  except CatchableError:
    instance_props(stream_obj)["closed".to_key()] = TRUE
    return FALSE

proc server_stream_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "ServerStream.close requires self")

  let stream_obj = get_positional_arg(args, 0, has_keyword_args)
  if stream_obj.kind != VkInstance:
    raise new_exception(types.Exception, "ServerStream.close must be called on a ServerStream instance")

  let closed_val = instance_props(stream_obj).getOrDefault("closed".to_key(), FALSE)
  if closed_val == TRUE:
    return NIL

  let req_ptr_val = instance_props(stream_obj).getOrDefault("__native_client".to_key(), NIL)
  if req_ptr_val.kind == VkPointer:
    let client = cast[AsyncSocket](req_ptr_val.to_pointer())
    try:
      waitFor client.send("0\c\L\c\L")
    except CatchableError:
      discard
    try:
      client.close()
    except CatchableError:
      discard

  instance_props(stream_obj)["closed".to_key()] = TRUE
  return NIL

proc vm_respond_sse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "respond_sse requires a request argument")

  let req_val = get_positional_arg(args, 0, has_keyword_args)
  let headers_val =
    if get_positional_count(arg_count, has_keyword_args) > 1:
      get_positional_arg(args, 1, has_keyword_args)
    else:
      NIL

  let client = get_native_client(req_val)
  var headers = headers_from_map(headers_val)
  apply_default_sse_headers(headers)

  try:
    send_status_and_headers(client, "200 OK", headers)
  except CatchableError as e:
    raise new_exception(types.Exception, "Failed to start SSE: " & e.msg)

  let stream_class = block:
    {.cast(gcsafe).}:
      (if server_stream_class_global != nil: server_stream_class_global else: new_class("ServerStream"))
  let stream_instance = new_instance_value(stream_class)
  instance_props(stream_instance)["__native_client".to_key()] =
    instance_props(req_val).getOrDefault("__native_client".to_key(), NIL)
  instance_props(stream_instance)["closed".to_key()] = FALSE
  return stream_instance

proc vm_redirect(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "redirect requires a destination URL")

  let location_arg = get_positional_arg(args, 0, has_keyword_args)
  if location_arg.kind != VkString:
    raise new_exception(types.Exception, "redirect destination must be a string")

  var status = 302
  if get_positional_count(arg_count, has_keyword_args) > 1:
    let status_arg = get_positional_arg(args, 1, has_keyword_args)
    if status_arg.kind == VkInt:
      status = status_arg.int64.int
    else:
      raise new_exception(types.Exception, "redirect status must be an integer")

  let headers = new_map_value()
  map_data(headers)["Location".to_key()] = location_arg.str.to_value()

  let redirect_class = block:
    {.cast(gcsafe).}:
      (if server_response_class_global != nil: server_response_class_global else: new_class("ServerResponse"))
  let instance = new_instance_value(redirect_class)

  instance_props(instance)["status".to_key()] = status.to_value()
  instance_props(instance)["body".to_key()] = "".to_value()
  instance_props(instance)["headers".to_key()] = headers

  return instance

# ============ WebSocket Connection Methods ============

proc get_ws_handle(instance: Value): ws_module.WebSocket =
  ## Extract the Nim WebSocket from a WsConnection instance.
  let ptr_val = instance_props(instance).getOrDefault("__ws_handle".to_key(), NIL)
  if ptr_val.kind != VkPointer:
    raise new_exception(types.Exception, "WsConnection has no active handle")
  cast[ws_module.WebSocket](ptr_val.to_pointer())

proc new_ws_connection_instance(ws: ws_module.WebSocket): Value {.gcsafe.} =
  ## Create a Gene WsConnection instance wrapping a Nim WebSocket.
  {.cast(gcsafe).}:
    let cls = if ws_connection_class_global != nil: ws_connection_class_global else: new_class("WsConnection")
    let instance = new_instance_value(cls)
    # Store the WebSocket ref as a pointer — prevent GC collection via GC_ref
    GC_ref(ws)
    instance_props(instance)["__ws_handle".to_key()] = cast[pointer](ws).to_value()
    instance_props(instance)["closed".to_key()] = FALSE
    return instance

proc ws_connection_send(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  ## WsConnection .send(text)
  if get_positional_count(arg_count, has_keyword_args) < 2:
    raise new_exception(types.Exception, "WsConnection.send requires data")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "WsConnection.send must be called on a WsConnection instance")

  let data_val = get_positional_arg(args, 1, has_keyword_args)
  let payload = case data_val.kind
    of VkString: data_val.str
    of VkMap, VkArray: $data_val
    else: $data_val

  let closed_val = instance_props(self).getOrDefault("closed".to_key(), FALSE)
  if closed_val == TRUE:
    return FALSE

  let ws = get_ws_handle(self)
  try:
    waitFor ws_module.ws_send(ws, payload)
    return TRUE
  except CatchableError:
    instance_props(self)["closed".to_key()] = TRUE
    return FALSE

proc ws_connection_recv(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  ## WsConnection .recv() — returns a Future that resolves to the next message string.
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "WsConnection.recv requires self")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "WsConnection.recv must be called on a WsConnection instance")

  let closed_val = instance_props(self).getOrDefault("closed".to_key(), FALSE)
  if closed_val == TRUE:
    return NIL

  let ws = get_ws_handle(self)

  # Recv synchronously — waitFor drives the event loop properly for SSL
  var result_val: Value
  {.cast(gcsafe).}:
    try:
      let frame = waitFor ws_module.ws_recv(ws)
      if frame.opcode == ws_module.WsOpClose:
        instance_props(self)["closed".to_key()] = TRUE
        result_val = NIL
      else:
        result_val = frame.payload.to_value()
    except CatchableError:
      instance_props(self)["closed".to_key()] = TRUE
      result_val = NIL

  # Return as an already-completed Gene future (no Nim future needed).
  let future_obj = FutureObj(
    state: FsSuccess,
    value: result_val,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil,
  )

  let future_val = new_ref(VkFuture)
  future_val.future = future_obj
  return future_val.to_ref_value()

proc ws_connection_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  ## WsConnection .close()
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "WsConnection.close requires self")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "WsConnection.close must be called on a WsConnection instance")

  let closed_val = instance_props(self).getOrDefault("closed".to_key(), FALSE)
  if closed_val == TRUE:
    return NIL

  let ws = get_ws_handle(self)
  try:
    waitFor ws_module.ws_close(ws)
  except CatchableError:
    discard

  instance_props(self)["closed".to_key()] = TRUE
  GC_unref(ws)
  return NIL

proc vm_ws_connect(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  ## ws_connect(url) — returns a completed Future with a WsConnection instance.
  ## The connect is performed synchronously via waitFor so that the Nim event
  ## loop drives the TLS handshake directly (the VM's poll(0) loop cannot
  ## drive byte-level async recv on SSL sockets).
  if arg_count < 1:
    raise new_exception(types.Exception, "ws_connect requires a URL argument")

  let url_val = get_positional_arg(args, 0, has_keyword_args)
  if url_val.kind != VkString:
    raise new_exception(types.Exception, "ws_connect URL must be a string")

  let url = url_val.str

  # Connect synchronously — waitFor drives the event loop properly for SSL
  var ws: ws_module.WebSocket
  {.cast(gcsafe).}:
    try:
      ws = waitFor ws_module.ws_connect(url)
    except CatchableError as e:
      raise new_exception(types.Exception, "WebSocket connect failed: " & e.msg)

  let instance = new_ws_connection_instance(ws)

  # Return as an already-completed Gene future (no Nim future needed).
  let future_obj = FutureObj(
    state: FsSuccess,
    value: instance,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil,
  )

  let future_val = new_ref(VkFuture)
  future_val.future = future_obj
  return future_val.to_ref_value()

# Call init_http_classes to register the callback
init_http_classes()

{.pop.}

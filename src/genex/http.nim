{.push warning[IgnoredSymbolInjection]: off, warning[ResultShadowed]: off.}
import tables, strutils
import httpclient, uri
import std/json
import ../asynchttpserver
import asyncdispatch, asyncnet
import asyncfutures  # Import asyncfutures explicitly
import nativesockets, net
import cgi

include ../gene/extension/boilerplate
import ../gene/vm
import ../gene/vm/thread as gene_thread
import ../gene/serdes
import std/typedthreads
import std/atomics
import std/exitprocs
# Explicitly alias to use asyncfutures.Future in this module (preserve generic)
type
  Future[T] {.used.} = asyncfutures.Future[T]

# ============ Gene Thread Worker Pool for Concurrent HTTP ============

const MAX_HTTP_WORKERS = 8

# Gene thread-based worker pool
var http_gene_workers: array[MAX_HTTP_WORKERS, Value]  # Stores Gene thread references (VkThread)
var http_gene_worker_count: int = 0
var http_gene_workers_initialized: bool = false
var next_http_worker_idx: Atomic[int]  # Round-robin index (atomic for thread safety)

# Global variables to store classes
var request_class_global: Class
var response_class_global: Class
var server_request_class_global: Class

var server_response_class_global: Class
var server_stream_class_global: Class

# Concurrent mode flag
var concurrent_mode: bool = false

# Global HTTP server instance
var http_server: AsyncHttpServer
var server_handler: proc(req: Value): Value {.gcsafe.}
var stored_gene_handler: Value  # Store the Gene function/instance
var stored_vm: ptr VirtualMachine   # Store VM reference for execution

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
proc execute_gene_function(vm: ptr VirtualMachine, fn: Value, args: seq[Value]): Value {.gcsafe.}
proc process_pending_http_requests*(vm: ptr VirtualMachine) {.gcsafe.}
proc response_to_literal(resp: Value): Value {.gcsafe.}
proc literal_to_server_request(req_map: Value): Value {.gcsafe.}
proc literal_error_response(message: string): Value {.gcsafe.}
proc http_worker_handle_request(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.}

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
    return new_str_value(json_str)


proc init*(vm: ptr VirtualMachine): Namespace {.exportc, dynlib.} =
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

    if App.app.gene_ns.kind == VkNamespace:
      App.app.gene_ns.ref.ns["Request".to_key()] = request_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["ServerRequest".to_key()] = server_request_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["Response".to_key()] = response_class_ref.to_ref_value()
      App.app.gene_ns.ref.ns["ServerStream".to_key()] = server_stream_class_ref.to_ref_value()

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

    # Register HTTP worker handler for thread-based concurrent processing
    let worker_handler_fn = new_ref(VkNativeFn)
    worker_handler_fn.native_fn = http_worker_handle_request
    App.app.global_ns.ref.ns["http_worker_handle_request".to_key()] = worker_handler_fn.to_ref_value()
    # Worker thread execution frames resolve symbols from gene_ns by default,
    # so the handler must also be available there in concurrent mode.
    App.app.gene_ns.ref.ns["http_worker_handle_request".to_key()] = worker_handler_fn.to_ref_value()

  # Register HTTP poll handler with the scheduler (outside the VmCreatedCallback lambda)
  # This will be called by run_forever in the main scheduler loop
  register_scheduler_callback(process_pending_http_requests)

# Future-based handler execution system
import locks

type
  PendingHttpRequest = object
    request: Value              # The Gene request object
    nim_future: Future[Value]   # Nim future to complete with response
    processed: bool             # Whether handler has been executed

# Global storage for handler and VM reference
var gene_handler_global: Value = NIL
var gene_vm_global: ptr VirtualMachine = nil

# Pending HTTP requests awaiting handler execution
var pending_http_requests: seq[PendingHttpRequest]
var pending_lock: Lock
initLock(pending_lock)

# Process pending HTTP requests (called from VM's poll_event_loop via EventLoopCallbacks)
# This executes the Gene handler and completes the Nim future
proc process_pending_http_requests*(vm: ptr VirtualMachine) {.gcsafe.} =
  {.cast(gcsafe).}:
    if pending_http_requests.len == 0:
      return

    # Process queued requests sequentially to keep the event loop responsive.
    withLock(pending_lock):
      # Process only ONE request per callback to allow async event loop to breathe
      if pending_http_requests.len > 0:
        var req = addr pending_http_requests[0]
        if not req.processed:
          req.processed = true

          # Execute the handler
          var result: Value
          if gene_handler_global.kind != VkNil:
            try:
              result = execute_gene_function(vm, gene_handler_global, @[req.request])
            except CatchableError as e:
              let error_response = block:
                let instance_class = (if server_response_class_global != nil: server_response_class_global else: new_class("ServerResponse"))
                let instance = new_instance_value(instance_class)
                instance_props(instance)["status".to_key()] = 500.to_value()
                instance_props(instance)["body".to_key()] = ("Internal Server Error: " & e.msg).to_value()
                instance_props(instance)["headers".to_key()] = new_map_value()
                instance
              result = error_response
          else:
            result = NIL

          # Complete the Nim future
          req.nim_future.complete(result)

          # Remove from pending list
          pending_http_requests.delete(0)

# ============ Gene Thread Worker Implementation ============

# Background async poller that processes thread replies
# This runs continuously while HTTP server is active, processing thread messages
var http_poller_running: bool = false

proc start_http_thread_poller(vm: ptr VirtualMachine) {.async.} =
  {.cast(gcsafe).}:
    if http_poller_running:
      return  # Already running

    if vm == nil:
      echo "Error: Cannot start HTTP poller with nil VM"
      return

    http_poller_running = true
    while http_gene_workers_initialized:
      # Poll for thread messages every 1ms
      if vm != nil:
        try:
          vm.poll_event_loop()
        except CatchableError as e:
          echo "Error in poll_event_loop: ", e.msg
      await sleepAsync(1)

    http_poller_running = false

# Initialize Gene thread workers
# Spawns Gene threads that listen for requests via on_message
proc init_http_gene_workers(count: int, vm: ptr VirtualMachine) =
  {.cast(gcsafe).}:
    if http_gene_workers_initialized:
      return

    let requested_count = min(count, MAX_HTTP_WORKERS)
    when not defined(release):
      echo "Initializing ", requested_count, " Gene HTTP worker threads..."

    var actual_count = 0
    for i in 0..<requested_count:
      # Get a free thread from the Gene thread pool
      let thread_id = gene_thread.get_free_thread()
      if thread_id == -1:
        echo "Warning: Could not allocate Gene thread for HTTP worker ", i
        continue

      # Initialize the thread
      let parent_id = current_thread_id
      gene_thread.init_thread(thread_id, parent_id)

      # Create the worker thread
      createThread(gene_thread.THREAD_DATA[thread_id].thread, thread_handler, thread_id)

      # Store the thread reference in sequential slots (no gaps)
      let thread_ref = types.Thread(
        id: thread_id,
        secret: THREADS[thread_id].secret
      )
      http_gene_workers[actual_count] = thread_ref.to_value()
      actual_count += 1

    # Track actual number of successfully initialized workers
    http_gene_worker_count = actual_count

    if actual_count == 0:
      echo "Error: No HTTP worker threads could be initialized"
      return

    http_gene_workers_initialized = true
    next_http_worker_idx.store(0)
    when not defined(release):
      echo "Gene HTTP worker threads initialized: ", actual_count, " of ", requested_count, " requested"

    # Start background poller to process thread replies
    asyncCheck start_http_thread_poller(vm)

    # Give the poller a chance to start running before any requests arrive
    try:
      poll(10)
    except ValueError:
      discard

# Shutdown Gene thread workers
proc shutdown_http_gene_workers() =
  {.cast(gcsafe).}:
    if not http_gene_workers_initialized:
      return

    when not defined(release):
      echo "Shutting down Gene HTTP worker threads..."
    for i in 0..<http_gene_worker_count:
      let worker = http_gene_workers[i]
      if worker.kind == VkThread:
        let thread_id = worker.ref.thread.id
        # Send termination message
        var term: types.ThreadMessage
        new(term)
        term.id = gene_thread.next_message_id
        term.msg_type = MtTerminate
        term.payload = NIL
        term.payload_bytes = types.ThreadPayload(bytes: @[])
        term.from_thread_id = current_thread_id
        term.from_thread_secret = THREADS[current_thread_id].secret
        gene_thread.next_message_id += 1
        gene_thread.THREAD_DATA[thread_id].channel.send(term)

        # Join thread and cleanup
        joinThread(gene_thread.THREAD_DATA[thread_id].thread)
        gene_thread.cleanup_thread(thread_id)
        http_gene_workers[i] = NIL

    http_gene_workers_initialized = false
    when not defined(release):
      echo "Gene HTTP worker threads shutdown complete"

# Dispatch a request to a Gene worker thread using send_expect_reply
# Returns a future that will be completed with the response
proc dispatch_to_gene_worker(vm: ptr VirtualMachine, request_data: Value): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # Round-robin dispatch (atomic fetch-and-increment for thread safety)
    let raw_idx = next_http_worker_idx.fetchAdd(1)
    let worker_idx = raw_idx mod http_gene_worker_count

    let worker = http_gene_workers[worker_idx]
    if worker.kind != VkThread:
      raise new_exception(types.Exception, "HTTP worker " & $worker_idx & " is not a valid thread")

    let thread_id = worker.ref.thread.id
    let thread_secret = worker.ref.thread.secret

    # Validate thread is still alive
    if not THREADS[thread_id].in_use or THREADS[thread_id].secret != thread_secret:
      raise new_exception(types.Exception, "HTTP worker " & $worker_idx & " is no longer valid")

    # Create Gene AST code to execute: (http_worker_handle_request <serialized_request>)
    # The request data is embedded directly in the Gene AST as a literal
    let handler_code = new_gene("http_worker_handle_request".to_symbol_value())
    handler_code.children.add(request_data)  # Request data will be serialized when compiling

    # Create message with MtRunExpectReply - worker will compile and execute the code
    var msg: types.ThreadMessage
    new(msg)
    msg.id = gene_thread.next_message_id
    msg.msg_type = MtRunExpectReply  # Run code and expect reply
    msg.payload = NIL
    msg.payload_bytes = types.ThreadPayload(bytes: @[])  # No payload bytes needed
    msg.code = handler_code.to_gene_value()  # Send the Gene AST to execute
    msg.from_thread_id = current_thread_id
    msg.from_thread_secret = THREADS[current_thread_id].secret
    let message_id = gene_thread.next_message_id
    gene_thread.next_message_id += 1

    # Send message to worker thread
    gene_thread.THREAD_DATA[thread_id].channel.send(msg)

    # Create a Nim async future for non-blocking await
    let nim_fut = newFuture[Value]("http_gene_worker")

    # Create a Gene future for the reply with attached Nim future
    let future_obj = FutureObj(
      state: FsPending,
      value: NIL,
      success_callbacks: @[],
      failure_callbacks: @[],
      nim_future: nim_fut
    )

    # Store future in VM's thread_futures table keyed by message ID
    vm.thread_futures[message_id] = future_obj
    vm.poll_enabled = true

    # Return the future
    let future_val = new_ref(VkFuture)
    future_val.future = future_obj
    return future_val.to_ref_value()

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

# Native function for HTTP worker threads to call the Gene handler
# This is registered globally and called via MtRunExpectReply from dispatch_to_gene_worker
proc http_worker_handle_request(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      raise new_exception(types.Exception, "http_worker_handle_request requires request data")

    let req_data = get_positional_arg(args, 0, has_keyword_args)

    # Convert literal map back to ServerRequest instance
    let request = literal_to_server_request(req_data)

    try:
      let result = execute_gene_function(vm, gene_handler_global, @[request])
      let literal_result = response_to_literal(result)
      if not is_literal_value(literal_result):
        return literal_error_response("Internal Server Error: response is not literal")
      return literal_result
    except CatchableError as e:
      when not defined(release):
        echo "Worker handler error: ", e.msg
      return literal_error_response("Internal Server Error: " & e.msg)

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

      if concurrent_mode and http_gene_workers_initialized and not needs_main_thread:
        # CONCURRENT MODE: Dispatch to Gene worker thread for parallel processing
        let req_literal = server_request_to_literal(gene_req)

        # Dispatch to Gene worker - returns a future with attached Nim future
        var future: Value
        try:
          future = dispatch_to_gene_worker(gene_vm_global, req_literal)
        except CatchableError as e:
          await req.respond(Http500, "Worker dispatch error: " & e.msg)
          return

        # Await the Nim future directly - non-blocking!
        # The future will be completed when poll_event_loop processes the thread reply
        try:
          # Get the attached Nim future and await it
          let nim_fut = future.ref.future.nim_future

          # Yield to event loop first to allow other requests to be accepted
          await sleepAsync(1)

          response = await nim_fut

          # Convert literal response map to instance if needed
          if response.kind == VkMap:
            response = literal_to_server_response(response)
        except CatchableError as e:
          # Future was rejected
          when not defined(release):
            echo "Worker error: ", e.msg
          await req.respond(Http500, "Worker error: " & e.msg)
          return
      else:
        # NON-CONCURRENT MODE: Queue for main thread processing
        # Create a Nim future to await the response
        let nim_future = newFuture[Value]("http_handler")

        # Add to pending requests list
        let pending_req = PendingHttpRequest(
          request: gene_req,
          nim_future: nim_future,
          processed: false
        )

        withLock(pending_lock):
          pending_http_requests.add(pending_req)

        # Await the Nim future (will be completed when process_pending_http_requests runs)
        try:
          response = await nim_future
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

  # Check for ^concurrent option and ^workers count
  {.cast(gcsafe).}:
    let concurrent_val = if has_keyword_args: get_keyword_arg(args, "concurrent") else: NIL
    concurrent_mode = concurrent_val != NIL and concurrent_val.to_bool()

    if concurrent_mode:
      # Get worker count (default to 4)
      let workers_val = if has_keyword_args: get_keyword_arg(args, "workers") else: NIL
      let worker_count = if workers_val.kind == VkInt: workers_val.int64.int else: 4

      when not defined(release):
        echo "Concurrent mode enabled with ", worker_count, " Gene worker threads"
      init_http_gene_workers(worker_count, vm)

  # Store the handler
  {.cast(gcsafe).}:
    # Store VM reference and handler globally for queue-based execution
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

  echo "HTTP server started on port ", port
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

# Call init_http_classes to register the callback
init_http_classes()

# Register shutdown hook to clean up worker threads on program exit
exitprocs.addExitProc(proc() =
  shutdown_http_gene_workers()
)

{.pop.}

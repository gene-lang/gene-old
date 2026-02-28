import std/json
import std/tables
import std/strutils
import std/times
import std/os
import std/osproc
import std/streams
import std/httpclient
import std/algorithm

const
  ToolCodeNotFound* = "TOOL_NOT_FOUND"
  ToolCodeDenied* = "TOOL_DENIED"
  ToolCodeExecFailed* = "TOOL_EXEC_FAILED"


type
  ToolContext* = object
    run_id*: string
    workspace_id*: string
    user_id*: string

  ToolPolicyDecision* = object
    allowed*: bool
    reason*: string

  ToolExecutor* = proc(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.}
  ToolPolicy* = proc(ctx: ToolContext; tool_name: string; args: JsonNode): ToolPolicyDecision {.gcsafe.}

  ToolAuditEvent* = object
    timestamp_ms*: int64
    run_id*: string
    workspace_id*: string
    user_id*: string
    tool_name*: string
    status*: string
    reason*: string
    duration_ms*: int64
    args_json*: JsonNode
    result_json*: JsonNode

  ToolAuditSink* = proc(event: ToolAuditEvent) {.gcsafe.}

  ToolDef* = object
    name*: string
    description*: string
    config*: JsonNode
    executor*: ToolExecutor

  ToolRegistry* = ref object
    tools*: Table[string, ToolDef]
    policy*: ToolPolicy
    audit_sink*: ToolAuditSink
    audit_events*: seq[ToolAuditEvent]


proc now_unix_ms(): int64 {.inline.} =
  (epochTime() * 1000).int64

proc new_tool_context*(run_id = ""; workspace_id = ""; user_id = ""): ToolContext =
  ToolContext(run_id: run_id, workspace_id: workspace_id, user_id: user_id)

proc allow_decision*(reason = ""): ToolPolicyDecision =
  ToolPolicyDecision(allowed: true, reason: reason)

proc deny_decision*(reason: string): ToolPolicyDecision =
  ToolPolicyDecision(allowed: false, reason: reason)

proc default_policy*(ctx: ToolContext; tool_name: string; args: JsonNode): ToolPolicyDecision {.gcsafe.} =
  discard ctx
  discard tool_name
  discard args
  allow_decision()

proc new_tool_registry*(): ToolRegistry =
  ToolRegistry(
    tools: initTable[string, ToolDef](),
    policy: default_policy,
    audit_events: @[]
  )

proc set_tool_policy*(registry: ToolRegistry; policy: ToolPolicy) =
  if registry.isNil:
    return
  registry.policy = if policy == nil: default_policy else: policy

proc set_tool_audit_sink*(registry: ToolRegistry; sink: ToolAuditSink) =
  if registry.isNil:
    return
  registry.audit_sink = sink

proc normalize_tool_name(name: string): string {.inline.} =
  name.strip().toLowerAscii()

proc register_tool*(registry: ToolRegistry; tool: ToolDef) =
  if registry.isNil:
    raise newException(ValueError, "Tool registry is nil")
  let key = normalize_tool_name(tool.name)
  if key.len == 0:
    raise newException(ValueError, "Tool name cannot be empty")
  if tool.executor == nil:
    raise newException(ValueError, "Tool executor cannot be nil")
  var normalized = tool
  normalized.name = key
  if normalized.config.isNil:
    normalized.config = newJObject()
  registry.tools[key] = normalized

proc list_tools*(registry: ToolRegistry): seq[string] =
  if registry.isNil:
    return @[]
  for name in registry.tools.keys:
    result.add(name)
  result.sort(system.cmp[string])

proc has_tool*(registry: ToolRegistry; name: string): bool =
  if registry.isNil:
    return false
  registry.tools.hasKey(normalize_tool_name(name))

proc emit_audit(registry: ToolRegistry; event: ToolAuditEvent) =
  if registry.isNil:
    return
  registry.audit_events.add(event)
  if registry.audit_sink != nil:
    registry.audit_sink(event)

proc make_error_result(tool_name: string; code: string; message: string): JsonNode =
  %*{
    "ok": false,
    "tool": tool_name,
    "code": code,
    "error": message
  }

proc invoke_tool*(registry: ToolRegistry; ctx: ToolContext; tool_name: string; args: JsonNode): JsonNode =
  let started = now_unix_ms()
  let normalized_name = normalize_tool_name(tool_name)
  let safe_args =
    if args.isNil or args.kind == JNull: newJObject()
    else: args

  if registry.isNil:
    return make_error_result(normalized_name, ToolCodeExecFailed, "Tool registry is nil")

  if not registry.tools.hasKey(normalized_name):
    let err_result = make_error_result(normalized_name, ToolCodeNotFound, "Tool not registered: " & normalized_name)
    registry.emit_audit(ToolAuditEvent(
      timestamp_ms: now_unix_ms(),
      run_id: ctx.run_id,
      workspace_id: ctx.workspace_id,
      user_id: ctx.user_id,
      tool_name: normalized_name,
      status: "not_found",
      reason: "missing tool",
      duration_ms: now_unix_ms() - started,
      args_json: safe_args,
      result_json: err_result
    ))
    return err_result

  let tool = registry.tools[normalized_name]
  let decision =
    if registry.policy == nil: default_policy(ctx, normalized_name, safe_args)
    else: registry.policy(ctx, normalized_name, safe_args)

  if not decision.allowed:
    let err_result = make_error_result(normalized_name, ToolCodeDenied, decision.reason)
    registry.emit_audit(ToolAuditEvent(
      timestamp_ms: now_unix_ms(),
      run_id: ctx.run_id,
      workspace_id: ctx.workspace_id,
      user_id: ctx.user_id,
      tool_name: normalized_name,
      status: "denied",
      reason: decision.reason,
      duration_ms: now_unix_ms() - started,
      args_json: safe_args,
      result_json: err_result
    ))
    return err_result

  try:
    let payload = tool.executor(tool.config, ctx, safe_args)
    result = %*{
      "ok": true,
      "tool": normalized_name,
      "result": payload
    }
    registry.emit_audit(ToolAuditEvent(
      timestamp_ms: now_unix_ms(),
      run_id: ctx.run_id,
      workspace_id: ctx.workspace_id,
      user_id: ctx.user_id,
      tool_name: normalized_name,
      status: "success",
      reason: "",
      duration_ms: now_unix_ms() - started,
      args_json: safe_args,
      result_json: result
    ))
  except CatchableError as e:
    result = make_error_result(normalized_name, ToolCodeExecFailed, e.msg)
    registry.emit_audit(ToolAuditEvent(
      timestamp_ms: now_unix_ms(),
      run_id: ctx.run_id,
      workspace_id: ctx.workspace_id,
      user_id: ctx.user_id,
      tool_name: normalized_name,
      status: "failed",
      reason: e.msg,
      duration_ms: now_unix_ms() - started,
      args_json: safe_args,
      result_json: result
    ))

proc get_json_str(obj: JsonNode; key: string; default = ""): string =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JString:
    obj[key].getStr()
  else:
    default

proc get_json_int(obj: JsonNode; key: string; default = 0): int =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind in {JInt, JFloat}:
    obj[key].getInt()
  else:
    default

proc ensure_json_array_string(obj: JsonNode; key: string): seq[string] =
  if obj.kind != JObject or not obj.hasKey(key):
    return @[]
  if obj[key].kind != JArray:
    raise newException(ValueError, "Field '" & key & "' must be an array")
  for item in obj[key].items:
    if item.kind != JString:
      raise newException(ValueError, "Field '" & key & "' must contain only strings")
    result.add(item.getStr())

proc parse_string_allowlist(config: JsonNode; key: string): seq[string] =
  if config.kind == JObject and config.hasKey(key) and config[key].kind == JArray:
    for item in config[key].items:
      if item.kind == JString:
        result.add(item.getStr())

proc parse_headers(obj: JsonNode): HttpHeaders =
  result = newHttpHeaders()
  if obj.kind != JObject or not obj.hasKey("headers"):
    return
  let headers = obj["headers"]
  if headers.kind != JObject:
    raise newException(ValueError, "headers must be an object")
  for k, v in headers:
    if v.kind != JString:
      raise newException(ValueError, "headers values must be strings")
    result[k] = v.getStr()

proc is_subpath(base_path: string; candidate: string): bool =
  when defined(windows):
    let base_norm = normalizedPath(base_path).toLowerAscii()
    let candidate_norm = normalizedPath(candidate).toLowerAscii()
  else:
    let base_norm = normalizedPath(base_path)
    let candidate_norm = normalizedPath(candidate)

  if candidate_norm == base_norm:
    return true
  candidate_norm.startsWith(base_norm & DirSep)

proc resolve_scoped_path(root: string; raw_path: string): string =
  if raw_path.len == 0:
    raise newException(ValueError, "path is required")

  let base = normalizedPath(absolutePath(root))
  let candidate =
    if raw_path.isAbsolute:
      normalizedPath(raw_path)
    else:
      normalizedPath(absolutePath(raw_path, base))

  if not is_subpath(base, candidate):
    raise newException(ValueError, "Path is outside workspace root")

  candidate

proc shell_executor(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
  discard ctx
  if args.kind != JObject:
    raise newException(ValueError, "shell args must be an object")

  let argv = ensure_json_array_string(args, "argv")
  if argv.len == 0:
    raise newException(ValueError, "shell argv must contain at least one element")

  let allowlist = parse_string_allowlist(config, "allowlist")
  if allowlist.len > 0 and argv[0] notin allowlist:
    raise newException(ValueError, "Command is not allowlisted: " & argv[0])

  let cwd = get_json_str(args, "cwd", "")
  if cwd.len > 0 and not dirExists(cwd):
    raise newException(ValueError, "cwd does not exist: " & cwd)

  let proc_args = if argv.len > 1: argv[1..^1] else: @[]
  var p: Process = nil
  try:
    p = startProcess(
      command = argv[0],
      args = proc_args,
      workingDir = cwd,
      options = {poUsePath, poStdErrToStdOut}
    )
    let output =
      if p.outputStream != nil: p.outputStream.readAll()
      else: ""
    let exit_code = waitForExit(p)
    %*{
      "exit_code": exit_code,
      "output": output,
      "ok": exit_code == 0
    }
  finally:
    if p != nil:
      close(p)

proc filesystem_executor(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
  discard ctx
  if args.kind != JObject:
    raise newException(ValueError, "filesystem args must be an object")

  let root = get_json_str(config, "workspace_root", ".")
  let action = get_json_str(args, "action", "").toLowerAscii()
  if action.len == 0:
    raise newException(ValueError, "filesystem action is required")

  let path = resolve_scoped_path(root, get_json_str(args, "path", ""))

  case action
  of "read":
    if not fileExists(path):
      raise newException(ValueError, "File does not exist: " & path)
    %*{
      "path": path,
      "content": readFile(path)
    }
  of "write":
    let content = get_json_str(args, "content", "")
    createDir(parentDir(path))
    writeFile(path, content)
    %*{
      "path": path,
      "bytes": content.len
    }
  of "list":
    if not dirExists(path):
      raise newException(ValueError, "Directory does not exist: " & path)
    var items = newJArray()
    for kind, p in walkDir(path, relative = true):
      let kind_s = case kind
        of pcFile: "file"
        of pcDir: "dir"
        of pcLinkToFile: "link_file"
        of pcLinkToDir: "link_dir"
      items.add(%*{"name": p, "kind": kind_s})
    %*{
      "path": path,
      "items": items
    }
  else:
    raise newException(ValueError, "Unsupported filesystem action: " & action)

proc http_fetch_executor(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
  discard config
  discard ctx
  if args.kind != JObject:
    raise newException(ValueError, "http_fetch args must be an object")

  let url = get_json_str(args, "url", "")
  if url.len == 0:
    raise newException(ValueError, "http_fetch url is required")

  let method_name = get_json_str(args, "method", "GET").toUpperAscii()
  let timeout_ms = get_json_int(args, "timeout_ms", 15000)
  let body = get_json_str(args, "body", "")

  var client = newHttpClient(timeout = timeout_ms)
  try:
    client.headers = parse_headers(args)

    let http_method = case method_name
      of "GET": HttpGet
      of "POST": HttpPost
      of "PUT": HttpPut
      of "PATCH": HttpPatch
      of "DELETE": HttpDelete
      of "HEAD": HttpHead
      else:
        raise newException(ValueError, "Unsupported HTTP method: " & method_name)

    let response = client.request(url, httpMethod = http_method, body = body)
    %*{
      "status_code": response.code.int,
      "status": $response.code,
      "body": response.body
    }
  finally:
    client.close()

proc register_builtin_shell_tool*(registry: ToolRegistry; allowlist: seq[string] = @[]) =
  var config = newJObject()
  var allow = newJArray()
  for cmd in allowlist:
    allow.add(%cmd)
  config["allowlist"] = allow

  registry.register_tool(ToolDef(
    name: "shell",
    description: "Execute an allowlisted command with argv",
    config: config,
    executor: shell_executor
  ))

proc register_builtin_filesystem_tool*(registry: ToolRegistry; workspace_root = ".") =
  var config = newJObject()
  config["workspace_root"] = %normalizedPath(absolutePath(workspace_root))

  registry.register_tool(ToolDef(
    name: "filesystem",
    description: "Scoped file read/write/list operations",
    config: config,
    executor: filesystem_executor
  ))

proc register_builtin_http_fetch_tool*(registry: ToolRegistry) =
  registry.register_tool(ToolDef(
    name: "http_fetch",
    description: "HTTP request tool",
    config: newJObject(),
    executor: http_fetch_executor
  ))

proc register_builtin_toolset*(registry: ToolRegistry; workspace_root = "."; shell_allowlist: seq[string] = @[]) =
  registry.register_builtin_shell_tool(shell_allowlist)
  registry.register_builtin_filesystem_tool(workspace_root)
  registry.register_builtin_http_fetch_tool()

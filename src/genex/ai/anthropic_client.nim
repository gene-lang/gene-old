## Anthropic API Client for Gene
## Implements Anthropic Messages API support with API token and OAuth/auth token modes.

import json, httpclient, strutils, os, tables, asyncdispatch

type
  AnthropicConfig* = ref object
    api_token*: string
    auth_token*: string
    base_url*: string
    model*: string
    headers*: Table[string, string]
    timeout_ms*: int
    max_retries*: int
    extra*: JsonNode

  AnthropicError* = ref object of CatchableError
    status*: int
    provider_error*: string
    request_id*: string
    retry_after*: int
    metadata*: JsonNode
    raw_body*: string

const
  DEFAULT_ANTHROPIC_BASE_URL* = "https://api.anthropic.com/v1"
  DEFAULT_ANTHROPIC_VERSION* = "2023-06-01"
  DEFAULT_ANTHROPIC_TIMEOUT_MS* = 30000
  DEFAULT_ANTHROPIC_MAX_RETRIES* = 3
  DEFAULT_ANTHROPIC_USER_AGENT* = "gene-anthropic-client/1.0"
  CLAUDE_CODE_USER_AGENT* = "claude-cli/2.1.75"
  CLAUDE_CODE_SYSTEM_PROMPT* = "You are Claude Code, Anthropic's official CLI for Claude."
  PI_AI_DEFAULT_ANTHROPIC_BETAS* = [
    "fine-grained-tool-streaming-2025-05-14",
    "interleaved-thinking-2025-05-14"
  ]
  PI_AI_OAUTH_ANTHROPIC_BETAS* = [
    "claude-code-20250219",
    "oauth-2025-04-20",
    "fine-grained-tool-streaming-2025-05-14",
    "interleaved-thinking-2025-05-14"
  ]

proc get_env_var(key: string, default: string = ""): string =
  try:
    result = os.getEnv(key, default)
  except:
    result = default

proc isAnthropicOAuthToken*(token: string): bool =
  ## OpenClaw/pi-ai detects Anthropic OAuth tokens via this prefix.
  token.len > 0 and token.contains("sk-ant-oat")

proc addUniqueAnthropicBeta(parts: var seq[string], beta: string) =
  let trimmed = beta.strip()
  if trimmed.len == 0:
    return
  if trimmed notin parts:
    parts.add(trimmed)

proc mergeAnthropicBetas(existing: string, required: openArray[string]): string =
  var parts: seq[string] = @[]
  for beta in required:
    addUniqueAnthropicBeta(parts, beta)
  for beta in existing.split(','):
    addUniqueAnthropicBeta(parts, beta)
  result = parts.join(",")

proc addAnthropicSystemTextBlock(blocks: JsonNode, text: string) =
  if text.strip().len == 0:
    return
  blocks.add(%*{
    "type": "text",
    "text": text
  })

proc normalizeAnthropicSystemBlocks(system_value: JsonNode): JsonNode =
  result = newJArray()
  case system_value.kind
  of JNull:
    discard
  of JString:
    addAnthropicSystemTextBlock(result, system_value.getStr())
  of JArray:
    for item in system_value:
      case item.kind
      of JString:
        addAnthropicSystemTextBlock(result, item.getStr())
      else:
        result.add(item)
  else:
    result.add(system_value)

proc applyAnthropicOAuthCompatibility(config: AnthropicConfig, payload: var JsonNode) =
  if not isAnthropicOAuthToken(config.auth_token):
    return

  var system_blocks = newJArray()
  addAnthropicSystemTextBlock(system_blocks, CLAUDE_CODE_SYSTEM_PROMPT)
  if payload.hasKey("system"):
    let existing_system = normalizeAnthropicSystemBlocks(payload["system"])
    for item in existing_system:
      system_blocks.add(item)
  payload["system"] = system_blocks

proc buildAnthropicConfig*(options: JsonNode = newJNull()): AnthropicConfig =
  let opts = if options.kind != JNull: options else: %*{}

  var auth_token = ""
  if opts.hasKey("auth_token"):
    auth_token = opts["auth_token"].getStr("")
  elif opts.hasKey("oauth_token"):
    auth_token = opts["oauth_token"].getStr("")
  else:
    auth_token = get_env_var("ANTHROPIC_OAUTH_TOKEN")

  var api_token = ""
  if opts.hasKey("api_token"):
    api_token = opts["api_token"].getStr("")
  elif opts.hasKey("api_key"):
    api_token = opts["api_key"].getStr("")
  else:
    api_token = get_env_var("ANTHROPIC_API_KEY")

  # Preserve OpenClaw compatibility: treat sk-ant-oat as OAuth/auth token.
  if auth_token.len == 0 and isAnthropicOAuthToken(api_token):
    auth_token = api_token
    api_token = ""

  let anthropic_version =
    if opts.hasKey("anthropic_version"):
      opts["anthropic_version"].getStr(DEFAULT_ANTHROPIC_VERSION)
    else:
      get_env_var("ANTHROPIC_VERSION", DEFAULT_ANTHROPIC_VERSION)

  let model =
    if opts.hasKey("model"):
      opts["model"].getStr("claude-3-5-sonnet-latest")
    else:
      get_env_var("ANTHROPIC_MODEL", "claude-3-5-sonnet-latest")

  let base_url =
    if opts.hasKey("base_url"):
      opts["base_url"].getStr(get_env_var("ANTHROPIC_BASE_URL", DEFAULT_ANTHROPIC_BASE_URL))
    else:
      get_env_var("ANTHROPIC_BASE_URL", DEFAULT_ANTHROPIC_BASE_URL)

  result = AnthropicConfig(
    api_token: api_token,
    auth_token: auth_token,
    base_url: base_url,
    model: model,
    timeout_ms: if opts.hasKey("timeout_ms"): opts["timeout_ms"].getInt(DEFAULT_ANTHROPIC_TIMEOUT_MS) else: DEFAULT_ANTHROPIC_TIMEOUT_MS,
    max_retries: if opts.hasKey("max_retries"): opts["max_retries"].getInt(DEFAULT_ANTHROPIC_MAX_RETRIES) else: DEFAULT_ANTHROPIC_MAX_RETRIES,
    headers: initTable[string, string]()
  )

  result.headers["Content-Type"] = "application/json"
  result.headers["Accept"] = "application/json"
  result.headers["User-Agent"] = DEFAULT_ANTHROPIC_USER_AGENT
  result.headers["anthropic-version"] = anthropic_version

  if result.auth_token.len > 0:
    result.headers["Authorization"] = "Bearer " & result.auth_token
  elif result.api_token.len > 0:
    result.headers["x-api-key"] = result.api_token

  let uses_oauth_setup_token = isAnthropicOAuthToken(result.auth_token)
  if uses_oauth_setup_token:
    result.headers["User-Agent"] = CLAUDE_CODE_USER_AGENT
    result.headers["x-app"] = "cli"
    result.headers["anthropic-dangerous-direct-browser-access"] = "true"

  var anthropic_beta = ""
  if opts.hasKey("anthropic_beta"):
    anthropic_beta = opts["anthropic_beta"].getStr("")
  elif opts.hasKey("beta"):
    anthropic_beta = opts["beta"].getStr("")
  else:
    anthropic_beta = get_env_var("ANTHROPIC_BETA")

  if uses_oauth_setup_token:
    anthropic_beta = mergeAnthropicBetas(anthropic_beta, PI_AI_OAUTH_ANTHROPIC_BETAS)
  elif anthropic_beta.len == 0 and result.auth_token.len > 0:
    anthropic_beta = "oauth-2025-04-20"
  if anthropic_beta.len > 0:
    result.headers["anthropic-beta"] = anthropic_beta

  if opts.hasKey("headers"):
    let headers = opts["headers"]
    for key, value in headers:
      result.headers[key] = value.getStr()

  if opts.hasKey("extra"):
    result.extra = opts["extra"]
  else:
    result.extra = %*{}

proc to_http_method(http_method: string): HttpMethod =
  case http_method.toUpperAscii()
  of "GET": HttpGet
  of "POST": HttpPost
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  of "HEAD": HttpHead
  of "PATCH": HttpPatch
  of "OPTIONS": HttpOptions
  else: HttpPost

proc request_async(url: string, http_method: HttpMethod, body: string, headers: HttpHeaders): Future[AsyncResponse] {.async.} =
  var client = newAsyncHttpClient()
  try:
    return await client.request(url, httpMethod = http_method, body = body, headers = headers)
  finally:
    client.close()

proc performAnthropicRequest*(
  config: AnthropicConfig,
  httpMethod: string,
  endpoint: string,
  payload: JsonNode = newJNull(),
  streaming: bool = false
): JsonNode =
  try:
    let url = config.base_url & endpoint
    let body = if payload.kind != JNull: $payload else: ""
    let request_method = to_http_method(httpMethod)

    var headers = newHttpHeaders()
    for key, value in config.headers:
      headers[key] = value

    let request_future = request_async(url, request_method, body, headers)
    let request_done = waitFor(request_future.withTimeout(config.timeout_ms))
    if not request_done:
      raise AnthropicError(
        msg: "Network error: request timed out after " & $config.timeout_ms & "ms",
        status: -1,
        provider_error: "timeout"
      )

    let response = request_future.read()
    let body_future = response.body()
    let body_done = waitFor(body_future.withTimeout(config.timeout_ms))
    if not body_done:
      raise AnthropicError(
        msg: "Network error: response body timed out after " & $config.timeout_ms & "ms",
        status: -1,
        provider_error: "timeout"
      )
    let response_body = body_future.read()

    let code_text = response.status.split()[0]
    let status_code = try: parseInt(code_text) except ValueError: -1
    if status_code < 200 or status_code >= 300:
      let errorBody = try: parseJson(response_body) except: %*{"message": response_body}
      var errorMsg = ""
      var errorType = ""

      if errorBody.kind == JObject and errorBody.hasKey("error"):
        let err_node = errorBody["error"]
        if err_node.kind == JObject:
          if err_node.hasKey("message"):
            errorMsg = err_node["message"].getStr()
          if err_node.hasKey("type"):
            errorType = err_node["type"].getStr()
      elif errorBody.kind == JObject and errorBody.hasKey("message"):
        errorMsg = errorBody["message"].getStr()
      else:
        errorMsg = response_body

      var err = AnthropicError(
        msg: "Anthropic API Error: " & errorMsg,
        status: status_code,
        provider_error: errorType,
        metadata: errorBody,
        raw_body: response_body
      )

      if response.headers.hasKey("request-id"):
        err.request_id = response.headers["request-id"]
      elif response.headers.hasKey("x-request-id"):
        err.request_id = response.headers["x-request-id"]

      if status_code == 429 and response.headers.hasKey("retry-after"):
        try:
          err.retry_after = parseInt(response.headers["retry-after"])
        except ValueError:
          discard

      raise err

    if streaming:
      result = %*{"streaming": true, "body": response_body}
    else:
      result = parseJson(response_body)
  except AnthropicError:
    raise
  except Exception as e:
    raise AnthropicError(
      msg: "Network error: " & e.msg,
      status: -1,
      provider_error: "network"
    )

proc buildAnthropicMessagesPayload*(config: AnthropicConfig, options: JsonNode): JsonNode =
  var payload = %*{
    "model": if options.hasKey("model"): options["model"].getStr(config.model) else: config.model,
    "messages": if options.hasKey("messages"): options["messages"] else: %*[],
    "max_tokens":
      if options.hasKey("max_tokens"):
        options["max_tokens"].getInt(1024)
      elif options.hasKey("max_completion_tokens"):
        options["max_completion_tokens"].getInt(1024)
      else:
        1024,
    "stream": if options.hasKey("stream"): options["stream"].getBool(false) else: false
  }

  let optionalFields = [
    "system",
    "temperature",
    "top_p",
    "top_k",
    "stop_sequences",
    "metadata",
    "tools",
    "tool_choice"
  ]
  for field in optionalFields:
    if options.hasKey(field):
      payload[field] = options[field]

  if config.extra != nil:
    for key, value in config.extra:
      payload[key] = value

  applyAnthropicOAuthCompatibility(config, payload)

  return payload

proc normalizeAnthropicResponse*(response: JsonNode): JsonNode =
  response

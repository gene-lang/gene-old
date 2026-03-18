## OpenAI-Compatible API Client for Gene
## Implements the OpenAIClient class with support for chat completions, responses, embeddings, and streaming

import json, httpclient, strutils, os, tables, asyncdispatch

type
  OpenAIConfig* = ref object
    api_key*: string
    auth_token*: string
    account_id*: string
    base_url*: string
    model*: string
    organization*: string
    headers*: Table[string, string]
    timeout_ms*: int
    max_retries*: int
    extra*: JsonNode

  OpenAIError* = ref object of CatchableError
    status*: int
    provider_error*: string
    request_id*: string
    retry_after*: int
    metadata*: JsonNode
    raw_body*: string

  StreamingChunk* = ref object
    delta*: JsonNode
    done*: bool
    event*: string

# Constants for OpenAI API endpoints
const
  DEFAULT_BASE_URL* = "https://api.openai.com/v1"
  DEFAULT_CODEX_BASE_URL* = "https://chatgpt.com"
  DEFAULT_CODEX_RESPONSES_ENDPOINT* = "/backend-api/codex/responses"
  DEFAULT_TIMEOUT_MS* = 30000
  DEFAULT_MAX_RETRIES* = 3
  GENECLAW_CODEX_ORIGINATOR* = "geneclaw"
  GENECLAW_CODEX_USER_AGENT* = "geneclaw/1.0"

# Helper functions for environment variable reading
proc getEnvVar*(key: string, default: string = ""): string =
  try:
    result = os.getEnv(key, default)
  except:
    result = default

# Secret redaction for logging
proc redactSecret*(value: string): string =
  if value.len <= 8:
    return "*".repeat(value.len)
  result = value[0..2] & "*".repeat(value.len - 6) & value[value.len-3..value.len-1]

proc is_sensitive_header_name(name: string): bool =
  let normalized = name.strip().toLowerAscii()
  case normalized
  of "authorization", "proxy-authorization", "x-api-key", "api-key", "openai-api-key":
    return true
  else:
    discard

  result = normalized.contains("token") or normalized.contains("secret")

proc redact_header_value(name: string, value: string): string =
  if not is_sensitive_header_name(name):
    return value

  let trimmed = value.strip()
  if trimmed.len == 0:
    return trimmed

  let first_space = trimmed.find(' ')
  if first_space > 0 and first_space < trimmed.len - 1:
    let scheme = trimmed[0 ..< first_space]
    let credential = trimmed[first_space + 1 .. ^1]
    return scheme & " " & redactSecret(credential)

  return redactSecret(trimmed)

proc redactHeadersForLog*(headers: Table[string, string]): string =
  var pairs: seq[string] = @[]
  for key, value in headers:
    pairs.add(key & ": " & redact_header_value(key, value))
  result = "{" & pairs.join(", ") & "}"

proc isCodexOAuth*(config: OpenAIConfig): bool =
  config != nil and config.auth_token.len > 0

proc resolveCodexBaseUrl(config: OpenAIConfig): string =
  if config == nil:
    return DEFAULT_CODEX_BASE_URL
  if config.base_url.len == 0 or config.base_url == DEFAULT_BASE_URL:
    return DEFAULT_CODEX_BASE_URL
  return config.base_url

proc cloneConfigWithBaseUrl(config: OpenAIConfig, base_url: string): OpenAIConfig =
  result = OpenAIConfig(
    api_key: config.api_key,
    auth_token: config.auth_token,
    account_id: config.account_id,
    base_url: base_url,
    model: config.model,
    organization: config.organization,
    headers: initTable[string, string](),
    timeout_ms: config.timeout_ms,
    max_retries: config.max_retries,
    extra: config.extra
  )
  for key, value in config.headers:
    result.headers[key] = value

# Config building with precedence: options > env > defaults
proc buildOpenAIConfig*(options: JsonNode = newJNull()): OpenAIConfig =
  let opts = if options.kind != JNull: options else: %*{}

  result = OpenAIConfig(
    api_key: if opts.hasKey("api_key"): opts["api_key"].getStr(getEnvVar("OPENAI_API_KEY")) else: getEnvVar("OPENAI_API_KEY"),
    auth_token: if opts.hasKey("auth_token"): opts["auth_token"].getStr(getEnvVar("OPENAI_AUTH_TOKEN", getEnvVar("OPENAI_OAUTH_TOKEN"))) else: getEnvVar("OPENAI_AUTH_TOKEN", getEnvVar("OPENAI_OAUTH_TOKEN")),
    account_id: if opts.hasKey("account_id"): opts["account_id"].getStr(getEnvVar("OPENAI_ACCOUNT_ID", getEnvVar("CHATGPT_ACCOUNT_ID"))) else: getEnvVar("OPENAI_ACCOUNT_ID", getEnvVar("CHATGPT_ACCOUNT_ID")),
    base_url: if opts.hasKey("base_url"): opts["base_url"].getStr(getEnvVar("OPENAI_BASE_URL", DEFAULT_BASE_URL)) else: getEnvVar("OPENAI_BASE_URL", DEFAULT_BASE_URL),
    model: if opts.hasKey("model"): opts["model"].getStr("gpt-3.5-turbo") else: "gpt-3.5-turbo",
    organization: if opts.hasKey("organization"): opts["organization"].getStr(getEnvVar("OPENAI_ORG")) else: getEnvVar("OPENAI_ORG"),
    timeout_ms: if opts.hasKey("timeout_ms"): opts["timeout_ms"].getInt(DEFAULT_TIMEOUT_MS) else: DEFAULT_TIMEOUT_MS,
    max_retries: if opts.hasKey("max_retries"): opts["max_retries"].getInt(DEFAULT_MAX_RETRIES) else: DEFAULT_MAX_RETRIES,
    headers: initTable[string, string]()
  )

  # Add default headers
  result.headers["Content-Type"] = "application/json"
  result.headers["User-Agent"] = "gene-openai-client/1.0"

  if result.auth_token != "":
    result.headers["Authorization"] = "Bearer " & result.auth_token
    result.headers["originator"] = GENECLAW_CODEX_ORIGINATOR
    result.headers["User-Agent"] = GENECLAW_CODEX_USER_AGENT
    if result.account_id != "":
      result.headers["ChatGPT-Account-Id"] = result.account_id
  elif result.api_key != "":
    result.headers["Authorization"] = "Bearer " & result.api_key

  if result.organization != "":
    result.headers["OpenAI-Organization"] = result.organization

  # Merge custom headers from options
  if opts.hasKey("headers"):
    let headers = opts["headers"]
    for key, value in headers:
      result.headers[key] = value.getStr()

  # Store extra fields for provider-specific passthrough
  if opts.hasKey("extra"):
    result.extra = opts["extra"]
  else:
    result.extra = %*{}

# HTTP client wrapper with signing and error handling
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
  let ai_debug = getEnvVar("GENE_AI_DEBUG", "") == "1"
  if ai_debug:
    echo "[genex/ai] request_async start ", $http_method, " ", url
  var client = newAsyncHttpClient()
  try:
    return await client.request(url, httpMethod = http_method, body = body, headers = headers)
  finally:
    if ai_debug:
      echo "[genex/ai] request_async close client"
    client.close()

proc extractRequestId(headers: HttpHeaders): string =
  for key in ["x-request-id", "x-oai-request-id"]:
    if headers.hasKey(key):
      return headers[key]
  return ""

proc extractOpenAIErrorDetails(errorBody: JsonNode): tuple[msg: string, errType: string] =
  if errorBody == nil:
    return ("", "")

  if errorBody.kind == JObject and errorBody.hasKey("error"):
    let nested = errorBody["error"]
    var msg = ""
    var errType = ""
    if nested.kind == JObject:
      if nested.hasKey("message"):
        msg = nested["message"].getStr()
      if nested.hasKey("type"):
        errType = nested["type"].getStr()
    elif nested.kind == JString:
      msg = nested.getStr()
    return (msg, errType)

  if errorBody.kind == JObject:
    if errorBody.hasKey("message") and errorBody["message"].kind == JString:
      return (errorBody["message"].getStr(), "")
    if errorBody.hasKey("detail"):
      if errorBody["detail"].kind == JString:
        return (errorBody["detail"].getStr(), "")
      return ($errorBody["detail"], "")

  if errorBody.kind == JString:
    return (errorBody.getStr(), "")

  return ($errorBody, "")

proc buildOpenAIHttpError(response: AsyncResponse, statusCode: int, response_body: string): OpenAIError =
  let errorBody = try: parseJson(response_body) except: %*{"message": response_body}
  let details = extractOpenAIErrorDetails(errorBody)
  result = OpenAIError(
    msg: "OpenAI API Error: " & details.msg,
    status: statusCode,
    provider_error: details.errType,
    metadata: errorBody,
    raw_body: response_body
  )
  result.request_id = extractRequestId(response.headers)

  if statusCode == 429 and response.headers.hasKey("retry-after"):
    try:
      result.retry_after = parseInt(response.headers["retry-after"])
    except:
      discard

proc performRequest*(config: OpenAIConfig, httpMethod: string, endpoint: string,
                   payload: JsonNode = newJNull(), streaming: bool = false,
                   extra_headers: seq[(string, string)] = @[]): JsonNode =
  try:
    let ai_debug = getEnvVar("GENE_AI_DEBUG", "") == "1"
    let url = config.base_url & endpoint
    let body = if payload.kind != JNull: $payload else: ""
    let request_method = to_http_method(httpMethod)

    var headers = newHttpHeaders()
    for key, value in config.headers:
      headers[key] = value
    for header in extra_headers:
      headers[header[0]] = header[1]

    when defined(debug):
      echo "DEBUG: OpenAI API Request: ", httpMethod, " ", url
      var effective_headers = initTable[string, string]()
      for key, value in config.headers:
        effective_headers[key] = value
      for header in extra_headers:
        effective_headers[header[0]] = header[1]
      echo "DEBUG: Headers: ", redactHeadersForLog(effective_headers)
      if body != "":
        echo "DEBUG: Body: ", body[0..min(body.len, 200)] & (if body.len > 200: "..." else: "")
    if ai_debug:
      echo "[genex/ai] performRequest start method=", httpMethod, " url=", url, " timeout_ms=", $config.timeout_ms

    let request_future = request_async(url, request_method, body, headers)
    if ai_debug:
      echo "[genex/ai] waiting request future"
    let request_done = waitFor(request_future.withTimeout(config.timeout_ms))
    if ai_debug:
      echo "[genex/ai] request_done=", $request_done
    if not request_done:
      if ai_debug:
        echo "[genex/ai] timeout branch raising OpenAIError"
      raise OpenAIError(
        msg: "Network error: request timed out after " & $config.timeout_ms & "ms",
        status: -1,
        provider_error: "timeout"
      )
    let response = request_future.read()
    if ai_debug:
      echo "[genex/ai] response received status=", response.status

    let body_future = response.body()
    if ai_debug:
      echo "[genex/ai] waiting body future"
    let body_done = waitFor(body_future.withTimeout(config.timeout_ms))
    if ai_debug:
      echo "[genex/ai] body_done=", $body_done
    if not body_done:
      raise OpenAIError(
        msg: "Network error: response body timed out after " & $config.timeout_ms & "ms",
        status: -1,
        provider_error: "timeout"
      )
    let response_body = body_future.read()

    when defined(debug):
      echo "DEBUG: Response status: ", response.status
      echo "DEBUG: Response headers: ", response.headers

    let statusCode = parseInt(response.status.split()[0])  # Extract just the status code (e.g., "200" from "200 OK")
    if statusCode < 200 or statusCode >= 300:
      raise buildOpenAIHttpError(response, statusCode, response_body)

    if not streaming:
      result = parseJson(response_body)
    else:
      # For streaming, we'll handle the response body differently
      result = %*{"streaming": true, "body": response_body}

  except OpenAIError:
    if getEnvVar("GENE_AI_DEBUG", "") == "1":
      echo "[genex/ai] performRequest rethrow OpenAIError"
    raise
  except Exception as e:
    if getEnvVar("GENE_AI_DEBUG", "") == "1":
      echo "[genex/ai] performRequest wrapping exception: ", e.msg
    raise OpenAIError(
      msg: "Network error: " & e.msg,
      status: -1,
      provider_error: "network"
    )

# Payload builders for different endpoints
proc buildChatPayload*(config: OpenAIConfig, options: JsonNode): JsonNode =
  var payload = %*{
    "model": if options.hasKey("model"): options["model"].getStr(config.model) else: config.model,
    "messages": if options.hasKey("messages"): options["messages"] else: %*[],
    "max_completion_tokens": if options.hasKey("max_completion_tokens"): options["max_completion_tokens"].getInt(1000)
                              elif options.hasKey("max_tokens"): options["max_tokens"].getInt(1000)
                              else: 1000,
    "temperature": if options.hasKey("temperature"): options["temperature"].getFloat(1.0) else: 1.0,
    "stream": if options.hasKey("stream"): options["stream"].getBool(false) else: false
  }

  # Native tool calling support
  if options.hasKey("tools"):
    payload["tools"] = options["tools"]
    payload["tool_choice"] = if options.hasKey("tool_choice"): options["tool_choice"] else: %*"auto"

  # Merge optional parameters
  let optionalFields = ["top_p", "n", "stop", "presence_penalty", "frequency_penalty", "logit_bias", "user"]
  for field in optionalFields:
    if options.hasKey(field):
      payload[field] = options[field]

  # Add extra fields from config
  if config.extra != nil:
    for key, value in config.extra:
      payload[key] = value

  return payload

proc buildEmbeddingsPayload*(config: OpenAIConfig, options: JsonNode): JsonNode =
  var payload = %*{
    "model": if options.hasKey("model"): options["model"].getStr(config.model) else: config.model,
    "input": if options.hasKey("input"): options["input"] else: %*"",
    "encoding_format": if options.hasKey("encoding_format"): options["encoding_format"].getStr("float") else: "float"
  }

  # Add extra fields from config
  if config.extra != nil:
    for key, value in config.extra:
      payload[key] = value

  return payload

proc buildResponsesPayload*(config: OpenAIConfig, options: JsonNode): JsonNode =
  var payload = %*{
    "model": if options.hasKey("model"): options["model"].getStr(config.model) else: config.model,
    "input": if options.hasKey("input"): options["input"] else: %*"",
    "max_tokens": if options.hasKey("max_tokens"): options["max_tokens"].getInt(1000) else: 1000,
    "temperature": if options.hasKey("temperature"): options["temperature"].getFloat(1.0) else: 1.0
  }

  # Merge optional parameters
  let optionalFields = ["top_p", "n", "stop", "presence_penalty", "frequency_penalty", "tools", "tool_choice"]
  for field in optionalFields:
    if options.hasKey(field):
      payload[field] = options[field]

  # Add extra fields from config
  if config.extra != nil:
    for key, value in config.extra:
      payload[key] = value

  return payload

proc buildCodexResponsesPayload*(config: OpenAIConfig, options: JsonNode): JsonNode =
  var payload = %*{
    "model": if options.hasKey("model"): options["model"].getStr(config.model) else: config.model,
    "instructions": if options.hasKey("instructions"): options["instructions"] else: %*"",
    "input": if options.hasKey("input"): options["input"] else: %*[],
    "store": false,
    "stream": true
  }

  if options.hasKey("tools"):
    payload["tools"] = options["tools"]

  if options.hasKey("tool_choice"):
    payload["tool_choice"] = options["tool_choice"]

  if config.extra != nil:
    for key, value in config.extra:
      payload[key] = value

  return payload

proc parseCodexResponsesSSE*(body: string): JsonNode =
  var event_name = ""
  var data_lines: seq[string] = @[]
  var completed_response: JsonNode = nil
  var failed_response: JsonNode = nil
  var stream_error: JsonNode = nil

  proc flush_event() =
    if data_lines.len == 0:
      event_name = ""
      return

    let payload_text = data_lines.join("\n")
    data_lines.setLen(0)

    if payload_text == "[DONE]":
      event_name = ""
      return

    let payload = try: parseJson(payload_text) except: nil
    if payload == nil:
      event_name = ""
      return

    let payload_type =
      if payload.kind == JObject and payload.hasKey("type"):
        payload["type"].getStr()
      else:
        event_name

    case payload_type
    of "response.completed":
      if payload.kind == JObject and payload.hasKey("response"):
        completed_response = payload["response"]
    of "response.failed":
      failed_response =
        if payload.kind == JObject and payload.hasKey("response"):
          payload["response"]
        else:
          payload
    of "error":
      stream_error = payload
    else:
      discard

    event_name = ""

  for raw_line in body.splitLines():
    let line = raw_line.strip(trailing = false)
    if line.len == 0:
      flush_event()
      continue
    if line.startsWith("event:"):
      event_name = line[6 .. ^1].strip()
      continue
    if line.startsWith("data:"):
      data_lines.add(line[5 .. ^1].strip())
      continue

  flush_event()

  if completed_response != nil:
    return completed_response

  if failed_response != nil:
    var err_msg = "Codex response failed"
    var err_type = "response_failed"
    if failed_response.kind == JObject and failed_response.hasKey("error"):
      let details = extractOpenAIErrorDetails(failed_response["error"])
      if details.msg.len > 0:
        err_msg = details.msg
      if details.errType.len > 0:
        err_type = details.errType
    raise OpenAIError(
      msg: "OpenAI API Error: " & err_msg,
      status: 200,
      provider_error: err_type,
      metadata: failed_response,
      raw_body: body
    )

  if stream_error != nil:
    let details = extractOpenAIErrorDetails(stream_error)
    raise OpenAIError(
      msg: "OpenAI API Error: " & (if details.msg.len > 0: details.msg else: "stream error"),
      status: 200,
      provider_error: if details.errType.len > 0: details.errType else: "stream_error",
      metadata: stream_error,
      raw_body: body
    )

  raise OpenAIError(
    msg: "OpenAI API Error: Codex stream ended without response.completed",
    status: -1,
    provider_error: "stream_incomplete",
    raw_body: body
  )

proc performCodexResponsesRequest*(config: OpenAIConfig, payload: JsonNode): JsonNode =
  let codex_config = cloneConfigWithBaseUrl(config, resolveCodexBaseUrl(config))
  var client = newHttpClient(timeout = codex_config.timeout_ms)

  try:
    let url = codex_config.base_url & DEFAULT_CODEX_RESPONSES_ENDPOINT
    let body = $payload

    var headers = newHttpHeaders()
    for key, value in codex_config.headers:
      headers[key] = value
    headers["Accept"] = "text/event-stream"

    when defined(debug):
      var effective_headers = initTable[string, string]()
      for key, value in codex_config.headers:
        effective_headers[key] = value
      effective_headers["Accept"] = "text/event-stream"
      echo "DEBUG: OpenAI Codex Request: POST ", url
      echo "DEBUG: Headers: ", redactHeadersForLog(effective_headers)
      echo "DEBUG: Body: ", body[0..min(body.len, 200)] & (if body.len > 200: "..." else: "")

    let response = client.request(url, httpMethod = HttpPost, body = body, headers = headers)
    let response_body = response.body
    let statusCode = parseInt(response.status.split()[0])
    if statusCode < 200 or statusCode >= 300:
      let errorBody = try: parseJson(response_body) except: %*{"message": response_body}
      let details = extractOpenAIErrorDetails(errorBody)
      var error = OpenAIError(
        msg: "OpenAI API Error: " & details.msg,
        status: statusCode,
        provider_error: details.errType,
        metadata: errorBody,
        raw_body: response_body
      )
      error.request_id = extractRequestId(response.headers)
      raise error

    return parseCodexResponsesSSE(response_body)
  except OpenAIError:
    raise
  except Exception as e:
    raise OpenAIError(
      msg: "Network error: " & e.msg,
      status: -1,
      provider_error: "network"
    )
  finally:
    client.close()

# Response normalization from JSON to Gene values
proc normalizeResponse*(response: JsonNode): JsonNode =
  # Convert JSON response to maintain consistency with Gene's Value types
  # This is a placeholder - actual conversion will be handled in the Gene bridge
  result = response

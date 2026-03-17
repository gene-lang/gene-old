## OpenAI-Compatible API Client for Gene
## Implements the OpenAIClient class with support for chat completions, responses, embeddings, and streaming

import json, httpclient, strutils, os, tables, asyncdispatch

type
  OpenAIConfig* = ref object
    api_key*: string
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
  DEFAULT_TIMEOUT_MS* = 30000
  DEFAULT_MAX_RETRIES* = 3

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

# Config building with precedence: options > env > defaults
proc buildOpenAIConfig*(options: JsonNode = newJNull()): OpenAIConfig =
  let opts = if options.kind != JNull: options else: %*{}

  result = OpenAIConfig(
    api_key: if opts.hasKey("api_key"): opts["api_key"].getStr(getEnvVar("OPENAI_API_KEY")) else: getEnvVar("OPENAI_API_KEY"),
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

  if result.api_key != "":
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

proc performRequest*(config: OpenAIConfig, httpMethod: string, endpoint: string,
                   payload: JsonNode = newJNull(), streaming: bool = false): JsonNode =
  try:
    let ai_debug = getEnvVar("GENE_AI_DEBUG", "") == "1"
    let url = config.base_url & endpoint
    let body = if payload.kind != JNull: $payload else: ""
    let request_method = to_http_method(httpMethod)

    var headers = newHttpHeaders()
    for key, value in config.headers:
      headers[key] = value

    when defined(debug):
      echo "DEBUG: OpenAI API Request: ", httpMethod, " ", url
      echo "DEBUG: Headers: ", redactHeadersForLog(config.headers)
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

    let statusCode = response.status.split()[0]  # Extract just the status code (e.g., "200" from "200 OK")
    if statusCode != "200":
      let errorBody = try: parseJson(response_body) except: %*{"message": response_body}
      var errorMsg = ""
      var errorType = ""
      if errorBody.hasKey("error"):
        if errorBody["error"].hasKey("message"):
          errorMsg = errorBody["error"]["message"].getStr()
        if errorBody["error"].hasKey("type"):
          errorType = errorBody["error"]["type"].getStr()
      else:
        errorMsg = errorBody.getStr()

      var error = OpenAIError(
        msg: "OpenAI API Error: " & errorMsg,
        status: parseInt(statusCode),
        provider_error: errorType,
        metadata: errorBody,
        raw_body: response_body
      )

      # Extract request ID if available
      if response.headers.hasKey("x-request-id"):
        error.request_id = response.headers["x-request-id"]

      # Extract retry-after for rate limiting
      if statusCode == "429" and response.headers.hasKey("retry-after"):
        try:
          error.retry_after = parseInt(response.headers["retry-after"])
        except:
          discard

      raise error

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

# Response normalization from JSON to Gene values
proc normalizeResponse*(response: JsonNode): JsonNode =
  # Convert JSON response to maintain consistency with Gene's Value types
  # This is a placeholder - actual conversion will be handled in the Gene bridge
  result = response

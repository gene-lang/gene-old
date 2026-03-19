## Streaming implementation for OpenAI API
## Handles SSE (Server-Sent Events) and chunked streaming

import json, strutils, httpclient, tables, streams
import ../../gene/types
import ../../gene/logging_core
import ../../gene/vm/extension_abi
import openai_client

const StreamingLogger = "genex/ai/streaming"

template streaming_log(level: LogLevel, message: untyped) =
  if extension_log_enabled(level, StreamingLogger):
    extension_log_message(level, StreamingLogger, message)

type
  StreamEvent* = ref object
    event*: string
    data*: JsonNode
    done*: bool

  StreamHandler* = proc(event: StreamEvent) {.gcsafe.}

# SSE parsing utilities
proc parseSSELine*(line: string): StreamEvent =
  if line.len == 0:
    return StreamEvent(event: "keepalive", done: false)

  if line.startsWith("event: "):
    return StreamEvent(event: line[7..line.len-1], done: false)

  if line.startsWith("data: "):
    let dataStr = line[6..line.len-1]
    if dataStr == "[DONE]":
      return StreamEvent(event: "done", done: true)

    try:
      let data = parseJson(dataStr)
      return StreamEvent(event: "data", data: data, done: false)
    except:
      return StreamEvent(event: "error", done: false)

  return StreamEvent(event: "unknown", done: false)

# Stream processing for both SSE and chunked responses
proc processStream*(stream: Stream, handler: StreamHandler) =
  if stream.isNil:
    return

  while not stream.atEnd():
    var line = stream.readLine()
    line = line.strip()
    if line.len == 0:
      continue

    let event = parseSSELine(line)

    streaming_log(LlDebug, "Stream event: " & event.event & " done: " & $event.done)

    if event.event in ["data", "done", "error"]:
      handler(event)

    if event.done:
      break

proc processBufferedStream*(body: string, handler: StreamHandler) =
  var buffer = newStringStream(body)
  defer: buffer.close()
  processStream(buffer, handler)

# HTTP streaming request processor
proc performStreamingRequest*(config: OpenAIConfig, endpoint: string,
                             payload: JsonNode, handler: StreamHandler) =
  var client = newHttpClient(timeout = config.timeout_ms)

  try:
    let url = config.base_url & endpoint
    let body = $payload

    var headers = newHttpHeaders()
    for key, value in config.headers:
      headers[key] = value

    if log_enabled(LlDebug, StreamingLogger):
      streaming_log(LlDebug, "OpenAI Streaming Request: POST " & url)
      streaming_log(LlDebug, "Headers: " & redactHeadersForLog(config.headers))
      streaming_log(LlDebug, "Body: " & body[0..min(body.len, 200)] &
                    (if body.len > 200: "..." else: ""))

    # Make streaming request
    let response = client.request(url, httpMethod = HttpPost,
                                 body = body, headers = headers)

    streaming_log(LlDebug, "Streaming response status: " & response.status)

    let statusCode = response.status.split()[0]
    if statusCode != "200":
      let errorBody = try: parseJson(response.body) except: %*{"message": response.body}
      var errorMsg = ""
      if errorBody.hasKey("error") and errorBody["error"].hasKey("message"):
        errorMsg = errorBody["error"]["message"].getStr()
      else:
        errorMsg = errorBody.getStr()

      raise OpenAIError(
        msg: "OpenAI Streaming Error: " & errorMsg,
        status: parseInt(statusCode),
        provider_error: "streaming_error",
        metadata: errorBody
      )

    # Process the streaming response
    if response.bodyStream != nil:
      processStream(response.bodyStream, handler)
    else:
      processBufferedStream(response.body, handler)

  except OpenAIError:
    raise
  except system.Exception as e:
    raise OpenAIError(
      msg: "Streaming network error: " & e.msg,
      status: -1,
      provider_error: "network"
    )
  finally:
    client.close()

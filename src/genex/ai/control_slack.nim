import std/json
import std/tables
import std/strutils
import std/httpclient
import std/os
import std/osproc
import std/uri
import std/mimetypes

import wrappers/openssl

import ./utils


type
  SlackVerifyResult* = object
    ok*: bool
    reason*: string

  SlackReplayGuard* = ref object
    ttl_sec*: int64
    seen*: Table[string, int64]

  SlackFileTransferResult* = object
    ok*: bool
    error*: string
    path*: string
    byte_size*: int64
    sha256*: string

  SlackUploadResult* = object
    ok*: bool
    error*: string
    file_id*: string
    title*: string
    permalink*: string
    byte_size*: int64
    real_path*: string
    mime_type*: string


proc bytes_to_hex(bytes: openArray[byte]): string =
  const hex_chars = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(hex_chars[(b shr 4) and 0x0F])
    result.add(hex_chars[b and 0x0F])

proc secure_eq(a: string; b: string): bool =
  if a.len != b.len:
    return false
  var diff = 0'u8
  for i in 0..<a.len:
    diff = diff or (cast[uint8](a[i]) xor cast[uint8](b[i]))
  diff == 0'u8

proc hmac_sha256_hex(key: string; message: string): string =
  var digest: array[EVP_MAX_MD_SIZE, byte]
  var digest_len: cuint = 0

  let key_ptr =
    if key.len == 0: nil
    else: cast[pointer](unsafeAddr key[0])
  let msg_ptr =
    if message.len == 0: nil
    else: message.cstring

  discard HMAC(
    EVP_sha256(),
    key_ptr,
    key.len.cint,
    msg_ptr,
    message.len.csize_t,
    cast[cstring](addr digest[0]),
    addr digest_len
  )

  bytes_to_hex(digest.toOpenArray(0, digest_len.int - 1))

proc compute_slack_signature*(signing_secret: string; timestamp_sec: string; raw_body: string): string =
  let base = "v0:" & timestamp_sec & ":" & raw_body
  "v0=" & hmac_sha256_hex(signing_secret, base)

proc parse_unix_sec(ts: string): int64 =
  try:
    parseInt(ts).int64
  except ValueError:
    -1

proc verify_slack_signature*(
  signing_secret: string;
  timestamp_sec: string;
  provided_signature: string;
  raw_body: string;
  now_ms = now_unix_ms();
  max_skew_sec = 300'i64
): SlackVerifyResult =
  if signing_secret.len == 0:
    return SlackVerifyResult(ok: false, reason: "missing signing secret")

  if provided_signature.len < 4 or not provided_signature.startsWith("v0="):
    return SlackVerifyResult(ok: false, reason: "invalid signature format")

  let ts = parse_unix_sec(timestamp_sec)
  if ts < 0:
    return SlackVerifyResult(ok: false, reason: "invalid timestamp")

  let now_sec = now_ms div 1000
  if abs(now_sec - ts) > max_skew_sec:
    return SlackVerifyResult(ok: false, reason: "stale timestamp")

  let expected = compute_slack_signature(signing_secret, timestamp_sec, raw_body)
  if not secure_eq(expected, provided_signature):
    return SlackVerifyResult(ok: false, reason: "signature mismatch")

  SlackVerifyResult(ok: true, reason: "")

proc is_slack_url_verification*(payload: JsonNode): bool =
  payload.kind == JObject and
    payload.hasKey("type") and
    payload["type"].kind == JString and
    payload["type"].getStr() == "url_verification"

proc slack_url_challenge*(payload: JsonNode): string =
  if payload.kind == JObject and payload.hasKey("challenge") and payload["challenge"].kind == JString:
    payload["challenge"].getStr()
  else:
    ""

proc slack_event_id*(payload: JsonNode): string =
  if payload.kind == JObject and payload.hasKey("event_id") and payload["event_id"].kind == JString:
    payload["event_id"].getStr()
  else:
    ""

proc json_get_str(obj: JsonNode; key: string): string =
  if obj.kind == JObject and obj.hasKey(key) and obj[key].kind == JString:
    obj[key].getStr()
  else:
    ""

proc json_get_int64(obj: JsonNode; key: string): int64 =
  if obj.kind != JObject or not obj.hasKey(key):
    return 0'i64
  case obj[key].kind
  of JInt:
    obj[key].getInt().int64
  of JFloat:
    obj[key].getFloat().int64
  else:
    0'i64

proc normalize_slack_attachment(file_obj: JsonNode): JsonNode =
  result = newJObject()
  result["source"] = %"slack"

  let file_id = json_get_str(file_obj, "id")
  if file_id.len > 0:
    result["file_id"] = %file_id

  let filename = json_get_str(file_obj, "name")
  if filename.len > 0:
    result["filename"] = %filename

  let title = json_get_str(file_obj, "title")
  if title.len > 0:
    result["title"] = %title

  let mime_type = json_get_str(file_obj, "mimetype")
  if mime_type.len > 0:
    result["mime_type"] = %mime_type

  let filetype = json_get_str(file_obj, "filetype")
  if filetype.len > 0:
    result["filetype"] = %filetype

  let pretty_type = json_get_str(file_obj, "pretty_type")
  if pretty_type.len > 0:
    result["pretty_type"] = %pretty_type

  let url_private = json_get_str(file_obj, "url_private")
  if url_private.len > 0:
    result["url_private"] = %url_private

  let url_private_download = json_get_str(file_obj, "url_private_download")
  if url_private_download.len > 0:
    result["url_private_download"] = %url_private_download

  let download_url =
    if url_private_download.len > 0: url_private_download
    else: url_private
  if download_url.len > 0:
    result["download_url"] = %download_url

  let size = json_get_int64(file_obj, "size")
  if size > 0:
    result["size"] = %size

proc extract_slack_attachments*(event: JsonNode): JsonNode =
  result = newJArray()
  if event.kind != JObject:
    return

  if event.hasKey("files") and event["files"].kind == JArray:
    for file_obj in event["files"]:
      if file_obj.kind == JObject:
        result.add(normalize_slack_attachment(file_obj))

  if result.len == 0 and event.hasKey("file") and event["file"].kind == JObject:
    result.add(normalize_slack_attachment(event["file"]))

proc slack_event_to_command*(payload: JsonNode; workspace_id = ""): CommandEnvelope =
  if payload.kind != JObject:
    raise newException(ValueError, "Slack payload must be an object")

  if is_slack_url_verification(payload):
    raise newException(ValueError, "url_verification payload does not carry a command")

  let payload_type = json_get_str(payload, "type")
  if payload_type != "event_callback":
    raise newException(ValueError, "Unsupported Slack payload type: " & payload_type)

  if not payload.hasKey("event") or payload["event"].kind != JObject:
    raise newException(ValueError, "Slack event_callback payload missing event object")

  let event = payload["event"]
  let event_type = json_get_str(event, "type")
  if event_type != "message":
    raise newException(ValueError, "Unsupported Slack event type: " & event_type)

  let subtype = json_get_str(event, "subtype")
  if subtype == "bot_message" or json_get_str(event, "bot_id").len > 0:
    raise newException(ValueError, "Bot messages are ignored")

  let event_id = slack_event_id(payload)
  let resolved_workspace =
    if workspace_id.len > 0: workspace_id
    else: json_get_str(payload, "team_id")

  let channel = json_get_str(event, "channel")
  let user = json_get_str(event, "user")
  let text = json_get_str(event, "text")
  let ts = json_get_str(event, "ts")
  let attachments = extract_slack_attachments(event)
  let thread_ts = block:
    let v = json_get_str(event, "thread_ts")
    if v.len > 0: v
    else: ts

  if channel.len == 0 or user.len == 0:
    raise newException(ValueError, "Slack message missing required user/channel")
  if text.len == 0 and attachments.len == 0:
    raise newException(ValueError, "Slack message missing text and attachments")

  let metadata = %*{
    "payload_type": payload_type,
    "event_type": event_type,
    "subtype": subtype,
    "team_id": json_get_str(payload, "team_id"),
    "event_time": if payload.hasKey("event_time"): payload["event_time"] else: newJInt(0),
    "slack_ts": ts,
    "attachments_count": attachments.len
  }

  new_command_envelope(
    command_id = if event_id.len > 0: event_id else: "slack-" & $now_unix_ms(),
    source = CsSlack,
    workspace_id = resolved_workspace,
    user_id = user,
    channel_id = channel,
    thread_id = thread_ts,
    text = text,
    attachments = attachments,
    metadata = metadata
  )

proc new_slack_replay_guard*(ttl_sec = 3600'i64): SlackReplayGuard =
  SlackReplayGuard(ttl_sec: ttl_sec, seen: initTable[string, int64]())

proc cleanup_replay_guard*(guard: SlackReplayGuard; now_ms = now_unix_ms()) =
  if guard.isNil:
    return
  let cutoff = now_ms - (guard.ttl_sec * 1000)
  var to_remove: seq[string] = @[]
  for event_id, seen_at in guard.seen:
    if seen_at < cutoff:
      to_remove.add(event_id)
  for event_id in to_remove:
    guard.seen.del(event_id)

proc mark_or_is_duplicate*(guard: SlackReplayGuard; event_id: string; now_ms = now_unix_ms()): bool =
  if guard.isNil:
    return false
  if event_id.len == 0:
    return false

  guard.cleanup_replay_guard(now_ms)

  if guard.seen.hasKey(event_id):
    return true

  guard.seen[event_id] = now_ms
  false


# --- Slack reply adapter ---

type
  SlackReplyTarget* = object
    channel*: string
    thread_ts*: string

  SlackReplyResult* = object
    ok*: bool
    error*: string
    ts*: string

  SlackClient* = ref object
    bot_token*: string
    base_url*: string


proc new_slack_client*(bot_token = ""; base_url = "https://slack.com"): SlackClient =
  let token =
    if bot_token.len > 0: bot_token
    else: getEnv("SLACK_BOT_TOKEN")
  SlackClient(bot_token: token, base_url: base_url)

proc reply_target_from_envelope*(envelope: CommandEnvelope): SlackReplyTarget =
  SlackReplyTarget(
    channel: envelope.channel_id,
    thread_ts: envelope.thread_id
  )

proc form_encode(params: openArray[(string, string)]): string =
  result = ""
  for i, (key, value) in params:
    if i > 0:
      result.add('&')
    result.add(encodeUrl(key))
    result.add('=')
    result.add(encodeUrl(value))

proc extract_slack_error(body: JsonNode; fallback = "unknown Slack API error"): string =
  if body.kind == JObject and body.hasKey("error") and body["error"].kind == JString:
    return body["error"].getStr()
  fallback

proc slack_api_form_json(client: SlackClient; method_path: string; params: openArray[(string, string)]): JsonNode =
  if client.isNil or client.bot_token.len == 0:
    raise newException(ValueError, "missing bot token")

  let url = client.base_url & "/api/" & method_path
  var http = newHttpClient()
  try:
    http.headers = newHttpHeaders({
      "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
      "Authorization": "Bearer " & client.bot_token
    })
    let response = http.request(url, httpMethod = HttpPost, body = form_encode(params))
    let body = parseJson(response.body)
    if body.kind == JObject and body.hasKey("ok") and body["ok"].kind == JBool and body["ok"].getBool():
      return body
    raise newException(IOError, extract_slack_error(body))
  finally:
    http.close()

proc slack_file_info*(client: SlackClient; file_id: string): JsonNode =
  if file_id.len == 0:
    raise newException(ValueError, "missing file id")

  let body = slack_api_form_json(client, "files.info", [("file", file_id)])
  if body.hasKey("file") and body["file"].kind == JObject:
    return normalize_slack_attachment(body["file"])
  raise newException(IOError, "Slack files.info returned no file payload")

proc try_hash_cmd(path: string): string =
  proc run_hash(cmd: string): string =
    let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})
    if res.exitCode != 0:
      return ""
    let tokens = res.output.splitWhitespace()
    if tokens.len == 0:
      return ""
    tokens[0]

  if findExe("shasum").len > 0:
    let digest = run_hash("shasum -a 256 " & quoteShell(path))
    if digest.len > 0:
      return digest
  if findExe("sha256sum").len > 0:
    let digest = run_hash("sha256sum " & quoteShell(path))
    if digest.len > 0:
      return digest
  if findExe("openssl").len > 0:
    let res = execCmdEx("openssl dgst -sha256 " & quoteShell(path), options = {poUsePath, poStdErrToStdOut})
    if res.exitCode == 0:
      let tokens = res.output.splitWhitespace()
      if tokens.len > 0:
        return tokens[^1]
  ""

proc path_within_root*(real_path: string; root_path: string): bool =
  if real_path.len == 0 or root_path.len == 0:
    return false
  let normalized_real = normalizedPath(real_path)
  let normalized_root = normalizedPath(root_path)
  when defined(windows):
    let lhs = normalized_real.toLowerAscii()
    let rhs = normalized_root.toLowerAscii()
    if lhs == rhs:
      return true
    let prefix = if rhs.endsWith(DirSep): rhs else: rhs & DirSep
    lhs.startsWith(prefix)
  else:
    if normalized_real == normalized_root:
      return true
    let prefix = if normalized_root.endsWith(DirSep): normalized_root else: normalized_root & DirSep
    normalized_real.startsWith(prefix)

proc resolve_managed_path*(requested_path: string; allowed_roots: seq[string]): string =
  if requested_path.len == 0:
    raise newException(ValueError, "missing file path")

  let real_path =
    try:
      expandSymlink(expandFilename(requested_path))
    except CatchableError:
      expandFilename(requested_path)
  if not fileExists(real_path):
    raise newException(ValueError, "file does not exist")

  var checked_roots = 0
  for root in allowed_roots:
    if root.len == 0:
      continue
    let resolved_root =
      try:
        if dirExists(root): expandSymlink(expandFilename(root))
        else: normalizedPath(absolutePath(root))
      except CatchableError:
        normalizedPath(absolutePath(root))
    if resolved_root.len == 0:
      continue
    inc checked_roots
    if path_within_root(real_path, resolved_root):
      return real_path

  if checked_roots == 0:
    raise newException(ValueError, "no managed roots configured")
  raise newException(ValueError, "path is outside managed roots")

proc slack_download_to_path*(client: SlackClient; download_url: string; dest_path: string): SlackFileTransferResult =
  if client.isNil or client.bot_token.len == 0:
    return SlackFileTransferResult(ok: false, error: "missing bot token")
  if download_url.len == 0:
    return SlackFileTransferResult(ok: false, error: "missing download url")
  if dest_path.len == 0:
    return SlackFileTransferResult(ok: false, error: "missing destination path")

  var http = newHttpClient()
  try:
    http.headers = newHttpHeaders({
      "Authorization": "Bearer " & client.bot_token
    })
    let response = http.request(download_url, httpMethod = HttpGet)
    if response.code.int >= 400:
      return SlackFileTransferResult(ok: false, error: "download failed: HTTP " & $response.code.int)

    let body = response.body
    writeFile(dest_path, body)
    SlackFileTransferResult(
      ok: true,
      error: "",
      path: dest_path,
      byte_size: body.len.int64,
      sha256: try_hash_cmd(dest_path)
    )
  except CatchableError as e:
    SlackFileTransferResult(ok: false, error: e.msg)
  finally:
    http.close()

proc slack_upload_file*(
  client: SlackClient;
  requested_path: string;
  allowed_roots: seq[string];
  channel_id: string;
  thread_ts = "";
  title = "";
  initial_comment = ""
): SlackUploadResult =
  if client.isNil or client.bot_token.len == 0:
    return SlackUploadResult(ok: false, error: "missing bot token")
  if channel_id.len == 0:
    return SlackUploadResult(ok: false, error: "missing channel")

  let real_path =
    try:
      resolve_managed_path(requested_path, allowed_roots)
    except CatchableError as e:
      return SlackUploadResult(ok: false, error: e.msg)

  if not fileExists(real_path):
    return SlackUploadResult(ok: false, error: "file does not exist")

  let filename = lastPathPart(real_path)
  let upload_title = if title.len > 0: title else: filename
  let byte_size = getFileSize(real_path).int64
  let ext = splitFile(real_path).ext.strip(chars = {'.'})
  let mime_db = newMimetypes()
  let mime_type =
    if ext.len > 0: mime_db.getMimetype(ext)
    else: "application/octet-stream"

  try:
    let get_url = slack_api_form_json(client, "files.getUploadURLExternal", [
      ("filename", filename),
      ("length", $byte_size)
    ])

    if not get_url.hasKey("upload_url") or get_url["upload_url"].kind != JString:
      return SlackUploadResult(ok: false, error: "Slack upload URL missing")
    if not get_url.hasKey("file_id") or get_url["file_id"].kind != JString:
      return SlackUploadResult(ok: false, error: "Slack file id missing")

    let upload_url = get_url["upload_url"].getStr()
    let file_id = get_url["file_id"].getStr()

    var upload_http = newHttpClient()
    try:
      upload_http.headers = newHttpHeaders({
        "Content-Type": mime_type
      })
      let upload_response = upload_http.request(upload_url, httpMethod = HttpPost, body = readFile(real_path))
      if upload_response.code.int >= 400:
        return SlackUploadResult(ok: false, error: "upload failed: HTTP " & $upload_response.code.int)
    finally:
      upload_http.close()

    var complete_params = @[
      ("files", $ %*[{"id": file_id, "title": upload_title}]),
      ("channel_id", channel_id)
    ]
    if thread_ts.len > 0:
      complete_params.add(("thread_ts", thread_ts))
    if initial_comment.len > 0:
      complete_params.add(("initial_comment", initial_comment))

    let complete = slack_api_form_json(client, "files.completeUploadExternal", complete_params)

    var permalink = ""
    if complete.hasKey("files") and complete["files"].kind == JArray and complete["files"].len > 0:
      let file_obj = complete["files"][0]
      if file_obj.kind == JObject and file_obj.hasKey("permalink") and file_obj["permalink"].kind == JString:
        permalink = file_obj["permalink"].getStr()

    SlackUploadResult(
      ok: true,
      error: "",
      file_id: file_id,
      title: upload_title,
      permalink: permalink,
      byte_size: byte_size,
      real_path: real_path,
      mime_type: mime_type
    )
  except CatchableError as e:
    SlackUploadResult(ok: false, error: e.msg)

proc slack_reply*(client: SlackClient; target: SlackReplyTarget; text: string): SlackReplyResult =
  if client.isNil or client.bot_token.len == 0:
    return SlackReplyResult(ok: false, error: "missing bot token")
  if target.channel.len == 0:
    return SlackReplyResult(ok: false, error: "missing channel")
  if text.len == 0:
    return SlackReplyResult(ok: false, error: "empty message")

  let payload = %*{
    "channel": target.channel,
    "text": text
  }
  if target.thread_ts.len > 0:
    payload["thread_ts"] = %target.thread_ts

  let url = client.base_url & "/api/chat.postMessage"
  var http = newHttpClient()
  try:
    http.headers = newHttpHeaders({
      "Content-Type": "application/json; charset=utf-8",
      "Authorization": "Bearer " & client.bot_token
    })
    let response = http.request(url, httpMethod = HttpPost, body = $payload)
    let body = parseJson(response.body)

    if body.kind == JObject and body.hasKey("ok") and body["ok"].kind == JBool and body["ok"].getBool():
      let ts =
        if body.hasKey("ts") and body["ts"].kind == JString: body["ts"].getStr()
        else: ""
      SlackReplyResult(ok: true, error: "", ts: ts)
    else:
      let err =
        if body.kind == JObject and body.hasKey("error") and body["error"].kind == JString:
          body["error"].getStr()
        else:
          "unknown Slack API error"
      SlackReplyResult(ok: false, error: err)
  except CatchableError as e:
    SlackReplyResult(ok: false, error: e.msg)
  finally:
    http.close()

proc slack_ack_json*(): JsonNode =
  ## Return the minimal 200 OK body Slack expects within 3 seconds.
  %*{"ok": true}

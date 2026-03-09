import os
import osproc
import strutils
import streams
import tables
import base64

import ../../gene/types

const
  default_pdf_command = "pdftotext"
  default_ocr_command = "tesseract"

var document_chunk_class*: Class

type
  ChunkStrategy* = enum
    csFixed
    csSentence
    csParagraph
    csRecursive

  MultipartPart = object
    name: string
    filename: string
    content_type: string
    data: string

proc init_documents_classes*() =
  VmCreatedCallbacks.add proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      if App == NIL or App.kind != VkApplication:
        return

      document_chunk_class = new_class("DocumentChunk")
      let class_ref = new_ref(VkClass)
      class_ref.class = document_chunk_class

      if App.app.gene_ns.kind == VkNamespace:
        App.app.gene_ns.ref.ns["DocumentChunk".to_key()] = class_ref.to_ref_value()

proc to_string_value(val: Value, label: string): string =
  case val.kind
  of VkString, VkSymbol:
    result = val.str
  else:
    raise new_exception(types.Exception, label & " must be a string")

proc map_get(map_val: Value, key: string): Value =
  if map_val.kind != VkMap:
    return NIL
  return map_data(map_val).getOrDefault(key.to_key(), NIL)

proc map_get_string(map_val: Value, key: string, default_value: string = ""): string =
  let val = map_get(map_val, key)
  if val == NIL:
    return default_value
  case val.kind
  of VkString, VkSymbol:
    return val.str
  else:
    return default_value

proc map_get_int(map_val: Value, key: string, default_value: int): int =
  let val = map_get(map_val, key)
  if val == NIL:
    return default_value
  case val.kind
  of VkInt:
    return val.int64.int
  of VkFloat:
    return int(val.float64)
  else:
    return default_value

proc map_get_bool(map_val: Value, key: string, default_value: bool): bool =
  let val = map_get(map_val, key)
  if val == NIL:
    return default_value
  return val.to_bool()

proc map_get_strings(map_val: Value, key: string): seq[string] =
  let val = map_get(map_val, key)
  if val.kind != VkArray:
    return @[]
  result = @[]
  for item in array_data(val):
    case item.kind
    of VkString, VkSymbol:
      result.add(item.str)
    else:
      discard

proc normalize_strategy(val: Value): string =
  if val == NIL:
    return "fixed"
  case val.kind
  of VkString, VkSymbol:
    var name = val.str
    if name.len > 0 and name[0] == ':':
      name = name[1..^1]
    return name
  else:
    return "fixed"

proc parse_strategy(name: string): ChunkStrategy =
  case name
  of "sentence":
    csSentence
  of "paragraph":
    csParagraph
  of "recursive":
    csRecursive
  else:
    csFixed

proc command_available(command: string): bool =
  if command.len == 0:
    return false
  if command.contains(DirSep) or command.contains(AltSep):
    return fileExists(command)
  return findExe(command).len > 0

proc resolve_command(config: Value, env_key: string, default_command: string): string =
  let configured = map_get_string(config, "command")
  if configured.len > 0:
    return configured
  let env_command = getEnv(env_key, "")
  if env_command.len > 0:
    return env_command
  return default_command

proc build_args(config: Value, default_args: seq[string], path: string): seq[string] =
  let custom_args = map_get_strings(config, "args")
  if custom_args.len == 0:
    return default_args

  result = @[]
  var found_path = false
  for arg in custom_args:
    if arg == "{path}":
      result.add(path)
      found_path = true
    else:
      result.add(arg)
  if not found_path:
    result.add(path)

proc run_command(command: string, args: seq[string]): tuple[output: string, exit_code: int, error: string] =
  try:
    let process = startProcess(command, args = args, options = {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exit_code = process.waitForExit()
    process.close()
    return (output, exit_code, "")
  except OSError as e:
    return ("", -1, e.msg)

proc split_pages(text: string): seq[string] =
  var parts = text.split('\f')
  if parts.len > 0 and parts[^1].strip().len == 0:
    parts.setLen(parts.len - 1)
  result = parts

proc new_document_chunk(text: string, metadata: Value): Value {.gcsafe.} =
  var chunk_class: Class
  {.cast(gcsafe).}:
    chunk_class = document_chunk_class
  if chunk_class == nil:
    let chunk_map = new_map_value()
    map_data(chunk_map) = initTable[Key, Value]()
    map_data(chunk_map)["text".to_key()] = text.to_value()
    map_data(chunk_map)["metadata".to_key()] = metadata
    return chunk_map

  var instance: Value
  {.cast(gcsafe).}:
    instance = new_instance_value(chunk_class)
  instance_props(instance)["text".to_key()] = text.to_value()
  instance_props(instance)["metadata".to_key()] = metadata
  return instance

proc chunk_metadata(index: int, strategy: string, source: string, start_pos: int, end_pos: int): Value =
  let meta = new_map_value()
  map_data(meta) = initTable[Key, Value]()
  map_data(meta)["index".to_key()] = index.to_value()
  map_data(meta)["strategy".to_key()] = strategy.to_value()
  if source.len > 0:
    map_data(meta)["source".to_key()] = source.to_value()
  if start_pos >= 0:
    map_data(meta)["start".to_key()] = start_pos.to_value()
  if end_pos >= 0:
    map_data(meta)["end".to_key()] = end_pos.to_value()
  meta

proc split_sentences(text: string): seq[string] =
  result = @[]
  var current = ""
  for i, ch in text:
    current.add(ch)
    if ch in {'.', '?', '!'}:
      let next_is_space = (i + 1 >= text.len) or text[i + 1].isSpaceAscii()
      if next_is_space:
        let trimmed = current.strip()
        if trimmed.len > 0:
          result.add(trimmed)
        current = ""
  let trimmed = current.strip()
  if trimmed.len > 0:
    result.add(trimmed)

proc split_paragraphs(text: string): seq[string] =
  let normalized = text.replace("\r\n", "\n")
  result = @[]
  for part in normalized.split("\n\n"):
    let trimmed = part.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc chunk_fixed(text: string, size: int, overlap: int, source: string): seq[Value] {.gcsafe.} =
  result = @[]
  if size <= 0:
    return result

  let safe_overlap = if overlap < 0: 0 else: min(overlap, size - 1)
  var index = 0
  var pos = 0
  while pos < text.len:
    let end_pos = min(pos + size, text.len)
    let chunk_text = text[pos..<end_pos]
    let meta = chunk_metadata(index, "fixed", source, pos, end_pos)
    result.add(new_document_chunk(chunk_text, meta))
    index.inc()
    if end_pos == text.len:
      break
    pos = end_pos - safe_overlap

proc chunk_by_units(units: seq[string], max_units: int, strategy: string, source: string): seq[Value] {.gcsafe.} =
  result = @[]
  if max_units <= 0:
    return result

  var index = 0
  var cursor = 0
  while cursor < units.len:
    let end_idx = min(cursor + max_units, units.len)
    let chunk_text = units[cursor..<end_idx].join(" ")
    let meta = chunk_metadata(index, strategy, source, -1, -1)
    result.add(new_document_chunk(chunk_text, meta))
    index.inc()
    cursor = end_idx

proc chunk_recursive(text: string, size: int, source: string): seq[Value] {.gcsafe.} =
  result = @[]
  if size <= 0:
    return result

  var index = 0
  for paragraph in split_paragraphs(text):
    if paragraph.len <= size:
      let meta = chunk_metadata(index, "recursive", source, -1, -1)
      result.add(new_document_chunk(paragraph, meta))
      index.inc()
      continue

    for sentence in split_sentences(paragraph):
      if sentence.len <= size:
        let meta = chunk_metadata(index, "recursive", source, -1, -1)
        result.add(new_document_chunk(sentence, meta))
        index.inc()
      else:
        for part in chunk_fixed(sentence, size, 0, source):
          let meta_val = if part.kind == VkInstance:
            instance_props(part).getOrDefault("metadata".to_key(), NIL)
          elif part.kind == VkMap:
            map_data(part).getOrDefault("metadata".to_key(), NIL)
          else:
            NIL
          if meta_val.kind == VkMap:
            map_data(meta_val)["strategy".to_key()] = "recursive".to_value()
          result.add(part)
          index.inc()

proc extract_pdf_text(path: string, config: Value): seq[string] =
  let command = resolve_command(config, "GENE_PDF_EXTRACTOR_CMD", default_pdf_command)
  if not command_available(command):
    raise new_exception(types.Exception, "PDF extractor not available.")

  let default_args = @["-layout", path, "-"]
  let args = build_args(config, default_args, path)
  let (output, exit_code, error) = run_command(command, args)

  if error.len > 0:
    raise new_exception(types.Exception, "PDF extractor failed: " & error)
  if exit_code != 0:
    raise new_exception(types.Exception, "PDF extractor failed: " & output)

  if map_get_bool(config, "split_pages", true):
    return split_pages(output)
  return @[output]

proc extract_image_text(path: string, config: Value): string =
  let command = resolve_command(config, "GENE_OCR_EXTRACTOR_CMD", default_ocr_command)
  if not command_available(command):
    raise new_exception(types.Exception, "OCR extractor not available.")

  let default_args = @[path, "stdout"]
  let args = build_args(config, default_args, path)
  let (output, exit_code, error) = run_command(command, args)

  if error.len > 0:
    raise new_exception(types.Exception, "OCR extractor failed: " & error)
  if exit_code != 0:
    raise new_exception(types.Exception, "OCR extractor failed: " & output)

  return output

proc encode_file_base64(path: string): string =
  if not fileExists(path):
    raise new_exception(types.Exception, "file_to_base64 file not found: " & path)
  try:
    return base64.encode(readFile(path))
  except IOError as e:
    raise new_exception(types.Exception, "file_to_base64 failed: " & e.msg)

proc chunk_text_value(text: string, config: Value): Value {.gcsafe.} =
  let strategy = parse_strategy(normalize_strategy(map_get(config, "strategy")))
  let size = map_get_int(config, "size", 500)
  let overlap = map_get_int(config, "overlap", 0)
  let source = map_get_string(config, "source")

  var chunks: seq[Value]
  case strategy
  of csFixed:
    chunks = chunk_fixed(text, size, overlap, source)
  of csSentence:
    chunks = chunk_by_units(split_sentences(text), max(size, 1), "sentence", source)
  of csParagraph:
    chunks = chunk_by_units(split_paragraphs(text), max(size, 1), "paragraph", source)
  of csRecursive:
    chunks = chunk_recursive(text, size, source)

  result = new_array_value(chunks)

proc parse_header_params(value: string): Table[string, string] =
  result = initTable[string, string]()
  for part in value.split(';'):
    let trimmed = part.strip()
    if trimmed.len == 0:
      continue
    if trimmed.contains('='):
      let pieces = trimmed.split('=', 1)
      if pieces.len == 2:
        var val = pieces[1].strip()
        if val.len >= 2 and val[0] == '"' and val[^1] == '"':
          val = val[1..^2]
        result[pieces[0].strip().toLowerAscii()] = val

proc parse_multipart(body: string, boundary: string): seq[MultipartPart] =
  result = @[]
  if boundary.len == 0:
    return result

  let marker = "--" & boundary
  let segments = body.split(marker)
  for segment in segments:
    var part = segment
    if part.len == 0:
      continue
    if part.startsWith("--"):
      break
    if part.startsWith("\r\n"):
      part = part[2..^1]
    if part.startsWith("\n"):
      part = part[1..^1]

    var header_end = part.find("\r\n\r\n")
    var header_sep_len = 4
    if header_end < 0:
      header_end = part.find("\n\n")
      header_sep_len = 2
    if header_end < 0:
      continue

    let header_block = part[0..<header_end]
    var content = part[(header_end + header_sep_len)..^1]
    if content.endsWith("\r\n"):
      content = content[0..^3]
    elif content.endsWith("\n"):
      content = content[0..^2]

    var name = ""
    var filename = ""
    var content_type = ""

    for line in header_block.splitLines():
      if not line.contains(":"):
        continue
      let pieces = line.split(":", 1)
      if pieces.len != 2:
        continue
      let header_name = pieces[0].strip().toLowerAscii()
      let header_value = pieces[1].strip()

      if header_name == "content-disposition":
        let params = parse_header_params(header_value)
        if params.hasKey("name"):
          name = params["name"]
        if params.hasKey("filename"):
          filename = params["filename"]
      elif header_name == "content-type":
        content_type = header_value

    if filename.len > 0 or name.len > 0:
      result.add(MultipartPart(name: name, filename: filename, content_type: content_type, data: content))

proc extract_boundary(headers: Value): string =
  if headers.kind != VkMap:
    return ""
  for k, v in map_data(headers):
    let key_val = cast[Value](k)
    if key_val.kind notin {VkString, VkSymbol}:
      continue
    if key_val.str.toLowerAscii() != "content-type":
      continue
    let header_val = block:
      if v.kind == VkString:
        v.str
      elif v.kind == VkArray and array_data(v).len > 0 and array_data(v)[0].kind in {VkString, VkSymbol}:
        array_data(v)[0].str
      else:
        $v
    for part in header_val.split(';'):
      let trimmed = part.strip()
      if trimmed.toLowerAscii().startsWith("boundary="):
        var boundary = trimmed.split("=", 1)[1].strip()
        if boundary.len >= 2 and boundary[0] == '"' and boundary[^1] == '"':
          boundary = boundary[1..^2]
        return boundary
  return ""

proc select_file_part(parts: seq[MultipartPart], field: string): MultipartPart =
  for part in parts:
    if part.filename.len == 0:
      continue
    if field.len == 0 or part.name == field:
      return part
  return MultipartPart(name: "", filename: "", content_type: "", data: "")

proc parse_upload(req_val: Value, options: Value): MultipartPart =
  if req_val.kind != VkInstance:
    raise new_exception(types.Exception, "upload requires a ServerRequest")

  let headers = instance_props(req_val).getOrDefault("headers".to_key(), NIL)
  let body_val = instance_props(req_val).getOrDefault("body".to_key(), NIL)
  let boundary = extract_boundary(headers)
  if boundary.len == 0:
    raise new_exception(types.Exception, "multipart boundary not found")

  let body = if body_val.kind == VkString: body_val.str else: ""
  let parts = parse_multipart(body, boundary)
  let field = map_get_string(options, "field")
  let part = select_file_part(parts, field)
  if part.filename.len == 0:
    raise new_exception(types.Exception, "no file found in upload")

  return part

proc vm_ai_documents_extract_pdf*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "extract_pdf requires a file path")

  let path_val = get_positional_arg(args, 0, has_keyword_args)
  let path = to_string_value(path_val, "extract_pdf path")
  var config = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    config = get_positional_arg(args, 1, has_keyword_args)

  let pages = extract_pdf_text(path, config)
  var result_pages = new_array_value()
  for page in pages:
    array_data(result_pages).add(page.to_value())
  return result_pages

proc vm_ai_documents_extract_image*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "extract_image requires a file path")

  let path_val = get_positional_arg(args, 0, has_keyword_args)
  let path = to_string_value(path_val, "extract_image path")
  var config = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    config = get_positional_arg(args, 1, has_keyword_args)

  let text = extract_image_text(path, config)
  return text.to_value()

proc vm_ai_documents_file_to_base64*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "file_to_base64 requires a file path")

  let path_val = get_positional_arg(args, 0, has_keyword_args)
  let path = to_string_value(path_val, "file_to_base64 path")
  let encoded = encode_file_base64(path)
  return encoded.to_value()

proc vm_ai_documents_chunk*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "chunk requires text")

  let text_val = get_positional_arg(args, 0, has_keyword_args)
  let text = to_string_value(text_val, "chunk text")
  var config = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    config = get_positional_arg(args, 1, has_keyword_args)

  return chunk_text_value(text, config)

proc vm_ai_documents_extract_and_chunk*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "extract_and_chunk requires a file path")

  let path_val = get_positional_arg(args, 0, has_keyword_args)
  let path = to_string_value(path_val, "extract_and_chunk path")
  var config = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    config = get_positional_arg(args, 1, has_keyword_args)

  var config_with_source = config
  if config.kind == VkMap:
    let key = "source".to_key()
    if not map_data(config).hasKey(key):
      map_data(config)[key] = path.to_value()
  else:
    let map_val = new_map_value()
    map_data(map_val) = initTable[Key, Value]()
    map_data(map_val)["source".to_key()] = path.to_value()
    config_with_source = map_val

  let pages = extract_pdf_text(path, config)
  let combined = pages.join("\n\n")
  return chunk_text_value(combined, config_with_source)

proc vm_ai_documents_save_upload*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    raise new_exception(types.Exception, "save_upload requires request and destination")

  let req_val = get_positional_arg(args, 0, has_keyword_args)
  let dest_val = get_positional_arg(args, 1, has_keyword_args)
  let dest_dir = to_string_value(dest_val, "save_upload destination")
  var options = NIL
  if get_positional_count(arg_count, has_keyword_args) > 2:
    options = get_positional_arg(args, 2, has_keyword_args)

  let part = parse_upload(req_val, options)
  let filename = lastPathPart(part.filename)
  if filename.len == 0:
    raise new_exception(types.Exception, "invalid upload filename")

  let max_size = map_get_int(options, "max_size", -1)
  if max_size > 0 and part.data.len > max_size:
    raise new_exception(types.Exception, "upload exceeds max_size")

  if not dirExists(dest_dir):
    createDir(dest_dir)

  let output_path = dest_dir / filename
  if fileExists(output_path) and not map_get_bool(options, "overwrite", false):
    raise new_exception(types.Exception, "upload destination already exists")

  writeFile(output_path, part.data)
  return output_path.to_value()

proc vm_ai_documents_validate_upload*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "validate_upload requires request")

  let req_val = get_positional_arg(args, 0, has_keyword_args)
  var options = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    options = get_positional_arg(args, 1, has_keyword_args)

  let part = parse_upload(req_val, options)
  let allowed = map_get_strings(options, "allowed_types")

  if allowed.len == 0:
    return TRUE

  let ext = splitFile(part.filename).ext.strip(leading = true, trailing = false, chars = {'.'}).toLowerAscii()
  let content_type = part.content_type.split(';')[0].strip().toLowerAscii()

  var ok = false
  for allowed_type in allowed:
    let normalized = allowed_type.toLowerAscii()
    if normalized.contains('/'):
      if content_type == normalized:
        ok = true
        break
    else:
      if ext == normalized:
        ok = true
        break

  if not ok:
    raise new_exception(types.Exception, "upload type not allowed")

  return TRUE

proc vm_ai_documents_extract_upload*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "extract_upload requires request")

  let req_val = get_positional_arg(args, 0, has_keyword_args)
  var options = NIL
  if get_positional_count(arg_count, has_keyword_args) > 1:
    options = get_positional_arg(args, 1, has_keyword_args)

  let part = parse_upload(req_val, options)
  let filename = lastPathPart(part.filename)
  let ext = splitFile(filename).ext.toLowerAscii()

  let tmp_dir = getTempDir() / "gene_uploads"
  if not dirExists(tmp_dir):
    createDir(tmp_dir)

  let temp_path = tmp_dir / filename
  writeFile(temp_path, part.data)
  defer:
    if fileExists(temp_path):
      removeFile(temp_path)

  if ext == ".pdf":
    let pages = extract_pdf_text(temp_path, options)
    return pages.join("\n\n").to_value()
  if ext in [".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".tif"]:
    let text = extract_image_text(temp_path, options)
    return text.to_value()

  raise new_exception(types.Exception, "unsupported upload type")

init_documents_classes()

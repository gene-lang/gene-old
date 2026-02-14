import strutils

const
  INDENT_WIDTH* = 2

type
  LineParts = object
    code: string
    comment: string

proc normalize_newlines*(source: string): string =
  source.replace("\r\n", "\n").replace('\r', '\n')

proc rstrip_ascii(line: string): string =
  result = line
  while result.len > 0 and result[^1] in {' ', '\t'}:
    result.setLen(result.len - 1)

proc split_lines_preserve(source: string): tuple[lines: seq[string], had_final_newline: bool] =
  var start = 0
  for i, ch in source:
    if ch == '\n':
      result.lines.add(source[start ..< i])
      start = i + 1

  if start < source.len:
    result.lines.add(source[start ..< source.len])
    result.had_final_newline = false
  else:
    result.had_final_newline = source.len > 0 and source[^1] == '\n'

proc split_comment(line: string): LineParts =
  var i = 0
  var in_string = false
  var in_char = false

  while i < line.len:
    let ch = line[i]

    if in_string:
      if ch == '\\' and i + 1 < line.len:
        i += 2
        continue
      if ch == '"':
        in_string = false
      inc i
      continue

    if in_char:
      if ch == '\\' and i + 1 < line.len:
        i += 2
        continue
      if ch == '\'':
        in_char = false
      inc i
      continue

    case ch
    of '"':
      in_string = true
    of '\'':
      in_char = true
    of '#':
      let next = if i + 1 < line.len: line[i + 1] else: '\0'
      if next in {' ', '\t', '!', '#', '<', '\0'}:
        result.code = line[0 ..< i]
        result.comment = line[i ..< line.len]
        return
    else:
      discard

    inc i

  result.code = line
  result.comment = ""

proc leading_close_count(code: string): int =
  var i = 0
  while i < code.len and code[i] in {' ', '\t'}:
    inc i

  while i < code.len:
    case code[i]
    of ')', ']', '}':
      inc result
      inc i
      while i < code.len and code[i] in {' ', '\t'}:
        inc i
    else:
      break

proc starts_with_keyword(code: string, keyword: string): bool =
  if not code.startsWith(keyword):
    return false
  if code.len == keyword.len:
    return true
  code[keyword.len] in {' ', '\t', ')', ']', '}'}

proc dedent_keyword_count(code: string): int =
  if starts_with_keyword(code, "elif"):
    return 1
  if starts_with_keyword(code, "else"):
    return 1
  if starts_with_keyword(code, "catch"):
    return 1
  if starts_with_keyword(code, "finally"):
    return 1
  0

proc update_depth(depth: var int, code: string) =
  var i = 0
  var in_string = false
  var in_char = false

  while i < code.len:
    let ch = code[i]

    if in_string:
      if ch == '\\' and i + 1 < code.len:
        i += 2
        continue
      if ch == '"':
        in_string = false
      inc i
      continue

    if in_char:
      if ch == '\\' and i + 1 < code.len:
        i += 2
        continue
      if ch == '\'':
        in_char = false
      inc i
      continue

    case ch
    of '"':
      in_string = true
    of '\'':
      in_char = true
    of '(','[','{':
      inc depth
    of ')',']','}':
      if depth > 0:
        dec depth
    else:
      discard

    inc i

proc is_blank(line: string): bool =
  for ch in line:
    if ch notin {' ', '\t'}:
      return false
  true

proc is_comment_only(line: string): bool =
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if i >= line.len:
    return false
  if line[i] != '#':
    return false
  if i + 1 >= line.len:
    return true
  line[i + 1] in {' ', '\t', '!', '#', '<'}

proc format_lines(lines: seq[string]): seq[string] =
  var depth = 0
  var hang_collection_indent = -1
  var hang_collection_depth = -1

  for idx, original in lines:
    var line = rstrip_ascii(original)

    if idx == 0 and line.startsWith("#!"):
      result.add(line)
      continue

    if is_blank(line):
      result.add("")
      continue

    if is_comment_only(line):
      # Keep comment text exactly (except trailing whitespace already removed).
      result.add(line)
      continue

    let parts = split_comment(line)
    let code_trimmed = parts.code.strip(leading = true, trailing = true)

    if code_trimmed.len == 0:
      # The line had no code before a comment marker. Preserve as comment line.
      result.add(parts.comment)
      continue

    let dedent = leading_close_count(code_trimmed) + dedent_keyword_count(code_trimmed)
    var effective_depth = depth - dedent
    if effective_depth < 0:
      effective_depth = 0

    var indent_count = effective_depth * INDENT_WIDTH
    if hang_collection_indent >= 0 and depth >= hang_collection_depth:
      if not code_trimmed.startsWith("]") and not code_trimmed.startsWith(")"):
        indent_count = hang_collection_indent

    var out_line = repeat(' ', indent_count) & code_trimmed
    if parts.comment.len > 0:
      # Preserve inline comment including any alignment spacing from source.
      var spacing = parts.code
      # Keep only trailing whitespace immediately before comment.
      var tail_start = spacing.len
      while tail_start > 0 and spacing[tail_start - 1] in {' ', '\t'}:
        dec tail_start
      let gap = spacing[tail_start ..< spacing.len]
      out_line &= gap & parts.comment

    result.add(out_line)
    update_depth(depth, code_trimmed)
    if hang_collection_indent >= 0 and depth < hang_collection_depth:
      hang_collection_indent = -1
      hang_collection_depth = -1

    let open_bracket = code_trimmed.find('[')
    if open_bracket >= 0:
      let close_bracket = code_trimmed.find(']')
      if close_bracket < 0:
        let after = if open_bracket + 1 < code_trimmed.len: code_trimmed[open_bracket + 1 ..< code_trimmed.len].strip() else: ""
        if after.len > 0:
          hang_collection_indent = indent_count + open_bracket + 1
          hang_collection_depth = depth

proc format_source*(source: string): string =
  let normalized = normalize_newlines(source)
  let split = split_lines_preserve(normalized)
  let formatted_lines = format_lines(split.lines)

  result = formatted_lines.join("\n")
  if split.had_final_newline:
    result &= "\n"

proc is_canonical_source*(source: string): bool =
  format_source(source) == normalize_newlines(source)

import os, strutils

type
  ViewerError* = object of CatchableError

  ViewerNodeKind* = enum
    VnkScalar
    VnkSequence
    VnkArray
    VnkMap
    VnkGene

  ViewerPathKind* = enum
    VpkIndex
    VpkKey
    VpkGeneType
    VpkGeneProp

  ViewerColorKind* = enum
    VckGene
    VckArray
    VckMap
    VckString
    VckLiteral
    VckOther

  ViewerPathSegment* = object
    kind*: ViewerPathKind
    index*: int
    name*: string

  ViewerSpan* = object
    synthetic*: bool
    start*: int
    stop*: int
    text*: string

  ViewerSourceLocation* = object
    line*: int
    column*: int

  ViewerDocument* = ref object
    file_path*: string
    source*: string
    root*: ViewerNode

  ViewerNode* = ref object
    doc*: ViewerDocument
    kind*: ViewerNodeKind
    span*: ViewerSpan
    loaded*: bool
    entries*: seq[ViewerEntry]

  ViewerEntry* = object
    segment*: ViewerPathSegment
    label*: string
    summary*: string
    node*: ViewerNode

  ViewerFrame* = object
    node*: ViewerNode
    selected*: int
    scroll*: int

  ViewerState* = ref object
    doc*: ViewerDocument
    frames*: seq[ViewerFrame]
    status*: string
    show_help*: bool
    type_ahead_query: string
    last_type_ahead_at: float
    quit_pending: bool

proc open_viewer_document*(file_path: string): ViewerDocument
proc open_viewer_document_from_source*(source, file_path: string): ViewerDocument
proc new_viewer_state*(doc: ViewerDocument): ViewerState
proc ensure_entries*(node: ViewerNode)
proc current_frame*(state: ViewerState): var ViewerFrame
proc current_entries*(state: ViewerState): seq[ViewerEntry]
proc selected_entry*(state: ViewerState): ptr ViewerEntry
proc selected_path_segments*(state: ViewerState): seq[ViewerPathSegment]
proc selected_path*(state: ViewerState): string
proc current_summary*(state: ViewerState): string
proc selected_location*(state: ViewerState): ViewerSourceLocation
proc classify_node*(node: ViewerNode): ViewerColorKind
proc classify_entry*(entry: ViewerEntry): ViewerColorKind
proc current_color*(state: ViewerState): ViewerColorKind
proc clear_type_ahead*(state: ViewerState)
proc clear_quit_pending*(state: ViewerState)
proc request_quit*(state: ViewerState): bool
proc apply_type_ahead*(state: ViewerState, fragment: string, event_time: float, body_height: int)
proc move_selection*(state: ViewerState, delta: int, body_height: int)
proc enter_selected*(state: ViewerState)
proc leave_current*(state: ViewerState)
proc return_to_root*(state: ViewerState)
proc reload*(state: ViewerState)
proc restore_visible_selection*(state: ViewerState, body_height: int)

const TypeAheadResetSeconds = 0.5

func min_int(a, b: int): int {.inline.} =
  if a < b: a else: b

func max_int(a, b: int): int {.inline.} =
  if a > b: a else: b

func is_space(ch: char): bool {.inline.} =
  ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == ','

func is_closer(ch: char): bool {.inline.} =
  ch in {')', ']', '}'}

func is_container(kind: ViewerNodeKind): bool {.inline.} =
  kind in {VnkSequence, VnkArray, VnkMap, VnkGene}

proc new_span(start_pos, stop_pos: int): ViewerSpan {.inline.} =
  ViewerSpan(start: start_pos, stop: stop_pos)

proc synthetic_span(text: string): ViewerSpan {.inline.} =
  ViewerSpan(synthetic: true, text: text, start: 0, stop: text.len)

proc span_text(node: ViewerNode): string =
  if node.span.synthetic:
    return node.span.text
  node.doc.source[node.span.start ..< node.span.stop]

proc span_text(doc: ViewerDocument, span: ViewerSpan): string =
  if span.synthetic:
    return span.text
  doc.source[span.start ..< span.stop]

proc first_non_trivia(source: string, start_pos, stop_pos: int): int =
  var pos = start_pos
  while pos < stop_pos:
    let ch = source[pos]
    case ch
    of ' ', '\t', ',', '\n', '\r':
      inc(pos)
    of '#':
      if pos + 1 >= stop_pos:
        break
      case source[pos + 1]
      of ' ', '!', '#', '\n', '\r':
        pos += 2
        while pos < stop_pos and source[pos] notin {'\n', '\r'}:
          inc(pos)
      of '<':
        var depth = 1
        pos += 2
        while pos < stop_pos and depth > 0:
          if source[pos] == '#' and pos + 1 < stop_pos and source[pos + 1] == '<':
            inc(depth)
            pos += 2
          elif source[pos] == '>' and pos + 1 < stop_pos and source[pos + 1] == '#':
            dec(depth)
            pos += 2
          else:
            inc(pos)
      else:
        break
    else:
      break
  pos

proc collapse_preview(text: string, max_len = 72): string =
  var compact = newStringOfCap(text.len)
  var spacing = false
  for ch in text:
    if ch.isSpaceAscii():
      spacing = compact.len > 0
    else:
      if spacing:
        compact.add(' ')
        spacing = false
      compact.add(ch)
    if compact.len >= max_len + 8:
      break
  result = compact.strip()
  if result.len == 0:
    result = "<empty>"
  elif result.len > max_len:
    result = result[0 ..< max_len - 3] & "..."

proc unescape_symbolish(text: string): string =
  var pos = 0
  while pos < text.len:
    if text[pos] == '\\' and pos + 1 < text.len:
      result.add(text[pos + 1])
      pos += 2
    else:
      result.add(text[pos])
      inc(pos)

proc render_segment(segment: ViewerPathSegment): string =
  case segment.kind
  of VpkIndex:
    $(segment.index + 1)
  of VpkKey:
    segment.name
  of VpkGeneType:
    "type"
  of VpkGeneProp:
    "^" & segment.name

proc display_index(index: int): int {.inline.} =
  index + 1

proc looks_numeric(text: string): bool =
  if text.len == 0:
    return false
  var pos = 0
  if text[pos] in {'+', '-'}:
    inc(pos)
  if pos >= text.len:
    return false

  var has_digit = false
  while pos < text.len:
    let ch = text[pos]
    case ch
    of '0'..'9':
      has_digit = true
    of '.', '_', '/', ':', 'e', 'E':
      discard
    else:
      return false
    inc(pos)
  has_digit

proc is_non_negative_int(text: string): bool =
  if text.len == 0:
    return false
  for ch in text:
    if ch notin {'0'..'9'}:
      return false
  true

proc scalar_color_kind(node: ViewerNode): ViewerColorKind =
  let text = collapse_preview(node.span_text(), max_len = 256).strip()
  if text.len == 0:
    return VckOther
  if text[0] == '"' or text.startsWith("#\""):
    return VckString
  if text in ["nil", "true", "false", "void", "_"] or text[0] == '\'' or looks_numeric(text):
    return VckLiteral
  VckOther

proc kind_from_source(source: string, span: ViewerSpan): ViewerNodeKind =
  if span.synthetic:
    return VnkScalar
  let pos = first_non_trivia(source, span.start, span.stop)
  if pos >= span.stop:
    return VnkScalar
  case source[pos]
  of '[':
    VnkArray
  of '{':
    VnkMap
  of '(':
    VnkGene
  of '#':
    if pos + 1 < span.stop:
      case source[pos + 1]
      of '[':
        VnkArray
      of '{':
        VnkMap
      of '(':
        VnkGene
      else:
        VnkScalar
    else:
      VnkScalar
  else:
    VnkScalar

proc new_node(doc: ViewerDocument, kind: ViewerNodeKind, span: ViewerSpan): ViewerNode =
  ViewerNode(doc: doc, kind: kind, span: span, loaded: false, entries: @[])

proc set_status(state: ViewerState, msg: string) =
  state.status = msg

proc scan_string(source: string, pos: var int, stop_pos: int, prefix = false) =
  if prefix and pos + 1 < stop_pos and source[pos] == '#' and source[pos + 1] == '"':
    pos += 2
  else:
    inc(pos)

  let triple =
    pos + 1 < stop_pos and source[pos - 1] == '"' and source[pos] == '"' and source[pos + 1] == '"'

  if triple:
    pos += 2

  while pos < stop_pos:
    if source[pos] == '\\':
      pos = min_int(pos + 2, stop_pos)
      continue
    if triple:
      if pos + 2 < stop_pos and source[pos] == '"' and source[pos + 1] == '"' and source[pos + 2] == '"':
        pos += 3
        return
    else:
      if source[pos] == '"':
        inc(pos)
        return
    inc(pos)

  raise newException(ViewerError, "Unterminated string literal")

proc scan_char_literal(source: string, pos: var int, stop_pos: int) =
  inc(pos)
  while pos < stop_pos:
    if source[pos] == '\\':
      pos = min_int(pos + 2, stop_pos)
    elif source[pos] == '\'':
      inc(pos)
      return
    else:
      inc(pos)
  raise newException(ViewerError, "Unterminated character literal")

proc scan_atom(source: string, pos: var int, stop_pos: int) =
  while pos < stop_pos:
    let ch = source[pos]
    if ch == '\\' and pos + 1 < stop_pos:
      pos += 2
    elif ch.is_space() or ch.is_closer() or ch in {'(', '[', '{'}:
      return
    else:
      inc(pos)

proc scan_regex(source: string, pos: var int, stop_pos: int) =
  pos += 2
  var closed = false
  while pos < stop_pos:
    if source[pos] == '\\':
      pos = min_int(pos + 2, stop_pos)
    elif source[pos] == '/':
      inc(pos)
      closed = true
      break
    else:
      inc(pos)
  if not closed:
    raise newException(ViewerError, "Unterminated regex literal")

  let replacement_start = pos
  while pos < stop_pos and not source[pos].is_space() and not is_closer(source[pos]):
    if source[pos] == '\\' and pos + 1 < stop_pos:
      pos += 2
    elif source[pos] == '/':
      inc(pos)
      while pos < stop_pos and source[pos] notin {' ', '\t', ',', '\n', '\r', ')', ']', '}'}:
        inc(pos)
      return
    else:
      inc(pos)

  if replacement_start == pos:
    return

proc scan_form(source: string, pos: var int, stop_pos: int)

proc scan_delimited(source: string, pos: var int, stop_pos: int, closer: char) =
  inc(pos)
  while true:
    pos = first_non_trivia(source, pos, stop_pos)
    if pos >= stop_pos:
      raise newException(ViewerError, "Unterminated container")
    if source[pos] == closer:
      inc(pos)
      return
    scan_form(source, pos, stop_pos)

proc scan_form(source: string, pos: var int, stop_pos: int) =
  pos = first_non_trivia(source, pos, stop_pos)
  if pos >= stop_pos:
    raise newException(ViewerError, "Unexpected end of input")

  case source[pos]
  of '[':
    scan_delimited(source, pos, stop_pos, ']')
  of '{':
    scan_delimited(source, pos, stop_pos, '}')
  of '(':
    scan_delimited(source, pos, stop_pos, ')')
  of ')', ']', '}':
    raise newException(ViewerError, "Unmatched delimiter: " & $source[pos])
  of '"':
    scan_string(source, pos, stop_pos)
  of '\'':
    scan_char_literal(source, pos, stop_pos)
  of '`', '%':
    inc(pos)
    scan_form(source, pos, stop_pos)
  of '#':
    if pos + 1 >= stop_pos:
      inc(pos)
      return
    case source[pos + 1]
    of '[':
      inc(pos)
      scan_delimited(source, pos, stop_pos, ']')
    of '{':
      inc(pos)
      scan_delimited(source, pos, stop_pos, '}')
    of '(':
      inc(pos)
      scan_delimited(source, pos, stop_pos, ')')
    of '/':
      scan_regex(source, pos, stop_pos)
    of '"':
      scan_string(source, pos, stop_pos, prefix = true)
    of '@':
      pos += 2
      scan_form(source, pos, stop_pos)
      scan_form(source, pos, stop_pos)
    else:
      scan_atom(source, pos, stop_pos)
  else:
    scan_atom(source, pos, stop_pos)

proc scan_top_level_spans(source: string): seq[ViewerSpan] =
  var pos = 0
  while true:
    pos = first_non_trivia(source, pos, source.len)
    if pos >= source.len:
      break
    let start_pos = pos
    scan_form(source, pos, source.len)
    result.add(new_span(start_pos, pos))

proc opener_length(source: string, span: ViewerSpan): int =
  let pos = first_non_trivia(source, span.start, span.stop)
  if pos < span.stop and source[pos] == '#' and pos + 1 < span.stop and source[pos + 1] in {'[', '{', '('}:
    2
  else:
    1

proc direct_children(source: string, span: ViewerSpan): seq[ViewerSpan] =
  let open_len = opener_length(source, span)
  let open_pos = first_non_trivia(source, span.start, span.stop)
  var pos = open_pos + open_len
  let stop_pos = max_int(open_pos + open_len, span.stop - 1)
  while true:
    pos = first_non_trivia(source, pos, stop_pos)
    if pos >= stop_pos:
      break
    let child_start = pos
    scan_form(source, pos, stop_pos)
    result.add(new_span(child_start, pos))

proc prop_key_info(token: string): tuple[is_prop: bool, implied: bool, value: string, bool_value: string] =
  if token.len >= 2 and token[0] == '^' and token[1] == '^':
    return (true, true, unescape_symbolish(token[2 .. ^1]), "true")
  if token.len >= 2 and token[0] == '^' and token[1] == '!':
    return (true, true, unescape_symbolish(token[2 .. ^1]), "false")
  if token.len >= 1 and token[0] == '^':
    return (true, false, unescape_symbolish(token[1 .. ^1]), "")
  (false, false, "", "")

proc entry_summary(doc: ViewerDocument, span: ViewerSpan, kind: ViewerNodeKind): string =
  let preview = collapse_preview(doc.span_text(span))
  case kind
  of VnkArray, VnkMap, VnkGene:
    preview
  of VnkSequence:
    "Sequence"
  of VnkScalar:
    preview

proc synthetic_scalar_node(doc: ViewerDocument, text: string): ViewerNode =
  new_node(doc, VnkScalar, synthetic_span(text))

proc add_entry(node: ViewerNode, segment: ViewerPathSegment, label: string, child_span: ViewerSpan) =
  let child_kind =
    if child_span.synthetic:
      VnkScalar
    else:
      kind_from_source(node.doc.source, child_span)
  let child = new_node(node.doc, child_kind, child_span)
  node.entries.add(ViewerEntry(
    segment: segment,
    label: label,
    summary: entry_summary(node.doc, child_span, child_kind),
    node: child
  ))

proc ensure_sequence_entries(node: ViewerNode) =
  if node.loaded:
    return
  let spans = scan_top_level_spans(node.doc.source)
  for idx, child_span in spans:
    node.add_entry(
      ViewerPathSegment(kind: VpkIndex, index: idx),
      "[" & $display_index(idx) & "]",
      child_span
    )
  node.loaded = true

proc ensure_array_entries(node: ViewerNode) =
  if node.loaded:
    return
  let children = direct_children(node.doc.source, node.span)
  for idx, child_span in children:
    node.add_entry(
      ViewerPathSegment(kind: VpkIndex, index: idx),
      "[" & $display_index(idx) & "]",
      child_span
    )
  node.loaded = true

proc ensure_map_entries(node: ViewerNode) =
  if node.loaded:
    return
  let items = direct_children(node.doc.source, node.span)
  var pos = 0
  while pos < items.len:
    let key_span = items[pos]
    let key_text = node.doc.span_text(key_span)
    let info = prop_key_info(key_text)
    if not info.is_prop:
      let child = new_node(node.doc, kind_from_source(node.doc.source, key_span), key_span)
      node.entries.add(ViewerEntry(
        segment: ViewerPathSegment(kind: VpkIndex, index: node.entries.len),
        label: "[" & $display_index(node.entries.len) & "]",
        summary: entry_summary(node.doc, key_span, child.kind),
        node: child
      ))
      inc(pos)
      continue

    if info.implied:
      let synthetic = synthetic_scalar_node(node.doc, info.bool_value)
      node.entries.add(ViewerEntry(
        segment: ViewerPathSegment(kind: VpkKey, name: info.value),
        label: "^" & info.value,
        summary: info.bool_value,
        node: synthetic
      ))
      inc(pos)
      continue

    if pos + 1 >= items.len:
      raise newException(ViewerError, "Map entry is missing a value")
    let value_span = items[pos + 1]
    node.add_entry(ViewerPathSegment(kind: VpkKey, name: info.value), "^" & info.value, value_span)
    pos += 2
  node.loaded = true

proc ensure_gene_entries(node: ViewerNode) =
  if node.loaded:
    return
  let items = direct_children(node.doc.source, node.span)
  if items.len == 0:
    node.loaded = true
    return

  node.add_entry(ViewerPathSegment(kind: VpkGeneType), "type", items[0])

  var child_index = 0
  var pos = 1
  while pos < items.len:
    let item_span = items[pos]
    let item_text = node.doc.span_text(item_span)
    let info = prop_key_info(item_text)
    if info.is_prop:
      if info.implied:
        let synthetic = synthetic_scalar_node(node.doc, info.bool_value)
        node.entries.add(ViewerEntry(
          segment: ViewerPathSegment(kind: VpkGeneProp, name: info.value),
          label: "^" & info.value,
          summary: info.bool_value,
          node: synthetic
        ))
        inc(pos)
        continue

      if pos + 1 >= items.len:
        raise newException(ViewerError, "Gene property is missing a value")
      let value_span = items[pos + 1]
      node.add_entry(ViewerPathSegment(kind: VpkGeneProp, name: info.value), "^" & info.value, value_span)
      pos += 2
      continue

    node.add_entry(
      ViewerPathSegment(kind: VpkIndex, index: child_index),
      "[" & $display_index(child_index) & "]",
      item_span
    )
    inc(child_index)
    inc(pos)

  node.loaded = true

proc ensure_entries*(node: ViewerNode) =
  if node == nil or node.loaded:
    return

  case node.kind
  of VnkScalar:
    node.loaded = true
  of VnkSequence:
    ensure_sequence_entries(node)
  of VnkArray:
    ensure_array_entries(node)
  of VnkMap:
    ensure_map_entries(node)
  of VnkGene:
    ensure_gene_entries(node)

proc viewer_root_kind(source: string, spans: seq[ViewerSpan]): tuple[kind: ViewerNodeKind, span: ViewerSpan] =
  if spans.len == 1:
    let kind = kind_from_source(source, spans[0])
    return (kind, spans[0])
  (VnkSequence, synthetic_span(""))

proc open_viewer_document_from_source*(source, file_path: string): ViewerDocument =
  let spans = scan_top_level_spans(source)
  let root_info = viewer_root_kind(source, spans)
  result = ViewerDocument(file_path: file_path, source: source)
  result.root = new_node(result, root_info.kind, root_info.span)
  if root_info.kind == VnkSequence:
    for idx, child_span in spans:
      result.root.add_entry(
        ViewerPathSegment(kind: VpkIndex, index: idx),
        "[" & $display_index(idx) & "]",
        child_span
      )
    result.root.loaded = true

proc open_viewer_document*(file_path: string): ViewerDocument =
  if not fileExists(file_path):
    raise newException(ViewerError, "File not found: " & file_path)
  open_viewer_document_from_source(readFile(file_path), file_path)

proc new_frame(node: ViewerNode): ViewerFrame =
  result = ViewerFrame(node: node, selected: 0, scroll: 0)
  node.ensure_entries()
  if node.entries.len == 0:
    result.selected = -1

proc current_frame*(state: ViewerState): var ViewerFrame =
  state.frames[^1]

proc restore_visible_selection*(state: ViewerState, body_height: int) =
  var frame = addr state.current_frame()
  if frame[].selected < 0:
    frame[].scroll = 0
    return
  if body_height <= 0:
    frame[].scroll = 0
    return
  if frame[].selected < frame[].scroll:
    frame[].scroll = frame[].selected
  elif frame[].selected >= frame[].scroll + body_height:
    frame[].scroll = frame[].selected - body_height + 1

proc new_viewer_state*(doc: ViewerDocument): ViewerState =
  result = ViewerState(
    doc: doc,
    frames: @[new_frame(doc.root)],
    status: "",
    show_help: false,
    type_ahead_query: "",
    last_type_ahead_at: 0.0,
    quit_pending: false
  )
  if doc.root.kind == VnkScalar:
    result.status = "scalar value"
  elif doc.root.kind == VnkSequence and doc.root.entries.len == 0:
    result.status = "empty document"

proc current_entries*(state: ViewerState): seq[ViewerEntry] =
  state.current_frame().node.ensure_entries()
  state.current_frame().node.entries

proc selected_entry*(state: ViewerState): ptr ViewerEntry =
  let entries = state.current_entries()
  let selected = state.current_frame().selected
  if selected < 0 or selected >= entries.len:
    return nil
  addr state.current_frame().node.entries[selected]

proc selected_path_segments*(state: ViewerState): seq[ViewerPathSegment] =
  if state.frames.len == 0:
    return @[]

  for idx in 1 ..< state.frames.len:
    let parent = state.frames[idx - 1]
    if parent.selected >= 0 and parent.selected < parent.node.entries.len:
      result.add(parent.node.entries[parent.selected].segment)

  let current = state.current_frame()
  if current.selected >= 0 and current.selected < current.node.entries.len:
    result.add(current.node.entries[current.selected].segment)

proc selected_path*(state: ViewerState): string =
  let segments = state.selected_path_segments()
  if segments.len == 0:
    return "/"
  result = ""
  for segment in segments:
    result &= "/" & render_segment(segment)

proc current_summary*(state: ViewerState): string =
  let selected = state.selected_entry()
  if selected != nil:
    return selected.summary
  collapse_preview(state.current_frame().node.span_text())

proc location_for_offset(source: string, offset: int): ViewerSourceLocation =
  let stop_at = max_int(0, min_int(source.len, offset))
  result = ViewerSourceLocation(line: 1, column: 1)
  var pos = 0
  while pos < stop_at:
    case source[pos]
    of '\n':
      inc(result.line)
      result.column = 1
      inc(pos)
    of '\r':
      inc(result.line)
      result.column = 1
      if pos + 1 < stop_at and source[pos + 1] == '\n':
        pos += 2
      else:
        inc(pos)
    else:
      inc(result.column)
      inc(pos)

proc selected_location*(state: ViewerState): ViewerSourceLocation =
  let selected = state.selected_entry()
  let node =
    if selected != nil:
      selected[].node
    else:
      state.current_frame().node

  if node.span.synthetic:
    return ViewerSourceLocation(line: 1, column: 1)
  location_for_offset(state.doc.source, node.span.start)

proc classify_node*(node: ViewerNode): ViewerColorKind =
  case node.kind
  of VnkGene:
    VckGene
  of VnkArray, VnkSequence:
    VckArray
  of VnkMap:
    VckMap
  of VnkScalar:
    scalar_color_kind(node)

proc classify_entry*(entry: ViewerEntry): ViewerColorKind =
  classify_node(entry.node)

proc current_color*(state: ViewerState): ViewerColorKind =
  let selected = state.selected_entry()
  if selected != nil:
    return classify_entry(selected[])
  classify_node(state.current_frame().node)

proc clear_type_ahead*(state: ViewerState) =
  state.type_ahead_query = ""
  state.last_type_ahead_at = 0.0

proc clear_quit_pending*(state: ViewerState) =
  state.quit_pending = false

proc request_quit*(state: ViewerState): bool =
  if state.quit_pending:
    state.quit_pending = false
    return true
  state.quit_pending = true
  false

proc find_index_entry(entries: openArray[ViewerEntry], target: int): int =
  if target <= 0:
    return -1
  let internal_target = target - 1
  for idx, entry in entries:
    if entry.segment.kind == VpkIndex and entry.segment.index == internal_target:
      return idx
  -1

proc find_text_entry(entries: openArray[ViewerEntry], query: string): int =
  let needle = query.toLowerAscii()
  for idx, entry in entries:
    if entry.label.toLowerAscii().contains(needle) or entry.summary.toLowerAscii().contains(needle):
      return idx
  -1

proc apply_type_ahead*(state: ViewerState, fragment: string, event_time: float, body_height: int) =
  if fragment.len == 0:
    return
  state.clear_quit_pending()

  let entries = state.current_entries()
  if entries.len == 0:
    return

  let expired =
    state.type_ahead_query.len == 0 or
    event_time < state.last_type_ahead_at or
    event_time - state.last_type_ahead_at > TypeAheadResetSeconds

  if expired:
    state.type_ahead_query = fragment
  else:
    state.type_ahead_query.add(fragment)
  state.last_type_ahead_at = event_time

  let match_index =
    if is_non_negative_int(state.type_ahead_query):
      find_index_entry(entries, parseInt(state.type_ahead_query))
    else:
      find_text_entry(entries, state.type_ahead_query)

  if match_index < 0:
    state.status = "no match: " & state.type_ahead_query
    return

  state.current_frame().selected = match_index
  restore_visible_selection(state, body_height)
  state.status = ""

proc move_selection*(state: ViewerState, delta: int, body_height: int) =
  var frame = addr state.current_frame()
  let entries_len = frame[].node.entries.len
  if entries_len == 0:
    return
  frame[].selected = max_int(0, min_int(entries_len - 1, frame[].selected + delta))
  restore_visible_selection(state, body_height)

proc enter_selected*(state: ViewerState) =
  let selected = state.selected_entry()
  if selected == nil:
    set_status(state, "nothing to enter")
    return
  if not is_container(selected[].node.kind):
    set_status(state, "leaf node")
    return
  state.frames.add(new_frame(selected[].node))
  set_status(state, "")

proc leave_current*(state: ViewerState) =
  if state.frames.len <= 1:
    set_status(state, "already at root")
    return
  state.frames.setLen(state.frames.len - 1)
  set_status(state, "")

proc return_to_root*(state: ViewerState) =
  if state.frames.len <= 1:
    set_status(state, "")
    return
  state.frames.setLen(1)
  set_status(state, "")

proc find_entry_index(node: ViewerNode, segment: ViewerPathSegment): int =
  node.ensure_entries()
  for idx, entry in node.entries:
    if entry.segment.kind != segment.kind:
      continue
    case segment.kind
    of VpkIndex:
      if entry.segment.index == segment.index:
        return idx
    of VpkKey, VpkGeneProp:
      if entry.segment.name == segment.name:
        return idx
    of VpkGeneType:
      return idx
  -1

proc reload*(state: ViewerState) =
  let path = state.selected_path_segments()
  let bodyless = 1
  state.clear_type_ahead()
  state.clear_quit_pending()
  state.doc = open_viewer_document(state.doc.file_path)
  state.frames = @[new_frame(state.doc.root)]

  var current = 0
  while current < path.len:
    let segment = path[current]
    let node = state.current_frame().node
    let idx = find_entry_index(node, segment)
    if idx < 0:
      break
    state.current_frame().selected = idx
    let child = node.entries[idx].node
    if current < path.high and is_container(child.kind):
      state.frames.add(new_frame(child))
    else:
      break
    inc(current)

  restore_visible_selection(state, bodyless)
  set_status(state, "reloaded")

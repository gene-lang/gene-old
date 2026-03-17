import strutils

import ./model
import ./curses_backend

const FooterLegend = "F1 Help  F5 Reload  F10 Quit"

func entry_is_container(entry: ViewerEntry): bool =
  entry.node.kind in {VnkSequence, VnkArray, VnkMap, VnkGene}

func viewer_color(kind: ViewerColorKind): ViewerColor =
  case kind
  of VckGene:
    VcGene
  of VckArray:
    VcArray
  of VckMap:
    VcMap
  of VckString:
    VcString
  of VckLiteral:
    VcLiteral
  of VckOther:
    VcOther

proc draw_header(state: ViewerState, width: int) =
  draw_text(0, 0, width, "File: " & state.doc.file_path)
  draw_text(1, 0, width, "Path: " & state.selected_path())

proc draw_footer(state: ViewerState, height, width: int) =
  draw_text(height - 2, 0, width, state.current_summary(), color = viewer_color(state.current_color()))
  let status_text =
    if state.status.len > 0:
      state.status
    else:
      FooterLegend
  draw_text(height - 1, 0, width, status_text)

proc draw_help(height, width: int) =
  let lines = @[
    "Arrow Up/Down: move selection",
    "Page Up/Down: move one screen",
    "Arrow Right or Enter: enter selected container",
    "Arrow Left: return to parent container",
    "F5: reload file from disk",
    "F10: quit viewer",
    "? or F1: toggle this help"
  ]
  let start_row = 3
  for idx, line in lines:
    if start_row + idx >= height - 2:
      break
    draw_text(start_row + idx, 0, width, line)

proc draw_leaf(state: ViewerState, height, width: int) =
  draw_text(3, 0, width, state.current_summary(), color = viewer_color(state.current_color()))

proc draw_entries(state: ViewerState, height, width: int) =
  let body_top = 3
  let body_height = max(1, height - 5)
  state.restore_visible_selection(body_height)
  let frame = state.current_frame()
  let start_idx = max(0, frame.scroll)
  let stop_idx = min(frame.node.entries.len, start_idx + body_height)
  var row = body_top
  for idx in start_idx ..< stop_idx:
    let entry = frame.node.entries[idx]
    let marker = if entry_is_container(entry): ">" else: " "
    let prefix = entry.label.alignLeft(12) & " " & marker & " "
    draw_text(row, 0, min(width, prefix.len), prefix, highlighted = idx == frame.selected)
    draw_text(
      row,
      prefix.len,
      max(0, width - prefix.len),
      entry.summary,
      highlighted = idx == frame.selected,
      color = viewer_color(classify_entry(entry))
    )
    inc(row)

proc render(state: ViewerState) =
  let height = terminal_height()
  let width = terminal_width()
  clear_screen()
  draw_header(state, width)
  if state.show_help:
    draw_help(height, width)
  elif state.current_frame().node.entries.len == 0:
    draw_leaf(state, height, width)
  else:
    draw_entries(state, height, width)
  draw_footer(state, height, width)
  present()

proc handle_key*(state: ViewerState, key: ViewerKey, body_height: int): bool =
  case key
  of VkUp:
    state.move_selection(-1, body_height)
  of VkDown:
    state.move_selection(1, body_height)
  of VkPageUp:
    state.move_selection(-max(1, body_height), body_height)
  of VkPageDown:
    state.move_selection(max(1, body_height), body_height)
  of VkRight, VkEnter:
    state.enter_selected()
  of VkLeft:
    state.leave_current()
  of VkF1, VkHelp:
    state.show_help = not state.show_help
    state.status = ""
  of VkF5:
    state.reload()
  of VkF10, VkQuit:
    return false
  of VkResize, VkNone:
    discard
  true

proc run_viewer*(doc: ViewerDocument) =
  var session = open_session()
  defer:
    close_session(session)

  let state = new_viewer_state(doc)
  render(state)
  while true:
    if not state.handle_key(read_key(), max(1, terminal_height() - 5)):
      break
    render(state)

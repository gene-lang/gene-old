import strutils, times

import ./model
import ./curses_backend
import ./editor

const FooterLegend = "Esc Root  F1 Help  F2 Edit  F5 Reload  F10 Quit"
const InlineEditLegend = "Enter Save  Esc Cancel  Backspace Delete"

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
  if state.is_inline_editing():
    draw_text(height - 2, 0, width, "Edit> " & state.inline_edit_buffer())
  else:
    draw_text(height - 2, 0, width, state.current_summary(), color = viewer_color(state.current_color()))
  let status_text =
    if state.status.len > 0:
      state.status
    elif state.is_inline_editing():
      InlineEditLegend
    else:
      FooterLegend
  draw_text(height - 1, 0, width, status_text)

proc draw_help(height, width: int) =
  let lines = @[
    "Arrow Up/Down: move selection",
    "Page Up/Down: move one screen",
    "Arrow Right or Enter: enter selected container",
    "Arrow Left: return to parent container",
    "Esc: return to root container",
    "Tab: edit selected scalar inline",
    "Type digits/text: jump by index or substring",
    "F2 or Ctrl-E: open file in external editor",
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

proc edit_current(state: ViewerState, session: var CursesSession) =
  let location = state.selected_location()
  close_session(session)

  var exit_code = 0
  var launch_error = ""
  try:
    exit_code = launch_external_editor(state.doc.file_path, location.line, location.column)
  except CatchableError as e:
    launch_error = e.msg

  session = open_session()

  if launch_error.len > 0:
    state.status = "edit failed: " & launch_error
    return

  try:
    state.reload()
    if exit_code == 0:
      state.status = "edited and reloaded"
    else:
      state.status = "editor exited with status " & $exit_code & "; reloaded"
  except CatchableError as e:
    state.status = "reload failed: " & e.msg

proc handle_key*(state: ViewerState, key: ViewerKey, body_height: int): bool =
  if key notin {VkNone, VkResize, VkQuit}:
    state.clear_type_ahead()
    state.clear_quit_pending()
    state.status = ""
  case key
  of VkTab:
    discard state.start_inline_edit()
  of VkEscape:
    state.return_to_root()
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
  of VkF2:
    discard
  of VkF5:
    state.reload()
  of VkF10:
    return false
  of VkQuit:
    state.clear_type_ahead()
    if state.request_quit():
      return false
    state.status = "Press Ctrl-C again to exit"
  of VkBackspace, VkResize, VkNone:
    discard
  true

proc handle_inline_edit_input(state: ViewerState, input: ViewerInput, body_height: int): bool =
  if input.text.len > 0:
    state.append_inline_edit(input.text)
    return true

  case input.key
  of VkBackspace:
    state.backspace_inline_edit()
  of VkEnter:
    discard state.save_inline_edit()
  of VkEscape:
    state.cancel_inline_edit()
  of VkQuit, VkF10:
    return state.handle_key(input.key, body_height)
  else:
    discard
  true

proc run_viewer*(doc: ViewerDocument) =
  var session = open_session()
  defer:
    close_session(session)

  let state = new_viewer_state(doc)
  render(state)
  while true:
    let input = read_input()
    let body_height = max(1, terminal_height() - 5)
    if state.is_inline_editing():
      if not handle_inline_edit_input(state, input, body_height):
        break
    elif input.text.len > 0:
      state.apply_type_ahead(input.text, epochTime(), body_height)
    elif input.key == VkF2:
      state.clear_type_ahead()
      edit_current(state, session)
    elif not state.handle_key(input.key, body_height):
      break
    render(state)

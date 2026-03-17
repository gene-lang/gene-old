import os, strutils, unittest

import gene/viewer/app
import gene/viewer/curses_backend
import gene/viewer/editor
import gene/viewer/model

suite "Terminal Gene Viewer Model":
  test "multi-form input becomes a synthetic root sequence":
    let source = """
      # comment
      (log ^level "info" ^msg "ready")
      [1 {^inner [2 3]}]
      {^status true}
    """
    let doc = open_viewer_document_from_source(source, "logs/sample.gene")
    let state = new_viewer_state(doc)

    check doc.root.kind == VnkSequence
    check doc.root.entries.len == 3
    check state.selected_path() == "/1"
    check doc.root.entries[0].summary.contains("(log")
    check doc.root.entries[1].node.kind == VnkArray
    check doc.root.entries[2].node.kind == VnkMap
    check classify_entry(doc.root.entries[0]) == VckGene
    check classify_entry(doc.root.entries[1]) == VckArray
    check classify_entry(doc.root.entries[2]) == VckMap

  test "navigation drills into nested values and restores parent selection":
    let source = """
      (root
        ^meta {^name "demo" ^enabled true}
        [10 {^leaf [1 2]}]
        ^flag true
      )
    """
    let doc = open_viewer_document_from_source(source, "nested.gene")
    let state = new_viewer_state(doc)

    check doc.root.kind == VnkGene
    check state.current_frame().node.entries.len == 4
    check state.selected_path() == "/type"

    state.move_selection(2, 10)
    check state.selected_path() == "/1"

    state.enter_selected()
    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/1/1"

    state.move_selection(1, 10)
    check state.selected_path() == "/1/2"

    state.enter_selected()
    check state.frames.len == 3
    check state.current_frame().node.kind == VnkMap
    check state.selected_path() == "/1/2/leaf"

    state.enter_selected()
    check state.frames.len == 4
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/1/2/leaf/1"

    state.leave_current()
    check state.frames.len == 3
    check state.current_frame().selected == 0
    check state.selected_path() == "/1/2/leaf"

    state.leave_current()
    check state.frames.len == 2
    check state.current_frame().selected == 1
    check state.selected_path() == "/1/2"

  test "reload preserves the deepest still-valid selection path":
    let source_path = absolutePath("tmp/viewer_reload.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "[1 [2 3] 4]")

    defer:
      if fileExists(source_path):
        removeFile(source_path)

    let doc = open_viewer_document(source_path)
    let state = new_viewer_state(doc)
    state.move_selection(1, 10)
    state.enter_selected()
    state.move_selection(1, 10)
    check state.selected_path() == "/2/2"

    writeFile(source_path, "[1 [2 3 4] 5]")
    state.reload()

    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/2/2"

  test "scalar values classify into string literal and other buckets":
    let source = """
      ["hello" 42 true symbol #/x/]
    """
    let doc = open_viewer_document_from_source(source, "colors.gene")
    let state = new_viewer_state(doc)

    check state.current_frame().node.entries.len == 5
    check classify_entry(state.current_frame().node.entries[0]) == VckString
    check classify_entry(state.current_frame().node.entries[1]) == VckLiteral
    check classify_entry(state.current_frame().node.entries[2]) == VckLiteral
    check classify_entry(state.current_frame().node.entries[3]) == VckOther
    check classify_entry(state.current_frame().node.entries[4]) == VckOther

  test "enter key opens expandable item":
    let source = """
      (root [1 2] {^name "Ada"})
    """
    let doc = open_viewer_document_from_source(source, "enter.gene")
    let state = new_viewer_state(doc)

    state.move_selection(1, 10)
    check state.selected_path() == "/1"

    check state.handle_key(VkEnter, 10)
    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/1/1"

  test "page up and down move by the visible body height":
    var items: seq[string] = @[]
    for i in 0 .. 19:
      items.add($i)
    let source = "[" & items.join(" ") & "]"
    let doc = open_viewer_document_from_source(source, "paging.gene")
    let state = new_viewer_state(doc)

    check state.selected_path() == "/1"
    check state.handle_key(VkPageDown, 5)
    check state.selected_path() == "/6"
    check state.current_frame().scroll == 1

    check state.handle_key(VkPageDown, 5)
    check state.selected_path() == "/11"
    check state.current_frame().scroll == 6

    check state.handle_key(VkPageUp, 5)
    check state.selected_path() == "/6"
    check state.current_frame().scroll == 5

  test "escape returns to the root container and preserves root selection":
    let source = """
      (root
        ^meta {^name "demo" ^enabled true}
        [10 {^leaf [1 2]}]
        ^flag true
      )
    """
    let doc = open_viewer_document_from_source(source, "escape_root.gene")
    let state = new_viewer_state(doc)

    state.move_selection(2, 10)
    state.enter_selected()
    state.move_selection(1, 10)
    check state.selected_path() == "/1/2"

    check state.handle_key(VkEscape, 10)
    check state.frames.len == 1
    check state.selected_path() == "/1"

  test "ctrl-e is treated as edit input":
    check classify_input(5).key == VkF2

  test "ctrl-c requires confirmation before exit":
    let doc = open_viewer_document_from_source("[1 2 3]", "quit_confirm.gene")
    let state = new_viewer_state(doc)

    check state.handle_key(VkQuit, 10)
    check state.status == "Press Ctrl-C again to exit"

    check not state.handle_key(VkQuit, 10)

  test "non-quit navigation clears pending ctrl-c confirmation":
    let doc = open_viewer_document_from_source("[1 2 3]", "quit_reset.gene")
    let state = new_viewer_state(doc)

    check state.handle_key(VkQuit, 10)
    check state.handle_key(VkDown, 10)
    check state.selected_path() == "/2"
    check state.handle_key(VkQuit, 10)
    check state.status == "Press Ctrl-C again to exit"

  test "selected location tracks the focused node start offset":
    let source = "(root\n  ^meta {^name \"demo\"}\n  [10 20]\n)\n"
    let doc = open_viewer_document_from_source(source, "location.gene")
    let state = new_viewer_state(doc)

    check state.selected_location() == ViewerSourceLocation(line: 1, column: 2)

    state.move_selection(2, 10)
    check state.selected_path() == "/1"
    check state.selected_location() == ViewerSourceLocation(line: 3, column: 3)

  test "editor command parsing and launch args preserve editor flags":
    let editor = parse_editor_command("nvim -u NONE")
    check editor.command == "nvim"
    check editor.args == @["-u", "NONE"]
    check editor_launch_args(editor, "tmp/sample.gene", 12, 7) ==
      @["-u", "NONE", "+call cursor(12,7)", "tmp/sample.gene"]

  test "generic editors open the file without vim cursor commands":
    let editor = EditorCommand(command: "nano", args: @["--view"])
    check editor_launch_args(editor, "tmp/sample.gene", 4, 2) ==
      @["--view", "tmp/sample.gene"]

  test "numeric type-ahead jumps to indexed children and extends within timeout":
    var items: seq[string] = @[]
    for i in 0 .. 19:
      items.add($i)
    let source = "[" & items.join(" ") & "]"
    let doc = open_viewer_document_from_source(source, "numeric_jump.gene")
    let state = new_viewer_state(doc)

    state.apply_type_ahead("1", 1.0, 5)
    check state.selected_path() == "/1"

    state.apply_type_ahead("2", 1.3, 5)
    check state.selected_path() == "/12"
    check state.current_frame().scroll == 7

  test "text type-ahead matches summaries and resets after timeout":
    let source = """["alpha" "abacus" "beta"]"""
    let doc = open_viewer_document_from_source(source, "text_jump.gene")
    let state = new_viewer_state(doc)

    state.apply_type_ahead("a", 2.0, 5)
    check state.selected_path() == "/1"

    state.apply_type_ahead("b", 2.3, 5)
    check state.selected_path() == "/2"

    state.apply_type_ahead("e", 3.0, 5)
    check state.selected_path() == "/3"

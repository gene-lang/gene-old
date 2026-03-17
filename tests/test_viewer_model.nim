import os, strutils, unittest

import gene/viewer/app
import gene/viewer/curses_backend
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
    check state.selected_path() == "/0"
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
    check state.selected_path() == "/0"

    state.enter_selected()
    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/0/0"

    state.move_selection(1, 10)
    check state.selected_path() == "/0/1"

    state.enter_selected()
    check state.frames.len == 3
    check state.current_frame().node.kind == VnkMap
    check state.selected_path() == "/0/1/leaf"

    state.enter_selected()
    check state.frames.len == 4
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/0/1/leaf/0"

    state.leave_current()
    check state.frames.len == 3
    check state.current_frame().selected == 0
    check state.selected_path() == "/0/1/leaf"

    state.leave_current()
    check state.frames.len == 2
    check state.current_frame().selected == 1
    check state.selected_path() == "/0/1"

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
    check state.selected_path() == "/1/1"

    writeFile(source_path, "[1 [2 3 4] 5]")
    state.reload()

    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/1/1"

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
    check state.selected_path() == "/0"

    check state.handle_key(VkEnter, 10)
    check state.frames.len == 2
    check state.current_frame().node.kind == VnkArray
    check state.selected_path() == "/0/0"

  test "page up and down move by the visible body height":
    var items: seq[string] = @[]
    for i in 0 .. 19:
      items.add($i)
    let source = "[" & items.join(" ") & "]"
    let doc = open_viewer_document_from_source(source, "paging.gene")
    let state = new_viewer_state(doc)

    check state.selected_path() == "/0"
    check state.handle_key(VkPageDown, 5)
    check state.selected_path() == "/5"
    check state.current_frame().scroll == 1

    check state.handle_key(VkPageDown, 5)
    check state.selected_path() == "/10"
    check state.current_frame().scroll == 6

    check state.handle_key(VkPageUp, 5)
    check state.selected_path() == "/5"
    check state.current_frame().scroll == 5

import unittest, os, strutils
import std/tables

import gene/types except Exception
import gene/vm

import ../helpers

suite ".gdat":
  test "gdat save/load roundtrip":
    init_all()
    let path = getTempDir() / "gene_test_gdat_roundtrip.gdat"
    if fileExists(path):
      removeFile(path)
    defer:
      if fileExists(path):
        removeFile(path)

    let escaped_path = path.replace("\\", "\\\\")
    let code =
      "(var data {^users [{^name \"Alice\" ^age 30} {^name \"Bob\" ^age 25}]})\n" &
      "(gdat/save data \"" & escaped_path & "\")\n" &
      "(gdat/load \"" & escaped_path & "\")"

    let result = VM.exec(code, "test_code")
    check result.kind == VkMap
    check map_data(result).hasKey("users".to_key())

    let users = map_data(result)["users".to_key()]
    check users.kind == VkArray
    check array_data(users).len == 2
    check map_data(array_data(users)[0])["name".to_key()] == "Alice".to_value()
    check map_data(array_data(users)[1])["name".to_key()] == "Bob".to_value()

  test "gdat header is written":
    init_all()
    let path = getTempDir() / "gene_test_gdat_header.gdat"
    if fileExists(path):
      removeFile(path)
    defer:
      if fileExists(path):
        removeFile(path)

    let escaped_path = path.replace("\\", "\\\\")
    let code =
      "(gdat/save {^ok true} \"" & escaped_path & "\")"
    discard VM.exec(code, "test_code")

    let content = readFile(path)
    check content.startsWith("#< gdat 1.0 >#\n")

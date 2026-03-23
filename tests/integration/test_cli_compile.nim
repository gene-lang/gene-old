import unittest, json, os

import commands/compile as compile_command
import gene/types except Exception

proc find_callable(metadata: JsonNode, name: string): JsonNode =
  if metadata.kind != JObject or not metadata.hasKey("callables"):
    return nil
  for item in metadata["callables"].items:
    if item.kind == JObject and item.hasKey("name") and item["name"].getStr() == name:
      return item
  nil

proc descriptor_matches(metadata: JsonNode, type_id: int, kind: string, name: string): bool =
  if metadata.kind != JObject or not metadata.hasKey("type_descriptors"):
    return false
  for desc in metadata["type_descriptors"].items:
    if desc.kind != JObject:
      continue
    if desc["id"].getInt() != type_id:
      continue
    if desc["kind"].getStr() != kind:
      continue
    if name.len == 0:
      return true
    if desc.hasKey("name") and desc["name"].getStr() == name:
      return true
  false

suite "Compile CLI":
  test "compile ai-metadata exports typed callable signatures":
    let result = compile_command.handle("compile", @[
      "--format:ai-metadata",
      "--eval:(fn add [a: Int b: Int] -> Int (a + b))"
    ])
    check result.success
    check result.output.len > 0

    let metadata = parseJson(result.output)
    check metadata["format"].getStr() == "ai-metadata"

    let callable = find_callable(metadata, "add")
    check callable != nil
    check callable["typed"].getBool()
    check callable["param_type_ids"].len == 2
    check callable["return_type_id"].getInt() != int(NO_TYPE_ID)
    for param_type_id in callable["param_type_ids"].items:
      check param_type_id.getInt() != int(NO_TYPE_ID)

    let first_param_type_id = callable["param_type_ids"][0].getInt()
    check descriptor_matches(metadata, first_param_type_id, "named", "Int")

  test "compile ai-metadata distinguishes typed and untyped callables":
    let source_path = absolutePath("tmp/compile_ai_metadata_mixed.gene")
    createDir(parentDir(source_path))
    writeFile(source_path, "(fn typed [x: Int] -> Int x)\n(fn raw [x] x)\n")

    defer:
      if fileExists(source_path):
        removeFile(source_path)

    let result = compile_command.handle("compile", @[
      "--format:ai-metadata",
      source_path
    ])
    check result.success
    check result.output.len > 0

    let metadata = parseJson(result.output)
    let typed_callable = find_callable(metadata, "typed")
    let raw_callable = find_callable(metadata, "raw")

    check typed_callable != nil
    check raw_callable != nil
    check typed_callable["typed"].getBool()
    check typed_callable["return_type_id"].getInt() != int(NO_TYPE_ID)
    check raw_callable["typed"].getBool() == false
    check raw_callable["return_type_id"].getInt() == int(NO_TYPE_ID)
    check raw_callable["param_type_ids"].len == 1
    check raw_callable["param_type_ids"][0].getInt() == int(NO_TYPE_ID)

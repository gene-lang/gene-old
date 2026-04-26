import unittest, tables, strutils

import gene/types except Exception
import gene/vm

import ../helpers

proc expect_enum_error(code: string, expected_message_part: string) =
  init_all()
  try:
    discard VM.exec(cleanup(code), "test_code")
    fail()
  except CatchableError as err:
    check err.msg.contains(expected_message_part)

# Tests for enum construct
# Most enum functionality is not yet implemented in our VM
# These tests are commented out until those features are available:

test_vm """
  (enum Color red green blue)
  Color/red
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "red"
  check r.ref.enum_member.value == 0

test_vm """
  (enum Status ^values [ok error pending])
  Status/ok
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "ok"
  check r.ref.enum_member.value == 0

test_vm """
  (enum Result:T:E
    (Ok value: T)
    (Err error: E)
    Empty)
  Result
""", proc(r: Value) =
  check r.kind == VkEnum
  let enum_def = r.ref.enum_def
  check enum_def.name == "Result"
  check enum_def.type_params == @["T", "E"]
  check enum_def.members.len == 3
  check enum_def.members.hasKey("Ok")
  check enum_def.members.hasKey("Err")
  check enum_def.members.hasKey("Empty")

  let ok = enum_def.members["Ok"]
  check ok.name == "Ok"
  check ok.value == 0
  check ok.fields == @["value"]
  check ok.field_type_ids.len == 1
  check ok.field_type_ids[0] != NO_TYPE_ID
  check ok.field_type_descs.len > ok.field_type_ids[0]
  check ok.field_type_descs[ok.field_type_ids[0]].kind == TdkVar
  check ok.field_type_descs[ok.field_type_ids[0]].var_id == 0

  let err = enum_def.members["Err"]
  check err.fields == @["error"]
  check err.field_type_ids.len == 1
  check err.field_type_ids[0] != NO_TYPE_ID
  check err.field_type_descs.len > err.field_type_ids[0]
  check err.field_type_descs[err.field_type_ids[0]].kind == TdkVar
  check err.field_type_descs[err.field_type_ids[0]].var_id == 1

  let empty = enum_def.members["Empty"]
  check empty.fields.len == 0
  check empty.field_type_ids.len == 0

test_vm """
  (enum Shape Point)
  (var Point Shape/Point)
  (Point)
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "Point"

test_vm """
  (enum Shape Point)
  (Shape/Point)
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "Point"

test_vm """
  (enum Shape (Circle radius))
  (var Circle Shape/Circle)
  (Circle 5)
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Circle"
  check r.ref.ev_data == @[5.to_value()]

test_vm """
  (enum Shape (Rect width height))
  (var Rect Shape/Rect)
  (Rect 10 20)
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Rect"
  check r.ref.ev_data == @[10.to_value(), 20.to_value()]

test "enum payload constructor diagnostics use qualified variant names":
  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (var Circle Shape/Circle)
    (Circle)
  """, "Variant Shape/Circle expects 1 arguments (radius), got 0")

  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (var Circle Shape/Circle)
    (Circle 1 2)
  """, "Variant Shape/Circle expects 1 arguments (radius), got 2")

  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (Shape/Rect 10)
  """, "Variant Shape/Rect expects 2 arguments (width, height), got 1")

  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (var Point Shape/Point)
    (Point 1)
  """, "Unit variant Shape/Point expects 0 arguments, got 1")

test "enum declarations reject malformed syntax with targeted diagnostics":
  expect_enum_error("""
    (enum Bad:T:T (Value value))
  """, "duplicate generic parameter T")

  expect_enum_error("""
    (enum Bad:t (Value value))
  """, "invalid generic parameter syntax")

  expect_enum_error("""
    (enum Bad One One)
  """, "duplicate variant One")

  expect_enum_error("""
    (enum Bad (Full value value))
  """, "duplicate field value")

  expect_enum_error("""
    (enum Bad (Full value:))
  """, "missing a type after ':'")

  expect_enum_error("""
    (enum Bad 123)
  """, "enum member must be a symbol or data variant")

  expect_enum_error("""
    (enum Bad:T (Full value: 123))
  """, "invalid type annotation")

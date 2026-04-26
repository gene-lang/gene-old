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

proc expect_var_payload_field(member: EnumMember, field_name: string, expected_var_id: int32) =
  check member.fields == @[field_name]
  check member.field_type_ids.len == 1
  if member.field_type_ids.len == 1:
    let field_type_id = member.field_type_ids[0]
    check field_type_id != NO_TYPE_ID
    if field_type_id != NO_TYPE_ID:
      check field_type_id.int >= 0
      check member.field_type_descs.len > field_type_id.int
      if field_type_id.int >= 0 and member.field_type_descs.len > field_type_id.int:
        let desc = member.field_type_descs[field_type_id.int]
        check desc.kind == TdkVar
        if desc.kind == TdkVar:
          check desc.var_id == expected_var_id

proc expect_enum_value(r: Value, enum_name: string, member_name: string, data: seq[Value]) =
  check r.kind == VkEnumValue
  if r.kind == VkEnumValue:
    let variant = r.ref.ev_variant
    check variant.kind == VkEnumMember
    if variant.kind == VkEnumMember:
      let member = variant.ref.enum_member
      check member.parent.ref.enum_def.name == enum_name
      check member.name == member_name
    check r.ref.ev_data == data

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

test "built-in Result and Option expose canonical generic enum metadata":
  init_all()

  let result_val = App.app.result_enum
  check result_val.kind == VkEnum
  let result_def = result_val.ref.enum_def
  check result_def.name == "Result"
  check result_def.type_params == @["T", "E"]
  check result_def.members.len == 2
  check result_def.members.hasKey("Ok")
  check result_def.members.hasKey("Err")

  if result_def.members.hasKey("Ok"):
    let ok = result_def.members["Ok"]
    check ok.name == "Ok"
    check ok.value == 0
    expect_var_payload_field(ok, "value", 0)

  if result_def.members.hasKey("Err"):
    let err = result_def.members["Err"]
    check err.name == "Err"
    check err.value == 1
    expect_var_payload_field(err, "error", 1)

  let option_val = App.app.option_enum
  check option_val.kind == VkEnum
  let option_def = option_val.ref.enum_def
  check option_def.name == "Option"
  check option_def.type_params == @["T"]
  check option_def.members.len == 2
  check option_def.members.hasKey("Some")
  check option_def.members.hasKey("None")

  if option_def.members.hasKey("Some"):
    let some = option_def.members["Some"]
    check some.name == "Some"
    check some.value == 0
    expect_var_payload_field(some, "value", 0)

  if option_def.members.hasKey("None"):
    let none_member = option_def.members["None"]
    check none_member.name == "None"
    check none_member.value == 1
    check none_member.fields.len == 0
    check none_member.field_type_ids.len == 0

  let global_ns = App.app.global_ns.ns
  check global_ns["Result".to_key()] == result_val
  check global_ns["Option".to_key()] == option_val
  check global_ns["Ok".to_key()].kind == VkEnumMember
  check global_ns["Ok".to_key()].ref.enum_member == result_def.members["Ok"]
  check global_ns["Err".to_key()].kind == VkEnumMember
  check global_ns["Err".to_key()].ref.enum_member == result_def.members["Err"]
  check global_ns["Some".to_key()].kind == VkEnumMember
  check global_ns["Some".to_key()].ref.enum_member == option_def.members["Some"]
  check global_ns["None".to_key()].kind == VkEnumMember
  check global_ns["None".to_key()].ref.enum_member == option_def.members["None"]

test_vm """
  (Ok ^value 5)
""", proc(r: Value) =
  expect_enum_value(r, "Result", "Ok", @[5.to_value()])

test_vm """
  (Result/Err ^error "bad")
""", proc(r: Value) =
  expect_enum_value(r, "Result", "Err", @[
    "bad".to_value()
  ])

test_vm """
  (Option/Some ^value "hello")
""", proc(r: Value) =
  expect_enum_value(r, "Option", "Some", @[
    "hello".to_value()
  ])

test_vm """
  (Option/None)
""", proc(r: Value) =
  check r.kind == VkEnumMember
  if r.kind == VkEnumMember:
    check r.ref.enum_member.parent.ref.enum_def.name == "Option"
    check r.ref.enum_member.name == "None"

test "built-in Result/Option constructors use ordinary enum constructor diagnostics":
  expect_enum_error("""
    (Ok 1 2)
  """, "Variant Result/Ok expects 1 arguments (value), got 2")

  expect_enum_error("""
    (Ok)
  """, "Variant Result/Ok expects 1 arguments (value), got 0")

  expect_enum_error("""
    (Result/Ok ^error "bad")
  """, "Variant Result/Ok got unknown keyword argument(s): error; expected fields: value")

  expect_enum_error("""
    (Err 1 ^error "bad")
  """, "Variant Result/Err cannot mix positional and keyword arguments")

  expect_enum_error("""
    (Err ^value "bad")
  """, "Variant Result/Err got unknown keyword argument(s): value; expected fields: error")

  expect_enum_error("""
    (None 1)
  """, "Unit variant Option/None expects 0 arguments, got 1")

  expect_enum_error("""
    (Option/None ^value 1)
  """, "Unit variant Option/None expects 0 keyword arguments, got: value")

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

test_vm """
  (enum Shape (Rect width height))
  (var Rect Shape/Rect)
  (Rect ^height 20 ^width 10)
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Rect"
  check r.ref.ev_data == @[10.to_value(), 20.to_value()]

test_vm """
  (enum Shape (Rect width height))
  (Shape/Rect ^height 20 ^width 10)
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Rect"
  check r.ref.ev_data == @[10.to_value(), 20.to_value()]

proc expect_enum_error_parts(code: string, expected_message_parts: openArray[string]) =
  init_all()
  try:
    discard VM.exec(cleanup(code), "test_code")
    fail()
  except CatchableError as err:
    for expected_message_part in expected_message_parts:
      check err.msg.contains(expected_message_part)

test "enum typed payload constructors validate concrete field annotations":
  expect_enum_error_parts("""
    (enum Metric (Counter value: Int))
    (var Counter Metric/Counter)
    (Counter "bad")
  """, ["Type error [GENE_TYPE_MISMATCH]", "field Metric/Counter.value"])

  expect_enum_error_parts("""
    (enum Metric (Counter value: Int))
    (var Counter Metric/Counter)
    (Counter ^value "bad")
  """, ["Type error [GENE_TYPE_MISMATCH]", "field Metric/Counter.value"])

test_vm """
  (enum Bag (Item value))
  (Bag/Item "free")
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Item"
  check r.ref.ev_data == @["free".to_value()]

test_vm """
  (enum Box:T (Item value: T))
  (Box/Item "free")
""", proc(r: Value) =
  check r.kind == VkEnumValue
  check r.ref.ev_variant.ref.enum_member.name == "Item"
  check r.ref.ev_data == @["free".to_value()]

test "enum keyword payload constructor diagnostics name fields and call shape":
  expect_enum_error("""
    (enum Shape (Rect width height))
    (var Rect Shape/Rect)
    (Rect ^width 10)
  """, "Variant Shape/Rect missing keyword argument(s): height; expected fields: width, height")

  expect_enum_error("""
    (enum Shape (Rect width height))
    (var Rect Shape/Rect)
    (Rect ^width 10 ^height 20 ^depth 30)
  """, "Variant Shape/Rect got unknown keyword argument(s): depth; expected fields: width, height")

  expect_enum_error("""
    (enum Shape (Rect width height))
    (var Rect Shape/Rect)
    (Rect 10 ^height 20)
  """, "Variant Shape/Rect cannot mix positional and keyword arguments")

  expect_enum_error("""
    (enum Shape Point)
    (var Point Shape/Point)
    (Point ^x 1)
  """, "Unit variant Shape/Point expects 0 keyword arguments, got: x")

  expect_enum_error("""
    (enum Shape (Rect width height))
    (var Rect Shape/Rect)
    (Rect ^width 10 ^width 11 ^height 20)
  """, "conflict with property shortcut found earlier")

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

test_vm """
  (enum Shape (Circle radius) (Rect width height) Point)
  (var circle (Shape/Circle 7))
  (var rect (Shape/Rect 10 20))
  (var point Shape/Point)
  [
    (case circle
      when (Shape/Circle r) r
      when (Shape/Rect w h) (w + h)
      when Shape/Point 0
      else -1)
    (case rect
      when (Shape/Circle r) r
      when (Shape/Rect w h) (w + h)
      when Shape/Point 0
      else -1)
    (case point
      when (Shape/Circle r) r
      when (Shape/Rect w h) (w + h)
      when Shape/Point 99
      else -1)
  ]
""", proc(r: Value) =
  check r == @[7, 30, 99].to_value()

test_vm """
  (enum Shape (Circle radius) (Rect width height) Point)
  (enum Shadow (Ok value))
  (var Circle Shape/Circle)
  (var shadow (Shadow/Ok "shadow"))
  (var miss (Shape/Circle 1))
  (var rect (Shape/Rect 10 20))
  [
    (case shadow
      when (Ok v) 1
      else 2)
    (case miss
      when (Shape/Rect w h) (w + h)
      else 3)
    (case rect
      when (Shape/Rect _ h) h
      else -1)
    (case (Circle 7)
      when (Circle r) r
      else -1)
  ]
""", proc(r: Value) =
  check r == @[2, 3, 20, 7].to_value()

test "enum variant case patterns validate declared arity with field names":
  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (var rect (Shape/Rect 10 20))
    (case rect
      when (Shape/Rect w) w
      else -1)
  """, "variant Shape/Rect pattern expects 2 binding(s) (width, height), got 1")

  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (var rect (Shape/Rect 10 20))
    (case rect
      when (Shape/Rect w h d) w
      else -1)
  """, "variant Shape/Rect pattern expects 2 binding(s) (width, height), got 3")

  expect_enum_error("""
    (enum Shape (Circle radius) (Rect width height) Point)
    (case Shape/Point
      when (Shape/Point p) p
      else -1)
  """, "variant Shape/Point pattern expects 0 binding(s), got 1")

test_vm """
  (import Identity:LeftIdentity make_unit:left_unit from "tests/fixtures/s05_identity_left")
  (import Identity:RightIdentity make_unit:right_unit from "tests/fixtures/s05_identity_right")
  (var left (LeftIdentity/Box 5))
  (var right (RightIdentity/Box 5))
  [
    (if (left == right) 1 else 0)
    (case left
      when (LeftIdentity/Box value) value
      when (RightIdentity/Box value) -100
      else -1)
    (case right
      when (LeftIdentity/Box value) -100
      when (RightIdentity/Box value) value
      else -1)
    (case (left_unit)
      when LeftIdentity/Unit 10
      when RightIdentity/Unit 20
      else -1)
    (case (right_unit)
      when LeftIdentity/Unit 10
      when RightIdentity/Unit 20
      else -1)
  ]
""", proc(r: Value) =
  check r.kind == VkArray
  let values = array_data(r)
  check values.len == 5
  if values.len == 5:
    check values[0] == 0.to_value()
    check values[1] == 5.to_value()
    check values[2] == 5.to_value()
    check values[3] == 10.to_value()
    check values[4] == 20.to_value()

test "quoted legacy Result/Option-shaped values fail typed boundaries with migration diagnostics":
  expect_enum_error_parts("""
    (fn accept_result [r: (Result Int String)] -> Int 1)
    (accept_result `(Ok 1))
  """, ["legacy Gene-expression ADT value", "Result", "enum"])

  expect_enum_error_parts("""
    (fn accept_option [o: (Option Int)] -> Int 1)
    (accept_option `(Some 1))
  """, ["legacy Gene-expression ADT value", "Option", "enum"])

  expect_enum_error_parts("""
    (fn accept_option [o: (Option Int)] -> Int 1)
    (accept_option `None)
  """, ["legacy Gene-expression ADT value", "Option", "enum"])

test_vm """
  (fn accept_result [r: (Result Int String)] -> Int
    (case r
      when (Ok value) value
      when (Err error) 0))
  (fn accept_option [o: (Option Int)] -> Int
    (case o
      when (Some value) value
      when None 0))
  [(accept_result (Ok 5)) (accept_option (Some 4))]
""", proc(r: Value) =
  check r == @[5, 4].to_value()


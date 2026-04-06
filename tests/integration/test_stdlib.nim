import unittest
import gene/vm
import gene/types except Exception
import ../helpers

test_vm """
  ((nil .class).name)
""", "Nil"

test_vm """
  (nil .to_s)
""", ""

test_vm """
  (nil .empty?)
""", true

test_vm """
  (nil .not_empty?)
""", false

test_vm """
  (gene .empty?)
""", false

test_vm """
  (gene .not_empty?)
""", true

test_vm """
  (`a .to_s)
""", "a"

test_vm """
  ("a" .to_s)
""", "a"

test_vm """
  ([1 "a"] .to_s)
""", "[1 \"a\"]"

test_vm """
  ({^a "a"} .to_s)
""", "{^a \"a\"}"

test_vm """
  ((`x ^a "a" "b") .to_s)
""", "(x ^a \"a\" \"b\")"

test_vm """
  (class A
    (method call [x y]
      (x + y)
    )
  )
  (var a (new A))
  (a 1 2)
""", 3

test "Zero-arg native methods warn on extra arguments; explicit grouping works for infix comparisons":
  init_all()

  # Extra args now produce a compile-time warning (not a runtime error)
  discard VM.exec("""
    (var a "abc")
    (a .length 1)
  """, "stdlib_native_method_extra_arg")

  # Infix without grouping: > is parsed as extra arg, fails at runtime
  expect CatchableError:
    discard VM.exec("""
      (var a "abc")
      (a .length > 0)
    """, "stdlib_native_method_infix_ambiguous")

  check VM.exec("""
    (var a "abc")
    ((a .length) > 0)
  """, "stdlib_native_method_grouped_infix") == TRUE

# putEnv("__GENE_TEST_ENV__", "gene_value")
# delEnv("__GENE_TEST_MISSING__")
# refresh_env_map()

# test_vm "$env", proc(result: Value) =
#   check result.kind == VkMap
#   let envKey = "__GENE_TEST_ENV__".to_key()
#   check envKey in result.ref.map
#   let value = result.ref.map[envKey]
#   check value.kind == VkString
#   check value.str == "gene_value"

# test_vm "$env/__GENE_TEST_ENV__", proc(result: Value) =
#   check result.kind == VkString
#   check result.str == "gene_value"

# test_vm """
#   ($env .get "__GENE_TEST_MISSING__")
# """, proc(result: Value) =
#   check result == NIL

# test_vm """
#   ($env .get "__GENE_TEST_MISSING__" "fallback")
# """, proc(result: Value) =
#   check result.kind == VkString
#   check result.str == "fallback"

test "Global $program and $args reflect CLI inputs":
  init_all()
  set_program_args("script.gene", @["123", "456"])

  let program_val = VM.exec("$program", "test_code")
  check program_val.kind == VkString
  check program_val.str == "script.gene"

  let args_val = VM.exec("$args", "test_code")
  check args_val.kind == VkArray
  check array_data(args_val).len == 2
  check array_data(args_val)[0].str == "123"
  check array_data(args_val)[1].str == "456"

  # Reset to default state for later tests
  set_program_args("", @[])

# test_vm """
#   ($if_main
#     42)
# """, 42.to_value()

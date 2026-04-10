import std/json
import unittest

import gene/error_display
import gene/types except Exception
import gene/vm
import gene/vm/diagnostics

import ../helpers

# NOTE: Exception handling is not yet implemented in the VM
# All tests below use test_interpreter which is not defined
# Basic VM throw test (merged from test_vm_exception.nim)
test_vm_error """
  (throw "test error")
"""

# These tests serve as documentation for future implementation

# Native Nim exception vs Gene exception:
# Nim exceptions can be accessed from nim/ namespace
# Nim exceptions should be translated to Gene exceptions eventually
# Gene core exceptions are defined in gene/ namespace
# Gene exceptions share same Nim class: Exception
# For convenience purpose all exception classes like gene/XyzException are aliased as XyzException

# Retry support - from the beginning of try?
# (try...catch...(retry))

# (throw)
# (throw message)
# (throw Exception)
# (throw Exception message)
# (throw (new Exception ...))

# (try...catch...catch...finally)
# (try...finally)
# (fn f []  # converted to (try ...)
#   ...
#   catch ExceptionX ...
#   catch * ...
#   finally ...
# )

# test "(throw ...)":
#   var code = """
#     (throw "test")
#   """.cleanup
#   test "Interpreter / eval: " & code:
#     init_all()
#     discard VM.eval(code)
#     # try:
#     #   discard VM.eval(code)
#     #   check false
#     # except:
#     #   discard

# Exception handling is not yet implemented in the VM
# These tests are placeholders for future implementation
test_vm """
  (try
    (throw)
    1
  catch *
    2
  )
""", 2

# TODO: Enable these tests once class inheritance and exception type matching are implemented
# test_vm """
#   (class TestException < Exception)
#   (try
#     (throw TestException)
#     1
#   catch TestException
#     2
#   catch *
#     3
#   )
# """, 2

# test_vm """
#   (class TestException < Exception)
#   (try
#     (throw)
#     1
#   catch TestException
#     2
#   catch *
#     3
#   )
# """, 3

test_vm """
  (try
    (throw "test")
  catch *
    ($ex .message)
  )
""", "test"

test_vm """
  (try
    (throw "boom")
  catch *
    ($ex .message)
  )
""", "boom"

test_vm """
  (try
    (throw "boom")
  catch _
    7
  )
""", 7

test_vm """
  (try
    (throw)
    1
  catch *
    2
  finally
    3   # value is discarded
  )
""", 2

# # Try can be omitted on the module level, like function body
# # This can simplify freeing resources
# test_vm """
#   (throw)
#   1
#   catch *
#   2
#   finally
#   3
# """, 2

# test_vm """
#   1
#   finally
#   3
# """, 1

test_vm """
  (try
    (throw)
    1
  catch *
    2
  finally
    (return 3)  # not allowed
  )
""", 2

test_vm """
  (try
    (throw)
    1
  catch *
    2
  finally
    (break)  # not allowed
  )
""", 2

test_vm """
  (var a 0)
  (try
    (throw)
    (a = 1)
  catch *
    (a = 2)
  finally
    (a = 3)
  )
  a
""", 3

# Scope must unwind when exceptions jump out of nested scopes; otherwise later
# variable resolves can target a stale inner scope and crash with IkVarResolve
# out-of-bounds.
test_vm """
  (var a0 0)
  (var a1 1)
  (var a2 2)
  (var a3 3)
  (var a4 4)
  (var a5 5)
  (var a6 6)
  (var a7 7)
  (var a8 8)
  (var a9 9)
  (var a10 10)
  (var a11 11)

  (try
    (if true
      (var b0 0)
      (var b1 1)
      (var b2 2)
      (var b3 3)
      (var b4 4)
      (var b5 5)
      (var b6 6)
      (var b7 7)
      (var b8 8)
      (var b9 9)
      (throw "boom")
    )
  catch *
    0
  )

  a11
""", 11


# test_vm """
#   (fn f []
#     (throw)
#     1
#   catch *
#     2
#   finally
#     3
#   )
#   (f)
# """, 2

# test_vm """
#   (macro m _
#     (throw)
#     1
#   catch *
#     2
#   finally
#     3
#   )
#   (m)
# """, 2

# test_vm """
#   (fn f [blk]
#     (blk)
#   )
#   (f
#     (->
#       (throw)
#       1
#     catch *
#       2
#     finally
#       3
#     )
#   )
# """, 2

# test_vm """
#   (do
#     (throw)
#     1
#   catch *
#     2
#   finally
#     3
#   )
# """, 2

test "runtime exception produces structured diagnostic envelope":
  init_all()
  try:
    discard VM.exec("(throw \"test diagnostic\")", "test_code")
    fail()
  except types.Exception as e:
    let msg = e.msg
    check msg.len > 0
    let parsed = parseJson(msg)
    check parsed.hasKey("code")
    check parsed.hasKey("message")
    check parsed.hasKey("severity")
    check parsed["severity"].getStr() == "error"
    check parsed.hasKey("stage")
    check parsed.hasKey("span")
    check parsed["span"].hasKey("line")
    check parsed["code"].getStr().len > 0

test "render_error_message preserves canonical diagnostic field order":
  let rendered = render_error_message(diagnostics.make_diagnostic_message(
    "GENE.RUNTIME.ERROR",
    "boom"
  ))
  check rendered == "{^message \"boom\" ^code \"GENE.RUNTIME.ERROR\" ^severity \"error\" ^stage \"runtime\" ^span {^file \"\" ^line 0 ^column 0} ^hints [] ^repair_tags [\"runtime\"]}"

import unittest

import ../src/gene/vm
import ./helpers
import ../src/gene/types except Exception

const TRAMPOLINE_OK = """
(do
  (fn /helper [x: Int] -> Int
    (+ x 1))
  (fn caller [y: Int] -> Int
    (helper y))
  (caller 10)
  caller)
"""

const TRAMPOLINE_UNTYPED = """
(do
  (fn /helper [x]
    (+ x 1))
  (fn caller [y: Int] -> Int
    (helper y))
  (caller 10)
  caller)
"""

const FIB_NATIVE = """
(do
  (fn fib [n: Int] -> Int
    (if (n < 2)
      n
    else
      (+ (fib (n - 1)) (fib (n - 2)))))
  (var a (fib 10))
  (var b (fib 20))
  [a b fib])
"""

const MISSING_RETURN_ANNOTATION = """
(do
  (fn candidate [x: Int]
    (+ x 1))
  (candidate 10)
  candidate)
"""

test "native trampoline: typed helper call compiles natively":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctGuarded
  VM.native_code = true
  let result = VM.exec(TRAMPOLINE_OK, "test_native_trampoline_ok")
  check result.kind == VkFunction
  let f = result.ref.fn
  check f.native_ready
  check not f.native_failed
  check f.native_descriptors.len == 1

test "native trampoline: untyped callee disables native compile":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctGuarded
  VM.native_code = true
  let result = VM.exec(TRAMPOLINE_UNTYPED, "test_native_trampoline_untyped")
  check result.kind == VkFunction
  let f = result.ref.fn
  check not f.native_ready
  check f.native_failed

test "native codegen: fib runs natively":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctGuarded
  VM.native_code = true
  let result = VM.exec(FIB_NATIVE, "test_native_fib")
  check result.kind == VkArray
  let items = array_data(result)
  check items.len == 3
  check items[0].to_int() == 55
  check items[1].to_int() == 6765
  check items[2].kind == VkFunction
  let f = items[2].ref.fn
  check f.native_ready
  check not f.native_failed
  check f.native_entry != nil

test "native codegen: repeated execution reuses published descriptors":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctGuarded
  VM.native_code = true

  let result = VM.exec(FIB_NATIVE, "test_native_fib_reuse")
  check result.kind == VkArray
  let items = array_data(result)
  check items.len == 3
  check items[2].kind == VkFunction

  let fn_value = items[2]
  let f = fn_value.ref.fn
  check f.native_ready
  let first_entry = f.native_entry
  let first_descriptor_count = f.native_descriptors.len

  let second = VM.exec_function(fn_value, @[10.to_value()])
  let third = VM.exec_function(fn_value, @[11.to_value()])
  check second.to_int() == 55
  check third.to_int() == 89
  check f.native_ready
  check not f.native_failed
  check f.native_entry == first_entry
  check f.native_descriptors.len == first_descriptor_count

test "native tier never disables native compile attempts":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctNever
  VM.native_code = false

  let result = VM.exec(TRAMPOLINE_OK, "test_native_tier_never")
  check result.kind == VkFunction
  let f = result.ref.fn
  check not f.native_ready
  check not f.native_failed

test "native tier fully-typed requires typed return boundary":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctFullyTyped
  VM.native_code = true

  let result = VM.exec(MISSING_RETURN_ANNOTATION, "test_native_tier_fully_typed")
  check result.kind == VkFunction
  let f = result.ref.fn
  check not f.native_ready
  check not f.native_failed

test "native guarded tier deopts on runtime guard miss":
  init_all()
  let prev = VM.native_code
  let prev_tier = VM.native_tier
  defer:
    VM.native_code = prev
    VM.native_tier = prev_tier
  VM.native_tier = NctGuarded
  VM.native_code = true

  let fn_value = VM.exec("(do (fn id [x: Int] -> Int x) id)", "test_native_tier_guarded_deopt")
  check fn_value.kind == VkFunction
  discard VM.exec_function(fn_value, @[1.to_value()])
  let f = fn_value.ref.fn
  check f.native_ready

  var raised = false
  try:
    discard VM.exec_function(fn_value, @["oops".to_value()])
  except CatchableError:
    raised = true
  check raised
  check f.native_ready
  check not f.native_failed

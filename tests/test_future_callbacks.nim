import unittest

import gene/types except Exception

import ./helpers

suite "Future Callbacks":
  test "on_success executes for manual Future.complete without polling":
    test_vm """
    (var result [])
    (var f (new gene/Future))
    (f .on_success (fn [v] (result .append v)))
    (f .complete 77)
    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 1
      check array_data(r)[0].to_int() == 77

  test "on_success executes next tick for already-completed manual future":
    test_vm """
    (var result 0)
    (var f (new gene/Future 41))
    (f .on_success (fn [v] (result = (+ v 1))))

    # Late callback registration should run on the next scheduler tick.
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, 42

  test "on_success callback executes for already-completed future":
    test_vm """
    (var result [])
    (var f (async 42))
    (await f)
    (f .on_success (fn [v] (result .append v)))

    # Force polling by doing work
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 1
      check array_data(r)[0].to_int() == 42

  test "on_failure executes next tick for already-failed future":
    test_vm """
    (var result [])
    (var f (async (throw "test error")))
    (try (await f) catch * nil)
    (f .on_failure (fn [e] (result .append "failed")))

    # Late callback registration should run on the next scheduler tick.
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 1
      check array_data(r)[0].kind == VkString

  test "on_failure callback executes for already-failed future":
    test_vm """
    (var result [])
    (var f (async (throw "test error")))
    (try (await f) catch * nil)
    (f .on_failure (fn [e] (result .append "failed")))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 1
      check array_data(r)[0].kind == VkString

  test "multiple callbacks execute in order":
    test_vm """
    (var result [])
    (var f (async 10))
    (await f)
    (f .on_success (fn [v] (result .append (v + 1))))
    (f .on_success (fn [v] (result .append (v + 2))))
    (f .on_success (fn [v] (result .append (v + 3))))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 3
      check array_data(r)[0].to_int() == 11
      check array_data(r)[1].to_int() == 12
      check array_data(r)[2].to_int() == 13

  test "callback chaining works":
    test_vm """
    (var result [])
    (var f (async 5))
    (await f)
    (f .on_success (fn [v] (result .append v)))
    (f .on_success (fn [v] (result .append (v * 2))))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 2
      check array_data(r)[0].to_int() == 5
      check array_data(r)[1].to_int() == 10

  test "callbacks don't execute for wrong state":
    test_vm """
    (var result [])
    (var f (async 42))
    (await f)
    # on_failure should not execute for successful future
    (f .on_failure (fn [e] (result .append "should not execute")))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 0

  test "on_failure executes next tick for cancelled futures":
    test_vm """
    (var result [])
    (var f (new gene/Future))
    (f .cancel)
    (f .on_failure (fn [e] (result .append "cancelled")))

    # Late callback registration should run on the next scheduler tick.
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 1
      check array_data(r)[0].kind == VkString
      check array_data(r)[0].str == "cancelled"

  test "callback with block syntax":
    test_vm """
    (var result 0)
    (var f (async 15))
    (await f)
    (f .on_success (fn [v]
      (result = (v + 5))
    ))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    result
    """, 20

  test "callback receives correct value":
    test_vm """
    (var received nil)
    (var f (async {^status "ok" ^value 123}))
    (await f)
    (f .on_success (fn [v] (received = v)))

    # Force polling
    (var i 0)
    (while (< i 200)
      (i = (+ i 1)))

    received/value
    """, 123

  test "callbacks clear after execution":
    test_vm """
    (var count 0)
    (var f (async 1))
    (await f)
    (f .on_success (fn [v] (count = (count + 1))))

    # Force multiple polls
    (var i 0)
    (while (< i 500)
      (i = (+ i 1)))

    # Callback should only execute once, not on every poll
    count
    """, 1

  test "state method returns correct state":
    test_vm """
    (var f (async 42))
    (var state1 (f .state))
    (await f)
    (var state2 (f .state))
    [state1 state2]
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 2
      check array_data(r)[0] == "success".to_symbol_value()  # Synchronous futures complete immediately
      check array_data(r)[1] == "success".to_symbol_value()

  test "value method returns correct value":
    test_vm """
    (var f (async 99))
    (await f)
    (f .value)
    """, 99

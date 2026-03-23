import std/unittest
import ../helpers

suite "Scope Lifetime":
  test_vm """
    (fn test []
      (var x 1)
      (var y 2)
      (+ x y))
    (test)
  """, 3

  test_vm """
    (fn outer []
      (var x 1)
      (do
        (var y 2)
        (do
          (var z 3)
          (+ x (+ y z)))))
    (outer)
  """, 6

  test_vm """
    (fn create_scope [n]
      (if (> n 0)
        (do
          (var x n)
          (create_scope (- n 1)))
        0))
    (create_scope 100)
  """, 0

  test_vm """
    (fn test_async []
      (var x 42)
      (var f (async x))
      (await f))
    (test_async)
  """, 42

  test_vm """
    (fn test_multi_async []
      (var x 10)
      (var f1 (async x))
      (var f2 (async (* x 2)))
      (+ (await f1) (await f2)))
    (test_multi_async)
  """, 30

  test_vm """
    (fn test_nested []
      (var outer 1)
      (var f (async (do
        (var inner 2)
        (+ outer inner))))
      (await f))
    (test_nested)
  """, 3

  test_vm """
    (var total 0)
    (fn accumulate [n]
      (if (> n 0)
        (do
          (var x n)
          (total = (+ total x))
          (accumulate (- n 1)))
        total))
    (accumulate 50)
  """, 1275

  # TODO: Test .on_success when callback support is implemented
  # test_vm """
  #   (fn test_callback []
  #     (var x 100)
  #     (var f (async x))
  #     (.on_success f (fn [val] val))
  #     (await f))
  #   (test_callback)
  # """, 100

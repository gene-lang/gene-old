import unittest

import ./helpers

suite "Static type checking":
  test_vm_error """
    (fn f [x: NotAType] x)
  """

  test_vm_error """
    (fn f [^limit: Int] -> Int
      limit
    )
    (f ^offset 1)
  """

  test_vm_error """
    (fn f [a: Int] -> Int
      a
    )
    (f 1 2)
  """

  test_vm_error """
    (fn add [a: Int b: Int] -> Int
      (+ a b)
    )
    (add 1 "x")
  """

  test_vm_error """
    (class Point
      ^fields {^x Int}
      (ctor [x: Int]
        (/x = x)
      )
      (method ok [] -> Int
        /x
      )
    )
    (var p (new Point 1))
    p/y
  """

  test_vm_error """
    (class Point
      ^fields {^x Int}
      (ctor [x: Int]
        (/x = x)
      )
      (method ok [] -> Int
        /x
      )
    )
    (var p (new Point 1))
    (p .missing)
  """

  test_vm_error """
    (class Base
      ^fields {^x Int}
      (ctor [x: Int]
        (/x = x)
      )
    )
    (class Child < Base
      ^fields {^x Int}
      (method call_super []
        (super .missing)
      )
    )
    ((new Child 1) .call_super)
  """

  test_vm """
    (var x: (Int | String) 1)
    (if (x .is Int)
      (do
        (var y x)
        (y = 2)
        y)
    else
      0)
  """, 2

  test_vm_error """
    (var x: (Int | String) 1)
    (if (x .is Int)
      (do
        (var y x)
        (y = "oops")
        y)
    else
      0)
  """

  test_vm_error """
    (var x: (Int | String) 1)
    (if (x .is Int)
      1
    else
      (do
        (var y x)
        (y + 1)))
  """

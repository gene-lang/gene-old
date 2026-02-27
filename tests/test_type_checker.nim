import unittest

import ./helpers
import ../src/gene/parser
import ../src/gene/type_checker as tc

proc test_strict_type_error(code: string) =
  var code = cleanup(code)
  test "Strict type checking: " & code:
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    var raised = false
    try:
      for node in read_all(code):
        checker.type_check_node(node)
    except CatchableError:
      raised = true
    check raised

suite "Static type checking":
  test_strict_type_error """
    (fn f [x: NotAType] x)
  """

  test_strict_type_error """
    (var a 1)
    (var b 2)
    ([a b] = [3 4])
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

  test_strict_type_error """
    (var x: (Int | String) 1)
    (if (x .is Int)
      (do
        (var y x)
        (y = "oops")
        y)
    else
      0)
  """

  test_strict_type_error """
    (var x: (Int | String) 1)
    (if (x .is Int)
      1
    else
      (do
        (var y x)
        (y + 1)))
  """

  test_strict_type_error """
    (var x: (Int | String) 1)
    (if (x is Int)
      1
    else
      (x + 1))
  """

  test_strict_type_error """
    (var x: ((Result Int String) | Int) (Ok 1))
    (case x
      when (Ok v)
        (x + 1)
      else
        0)
  """

  test_strict_type_error """
    (var x: ((Result Int String) | Int) (Ok 1))
    (match x
      (Ok v) (x + 1)
      _ 0)
  """

  test "Strict type checking: catch binding variable is scoped":
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    let code = cleanup("""
      (try
        (throw "boom")
      catch ex
        ex
      finally
        1
      )
    """)
    for node in read_all(code):
      checker.type_check_node(node)
    check true

  test "Strict type checking: for index plus destructuring pattern":
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    let code = cleanup("""
      (for [i [a b]] in [[1 2] [3 4]]
        (+ i a)
        b
      )
    """)
    for node in read_all(code):
      checker.type_check_node(node)
    check true

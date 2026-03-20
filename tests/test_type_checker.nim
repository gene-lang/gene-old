import unittest

import ./helpers
import ../src/gene/parser
import ../src/gene/type_checker as tc
import ../src/gene/types except Exception

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

  test_strict_type_error """
    (class Point
      ^fields {^x Int}
      (ctor [x: Int]
        (/x = x)
      )
    )
    (var p (new Point 1))
    (p/x = "bad")
  """

  test_strict_type_error """
    (class Point
      ^fields {^x Int ^y Int}
      (ctor [x: Int y: String]
        (/x = x)
        (/y = y)
      )
    )
    (var p (new Point 1 "test"))
    p/y
  """

  test_strict_type_error """
    (class Point
      ^fields {^x Int}
      (ctor [x: Int]
        (/x = x)
      )
      (method bad [] -> String
        /x
      )
    )
    ((new Point 1) .bad)
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

  test_vm """
    (var x: (String | Nil) "hi")
    (ifel (x != nil)
      (x ++ "!")
      "missing")
  """, "hi!".to_value()

  test_strict_type_error """
    (var x: (String | Nil) nil)
    (ifel (x != nil)
      "ok"
      (x ++ "!"))
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

  test "Strict type checking: catch destructuring bindings are scoped":
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    let code = cleanup("""
      (try
        (throw [1 2])
      catch [a b]
        (+ a b)
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

  test_vm """
    (fn identity:T [x: T] -> T
      x)
    [(identity 42) (identity "hello")]
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 2
    check array_data(result)[0] == 42
    check array_data(result)[1] == "hello".to_value()

  test_vm """
    (types_equivalent (String | Nil) `(Nil | String))
  """, TRUE

  test_vm """
    ("hi" is (String | Nil))
  """, TRUE

  test_vm """
    ("hi" .is (String | Nil))
  """, TRUE

  test_vm """
    (type X (String | Nil))
    (types_equivalent X `(String | Nil))
  """, TRUE

  test_vm """
    (type UserId (Int | String))
    (var uid: UserId 99)
    uid
  """, 99

  test_vm """
    (type X (String | Nil))
    (fn f [x: X] -> String
      (if (x != nil)
        x
      else
        "missing"))
    [(f "ok") (f nil)]
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 2
    check array_data(result)[0] == "ok".to_value()
    check array_data(result)[1] == "missing".to_value()

  test_vm_error """
    (type X (String | Nil))
    (fn f [x: X] -> String
      (if (x != nil)
        x
      else
        "missing"))
    (f 1)
  """

  test_vm """
    (class Box
      (method echo:T [x: T] -> T
        x))
    (var box (new Box))
    [(box .echo 42) (box .echo "hello")]
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 2
    check array_data(result)[0] == 42
    check array_data(result)[1] == "hello".to_value()

  test_vm """
    (var x: (String | Nil) "hi")
    (if (x != nil)
      (x ++ "!")
    else
      "missing")
  """, "hi!".to_value()

  test_vm """
    (class Point
      ^fields {^x Int ^y Int}
      (ctor [x y]
        (/x = x)
        (/y = y))
    )
    (var p (new Point 3 4))
    (var maybe_label: (String | Nil) "Gene")
    (if (maybe_label != nil)
      maybe_label
    else
      "missing")
  """, "Gene".to_value()

  test_vm """
    (var x: (Int | String) "hi")
    (if (not (x .is Int))
      x
    else
      "bad")
  """, "hi".to_value()

  test_strict_type_error """
    (var x: (String | Nil) nil)
    (if (x != nil)
      "ok"
    else
      (x ++ "!"))
  """

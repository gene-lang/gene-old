import unittest, strutils

import ./helpers
import ../src/gene/parser
import ../src/gene/type_checker as tc
import ../src/gene/types except Exception
import ../src/gene/vm

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

proc test_strict_type_error_contains(code: string, expected: string) =
  var code = cleanup(code)
  test "Strict type checking error contains '" & expected & "': " & code:
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    var raised = false
    var message = ""
    try:
      for node in read_all(code):
        checker.type_check_node(node)
    except CatchableError as e:
      raised = true
      message = e.msg
    check raised
    check message.contains(expected)

proc test_strict_type_error_contains_all(code: string, expected: openArray[string]) =
  var code = cleanup(code)
  test "Strict type checking error contains migration diagnostics: " & code:
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    var raised = false
    var message = ""
    try:
      for node in read_all(code):
        checker.type_check_node(node)
    except CatchableError as e:
      raised = true
      message = e.msg
    check raised
    for part in expected:
      check message.contains(part)

proc test_strict_type_ok(code: string) =
  var code = cleanup(code)
  test "Strict type checking succeeds: " & code:
    let checker = tc.new_type_checker(strict = true, module_filename = "test_code")
    for node in read_all(code):
      checker.type_check_node(node)
    check true

suite "Static type checking":
  test_strict_type_ok """
    (fn typed_middle_rest [head: Int nums...: Int tail: Bool]
      [head nums tail]
    )
    (typed_middle_rest 1 2 3 true)
  """

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

  test_strict_type_error """
    (fn typed_middle_rest [head: Int nums...: Int tail: Bool]
      [head nums tail]
    )
    (typed_middle_rest 1 2 "x" true)
  """

  test_strict_type_error """
    (fn typed_middle_rest [head: Int nums...: Int tail: Bool]
      [head nums tail]
    )
    (typed_middle_rest 1 2 3 4)
  """

  test_strict_type_ok """
    (fn typed_nested_rest [chunks...: (Array Int)]
      chunks
    )
    (typed_nested_rest [1 2] [3 4])
  """

  test_strict_type_error """
    (fn typed_nested_rest [chunks...: (Array Int)]
      chunks
    )
    (typed_nested_rest [1 2] 3)
  """

  test_strict_type_ok """
    (fn fixed_array_plus_rest [item: (Array Int) rest...: Int]
      [item rest]
    )
    (fixed_array_plus_rest [1 2] 3 4)
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
      (for i [a b] in [[1 2] [3 4]]
        (+ i a)
        b
      )
    """)
    for node in read_all(code):
      checker.type_check_node(node)
    check true

  test_strict_type_error """
    (for k v in {^a 1 ^b 2}
      (k + v)
    )
  """

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
    (type X (String | Nil))
    (class Box
      (method show [x: X] -> String
        (if (x != nil)
          x
        else
          "missing")))
    (var box (new Box))
    [(box .show "ok") (box .show nil)]
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 2
    check array_data(result)[0] == "ok".to_value()
    check array_data(result)[1] == "missing".to_value()

  test_vm_error """
    (type X (String | Nil))
    (class Box
      (method show [x: X] -> String
        (if (x != nil)
          x
        else
          "missing")))
    ((new Box) .show 1)
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

  test_strict_type_ok """
    (fn noop [] -> Void VOID)
    (fn takes_void [f: (Fn -> Void)] -> Void
      (f))
    (takes_void noop)
  """

  test_strict_type_ok """
    (fn make_one [] -> Int 1)
    (fn takes_zero [f: (Fn -> Int)] -> Int
      (f))
    (takes_zero make_one)
  """

  test_strict_type_ok """
    (type MixedFn (Fn [^a Int ^... String Int ... String] -> String))
    (type DisplayMethod (Method [Int] -> String))
  """

  test_strict_type_error """
    (var self 1)
  """

  test_strict_type_error """
    (fn self [] 1)
  """

  test_strict_type_error """
    (fn f [self: Int] self)
  """

  test_strict_type_error """
    (type Self Int)
  """

  test_strict_type_error """
    (class Self)
  """

  test_strict_type_error """
    (fn f [x: Self] x)
  """

  test_vm """
    (class Box
      (method clone [] -> Self
        self))
    (var box (new Box))
    (box .clone)
  """, proc(result: Value) =
    check result.kind == VkInstance

  test_strict_type_ok """
    (interface Renderable
      (field name String)
      (method render [ctx: Any] -> String)
    )
    (class Base
      (field name String)
      (method render [ctx: Any] -> String
        name
      )
    )
    (class View < Base implements Renderable)
  """

  test_strict_type_error """
    (interface Renderable
      (method render [ctx: Any] -> String)
    )
    (class Broken implements Renderable)
  """

  test_strict_type_error """
    (interface Renderable
      (method render [ctx: Any] -> String)
    )
    (class Broken
      (implement Renderable)
    )
  """

  test_strict_type_error """
    (interface Renderable
      (method render [Int] -> String)
    )
  """

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

  test_strict_type_ok """
    (enum Maybe:T
      (Some value: T)
      None)
    (fn passthrough [m: (Maybe Int)] -> (Maybe Int)
      m)
  """

  test_strict_type_error_contains """
    (enum Bad:T:T
      (Item value: T))
  """, "duplicate generic parameter T"

  test_strict_type_error_contains """
    (enum Bad
      Same
      Same)
  """, "duplicate variant Same"

  test_strict_type_error_contains """
    (enum Bad
      (Pair left left))
  """, "duplicate field left"

  test_strict_type_error_contains """
    (enum Bad
      (Item value:))
  """, "missing a type after ':'"

  test_strict_type_error_contains """
    (enum Bad
      (Item value: 1))
  """, "invalid type annotation"

  test_strict_type_error_contains """
    (enum Bad:T
      (Item value: MissingType))
  """, "Unknown type: MissingType"

  test_strict_type_ok """
    (fn unwrap_result [r: (Result Int String)] -> Int
      (var value (r ?))
      value)
    (unwrap_result (Ok 7))
  """

  test_strict_type_error_contains """
    (fn unwrap_result_wrong [r: (Result Int String)] -> String
      (r ?))
  """, "expected String, got Int"

  test_strict_type_ok """
    (fn unwrap_option [o: (Option String)] -> String
      (var value (o ?))
      value)
    (unwrap_option (Some "ready"))
  """

  test_strict_type_error_contains """
    (fn unwrap_option_wrong [o: (Option String)] -> Int
      (o ?))
  """, "expected Int, got String"

  test_strict_type_ok """
    (fn unwrap_keyword_ok [] -> Int
      ((Ok ^value 1) ?))
    (unwrap_keyword_ok)
  """

  test_strict_type_error_contains """
    (fn unwrap_keyword_ok_wrong [] -> String
      ((Ok ^value 1) ?))
  """, "expected String, got Int"

  test_strict_type_ok """
    (fn unwrap_keyword_some [] -> String
      ((Some ^value "ready") ?))
    (unwrap_keyword_some)
  """

  test_strict_type_error_contains """
    (fn unwrap_keyword_some_wrong [] -> Int
      ((Some ^value "ready") ?))
  """, "expected Int, got String"

  test_vm """
    (enum Result:T:E
      (Ok value: T)
      (Err error: E)
      Empty)
    (var ok (Result/Ok 42))
    (fn accept_result [r: (Result Int String)] -> String
      "accepted")
    [(accept_result ok) (accept_result Result/Empty)]
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 2
    check array_data(result)[0] == "accepted".to_value()
    check array_data(result)[1] == "accepted".to_value()

  test_vm_error """
    (enum Result:T:E
      (Ok value: T)
      (Err error: E))
    (enum Status ^values [ready done])
    (var ok (Result/Ok 42))
    (fn accept_status [s: Status] -> String
      "status")
    (accept_status ok)
  """

  test_strict_type_error_contains """
    (enum Shape (Circle radius: Int))
    (enum Badge (Circle radius: Int))
    (var shape (Shape/Circle 3))
    (case shape
      when (Circle r)
        r
      else
        0)
  """, "variant Circle is ambiguous; use"

  test_strict_type_error_contains """
    (enum Shape Point)
    (fn classify [shape: Shape] -> Int
      (case shape
        when Shape/Circle
          1
        else
          0))
  """, "enum pattern Shape/Circle references unknown enum or variant"

  test_strict_type_error_contains """
    (enum Shape (Rect width: Int height: Int) Point)
    (fn bad_rect [shape: Shape] -> Int
      (case shape
        when (Shape/Rect w)
          w
        when Shape/Point
          0))
  """, "variant Shape/Rect pattern expects 2 binding(s) (width, height), got 1"

  test_strict_type_error_contains """
    (enum Shape Point)
    (fn bad_point [shape: Shape] -> Int
      (case shape
        when (Shape/Point p)
          p
        else
          0))
  """, "variant Shape/Point pattern expects 0 binding(s), got 1"

  test_strict_type_ok """
    (enum Shape (Circle radius: Int) (Rect width: Int height: Int) Point)
    (fn classify [shape: Shape] -> Int
      (case shape
        when (Shape/Circle r)
          (r + 1)
        when (Shape/Rect w h)
          (w + h)
        when Shape/Point
          0))
  """

  test_strict_type_error_contains """
    (enum Shape (Circle radius: Int) Point)
    (fn bad_radius_use [shape: Shape] -> String
      (case shape
        when (Shape/Circle r)
          (r ++ "!")
        when Shape/Point
          "point"))
  """, "expected String, got Int"

  test_strict_type_error_contains """
    (fn bad_result_error_binding [r: (Result Int String)] -> Int
      (case r
        when (Ok value)
          value
        when (Err error)
          (error + 1)))
  """, "expected Int, got String"

  test_strict_type_error_contains """
    (enum Box:T (Item value: T) Empty)
    (fn bad_box_binding [box: (Box String)] -> Int
      (case box
        when (Box/Item value)
          (value + 1)
        when Box/Empty
          0))
  """, "expected Int, got String"

  test_strict_type_error_contains """
    (enum Shape (Circle radius: Int) (Rect width: Int height: Int) Point)
    (fn classify [shape: Shape] -> Int
      (case shape
        when (Shape/Circle r)
          r))
  """, "non-exhaustive case over Shape; missing variants: Rect, Point"

  test_strict_type_ok """
    (enum Shape (Circle radius: Int) (Rect width: Int height: Int) Point)
    (fn classify [shape: Shape] -> Int
      (case shape
        when (Shape/Circle r)
          r
        else
          0))
  """

  test_strict_type_error_contains_all """
    (type (Result T E)
      ((Ok T) | (Err E)))
  """, ["legacy ADT declaration", "Result", "(enum Result:T:E"]

  test_strict_type_error_contains_all """
    (type (Option T)
      ((Some T) | None))
  """, ["legacy ADT declaration", "Option", "(enum Option:T"]

  test_strict_type_error_contains_all """
    (type (Result 1)
      ((Ok Int) | (Err String)))
  """, ["legacy ADT declaration", "Result", "invalid generic head"]

  test_strict_type_error_contains_all """
    (type (123 T)
      ((Item T)))
  """, ["legacy ADT declaration", "invalid generic head", "(enum Name:T"]

  test "Runtime compilation rejects legacy ADT declarations with migration diagnostics":
    proc expect_runtime_legacy_rejection(code: string, expected_parts: openArray[string]) =
      init_all()
      var raised = false
      var message = ""
      try:
        discard VM.exec(cleanup(code), "legacy_adt_runtime_rejection.gene")
      except CatchableError as e:
        raised = true
        message = e.msg
      check raised
      for part in expected_parts:
        check message.contains(part)

    expect_runtime_legacy_rejection("""
      (type (Result T E)
        ((Ok T) | (Err E)))
    """, ["legacy ADT declaration", "Result", "(enum Result:T:E"])

    expect_runtime_legacy_rejection("""
      (type (123 T)
        ((Item T)))
    """, ["legacy ADT declaration", "invalid generic head", "(enum Name:T"])

  test_strict_type_ok """
    (fn accept_enum_result [r: (Result Int String)] -> Int
      (case r
        when (Ok value)
          value
        when (Err error)
          0))
    (fn accept_enum_option [o: (Option Int)] -> Int
      (case o
        when (Some value)
          value
        when None
          0))
    (accept_enum_result (Ok 8))
    (accept_enum_option (Some 9))
  """


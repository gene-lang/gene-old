import std/[unittest, os, tables]
import ../src/types
import ../src/parser
import ../src/compiler
import ../src/vm
import ../src/ffi

proc run(source: string): Value =
  let prog = parseProgram(source)
  let module = compileProgram(prog)
  var vm = newVm()
  registerDefaultNatives(vm)
  vm.runModule(module)

proc runWithPath(source: string; sourcePath: string): Value =
  let prog = parseProgram(source, sourcePath)
  let module = compileProgram(prog, sourcePath)
  var vm = newVm()
  registerDefaultNatives(vm)
  vm.runModule(module)

suite "VM - Primitives":
  test "nil value":
    let r = run("nil")
    check isNil(r)

  test "true value":
    let r = run("true")
    check isBool(r)
    check asBool(r) == true

  test "false value":
    let r = run("false")
    check isBool(r)
    check asBool(r) == false

  test "integer value":
    let r = run("42")
    check isInt(r)
    check asInt(r) == 42

  test "negative integer":
    let r = run("-7")
    check isInt(r)
    check asInt(r) == -7

  test "float value":
    let r = run("3.14")
    check isNumber(r)
    check abs(asFloat(r) - 3.14) < 0.001

  test "string value":
    let r = run("\"hello\"")
    let s = asStringObj(r)
    check s != nil
    check s.value == "hello"

suite "VM - Arithmetic":
  test "integer addition":
    let r = run("(+ 1 2)")
    check asInt(r) == 3

  test "integer subtraction":
    let r = run("(- 10 3)")
    check asInt(r) == 7

  test "integer multiplication":
    let r = run("(* 4 5)")
    check asInt(r) == 20

  test "float division":
    let r = run("(/ 10 4)")
    check abs(asFloat(r) - 2.5) < 0.001

  test "modulo":
    let r = run("(% 10 3)")
    check asInt(r) == 1

  test "infix addition":
    let r = run("(1 + 2)")
    check asInt(r) == 3

  test "infix subtraction":
    let r = run("(10 - 3)")
    check asInt(r) == 7

  test "infix multiplication":
    let r = run("(4 * 5)")
    check asInt(r) == 20

  test "infix comparison":
    let r = run("(3 < 5)")
    check asBool(r) == true

  test "addition of large numbers":
    let r = run("(+ 1000000 2000000)")
    check asInt(r) == 3000000

  test "mixed int/float addition":
    let r = run("(+ 1 2.5)")
    check abs(asFloat(r) - 3.5) < 0.001

  test "infix precedence":
    let r = run("(5 + 3 * 2 ** 2)")
    check asInt(r) == 17

suite "VM - Comparisons":
  test "equal integers":
    check asBool(run("(== 5 5)")) == true

  test "not equal integers":
    check asBool(run("(!= 1 2)")) == true

  test "less than":
    check asBool(run("(< 1 2)")) == true

  test "less than false":
    check asBool(run("(< 5 3)")) == false

  test "less than or equal":
    check asBool(run("(<= 3 3)")) == true

  test "greater than":
    check asBool(run("(> 5 3)")) == true

  test "greater than or equal":
    check asBool(run("(>= 3 3)")) == true

  test "equal strings":
    check asBool(run("(== \"hello\" \"hello\")")) == true

  test "not equal strings":
    check asBool(run("(!= \"hello\" \"world\")")) == true

suite "VM - Boolean Logic":
  test "and true true":
    check asBool(run("(&& true true)")) == true

  test "and true false":
    check asBool(run("(&& true false)")) == false

  test "or false true":
    check asBool(run("(|| false true)")) == true

  test "or false false":
    check asBool(run("(|| false false)")) == false

  test "not via comparison true":
    check asBool(run("(== true false)")) == false

  test "not via comparison false":
    check asBool(run("(== false false)")) == true

  test "truthiness of 0 via and":
    # 0 is falsy: (&& 0 true) should be false
    check asBool(run("(&& 0 true)")) == false

  test "truthiness of nil via and":
    # nil is falsy: (&& nil true) should be false
    check asBool(run("(&& nil true)")) == false

  test "truthiness of 1 via and":
    # 1 is truthy: (&& 1 true) should be true
    check asBool(run("(&& 1 true)")) == true

suite "VM - Variables":
  test "var declaration and use":
    let r = run("(var x 42)\nx")
    check asInt(r) == 42

  test "var assignment":
    let r = run("(var x 1)\n(x = 2)\nx")
    check asInt(r) == 2

  test "var without value is nil":
    let r = run("(var x)\nx")
    check isNil(r)

  test "compound +=":
    let r = run("(var x 5)\n(x += 3)\nx")
    check asInt(r) == 8

  test "compound -=":
    let r = run("(var x 10)\n(x -= 3)\nx")
    check asInt(r) == 7

  test "compound *=":
    let r = run("(var x 4)\n(x *= 3)\nx")
    check asInt(r) == 12

suite "VM - If/elif/else":
  test "if true branch":
    let r = run("(if true 1 else 2)")
    check asInt(r) == 1

  test "if false branch":
    let r = run("(if false 1 else 2)")
    check asInt(r) == 2

  test "if without else returns nil":
    let r = run("(if false 1)")
    check isNil(r)

  test "if as expression":
    let r = run("(var x (if true 42 else 0))\nx")
    check asInt(r) == 42

  test "elif chain":
    let r = run("(var x 5)\n(if (x > 10) 1 elif (x > 3) 2 else 3)")
    check asInt(r) == 2

  test "nested if":
    let r = run("(if true (if false 1 else 2) else 3)")
    check asInt(r) == 2

suite "VM - Loops":
  test "loop with break":
    let r = run("""
      (var x 0)
      (loop
        (x += 1)
        (if (x >= 5) (break)))
      x
    """)
    check asInt(r) == 5

  test "loop with continue":
    let r = run("""
      (var sum 0)
      (var i 0)
      (loop
        (i += 1)
        (if (i > 10) (break))
        (if ((i % 2) == 0) (continue))
        (sum += i))
      sum
    """)
    check asInt(r) == 25  # 1+3+5+7+9

  test "for-in over array":
    let r = run("""
      (var sum 0)
      (for x in [1 2 3 4 5]
        (sum += x))
      sum
    """)
    check asInt(r) == 15

  test "while loop":
    let r = run("""
      (var x 3)
      (while (x > 0)
        (x -= 1))
      x
    """)
    check asInt(r) == 0

  test "repeat loop":
    let r = run("""
      (var x 0)
      (repeat 3
        (x += 2))
      x
    """)
    check asInt(r) == 6

  test "repeat loop with continue and break":
    let r = run("""
      (var sum 0)
      (var seen 0)
      (repeat 10
        (seen += 1)
        (if (seen > 6) (break))
        (if ((seen % 2) == 0) (continue))
        (sum += seen))
      [sum seen]
    """)
    let outArr = asArrayObj(r)
    check outArr != nil
    check outArr.items.len == 2
    check asInt(outArr.items[0]) == 9
    check asInt(outArr.items[1]) == 7

suite "VM - Case":
  test "case when else":
    let r = run("""
      (var value 2)
      (case value
        when 1 "one"
        when 2 "two"
        else "other")
    """)
    let s = asStringObj(r)
    check s != nil
    check s.value == "two"

suite "VM - Functions":
  test "simple function call":
    let r = run("""
      (fn add [a b] (+ a b))
      (add 3 4)
    """)
    check asInt(r) == 7

  test "function return value":
    let r = run("""
      (fn double [x] (* x 2))
      (double 21)
    """)
    check asInt(r) == 42

  test "explicit return":
    let r = run("""
      (fn first_pos [a b]
        (if (a > 0) (return a))
        (if (b > 0) (return b))
        0)
      (first_pos -1 5)
    """)
    check asInt(r) == 5

  test "recursive factorial":
    let r = run("""
      (fn factorial [n]
        (if (n <= 1) 1
        else (n * (factorial (n - 1)))))
      (factorial 5)
    """)
    check asInt(r) == 120

  test "anonymous function":
    let r = run("""
      (var double (fn [x] (x * 2)))
      (double 5)
    """)
    check asInt(r) == 10

  test "higher-order function":
    let r = run("""
      (fn apply [f x] (f x))
      (fn double [x] (x * 2))
      (apply double 21)
    """)
    check asInt(r) == 42

  test "default positional parameter":
    let r = run("""
      (fn add [a = 1 b] (a + b))
      (add 4)
    """)
    check asInt(r) == 5

  test "keyword parameters and call shorthands":
    let r = run("""
      (fn choose [^^a b]
        (if a b))
      (var x (choose 4))
      (var y (choose ^!a 4))
      [x y]
    """)
    let arr = asArrayObj(r)
    check arr != nil
    check arr.items.len == 2
    check asInt(arr.items[0]) == 4
    check isNil(arr.items[1])

  test "variadic parameter collects rest":
    let r = run("""
      (fn collect [head tail...]
        [head tail])
      (collect 1 2 3 4)
    """)
    let outArr = asArrayObj(r)
    check outArr != nil
    check outArr.items.len == 2
    check asInt(outArr.items[0]) == 1
    let rest = asArrayObj(outArr.items[1])
    check rest != nil
    check rest.items.len == 3
    check asInt(rest.items[0]) == 2
    check asInt(rest.items[2]) == 4

suite "VM - Closures":
  test "simple closure":
    let r = run("""
      (fn make_adder [x]
        (fn [y] (x + y)))
      (var add5 (make_adder 5))
      (add5 10)
    """)
    check asInt(r) == 15

  test "closure captures value":
    # Note: Closures capture values, not references; mutation doesn't persist
    let r = run("""
      (fn make_adder [base]
        (fn [x] (base + x)))
      (var add10 (make_adder 10))
      (add10 7)
    """)
    check asInt(r) == 17

suite "VM - Arrays":
  test "array literal":
    let r = run("[1 2 3]")
    let arr = asArrayObj(r)
    check arr != nil
    check arr.items.len == 3

  test "array indexing":
    let r = run("""
      (var arr [10 20 30])
      arr/0
    """)
    check asInt(r) == 10

  test "array length":
    let r = run("""
      (var arr [1 2 3 4 5])
      arr/.length
    """)
    check asInt(r) == 5

  test "array spread":
    let r = run("""
      (var a [1 2])
      (var b [3 4])
      (var c [a... b...])
      (len c)
    """)
    check asInt(r) == 4

  test "empty array":
    let r = run("[]")
    let arr = asArrayObj(r)
    check arr != nil
    check arr.items.len == 0

  test "array .push and .pop":
    let r = run("""
      (var arr [1 2])
      (arr .push 3)
      (var popped (arr .pop))
      [arr popped]
    """)
    let outArr = asArrayObj(r)
    check outArr != nil
    let arr = asArrayObj(outArr.items[0])
    check arr != nil
    check arr.items.len == 2
    check asInt(arr.items[0]) == 1
    check asInt(arr.items[1]) == 2
    check asInt(outArr.items[1]) == 3

  test "array .map/.filter/.reduce":
    let r = run("""
      (var arr [1 2 3])
      (var mapped (arr .map (fn [x] (x * 2))))
      (var filtered (arr .filter (fn [x] (x > 1))))
      (var reduced (arr .reduce 0 (fn [acc x] (acc + x))))
      [mapped filtered reduced]
    """)
    let outArr = asArrayObj(r)
    check outArr != nil
    let mapped = asArrayObj(outArr.items[0])
    let filtered = asArrayObj(outArr.items[1])
    check mapped != nil
    check filtered != nil
    check mapped.items.len == 3
    check asInt(mapped.items[0]) == 2
    check asInt(mapped.items[2]) == 6
    check filtered.items.len == 2
    check asInt(filtered.items[0]) == 2
    check asInt(filtered.items[1]) == 3
    check asInt(outArr.items[2]) == 6

suite "VM - Maps":
  test "map literal":
    let r = run("{^a 1 ^b 2}")
    let m = asMapObj(r)
    check m != nil
    check m.entries.len == 2

  test "map access":
    let r = run("""
      (var m {^x 42})
      m/x
    """)
    check asInt(r) == 42

  test "map set":
    let r = run("""
      (var m {^x 1})
      (m/x = 99)
      m/x
    """)
    check asInt(r) == 99

  test "empty map":
    let r = run("{}")
    let m = asMapObj(r)
    check m != nil
    check m.entries.len == 0

suite "VM - Classes":
  test "class instantiation":
    let r = run("""
      (class Point
        (ctor [x y]
          (/x = x)
          (/y = y)))
      (var p (new Point 3 4))
      p/x
    """)
    check asInt(r) == 3

  test "class method":
    let r = run("""
      (class Point
        (ctor [x y]
          (/x = x)
          (/y = y))
        (method sum []
          (/x + /y)))
      (var p (new Point 3 4))
      (p .sum)
    """)
    check asInt(r) == 7

  test "class method with args":
    let r = run("""
      (class Calc
        (ctor [base]
          (/base = base))
        (method add [n]
          (/base + n)))
      (var c (new Calc 10))
      (c .add 5)
    """)
    check asInt(r) == 15

  test "class inheritance":
    let r = run("""
      (class Animal
        (ctor [name]
          (/name = name))
        (method speak []
          "..."))
      (class Dog < Animal
        (method speak []
          "Woof!"))
      (var d (new Dog "Rex"))
      (d .speak)
    """)
    let s = asStringObj(r)
    check s != nil
    check s.value == "Woof!"

  test "inherited field access":
    let r = run("""
      (class Animal
        (ctor [name]
          (/name = name)))
      (class Dog < Animal
        (ctor [name]
          (/name = name)))
      (var d (new Dog "Rex"))
      d/name
    """)
    let s = asStringObj(r)
    check s != nil
    check s.value == "Rex"

suite "VM - Exception handling":
  test "try-catch catches thrown error":
    let r = run("""
      (try
        (throw "oops")
      catch e
        42)
    """)
    check asInt(r) == 42

  test "try without error returns body value":
    let r = run("""
      (try
        99
      catch e
        0)
    """)
    check asInt(r) == 99

  test "division by zero throws":
    let r = run("""
      (try
        (/ 1 0)
      catch e
        -1)
    """)
    check asInt(r) == -1

  test "uncaught throw raises runtime error":
    expect VmRuntimeError:
      discard run("(throw \"uncaught\")")

suite "VM - Async/Await":
  test "async resolves immediately":
    let r = run("(await (async 42))")
    check asInt(r) == 42

  test "async nil":
    let r = run("(await (async nil))")
    check isNil(r)

  test "async with expression":
    let r = run("(await (async (+ 1 2)))")
    check asInt(r) == 3

suite "VM - Generators":
  test "generator basic":
    let r = run("""
      (fn gen []
        (yield 1)
        (yield 2)
        (yield 3))
      (var g (gen))
      (var a (resume g))
      (var b (resume g))
      (var c (resume g))
      (+ (+ a b) c)
    """)
    check asInt(r) == 6

  test "generator for-in":
    let r = run("""
      (fn range [n]
        (var i 0)
        (loop
          (if (i >= n) (break))
          (yield i)
          (i += 1)))
      (var sum 0)
      (for x in (range 5)
        (sum += x))
      sum
    """)
    check asInt(r) == 10  # 0+1+2+3+4

suite "VM - Native functions":
  test "str converts int":
    let r = run("(str 42)")
    let s = asStringObj(r)
    check s != nil
    check s.value == "42"

  test "len of array":
    let r = run("(len [1 2 3])")
    check asInt(r) == 3

  test "len of string":
    let r = run("(len \"hello\")")
    check asInt(r) == 5

  test "to_i parses integer":
    let r = run("(to_i \"123\")")
    check asInt(r) == 123

  test "to_upper":
    let r = run("(to_upper \"hello\")")
    let s = asStringObj(r)
    check s != nil
    check s.value == "HELLO"

  test "sqrt":
    let r = run("(sqrt 9)")
    check abs(asFloat(r) - 3.0) < 0.001

  test "append strings":
    let r = run("(append \"hello\" \" world\")")
    let s = asStringObj(r)
    check s != nil
    check s.value == "hello world"

suite "VM - typeof":
  test "typeof int":
    let r = run("(typeof 42)")
    check asSymbolName(r) == "int"

  test "typeof string":
    let r = run("(typeof \"hello\")")
    check asSymbolName(r) == "string"

  test "typeof bool":
    let r = run("(typeof true)")
    check asSymbolName(r) == "bool"

  test "typeof nil":
    let r = run("(typeof nil)")
    check asSymbolName(r) == "nil"

  test "typeof array":
    let r = run("(typeof [1 2])")
    check asSymbolName(r) == "array"

suite "VM - String operations":
  test "string concatenation via append":
    let r = run("(append \"hello\" \" world\")")
    let s = asStringObj(r)
    check s != nil
    check s.value == "hello world"

  test "string length member":
    let r = run("""
      (var s "hello")
      s/.length
    """)
    check asInt(r) == 5

  test "hash interpolation":
    let r = run("""
      (var name "Gene")
      "Hello, #{name}!"
    """)
    let s = asStringObj(r)
    check s != nil
    check s.value == "Hello, Gene!"

suite "VM - Nil-safe navigation":
  test "nil-safe chain returns nil":
    let r = run("""
      (var user nil)
      user?/profile?/email
    """)
    check isNil(r)

  test "nil-safe chain returns value":
    let r = run("""
      (var user {^profile {^email "u@example.com"}})
      user?/profile?/email
    """)
    let s = asStringObj(r)
    check s != nil
    check s.value == "u@example.com"

suite "VM - Multiple expressions":
  test "last expression is result":
    let r = run("1\n2\n3")
    check asInt(r) == 3

  test "expressions execute in order":
    let r = run("""
      (var x 0)
      (x += 1)
      (x += 2)
      (x += 3)
      x
    """)
    check asInt(r) == 6

suite "VM - Capabilities":
  test "cap_grant and cap_assert":
    let r = run("""
      (cap_grant "net")
      (try
        (cap_assert net)
        true
      catch e
        false)
    """)
    check asBool(r) == true

  test "cap_assert fails without grant":
    let r = run("""
      (cap_clear)
      (try
        (cap_assert net)
        true
      catch e
        false)
    """)
    check asBool(r) == false

suite "VM - Modules":
  test "file import with relative path and cache":
    let root = getTempDir() / "genex_vm_modules_test"
    defer:
      if dirExists(root):
        removeDir(root)
    if dirExists(root):
      removeDir(root)
    createDir(root)

    let subPath = root / "sub.gene"
    let utilsPath = root / "utils.gene"
    let mainPath = root / "main.gene"

    writeFile(subPath, "(var n 7)\n")
    writeFile(utilsPath, """
      (import * as Sub "./sub")
      (var answer (Sub/n + 35))
      (fn inc [x] (x + 1))
    """)

    let mainSrc = """
      (import * as Utils "./utils")
      (import * as Utils2 "./utils")
      [Utils/answer (Utils/inc 9) Utils2/answer]
    """
    writeFile(mainPath, mainSrc)

    let r = runWithPath(mainSrc, mainPath)
    let arr = asArrayObj(r)
    check arr != nil
    check arr.items.len == 3
    check asInt(arr.items[0]) == 42
    check asInt(arr.items[1]) == 10
    check asInt(arr.items[2]) == 42

suite "VM - AOP bundles":
  test "aspect bundle is callable":
    let r = run("""
      (aspect X [cls m1]
        (before m1 [a...] nil))
      (X 1 2)
    """)
    check isNil(r)

suite "VM - Quotes":
  test "quote returns gene value":
    let r = run("`(a b c)")
    let g = asGeneObj(r)
    check g != nil
    check g.children.len == 2  # b, c are children; a is type

  test "quote preserves structure":
    let r = run("`42")
    check isInt(r)
    check asInt(r) == 42

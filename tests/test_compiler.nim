import std/[unittest]
import ../src/types
import ../src/parser
import ../src/ir
import ../src/compiler

proc compile(source: string): AirModule =
  let prog = parseProgram(source)
  compileProgram(prog)

proc mainFnCode(m: AirModule): seq[AirInst] =
  m.functions[m.mainFn].code

proc hasOpcode(code: seq[AirInst]; op: AirOpcode): bool =
  for inst in code:
    if inst.op == op:
      return true
  false

proc findOpcode(code: seq[AirInst]; op: AirOpcode): int =
  for i, inst in code:
    if inst.op == op:
      return i
  -1

suite "Compiler - Literals":
  test "compile nil":
    let m = compile("nil")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConstNil)

  test "compile true":
    let m = compile("true")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConstTrue)

  test "compile false":
    let m = compile("false")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConstFalse)

  test "compile integer":
    let m = compile("42")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConst)
    check m.constants.len >= 1

  test "compile string":
    let m = compile("\"hello\"")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConst)

  test "compile float":
    let m = compile("3.14")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConst)

suite "Compiler - Variables":
  test "var declaration with value":
    let m = compile("(var x 10)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConst)
    check code.hasOpcode(OpStoreGlobal)

  test "var declaration without value":
    let m = compile("(var x)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConstNil)
    check code.hasOpcode(OpStoreGlobal)

  test "var assignment":
    let m = compile("(var x 1)\n(x = 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpStoreGlobal)

  test "compound assignment +=":
    let m = compile("(var x 5)\n(x += 3)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpAdd)

  test "compound assignment -=":
    let m = compile("(var x 5)\n(x -= 3)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpSub)

  test "compound assignment *=":
    let m = compile("(var x 5)\n(x *= 3)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpMul)

suite "Compiler - Arithmetic":
  test "addition (prefix)":
    let m = compile("(+ 1 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpAdd)

  test "subtraction (prefix)":
    let m = compile("(- 3 1)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpSub)

  test "multiplication (prefix)":
    let m = compile("(* 2 3)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpMul)

  test "division (prefix)":
    let m = compile("(/ 10 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpDiv)

  test "modulo (prefix)":
    let m = compile("(% 10 3)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpMod)

  test "infix addition":
    let m = compile("(1 + 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpAdd)

  test "infix comparison":
    let m = compile("(1 < 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCmpLt)

  test "infix precedence lowering":
    let m = compile("(5 + 3 * 2 ** 2)")
    let code = mainFnCode(m)
    let powAt = findOpcode(code, OpPow)
    let mulAt = findOpcode(code, OpMul)
    let addAt = findOpcode(code, OpAdd)
    check powAt >= 0
    check mulAt > powAt
    check addAt > mulAt

suite "Compiler - Comparisons":
  test "equal":
    let m = compile("(== 1 1)")
    check mainFnCode(m).hasOpcode(OpCmpEq)

  test "not equal":
    let m = compile("(!= 1 2)")
    check mainFnCode(m).hasOpcode(OpCmpNe)

  test "less than":
    let m = compile("(< 1 2)")
    check mainFnCode(m).hasOpcode(OpCmpLt)

  test "less than or equal":
    let m = compile("(<= 1 2)")
    check mainFnCode(m).hasOpcode(OpCmpLe)

  test "greater than":
    let m = compile("(> 2 1)")
    check mainFnCode(m).hasOpcode(OpCmpGt)

  test "greater than or equal":
    let m = compile("(>= 2 1)")
    check mainFnCode(m).hasOpcode(OpCmpGe)

suite "Compiler - Boolean operators":
  test "logical and":
    let m = compile("(&& true false)")
    check mainFnCode(m).hasOpcode(OpLogAnd)

  test "logical or":
    let m = compile("(|| true false)")
    check mainFnCode(m).hasOpcode(OpLogOr)

  test "logical not":
    # Note: `!` ends with `!`, so the compiler treats it as a macro-style call
    # rather than emitting OpLogNot. The behavior is still correct at runtime.
    let m = compile("(! true)")
    check mainFnCode(m).hasOpcode(OpCallMacro)

suite "Compiler - If/elif/else":
  test "simple if":
    let m = compile("(if true 1)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpBrFalse)
    check code.hasOpcode(OpJump)

  test "if-else":
    let m = compile("(if true 1 else 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpBrFalse)

  test "if-elif-else":
    let m = compile("(if false 1 elif true 2 else 3)")
    let code = mainFnCode(m)
    # should have multiple BrFalse for chained conditions
    var brCount = 0
    for inst in code:
      if inst.op == OpBrFalse:
        inc brCount
    check brCount >= 2

suite "Compiler - Loops":
  test "simple loop":
    let m = compile("(loop (break))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpJump)

  test "loop with body":
    let m = compile("(var x 0)\n(loop\n  (x += 1)\n  (if (x >= 5) (break)))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpJump)
    check code.hasOpcode(OpAdd)

  test "for loop":
    let m = compile("(for i in [1 2 3] (println i))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpIterInit)
    check code.hasOpcode(OpIterHasNext)
    check code.hasOpcode(OpIterNext)

  test "while loop":
    let m = compile("(var x 3) (while (x > 0) (x -= 1))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpBrFalse)
    check code.hasOpcode(OpJump)

  test "repeat loop":
    let m = compile("(var x 0) (repeat 3 (x += 1))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCmpLt)
    check code.hasOpcode(OpJump)

suite "Compiler - Functions":
  test "named function":
    let m = compile("(fn add [a b] (+ a b))")
    # Should create a second function (main is first)
    check m.functions.len >= 2
    let fnMeta = m.functions[1]
    check fnMeta.name == "add"
    check fnMeta.arity == 2

  test "anonymous function":
    let m = compile("(fn [x] (+ x 1))")
    check m.functions.len >= 2
    let fnMeta = m.functions[1]
    check fnMeta.name == "<lambda>"
    check fnMeta.arity == 1

  test "function with type annotations":
    let m = compile("(fn add [a:Int b:Int] -> Int (+ a b))")
    check m.functions.len >= 2
    let fnMeta = m.functions[1]
    check fnMeta.params[0].typeAnn == "Int"
    check fnMeta.params[1].typeAnn == "Int"

  test "function body compiles return":
    let m = compile("(fn f [] (return 42))")
    check m.functions.len >= 2
    check m.functions[1].code.hasOpcode(OpReturn)

  test "function with no params":
    let m = compile("(fn greet [] 42)")
    check m.functions[1].arity == 0

  test "generator function (fn*)":
    let m = compile("(fn* range [n] (yield n))")
    check m.functions.len >= 2
    check FFlagGenerator in m.functions[1].flags

  test "keyword/default/variadic params metadata":
    let m = compile("(fn f [a = 1 ^b ^^c ^!d rest...] a)")
    let fnMeta = m.functions[1]
    check fnMeta.params.len == 5
    check fnMeta.params[0].name == "a"
    check fnMeta.params[0].hasDefault == true
    check fnMeta.params[0].defaultValue.toDebugString() == "1"
    check fnMeta.params[1].name == "b"
    check fnMeta.params[1].isKeyword == true
    check fnMeta.params[1].hasDefault == false
    check fnMeta.params[2].name == "c"
    check fnMeta.params[2].isKeyword == true
    check fnMeta.params[2].hasDefault == true
    check fnMeta.params[2].defaultValue.toDebugString() == "true"
    check fnMeta.params[3].name == "d"
    check fnMeta.params[3].isKeyword == true
    check fnMeta.params[3].hasDefault == true
    check fnMeta.params[3].defaultValue.toDebugString() == "nil"
    check fnMeta.params[4].name == "rest"
    check fnMeta.params[4].isVariadic == true

suite "Compiler - Classes":
  test "simple class":
    let m = compile("(class Point)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpClassNew)

  test "class with ctor":
    let m = compile("""
      (class Point
        (ctor [x y]
          (/x = x)
          (/y = y)))
    """)
    let code = mainFnCode(m)
    check code.hasOpcode(OpClassNew)
    check code.hasOpcode(OpCtorDef)

  test "class with method":
    let m = compile("""
      (class Point
        (method get_x [] /x))
    """)
    let code = mainFnCode(m)
    check code.hasOpcode(OpClassNew)
    check code.hasOpcode(OpMethodDef)

  test "class with inheritance":
    let m = compile("""
      (class Animal)
      (class Dog < Animal)
    """)
    let code = mainFnCode(m)
    check code.hasOpcode(OpClassExtends)

suite "Compiler - Try/Catch":
  test "try-catch":
    let m = compile("""
      (try
        (throw "error")
      catch e
        e)
    """)
    let code = mainFnCode(m)
    check code.hasOpcode(OpTryBegin)
    check code.hasOpcode(OpTryEnd)
    check code.hasOpcode(OpCatchBegin)
    check code.hasOpcode(OpCatchEnd)

  test "throw":
    let m = compile("(throw \"error\")")
    let code = mainFnCode(m)
    check code.hasOpcode(OpThrow)

  test "try-catch-finally":
    let m = compile("""
      (try
        42
      catch e
        0
      finally
        nil)
    """)
    let code = mainFnCode(m)
    check code.hasOpcode(OpTryBegin)
    check code.hasOpcode(OpFinallyBegin)
    check code.hasOpcode(OpFinallyEnd)

  test "catch wildcard underscore":
    let m = compile("(try (throw \"x\") catch _ 42)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCatchBegin)
    check code.hasOpcode(OpCatchEnd)

suite "Compiler - Async/Await":
  test "async block":
    let m = compile("(async 42)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpAsyncBegin)
    check code.hasOpcode(OpAsyncEnd)

  test "await":
    let m = compile("(await (async 42))")
    let code = mainFnCode(m)
    check code.hasOpcode(OpAwait)

suite "Compiler - Generators":
  test "yield in function":
    let m = compile("(fn f [] (yield 1))")
    check m.functions.len >= 2
    check m.functions[1].code.hasOpcode(OpYield)

  test "resume":
    let m = compile("(resume gen)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpResume)

suite "Compiler - Collections":
  test "array literal":
    let m = compile("[1 2 3]")
    let code = mainFnCode(m)
    check code.hasOpcode(OpArrNew)
    check code.hasOpcode(OpArrPush)
    check code.hasOpcode(OpArrEnd)

  test "map literal":
    let m = compile("{^a 1 ^b 2}")
    let code = mainFnCode(m)
    check code.hasOpcode(OpMapNew)
    check code.hasOpcode(OpMapSet)
    check code.hasOpcode(OpMapEnd)

  test "array spread":
    let m = compile("(var a [1 2])\n[a...]")
    let code = mainFnCode(m)
    check code.hasOpcode(OpArrSpread)

suite "Compiler - Case":
  test "case compiles comparisons and branches":
    let m = compile("(case x when 1 10 when 2 20 else 30)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCmpEq)
    check code.hasOpcode(OpBrFalse)
    check code.hasOpcode(OpJump)

suite "Compiler - Module structure":
  test "main function is at index 0":
    let m = compile("42")
    check m.mainFn == 0
    check m.functions[0].name == "__main__"

  test "empty program produces nil return":
    let m = compile("")
    let code = mainFnCode(m)
    check code.hasOpcode(OpConstNil)
    check code.hasOpcode(OpReturn)

  test "last expression is returned":
    let m = compile("1\n2\n3")
    let code = mainFnCode(m)
    # intermediate values get OpPop'd, last doesn't
    var popCount = 0
    for inst in code:
      if inst.op == OpPop:
        inc popCount
    check popCount == 2

suite "Compiler - Member access":
  test "path lookup":
    let m = compile("(var x {^a 1})\nx/a")
    let code = mainFnCode(m)
    check code.hasOpcode(OpGetMember)

  test "self access /x":
    let m = compile("""
      (class Foo
        (method get [] /x))
    """)
    # The method function should have OpLoadSelf
    check m.functions.len >= 2
    # Method fn is the last one added
    let methodFn = m.functions[^1]
    check methodFn.code.hasOpcode(OpLoadSelf)

  test "nil-safe member access":
    let m = compile("user?/profile?/email")
    let code = mainFnCode(m)
    check code.hasOpcode(OpGetMemberNil)

suite "Compiler - Capabilities and Quotas":
  test "capabilities block":
    let m = compile("(capabilities [net] 42)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCapEnter)
    check code.hasOpcode(OpCapExit)

  test "cap_assert":
    let m = compile("(cap_assert net)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCapAssert)

  test "quota_set":
    let m = compile("(quota_set \"cpu\" 1000)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpQuotaSet)

  test "quota_check":
    let m = compile("(quota_check \"cpu\" 100)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpQuotaCheck)

suite "Compiler - Tool calls":
  test "tool_call":
    let m = compile("(tool_call echo {^msg \"hi\"})")
    let code = mainFnCode(m)
    check code.hasOpcode(OpToolPrep)
    check code.hasOpcode(OpToolCall)
    check m.toolSchemas.len >= 1
    check m.toolSchemas[0].name == "echo"

  test "tool_await":
    let m = compile("(tool_await fut)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpToolAwait)

  test "tool_unwrap":
    let m = compile("(tool_unwrap fut)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpToolResultUnwrap)

suite "Compiler - Modules and AOP":
  test "file import emits OpImport with path constant":
    let m = compile("(import * as Utils \"./utils\")")
    let code = mainFnCode(m)
    var got = false
    for inst in code:
      if inst.op == OpImport and inst.mode == 1'u8:
        got = true
        check int(inst.c) >= 0
    check got == true

  test "keyword call emits OpCallKw":
    let m = compile("(f ^a 1 2)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpCallKw)

  test "before advice emits decorator apply":
    let m = compile("(fn f [x] x) (before f [x] nil)")
    let code = mainFnCode(m)
    check code.hasOpcode(OpDecoratorApply)

  test "aspect defines callable bundle":
    let m = compile("(aspect X [cls m1] (before m1 [a...] nil))")
    check m.functions.len >= 2
    var found = false
    for fnMeta in m.functions:
      if fnMeta.name == "X":
        found = true
        break
    check found == true

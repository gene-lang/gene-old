import std/[unittest, tables]
import ../src/types
import ../src/parser

suite "Parser - Primitives":
  test "parse nil":
    let node = parseOne("nil")
    check node.kind == AkNil

  test "parse true":
    let node = parseOne("true")
    check node.kind == AkBool
    check node.boolVal == true

  test "parse false":
    let node = parseOne("false")
    check node.kind == AkBool
    check node.boolVal == false

  test "parse integer":
    let node = parseOne("42")
    check node.kind == AkInt
    check node.intVal == 42

  test "parse negative integer":
    let node = parseOne("-7")
    check node.kind == AkInt
    check node.intVal == -7

  test "parse zero":
    let node = parseOne("0")
    check node.kind == AkInt
    check node.intVal == 0

  test "parse float":
    let node = parseOne("3.14")
    check node.kind == AkFloat
    check abs(node.floatVal - 3.14) < 0.001

  test "parse string":
    let node = parseOne("\"hello\"")
    check node.kind == AkString
    check node.text == "hello"

  test "parse empty string":
    let node = parseOne("\"\"")
    check node.kind == AkString
    check node.text == ""

  test "parse string with escape sequences":
    let node = parseOne("\"line1\\nline2\"")
    check node.kind == AkString
    check node.text == "line1\nline2"

  test "parse tab escape":
    let node = parseOne("\"a\\tb\"")
    check node.kind == AkString
    check node.text == "a\tb"

  test "parse symbol":
    let node = parseOne("foo")
    check node.kind == AkSymbol
    check node.text == "foo"

  test "parse symbol with special chars":
    let node = parseOne("foo-bar_baz")
    check node.kind == AkSymbol
    check node.text == "foo-bar_baz"

suite "Parser - Keywords":
  test "parse keyword":
    let node = parseOne("^name")
    check node.kind == AkKeyword
    check node.text == "name"

  test "parse keyword with double caret (implicit true)":
    let node = parseOne("^^verbose")
    check node.kind == AkKeyword
    check node.text == "^verbose"

  test "parse keyword with bang (implicit nil)":
    let node = parseOne("^!debug")
    check node.kind == AkKeyword
    check node.text == "!debug"

suite "Parser - Quotes":
  test "parse backtick quote":
    let node = parseOne("`foo")
    check node.kind == AkQuote
    check node.quoted.kind == AkSymbol
    check node.quoted.text == "foo"

  test "parse quoted list":
    let node = parseOne("`(a b c)")
    check node.kind == AkQuote
    check node.quoted.kind == AkList
    check node.quoted.items.len == 3

  test "parse single-quote":
    let node = parseOne("'foo")
    check node.kind == AkQuote
    check node.quoted.kind == AkSymbol

suite "Parser - Lists (S-expressions)":
  test "parse empty list":
    let node = parseOne("()")
    check node.kind == AkList
    check node.items.len == 0

  test "parse simple list":
    let node = parseOne("(+ 1 2)")
    check node.kind == AkList
    check node.items.len == 3
    check node.items[0].kind == AkSymbol
    check node.items[0].text == "+"
    check node.items[1].kind == AkInt
    check node.items[1].intVal == 1
    check node.items[2].kind == AkInt
    check node.items[2].intVal == 2

  test "parse nested lists":
    let node = parseOne("(+ (- 3 1) 2)")
    check node.kind == AkList
    check node.items.len == 3
    check node.items[1].kind == AkList
    check node.items[1].items.len == 3

  test "parse deeply nested":
    let node = parseOne("(a (b (c d)))")
    check node.kind == AkList
    check node.items.len == 2
    let inner = node.items[1]
    check inner.kind == AkList
    check inner.items[1].kind == AkList

  test "parse list with keywords":
    let node = parseOne("(foo ^a 1 ^b 2)")
    check node.kind == AkList
    # keywords get expanded in-list
    check node.items.len == 5

suite "Parser - Arrays":
  test "parse empty array":
    let node = parseOne("[]")
    check node.kind == AkArray
    check node.items.len == 0

  test "parse array with values":
    let node = parseOne("[1 2 3]")
    check node.kind == AkArray
    check node.items.len == 3
    check node.items[0].kind == AkInt
    check node.items[0].intVal == 1
    check node.items[2].intVal == 3

  test "parse mixed type array":
    let node = parseOne("[1 \"hello\" true nil]")
    check node.kind == AkArray
    check node.items.len == 4
    check node.items[0].kind == AkInt
    check node.items[1].kind == AkString
    check node.items[2].kind == AkBool
    check node.items[3].kind == AkNil

  test "parse nested array":
    let node = parseOne("[[1 2] [3 4]]")
    check node.kind == AkArray
    check node.items.len == 2
    check node.items[0].kind == AkArray
    check node.items[0].items.len == 2

suite "Parser - Maps":
  test "parse empty map":
    let node = parseOne("{}")
    check node.kind == AkMap
    check node.entries.len == 0

  test "parse map with keyword keys":
    let node = parseOne("{^a 1 ^b 2}")
    check node.kind == AkMap
    check node.entries.len == 2
    check node.entries[0].key.kind == AkKeyword
    check node.entries[0].key.text == "a"
    check node.entries[0].value.kind == AkInt
    check node.entries[0].value.intVal == 1

  test "parse map with implicit true":
    let node = parseOne("{^^a}")
    check node.kind == AkMap
    check node.entries.len == 1
    check node.entries[0].key.kind == AkKeyword
    check node.entries[0].key.text == "a"
    check node.entries[0].value.kind == AkBool
    check node.entries[0].value.boolVal == true

  test "parse map with implicit nil":
    let node = parseOne("{^!a}")
    check node.kind == AkMap
    check node.entries.len == 1
    check node.entries[0].key.text == "a"
    check node.entries[0].value.kind == AkNil

  test "parse nested map shorthand":
    let node = parseOne("{^a^b 1}")
    check node.kind == AkMap
    check node.entries.len == 1
    check node.entries[0].key.kind == AkKeyword
    check node.entries[0].key.text == "a"
    check node.entries[0].value.kind == AkMap
    check node.entries[0].value.entries.len == 1
    check node.entries[0].value.entries[0].key.kind == AkKeyword
    check node.entries[0].value.entries[0].key.text == "b"
    check node.entries[0].value.entries[0].value.kind == AkInt
    check node.entries[0].value.entries[0].value.intVal == 1

  test "parse nested map shorthand with implicit true":
    let node = parseOne("{^a^^b}")
    check node.kind == AkMap
    check node.entries.len == 1
    check node.entries[0].value.kind == AkMap
    check node.entries[0].value.entries[0].value.kind == AkBool
    check node.entries[0].value.entries[0].value.boolVal == true

  test "parse nested map shorthand with implicit nil":
    let node = parseOne("{^a^!b}")
    check node.kind == AkMap
    check node.entries.len == 1
    check node.entries[0].value.kind == AkMap
    check node.entries[0].value.entries[0].value.kind == AkNil

suite "Parser - Comments":
  test "skip line comment":
    let prog = parseProgram("# this is a comment\n42")
    check prog.exprs.len == 1
    check prog.exprs[0].kind == AkInt
    check prog.exprs[0].intVal == 42

  test "skip inline comment":
    let prog = parseProgram("(+ 1 2) # comment")
    check prog.exprs.len == 1
    check prog.exprs[0].kind == AkList

  test "comment-only input":
    let prog = parseProgram("# just a comment")
    check prog.exprs.len == 0

suite "Parser - String Interpolation":
  test "simple interpolation":
    let node = parseOne("\"hello ${name}\"")
    check node.kind == AkInterpolatedString
    check node.parts.len == 2
    check node.parts[0].kind == AkString
    check node.parts[0].text == "hello "
    check node.parts[1].kind == AkSymbol
    check node.parts[1].text == "name"

  test "no interpolation is plain string":
    let node = parseOne("\"just text\"")
    check node.kind == AkString
    check node.text == "just text"

  test "hash interpolation":
    let node = parseOne("\"hello #{name}\"")
    check node.kind == AkInterpolatedString
    check node.parts.len == 2
    check node.parts[0].kind == AkString
    check node.parts[0].text == "hello "
    check node.parts[1].kind == AkSymbol
    check node.parts[1].text == "name"

suite "Parser - Program":
  test "parse multiple expressions":
    let prog = parseProgram("1 2 3")
    check prog.exprs.len == 3
    check prog.exprs[0].kind == AkInt
    check prog.exprs[1].kind == AkInt
    check prog.exprs[2].kind == AkInt

  test "parse empty program":
    let prog = parseProgram("")
    check prog.exprs.len == 0

  test "parse whitespace-only program":
    let prog = parseProgram("   \n\n  ")
    check prog.exprs.len == 0

suite "Parser - Semicolons":
  test "semicolon chains":
    let node = parseOne("(a; b)")
    check astToString(node) == "((a) b)"

  test "semicolon chains (three segments)":
    let node = parseOne("(a; b; c)")
    check astToString(node) == "(((a) b) c)"

  test "semicolon chains with props":
    let node = parseOne("(a ^x 1; b ^y 2; c)")
    check astToString(node) == "(((a ^x 1) b ^y 2) c)"

suite "Parser - Parser Macro":
  test "#@ parser macro":
    let node = parseOne("#@f x")
    check node.kind == AkList
    check astToString(node) == "(f x)"

  test "#@ parser macro in list":
    let node = parseOne("(x ^a #@f 1 ^b 2 c)")
    check node.kind == AkList
    check astToString(node) == "(x ^a (f 1) ^b 2 c)"

suite "Parser - Spread operator":
  test "spread in array":
    let node = parseOne("[a...]")
    check node.kind == AkArray
    check node.items.len == 1
    check node.items[0].kind == AkSymbol
    check node.items[0].text == "a..."

suite "Parser - astToString":
  test "nil to string":
    check astToString(parseOne("nil")) == "nil"

  test "int to string":
    check astToString(parseOne("42")) == "42"

  test "symbol to string":
    check astToString(parseOne("foo")) == "foo"

  test "list to string":
    check astToString(parseOne("(+ 1 2)")) == "(+ 1 2)"

  test "array to string":
    check astToString(parseOne("[1 2 3]")) == "[1 2 3]"

suite "Parser - Error handling":
  test "unterminated string":
    expect ParseError:
      discard parseOne("\"unterminated")

  test "unterminated list":
    expect ParseError:
      discard parseOne("(a b c")

  test "unterminated array":
    expect ParseError:
      discard parseOne("[1 2 3")

  test "empty keyword":
    expect ParseError:
      discard parseOne("^")

suite "Parser - quotedAstToValue":
  test "quoted nil":
    let v = quotedAstToValue(parseOne("nil"))
    check isNil(v)

  test "quoted integer":
    let v = quotedAstToValue(parseOne("42"))
    check isInt(v)
    check asInt(v) == 42

  test "quoted string":
    let v = quotedAstToValue(parseOne("\"hello\""))
    let s = asStringObj(v)
    check s != nil
    check s.value == "hello"

  test "quoted array":
    let v = quotedAstToValue(parseOne("[1 2 3]"))
    let arr = asArrayObj(v)
    check arr != nil
    check arr.items.len == 3

  test "quoted gene (list)":
    let v = quotedAstToValue(parseOne("(Point ^x 1 ^y 2)"))
    let g = asGeneObj(v)
    check g != nil
    check len(g.props) == 2

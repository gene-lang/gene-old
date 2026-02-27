# To run these tests, simply execute `nimble test` or `nim c -r tests/test_parser.nim`

import unittest, options, tables

import gene/types except Exception

import ./helpers

# 0b... Bin
# 0x... Hex
# (#Base64 ...)  Base64

# Parser options:
# A map of name->stack is used to store parser options
# A cache of computed options are stored, and refreshed whenever any of below commands is found.
# (#Set name value)
# (#Unset name...) - will clear non-pushed top value of the stack
# (#Reset name...) - will clear all non-pushed values of the stack
# (#Push name value)
# Set vs Push:
# Options are applicable to end of document or until it's changed by further Set/Unset/....
# Options are applicable to gene/array/map and will be removed automatically
# Push is recommended over Set

# Usecases:
# (#Set x 1) (#Get x) -> 1
# [(#Set x 1)] (#Get x) -> 1

# (#Push x 1) (#Get x) -> 1
# [(#Push x 1)] (#Get x) -> nil

# [(#Push x 1) (#Set x 2)] (#Get x) -> 2
# ...

# Parsing from a stream (like a log file that is being written to continually, or an incoming socket)
# Parsing can be interrupted in these cases - what is the best way to stop?

test_parser "nil", NIL
test_parser "true", TRUE
test_parser "false", FALSE

test_parser "10", 10
test_parser "-1", -1  # With NaN boxing, negative integers are properly supported
test_parser "10e10", 10e10
test_parser "+5.0E5", +5.0E5

# Character literals now use 'a' syntax, not \a
test_parser "'a'", 'a'
test_parser "'b'", 'b'
test_parser "'Z'", 'Z'
test_parser "'0'", '0'
test_parser "' '", ' '
test_parser "'\\n'", '\n'
test_parser "'\\t'", '\t'
test_parser "'\\r'", '\r'
test_parser "'\\f'", '\f'
test_parser "'\\b'", '\b'
test_parser "'\\\\'", '\\'
# Unicode characters don't fit in a single char, skip for now
# test_parser "'中'", "中".runeAt(0)

# These are no longer valid - \ is not a macro anymore
# test_parser "\\\"nil\"", to_symbol_value("nil")
# test_parser "\\\"true\"", to_symbol_value("true")
# test_parser "\\'nil'", to_symbol_value("nil")

test_parser "\"test\"", "test"
test_parser ",\"test\",", "test"
# Single quotes are for characters now, not strings
# test_parser "'test'", "test"  
# test_parser ",'test',", "test"

test_parser "a", to_symbol_value("a")
test_parser "A", to_symbol_value("A")
test_parser "/", to_symbol_value("/")
test_parser "+a", to_symbol_value("+a")
test_parser "#a", to_symbol_value("#a")
test_parser "a#b", to_symbol_value("a#b")
test_parser "a:b", to_symbol_value("a:b")
test_parser "a\\ b", to_symbol_value("a b")
test_parser "a\\/b", to_symbol_value("a/b")
test_parser "n/A", to_complex_symbol(@["n", "A"])
test_parser "n\\/A/B", to_complex_symbol(@["n/A", "B"])
test_parser "n/m/A", to_complex_symbol(@["n", "m", "A"])
test_parser "/A", to_complex_symbol(@["", "A"])
test_parser "^a", to_symbol_value("^a")
test_parser "symbol-👋", to_symbol_value("symbol-👋")
test_parser "+foo+", to_symbol_value("+foo+")

test_parser "#/b/", proc(r: Value) =
  check r.kind == VkRegex
  check r.ref.regex_pattern == "b"
  check r.ref.regex_flags == 0

test_parser "#/a\\/b/", proc(r: Value) =
  check r.kind == VkRegex
  check r.ref.regex_pattern == "a/b"

test_parser "#/b/i", proc(r: Value) =
  check r.kind == VkRegex
  check (r.ref.regex_flags and REGEX_FLAG_IGNORE_CASE) != 0

test_parser "#/(\\d)/[\\1]/m", proc(r: Value) =
  check r.kind == VkRegex
  check r.ref.regex_pattern == "(\\d)"
  check r.ref.regex_has_replacement
  check r.ref.regex_replacement == "[\\1]"
  check (r.ref.regex_flags and REGEX_FLAG_MULTILINE) != 0

# test_parser "2020-12-02", new_gene_date(2020, 12, 02)
# test_parser "2020-12-02T10:11:12Z",
#   new_gene_datetime(init_date_time(02, cast[Month](12), 2020, 10, 11, 12, utc()))
# test_parser "10:11:12", new_gene_time(10, 11, 12)

test_parser "{}", new_map_value()
test_parser "{^a 1}", {"a": to_value(1)}.to_value()
test_parser "{^a\\/b 1}", {"a/b": to_value(1)}.to_value()

test_parser "{^a^b 1}", to_value({"a": to_value({"b": to_value(1)})})
test_parser "{^a^^b}", to_value({"a": to_value({"b": TRUE})})
test_parser "{^a^!b}", to_value({"a": to_value({"b": FALSE})})
test_parser "{^a^b 1 ^a^c 2}", to_value({"a": to_value({"b": to_value(1), "c": to_value(2)})})
test_parser "{^a^^b ^a^c 2}", to_value({"a": to_value({"b": TRUE, "c": to_value(2)})})
# test_parser "{^a^b 1 ^a {^c 2}}", {"a": to_value({"b": to_value(1), "c": to_value(2)}.toTable)}.toTable
test_parser_error "{^a^b 1 ^a 2}"
test_parser_error "{^a^b 1 ^a {^c 2}}"

test_parser "(_ ^a^b 1)", proc(r: Value) =
  assert map_data(r.gene.props["a".to_key()])["b".to_key()] == 1
test_parser "(_ ^a^^b 1)", proc(r: Value) =
  assert map_data(r.gene.props["a".to_key()])["b".to_key()] == TRUE
  assert r.gene.children[0] == 1

test_parser "[]", @[]
test_parser "[,]", @[]
test_parser "[1 2]", new_array_value(to_value(1), to_value(2))
test_parser "[1, 2]", new_array_value(to_value(1), to_value(2))

test_parser "#[]", proc(r: Value) =
  check r.kind == VkStream
  check r.ref.stream.len == 0
  check r.ref.stream_index == 0
  check not r.ref.stream_ended

test_parser "#[1 2]", proc(r: Value) =
  check r.kind == VkStream
  check r.ref.stream.len == 2
  check r.ref.stream[0].to_int() == 1
  check r.ref.stream[1].to_int() == 2

test_parser "#[\"hello\" 42 true]", proc(r: Value) =
  check r.kind == VkStream
  check r.ref.stream.len == 3
  check r.ref.stream[0].kind == VkString
  check r.ref.stream[0].str == "hello"
  check r.ref.stream[1].to_int() == 42
  check r.ref.stream[2] == TRUE

test_parser "#[[1] [2]]", proc(r: Value) =
  check r.kind == VkStream
  check r.ref.stream.len == 2
  for idx, item in r.ref.stream:
    check item.kind == VkArray
    check array_data(item).len == 1
    check array_data(item)[0].to_int() == idx + 1

test_parser "#[1 2 3 4 5 6 7 8 9 10]", proc(r: Value) =
  check r.kind == VkStream
  check r.ref.stream.len == 10
  for idx, item in r.ref.stream:
    check item.to_int() == idx + 1

test_parser_error "#[1 2"

test_parser ",a", to_symbol_value("a")
test_parser "a,", to_symbol_value("a")

test_parser "1 2 3", 1

test_parser "()", proc(r: Value) =
  let gene = r.gene
  check gene.type == NIL
  check gene.props.len == 0
  check gene.children.len == 0

test_parser "(())", proc(r: Value) =
  check r.kind == VkGene
  let gene = r.gene
  check gene.children.len == 0
  check gene.type.kind == VkGene
  check gene.type.gene.children.len == 0

test_parser "(1 2 3)", proc(r: Value) =
  check r.gene.type == 1
  check r.gene.children == @[to_value(2), to_value(3)]

test_parser "(nil 2 3)", proc(r: Value) =
  check r.gene.type.kind == VkNil
  check r.gene.children == @[to_value(2), to_value(3)]

test_parser """
  (_ 1 "test")
""", proc(r: Value) =
  check r.gene.children[0] == 1
  check r.gene.children[1] == "test"

test_parser "(1 ^a 2 3 4)", proc(r: Value) =
  check r.gene.type == 1
  check r.gene.props == to_table({"a".to_key(): to_value(2)})
  check r.gene.children == @[to_value(3), to_value(4)]

test_parser "(1 2 ^a 3 4)", proc(r: Value) =
  check r.gene.type == 1
  check r.gene.props == to_table({"a".to_key(): to_value(3)})
  check r.gene.children == @[to_value(2), to_value(4)]

test_parser "(1 ^^a 2 3)", proc(r: Value) =
  check r.gene.type == 1
  check r.gene.props == to_table({"a".to_key(): TRUE})
  check r.gene.children == @[to_value(2), to_value(3)]

test_parser "(1 ^!a 2 3)", proc(r: Value) =
  check r.gene.type == 1
  check r.gene.props == to_table({"a".to_key(): NIL})
  check r.gene.children == @[to_value(2), to_value(3)]

test_parser "{^^x ^!y ^^z}", proc(r: Value) =
  check r.kind == VkMap
  check map_data(r) == to_table({"x".to_key(): TRUE, "y".to_key(): NIL, "z".to_key(): TRUE})

test_parser ":foo", proc(r: Value) =
  check r.kind == VkSymbol
  check r == to_symbol_value(":foo")

test_parser "`foo", proc(r: Value) =
  check r.ref.kind == VkQuote
  check r.ref.quote == to_symbol_value("foo")

test_parser "%foo", proc(r: Value) =
  check r.ref.kind == VkUnquote
  check r.ref.unquote == to_symbol_value("foo")
  check r.ref.unquote_discard == false

test_parser "%_foo", proc(r: Value) =
  check r.ref.kind == VkUnquote
  check r.ref.unquote == to_symbol_value("foo")
  check r.ref.unquote_discard == true

test_parser "%(1 + 2)", proc(r: Value) =
  check r.ref.kind == VkUnquote
  check r.ref.unquote.kind == VkGene
  check r.ref.unquote.gene.type == 1
  check r.ref.unquote.gene.children[0] == to_symbol_value("+")
  check r.ref.unquote.gene.children[1] == 2

# Additional tests for Gene expressions
test_parser "`(1 + 2)", proc(r: Value) =
  check r.ref.kind == VkQuote
  check r.ref.quote.kind == VkGene
  check r.ref.quote.gene.type == 1
  check r.ref.quote.gene.children[0] == to_symbol_value("+")
  check r.ref.quote.gene.children[1] == 2

test_parser "(_ 1 2)", proc(r: Value) =
  check r.kind == VkGene
  check r.gene.type == to_symbol_value("_")
  check r.gene.children[0] == 1
  check r.gene.children[1] == 2

test_parser "(`a 1 2)", proc(r: Value) =
  check r.kind == VkGene
  check r.gene.type.ref.kind == VkQuote
  check r.gene.type.ref.quote == to_symbol_value("a")
  check r.gene.children[0] == 1
  check r.gene.children[1] == 2

# # TODO: %_ is not allowed on gene type and property value
# # (%_foo)         should throw error
# # (a ^name %_foo) should throw error
# # {^name %_foo}   should throw error

# # test_parser "#_ [foo bar]", proc(r: Value) =
# #   check r == nil

# test_parser "1/2", proc(r: Value) =
#   check r.kind == VkRatio
#   check r.ratio_num == BiggestInt(1)
#   check r.ratio_denom == BiggestInt(2)

# test_parser "{^ratio -1/2}", proc(r: Value) =
#   check r.kind == VkMap
#   check r.map["ratio"] == new_gene_ratio(-1, 2)

# test_parser_error """
#   # Gene properties should not be mixed with children like below
#   (a ^b b c ^d d) # b & d are properties but are separated by c
# """

# test_parser_error "{^ratio 1/-2}"

# test_parser "0!11", proc(r: Value) =
#   check r.kind == VkByte
#   check r.byte_bit_size == 2
#   check r.byte == 3

# test_parser "0!11110000", proc(r: Value) =
#   check r.kind == VkByte
#   check r.byte_bit_size == 8
#   check r.byte == 240

# test_parser "0!1111~ 0000", proc(r: Value) =
#   check r.kind == VkByte
#   check r.byte_bit_size == 8
#   check r.byte == 240

# test_parser "0!000011110000", proc(r: Value) =
#   check r.kind == VkBin
#   check r.bin_bit_size == 12
#   check r.bin == @[uint8(15), uint8(0)]

# test_parser "0*a0", proc(r: Value) =
#   check r.kind == VkByte
#   check r.byte_bit_size == 8
#   check r.byte == 160

# test_parser "0*A0", proc(r: Value) =
#   check r.kind == VkByte
#   check r.byte_bit_size == 8
#   check r.byte == 160

# test_parser "0*a003", proc(r: Value) =
#   check r.kind == VkBin
#   check r.bin_bit_size == 16
#   check r.bin == @[uint8(160), uint8(3)]

# test_parser "0*a0~ 03", proc(r: Value) =
#   check r.kind == VkBin
#   check r.bin_bit_size == 16
#   check r.bin == @[uint8(160), uint8(3)]

# test_parser "0#ABCD", proc(r: Value) =
#   check r.kind == VkBin
#   check r.bin_bit_size == 24
#   check r.bin == @[uint8(0), uint8(16), uint8(131)]

# test_parser "0#AB~ CD", proc(r: Value) =
#   check r.kind == VkBin
#   check r.bin_bit_size == 24
#   check r.bin == @[uint8(0), uint8(16), uint8(131)]

# # Unit conversion
# test_parser """
#   1m # 1m = 1 minute = 60 seconds (1 = 1s = 1 second)
# """, 60
# test_parser """
#   1s
# """, 1
# test_parser """
#   1ms
# """, 0.001
# # test_parser """
# #   (#Unit "m" 1)  # 1m = 1 meter (meter is defined as the default unit for length)
# #   1m
# # """, 1
# test_parser """
#   1m30s
# """, 90
# test_parser """
#   1s500ms
# """, 1.5
# # test_parser """
# #   1m30
# # """, 90

# Support decorator from the parser. It can appear anywhere except property names.
# Pros:
#   Easier to write
# Cons:
#   Harder to read ?!
#
# #@f a       = (f a)
# (#@f a)     = ((f a))
# (#@f #@g a) = ((f (g a)))
# #@(f a) b   = (((f a) b))
# {^p #@f a}  = {^p (f a)}

test_parser """
  #@f a
""", proc(r: Value) =
  check r.kind == VkGene
  check r.gene.type.str == "f"
  check r.gene.children[0].str == "a"

test_parser """
  #@f #@g a
""", proc(r: Value) =
  check r.kind == VkGene
  check r.gene.type.str == "f"
  check r.gene.children[0].kind == VkGene
  check r.gene.children[0].gene.type.str == "g"
  check r.gene.children[0].gene.children[0].str == "a"

# test_parser """
#   #*f
# """, proc(r: Value) =
#   check r.kind == VkGene
#   check r.gene_type.str == "f"

test_parser """
  {^p #@f a}
""", proc(r: Value) =
  check map_data(r)["p".to_key()].kind == VkGene
  check map_data(r)["p".to_key()].gene.type.str == "f"
  check map_data(r)["p".to_key()].gene.children[0].str == "a"

test_read_all "nil", proc(r: seq[Value]) =
  check r[0] == NIL

test_read_all """
  1 # comment
  2
""", proc(r: seq[Value]) =
  check r[0] == 1
  check r[1] == 2

test_read_all """
  1 ##comment
  2
""", proc(r: seq[Value]) =
  check r[0] == 1
  check r[1] == 2

test_read_all "a,b", proc(r: seq[Value]) =
  check r[0] == to_symbol_value("a")
  check r[1] == to_symbol_value("b")

test_read_all "1 2", @[to_value(1), to_value(2)]

test_parser """
  [
    1 # test
  ]
""", @[1]

test_parser """
  #
  # comment
  #
  1
  #
""", 1

test_parser "[a/[1 2]]", proc(r: Value) =
  check array_data(r)[0].ref.csymbol[0] == "a"
  check array_data(r)[0].ref.csymbol[1] == ""
  check array_data(array_data(r)[1])[0] == 1
  check array_data(array_data(r)[1])[1] == 2

test_parser """
  #< comment ># 1
""", 1

test_parser """
  #< #<< comment >># ># 1
""", 1

test_parser """
  #<
  comment
  #># 1
""", 1

test_parser """
  #<
  comment
  #>## 1
  2
""", 2

test_parser """
  #<
  #<<
  comment
  #>>#
  #># 1
""", 1

# test_parse_document """
#   ^name "Test document"
#   ^version "0.1.0"
# """, proc(r: Document) =
#   check r.props["name"] == "Test document"
#   check r.props["version"] == "0.1.0"
#   check r.children.len == 0

# test_parse_document """
#   ^name "Test document"
#   1 2
# """, proc(r: Document) =
#   check r.props["name"] == "Test document"
#   check r.children == @[1, 2]

test_parser "\"\"\"a\"\"\"", "a"
test_parser "[\"\"\"a\"\"\"]", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 1
  check array_data(r)[0] == "a"

test_parser "\"\"\"a\"b\"\"\"", "a\"b"

# Trim whitespaces and new line after opening """
# E.g. """  \na""" => "a"
test_parser "\"\"\"  \na\"\"\"", "\na"
# Trim whitespaces before closing """
# E.g. """a\n   """ => "a\n"
test_parser "\"\"\"a\n   \"\"\"", "a\n"

# test_parser """
#   (#File "f" "abc")
# """, proc(r: Value) =
#   check r.kind == VkFile
#   check r.file_name == "f"
#   check r.file_content == "abc"

# test_parser """
#   (#File f "abc") # File name can be a symbol treated as a string literal
# """, proc(r: Value) =
#   check r.kind == VkFile
#   check r.file_name == "f"

# test_parser """
#   (#File "f" 0!11)
# """, proc(r: Value) =
#   check r.kind == VkFile
#   check r.file_name == "f"
#   var content = r.file_content
#   check content.kind == VkByte
#   check content.byte_bit_size == 2
#   check content.byte == 3

# test_parser """
#   (#Dir "d")
# """, proc(r: Value) =
#   check r.kind == VkDirectory
#   check r.dir_name == "d"

# test_parser """
#   (#Dir d) # Dir name can be a symbol treated as a string literal
# """, proc(r: Value) =
#   check r.kind == VkDirectory
#   check r.dir_name == "d"

# test_parser """
#   (#Dir "d"
#     (#File "f" "abc")
#   )
# """, proc(r: Value) =
#   check r.kind == VkDirectory
#   check r.dir_name == "d"
#   check r.dir_members.len == 1
#   var file = r.dir_members["f"]
#   check file.kind == VkFile
#   check file.file_name == "f"
#   check file.file_content == "abc"

# test_parser """
#   (#Gar x
#     (#File f "abc")
#     (#Dir "d"
#       (#File "f2" "def")
#     )
#   )
# """, proc(r: Value) =
#   check r.kind == VkArchiveFile
#   check r.arc_file_name == "x"
#   check r.arc_file_members.len == 2
#   var file = r.arc_file_members["f"]
#   check file.kind == VkFile
#   check file.file_name == "f"
#   check file.file_content == "abc"

# test_parse_archive """
#   (#Dir "d"
#     (#File "f" "abc")
#   )
# """, proc(r: Value) =
#   check r.kind == VkArchiveFile
#   var dir = r.arc_file_members["d"]
#   check dir.dir_name == "d"
#   var file = dir.dir_members["f"]
#   check file.kind == VkFile
#   check file.file_name == "f"
#   check file.file_content == "abc"

# test """Parser / read_stream:
#   1 2
# """:
#   var code = cleanup"""
#     1 2
#   """
#   var data = new_gene_vec()
#   proc handle(value: Value) =
#     data.vec.add(value)
#   var parser = new_parser()
#   parser.read_stream(code, handle)
#   check data == @[1, 2]

# test_parser """
#   (#Ignore) 1
# """, 1

# test_parser """
#   #&x
# """, proc(r: Value) =
#   check r.kind == VkReference
#   check r.reference.name == "x"

# test_parser """
#   (#Ref "x" 1)
# """, proc(r: Value) =
#   check r.kind == VkRefTarget
#   check r.ref_target.name  == "x"
#   check r.ref_target.value == 1

# test_parser """
#   [
#     (#Ref "x" 1)
#     #&x
#   ]
# """, proc(r: Value) =
#   let last = r.vec[^1]
#   check last.kind == VkReference
#   check last.reference.name  == "x"
#   check last.reference.value == 1

# test_parser """
#   [
#     #&x
#     (#Ref "x" 1)
#   ]
# """, proc(r: Value) =
#   let first = r.vec[0]
#   check first.kind == VkReference
#   check first.reference.name  == "x"
#   check first.reference.value == 1

# test_parser_error """
#   [
#     (#Ref "x" 1)
#     (#Ref "x" 2) # Should trigger parser error
#   ]
# """

# Semicolon chaining tests: (a; b; c) = (((a) b) c)
# This creates left-associative chaining where each semicolon
# wraps the previous expression as the type of a new gene

test_parser """
  (a; b)
""", proc(r: Value) =
  # (a; b) = ((a) b)
  check r.kind == VkGene
  # The type should be (a)
  check r.gene.type.kind == VkGene
  check r.gene.type.gene.type == to_symbol_value("a")
  check r.gene.type.gene.children.len == 0
  # The child should be b
  check r.gene.children.len == 1
  check r.gene.children[0] == to_symbol_value("b")

test_parser """
  (a; b; c)
""", proc(r: Value) =
  # (a; b; c) = (((a) b) c)
  check r.kind == VkGene
  # The type should be ((a) b)
  check r.gene.type.kind == VkGene
  let inner = r.gene.type
  # inner = ((a) b), its type should be (a)
  check inner.gene.type.kind == VkGene
  check inner.gene.type.gene.type == to_symbol_value("a")
  # inner's child should be b
  check inner.gene.children.len == 1
  check inner.gene.children[0] == to_symbol_value("b")
  # Outer child should be c
  check r.gene.children.len == 1
  check r.gene.children[0] == to_symbol_value("c")

test_parser """
  (a x; b y; c z)
""", proc(r: Value) =
  # (a x; b y; c z) = (((a x) b y) c z)
  check r.kind == VkGene
  # Outer children: [c, z]
  check r.gene.children.len == 2
  check r.gene.children[0] == to_symbol_value("c")
  check r.gene.children[1] == to_symbol_value("z")
  # Type is ((a x) b y)
  check r.gene.type.kind == VkGene
  let middle = r.gene.type
  check middle.gene.children.len == 2
  check middle.gene.children[0] == to_symbol_value("b")
  check middle.gene.children[1] == to_symbol_value("y")
  # Middle type is (a x)
  check middle.gene.type.kind == VkGene
  let inner = middle.gene.type
  check inner.gene.type == to_symbol_value("a")
  check inner.gene.children.len == 1
  check inner.gene.children[0] == to_symbol_value("x")

test_parser """
  (1; 2; 3)
""", proc(r: Value) =
  # (1; 2; 3) = (((1) 2) 3)
  check r.kind == VkGene
  check r.gene.children.len == 1
  check r.gene.children[0] == 3
  check r.gene.type.kind == VkGene
  let middle = r.gene.type
  check middle.gene.children.len == 1
  check middle.gene.children[0] == 2
  check middle.gene.type.kind == VkGene
  check middle.gene.type.gene.type == 1

# Test semicolon chaining with properties
test_parser """
  (a ^b c d; ^e f g)
""", proc(r: Value) =
  # (a ^b c d; ^e f g) = ((a ^b c d) ^e f g)
  check r.kind == VkGene
  # Outer gene: type=((a ^b c d)), props={e: f}, children=[g]
  check r.gene.props.len == 1
  check r.gene.props["e".to_key()] == to_symbol_value("f")
  check r.gene.children.len == 1
  check r.gene.children[0] == to_symbol_value("g")
  # Inner gene: type=a, props={b: c}, children=[d]
  check r.gene.type.kind == VkGene
  let inner = r.gene.type
  check inner.gene.type == to_symbol_value("a")
  check inner.gene.props.len == 1
  check inner.gene.props["b".to_key()] == to_symbol_value("c")
  check inner.gene.children.len == 1
  check inner.gene.children[0] == to_symbol_value("d")

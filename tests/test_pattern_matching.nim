import unittest

import gene/types except Exception

import ./helpers

# Pattern Binding
#
# * Argument parsing
# * (var pattern input)
#   Binding works similar to argument parsing
# * Custom matchers can be created, which takes something and
#   returns a function that takes an input and a scope object and
#   parses the input and stores as one or multiple variables
# * Every standard type should have an adapter to allow pattern matching
#   to access its data easily
# * Support "|" for different branches
#

# Mode: argument, bind, ...
# When matching arguments, root level name will match first item in the input
# While (var name value) binds the whole value
#
# Root level
# (var name input)
# (var _ input)
#
# Child level
# (var [a? b] input) # "a" is optional, if input contains only one item, it'll be
#                      # assigned to "b"
# (var [a... b] input) # "a" will match 0 to many items, the last item is assigned to "b"
# (var [a = 1 b] input) # "a" is optional and has default value of 1
#
# Grandchild level
# (var [a b [c]] input) # "c" will match a grandchild
#
# Match properties
# (var [^a] input)  # "a" will match input's property "a"
# (var [^a!] input) # "a" will match input's property "a" and is required
# (var [^a: var_a] input) # "var_a" will match input's property "a"
# (var [^a: var_a = 1] input) # "var_a" will match input's property "a", and has default
#                               # value of 1
#
# Q: How do we match gene_type?
# A: Use "*" to signify it. like "^" to signify properties. It does not support optional,
#    default values etc
#    [*type] will assign gene_type to "type"
#    [*: [...]] "*:" or "*name:" will signify that next item matches gene_type's internal structure
#

test_vm """
  (fn f [a]
    a
  )
  (f 1)
""", 1

test_vm """
  (fn f [a b]
    (a + b)
  )
  (f 1 2)
""", 3

test_vm """
  (var a [1])
  a
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 1
  check array_data(r)[0] == 1

# Array pattern matching
test_vm """
  (var [a] [1])
  a
""", 1

# Array pattern matching with multiple elements
test_vm """
  (var [a b] [1 2])
  (a + b)
""", 3

# Compatibility lowering: (match pattern value) -> (var pattern value)
test_vm """
  (match [a b] [1 2])
  (a + b)
""", 3

# TODO: match is not implemented in VM yet
# test_vm """
#   (var x (_ 1))
#   (match [a b = nil] x)
#   b
# """, Value(kind: VkNil)

# TODO: match is not implemented in VM yet
# test_vm """
#   (match
#     [:if cond :then logic1 :else logic2]
#     [:if 0    :then 1      :else 2]
#   )
#   cond
# """, 0

# TODO: match is not implemented in VM yet
# test_vm """
#   (match
#     [:if cond :then logic1 :else logic2]
#     [:if 0    :then 1      :else 2]
#   )
#   logic1
# """, 1

# TODO: match is not implemented in VM yet
# test_vm """
#   (match
#     [:if cond :then logic1 :else logic2]
#     [:if 0    :then 1      :else 2]
#   )
#   logic2
# """, 2

# TODO: match is not implemented in VM yet
# test_vm """
#   (match
#     [:if cond :then logic1... :else logic2...]
#     [:if 0    :then 1 2       :else 3 4]
#   )
#   logic1
# """, @[1, 2]

# TODO: match is not implemented in VM yet
# test_vm """
#   (match
#     [:if cond :then logic1... :else logic2...]
#     [:if 0    :then 1 2       :else 3 4]
#   )
#   logic2
# """, @[3, 4]

# proc test_arg_matching*(pattern: string, input: string, callback: proc(result: MatchResult)) =
#   var pattern = cleanup(pattern)
#   var input = cleanup(input)
#   test "Pattern Matching: \n" & pattern & "\n" & input:
#     var p = read(pattern)
#     var i = read(input)
#     var m = new_arg_matcher()
#     m.parse(p)
#     var result = m.match(i)
#     callback(result)

# test_arg_matching "a", "[1]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1

# test_arg_matching "_", "[]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 0

# test_arg_matching "a", "[]", proc(r: MatchResult) =
#   check r.kind == MatchMissingFields
#   check r.missing[0] == "a"

# test_arg_matching "a", "(_ 1)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1

# test_arg_matching "[a b]", "[1 2]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2

# test_arg_matching "[_ b]", "(_ 1 2)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "b"
#   check r.fields[0].value == 2

# test_arg_matching "[[a] b]", "[[1] 2]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2

# test_arg_matching "[[[a] [b]] c]", "[[[1] [2]] 3]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 3
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2
#   check r.fields[2].name == "c"
#   check r.fields[2].value == 3

# test_arg_matching "[a = 1]", "[]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1

# test_arg_matching "[a b = 2]", "[1]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2

# test_arg_matching "[a = 1 b]", "[2]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2

# test_arg_matching "[a b = 2 c]", "[1 3]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 3
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2
#   check r.fields[2].name == "c"
#   check r.fields[2].value == 3

# test_arg_matching "[a...]", "[1 2]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == new_gene_vec(new_gene_int(1), new_gene_int(2))

# test_arg_matching "[a b...]", "[1 2 3]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == new_gene_vec(new_gene_int(2), new_gene_int(3))

# test_arg_matching "[a... b]", "[1 2 3]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == new_gene_vec(new_gene_int(1), new_gene_int(2))
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 3

# test_arg_matching "[a b... c]", "[1 2 3 4]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 3
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == new_gene_vec(new_gene_int(2), new_gene_int(3))
#   check r.fields[2].name == "c"
#   check r.fields[2].value == 4

# test_arg_matching "[a [b... c]]", "[1 [2 3 4]]", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 3
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == new_gene_vec(new_gene_int(2), new_gene_int(3))
#   check r.fields[2].name == "c"
#   check r.fields[2].value == 4

# # test_arg_matching "[a :do b]", "[1 do 2]", proc(r: MatchResult) =
# #   check r.kind == MatchSuccess
# #   check r.fields.len == 2
# #   check r.fields[0].name == "a"
# #   check r.fields[0].value == 1
# #   check r.fields[1].name == "b"
# #   check r.fields[1].value == 2

# test_arg_matching "[^a]", "(_ ^a 1)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1

# test_arg_matching "[^a = 1]", "(_)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1

# test_arg_matching "[^a = 1 b]", "(_ 2)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 2
#   check r.fields[0].name == "a"
#   check r.fields[0].value == 1
#   check r.fields[1].name == "b"
#   check r.fields[1].value == 2

# test_arg_matching "[^a]", "()", proc(r: MatchResult) =
#   check r.kind == MatchMissingFields
#   check r.missing[0] == "a"

# test_arg_matching "[^props...]", "(_ ^a 1 ^b 2)", proc(r: MatchResult) =
#   check r.kind == MatchSuccess
#   check r.fields.len == 1
#   check r.fields[0].name == "props"
#   check r.fields[0].value.map["a"] == 1
#   check r.fields[0].value.map["b"] == 2

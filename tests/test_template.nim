import unittest, tables

import gene/types except Exception

import ./helpers

# How built-in templates work:
# Any quoted value is a template: e.g. `(%a b)
# Interpret: (%a b)
# Render: ($render `(%a b)) => (<value of a> b)

test_vm """
  (var tpl `(%f b))
  (fn f [a] (a + 1))
  (var x ($render tpl)) # => (<function f> b)
  (var b 2)
  (eval x)
""", 3

test_vm """
  (var tpl `(%f %b))
  (fn f [a] (a + 1))
  (var b 2)
  (var x ($render tpl)) # => (<function f> 2)
  (eval x)
""", 3

test_vm """
  (var tpl `(test %a 2))
  (var a 1)
  ($render tpl)
""", proc(r: Value) =
  check r.gene_type == new_gene_symbol("test")
  check r.gene_children[0] == 1
  check r.gene_children[1] == 2

test_vm """
  (var tpl `[%(f b)])
  (fn f [a] (a + 1))
  (var b 1)
  ($render tpl)
""", @[2]

test_vm """
  (var tpl `{^p %(f b)})
  (fn f [a] (a + 1))
  (var b 1)
  ($render tpl)
""", proc(r: Value) =
  check map_data(r)["p".to_key()] == 2

test_vm """
  (var i 1)
  ($render `[
    %(var i 2)
  ])
  i
""", 1

test_vm """
  ($render `[
    1
    %_(var i 2)
    2
  ])
""", @[1, 2]

# TODO: Enable when for loops with $emit in templates are implemented
# test_vm """
#   ($render :[
#     %(for i in [1 2]
#       ($emit i)
#     )
#   ])
# """, @[1, 2]

# TODO: Enable when for loops with $emit in templates are implemented
# test_vm """
#   ($render :(_
#     %(for i in [1 2]
#       ($emit i)
#     )
#   ))
# """, proc(r: Value) =
#   check r.gene_children[0] == 1
#   check r.gene_children[1] == 2

# TODO: Enable when for loops with $emit in templates are implemented
# test_vm """
#   ($render :[
#     %(for i in [1 2]
#       ($emit
#         :[a %i]
#       )
#     )
#   ])
# """, proc(r: Value) =
#   # r.vec[0] == [a %i]
#   check r.ref.arr[0].ref.arr[0] == new_gene_symbol("a")
#   check r.ref.arr[0].ref.arr[1].kind == VkUnquote
#   check r.ref.arr[0].ref.arr[1].ref.unquote == new_gene_symbol("i")

test_vm """
  (var tpl `[%a])
  (var a 1)
  ($render tpl)
  (a = 2)
  ($render tpl)
""", @[2]

test_vm """
  (var tpl `{^a %a})
  (var a 1)
  ($render tpl)
  (a = 2)
  ($render tpl)
""", proc(r: Value) =
  check map_data(r)["a".to_key()] == 2

test_vm """
  (var tpl `(_ %a))
  (var a 1)
  ($render tpl)
  (a = 2)
  ($render tpl)
""", proc(r: Value) =
  check r.gene.children[0] == 2

# # test_vm """
# #   (var a [1 2])
# #   :(test
# #     %a...
# #     3
# #   )
# # """, proc(r: Value) =
# #   check r.gene_type == new_gene_symbol("test")
# #   check r.gene_children[0] == 1
# #   check r.gene_children[1] == 2
# #   check r.gene_children[2] == 3

# # TODO: nested quote/unquote, need more thoughts before implementing
# # test_vm """
# #   (var a 1)
# #   ::(test %a 2)
# # """, proc(r: Value) =
# #   check r == read(":(test %a 2)")

# # test_vm """
# #   (var a 1)
# #   ::(test %%a 2)
# # """, proc(r: Value) =
# #   check r == read(":(test 1 2)")

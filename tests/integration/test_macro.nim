import unittest

import gene/types except Exception

import ../helpers

# Macro support
#
# * A macro will generate an AST tree and pass back to the VM to execute.
#

# Basic macro-like function that returns its argument
test_vm """
  (fn m! [a]
    a
  )
  (m! b)
""", "b".to_symbol_value()

# Test that macro-like function arguments are not evaluated
test_vm """
  (fn m! [a]
    `macro_result
  )
  (m! (this_would_fail_if_evaluated))
""", "macro_result".to_symbol_value()

test_vm """
  (fn m! [a b]
    (+ ($caller_eval a) ($caller_eval b))
  )
  (m! 1 2)
""", 3

test_vm """
  (fn m! [a = 1]
    (+ ($caller_eval a) 2)
  )
  (m!)
""", 3

# Simple test without function wrapper
test_vm """
  (var a 1)
  (fn m! []
    ($caller_eval `a)
  )
  (m!)
""", 1

test_vm """
  (fn m! []
    ($caller_eval `a)
  )
  (fn f []
    (var a 1)
    (m!)
  )
  (f)
""", 1

test_vm """
  (var a 1)
  (fn m! [b]
    ($caller_eval b)
  )
  (m! a)
""", 1

# Macro-like function: name! should leave arguments unevaluated
test_vm """
  (fn quote! [x] x)
  (quote! (throw "boom"))
""", proc(r: Value) =
  check r.kind == VkGene

# macro input shape keeps type props and children
test_vm """
  (fn inspect! [expr]
    [(expr .type) (./ (expr .props) "tag") (./ (expr .children) 0) (./ (expr .children) 1)]
  )
  (inspect! (demo ^tag "meta" a b))
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 4
  check array_data(r)[0] == "demo".to_symbol_value()
  check array_data(r)[1] == "meta".to_value()
  check array_data(r)[2] == "a".to_symbol_value()
  check array_data(r)[3] == "b".to_symbol_value()

# caller_eval evaluates retained macro child in caller scope
test_vm """
  (fn eval_child! [expr]
    ($caller_eval (./ (expr .children) 0))
  )
  (var x 40)
  (eval_child! (hold (x + 2)))
""", 42

# Macro-like constructors are rejected for classes.
test_vm_error """
  (class Regular
    (ctor []
      (/x = 1)
    )
  )
  (new! Regular)
"""

# Defining ctor! is rejected.
test_vm_error """
  (class MacroCtor
    (ctor! [x]
      (/body = x)
    )
  )
"""

# Using new! is rejected even without a constructor.
test_vm_error """
  (class Plain)
  (new! Plain)
"""
# test_core """
#   (fn m! []
#     (class A
#       (method test [] "A.test")
#     )
#     ($caller_eval
#       (:$def_ns_member "B" A)
#     )
#   )
#   (m! nil)
#   ((new B) .test)
# """, "A.test"

# test_core """
#   (fn m! [name]
#     (class A
#       (method test [] "A.test")
#     )
#     ($caller_eval
#       (:$def_ns_member name A)
#     )
#   )
#   (m! "B")
#   ((new B) .test)
# """, "A.test"

# # TODO: this should be possible with macro/caller_eval etc
# test_vm """
#   (fn with! [name value body...]
#     (var expr
#       :(do
#         (var %name %value)
#         %body...
#         %name))
#     ($caller_eval expr)
#   )
#   (var b "b")
#   (with! a "a"
#     (a = (a b))
#   )
# """, "ab"

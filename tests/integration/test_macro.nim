import unittest
import tables

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

# new! should be rejected when the class only has ctor (eager)
test_vm_error """
  (class Regular
    (ctor []
      (/x = 1)
    )
  )
  (new! Regular)
"""

# new should be rejected when the class only has ctor! (lazy)
test_vm_error """
  (class MacroCtor
    (ctor! [x]
      (/body = x)
    )
  )
  (new MacroCtor)
"""

# new! with ctor! delivers unevaluated arguments to the constructor
test_vm """
  (class MacroCtor
    (ctor! [x]
      (/body = x)
    )
  )
  (var m (new! MacroCtor (+ 1 2)))
  m/body
""", proc(r: Value) =
  check r.kind == VkGene
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

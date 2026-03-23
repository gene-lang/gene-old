import unittest

import gene/types except Exception

import ../helpers

# Support special variables to access positional arguments?
#   E.g. $0, $1, $-1(last)

test_vm """
  (block [])
""", proc(r: Value) =
  check r.ref.kind == VkBlock

test_vm """
  (block [a] a)
""", proc(r: Value) =
  check r.ref.kind == VkBlock

test_vm """
  (fn f [b]
    (b)
  )
  (f (block [] 1))
""", 1

test_vm """
  (fn f [b]
    (b 2)
  )
  (f (block [a] (a + 1)))
""", 3

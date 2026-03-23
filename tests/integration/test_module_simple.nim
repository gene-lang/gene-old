import unittest

import gene/types except Exception
import gene/vm

import ../helpers

# Simple namespace test
test_vm """
  (ns test)
  test
""", proc(r: Value) =
  check r.kind == VkNamespace
  check r.ref.ns.name == "test"

test_vm """
  (var x 42)
  x
""", 42

# First test that ns captures variables correctly
test_vm """
  (var outer 1)
  (ns test
    (var inner 2)
  )
  outer
""", 1

# Test accessing namespace member
test_vm """
  (ns test
    (var x 100)
  )
  test
""", proc(r: Value) =
  check r.kind == VkNamespace
  # TODO: Figure out why variables aren't being stored in namespace
import unittest

import gene/types except Exception

import ./helpers

test_vm """
  (do
    ($vmstmt duration_start)
    1
  )
""", 1

test_vm """
  (do
    ($vmstmt duration_start)
    ($vm duration)
  )
""", proc(r: Value) =
  check r.kind == VkFloat
  check r.float64 >= 0.0

test_vm_error "($vm duration_start)"

test_vm_error "($vm does_not_exist)"

test_vm_error "($vmstmt duration)"

test_vm_error "(println ($vmstmt duration_start))"

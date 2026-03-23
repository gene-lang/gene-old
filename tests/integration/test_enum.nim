import unittest

import gene/types except Exception

import ../helpers

# Tests for enum construct
# Most enum functionality is not yet implemented in our VM
# These tests are commented out until those features are available:

test_vm """
  (enum Color red green blue)
  Color/red
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "red"
  check r.ref.enum_member.value == 0

test_vm """
  (enum Status ^values [ok error pending])
  Status/ok
""", proc(r: Value) =
  check r.kind == VkEnumMember
  check r.ref.enum_member.name == "ok"
  check r.ref.enum_member.value == 0

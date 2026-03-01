import unittest

import gene/types except Exception

import ./helpers

# Namespace related metaprogramming:
#
# * Namespace.member_defined (called when a member is defined or re-defined)
# * Namespace.member_removed
# * Namespace.on_member_missing (invoked only if <some_ns>/something is invoked and something is not defined)
# * Namespace.has_member - it should be consistent with member_missing

# Basic namespace creation
# Covered by VM namespace tests; keep one assertion here for readability

# Namespace access
test_vm """
  (ns n)
  n
""", proc(r: Value) =
  check r.ref.ns.name == "n"

# Multiple namespaces in same scope
test_vm """
  (ns n)
  (ns m)
  m
""", proc(r: Value) =
  check r.ref.ns.name == "m"

# Variables in namespace scope
# Nested namespace creation moved to test_vm_namespace.nim; avoid duplication here

test_vm """
  (ns n)
  (var a 1)
  a
""", 1

# Nested namespaces and path access (migrated from test_vm_namespace.nim)
test_vm """
  (ns n
    (ns /m)
  )
  n
""", proc(r: Value) =
  check r.ref.ns.name == "n"
  check r.ref.ns["m".to_key()].ref.ns.name == "m"

test_vm """
  (ns n
    (ns /m)
  )
  n/m
""", proc(r: Value) =
  check r.ref.ns.name == "m"

# Nested namespace creation - needs to be fixed to handle body compilation
# test_vm """
#   (ns n
#     (ns m)
#   )
#   n/m
# """, proc(r: Value) =
#   check r.ref.ns.name == "m"

# The following tests require features not yet implemented in VM:
# - Classes
# - Complex symbol handling in var definitions (n/a)
# - Namespace path resolution (n/m)
# - The 'global' symbol
# - Member missing handlers (.on_member_missing)
# - $ns syntax
# - Proxy functionality
# - /a syntax for namespace variables

# Classes not yet implemented in VM
# test_vm """
#   (ns n
#     (class A)
#   )
#   n/A
# """, proc(r: Value) =
#   check r.class.name == "A"

# Namespace variable definition with / prefix not supported
# test_vm """
#   (ns n
#     (var /a 1)
#   )
#   n/a
# """, 1

# Classes not yet implemented in VM
# test_vm """
#   (ns n)
#   (class n/A)
#   n/A
# """, proc(r: Value) =
#   check r.class.name == "A"

# Complex symbols in var not yet supported
# test_vm """
#   (ns n)
#   (var n/test 1)
#   n/test
# """, 1

# Nested namespace creation outside body not yet supported
# test_vm """
#   (ns n)
#   (ns n/m)
#   n/m
# """, proc(r: Value) =
#   check r.ref.ns.name == "m"

# Classes not yet implemented in VM
# test_vm """
#   (ns n)
#   (ns n/m
#     (class A)
#   )
#   n/m/A
# """, proc(r: Value) =
#   check r.class.name == "A"

# Global namespace access not yet implemented
# test_vm """
#   global
# """, proc(r: Value) =
#   check r.ref.ns.name == "global"

# Classes not yet implemented in VM
# test_vm """
#   (class global/A)
#   global/A
# """, proc(r: Value) =
#   check r.class.name == "A"

# Global variable access - complex symbols not supported
# test_vm """
#   (var global/a 1)
#   a
# """, 1

# Classes not yet implemented in VM
# test_vm """
#   (class A
#     (fn f [a] a)
#   )
#   (A/f 1)
# """, 1

# Classes not yet implemented in VM
# test_vm """
#   (ns n
#     (class A)
#     (ns m
#       (class B < A)
#     )
#   )
#   n/m/B
# """, proc(r: Value) =
#   check r.class.name == "B"

test_vm """
  (ns n
    (.on_member_missing
      (fn [name]
        (if (name == "test")
          1
        )
      )
    )
  )
  n/test
""", 1

# String concatenation via ("" ...) pattern not yet implemented in VM
# test_vm """
#   (ns n
#     (.on_member_missing
#       (fn [name]
#         ("" /.name "/" name)
#       )
#     )
#   )
#   n/test
# """, "n/test"

# Classes and member missing handlers not yet implemented in VM
# test_vm """
#   (class C
#     (.on_member_missing
#       (fn [name]
#         ("" /.name "/" name)
#       )
#     )
#   )
#   C/test
# """, "C/test"

test_vm """
  (ns n
    (.on_member_missing
      (fn [name]
        (if (name == "a")
          1
        )
      )
    )
    (.on_member_missing
      (fn [name]
        (if (name == "b")
          2
        )
      )
    )
  )
  (n/a + n/b)
""", 3

# $ns syntax not yet implemented in VM
# test_vm """
#   ($ns/a = 1)
#   (a = 2)
#   $ns/a
# """, 2

# $ns syntax not yet implemented in VM
# test_vm """
#   (var a 1)
#   ($ns/a = 1)
#   (a = 2)
#   $ns/a
# """, 1

# Proxy functionality not yet implemented in VM
# test_vm """
#   (ns n)
#   (ns m
#     (var a 1)
#   )
#   (n .proxy :a m)
#   n/a
# """, 1

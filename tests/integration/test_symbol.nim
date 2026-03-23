import unittest

import gene/types except Exception

import ../helpers

# Builtins:
# global
# gene - standard library
# genex - additional or experimental standard library
# self
# $vm
# $app
# $pkg
# $module
# $ns
# $fn
# $class
# $method
# $args
# $ex

# a       # variable in current scope or namespace
# $ns/a   # member of namespace
# /prop   # property of self object
# /0      # first entry of self.gene_children, or self.vec etc
# /-1     # last entry of self.gene_children, or self.vec etc

# TODO: Unify access of properties, children and generic selector feature

# n/f     # member of namespace like objects (namespace, class, mixin)
# e/X     # member of enum
# x/prop     # prop of x (instance or gene or map)
# x/.meth     # call meth on x  (shortcut for calling method without arguments)
# self/.meth  # call meth on self

# Basic symbol tests
test_vm "`a", "a".to_symbol_value()
test_vm "`test", "test".to_symbol_value()

# Namespace tests that work with our VM
test_vm """
  (ns n)
""", proc(r: Value) =
  check r.ref.ns.name == "n"

test_vm """
  (ns n
    (ns /m)
  )
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

# Gene property access tests
test_vm """
  (var x {^a 1})
  x/a
""", 1

test_vm """
  (var x (_ ^a 1))
  x/a
""", 1

# Array access tests
test_vm """
  (var x [1 2])
  x/0
""", 1

test_vm """
  (var x (_ 1 2))
  x/0
""", 1

# Nested access tests
test_vm """
  (var x {^a [1 2]})
  x/a/1
""", 2

# Complex symbol tests - not yet implemented in VM
# test_vm "a/b", to_complex_symbol(@["a", "b"])
# test_vm "a/b/c", to_complex_symbol(@["a", "b", "c"])

# More advanced symbol resolution features are not yet implemented in our VM
# These tests are commented out until those features are available:

# test_vm """
#   $app
# """, proc(r: Value) =
#   check r.app.ns.name == "global"

# test_vm """
#   $ns
# """, proc(r: Value) =
#   check r.ns.name == "<root>"

# test_vm """
#   (ns n
#     (ns m
#       (class C)
#     )
#   )
#   n/m/C
# """, proc(r: Value) =
#   check r.class.name == "C"

# test_vm """
#   (class C
#     (mixin M
#       (fn f [] 1)
#     )
#   )
#   (C/M/f)
# """, 1

# test_vm """
#   (enum A first second)
#   A/second
# """, proc(r: Value) =
#   var m = r.enum_member
#   check m.parent.enum.name == "A"
#   check m.name == "second"
#   check m.value == 1

# test_vm """
#   (class C
#     (ctor _
#       (/prop = 1)
#     )
#   )
#   (var c (new C))
#   c/prop
# """, 1

# test_vm """
#   (class C
#     (ctor _
#       (/prop = 1)
#     )
#   )
#   (var c (new C))
#   ($with c /prop)
# """, 1

# test_vm """
#   (class C
#     (method test _
#       1
#     )
#   )
#   (var c (new C))
#   c/.test
# """, 1

# test_vm """
#   (class C
#     (method test _
#       1
#     )
#   )
#   (var c (new C))
#   ($with c /.test)
# """, 1

# test_vm """
#   (class C
#     (method test _
#       (/p = 1)
#     )
#   )
#   ((new C).test)
# """, 1

# test_vm """
#   (fn f []
#     1
#   )
#   f/.call
# """, 1

# test_vm """
#   (fn f []
#     [1 2]
#   )
#   f/.call/0
# """, 1

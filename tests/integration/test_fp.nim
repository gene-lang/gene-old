import unittest

import gene/types except Exception

import ../helpers

# Functional programming:
#
# * Define function
# * Call function
# * Return function as result
# * Pass function around
# * Closure
# * Bounded function
# * Iterators
# * Pure function (mark function as pure, all standard lib should be marked pure if true)
# * Continuation - is it possible?
#
# * Native function
#   proc(props: Table[string, Value], children: openarray[Value]): Value
# * Native method
#   Simple: proc(
#     self: Value,
#     props: Table[string, Value],
#     children: openarray[Value],
#   ): Value
#   Complex: proc(
#     caller: Frame,
#     options: Table[FnOption, Value],
#     self: Value,
#     props: Table[string, Value],
#     children: openarray[Value],
#   ): Value
#
# How do we support "self" inside function?
# self = true to allow self to be used inside function
# inherit_self = true to automatically inherit self in the caller's context
# (fn ^^self f [^a b]
#   (.size)
# )
# (call f ^self "" (_ ^a 2 3))
# ("" . f ^a 1 2)    # A shortcut to call f with self, (call ...) is the generic form
# ("" >> f ^a 1 2)   # A shortcut to call f with self, (call ...) is the generic form
# (. f ^a 1 2)       # A shortcut to call f with self from current scope
# (>> f ^a 1 2)      # A shortcut to call f with self from current scope

test_vm "(fn f [a] a)", proc(r: Value) =
  check r.ref.fn.name == "f"

test_vm "(fn \"f\" [a] a)", proc(r: Value) =
  check r.ref.fn.name == "f"

test_vm "(fn f [])", proc(r: Value) =
  check r.ref.fn.matcher.children.len == 0

test_vm_error "(fnx [x] x)"
test_vm_error "(fn add x (x + 1))"

test_vm """
  (fn f [] 1)
  (f)
""", 1

test_vm """
  (ns /n
    (ns /m)
  )
  (fn n/m/f [] 1)
  (n/m/f)
""", 1

# TODO: Implement ^!return syntax
# test_vm """
#   (fn f []
#     # ^^return_nothing vs ^^return_nil vs ^return nil vs ^!return
#     ^!return
#     1
#   )
#   (f)
# """, Value(nil)

test_vm """
  (fn f [a] (a + 1))
  (f 1)
""", 2

# test_vm """
#   (fn f [a b]
#     (a + b)
#   )
#   (var c [1 2])
#   (f c...)
# """, 3

# test_vm """
#   (fn f [a b]
#     (a + b)
#   )
#   (f (... [1 2]))
# """, 3

# test_vm """
#   # How do we tell interpreter to pass arguments as $args?
#   # TODO: Define syntax for raw $args in functions.
#   (fn f []
#     $args
#   )
#   (f ^a "a" 1 2)
# """, proc(r: Value) =
#   check r.gene_props["a"] == "a"
#   check r.gene_children[0] == 1
#   check r.gene_children[1] == 2

# TODO: Implement (1 . f) method call syntax
# test_vm """
#   (fn f [self] self)
#   (1 . f)
# """, 1

test_vm """
  (fn f [a = 1] a)
  (f)
""", 1

# TODO: Implement _ as placeholder to trigger default arguments
# test_vm """
#   (fn f [a = 1] a)
#   (f _)
# """, 1

test_vm """
  (fn f [a = 1] a)
  (f 2)
""", 2

# test_vm """
#   (fn f [a b = a] b)
#   (f 1)
# """, 1

# test_vm """
#   (fn f [a b = a] b)
#   (f 1 2)
# """, 2

# test_vm """
#   (fn f [a b = (a + 1)] b)
#   (f 1)
# """, 2

# test_vm """
#   (fn f []
#     (result = 1) # result: no need to define
#     2
#   )
#   (f)
# """, 1



test_vm """
  (fn fib [n]
    (if (n < 2)
      n
    else
      ((fib (n - 1)) + (fib (n - 2)))
    )
  )
  (fib 6)
""", 8

test_vm """
  (fn f []
    (fn g [a] a)
  )
  ((f) 1)
""", 1

test_vm """
  (fn f [a]
    (fn g [] a)
  )
  ((f 1))
""", 1

# test_vm """
#   (fn f []
#     (var r $return)
#     (r 1)
#     2
#   )
#   (f)
# """, 1

# # return can be assigned and will remember which function
# # to return from
# # Caution: "r" should only be used in nested functions/blocks inside "f"
# test_vm """
#   (fn g [ret]
#     (ret 1)
#   )
#   (fn f []
#     (var r $return)
#     (loop
#       (g r)
#     )
#   )
#   (f)
# """, 1

# # return can be assigned and will remember which function
# # to return from
# test_vm """
#   (fn f []
#     (var r $return)
#     (fn g []
#       (r 1)
#     )
#     (loop
#       (g)
#     )
#   )
#   (f)
# """, 1

# test_vm """
#   (fn f [] $args)
#   (f 1)
# """, proc(r: Value) =
#   check r.gene_children[0] == 1

# test_vm """
#   (fn f [a b] (a + b))
#   (fn g []
#     (f $args...)
#   )
#   (g 1 2)
# """, 3

test_vm """
  (var f
    (fn [a] a)
  )
  (f 1)
""", 1

test_vm """
  (var f
    (fn [] 1)
  )
  (f)
""", 1

test_vm """
  (fn /f [] 1)    # first f in namespace
  (var f        # second f in scope
    (fn []
      (($ns/f) + 1) # reference to namespace f
    )
  )
  (f)           # second f
""", 2

# TODO: Implement named argument support
# test_vm """
#   (fn f [^a] a)
#   (f ^a 1)
# """, 1

# Should throw MissingArgumentError
# try:
#   test_vm """
#     (fn f [^a] a)
#     (f)
#   """, Nil
#   fail()
# except types.Exception:
#   discard

# test_vm """
#   (fn f [^?a] a) # ^?a, optional named argument, default to Nil
#   (f)
# """, Nil

# TODO: Implement named argument support
# test_vm """
#   (fn f [^a = 1] a)
#   (f)
# """, 1

# test_vm """
#   (fn f [^a = 1] a)
#   (f ^a 2)
# """, 2

# test_vm """
#   (fn f [^a = 1 b] b)
#   (f 2)
# """, 2

# test_vm """
#   (fn f [^a ^rest...] a)
#   (f ^a 1 ^b 2 ^c 3)
# """, 1

# test_vm """
#   (fn f [^a ^rest...] rest)
#   (f ^a 1 ^b 2 ^c 3)
# """, proc(r: Value) =
#   check r.ref.map.len == 2
#   check r.ref.map["b".to_key()] == 2
#   check r.ref.map["c".to_key()] == 3

# test_vm """
#   (fn f [] 1)
#   (call f)
# """, 1

# test_vm """
#   (fn f [a b] (a + b))
#   (call f [1 2])
# """, 3

# # # Should throw error because we expect call takes a single argument
# # # which must be an array, a map or a gene that will be exploded
# # test_vm """
# #   (fn f [a b] (a + b))
# #   (call f 1 2)
# # """, 1

# test_vm """
#   (fn f [^a b] (a + b))
#   (call f (_ ^a 1 2))
# """, 3

# # test_vm """
# #   (fn f [^a b] (self + a + b))
# #   (call f ^self 1 (_ ^a 2 3))
# # """, 6

# # test_vm """
# #   (fn f [a]
# #     (self + a)
# #   )
# #   (1 >> f 2)
# # """, 3

# # $bind work like Function.bind in JavaScript.
# test_vm """
#   (fn f [a b]
#     (self + a + b)
#   )
#   (var g
#     ($bind f 1 2)
#   )
#   (g 3)
# """, 6

# TODO: Implement $bind
# test_vm """
#   (fn f [self] self)
#   (var f1
#     ($bind f 1) # self = 1
#   )
#   (f1)
# """, 1

# test_vm """
#   (fn f [a b]
#     [self + a + b]
#   )
#   (var f1
#     ($bind f 1 2) # self = 1, a = 2
#   )
#   (f1 3) # b = 3
# """, 6

# test_vm """
#   (fn f [a b]
#     (a + b)
#   )
#   (var f1
#     ($bind_args f 1) # a = 1
#   )
#   (f1 2)
# """, 3


# ---- Migrated unique tests from test_vm_fp.nim ----




test_vm """
  (fn f [a]
    (a + 2)
  )
  (f 1)
""", 3


# Keep one explicit return test to validate return semantics
# (no-arg function returning 1 explicitly)
test_vm """
  (fn f []
    (return 1)
    2
  )
  (f)
""", 1

# And one test for return without value (should return nil)
test_vm """
  (fn f []
    (return)
    2
  )
  (f)
""", Value(nil)



# Note: Duplicate function primitive tests removed (covered earlier):
# - empty body fn name extraction
# - simple fn that returns 1
# - fn returns an array and we inspect element
# - positional param forms (parameter list vs. unbracketed)
# - binary add with two params
# - explicit return vs implicit result
# - fn anonymous function trivial returns
# - default arg + computation returning 3


test_vm """
  (fn f []
    (g)
  )
  (fn g []
    1
  )
  (f)
""", 1

test_vm """
  (var a 1)
  (fn f [b]
    (a + b)
  )
  (f 2)
""", 3

test_vm """
  (var a 1)
  (fn f [b]
    (a = 2)
    (a + b)
  )
  (f 2)
""", 4

test_vm """
  (var a 1)
  (fn f []
    (var b 2)
    (fn g []
      (a + b)
    )
  )
  ((f))
""", 3

import unittest

import gene/types except Exception

import ./helpers

# Super call to parent eager method

test_vm """
  (class Base
    (ctor [x] (/x = x))
    (method add [y]
      (+ /x y)
    )
  )
  (class Child < Base
    (ctor [x]
      (super .ctor x)
    )
    (method add [y]
      (super .add y)
    )
  )
  (var c (new Child 2))
  (c .add 3)
""", 5.to_value()

# Super call to parent eager method should forward keyword args

test_vm """
  (class Base
    (method m [^x]
      x
    )
  )
  (class Child < Base
    (method m [^x]
      (super .m ^x x)
    )
  )
  ((new Child) .m ^x 42)
""", 42.to_value()

# Super call to parent constructor should forward keyword args

test_vm """
  (class Base
    (ctor [^x ^y]
      (/sum = (+ x y))
    )
  )
  (class Child < Base
    (ctor [^x ^y]
      (super .ctor ^x x ^y y)
    )
  )
  (var c (new Child ^x 3 ^y 4))
  c/sum
""", 7.to_value()

# Super call to parent macro method should preserve unevaluated args

test_vm """
  (class Base
    (method m! [x] x)
  )
  (class Child < Base
    (method m! [x]
      (super .m! (+ 1 2))
    )
  )
  ((new Child) .m! 0)
""", proc(v: Value) =
  check v.kind == VkGene

# Super call to parent macro constructor

test_vm """
  (class Base
    (ctor! [expr]
      (/body = expr)
    )
  )
  (class Child < Base
    (ctor! [expr]
      (super .ctor! expr)
    )
  )
  (var c (new! Child (+ 1 2)))
  c/body
""", proc(v: Value) =
  check v.kind == VkGene

# Bare super proxies are not supported; use (super .member ...).

test_vm_error """
  (class Base
    (method m [] 1)
  )
  (class Child < Base
    (method m []
      super
    )
  )
  ((new Child) .m)
"""

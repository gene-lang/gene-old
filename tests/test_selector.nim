import unittest
import tables

import gene/types except Exception

import ./helpers

# Selector
# * Borrow ideas from XPath/XSLT/CSS
#   * XPath: locate any node or group of nodes in a xml document
#   * XSLT: transform a xml document to another
#   * CSS: apply styles on any element or group of elements in a html document
#   * CSS Selectors: similar to XPath
# * Mode:
#   * Match first
#   * Match all
# * Flags:
#   * error_on_no_match: Throw error if none is matched
# * Types
#   * Index: 0,1,..-2,-1
#   * Index list
#   * Index range: 0..2
#   * Property name
#   * Property name list
#   * Property name pattern: /^test/
#   * Gene type: :$type
#   * Gene properties: :$props
#   * Gene property names: :$keys
#   * Gene property values: :$values
#   * Gene children: :$children
#   * Descendants: :$descendants - how does match work for this? self.gene.children and their descendants?
#   * Self and descendants: _
#   * Predicate (fn [it] ...)
#   * Composite: [0 1 (range 3 5)]
#
# SelectorResult
# * Single value
# * Array or map or gene
#
# Define styles for gene value matched by a selector (like CSS).
# This should live outside the gene value.
# Inline styles can be defined for a gene. However it is not related to selectors.
# Shortcuts like those in css selectors
#   * id: &x matches (_ ^id "x")
#   * type: :y matches (y)
#   * tag (like css classes): ?t1?t2 matches (_ ^tags ["t1" "t2"])
#
# Transform a gene value based on selectors and actions (like XSLT)
# Should support non-gene output, e.g. raw strings.
# Actions:
#   * Copy value matched by selector to output
#   * Call callback with value, add result to output
#
# Distinguish predicates, transformers and callbacks etc:
# * Predicates return special list of path=value or value
# * Callbacks' does not return special list, thus discarded

# @p        <=> (@ "p")
# (@p)      <=> ((@ "p"))       <=> /p        <=> (self ./p)
# (@p)      <=> ((@ "p") self)
# (/p = 1)  <=> ((@ "p") = 1)   <=> (self ./p = 1)
# (/p += 1) <=> (/p = (/p + 1)) <=> ((@ "p") = ((@ "p") + 1))

# (./p)     <=> (self ./p)      <=> (self ./ "p")
# (/p = 1)  <=> ($set self @p 1)

# (@ "test")             # target["test"]
# @test                  # target["test"]
# (@ 0 "test")           # target[0]["test"]
# @0/test                # target[0]["test"]
# (@ (@ 0) "test")       # target[0]["test"]
# (@ [0 1] "test")       # target[0, 1]["test"]
# (@ (range 0 3) :type)  # target[0..3].type
# (@* [0 "test"] [1 "another"])  # target[0]["test"] + target[1]["another"]
#
# /0/test                   # ((@ 0 "test") self)
# (./ 0 "test")             # ((@ 0 "test") self)
# (./0/test)                # ((@ 0 "test") self)
# (./ :type)                # ((@ :type) self)
# (obj ./ 0 "test")         # ((@ 0 "test") obj)
# ((@* 0 1) self)
# (./ 0 "test" = "value")   # (assign self (@ 0 "test") "value")
# (./test)                  # ((@ "test") self)
# (./first/second)          # ((@ "first" "second") self)
#
# * Search
# * Update
# * Remove

test_vm """
  (var x {^a 1})
  x/a
""", 1

test_vm """
  (var x [1 2 3])
  x/0
""", 1

test_vm """
  (var x [1 2 3])
  x/2
""", 3

# Testing the ./ selector operator:

test_vm """
  (./ {^a "A"} "a")
""", "A"

test_vm """
  (./ {} "a")
""", VOID

test_vm """
  (./ {} "a" 1)
""", 1

test_vm """
  (var x {})
  x/a
""", VOID

test_vm """
  (var key "name")
  (var data {^name "Ada"})
  data/<key>
""", "Ada"

test_vm """
  (var state {^selected "name"})
  (var data {^user {^name "Ada"}})
  data/user/<state/selected>
""", "Ada"

test_vm """
  (var idx 1)
  (var data {^users [{^name "Ada"} {^name "Bob"}]})
  data/users/<idx>/name
""", "Bob"

test_vm_error """
  (var key nil)
  (var data {^name "Ada"})
  data/<key>
"""

test_vm_error """
  (var x {})
  x/a/!
"""

test_vm_error """
  (var x {})
  x/a/!/b
"""

test_vm """
  (var x {^a {}})
  x/a/!/b
""", VOID

test_vm_error """
  (var x {^a {}})
  x/a/b/!
"""

test_vm """
  (var x nil)
  x/a
""", proc(r: Value) =
  check r == NIL

test_vm """
  (var x nil)
  (x/a is Nil)
""", TRUE

test_vm_error """
  (var x nil)
  x/!/a
"""

test_vm """
  ({^a "A"} ./a)
""", "A"

# This test uses _ to create a gene expression, which requires different syntax
# test_vm """
#   ((_ ^a "A") ./ "a")
# """, "A"

test_vm """
  ([1 2] ./ 0)
""", proc(r: Value) =
  check r == 1.to_value()

test_vm """
  ([1 2] ./0)
""", 1

# test_vm """
#   ([0 1 2 -2 -1] ./ (0 .. 1))
# """, @[0, 1]

# test_vm """
#   ([0 1 2 -2 -1] ./ (0 .. -2))
# """, @[0, 1, 2, -2]

# test_vm """
#   ([0 1 2 -2 -1] ./ (-2 .. -1))
# """, @[-2, -1]

# test_vm """
#   ([0 1 2 -2 -1] ./ (-1 .. -1))
# """, @[-1]

# test_vm """
#   ([0 1 2 -2 -1] ./ (6 .. -1))
# """, @[]

# test_vm """
#   ([] ./ (0 .. 1))
# """, @[]

# test_vm """
#   ([] ./ (-2 .. -1))
# """, @[]

# test_vm """
#   ([1] ./ (-2 .. -1))
# """, @[1]

# test_vm """
#   ((_ 0 1 2 -2 -1) ./ (0 .. -2))
# """, @[0, 1, 2, -2]

# test_vm """
#   ((_) ./ (-2 .. -1))
# """, @[]

# test_vm """
#   ((_) ./ (0 .. -2))
# """, @[]

# test_vm """
#   ((_ 1) ./ (-2 .. -1))
# """, @[1]

test_vm """
  ((@ "test") {^test 1})
""", 1

test_vm """
  (var data {^a {^b 42}})
  ((@ "a" "b") data)
""", 42

test_vm """
  (var data {^a {^b 99}})
  (@a/b data)
""", 99

test_vm """
  (var data {})
  (@a/b data 123)
""", 123

test_vm """
  (var arr [{^name "n"}])
  (@0/name arr)
""", "n"

test_vm """
  (var data {^users [{^name "Alice"} {^name "Bob"}]})
  (@users/*/name data)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == "Alice".to_value()
  check array_data(r)[1] == "Bob".to_value()

test_vm """
  (var data {^users [{^name "Alice"} {^name "Bob"}]})
  (data .@users/0/name)
""", "Alice"

test_vm """
  (var data {^users [{^name "Alice"} {^name "Bob"}]})
  (data .@ "users" 1 "name")
""", "Bob"

test_vm """
  (var method_name "size")
  (var xs [1 2 3])
  xs/.<method_name>
""", 3

test_vm """
  (class Greeter
    (method speak _ "hi"))
  (var g (new Greeter))
  (var method_name "speak")
  g/.<method_name>
""", "hi"

test_vm """
  (class Multiplier
    (method scale [n factor]
      (n * factor)))
  (var m (new Multiplier))
  (var method_name "scale")
  (m . method_name 6 7)
""", 42

test_vm """
  (var data [[10 11] [20 21]])
  ((@ * 1) data)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == 11.to_value()
  check array_data(r)[1] == 21.to_value()

test_vm """
  (var xs [1 2 3])
  ((@ * (fn [x] (x + 1))) xs)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 3
  check array_data(r)[0] == 2.to_value()
  check array_data(r)[1] == 3.to_value()
  check array_data(r)[2] == 4.to_value()

test_vm """
  (var data [{^name "a"} {^name "b"}])
  ((@ * name) data)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == "a".to_value()
  check array_data(r)[1] == "b".to_value()

test_vm """
  (fn users* []
    (yield {^name "a"})
    (yield {^name "b"}))

  ((@ * name) (users*))
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == "a".to_value()
  check array_data(r)[1] == "b".to_value()

test_vm """
  (var data {^a 1})
  ((@ * a) data)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 0

test_vm """
  (var data [[1] (./ {} "a")])
  ((@ * 0) data)
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 1
  check array_data(r)[0] == 1.to_value()

test_vm_error """
  (var data [[10] [20]])
  ((@ * 1 !) data)
"""

test_vm """
  (var m {^a 1 ^b 2})
  ((@ ** (fn [k v] [k (v + 10)]) @@) m)
""", proc(r: Value) =
  check r.kind == VkMap
  check map_data(r)["a".to_key()] == 11.to_value()
  check map_data(r)["b".to_key()] == 12.to_value()

test_vm """
  (fn entries* []
    (yield ["a" 1])
    (yield ["b" 2]))

  ((@ ** (fn [k v] [k (v + 10)]) @@) (entries*))
""", proc(r: Value) =
  check r.kind == VkMap
  check map_data(r)["a".to_key()] == 11.to_value()
  check map_data(r)["b".to_key()] == 12.to_value()

test_vm """
  (var m {^a 1 ^b (./ {} "x")})
  ((@ ** @@) m)
""", proc(r: Value) =
  check r.kind == VkMap
  check map_data(r).len == 1
  check map_data(r)["a".to_key()] == 1.to_value()

test_vm """
  (class C
    (ctor [x]
      (/x = x)
    )
  )
  (var c (new C 1))
  ((@ ** @@) c)
""", proc(r: Value) =
  check r.kind == VkMap
  check map_data(r)["x".to_key()] == 1.to_value()

test_vm """
  (var data {^a 1})
  (var r ((@ a (fn [item] (item + 1))) data))
  [r data/a]
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == 2.to_value()
  check array_data(r)[1] == 1.to_value()

test_vm """
  (var data {^a [1 2]})
  ((@ a (fn [item] (item .append 3) item)) data)
  data/a/2
""", 3

test_vm """
  (var data {^a {^b 1}})
  (var r ((@ a (fn [item] {^b 2}) b) data))
  [r data/a/b]
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 2
  check array_data(r)[0] == 2.to_value()
  check array_data(r)[1] == 1.to_value()

test_vm """
  (var data {})
  ((@ a (fn [item] 1)) data)
  data/a
""", VOID

# This test uses @test shorthand which requires special parsing
# For now, @test creates a selector that needs to be applied differently
# test_vm """
#   (@test {^test 1})
# """, 1

# test_vm """
#   ((@ "test" 0) {^test [1]})
# """, 1

# test_vm """
#   (@test/0 {^test [1]})
# """, 1

# test_vm """
#   (@0/test [{^test 1}])
# """, 1

# test_vm """
#   ([{^test 1}] ./ 0 "test")
# """, 1

# test_vm """
#   ([{^test 1}] ./0/test)
# """, 1

# test_vm """
#   ($with [{^test 1}]
#     (./ 0 "test")
#   )
# """, 1

# test_vm """
#   (var a [0])
#   (a/0 = 1)
#   a/0
# """, 1

# test_vm """
#   (var a [0])
#   a/-1
# """, 0

# test_vm """
#   ($with [{^test 1}]
#     (./0/test)
#   )
# """, 1

test_vm """
  (var a {})
  ($set a (@ "test") 1)
  ((@ "test") a)
""", 1

test_vm """
  (var a [0])
  ($set a @0 1)
  a
""", proc(r: Value) =
  check r.kind == VkArray
  check array_data(r).len == 1
  check array_data(r)[0] == 1.to_value()

# test_vm """
#   (class A)
#   (var a (new A))
#   ($set a @test 1)
#   (@test a)
# """, 1

# test_vm """
#   (class A
#     (method test x
#       ($set @x x)
#     )
#   )
#   (var a (new A))
#   (a .test 1)
#   a/x
# """, 1

# test_vm """
#   (class A
#     (ctor []
#       (/description = "Class A")
#     )
#   )
#   (new A)
# """, proc(r: Value) =
#   check r.instance_props["description"] == "Class A"

# test_vm """
#   ((@ 0) [1 2])
# """, 1

# test_vm """
#   ((@ 0 "test") [{^test 1}])
# """, 1

# test_vm """
#   ((@ (@ 0)) [1 2])
# """, 1

# test_vm """
#   ((@ [0 1]) [1 2])
# """, @[1, 2]

# test_vm """
#   ((@ ["a" "b"]) {^a 1 ^b 2 ^c 3})
# """, @[1, 2]

# test_vm """
#   ((@* 0 1) [1 2])
# """, @[1, 2]

# test_vm """
#   (class A
#     (method test _
#       1
#     )
#   )
#   ((@. "test") (new A))
# """, 1

# test_vm """
#   (class A
#     (method test _
#       1
#     )
#   )
#   (@.test (new A))
# """, 1

# test_vm """
#   (class A
#     (method test _
#       1
#     )
#   )
#   (@0/.test [(new A)])
# """, 1

# test_vm """
#   ((@ :TEST 0)
#     (_ (:TEST 1))
#   )
# """, @[1]

# test_core """
#   (((@ _)
#     (_ (:TEST 1))
#     # Matches
#     # self: (_ (:TEST 1))
#     # descendants: (:TEST 1), 1
#   ).size)
# """, 3

# test_vm """
#   (var a)
#   (fn f [v]
#     (a = v)
#     (:void)
#   )
#   ((@ 0 f) [123])
#   a
# """, 123

# test_core """
#   ((@ 0 gene/inc) [1])
# """, @[2]

# test_vm """
#   ([] ./ 0 ^default 123)
# """, 123

# test_vm """
#   ([] ./0 ^default 123)
# """, 123

# test_vm """
#   (@0 [] ^default 123)
# """, 123

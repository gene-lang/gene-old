import gene/types except Exception

import ../helpers

# map missing key returns VOID
test_vm """
  (var m {^present nil})
  m/missing
""", VOID

test_vm """
  (var m {^present nil})
  m/present
""", NIL

# array out-of-range returns VOID
test_vm """
  (var xs [nil])
  xs/4
""", VOID

test_vm """
  (var xs [nil])
  xs/0
""", NIL

# Gene missing property returns VOID
test_vm """
  (var g `(item ^present nil nil))
  g/missing
""", VOID

test_vm """
  (var g `(item ^present nil nil))
  g/present
""", NIL

test_vm """
  (var g `(item ^present nil nil))
  g/4
""", VOID

test_vm """
  (var g `(item ^present nil nil))
  g/0
""", NIL

# instance missing property returns VOID
test_vm """
  (class Box
    (ctor []
      (/present = nil)
    )
  )
  (var box (new Box))
  box/missing
""", VOID

test_vm """
  (class Box
    (ctor []
      (/present = nil)
    )
  )
  (var box (new Box))
  box/present
""", NIL

# case without matching branch returns NIL
test_vm """
  (case 5 when 1 "one" when 2 "two")
""", NIL

# function returning explicit nil returns NIL
test_vm """
  (fn maybe_value []
    nil
  )
  (maybe_value)
""", NIL

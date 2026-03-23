import gene/types except Exception

import ../helpers

# Tests for for loop construct

test_vm """
  (var sum 0)
  (for i in [1 2 3]
    (sum += i)
  )
  sum
""", 6

test_vm """
  (var sum 0)
  (for i in (0 .. 2)
    (sum += i)
  )
  sum
""", 3

test_vm """
  (var sum 0)
  (for [i [a b]] in [[1 2] [3 4]]
    (sum += i)
    (sum += a)
    (sum += b)
  )
  sum
""", 11

test_vm """
  (var sum 0)
  (for {^x x ^y y} in [{^x 1 ^y 2} {^x 3 ^y 4}]
    (sum += x)
    (sum += y)
  )
  sum
""", 10

test_vm """
  (fn counter* [n]
    (var i 0)
    (while (i < n)
      (yield i)
      (i += 1)))

  (var sum 0)
  (for i in (counter* 4)
    (sum += i)
  )
  sum
""", 6

test_vm """
  (fn pairs* []
    (yield [0 2])
    (yield [1 3]))

  (var sum 0)
  (for [k v] in (pairs*)
    (sum += k)
    (sum += v)
  )
  sum
""", 6

test_vm """
  (var sum 0)
  (for [_ v] in {^a 1 ^b 2}
    (sum += v)
  )
  sum
""", 3

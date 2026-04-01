import gene/types except Exception

import ../helpers

# Tests for for loop construct

# Simple value iteration
test_vm """
  (var sum 0)
  (for i in [1 2 3]
    (sum += i)
  )
  sum
""", 6

# Range iteration
test_vm """
  (var sum 0)
  (for i in (0 .. 2)
    (sum += i)
  )
  sum
""", 3

# Index + destructured value: (for i [a b] in ...)
test_vm """
  (var sum 0)
  (for i [a b] in [[1 2] [3 4]]
    (sum += i)
    (sum += a)
    (sum += b)
  )
  sum
""", 11

# Map destructuring of each element
test_vm """
  (var sum 0)
  (for {^x x ^y y} in [{^x 1 ^y 2} {^x 3 ^y 4}]
    (sum += x)
    (sum += y)
  )
  sum
""", 10

# Generator iteration
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

# Generator yielding pairs with key + value syntax
test_vm """
  (fn pairs* []
    (yield [0 2])
    (yield [1 3]))

  (var sum 0)
  (for k v in (pairs*)
    (sum += k)
    (sum += v)
  )
  sum
""", 6

# Map iteration with key + value: (for k v in map ...)
test_vm """
  (var sum 0)
  (for _ v in {^a 1 ^b 2}
    (sum += v)
  )
  sum
""", 3

# Array iteration with index + value: (for i x in arr ...)
test_vm """
  (var result 0)
  (for i x in [10 20 30]
    (result += (i + x))
  )
  result
""", 63  # (0+10) + (1+20) + (2+30) = 63

# Map iteration with key + destructured value: (for k [a b] in map ...)
test_vm """
  (var sum 0)
  (for k [a b] in {^x [1 2] ^y [3 4]}
    (sum += a)
    (sum += b)
  )
  sum
""", 10

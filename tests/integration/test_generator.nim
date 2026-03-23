import ../helpers

test_vm """
  (fn counter* [n]
    (var i 0)
    (while (i < n)
      (yield i)
      (i += 1)))

  (var gen (counter* 3))
  (assert ((gen .next) == 0))
  (assert ((gen .next) == 1))
  (assert ((gen .next) == 2))
  (assert ((gen .next) == not_found))
"""

test_vm """
  (fn fibonacci* [n]
    (var a 0)
    (var b 1)
    (var count 0)
    (while (count < n)
      (yield a)
      (var temp (a + b))
      (a = b)
      (b = temp)
      (count += 1)))

  (var fib (fibonacci* 5))
  (assert ((fib .next) == 0))
  (assert ((fib .next) == 1))
  (assert ((fib .next) == 1))
  (assert ((fib .next) == 2))
  (assert ((fib .next) == 3))
  (assert ((fib .next) == not_found))
"""

test_vm """
  (var make-squares (fn ^^generator [max]
    (var i 0)
    (while (i < max)
      (yield (i * i))
      (i += 1))))

  (var squares (make-squares 4))
  (assert ((squares .next) == 0))
  (assert ((squares .next) == 1))
  (assert ((squares .next) == 4))
  (assert ((squares .next) == 9))
  (assert ((squares .next) == not_found))
"""

test_vm """
  (fn counter* [start]
    (var i start)
    (while (i < (start + 3))
      (yield i)
      (i += 1)))

  (var gen1 (counter* 0))
  (var gen2 (counter* 10))

  (assert ((gen1 .next) == 0))
  (assert ((gen2 .next) == 10))
  (assert ((gen1 .next) == 1))
  (assert ((gen2 .next) == 11))
  (assert ((gen1 .next) == 2))
  (assert ((gen2 .next) == 12))
  (assert ((gen1 .next) == not_found))
  (assert ((gen2 .next) == not_found))
"""

test_vm """
  (fn empty* []
    nil)

  (var gen (empty*))
  (assert ((gen .next) == not_found))
  (assert ((gen .next) == not_found))
"""

test_vm """
  (fn nil-gen* []
    (yield 1)
    (yield nil)
    (yield 3))

  (var gen (nil-gen*))
  (assert ((gen .next) == 1))
  (assert ((gen .next) == nil))
  (assert ((gen .next) == 3))
  (assert ((gen .next) == not_found))
"""

test_vm """
  (fn counter* []
    (yield 1)
    (yield 2))

  (var gen (counter*))
  (assert (gen .has_next))
  (assert (gen .has_next))
  (assert ((gen .next) == 1))
  (assert (gen .has_next))
  (assert ((gen .next) == 2))
  (assert (not (gen .has_next)))
  (assert ((gen .next) == not_found))
"""

test_vm """
  (fn make-counter [start]
    (fn counter* []
      (var i start)
      (while true
        (yield i)
        (i += 1)))
    counter*)

  (var counter-fn (make-counter 5))
  (var gen (counter-fn))
  (assert ((gen .next) == 5))
  (assert ((gen .next) == 6))
  (assert ((gen .next) == 7))
"""

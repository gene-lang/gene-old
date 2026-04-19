import std/unittest
import ../helpers

suite "Phase 1.5 actor-ready closures":
  test_vm """
    (fn make_reader []
      (do
        (var payload [5 6 7])
        (var bonus {^extra 9})
        (var packet `(Widget ^meta {^weight 4} [100 200]))
        (freeze
          (fn []
            (+ (+ (./ payload 2) bonus/extra)
               (+ packet/meta/weight packet/0/0))))))
    (var reader (make_reader))
    (reader)
  """, 120

  test_vm """
    (fn make_adder [n]
      (do
        (var captured [n])
        (freeze
          (fn [x]
            (x + captured/0)))))
    (var add5 (make_adder 5))
    (add5 10)
  """, 15

  test_vm """
    (fn make_nested []
      (var outer {^base 40})
      (do
        (var delta [2])
        (freeze
          (fn []
            (+ outer/base delta/0)))))
    (var f (make_nested))
    (f)
  """, 42

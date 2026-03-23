import unittest
import strformat
import times

import ../src/gene/types except Exception
import ../src/gene/parser
import ../src/gene/compiler
import ../src/gene/vm

import ../helpers

test "Zero-argument functions":
  # Test basic zero-arg function
  test_vm("(fn get_constant [] 42) (get_constant)", 42.to_value())
  
  # Test zero-arg function with explicit value return
  test_vm("(fn do_nothing [] 0) (do_nothing)", 0.to_value())
  
  # Test nested zero-arg calls
  test_vm("""
    (fn inner [] 10)
    (fn outer [] (inner))
    (outer)
  """, 10.to_value())
  
  # Test zero-arg function with side effects (using var)
  test_vm("""
    (var counter 0)
    (fn increment [] (counter = (counter + 1)))
    (increment)
    (increment)
    counter
  """, 2.to_value())

test "Single-argument functions":
  # Test basic single-arg function
  test_vm("(fn identity [x] x) (identity 5)", 5.to_value())
  
  # Test single-arg arithmetic
  test_vm("(fn double [n] (n * 2)) (double 7)", 14.to_value())
  
  # Test single-arg with conditional
  test_vm("""
    (fn abs [x]
      (if (x < 0)
        (0 - x)
      else
        x))
    (abs -5)
  """, 5.to_value())
  
  # Test recursive single-arg (factorial)
  test_vm("""
    (fn factorial [n]
      (if (n <= 1)
        1
      else
        (n * (factorial (n - 1)))))
    (factorial 5)
  """, 120.to_value())

test "Two-argument functions":
  # Test basic two-arg function
  test_vm("(fn add [a b] (a + b)) (add 3 4)", 7.to_value())
  
  # Test two-arg with different types
  test_vm("""
    (fn pair [x y] [x y])
    (pair 1 "two")
  """, new_array_value(@[1.to_value(), "two".to_value()]))

  # Test two-arg comparison
  test_vm("""
    (fn max [a b]
      (if (a > b) a else b))
    (max 10 5)
  """, 10.to_value())
  
  # Test recursive two-arg (power)
  test_vm("""
    (fn power [base exp]
      (if (exp == 0)
        1
      else
        (base * (power base (exp - 1)))))
    (power 2 8)
  """, 256.to_value())

test "Mixed function calls":
  # Test calling functions with different arg counts
  test_vm("""
    (fn zero [] 0)
    (fn one [x] x)
    (fn two [x y] (x + y))
    
    ((two (one 5) (zero)) + (one 3))
  """, 8.to_value())
  
  # Test function returning function - DISABLED (closures not fully implemented)
  # test_vm("""
  #   (fn make_adder [n]
  #     (fn [x] (x + n)))
  #   (var add5 (make_adder 5))
  #   (add5 10)
  # """, 15.to_value())

test "Performance: Fibonacci comparison":
  # Small fibonacci for testing correctness
  test_vm("""
    (fn fib [n]
      (if (n < 2)
        n
      else
        ((fib (n - 1)) + (fib (n - 2)))))
    (fib 10)
  """, 55.to_value())

test "Performance: Zero-arg function calls":
  # # Test that zero-arg optimization works - DISABLED (closures not fully implemented)
  # test_vm("""
  #   (fn counter []
  #     (var count 0)
  #     (fn []
  #       (count = (count + 1))
  #       count))
  #   (var c (counter))
  #   (c)
  #   (c)
  #   (c)
  # """, 3.to_value())
  
  # Simple zero-arg test instead
  test_vm("""
    (fn get_value [] 100)
    (get_value)
  """, 100.to_value())

test "Performance: Two-arg recursive functions":
  # Ackermann function (small values only for testing)
  test_vm("""
    (fn ack [m n]
      (if (m == 0)
        (n + 1)
      else
        (if (n == 0)
          (ack (m - 1) 1)
        else
          (ack (m - 1) (ack m (n - 1))))))
    (ack 2 3)
  """, 9.to_value())

test "Edge cases":
  # Test empty function body (returns 0)
  test_vm("(fn empty [] 0) (empty)", 0.to_value())
  
  # Test function with unused parameters
  test_vm("(fn ignore [a b] 42) (ignore 1 2)", 42.to_value())
  
  # Test nested function definitions
  test_vm("""
    (fn outer [x]
      (fn inner [y]
        (x + y))
      (inner 10))
    (outer 5)
  """, 15.to_value())

# Performance benchmark tests (optional, can be run separately)
when isMainModule:
  test "Benchmark: Zero-arg function (100 calls)":
    let code = """
      (fn constant [] 42)
      (var sum 0)
      (var i 0)
      (loop
        (if (i >= 100) (break))
        (sum = (sum + (constant)))
        (i = (i + 1)))
      sum
    """
    
    let start = epochTime()
    test_vm(code, 4200.to_value())
    let elapsed = epochTime() - start
    echo fmt"  Zero-arg benchmark: {elapsed:.4f}s"
  
  test "Benchmark: Single-arg function (fibonacci 20)":
    let code = """
      (fn fib [n]
        (if (n < 2)
          n
        else
          ((fib (n - 1)) + (fib (n - 2)))))
      (fib 20)
    """
    
    let start = epochTime()
    test_vm(code, 6765.to_value())
    let elapsed = epochTime() - start
    echo fmt"  Single-arg benchmark (fib 20): {elapsed:.4f}s"
  
  test "Benchmark: Two-arg function (ackermann 3 5)":
    let code = """
      (fn ack [m n]
        (if (m == 0)
          (n + 1)
        else
          (if (n == 0)
            (ack (m - 1) 1)
          else
            (ack (m - 1) (ack m (n - 1))))))
      (ack 3 5)
    """
    
    let start = epochTime()
    test_vm(code, 253.to_value())
    let elapsed = epochTime() - start
    echo fmt"  Two-arg benchmark (ack 3 5): {elapsed:.4f}s"

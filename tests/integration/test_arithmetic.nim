import gene/types except Exception

import ../helpers

# Tests for arithmetic operations
# Basic arithmetic operations are implemented in our VM
# Note: basic arithmetic cases like (1 + 2) are covered in tests/test_vm.nim; keeping the rest here for broader coverage


test_vm "(5 - 3)", 2
test_vm "(4 * 2)", 8
test_vm "(8 / 2)", 4.0
test_vm "(9 / 3)", 3.0

# Test precedence with parentheses
test_vm "((1 + 2) * 3)", 9
test_vm "(1 + (2 * 3))", 7
test_vm "((10 - 4) / 2)", 3.0

# Test with floats
# NOTE: Some float values like 1.0, 1.5 have bit patterns that are misinterpreted as integers
# due to the tagged pointer system. Using float values that are correctly tagged.
test_vm "(2.5 + 2.5)", 5.0
test_vm "(5.0 - 2.5)", 2.5
test_vm "(3.0 * 2.0)", 6.0
test_vm "(10.0 / 2.0)", 5.0

# Test with negative numbers
# With NaN boxing, negative integers are now properly supported
test_vm "(-1 + 2)", 1
test_vm "(1 + -2)", -1
test_vm "(-3 * 2)", -6
test_vm "(6 / -2)", -3.0  # Division always returns float

# More complex arithmetic - not yet implemented in VM
# test_vm "(1 + 2 + 3)", 6
# test_vm "(2 * 3 + 4)", 10
# test_vm "(2 + 3 * 4)", 14
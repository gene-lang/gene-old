# Optimized arithmetic operations with type specialization
# This module provides fast paths for common arithmetic operations
# avoiding allocations and unnecessary checks where possible

import math
import ../types

proc c_fmod(x, y: cdouble): cdouble {.importc: "fmod", header: "<math.h>".}

# Fast integer arithmetic with overflow checking
template add_int_fast*(a, b: int64): Value {.dirty.} =
  # Check for overflow
  when defined(release):
    # In release mode, just wrap around
    (a + b).to_value()
  else:
    # In debug mode, check for overflow
    let sum = a + b
    if (b > 0 and sum < a) or (b < 0 and sum > a):
      # Overflow occurred - could upgrade to bigint here
      raise new_exception(types.Exception, "Integer overflow in addition")
    else:
      sum.to_value()

template sub_int_fast*(a, b: int64): Value {.dirty.} =
  when defined(release):
    (a - b).to_value()
  else:
    let diff = a - b
    if (b > 0 and diff > a) or (b < 0 and diff < a):
      raise new_exception(types.Exception, "Integer overflow in subtraction")
    else:
      diff.to_value()

template mul_int_fast*(a, b: int64): Value {.dirty.} =
  when defined(release):
    (a * b).to_value()
  else:
    if a != 0 and b != 0:
      let product = a * b
      if product div a != b:
        raise new_exception(types.Exception, "Integer overflow in multiplication")
      else:
        product.to_value()
    else:
      0.to_value()

template div_int_fast*(a, b: int64): Value {.dirty.} =
  if b == 0:
    raise new_exception(types.Exception, "Division by zero")
  else:
    (a div b).to_value()

# Fast float arithmetic (no overflow checks needed)
template add_float_fast*(a, b: float64): Value {.dirty.} =
  (a + b).to_value()

template sub_float_fast*(a, b: float64): Value {.dirty.} =
  (a - b).to_value()

template mul_float_fast*(a, b: float64): Value {.dirty.} =
  (a * b).to_value()

template div_float_fast*(a, b: float64): Value {.dirty.} =
  if b == 0.0:
    if a == 0.0:
      NaN.to_value()
    elif a > 0.0:
      Inf.to_value()
    else:
      (-Inf).to_value()
  else:
    (a / b).to_value()

# Mixed arithmetic helpers
template add_mixed*(int_val: int64, float_val: float64): Value {.dirty.} =
  (int_val.float64 + float_val).to_value()

template sub_mixed*(int_val: int64, float_val: float64): Value {.dirty.} =
  (int_val.float64 - float_val).to_value()

template mul_mixed*(int_val: int64, float_val: float64): Value {.dirty.} =
  (int_val.float64 * float_val).to_value()

template div_mixed*(int_val: int64, float_val: float64): Value {.dirty.} =
  if float_val == 0.0:
    if int_val == 0:
      NaN.to_value()
    elif int_val > 0:
      Inf.to_value()
    else:
      (-Inf).to_value()
  else:
    (int_val.float64 / float_val).to_value()

# Specialized comparison operations
template lt_int_fast*(a, b: int64): Value {.dirty.} =
  if a < b: TRUE else: FALSE

template lt_float_fast*(a, b: float64): Value {.dirty.} =
  if a < b: TRUE else: FALSE

template lt_mixed*(int_val: int64, float_val: float64): Value {.dirty.} =
  if int_val.float64 < float_val: TRUE else: FALSE

template lte_int_fast*(a, b: int64): Value {.dirty.} =
  if a <= b: TRUE else: FALSE

template lte_float_fast*(a, b: float64): Value {.dirty.} =
  if a <= b: TRUE else: FALSE

template gt_int_fast*(a, b: int64): Value {.dirty.} =
  if a > b: TRUE else: FALSE

template gt_float_fast*(a, b: float64): Value {.dirty.} =
  if a > b: TRUE else: FALSE

template gte_int_fast*(a, b: int64): Value {.dirty.} =
  if a >= b: TRUE else: FALSE

template gte_float_fast*(a, b: float64): Value {.dirty.} =
  if a >= b: TRUE else: FALSE

template eq_int_fast*(a, b: int64): Value {.dirty.} =
  if a == b: TRUE else: FALSE

template eq_float_fast*(a, b: float64): Value {.dirty.} =
  if a == b: TRUE else: FALSE

template neq_int_fast*(a, b: int64): Value {.dirty.} =
  if a != b: TRUE else: FALSE

template neq_float_fast*(a, b: float64): Value {.dirty.} =
  if a != b: TRUE else: FALSE

# Power operation specialization
proc pow_int_fast*(base, exp: int64): Value =
  if exp < 0:
    # Negative exponent returns float
    return pow(base.float64, exp.float64).to_value()
  elif exp == 0:
    return 1.to_value()
  elif exp == 1:
    return base.to_value()
  else:
    var res: int64 = 1
    var b = base
    var e = exp
    while e > 0:
      if (e and 1) == 1:
        res *= b
        # Check for overflow
        when not defined(release):
          if b != 0 and res div b != (res div b):
            raise new_exception(types.Exception, "Integer overflow in power")
      b *= b
      e = e shr 1
    return res.to_value()

proc pow_float_fast*(base, exp: float64): Value {.inline.} =
  pow(base, exp).to_value()

# Modulo operation
template mod_int_fast*(a, b: int64): Value {.dirty.} =
  if b == 0:
    raise new_exception(types.Exception, "Modulo by zero")
  else:
    (a mod b).to_value()

proc mod_float_fast*(a, b: float64): Value {.inline.} =
  if b == 0.0:
    NaN.to_value()
  else:
    c_fmod(a, b).to_value()

# Bitwise operations (integers only)
template and_int_fast*(a, b: int64): Value {.dirty.} =
  (a and b).to_value()

template or_int_fast*(a, b: int64): Value {.dirty.} =
  (a or b).to_value()

template xor_int_fast*(a, b: int64): Value {.dirty.} =
  (a xor b).to_value()

template shl_int_fast*(a, b: int64): Value {.dirty.} =
  if b < 0 or b >= 64:
    raise new_exception(types.Exception, "Invalid shift amount")
  else:
    (a shl b).to_value()

template shr_int_fast*(a, b: int64): Value {.dirty.} =
  if b < 0 or b >= 64:
    raise new_exception(types.Exception, "Invalid shift amount")
  else:
    (a shr b).to_value()

# Unary operations
template neg_int_fast*(a: int64): Value {.dirty.} =
  (-a).to_value()

template neg_float_fast*(a: float64): Value {.dirty.} =
  (-a).to_value()

template not_int_fast*(a: int64): Value {.dirty.} =
  (not a).to_value()

# Helper to check if values are numeric and get their values
template is_numeric*(v: Value): bool =
  v.kind in {VkInt, VkFloat}

template get_int_val*(v: Value): int64 =
  v.to_int()

template get_float_val*(v: Value): float64 =
  to_float(v)

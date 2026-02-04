## Runtime Type Information and Checking
##
## This module provides runtime type checking utilities that work with
## Gene's NaN-boxed values and the gradual type system.

import ./type_defs
import ./value_core

# Runtime type checking using NaN tags
proc is_int*(v: Value): bool {.inline.} =
  ## Check if value is an integer at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == SMALL_INT_TAG

proc is_float*(v: Value): bool {.inline.} =
  ## Check if value is a float at runtime
  # Floats are any non-NaN value in NaN space
  (v.raw and NAN_MASK) != NAN_MASK

proc is_bool*(v: Value): bool {.inline.} =
  ## Check if value is a boolean at runtime
  v == TRUE or v == FALSE

proc is_string*(v: Value): bool {.inline.} =
  ## Check if value is a string at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == STRING_TAG

proc is_symbol*(v: Value): bool {.inline.} =
  ## Check if value is a symbol at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == SYMBOL_TAG

proc is_nil*(v: Value): bool {.inline.} =
  ## Check if value is nil at runtime
  v == NIL

proc is_array*(v: Value): bool {.inline.} =
  ## Check if value is an array at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == ARRAY_TAG

proc is_map*(v: Value): bool {.inline.} =
  ## Check if value is a map at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == MAP_TAG

proc is_instance*(v: Value): bool {.inline.} =
  ## Check if value is a class instance at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == INSTANCE_TAG

proc is_gene*(v: Value): bool {.inline.} =
  ## Check if value is a Gene expression at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == GENE_TAG

# Type validation for function calls
proc validate_int*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is an integer, raise exception if not
  if not is_int(v):
    raise new_exception(type_defs.Exception, param_name & " must be Int, got " & $v.kind)

proc validate_float*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a float, raise exception if not
  if not is_float(v):
    raise new_exception(type_defs.Exception, param_name & " must be Float, got " & $v.kind)

proc validate_bool*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a boolean, raise exception if not
  if not is_bool(v):
    raise new_exception(type_defs.Exception, param_name & " must be Bool, got " & $v.kind)

proc validate_string*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a string, raise exception if not
  if not is_string(v):
    raise new_exception(type_defs.Exception, param_name & " must be String, got " & $v.kind)

# Get runtime type name as string
proc runtime_type_name*(v: Value): string =
  ## Get the runtime type name of a value
  ## This uses the NaN tag to determine the type
  case v.kind
  of VkInt: "Int"
  of VkFloat: "Float"
  of VkBool: "Bool"
  of VkString: "String"
  of VkSymbol: "Symbol"
  of VkComplexSymbol: "ComplexSymbol"
  of VkNil: "Nil"
  of VkArray: "Array"
  of VkMap: "Map"
  of VkInstance:
    # For instances, try to get the class name
    let inst = cast[ptr InstanceObj](v.raw and PAYLOAD_MASK)
    if inst != nil and inst.instance_class != nil:
      return inst.instance_class.name
    "Instance"
  of VkGene: "Gene"
  of VkFuture: "Future"
  of VkGenerator: "Generator"
  of VkThread: "Thread"
  else: $v.kind

# Type compatibility checking for gradual typing
proc is_compatible*(value: Value, expected_type: string): bool =
  ## Check if a value is compatible with an expected type name
  ## Returns true for:
  ## - Exact type match
  ## - Any type (gradual typing)
  ## - Type hierarchy (e.g., Int is compatible with Numeric)
  ## - Class inheritance (e.g., Dog is compatible with Animal)
  
  if expected_type == "Any":
    return true
  
  let actual = runtime_type_name(value)
  
  # Exact match
  if actual == expected_type:
    return true
  
  # Type hierarchy checks for primitives
  case expected_type
  of "Numeric":
    return actual in ["Int", "Float"]
  of "Collection":
    return actual in ["Array", "Map", "Set"]
  else:
    discard
  
  # Class inheritance check for instances
  if value.kind == VkInstance:
    let inst = cast[ptr InstanceObj](value.raw and PAYLOAD_MASK)
    if inst != nil and inst.instance_class != nil:
      # Walk up the class hierarchy
      var current = inst.instance_class.parent
      while current != nil:
        if current.name == expected_type:
          return true
        current = current.parent
  
  return false

proc validate_type*(value: Value, expected_type: string, param_name: string = "argument") =
  ## Validate that a value is compatible with an expected type
  ## Raises a Gene exception if not compatible (catchable by Gene try/catch)
  if not is_compatible(value, expected_type):
    let actual = runtime_type_name(value)
    raise new_exception(type_defs.Exception,
      "Type error: expected " & expected_type & ", got " & actual & " in " & param_name)

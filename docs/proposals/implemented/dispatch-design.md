# Dynamic Dispatch Design

**Author:** Sunni (AI Assistant)  
**Date:** 2026-01-29  
**Status:** 🟢 Implementation

## Overview

Gene uses a two-phase dispatch system:
1. **Name resolution** - resolve function/method by name
2. **Type validation** - validate argument types match signature

This design supports gradual typing with NaN-tagged values.

## Dispatch Flow

```
Call site: (add x y)
    ↓
1. Resolve "add" by name
    ↓
2. Check argument types against signature
    ↓
3. Call if types match (or dynamic fallback)
```

## Type Representation

### Compile-Time
- Type annotations stored in TypeExpr (type_checker.nim)
- Generic type variables (TkVar) for parametric polymorphism
- Function types include parameter and return types

### Runtime
- NaN tagging provides fast type checks
- Type bits encoded in f64 value
- No separate type metadata needed for primitives
- Objects have type_id in header

## Generics

### Gradual Approach
```gene
# Type parameter T is for documentation/static checking
(fn [T] (identity [x ^T]) ^T
  x)

# At runtime: just use dynamic types from NaN tags
# No code specialization (like TypeScript)
# Type checking when annotations present
```

### Type Variable Resolution
- Type variables (^T) unified at compile-time when possible
- At runtime, treated as `Any` (accept any type)
- Future: JIT can specialize based on observed types

## Validation Strategy

### Single Validation (Not Overloading)
- One function per name (for now)
- Resolve name → get single candidate
- Validate args match or are compatible with `Any`

### Type Compatibility
```
Int     <: Any     (always)
Float   <: Any     (always)
T       <: Any     (type variables default to Any)
Any     -> Concrete (runtime check with NaN tag)
```

## Implementation Plan

### Phase 1: Enable Type Checking (Week 1) ✅
- [x] Make type_check=true by default in compiler
- [x] Update CLI to support --no-type-check flag
- [x] Make missing annotations default to ^Any
- [x] Test with existing code (65 tests passing)

### Phase 2: Two-Phase Dispatch (Week 2) ✅
- [x] Add function signature storage in VM
- [x] Implement name resolution phase
- [x] Add argument type validation phase (validate_type in args.nim)
- [x] Runtime type checks using NaN tags

### Phase 3: Gradual Generics (Week 3) ✅
- [x] Ensure type variables default to Any at runtime (untyped params = Any)
- [x] No monomorphization (single code path)
- [x] Allow generic functions to work with dynamic types
- [x] Class inheritance works with type validation

### Phase 4: Runtime Type Info (Week 4) ✅
- [x] Add type_id to object headers (using InstanceObj.class_obj)
- [x] Implement `.is` type checks (all built-in types + inheritance)
- [x] Support runtime type queries

## Example

```gene
# Function with type annotations
(fn (add [x ^Int y ^Int]) ^Int
  (+ x y))

# Call site
(add 1 2)   # OK: Int + Int -> Int
(add 1.0 2) # Error: Float incompatible with ^Int
```

### With Generics
```gene
# Generic identity function
(fn [T] (identity [x ^T]) ^T
  x)

# Calls
(identity 42)       # T = Int (inferred)
(identity "hello")  # T = String (inferred)
```

### Gradual Typing
```gene
# No annotations = Any
(fn (flexible [x y])
  (+ x y))

(flexible 1 2)       # OK: dynamic
(flexible "a" "b")   # OK: dynamic
```

## Implementation Notes (2026-01-31)

### Runtime Type Validation
- **Location:** `src/gene/types/runtime_types.nim` (validate_type proc)
- **Entry points:** 
  - `src/gene/vm/args.nim` (process_args routes typed functions through validation)
  - `src/gene/vm.nim` (checks `has_type_annotations` flag)
- **Error handling:** Raises Gene exceptions (new_exception) - catchable by Gene try/catch (when SIGSEGV bug fixed)

### .is Operator
- **Location:** `src/gene/vm/is_operator.nim`
- **Supported types:** Int, Float, Bool, String, Symbol, Char, Nil, Array, Map, Set, Regex, Time, Date, DateTime, Range, Function, Macro, Proc, Class, Instance, Enum, Any
- **Inheritance:** Works correctly - `(child .is Parent)` returns true

### Known Issues
- `try/catch` causes SIGSEGV in `value_core.nim:2280 pop` - type errors can't be caught in Gene code yet

## Notes

- Start simple: single validation per function name
- Gradual: missing annotations = Any
- NaN tagging gives us fast runtime type checks
- Future: overloading can be added later
- Future: JIT specialization based on type annotations

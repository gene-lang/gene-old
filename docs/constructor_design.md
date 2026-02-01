# Constructor Design for Gene Language

## Overview

This document describes the design and implementation of constructors in Gene, including both regular constructors and macro constructors. The goal is to provide a natural, aesthetically pleasing syntax that clearly distinguishes between evaluated and unevaluated argument handling.

## Current State

Gene already has partial support for macro constructors:

- `ctor!` - Creates a macro-like constructor that receives unevaluated arguments
- `new!` - Calls a constructor with unevaluated arguments
- `new` - Calls a constructor with evaluated arguments

## Design Principles

1. **Clarity**: The syntax should clearly indicate whether arguments are evaluated or unevaluated
2. **Consistency**: Follow the same `!` convention used for macro-like functions and methods
3. **Safety**: Provide helpful error messages when constructors and instantiation don't match
4. **Flexibility**: Support both simple and complex constructor patterns

## Syntax Design

### Constructor Definitions

```gene
# Regular constructor - arguments are evaluated
(class Person
  (ctor [name age]
    (/name = name)      # name is already evaluated
    (/age = age)        # age is already evaluated
  )
)

# Macro constructor - arguments are unevaluated
(class LazyPerson
  (ctor! [name age]
    (/name = ($caller_eval name))  # name is a symbol, we evaluate it
    (/age = ($caller_eval age))    # age is a symbol, we evaluate it
  )
)
```

### Object Instantiation

```gene
# Regular instantiation with regular constructor
(var p1 (new Person "Alice" 30))

# Macro instantiation with macro constructor
(var p2 (new! LazyPerson name age))  # name and age are symbols

# These should throw exceptions:
(var p3 (new Person name age))        # Regular constructor expects evaluated args
(var p4 (new! LazyPerson "Bob" 25))   # Macro constructor expects unevaluated args
```

### Inheritance and Super Calls

```gene
(class Student < Person
  (ctor! [name age grade]
    (super .ctor! name age)    # Pass unevaluated args to parent macro constructor
    (/grade = ($caller_eval grade))
  )
)

(class Employee < Person
  (ctor [name age salary]
    (super .ctor name age)     # Pass evaluated args to parent regular constructor
    (/salary = salary)
  )
)
```

## Implementation Requirements

### 1. Constructor Type Detection

The compiler must detect constructor types:
- `ctor` → Regular constructor (evaluated args)
- `ctor!` → Macro constructor (unevaluated args)

### 2. Instantiation Validation

The VM must validate constructor/instance pairs:
- `new Class` with regular constructor ✓
- `new! Class` with macro constructor ✓
- `new Class` with macro constructor ✗ (error: "Cannot use 'new' with macro constructor, use 'new!'")
- `new! Class` with regular constructor ✗ (error: "Cannot use 'new!' with regular constructor, use 'new'")

### 3. Super Constructor Calls

Support both regular and macro super calls:
- `(super .ctor args...)` - Regular super constructor call
- `(super .ctor! args...)` - Macro super constructor call

### 4. Error Messages

Clear, helpful error messages for mismatches:
- "Constructor mismatch: Class 'Foo' has a macro constructor, use 'new!' instead of 'new'"
- "Constructor mismatch: Class 'Bar' has a regular constructor, use 'new' instead of 'new!'"
- "Super constructor mismatch: Parent class has a macro constructor, use '(super .ctor!)' instead of '(super .ctor)'"

## Use Cases

### 1. Lazy Evaluation

```gene
(class Config
  (ctor! [config_file]
    (/config_file = ($caller_eval config_file))
    (/data = nil)  # Will be loaded lazily
  )

  (method load_config _
    (/data = (read_file /config_file))
  )
)

(var cfg (new! Config config_file_path))  # config_file_path is a symbol
```

### 2. Expression Templates

```gene
(class Query
  (ctor! [table condition]
    (/table = ($caller_eval table))
    (/condition = condition)      # Keep as unevaluated expression
  )

  (method to_sql _
    "SELECT * FROM " + /table + " WHERE " + (condition .to_sql)
  )
)

(var q (new! Query users (> age 18)))  # (> age 18) stays as expression
```

### 3. Validation Rules

```gene
(class ValidatedField
  (ctor! [field_name validation_rule]
    (/field_name = ($caller_eval field_name))
    (/validation_rule = validation_rule)  # Keep rule as callable
  )

  (method validate [value]
    ((/validation_rule) value)
  )
)

(var name_field (new! ValidatedField name (fn [v] (and (> v.len 0) (< v.len 50)))))
```

## Implementation Plan

### Phase 1: Validation
- Add constructor type tracking in Class metadata
- Implement validation in VM for `new`/`new!` calls
- Add clear error messages

### Phase 2: Super Constructor Support
- Implement `(super .ctor!)` syntax
- Handle macro super calls in inheritance chains
- Add validation for super constructor calls

### Phase 3: Testing and Documentation
- Comprehensive test suite for all constructor patterns
- Update language documentation
- Add examples to standard library

## Backward Compatibility

This design is fully backward compatible:
- Existing `ctor` and `new` code continues to work unchanged
- New `ctor!` and `new!` syntax is additive
- Only new validation errors are introduced for mismatched usage

## Future Considerations

### 1. Constructor Overloading
Potentially support multiple constructors with different signatures:
```gene
(class Point
  (ctor [x y] ...)      # Two-arg constructor
  (ctor! [coord] ...)   # Single symbolic arg constructor
)
```

### 2. Constructor Attributes
Attributes to modify constructor behavior:
```gene
(class Example
  (ctor [args...] {^private true})  # Private constructor
  (ctor! [args...] {^inline true})  # Inline macro constructor
)
```

### 3. Default Constructors
Automatic generation of default constructors when none are defined.

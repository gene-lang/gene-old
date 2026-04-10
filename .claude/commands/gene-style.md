---
name: Gene Style Guide
description: Design philosophy and syntax preferences for writing idiomatic Gene code
category: Gene
tags: [gene, style, syntax]
---

# Gene Language Style Guide

## Design Philosophy

Gene is a **homoiconic Lisp-like language** that values:
- **Readability over brevity** - code should be clear at a glance
- **Consistency** - similar operations should look similar
- **Minimal parentheses** - use syntax sugar to reduce nesting when it improves clarity

## Formatting

### Closing Brackets

**One-line expressions**: Keep brackets on same line
```gene
(if cond then a else b)
(x + y)
{^name "Alice"}
[1 2 3]
```

**Multi-line expressions**: Closing `)]}`on its own line, same indentation as opening
```gene
# Preferred
(if (x > 5)
  "big"
else
  "small"
)

(fn process [items]
  (items .each (fn [item]
    (println item)
  ))
)

{
  ^name "Alice"
  ^age 30
}

# Avoid - closing bracket not on own line
(if (x > 5)
  "big"
else
  "small")
```

## Syntax Preferences

### Method Calls

**No-argument methods**: Use `/.` shorthand instead of parentheses
```gene
# Preferred
str/.length
arr/.size
obj/.to_s

# Avoid
(str .length)
(arr .size)
```

**Methods with arguments**: Use parentheses with space before method name
```gene
# Preferred
(arr .get 0)
(str .substr 0 5)

# Avoid - no space before method
(arr.get 0)
```

### Property/Index Access

**Use `/` for property and index access**:
```gene
# Preferred
arr/0           # Array index
map/key         # Map key (symbol)
obj/property    # Object property

# Avoid
(arr .get 0)    # Unless you need default value handling
```

### Operators

**Infix operators inside parentheses**:
```gene
# Preferred
(x + y)
(a == b)
(i >= arr/.size)

# Assignment
(x = 10)
(x += 1)
```

### Variables

```gene
(var x 10)              # Declaration with initial value
(var y)                 # Declaration without value (nil)
(x = 20)                # Assignment
```

### Maps and Arrays

**Maps use `^` prefix for keys**:
```gene
# Preferred
{^name "Alice" ^age 30}
{^key value ^another "thing"}

# Access
map/name
(map .get "name" "default")
```

**Arrays use brackets**:
```gene
[1 2 3]
["a" "b" "c"]
```

### Control Flow

**One-line if**: Use `then` keyword for single-line conditionals:
```gene
# Preferred for simple cases
(if cond then a else b)
(if (x > 0) then "positive" else "non-positive")
```

**Multi-line if/elif/else**:
```gene
(if condition
  result-if-true
else
  result-if-false
)

(if (x > 5)
  "big"
elif (x == 5)
  "equal"
else
  "small"
)
```

**Loops**:
```gene
(loop
  (if done (break))
  ...body...
)

# Iteration
(items .each (fn [item]
  ...process item...
))
```

### Functions

```gene
# Named function
(fn add [a b]
  (a + b)
)

# With default parameter
(fn greet [name = "World"]
  (println "Hello" name)
)

# Anonymous/lambda
(fn [x] (x * 2))
```

### Classes

```gene
(class Point
  (ctor [x y]
    (/x = x)          # Use / for instance properties
    (/y = y)
  )

  (method distance [other]
    # Method body
  )
)

(var p (new Point 3 4))
p/x                     # Access property
(p .distance other)     # Call method
```

### String Interpolation

**Use `#"..."` for interpolation**:
```gene
(var name "World")
#"Hello, #{name}!"      # => "Hello, World!"

# Multi-line with triple quotes
#"""
Multi-line string
with #{interpolation}
"""
```

### Error Handling

```gene
# Catch all exceptions
(try
  (risky-operation)
catch *
  (println "Error:" $ex/message)
)

# Catch specific type (must be subclass of Exception)
(try
  (risky-operation)
catch SomeException
  (println "Caught:" $ex/message)
)

(throw "Something went wrong")
```

## Naming Conventions

- **Variables/functions**: `snake_case`
- **Classes**: `PascalCase`
- **Constants**: `UPPER_SNAKE_CASE`

## Common Patterns

### Building Strings
```gene
(var out "")
(items .each (fn [item]
  (out .append item/.to_s)
  )
)
```

### Iterating with Index
```gene
(var i 0)
(loop
  (if (i >= items/.size) (break))
  (var item (items .get i))
  # ... process ...
  (i += 1)
)
```

### Map Transformation
```gene
(var results [])
(items .each (fn [item]
  (results .append (transform item))
  )
)
```

### Guard Clauses
```gene
(fn process [input]
  (if (input == nil)
    (return nil)
  )
  (if (input/.length == 0)
    (return "")
  )
  # Main logic here
)
```

## Things to Avoid

1. **Don't use `(obj .method)` for no-arg calls** - use `obj/.method`

2. **Don't convert char to string with `.to_s`** - it wraps in quotes
   ```gene
   # Wrong - produces 'a' with quotes
   (var ch (str .char_at 0))
   ch/.to_s

   # Right - use substr for single char as string
   (str .substr 0 0)
   ```

3. **Exception catching syntax**
   ```gene
   # Catch all exceptions
   catch *
     $ex/message    # Access exception via $ex

   # Catch specific exception type (must be subclass of Exception)
   catch SomeException
     $ex/message
   ```

4. **Don't forget `^` prefix for map keys**
   ```gene
   # Wrong
   {key "value"}

   # Right
   {^key "value"}
   ```

## Async/Await

```gene
(var result (await (async-operation)))

(async
  (println "This runs 'asynchronously'")
)
```

## Comments

```gene
# Single line comment

#<
  Multi-line
  block comment
>#
```

# Generator Functions Design Document

## Overview

Generator functions are pull-based producers. Unlike regular functions that return once, generators suspend at `yield`, preserve local state, and resume when the caller requests the next value.

Current semantics:
- Exhaustion is reported with `NOT_FOUND`.
- `void` is distinct from exhaustion. If a generator explicitly yields `void`, that is a real yielded value.
- The public runtime API today is `.next` and `.has_next`.
- Generators are currently a low-level lazy sequence primitive, not yet a full language-wide iteration protocol.

Typical uses:
- Lazy counters and ranges
- Stateful sequences such as Fibonacci
- Wrapping pagination or streaming behind a pull API
- Tree or token traversal without materializing all results up front

## Syntax

### Named Generator Functions
```gene
# Named generator functions end with *
(fn fibonacci* [n]
  (var a 0)
  (var b 1)
  (var i 0)
  (while (< i n)
    (yield a)
    (var temp (+ a b))
    (a = b)
    (b = temp)
    (i = (+ i 1))))
```

### Anonymous Generator Functions
```gene
# Anonymous generators use ^^generator flag
(var gen (fn ^^generator [max]
  (var i 0)
  (while (< i max)
    (yield i)
    (i = (+ i 1)))))
```

## Usage

```gene
# Create a generator instance
(var fib (fibonacci* 10))

# Get values using .next method
(println (fib .next))  # 0
(println (fib .next))  # 1
(println (fib .next))  # 1
(println (fib .next))  # 2

# has_next will call next() and return false if NOT_FOUND is returned.
# has_next will not consume the value. it can be called multiple times.

# When generator is exhausted, returns NOT_FOUND
(var gen (fibonacci* 2))
(gen .next)  # 0
(gen .next)  # 1
(gen .next)  # NOT_FOUND
```

### Exhaustion vs `void`

Generator exhaustion is `NOT_FOUND`, not `void`.

```gene
(fn values* []
  (yield 1)
  (yield void)
  (yield 3))

(var g (values*))
(g .next)  # 1
(g .next)  # void
(g .next)  # 3
(g .next)  # NOT_FOUND
```

This distinction is intentional:
- `NOT_FOUND` means there is no next value.
- `void` means the generator produced a value whose content is `void`.

### Current Iteration Style

Generators are currently meant to be consumed manually:

```gene
(var g (fibonacci* 5))
(while (g .has_next)
  (println (g .next)))
```

`for ... in` integration is not implemented yet, so generators should be treated as manual pull iterators for now.

## Implementation Architecture

### 1. Type System Changes

#### Function Type Extension
- Add `is_generator: bool` field to `Function` type
- Generators are functions with special execution semantics

#### Generator Instance Type
- New `VkGenerator` value kind
- Contains:
  - `function: Function` - The generator function definition
  - `state: GeneratorState` - Current execution state
  - `frame: Frame` - Saved execution frame
  - `pc: int` - Program counter position
  - `scope: ScopeObj` - Captured scope
  - `done: bool` - Whether generator is exhausted

### 2. Parser Changes

#### Named Generators
- Detect function names ending with `*`
- Set `is_generator = true` on the Function object
- Keep `*` as part of the function name (e.g., `fibonacci*`)

#### Anonymous Generators
- Parse `^^generator` flag in function definitions
- Set `is_generator = true` when flag is present

### 3. Compiler Changes

#### New Instructions
- `IkYield` - Pause execution and return value
- `IkGeneratorReturn` - Mark generator as done

#### Compilation Rules
- When compiling generator functions, wrap body in generator setup
- Track yield points for state management
- Ensure proper scope capture

### 4. VM Changes

#### Generator Creation
- When calling a generator function, return a VkGenerator instead of executing
- Initialize generator state with:
  - Fresh frame
  - Starting PC
  - Captured scope
  - done = false

#### Yield Execution
- Save current frame state (stack, locals, PC)
- Return yielded value
- Mark generator as suspended

#### Next Method
- Restore saved frame state
- Continue execution from saved PC
- Handle generator exhaustion (return NOT_FOUND when done)

### 5. Memory Management

#### Scope Capture
- Generators must capture their scope to maintain local variables
- Use reference counting to prevent premature deallocation
- Similar to async functions but with multiple suspension points

#### Frame Management
- Allocate dedicated frame for each generator instance
- Frame persists between .next calls
- Clean up frame when generator is garbage collected

## Examples

### Simple Counter
```gene
(fn counter* [max]
  (var i 0)
  (while (< i max)
    (yield i)
    (i = (+ i 1))))

(var c (counter* 5))
(while true
  (var val (c .next))
  (if (== val NOT_FOUND)
    (break)
    (println val)))
# Output: 0 1 2 3 4
```

### Infinite Generator
```gene
(fn naturals* []
  (var n 0)
  (while true
    (yield n)
    (n = (+ n 1))))

(var nat (naturals*))
(println (nat .next))  # 0
(println (nat .next))  # 1
# Can continue forever...
```

### Generator with State
```gene
(fn running-total* [xs]
  (var sum 0)
  (for x in xs
    (sum = (+ sum x))
    (yield sum)))

(var totals (running-total* [1 2 3]))
(totals .next)   # 1
(totals .next)   # 3
(totals .next)   # 6
(totals .next)   # NOT_FOUND
```

## Future Enhancements

### Generator Expressions
```gene
# Potential future syntax
(var squares (for* x in (range 10) (* x x)))
```

### Async Generators
```gene
# Combine async and generator
(fn fetch-pages* [urls]
  (for url in urls
    (yield (await (fetch url)))))
```

### Generator Comprehensions
```gene
# List comprehension style
(var evens [x for* x in (range 100) if (even? x)])
```

## Testing Strategy

1. **Basic Functionality**
   - Simple yield and next
   - Generator exhaustion returns NOT_FOUND
   - Multiple generator instances

2. **State Preservation**
   - Local variables maintain state
   - Multiple yields in sequence
   - Nested loops with yields

3. **Edge Cases**
   - Empty generators (no yields)
   - Single yield generators
   - Generators that yield NOT_FOUND
   - Recursive generators

4. **Memory Management**
   - Scope capture and cleanup
   - Multiple active generators
   - Generators going out of scope

5. **Integration**
   - Generators in higher-order functions
   - Generators as arguments
   - Generators in collections
   - Explicitly cover `yield void` vs exhaustion
   - Document that `for ... in generator` is not supported yet

## Implementation Phases

### Phase 1: Core Infrastructure
1. Add VkGenerator type and is_generator flag
2. Implement IkYield instruction
3. Basic generator creation and .next method

### Phase 2: Parser Support
1. Parse fn* syntax for named generators
2. Parse ^^generator flag for anonymous generators
3. Validate generator function definitions

### Phase 3: Compiler Integration
1. Compile yield statements
2. Handle generator function calls
3. Implement proper scope capture

### Phase 4: VM Execution
1. Generator state management
2. Frame suspension and resumption
3. Exhaustion handling (return NOT_FOUND)

### Phase 5: Testing and Refinement
1. Comprehensive test suite
2. Performance optimization
3. Memory leak detection and fixes

## Open Questions

1. **Send Method**: Should we support sending values into generators like Python?
2. **Error Handling**: How should exceptions in generators be handled?
3. **Performance**: Should we optimize for memory or speed?
4. **Cleanup**: When should generator resources be released?
5. **Iteration Protocol**: Should generators integrate with for loops automatically?

## References

- Python PEP 255 (Simple Generators)
- JavaScript ES6 Generators
- Rust Generators RFC
- C# Iterators and yield return

# Gene Language: Design Principles and Vision

> **Note:** This document describes both current capabilities and future vision. Examples marked as "PLANNED" or "CURRENT" indicate implementation status. See the "Current State and Future Direction" section for details.

## Core Philosophy

Gene is a programming language that combines the best ideas from Lisp, Ruby, and functional programming, with a focus on performance and expressiveness. The language is built around five key principles:

1. **Gene-centric data model** - Everything revolves around Gene expressions
2. **Everything is an object** - Ruby-inspired object model for discoverability
3. **FP + OOP harmony** - Functional and object-oriented paradigms work together naturally
4. **Macros for extensibility** - Meta-programming as a first-class feature
5. **Performance through simplicity** - Clean pipeline from source to execution

## 1. Gene-Centric Data Model

### Gene as Universal Data Structure

The Gene expression is the fundamental building block. It's a tagged S-expression:

```gene
(tag arg1 arg2 ...)
```

Gene expressions serve multiple purposes:

**Code:**
```gene
(fn add [a b] (+ a b))
(if (> x 5) "big" else "small")
```

**Data:**
```gene
(user "Alice" ^age 30 ^active true)
(post ^title "Hello" ^content "World" ^tags ["news" "tech"])
```

**Templates:**
```gene
`(div
  (h1 %title)
  (p %content))
```

**DSLs:**
```gene
(http/get "/api/users"
  ^headers {^auth token}
  ^timeout 5000)

(sql/select [`name `email]
  ^from "users"
  ^where (> age 18))
```

### Homoiconicity

Code is data. Data is code. This enables:
- Easy AST manipulation
- Natural macro system
- Code generation without special syntax
- Meta-programming as a core feature

### Intuitive Gene Manipulation (PLANNED)

Gene should be as easy to work with as arrays and maps. Currently, Gene expressions can be created and accessed with `/` index syntax:

**Current:**
```gene
# Create Gene expression
(var g (_ 1 2 3))

# Index access
g/0  # => 1
g/1  # => 2

# Quote and render
(var tpl `(test %x))
(var x 42)
($render tpl)  # => (test 42)
```

**Planned:**
```gene
# Method-based access
((user ^name "Alice" ^age 30) .get `name)  # => "Alice"
((user ^name "Alice" ^age 30) .type)       # => user
((user ^name "Alice" ^age 30) .children)   # => [`name "Alice" `age 30]

# Transform
((user ^name "Alice" ^age 30)
  .update `age 31)  # => (user ^name "Alice" ^age 31)

# Pattern matching
(case data
  when 1 ...
  when 2 ...
  else ...
)
```

## 2. Everything Is an Object

Inspired by Ruby: every value responds to methods.

### Unified Method Syntax

**Currently implemented:**

```gene
# Strings
("hello" .to_upper)          # => "HELLO"
("hello" .to_lower)          # => "hello"
("hello" .length)            # => 5
("hello" .append "world")    # => "helloworld"

# Arrays
([1 2] .size)                # => 2
([1 2] .add 3)               # => [1 2 3] (mutates)
([1 2 3] .get 1)             # => 2

# Maps
({^a 1 ^b 2} .get `a)        # => 1
({^a 1} .contains `a)        # => true

# Gene expressions (index access)
(var g (_ 1 2 3))
g/0                          # => 1 (element access)

# Classes and namespaces
(new File "path.txt")        # Create instance
(File/write "file.txt" "content")  # Namespace function
(Math/sqrt 16)               # => 4.0
```

**Planned enhancements:**

```gene
# More collection methods
([1 2 3] .map double)        # => [2 4 6]
([1 2 3] .filter odd?)       # => [1 3]
({^a 1 ^b 2} .keys)          # => [`a `b]

# Number methods
(42 .to_s)                   # => "42"
(3.14 .round)                # => 3

# Gene manipulation methods
((user ^name "Alice") .get `name)   # => "Alice"
((user ^name "Alice") .type)        # => user
```

### Benefits

1. **Discoverability** - Methods make APIs explorable
2. **Consistency** - Same syntax across all types
3. **Chainability** - Natural pipelines
4. **Extensibility** - Add methods to existing types

### Method Definition

**Currently:** Methods are defined in Nim code using `def_native_method`:

```nim
# In src/gene/vm/core.nim
proc string_to_upper(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                     arg_count: int, has_keyword_args: bool): Value =
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  return self_arg.str.toUpperAscii().to_value()

string_class.def_native_method("to_upper", string_to_upper)
```

**Planned:** Method definition in Gene syntax:

```gene
# Define instance method
(class Array
  (method map [self f]
    [(for item in self
      ($emit (f item)))])

  # Define class method
  (method /from_range [cls start end]
    [(for i in (range start end)
      ($emit i))])
)

# Usage
([1 2 3] .map double)           # Instance method
(Array/from_range 1 10)         # Class/namespace function
```

## 3. FP + OOP Harmony

Functional programming and object-oriented programming are complementary, not contradictory.

### Object-Oriented Structure

Objects provide:
- **Organization** - Methods grouped by type
- **Discoverability** - IDE autocomplete, documentation
- **State management** - When needed
- **Polymorphism** - Different types, same interface

```gene
# Method chaining (OOP style) - PLANNED
(data
  .filter is-active;
  .map transform-user;
  .sort-by `name;
  .take 10)

# ; is a shorthand for wrapping up the previous expression
(a b; c) => ((a b) c)
```

### Functional Composition

Functions provide:
- **Transformation** - Pure functions, no side effects
- **Composition** - Build complex from simple
- **Higher-order functions** - Functions as values
- **Immutability** - Safe concurrent programming

```gene
# Pure functions
(fn double [x] (* x 2))
(fn add [a b] (+ a b))

# Composition
(fn compose [f g]
  (fn [x] (f (g x))))

(var double-then-add-5 (compose (add 5) double))
(double-then-add-5 3)  # => 11  (3*2+5)

# Higher-order functions
(map double [1 2 3])  # => [2 4 6]
```

### Working Together

```gene
# Functions work today
(fn double [x] (* x 2))
(fn is-positive [x] (> x 0))

# Function calls
(double 5)  # => 10

# Higher-order functions (PLANNED - needs collection methods)
([1 2 3 4 5]
  .filter is-positive
  .map double)

# OOP + FP together (PLANNED - needs class syntax)
(class UserService
  (fn active-user-names [self]
    (self/users
      .filter (fn [u] u.active);
      .map (fn [u] u.name);
      .sort)))
```

### Best of Both Worlds

| Aspect | OOP Provides | FP Provides |
|--------|--------------|-------------|
| Structure | Classes, methods, namespaces | Modules, pure functions |
| Abstraction | Interfaces, inheritance | Higher-order functions, composition |
| State | Encapsulation, mutation | Immutability, transformations |
| Reuse | Inheritance, mixins | Function composition, partial application |
| Discovery | Method listing, docs | Type signatures, examples |

## 4. Macros for Extensibility

Gene has a working macro system that enables meta-programming and code transformation.

### Current Macro System

**Macro Functions:** Functions whose names end with `!` are macros:

```gene
# Define a macro - note the ! suffix
(fn unless! [condition body]
  (if ($caller_eval condition)
    nil
  else
    ($caller_eval body)))

# Usage - arguments are NOT evaluated when passed to macro
(unless! (> x 5)
  (println "x is small"))

# The condition and body are passed as AST nodes
# The macro evaluates them in the caller's context using $caller_eval
```

**Key Features:**

1. **Unevaluated Arguments:** Arguments to macro functions (names ending with `!`) are passed as AST nodes, not evaluated values
2. **`$caller_eval`:** Evaluates expressions in the caller's scope, not the macro's scope
3. **Code Transformation:** Macros can inspect, transform, and generate code before evaluation

**More Examples:**

```gene
# Simple macro that evaluates argument twice
(fn twice! [expr]
  (do
    ($caller_eval expr)
    ($caller_eval expr)))

(var x 0)
(twice! (x = (+ x 1)))
# x is now 2

# Macro with default arguments
(fn with_default! [a = 1]
  (+ ($caller_eval a) 2))

(with_default!)  # => 3
(with_default! 5)  # => 7

# Access caller's variables
(var a 10)
(fn get_a! []
  ($caller_eval `a))

(get_a!)  # => 10
```

### Template System

Templates work with quote/unquote for code generation:

Note:
- Quote prefix is backtick (`` ` ``) and applies to the next form, e.g. ``(foo ...)``.
- Leading-colon tokens are ordinary symbols (e.g. `:foo`).
- Migration: ``:(...)`` → ``(...)``.

```gene
# Quote (template)
(var tpl `(+ 1 %x))

# Unquote and render
(var x 2)
($render tpl)  # => (+ 1 2)

# Eval the result
(eval ($render tpl))  # => 3
```

### Combining Macros and Templates

```gene
# Macro that generates code using templates
(fn when! [condition body...]
  ($caller_eval
    ($render
      `(if %condition %body ...))))

# Usage
(when! (> x 5)
  (println "x is large")
  (println "very large"))
```

### Macro Use Cases

**1. Control flow extensions:**
```gene
# When - execute body only if condition is true
(fn when! [condition body...]
  (if ($caller_eval condition)
    ($caller_eval body...)))

(when! (> x 5)
  (println "x is large")
  (println "doing more work"))

# Unless - opposite of if
(fn unless! [condition body]
  (if (not ($caller_eval condition))
    ($caller_eval body)))
```

**2. Variable capture and scope manipulation:**
```gene
# Capture caller's variables
(fn debug_var! [name]
  (println (str "Variable " name " = " ($caller_eval name))))

(var x 42)
(debug_var! x)  # Prints: Variable x = 42

# Let-like binding (simplified)
(fn let! [bindings body...]
  # Would need template generation for full implementation
  ($caller_eval body...))
```

**3. Code generation with templates:**
```gene
# Generate repetitive code
(fn repeat_n! [n expr]
  (var result `(do))
  (for i in (range n)
    (result = `(do %@result %expr)))
  ($caller_eval result))

# Usage
(repeat_n! 3 (println "Hello"))
# Prints "Hello" three times
```

**4. DSL building blocks:**
```gene
# Simple assertion macro
(fn assert! [condition message]
  ($caller_eval
    `(if (not %condition)
      (throw (str "Assertion failed: " %message)))))

(assert! (> x 0) "x must be positive")
```

### Macro System Characteristics

✅ **Unevaluated arguments** - Macro args are passed as AST nodes
✅ **Caller scope evaluation** - `$caller_eval` for hygiene
✅ **Template system** - Quote/unquote for code generation
📋 **Advanced features planned:**
- Compile-time macro expansion (currently runtime)
- Gensym for automatic hygiene
- Macro expansion introspection/debugging
- Pattern matching in macro arguments

## 5. Performance Through Simplicity

Gene achieves performance through a clean, optimizable pipeline.

### Execution Pipeline

```
Source Code → Parser → AST → Compiler → Bytecode → VM
                ↓            ↓           ↓
              Fast      Optimizations  Stack-based
            Minimal      Clean IR      Efficient
```

### Parser (`parser.nim`)

**Responsibilities:**
- Convert Gene source to AST
- Handle quote/unquote syntax
- Minimal processing - defer to compiler

**Performance characteristics:**
- Single-pass parsing
- No complex transformations
- Fast enough for REPL usage

### Compiler (`compiler.nim`)

**Responsibilities:**
- Transform AST to bytecode
- Macro expansion
- Static analysis
- Optimization passes

**Current optimizations:**
- Tail call optimization (potential)
- Constant folding
- Dead code elimination (potential)

**Future optimizations:**
- Inlining small functions
- Loop unrolling
- Type specialization

### VM (`vm.nim`)

**Responsibilities:**
- Execute bytecode efficiently
- Stack-based execution
- Method dispatch
- Memory management

**Performance characteristics:**
- Stack-based = minimal allocation
- Direct-threaded interpreter (potential)
- Reference counting for memory
- Frame pooling for function calls

**Future enhancements:**
- JIT compilation for hot paths
- Inline caching for method dispatch
- Generational GC (optional)

### Type System (`types.nim`)

**Current design:**
- Discriminated union (Value)
- 100+ value types
- Reference counting
- Manual memory management for scopes

**Performance benefits:**
- Single pointer per value
- Fast type checking (switch on enum)
- No boxing overhead for primitives
- Predictable memory layout

### Benchmark Philosophy

Performance targets (relative to Ruby/Python):
- **Parsing**: 5-10x faster (minimal complexity)
- **Compilation**: Comparable (Ruby doesn't compile)
- **Execution**: 2-5x faster (bytecode VM, not interpreted)
- **Memory**: Similar or better (ref counting vs GC)

Not trying to compete with:
- C/Rust (systems languages)
- Java/C# (JIT compilation)
- Go (compiled, static typed)

Target niche:
- Dynamic languages that need better performance
- Metaprogramming-heavy workloads
- DSL implementation
- Scripting with structure

## How It All Fits Together

### Example: Building a Web DSL (PLANNED)

This example shows the vision - most features are not yet implemented:

**1. Gene for structure:**
```gene
(defroute GET "/users" [req]
  (render `users users))
```

**2. Objects for organization:**
```gene
(class Router
  (fn add [self method path handler]
    (self/routes .add {^method method ^path path ^handler handler}))

  (fn handle [self req]
    (self/routes
      .find (fn [r] (and (== r.method req.method)
                         (r.path .matches? req.path)));
      .handler;
      .call req)))
```

### Example: Data Processing (Current Capabilities)

```gene
# Read file (works today)
(var content (File/read "data.txt"))

# Functions work
(fn is-positive [x] (> x 0))
(fn double [x] (* x 2))

# Basic array operations (works today)
(var arr [1 2 3])
(arr .add 4)           # => [1 2 3 4]
(var size (arr .size)) # => 4

# String operations (works today)
(var str "hello")
(var upper (str .to_upper))  # => "HELLO"

# Template with quote/unquote (works today)
(var name "Alice")
(var greeting `(println "Hello" %name))
(var rendered ($render greeting))  # => (println "Hello " "Alice")

### Example: Data Processing (Full Vision - PLANNED)

```gene
# Read and parse Gene data
(var users
  (File/read "users.gene")
  ($parse))

# Transform with method chaining
(var active-users
  (users
    .filter (fn [u] (u .get `active));
    .map (fn [u]
      (u .update `name ((u .get `name) .to_upper)));
    .sort-by (fn [u] (u .get `created_at))))

# Generate HTML report with template
(var report
  `(html
    (head (title "User Report"))
    (body
      (h1 "Active Users")
      (ul
        %(active-users .map (block [user]
          ($render `(li %(user .get `name)))))))))

# Render and save
(File/write "report.html" ($render report))
```

The full vision combines:
- **Gene data** for structured content
- **Methods** for discoverability
- **Functions** for transformations
- **Templates** with quote/unquote

## Current State and Future Direction

### What's Working

✅ **Parser** - Clean Gene syntax parsing
✅ **Compiler** - AST to bytecode compilation
✅ **VM** - Stack-based execution
✅ **Types** - Rich value system (100+ types)
✅ **Methods** - Method dispatch on string, array, map types
✅ **Functions** - First-class functions, closures
✅ **Macros** - Runtime macro system with `!` suffix and `$caller_eval`
✅ **Templates** - Quote/unquote system with `$render`
✅ **Arrays/Maps** - Core collection types with basic methods
✅ **Classes** - Basic OOP support (native classes)
✅ **Async** - Future-based async (synchronous for now)
✅ **Namespaces** - Class/namespace functions with `/` syntax

### In Progress / Planned

🔨 **Gene manipulation** - Rich API for Gene expressions (`.get`, `.type`, `.children` methods)
🔨 **Collection methods** - `.map`, `.filter`, `.reduce` on arrays
📋 **Pattern matching** - Destructuring and dispatch
📋 **Compile-time macros** - Expand macros during compilation (currently runtime)
📋 **User-defined classes** - Class definition syntax in Gene
📋 **Standard library** - Comprehensive FP + OOP stdlib
📋 **Module system** - Import/export, package management
📋 **Error handling** - Better exception system, stack traces
📋 **Performance** - Optimization passes, profiling
📋 **Tooling** - LSP, debugger, REPL improvements

### Design Consistency Checklist

When adding features, ensure:

- [ ] **Gene-centric** - Does it work naturally with Gene expressions?
- [ ] **Object-oriented** - Can it be accessed via methods?
- [ ] **Functional** - Does it support FP patterns (immutability, composition)?
- [ ] **Extensible** - Can users extend it with macros?
- [ ] **Performant** - Is the implementation efficient?
- [ ] **Consistent** - Does it follow existing patterns?
- [ ] **Documented** - Are there examples and use cases?

## Comparison with Other Languages

### vs Lisp/Clojure

**Similarities:**
- Homoiconicity (code as data)
- S-expression syntax
- Macros as core feature
- Functional programming support

**Differences:**
- **Gene vs Lists**: Gene expressions have explicit tags
- **Objects**: Everything is an object, not just data
- **Methods**: Ruby-style method syntax (`.method`)
- **Performance**: Bytecode VM, not interpreter
- **Syntax**: More flexible (maps use `{}`, arrays use `[]`)

### vs Ruby

**Similarities:**
- Everything is an object
- Method-based API
- Clean, readable syntax
- Focus on developer happiness

**Differences:**
- **Homoiconicity**: Code as data (Ruby doesn't have this)
- **Macros**: Compile-time metaprogramming (Ruby has runtime only)
- **Immutability**: FP-friendly (Ruby is mutation-heavy)
- **Performance**: Bytecode compilation (Ruby is interpreted/JIT)
- **Syntax**: S-expressions vs Ruby syntax

### vs JavaScript/Python

**Similarities:**
- Dynamic typing
- First-class functions
- Object-oriented features
- Practical, pragmatic approach

**Differences:**
- **Code as data**: Gene expressions are structured data
- **Macros**: Compile-time extension (JS/Python don't have)
- **Method uniformity**: Every value has methods
- **FP support**: Better immutability and composition
- **Performance**: Designed for optimization from start

### Unique Positioning

Gene occupies a sweet spot:

| Feature | Lisp | Ruby | JS/Python | Gene |
|---------|------|------|-----------|------|
| Code as data | ✅ | ❌ | ❌ | ✅ |
| Everything is object | ❌ | ✅ | Partial | ✅ |
| Macros | ✅ | ❌ | ❌ | ✅ |
| FP + OOP | FP-first | OOP-first | Mixed | Equal |
| Performance focus | Varies | Slow | Fast (JS JIT) | Fast (VM) |
| Readable syntax | ❌ | ✅ | ✅ | ✅ |

**Gene's niche**: Homoiconic, object-oriented, functional, and fast.

## Guiding Principles for Development

### 1. **Simplicity over Complexity**
- Prefer clear, simple implementations
- Avoid unnecessary abstraction layers
- Keep the core small and focused

### 2. **Consistency over Novelty**
- Follow established patterns
- Don't add features that break the mental model
- One obvious way to do common tasks

### 3. **Power without Obscurity**
- Advanced features should be discoverable
- Simple things should be simple
- Complex things should be possible

### 4. **Performance by Design**
- Think about performance from the start
- Profile and optimize real-world use cases
- Don't sacrifice correctness for speed

### 5. **Evolution over Revolution**
- Language features should build on each other
- Maintain backward compatibility when possible
- Add features incrementally, not in big leaps

### 6. **Pragmatism over Purity**
- FP is great, but mutation when needed
- Immutability by default, mutation when explicit
- Theory informs practice, practice validates theory

## Conclusion

Gene aims to be:

- **Expressive** - Code as data, macros, DSLs
- **Discoverable** - Methods, objects, consistent APIs
- **Powerful** - FP + OOP, higher-order functions, metaprogramming
- **Fast** - Bytecode compilation, efficient VM, optimization opportunities
- **Practical** - Real-world use cases, comprehensive stdlib, good tooling

The architecture (parse → compile → bytecode → VM) provides a solid foundation for achieving these goals. The current implementation demonstrates the viability of the design. The path forward is clear: build out the ecosystem while maintaining these core principles.

Gene is positioned to be what Lisp could be with modern sensibilities: **Code as data + Objects + FP + Performance**. This combination fills a gap in the language landscape and offers a compelling alternative for developers who want the power of metaprogramming with the ergonomics of Ruby and the performance of a compiled language.

---

*Gene Language Design Principles v1.0*
*Last updated: 2025-10-16*

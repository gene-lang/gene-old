# 5. Functions

## 5.1 Function Definition

```gene
# Named function
(fn add [a b] (a + b))

# No parameters
(fn hello [] (println "hi"))

# Anonymous (lambda)
(var double (fn [x] (x * 2)))
```

Functions are first-class values — they can be stored in variables, passed as arguments, and returned from other functions.

## 5.2 Parameter Patterns

### Positional Arguments
```gene
(fn f [a b c] ...)
(f 1 2 3)
```

### Default Values
```gene
(fn greet [name = "World"]
  (println #"Hello, #{name}!"))
(greet)          # => Hello, World!
(greet "Gene")   # => Hello, Gene!
```

### Rest (Variadic) Arguments
```gene
(fn sum_all [first rest...]
  (var total first)
  (for x in rest (total += x))
  total)
(sum_all 1 2 3 4)   # => 10
```

### Keyword Arguments
```gene
(fn config [^host ^port = 8080 ^^ssl ^!debug]
  ...)
```

| Syntax   | Meaning                                    |
|----------|--------------------------------------------|
| `^name`  | Keyword argument (required, no default)    |
| `^name = val` | Keyword argument with default         |
| `^^name` | Boolean flag, defaults to `true`           |
| `^!name` | Negated boolean flag, defaults to `nil`    |

Calling:
```gene
(config ^host "localhost" ^^ssl ^!debug ^port 9090)
```

## 5.3 Type Annotations

```gene
(fn add [a: Int b: Int] -> Int
  (a + b))
```

## 5.4 Closures

Functions capture their enclosing scope:

```gene
(fn make_counter [start]
  (var count start)
  (fn []
    (count += 1)
    count))

(var c (make_counter 0))
(c)   # => 1
(c)   # => 2
```

## 5.5 Function `.call`

Functions can be invoked via the `.call` method:

```gene
(fn adder [x y] (x + y))
(adder .call 3 4)   # => 7
```

## 5.6 Macro Functions (`!` suffix)

Functions ending with `!` receive their arguments **unevaluated** as AST nodes:

```gene
(fn debug! [expr]
  (println "DEBUG expr:" expr)
  ($caller_eval expr))

(var x 10)
(debug! (x + 5))   # Prints: DEBUG expr: (x + 5), returns 15
```

### `$caller_eval`

Evaluates an expression in the **caller's** scope, not the macro's scope:

```gene
(fn unless! [cond body]
  (if (! ($caller_eval cond))
    ($caller_eval body)))

(var x 5)
(unless! (x > 10) (println "x is small"))
```

### `$render`

Expands a quoted template with variable substitution:

```gene
(var tpl `(+ 1 %x))
(var x 5)
($render tpl)   # => (+ 1 5)
```

## 5.7 Function Metadata

Functions can carry metadata:

```gene
(fn my_add [a b]
  ^intent "Add two values"
  ^examples [
    [1 2] -> 3
    [2 3] -> 5
  ]
  (a + b))

(function_intent my_add)     # => "Add two values"
(function_examples my_add)   # => [[1,2] -> 3, [2,3] -> 5]
```

---

## Potential Improvements

- **Tail call optimization**: Recursive functions are not TCO'd. Deep recursion overflows the stack. This is the single most impactful missing optimization for a Lisp-like language.
- **Multi-body functions**: No support for multiple arities in a single definition (e.g., Clojure's `(fn ([x] ...) ([x y] ...))`).
- **Keyword argument ergonomics**: The `^`, `^^`, `^!` syntax is powerful but has a steep learning curve. Consider whether the three-way distinction is necessary or if `^name` + `^name = default` would suffice.
- **Named arguments at call site**: Keywords must match exactly. No positional-to-keyword bridging.
- **Partial application / currying**: No built-in `partial` or auto-currying. Must manually create wrapper closures.
- **Macro hygiene**: Macros using `$caller_eval` are not hygienic — they can capture or shadow caller variables unintentionally. A hygienic macro system would prevent accidental name collisions.
- **Compile-time macro expansion**: Macros expand at runtime, not compile time. This means macro overhead on every call. Compile-time expansion would eliminate this cost.
- **Variadic + keyword mixing**: The interaction between `rest...` args and keyword args in the same function signature can be confusing. Clear precedence rules should be documented.
- **Function composition operators**: No `compose`, `pipe`, or threading macros (like Clojure's `->`, `->>`) built in.

# Gene Language Vision

## One Line

**A homoiconic language where code is data, everything is an object, and the data model makes DSLs inevitable.**

## The Core Insight: The Gene Data Structure

Most Lisp languages are built on lists. Gene is built on something richer — the **Gene expression**: a tagged node with both named properties and positional children.

```gene
(type ^prop1 val1 ^prop2 val2 child1 child2)
```

This isn't just syntax sugar. It's a structural advantage:

- **HTML/DOM**: `(div ^class "main" (p "hello"))` — properties are attributes, children are content
- **Function calls**: `(fn add [a b] (a + b))` — name, parameter list, body
- **Data records**: `(Person ^name "Alice" ^age 30)` — named fields + positional data
- **DSLs**: `(route GET "/users" ^auth required (handler ...))` — keyword config + body
- **AI tools**: `(tool create_user ^description "..." ^params {...} (impl ...))` — self-describing

In Clojure you'd need `{:tag 'div :attrs {:class "main"} :children [...]}`. In Gene, it's just there. The data model *is* the DSL.

## Design Pillars

### 1. Homoiconicity That's Actually Useful

Lisp's code-as-data is powerful but lists are limiting. Gene expressions carry **type + props + children** — closer to how humans actually structure information. This makes Gene homoiconic without being list-obsessed.

```gene
# Code is data
(var ast `(fn add [a b] (a + b)))
ast/.type       # => fn
ast/.props      # => {}
ast/.children   # => [add [a b] (a + b)]

# Data looks like what it represents
(var page `(html
  (head (title "My App"))
  (body ^class "dark"
    (h1 "Welcome")
    (p "Hello world"))))
```

### 2. Everything Is an Object — Ruby's Gift

Every value responds to methods. No primitives vs objects split. This gives discoverability (what can I do with this?) and consistency (same calling syntax everywhere).

```gene
(42 .to_s)                    # => "42"
("hello" .to_upper)           # => "HELLO"
([1 2 3] .map (fn [x] (x * 2)))  # => [2 4 6]
({^a 1 ^b 2} .keys)           # => ["a" "b"]
```

Method chaining with `;` enables fluent pipelines:

```gene
(users
  .filter (fn [u] u/active);
  .map (fn [u] u/name);
  .sort;
  .reverse;
  .take 10)
```

### 3. Functional + Object-Oriented Harmony

Gene doesn't make you choose. Functions are first-class values for transformation. Objects organize behavior by type. They compose naturally.

```gene
# FP: pure functions, composition
(fn double [x] (x * 2))
(fn positive? [x] (x > 0))
(var result ([1 -2 3 -4] .filter positive?; .map double))

# OOP: organization, state, dispatch
(class UserService
  (ctor [db] (/db = db))
  (method active_users _
    (/db .query "SELECT * FROM users WHERE active = 1";
      .map (fn [row] (User .from_row row)))))
```

### 4. Macros as a First-Class Feature

The `!` suffix convention is elegant — any function ending with `!` receives unevaluated arguments. Combined with `$caller_eval`, this gives you powerful metaprogramming without a separate macro system.

```gene
(fn unless! [cond body]
  (if (! ($caller_eval cond))
    ($caller_eval body)))

(fn when! [cond body...]
  (if ($caller_eval cond)
    ($caller_eval body...)))
```

Templates with quote/unquote (`\`` and `%var`) enable code generation that reads like the output.

### 5. Performance Through Architecture

The execution pipeline is clean and optimizable:

```
Source → Parser → AST → Compiler → Bytecode → VM (computed-goto dispatch)
```

NaN-boxed 8-byte values, pooled stack frames, reference counting, and computed-goto dispatch already deliver 3.76M calls/sec. The roadmap targets 10M+ through string interning, array pooling, superinstructions, and inline caching — with JIT as a future option.

## Language Character

### What Gene Feels Like

```gene
# Hello world
(print "Hello, World!")

# A real program
(import genex/http)

(fn handler [req]
  (case req/path
    when "/"      (respond 200 "Welcome")
    when "/users" (respond 200 (users_json))
    else          (respond 404 "Not found")))

(var server (http/start_server 8080 handler))
(println "Server running on :8080")
(run_forever)
```

It reads like a scripting language but compiles to bytecode. S-expressions give structure; method calls give ergonomics; properties give expressiveness.

### Slash Syntax — The Unsung Hero

`/` is Gene's universal accessor. One syntax for everything:

```gene
arr/0           # Array index
map/key         # Map key
obj/property    # Object property
ns/member       # Namespace member
Enum/variant    # Enum access
$env/HOME       # Environment variable
path/to/module  # Module path
```

And `/.` for no-arg method calls: `obj/.method` → `(obj .method)`

### Graceful Complexity Curve

| Level | You write | Gene gives you |
|-------|-----------|---------------|
| **Day 1** | `(print "hi")`, `(var x 10)`, `(if (x > 5) "big" "small")` | A scripting language |
| **Week 1** | Functions, classes, collections, loops | An application language |
| **Month 1** | Macros, async, pattern matching, namespaces | A power-user language |
| **Expert** | DSLs, code generation, custom dispatch | A language-building language |

### Error Handling That Scales

```gene
# Simple: catch all
(try (risky) catch * (println "Error:" $ex))

# Typed: catch specific errors
(try (db_query)
  catch DbError (handle_db $ex)
  catch *       (handle_other $ex))

# Functional: Result type with ? operator
(fn get_email [id]
  (var user (db/find_user? id))     # Returns Err early on failure
  (Ok user/email))

# Contract: pre/postconditions
(fn withdraw [account amount]
  ^pre [(amount > 0) (/balance >= amount)]
  ^post [(/balance >= 0)]
  (/balance = (/balance - amount)))
```

## What Makes Gene Different

### vs Lisp/Clojure

Gene isn't just lists. The type + props + children model is strictly more expressive than `(head . rest)`. No need for property maps as workarounds. Built-in OOP means no object system bolt-on.

### vs Ruby

Gene has homoiconicity. Ruby's metaprogramming is powerful but runtime-only. Gene macros let you transform code as data. Plus: bytecode VM, async/await, and a type system on the roadmap.

### vs Python

Gene has a coherent design philosophy. No "there's one obvious way... except these 47 historical exceptions." The macro system is first-class. The data model is unified.

### vs Elixir

Both build on homoiconic cores. But Gene's data model (type + props + children) is richer than Elixir's tuples + keyword lists. Gene also targets OOP ergonomics, not just FP purity.

## The Road Ahead

### Near-Term (Making It Real)
1. **Green CI** — builds and tests pass on all platforms
2. **Performance** — 10M calls/sec target (string interning, array pooling, superinstructions)
3. **Module system** — proper import/export with encapsulation
4. **Error messages** — clear, actionable, with source locations
5. **REPL experience** — history, completion, inline docs

### Mid-Term (Making It Useful)
6. **Package manager** — `gene deps`, registry, version resolution
7. **Pattern matching** — nested patterns, guards, exhaustiveness checking
8. **Type system** — gradual typing with inference (already partially implemented)
9. **LSP** — already exists, needs polish
10. **Real-world examples** — web server, CLI tools, data pipelines

### Long-Term (Making It Special)
11. **Effect system** — track side effects in function signatures
12. **AI-native features** — tool definitions, code introspection, observability
13. **Native JIT** — hot-path compilation for competitive performance
14. **WASM target** — run Gene in the browser (runtime already exists)

## The Pitch

**Gene is what happens when you take Lisp's homoiconicity, Ruby's object model, and a data structure that actually matches how we think about information — and make them the same thing.**

The Gene expression — type + props + children — isn't just a syntax choice. It's a unified model for code, data, configuration, DSLs, and AI tool definitions. One structure, infinite expression.

The language meets you where you are: scripting on day one, application development within a week, and language extension whenever you're ready. The complexity curve is a ramp, not a cliff.

Performance comes from architecture, not heroics. NaN-boxed values, computed-goto dispatch, and a clean compiler pipeline give Gene a 10x+ head start over interpreted languages, with a clear path to JIT-level speeds.

Gene's niche is specific and underserved: **developers who want metaprogramming power without abandoning object-oriented ergonomics, backed by real performance.** No existing language occupies this space.

---

*"Code as data, everything as objects, performance by design."*

# Proposal: Value vs Entity

## The Problem

Gene currently has inconsistent mutation semantics — scalars copy by value, collections share by reference. This is confusing and a poor foundation for an AI-oriented language.

This document describes the target model. The current implementation now uses
`#[...]`, `#{...}`, and `#(...)` for **sealed** arrays, maps, and genes
(shallow immutable containers), while `(freeze v)` produces **frozen** values
with deep immutability over the Phase 1 MVP scope. Strings are already
immutable and pointer-shareable.

## Design Decision

The split is **not** scalar vs container. It's **value vs entity**:

- **Values** — defined by contents, no lifecycle, immutable
- **Entities** — have identity that persists through state changes, mutable

## Mutability Rules

### Immutable (Values)

| Type | Example | Notes |
|------|---------|-------|
| Integers | `1`, `42` | Always immutable |
| Booleans | `true`, `false` | Always immutable |
| Characters | `'a'` | Always immutable |
| Nil | `nil` | Always immutable |
| Symbols | `foo`, `^key` | Interned, used as map keys |
| Sealed containers | `#[1 2]`, `#{^a 1}`, `#(Foo 1)` | `#` prefix seals the outer container only |
| Frozen containers | `(freeze [1 2])`, `(freeze {^a 1})` | `freeze` recursively deep-freezes MVP scope |

### Mutable (Entities)

| Type | Example | Notes |
|------|---------|-------|
| Arrays | `[1 2 3]` | Mutable by default |
| Maps | `{^a 1}` | Mutable by default |
| Genes | `(Foo 1 2)` | Mutable by default |
| Strings | `"hello"` | Immutable, pointer-shareable |
| Class instances | `(new User "GL")` | Mutable entities |

### Bindings

- `var` — mutable binding (can reassign)
- `const` — proposed immutable binding (cannot reassign)

## Examples

### Scalars — immutable, rebinding only

```gene
(var a 1)
(var b a)
(a += 1)        # sugar for (a = (+ a 1))
# a: 2, b: 1 — no aliasing
```

### Containers — mutable, shared reference

```gene
(var c [1 2])
(var d c)
(c .add 3)
# c: [1 2 3], d: [1 2 3] — same object
```

### Strings — immutable values

```gene
(var s "hello")
(var t s)
(var u (s .append " world"))
# s: "hello", t: "hello", u: "hello world" — append returns a new value
```

### Sealed containers — shallow immutable values

```gene
(var c #[1 2])
(var d c)
(var c2 [c... 3])
# c: #[1 2], d: #[1 2], c2: [1 2 3]
```

### Frozen containers — deep immutable values

```gene
(var c (freeze [1 {^a 2}]))
# c and every reachable MVP child are frozen and pointer-shareable
```

### Entities — mutable, identity persists

```gene
(class User
  (ctor [name]
    (/name = name)
  )
  (method rename [name]
    (/name = name)
  )
)
(var u (new User "Guoliang"))
(var v u)
(u .rename "GL")
# v/name -> "GL" — same entity
```

## Map Keys

Map keys are **symbols** (always immutable, interned). Mutable strings are never used as keys, so no hash stability concerns.

## The Organism Analogy

An organism (entity) replaces its cells (values) constantly yet remains the same organism. Identity lives in the entity, not in the data. The language mirrors this: entities are mutable and identity-bearing, values are immutable and replaceable.

## Runtime Optimization

The semantic model doesn't limit performance:
- NaN-boxing for inline scalars
- Structural sharing for frozen containers
- Copy-on-write when refcount is 1
- Escape analysis to avoid unnecessary allocations

## Summary

- **Scalars** (int, bool, char, nil, symbol): always immutable
- **Structured container types** (array, map, gene): mutable by default
- **Strings**: immutable by default
- **`#` prefix**: sealed/shallow-immutable variant of array, map, and gene
- **`freeze`**: deep-frozen variant over the Phase 1 MVP scope
- **Class instances**: mutable entities with persistent identity
- **`var`**: mutable binding / **`const`**: immutable binding

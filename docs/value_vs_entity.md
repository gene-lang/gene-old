# Proposal: Value vs Entity

## The Problem

Gene currently has inconsistent mutation semantics — scalars copy by value, collections share by reference. This is confusing and a poor foundation for an AI-oriented language.

This document describes the target model. The current implementation now uses `#[...]` for immutable arrays, `#{...}` for immutable maps, and `#(...)` for immutable genes, but the rest of the proposal is still design work rather than a complete description of shipped behavior.

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
| Frozen containers | `#[1 2]`, `#{^a 1}`, `#(Foo 1)` | `#` prefix freezes |

### Mutable (Entities)

| Type | Example | Notes |
|------|---------|-------|
| Arrays | `[1 2 3]` | Mutable by default |
| Maps | `{^a 1}` | Mutable by default |
| Genes | `(Foo 1 2)` | Mutable by default |
| Strings | `"hello"` | Mutable (array of chars) |
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

### Strings — mutable like arrays

```gene
(var s "hello")
(var t s)
(s .append " world")
# s: "hello world", t: "hello world" — same object
```

### Frozen containers — immutable values

```gene
(var c #[1 2])
(var d c)
(var c2 [c... 3])
# c: #[1 2], d: #[1 2], c2: [1 2 3]
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
- **Structured types** (array, map, gene, string): mutable by default
- **`#` prefix**: frozen/immutable variant of any structured type
- **Class instances**: mutable entities with persistent identity
- **`var`**: mutable binding / **`const`**: immutable binding

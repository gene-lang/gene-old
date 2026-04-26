# Enum and ADT Unification

Gene is converging on one public sum-type model: `enum`. Simple enums and payload-bearing algebraic data types use the same declaration form, metadata model, diagnostics, and runtime identity rules.

The reader for this document is a Gene maintainer working on enum ADT implementation slices. After reading, they should know exactly what the declaration contract already provides and which behaviors are deliberately left to downstream work.

## Public model

The canonical public declaration form is:

```gene
(enum Name:T:E
  (Variant field: T)
  (Other error: E)
  UnitVariant)
```

The declaration head contains the enum name plus optional colon-prefixed generic parameters. The canonical enum base name is the portion before the first generic parameter. For example, `(enum Result:T:E ...)` declares the enum `Result`; type usage supplies concrete parameters as `(Result Int String)`.

Legacy Gene-expression ADT declarations such as `(type (Result T E) ...)` are not a supported alternate public model. New language behavior, documentation, and tests should use `enum` for sum types.

## Declaration syntax

### Unit variants

```gene
(enum Color red green blue)

(var c Color/red)
```

A unit variant has no payload fields. It is represented by the enum member itself and belongs to its parent enum.

The older `^values` spelling is accepted as simple-enum declaration sugar and canonicalizes to the same unit-variant metadata:

```gene
(enum Status ^values [ready done])
```

### Payload variants

```gene
(enum Shape
  (Circle radius)
  (Rect width height)
  Point)
```

A payload variant is written as a list whose first element is the variant name and whose remaining elements are field declarations. Field order is significant and is preserved for constructors, display, destructuring, and downstream type enforcement.

### Field type annotations

```gene
(enum Result:T:E
  (Ok value: T)
  (Err error: E)
  Empty)
```

A field may include an optional type annotation with Gene's `field: Type` syntax. S01 records the resolved field type descriptor when one is available, alongside the ordered field name. Untyped fields remain valid and accept any value until a downstream constructor/type-enforcement slice applies stricter checks.

## S01 declaration contract

S01 delivers the canonical declaration and metadata baseline:

- `enum` is the single public ADT declaration form.
- Generic enum heads use colon parameters, such as `Result:T:E`.
- The stored enum name is the base name, such as `Result`, not `Result:T:E`.
- Each variant records whether it is a unit variant or a payload variant.
- Payload variants record ordered field names.
- Payload fields may record optional type descriptors for later enforcement.
- Enum declaration diagnostics identify malformed declarations, duplicate variants, duplicate fields, invalid generic parameters, and invalid field annotations.
- Type annotations can refer to generic enum applications such as `(Result Int String)` and accept values whose parent enum is `Result`.

S01 intentionally does not make every enum ADT behavior final. It provides the metadata and diagnostics that later slices consume.

## Downstream ownership

The following behaviors are deliberately staged after S01:

| Area | Downstream responsibility |
|------|---------------------------|
| Constructors and field enforcement | Enforce constructor arity, keyword behavior, and annotated field types consistently for payload variants. |
| Result and Option migration | Make `Result` and `Option` ordinary enum declarations end-to-end, including compatibility handling for existing shortcuts. |
| Pattern matching | Match and destructure enum variants through the unified enum metadata rather than hardcoded Gene-expression ADT names. |
| Import identity and persistence | Preserve nominal enum identity across modules, GIR/cache, and serialization boundaries. |
| Final examples | Publish polished examples only after constructor, matching, and identity semantics are all closed. |

## Runtime representation direction

The unified model has three conceptual values:

- **Enum definition**: the named sum type, such as `Result` or `Shape`.
- **Enum member**: one declared variant, such as `Result/Ok` or `Shape/Point`.
- **Enum value**: an instantiated payload variant, such as `(Result/Ok 42)`.

Unit variants use the enum member as the value. Payload variants use an enum value that points back to the member and stores field payloads in declaration order.

## Construction surface

Construction is the responsibility of the constructor-enforcement slice. The intended public shape is:

```gene
(var ok (Result/Ok 42))
(var err (Result/Err "boom"))
(var empty Result/Empty)
```

S01 preserves the metadata needed to implement this consistently. Documentation should avoid claiming final constructor enforcement until the downstream slice validates arity, keyword arguments, field annotations, and diagnostics.

## Pattern-matching surface

Enum pattern matching is downstream. The intended direction is to match on enum variants and bind fields by declaration order:

```gene
(case result
  (when (Ok value) value)
  (when (Err error) error)
  (when Empty nil))
```

This must be implemented through enum metadata, not by recognizing hardcoded `Ok`, `Err`, `Some`, or `None` Gene-expression forms. Exhaustiveness checking is also downstream and should start as diagnostic-grade feedback before becoming stricter.

## Compatibility stance

Gene may temporarily contain compatibility shortcuts while `Result` and `Option` migrate, but those shortcuts are not a second ADT model. New code and docs should prefer enum-qualified forms such as `Result/Ok` and `Option/Some` when describing the unified model.

## Validation expectations

A complete implementation slice should keep three inspection surfaces aligned:

1. Declaration tests that exercise generic enum heads, unit variants, payload fields, and annotations.
2. Negative tests that assert targeted diagnostics for malformed declarations.
3. OpenSpec validation that captures the public contract with scenario-based requirements.

If those surfaces disagree, the implementation is not ready to become the next baseline for downstream enum ADT work.

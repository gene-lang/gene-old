## Context

Gene's current collection surface does not provide a first-class set optimized for membership checks and deduplication across arbitrary values. Arrays require linear scans, and emulating sets with `HashMap` adds noise and extra value storage that callers do not care about.

`HashSet` fills that gap as a native runtime collection focused on membership, iteration, and standard set algebra. The design should stay aligned with the new `HashMap` semantics where possible so users get one consistent notion of "hashable value" across keyed collections.

## Goals / Non-Goals

- Goals:
  - Add a Nim-backed `HashSet` runtime type for general-purpose membership and deduplication over arbitrary `Value`s.
  - Expose `HashSet` through `(new HashSet ...)` without requiring a literal syntax in the first implementation.
  - Reuse the same hash-plus-`==` identity contract as `HashMap`.
  - Support built-in scalar values, structural composite values, and user-defined objects that expose `.hash`.
  - Ship iteration and core set algebra helpers in the first implementation.
- Non-Goals:
  - Introduce a set literal syntax in this change.
  - Change `{}` / `Map` or `{{}}` / `HashMap` semantics.
  - Define a serialization format for `HashSet` in this change.

## Decisions

- Decision: make `HashSet` constructor-only for now via `(new HashSet item1 item2 ...)`.
  - Alternatives considered: introducing a literal now. Rejected because the explored literal candidates either conflict with existing syntax or need a separate parser design pass.

- Decision: define `HashSet` member identity as computed hash plus runtime `==`.
  - Alternatives considered: object identity or hash-only membership. Rejected because the collection should align with `HashMap` and must not alias unequal members that share a hash.

- Decision: reuse `HashMap` hashing behavior for `HashSet`.
  - Alternatives considered: a separate set-only hashing path. Rejected because the semantics should stay consistent across arbitrary-key collections and duplicated hashing logic would drift.

- Decision: make `.has` the canonical membership method and keep `.contains` as an alias.
  - Alternatives considered: documenting both names as equally primary. Rejected because one canonical name is simpler for docs and tests.

- Decision: have `.add` mutate and return `self`.
  - Alternatives considered: returning the inserted value or a boolean. Rejected because chained mutating collection APIs are already the more useful shape here.

- Decision: have `.delete` return the removed member when present, or `nil` when absent.
  - Alternatives considered: returning booleans only. Rejected because returning the removed value is both informative and matches the design note.

- Decision: include `.to_array` plus `for` iteration support in the first implementation.
  - Alternatives considered: shipping only membership operations first. Rejected because a set without iteration is incomplete for real use.

- Decision: include `.union`, `.intersect`, `.diff`, and `.subset?` in the first implementation.
  - Alternatives considered: deferring set algebra to a follow-up. Rejected because these operations are core to why users reach for a set in the first place.

- Decision: render `HashSet` values as `(HashSet item1 item2 ...)`.
  - Alternatives considered: object-style printing or a speculative literal form. Rejected because the constructor form is the public surface in this change.

## Risks / Trade-offs

- Mutable composite members can become unreachable if their hash-relevant contents change after insertion.
- If `HashMap` hashing semantics change, `HashSet` must stay in lockstep or membership behavior will diverge.
- Constructor-only surface is deliberately conservative and may feel less lightweight than a literal until a later parser change lands.

## Migration Plan

1. Approve the `HashSet` surface and semantics.
2. Land the runtime representation, hashing reuse, stdlib registration, and iteration support.
3. Add integration coverage for membership, algebra, iteration, printing, and unhashable-member errors.
4. Revisit literal syntax later if real user demand justifies a dedicated parser change.

## Follow-Up

- Evaluate a future literal syntax such as `|a b c|` only if constructor-only `HashSet` proves too verbose in practice.

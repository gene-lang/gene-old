## 1. Descriptor Core
- [x] 1.1 Add `TypeDesc`/`TypeId` definitions to core type defs.
- [x] 1.2 Extend scope/matcher/compilation-unit metadata to carry descriptor IDs/tables.
- [ ] 1.3 Add descriptor interning helpers for compiler/runtime use.

## 2. GIR Integration
- [x] 2.1 Extend GIR schema/version with descriptor table serialization.
- [x] 2.2 Roundtrip scope tracker descriptor IDs through snapshot serialization.
- [x] 2.3 Add GIR tests covering descriptor table persistence.

## 3. Compiler + Runtime Wiring
- [ ] 3.1 Emit descriptor IDs alongside existing string metadata during compilation.
- [ ] 3.2 Teach runtime validation to prefer descriptor/runtime objects.
- [ ] 3.3 Preserve string fallback paths during migration.

## 4. Validation
- [ ] 4.1 Add mixed typed/untyped boundary tests using descriptor paths.
- [ ] 4.2 Add import/module boundary tests validating descriptor continuity.
- [ ] 4.3 Benchmark validation overhead vs current string parsing path.

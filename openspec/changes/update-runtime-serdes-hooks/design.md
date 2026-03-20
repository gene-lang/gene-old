## Context
`gene/serdes` already provides the canonical Gene-native text serialization
format and typed references for named runtime objects. The current serializer
keeps a fast native path for primitives and structural values, but it also
contains anonymous-instance snapshot behavior that should not remain part of
the durable runtime serialization contract. Meanwhile, it rejects `VkCustom`
values outright.

At the same time, `gene deser|deserialize` is now a user-facing CLI entry point
for the same runtime format. Its help text and docs need to stay aligned with
the actual serialized forms and hook semantics.

## Goals / Non-Goals
- Goals:
  - Keep `gene/serdes` as the single canonical wire format owner.
  - Allow `VkCustom` values to round-trip through explicit class hooks.
  - Preserve stable, fast native serialization for non-instance values and
    named refs.
  - Keep `gene deser|deserialize` behavior and documentation aligned with the
    runtime implementation.
- Non-Goals:
  - Replace the canonical `(gene/serialization ...)` text format.
  - Make all built-in values serialize through ordinary method dispatch.
  - Add a general object-inspection or reflection API beyond the serdes hooks.
  - Change the typed-reference model for classes, functions, namespaces, enums,
    or named instances.

## Decisions

### Decision: Non-instance values continue to use the native serializer path
For values other than `VkCustom`, `gene/serdes` SHALL continue to use the
existing native serializer implementation directly, subject to the named-vs-
anonymous instance rule below.

Rationale:
- This keeps hot-path behavior unchanged for primitives, arrays, maps, genes,
  and typed refs.
- It avoids recursive method dispatch inside container serialization.
- It preserves the current textual format and stability guarantees.

### Decision: Hook payloads are Gene values, not pre-rendered strings
Serialize hooks SHALL return ordinary Gene values. `gene/serdes` SHALL then
serialize those payload values using the canonical runtime serializer.

Deserialize hooks SHALL receive the deserialized payload value rather than raw
text.

Rationale:
- This preserves one canonical text format.
- It keeps hook implementations simple and composable.
- It lets payloads contain nested values that already participate in runtime
  serdes.

### Decision: Named instances preserve reference semantics
Instances with canonical module/path origins SHALL continue to serialize as
`InstanceRef` and SHALL bypass custom payload hooks.

Rationale:
- This preserves identity-oriented behavior for exported/shared instances.
- It avoids changing the meaning of existing reference payloads.

### Decision: Anonymous instances and objects are not runtime-serializable
Anonymous user-defined instances or object-like values without canonical
reference identity SHALL be rejected by `gene/serdes/serialize` rather than
serialized as inline snapshots.

Legacy inline anonymous-instance envelopes SHALL be removed from the supported
`gene/serdes/deserialize` compatibility surface.

Rationale:
- This keeps the durable runtime format focused on stable references and
  explicit custom serialization contracts.
- It avoids carrying forward a snapshot representation that the project no
  longer wants to support.

### Decision: `VkCustom` values use an explicit hook-based envelope
`VkCustom` values SHALL round-trip through the same `Instance` envelope shape
used by inline instance payloads, containing:
1. A class reference identifying the custom runtime type
2. A hook-produced payload value

Serialization SHALL require a class `serialize` or `.serialize` hook.
Deserialization SHALL require a class `deserialize` or `.deserialize` hook.
If either required hook is absent, the operation SHALL fail.
There is no generic fallback reconstruction path for arbitrary `VkCustom`
payloads.

Rationale:
- `VkCustom` values have runtime-specific backing data that the serializer
  cannot reconstruct generically.
- Reusing the `Instance` envelope keeps the wire format simpler and avoids
  introducing another top-level runtime serdes form.

### Decision: `gene deser|deserialize` remains a thin runtime wrapper
The CLI command SHALL continue to call the runtime deserializer and SHALL not
reimplement special handling for hook-based payloads. Its updates in this change
are to help text, examples, documentation, and test coverage so the command’s
surface stays aligned with runtime behavior.

Rationale:
- One deserialization implementation is easier to keep correct.
- The CLI should expose the canonical runtime behavior, not fork it.

## Risks / Trade-offs
- Removing anonymous-instance snapshots is a breaking change for any existing
  payloads that relied on the old inline instance form.
  - Mitigation: document the rejection clearly in runtime tests and in
    `gene deser|deserialize` help/docs.
- `VkCustom` serialization adds a new wire-form variant.
  - Mitigation: keep the envelope explicit and class-ref based so it stays
    inspectable and deterministic.
- Hook naming may overlap with future public convenience methods.
  - Mitigation: this change only defines serdes hooks for `VkCustom`;
    non-instance values remain on the native path and anonymous instances are
    rejected.

## Migration Plan
1. Preserve the current typed-reference forms for named runtime objects.
2. Remove anonymous inline instance serialization/deserialization support.
3. Add `VkCustom` reconstruction through the `Instance` envelope plus required
   class hooks.
4. Update CLI help/docs/examples and add regression tests for rejection and
   for the current typed-reference/custom forms.

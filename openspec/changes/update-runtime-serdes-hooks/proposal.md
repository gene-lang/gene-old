## Why
Runtime serialization in Gene currently mixes durable reference-style behavior
for named runtime objects with ad hoc snapshot behavior for anonymous instance
values. That snapshot form is not a good compatibility surface and should not
remain part of the canonical runtime serdes contract. At the same time,
`VkCustom` values participate in class/method dispatch but cannot round-trip
through `gene/serdes` at all unless they are reduced to some other value
outside the serializer.

This leaves custom runtime values without a canonical persistence contract and
leaves `gene deser|deserialize` documentation at risk of advertising instance
payload forms that should no longer be supported.

## What Changes
- Preserve the current native fast path for non-instance values and named
  references, including named/exported instances that already serialize as
  `InstanceRef`.
- Reject anonymous instance/object snapshot serialization in `gene/serdes` and
  remove legacy support for deserializing that inline instance form.
- Add a canonical serialized form for `VkCustom` values using the `Instance`
  envelope shape with class ref plus hook-produced payload, reconstructed
  through class
  `deserialize`/`.deserialize`.
- Update the `gene deser|deserialize` command help, examples, docs, and tests
  so they describe and exercise the updated runtime serdes behavior.

## Impact
- Affected specs: `runtime-serdes`, `deserialize-command`
- Affected code: `src/gene/serdes.nim`, `src/commands/deser.nim`,
  `docs/deserialize_command.md`, serdes tests in `tests/` and
  `testsuite/stdlib/`

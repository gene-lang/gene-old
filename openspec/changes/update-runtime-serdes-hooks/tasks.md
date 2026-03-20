## 1. Implementation
- [x] 1.1 Define the canonical hook-based serialization contract for `VkCustom`
      values, including use of the `Instance` envelope shape and the payload
      rules.
- [x] 1.2 Update `src/gene/serdes.nim` so non-instance values continue to use
      the native serializer path without method-hook dispatch.
- [x] 1.3 Preserve `InstanceRef` behavior for named/exported instances and
      reject anonymous instance/object serialization in the runtime serdes path.
- [x] 1.4 Add `VkCustom` serialization and deserialization support through
      class `serialize`/`.serialize` and `deserialize`/`.deserialize` hooks,
      failing when either required hook is missing.
- [x] 1.5 Remove support for deserializing legacy inline anonymous-instance
      payloads while keeping the existing typed reference forms intact.
- [x] 1.6 Update `gene deser|deserialize` help text, documentation, and
      examples to reflect the updated runtime serdes contract and current
      serialized syntax.

## 2. Validation
- [x] 2.1 Add or update Nim tests for anonymous-instance rejection,
      custom-value hook round-trips, named-instance stability, and rejection
      behavior when custom hooks are missing.
- [x] 2.2 Add or update Gene tests under `testsuite/stdlib/` for the public
      `gene/serdes` behavior and dedicated CLI tests for `gene deser|deserialize`.
- [x] 2.3 Run focused serdes and CLI tests plus `openspec validate
      update-runtime-serdes-hooks --strict`.

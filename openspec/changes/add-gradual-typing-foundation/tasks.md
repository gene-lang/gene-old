## 1. S01 Contract and Documentation Surface

- [x] 1.1 Add the `gradual-typing` OpenSpec delta with ADDED requirements for the foundation contract.
- [x] 1.2 Write `docs/gradual-typing.md` as the canonical in-repo foundation design for future implementers.
- [x] 1.3 Link current type-system docs and feature status to the canonical foundation design while preserving their current-state framing.
- [x] 1.4 Validate the OpenSpec change and link discovery commands.

## 2. S02 Source Descriptor Metadata Verifier

- [x] 2.1 Add a source-compile descriptor metadata verifier that walks all source-owned `TypeId` metadata after checker/compiler descriptor merge.
- [x] 2.2 Reject invalid metadata with `GENE_TYPE_METADATA_INVALID` diagnostics that include phase, owner/path, invalid `TypeId`, descriptor-table length, and source path.
- [x] 2.3 Add positive and negative tests for matcher metadata, scope type expectations, type aliases, class/interface property metadata, runtime type values, and nested descriptor references.
- [x] 2.4 Prove valid source compilation still works for existing typed and untyped programs.

## 3. S03 GIR Verifier and Source/GIR Parity

- [x] 3.1 Run the descriptor metadata verifier when GIR files are loaded before import, execution, or runtime validation consumes loaded metadata.
- [x] 3.2 Include GIR path and source path, when available, in invalid GIR metadata diagnostics.
- [x] 3.3 Add source/GIR parity checks proving source-compiled and cached-GIR execution agree on descriptor metadata and runtime type behavior.
- [x] 3.4 Add negative tests for corrupted or inconsistent GIR descriptor tables without relying on ignored local artifacts.

## 4. S04 Opt-In Strict Nil Scaffold

- [x] 4.1 Add an opt-in `--strict-nil` mode that rejects `nil` at typed boundaries unless the expected type is `Any`, `Nil`, `Option[T]`, or a union containing `Nil`.
- [x] 4.2 Preserve default gradual nil compatibility for existing programs when strict nil is not enabled.
- [x] 4.3 Apply strict nil behavior consistently to arguments, returns, locals/assignments, typed properties, and GIR-loaded metadata paths.
- [x] 4.4 Add tests for default nil compatibility, strict nil rejection, explicit `Nil` acceptance, `Option[T]` acceptance, and union-with-`Nil` acceptance.

## 5. S05 Final Foundation Gate

- [x] 5.1 Run the source verifier, GIR verifier, source/GIR parity, default nil compatibility, strict nil, and documentation discovery checks as one final foundation gate.
- [x] 5.2 Confirm diagnostics remain actionable and contain all required metadata fields.
- [x] 5.3 Confirm deferred tracks remain documented as deferred rather than claimed as implemented.
- [x] 5.4 Update final milestone evidence without editing historical proposal archaeology.

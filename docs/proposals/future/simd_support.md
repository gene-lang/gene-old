# SIMD Support Proposal

This document sketches how SIMD (Single Instruction, Multiple Data) could be added to Gene, with a focus on exposing vectorised computation through native functions written in Nim.

## Goals
- Accelerate numeric workloads (math, signal processing, image ops) without breaking Gene’s existing semantics.
- Keep Gene bytecode and runtime stable for non‑SIMD hosts by providing scalar fallbacks.
- Let native functions leverage platform SIMD (SSE, AVX, NEON, etc.) while hiding CPU quirks from Gene developers.

## Scope & Assumptions
- SIMD lives in native Nim code; the Gene language surface stays minimal (no new syntax required to start).
- Gene values remain NaN-boxed; SIMD data is either transient in native code or encapsulated in new `ValueKind`s if we later expose vectors directly.
- SIMD kernels must behave deterministically when instructions are unavailable (feature detection + fallback).

## Architecture Overview

1. **Native Function Boundary**  
   - Extend the native function API to accept contiguous buffers or higher-order helpers (`withArrayData[T](value, proc)`), so native code can load data into vector registers efficiently.
   - Add optional metadata (e.g. `FnFlagRequiresSimd`) to mark functions that need specific instruction sets. The VM uses this to dispatch to scalar fallbacks or raise informative errors.

2. **Feature Detection**  
   - At VM init, detect CPU capabilities (e.g. via Nim’s `cpuinfo` or custom CPUID shims) and stash them in `App` or a dedicated capability table.
   - Provide helpers like `simdSupported(Sse2)` for runtime checks in native functions.  

3. **Kernel Implementation**  
   - Use Nim intrinsics or the `std/simd` module to write portable kernels. Example (sketch):
     ```nim
     when defined(v128):
       import std/simd
     
     proc simdAddFloat32(dst, a, b: ptr UncheckedArray[float32]; len: int) =
       var i = 0
       when defined(v128):
         let vLen = len - (len mod 4)
         while i < vLen:
           let va = load(vec128[float32], a + i)
           let vb = load(vec128[float32], b + i)
           store(dst + i, va + vb)
           inc i, 4
       while i < len:
         dst[i] = a[i] + b[i]
         inc i
     ```
   - Always include scalar tails or full scalar fallback to preserve correctness.

4. **Invocation Pattern**  
   - Native functions should:
     1. Validate argument shapes (`array?`, `float32?`, aligned length).
     2. Select SIMD or scalar path based on capability helper.
     3. Return Gene arrays or scalars as usual.
   - Consider helper templates/macros to reduce boilerplate (shape checking, fallback dispatch).

## Integrating with the VM
- **Value Handling**: reuse existing array/map storage. Copy data into temporary buffers when necessary; avoid mutating shared arrays unless write-safe.
- **Garbage Safety**: Ensure SIMD kernels operate on raw pointers only inside `GC_suspend`/`GC_resume`-safe regions if required (depends on ARC/ORC settings).
- **Error Reporting**: Throw descriptive exceptions (`Exception`) when SIMD prerequisites fail (e.g. unsupported data type).

## Future Extensions
- **Dedicated Vector ValueKinds**: Add types like `VkFloat4` for inline storage and new bytecode ops (e.g. `IkVecAdd`). Requires compiler + VM changes but unlocks broader optimisation.
- **Autovec Hints**: Teach the compiler to emit SIMD-friendly loops for pure Gene code, using pattern recognition or explicit annotations.
- **SIMD-aware Collections**: Introduce aligned `Tensor` or `Matrix` types with guaranteed layout.

## Testing Strategy
- Unit tests for capability detection (`simdSupported`).
- Native function tests that exercise both SIMD and scalar fallbacks.
- Cross-platform CI runs (x86_64 SSE2 baseline, AVX2, ARM NEON).

## Open Questions
- What minimal instruction set should be considered “baseline” (SSE2?) to avoid constant fallbacks?
- Should we allow Gene code to query SIMD availability directly?
- How do we package multiple kernel variants (fat binaries vs. runtime selection)?

## Next Steps
1. Prototype CPU capability detection and expose it to native functions.
2. Implement one SIMD-accelerated native routine (e.g. `gene/math.vec-add`) with fallbacks.
3. Document the native API changes for contributors.

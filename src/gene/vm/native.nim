## Native code execution: try_native_call, native_trampoline.
## Included from vm.nim — shares its scope.

# Convert args to int64 (uniform ABI: floats are bitcast to int64)
proc arg_to_i64(v: Value): int64 {.inline.} =
  if v.kind == VkFloat:
    cast[int64](v.to_float())
  else:
    v.to_int()

type
  NativeFn0 = proc(ctx: ptr NativeContext): int64 {.cdecl.}
  NativeFn1 = proc(ctx: ptr NativeContext, a0: int64): int64 {.cdecl.}
  NativeFn2 = proc(ctx: ptr NativeContext, a0, a1: int64): int64 {.cdecl.}
  NativeFn3 = proc(ctx: ptr NativeContext, a0, a1, a2: int64): int64 {.cdecl.}
  NativeFn4 = proc(ctx: ptr NativeContext, a0, a1, a2, a3: int64): int64 {.cdecl.}
  NativeFn5 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4: int64): int64 {.cdecl.}
  NativeFn6 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4, a5: int64): int64 {.cdecl.}
  NativeFn7 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4, a5, a6: int64): int64 {.cdecl.}

proc native_trampoline*(
    ctx: ptr NativeContext,
    descriptor_idx: int64,
    args: ptr UncheckedArray[int64],
    argc: int64
): int64 {.cdecl, exportc.} =
  let idx = int(descriptor_idx)
  assert idx >= 0, "negative descriptor index"
  assert idx < int(ctx.descriptor_count), "descriptor index out of range"
  let desc = ctx.descriptors[idx]
  let n = int(argc)
  assert n == desc.argTypes.len, "argc/descriptor mismatch"

  const MAX_NATIVE_ARGS = 8
  assert n <= MAX_NATIVE_ARGS
  var scratch: array[MAX_NATIVE_ARGS, Value]
  for i in 0..<n:
    case desc.argTypes[i]
    of CatInt64:
      scratch[i] = args[i].to_value()
    of CatFloat64:
      scratch[i] = cast[float64](args[i]).to_value()

  var boxed: seq[Value]
  if n == 0:
    boxed = @[]
  else:
    boxed = @scratch[0..<n]

  let result_val = case desc.callable.kind
    of VkFunction:
      ctx.vm.exec_function(desc.callable, boxed)
    of VkNativeFn:
      call_native_fn(desc.callable.ref.native_fn, ctx.vm, boxed)
    of VkBoundMethod:
      let bm = desc.callable.ref.bound_method
      ctx.vm.exec_method(bm.method.callable, bm.self, boxed)
    else:
      ctx.vm.exec_callable(desc.callable, boxed)

  case desc.returnType
  of CrtInt64:
    return result_val.to_int()
  of CrtFloat64:
    return cast[int64](result_val.to_float())
  of CrtValue:
    return cast[int64](result_val)

proc try_native_call(self: ptr VirtualMachine, f: Function, args: seq[Value], out_value: var Value): bool =
  if not self.native_code:
    return false
  if f.is_generator or f.async or f.is_macro_like:
    return false
  if not native_args_supported(f, args):
    return false
  if not f.native_ready:
    if f.native_failed:
      return false
    if f.body_compiled == nil:
      f.compile()
    let compiled = compile_to_native(f)
    if not compiled.ok:
      f.native_failed = true
      return false
    if f.native_descriptors.len > 0:
      release_descriptors(f.native_descriptors)
    f.native_entry = compiled.entry
    f.native_ready = true
    # Determine if return value is float (from HIR inference or explicit annotation)
    f.native_return_float = compiled.returnFloat
    f.native_descriptors = compiled.descriptors

  var ctx = NativeContext(
    vm: self,
    trampoline: cast[pointer](native_trampoline),
    descriptors: nil,
    descriptor_count: f.native_descriptors.len.int32
  )
  if f.native_descriptors.len > 0:
    ctx.descriptors = cast[ptr UncheckedArray[CallDescriptor]](f.native_descriptors[0].addr)

  var result_i64: int64
  case args.len
  of 0:
    result_i64 = cast[NativeFn0](f.native_entry)(addr ctx)
  of 1:
    result_i64 = cast[NativeFn1](f.native_entry)(addr ctx, args[0].arg_to_i64())
  of 2:
    result_i64 = cast[NativeFn2](f.native_entry)(addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64())
  of 3:
    result_i64 = cast[NativeFn3](f.native_entry)(addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64())
  of 4:
    result_i64 = cast[NativeFn4](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64()
    )
  of 5:
    result_i64 = cast[NativeFn5](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(), args[4].arg_to_i64()
    )
  of 6:
    result_i64 = cast[NativeFn6](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(), args[4].arg_to_i64(), args[5].arg_to_i64()
    )
  of 7:
    result_i64 = cast[NativeFn7](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(),
      args[4].arg_to_i64(), args[5].arg_to_i64(), args[6].arg_to_i64()
    )
  else:
    return false
  # Unbox result: if return type is float, bitcast int64 back to float64
  if f.native_return_float:
    out_value = cast[float64](result_i64).to_value()
  else:
    out_value = result_i64.to_value()
  true

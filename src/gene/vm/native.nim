## Native code execution: try_native_call, native_trampoline.
## Included from vm.nim — shares its scope.

proc native_arg_type_id(f: Function, idx: int): TypeId {.inline.} =
  if f != nil and f.matcher != nil and idx >= 0 and idx < f.matcher.children.len:
    result = f.matcher.children[idx].type_id
  else:
    result = NO_TYPE_ID

# Convert args to int64 (uniform ABI: floats bitcast; strings pass payload pointer;
# arrays/maps/other pass raw NaN-boxed bits).
proc arg_to_i64(v: Value, tid: TypeId): int64 {.inline.} =
  case tid
  of BUILTIN_TYPE_FLOAT_ID:
    result = cast[int64](v.to_float())
  of BUILTIN_TYPE_STRING_ID:
    result = cast[int64](cast[uint64](v) and PAYLOAD_MASK)
  of BUILTIN_TYPE_INT_ID:
    result = v.to_int()
  of BUILTIN_TYPE_ARRAY_ID, BUILTIN_TYPE_MAP_ID:
    # Pass raw NaN-boxed Value bits for compound types
    result = cast[int64](v.raw)
  else:
    # For unknown types or dynamic dispatch, pass raw bits
    if v.kind == VkFloat:
      result = cast[int64](v.to_float())
    elif v.kind == VkInt:
      result = v.to_int()
    else:
      result = cast[int64](v.raw)

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
    of CatValue:
      scratch[i] = Value(raw: cast[uint64](args[i]))

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
    retain(result_val)
    return cast[int64](result_val.raw)

proc prepare_native_ctx(self: ptr VirtualMachine, f: Function, out_ctx: var NativeContext): bool {.inline.} =
  ## Shared preamble: ensure native code is compiled and set up NativeContext.
  ## Returns false if native execution is not available for this function.
  if f.is_generator or f.async or f.is_macro_like:
    return false
  acquire(native_publication_lock)
  defer: release(native_publication_lock)
  if not f.native_ready:
    if f.native_failed:
      return false
    var compiled_body = load_published_body(f)
    if compiled_body == nil:
      f.compile()
      compiled_body = load_published_body(f)
    if compiled_body == nil:
      f.native_failed = true
      return false
    let compiled = compile_to_native(f)
    if not compiled.ok:
      f.native_failed = true
      return false
    if f.native_descriptors.len > 0:
      release_descriptors(f.native_descriptors)
    f.native_entry = compiled.entry
    f.native_return_float = compiled.returnFloat
    f.native_return_string = compiled.returnString
    f.native_return_value = compiled.returnValue
    f.native_descriptors = compiled.descriptors
    f.native_ready = true

  out_ctx = NativeContext(
    vm: self,
    trampoline: cast[pointer](native_trampoline),
    entry: f.native_entry,
    descriptors: nil,
    descriptor_count: f.native_descriptors.len.int32,
    return_float: f.native_return_float,
    return_string: f.native_return_string,
    return_value: f.native_return_value
  )
  if f.native_descriptors.len > 0:
    out_ctx.descriptors = cast[ptr UncheckedArray[CallDescriptor]](f.native_descriptors[0].addr)
  true

proc unbox_native_result(ctx: NativeContext, result_i64: int64, out_value: var Value) {.inline.} =
  if ctx.return_float:
    out_value = cast[float64](result_i64).to_value()
  elif ctx.return_value:
    out_value = Value(raw: cast[uint64](result_i64))
  elif ctx.return_string:
    let payload = cast[uint64](result_i64) and PAYLOAD_MASK
    out_value = cast[Value](STRING_TAG or payload)
  else:
    out_value = result_i64.to_value()

proc try_native_call0(self: ptr VirtualMachine, f: Function, out_value: var Value): bool =
  if self.effective_native_tier() == NctNever:
    return false
  if not native_call_supported0(self, f):
    return false
  var ctx: NativeContext
  if not self.prepare_native_ctx(f, ctx):
    return false
  let result_i64 = cast[NativeFn0](ctx.entry)(addr ctx)
  unbox_native_result(ctx, result_i64, out_value)
  true

proc try_native_call1(self: ptr VirtualMachine, f: Function, arg: Value, out_value: var Value): bool =
  if self.effective_native_tier() == NctNever:
    return false
  if not native_call_supported1(self, f, arg):
    return false
  var ctx: NativeContext
  if not self.prepare_native_ctx(f, ctx):
    return false
  let a0 = arg_to_i64(arg, native_arg_type_id(f, 0))
  let result_i64 = cast[NativeFn1](ctx.entry)(addr ctx, a0)
  unbox_native_result(ctx, result_i64, out_value)
  true

proc try_native_call(self: ptr VirtualMachine, f: Function, args: seq[Value], out_value: var Value): bool =
  if self.effective_native_tier() == NctNever:
    return false
  if not native_call_supported(self, f, args):
    return false
  var ctx: NativeContext
  if not self.prepare_native_ctx(f, ctx):
    return false

  var m: array[8, int64]  # Stack-allocated marshal buffer (max 7 args + headroom)
  for i in 0..<args.len:
    m[i] = arg_to_i64(args[i], native_arg_type_id(f, i))

  var result_i64: int64
  case args.len
  of 0:
    result_i64 = cast[NativeFn0](ctx.entry)(addr ctx)
  of 1:
    result_i64 = cast[NativeFn1](ctx.entry)(addr ctx, m[0])
  of 2:
    result_i64 = cast[NativeFn2](ctx.entry)(addr ctx, m[0], m[1])
  of 3:
    result_i64 = cast[NativeFn3](ctx.entry)(addr ctx, m[0], m[1], m[2])
  of 4:
    result_i64 = cast[NativeFn4](ctx.entry)(addr ctx, m[0], m[1], m[2], m[3])
  of 5:
    result_i64 = cast[NativeFn5](ctx.entry)(addr ctx, m[0], m[1], m[2], m[3], m[4])
  of 6:
    result_i64 = cast[NativeFn6](ctx.entry)(addr ctx, m[0], m[1], m[2], m[3], m[4], m[5])
  of 7:
    result_i64 = cast[NativeFn7](ctx.entry)(addr ctx, m[0], m[1], m[2], m[3], m[4], m[5], m[6])
  else:
    return false
  unbox_native_result(ctx, result_i64, out_value)
  true

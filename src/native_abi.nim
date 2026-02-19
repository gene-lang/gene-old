const
  GeneAbiVersion* = 1'u32

type
  AirNativeStatus* = enum
    AirNativeOk = 0
    AirNativeErr = 1
    AirNativeTrap = 2

  AirNativeCtx* {.bycopy.} = object
    vm*: pointer
    task_id*: uint64
    caps_mask*: uint64
    trace_id*: uint64

  AirNativeFn* = proc(
    ctx: ptr AirNativeCtx;
    args: ptr uint64;
    argc: uint16;
    out_result: ptr uint64;
    out_error: ptr uint64
  ): cint {.cdecl.}

  AirNativeRegistration* {.bycopy.} = object
    name*: cstring
    arity*: int16
    caps_mask*: uint64
    fn*: AirNativeFn

  GeneRegisterNativeFn* = proc(reg: ptr AirNativeRegistration; userData: pointer): int32 {.cdecl.}

  GeneHostApi* {.bycopy.} = object
    abi_version*: uint32
    user_data*: pointer
    register_native*: GeneRegisterNativeFn

  GeneExtensionInitFn* = proc(host: ptr GeneHostApi): int32 {.cdecl.}

const
  GENE_LLM_HOST_ABI_VERSION* = 1'u32

type
  GeneLlmHostStatus* = enum
    GlhsOk = 0
    GlhsErr = 1
    GlhsAbiMismatch = 2

  GeneLlmHostAbiVersionFn* = proc(): uint32 {.cdecl, gcsafe.}
  GeneLlmHostLoadModelFn* = proc(path: cstring, options_ser: cstring,
                                 out_model_id: ptr int64, out_error: ptr cstring): int32 {.cdecl, gcsafe.}
  GeneLlmHostNewSessionFn* = proc(model_id: int64, options_ser: cstring,
                                  out_session_id: ptr int64, out_error: ptr cstring): int32 {.cdecl, gcsafe.}
  GeneLlmHostInferFn* = proc(session_id: int64, prompt: cstring, options_ser: cstring,
                             out_result_ser: ptr cstring, out_error: ptr cstring): int32 {.cdecl, gcsafe.}
  GeneLlmHostCloseModelFn* = proc(model_id: int64, out_error: ptr cstring): int32 {.cdecl, gcsafe.}
  GeneLlmHostCloseSessionFn* = proc(session_id: int64, out_error: ptr cstring): int32 {.cdecl, gcsafe.}
  GeneLlmHostFreeCStringFn* = proc(s: cstring) {.cdecl, gcsafe.}

when defined(gene_wasm):
  proc gene_host_now*(): int64 {.importc, cdecl.}
  proc gene_host_rand*(): int64 {.importc, cdecl.}
  proc gene_host_file_exists*(path: cstring): cint {.importc, cdecl.}
  proc gene_host_read_file*(path: cstring; outBuf: ptr cstring; outLen: ptr cint): cint {.importc, cdecl.}
  proc gene_host_write_file*(path: cstring; data: cstring; len: cint): cint {.importc, cdecl.}
  proc gene_host_free*(p: pointer) {.importc, cdecl.}

proc hostNowUnix*(): int64 =
  when defined(gene_wasm):
    gene_host_now()
  else:
    0'i64

proc hostRandI64*(): int64 =
  when defined(gene_wasm):
    gene_host_rand()
  else:
    0'i64

proc hostFileExists*(path: string): bool =
  when defined(gene_wasm):
    gene_host_file_exists(path.cstring) != 0
  else:
    false

proc hostReadTextFile*(path: string): string =
  when defined(gene_wasm):
    var outBuf: cstring = nil
    var outLen: cint = 0
    if gene_host_read_file(path.cstring, addr outBuf, addr outLen) != 0 or outBuf == nil or outLen <= 0:
      return ""
    result = newString(outLen)
    copyMem(addr result[0], outBuf, outLen)
    gene_host_free(cast[pointer](outBuf))
  else:
    ""

proc hostWriteTextFile*(path: string; content: string): bool =
  when defined(gene_wasm):
    gene_host_write_file(path.cstring, content.cstring, cint(content.len)) == 0
  else:
    false

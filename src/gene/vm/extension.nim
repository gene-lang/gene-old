import dynlib, strutils
import ../types

when defined(posix):
  # Use dlopen with RTLD_GLOBAL on POSIX systems
  # This makes symbols from the main executable available to the loaded library
  const RTLD_NOW = 2
  const RTLD_GLOBAL = 256  # 0x100

  when defined(macosx):
    # On macOS, dlopen is in libSystem
    proc dlopen(filename: cstring, flag: cint): pointer {.importc.}
    proc dlsym(handle: pointer, symbol: cstring): pointer {.importc.}
    proc dlclose(handle: pointer): cint {.importc.}
    proc dlerror(): cstring {.importc.}
  else:
    # On Linux, dlopen is in libdl
    proc dlopen(filename: cstring, flag: cint): pointer {.importc, dynlib: "libdl.so(|.2|.1)".}
    proc dlsym(handle: pointer, symbol: cstring): pointer {.importc, dynlib: "libdl.so(|.2|.1)".}
    proc dlclose(handle: pointer): cint {.importc, dynlib: "libdl.so(|.2|.1)".}
    proc dlerror(): cstring {.importc, dynlib: "libdl.so(|.2|.1)".}

  proc loadLibGlobal(path: cstring): LibHandle =
    ## Load library with RTLD_GLOBAL so it can see symbols from main executable
    let handle = dlopen(path, RTLD_NOW or RTLD_GLOBAL)
    if handle == nil:
      let err = dlerror()
      echo "DEBUG: dlopen error: ", if err != nil: $err else: "unknown"
      return nil
    return cast[LibHandle](handle)

type
  # Function type for extension initialization
  Init* = proc(vm: ptr VirtualMachine): Namespace {.gcsafe, nimcall.}

  # Function type for setting globals in extension
  SetGlobals* = proc(vm: ptr VirtualMachine) {.nimcall.}

proc load_extension*(vm: ptr VirtualMachine, path: string): Namespace =
  ## Load a dynamic library extension and return its namespace
  var lib_path = path

  # Try adding .so extension if not present
  if not (path.endsWith(".so") or path.endsWith(".dll") or path.endsWith(".dylib")):
    when defined(windows):
      lib_path = path & ".dll"
    elif defined(macosx):
      lib_path = path & ".dylib"
    else:
      lib_path = path & ".so"

  when defined(posix):
    # Use RTLD_GLOBAL on POSIX to make main executable symbols available
    let handle = loadLibGlobal(lib_path.cstring)
  else:
    let handle = loadLib(lib_path.cstring)

  if handle.isNil:
    raise new_exception(types.Exception, "Failed to load extension: " & lib_path)

  # Call set_globals to pass VM pointer to extension
  let set_globals = cast[SetGlobals](handle.symAddr("set_globals"))
  if set_globals == nil:
    raise new_exception(types.Exception, "set_globals not found in extension: " & path)

  set_globals(vm)

  # Call init to get the extension's namespace
  let init = cast[Init](handle.symAddr("init"))
  if init == nil:
    raise new_exception(types.Exception, "init not found in extension: " & path)

  result = init(vm)
  if result == nil:
    raise new_exception(types.Exception, "Extension init returned nil: " & path)



# No longer needed since we use deterministic hashing

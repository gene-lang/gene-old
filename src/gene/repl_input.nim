import std/[dynlib, strutils, terminal]

type
  ReplInputBackendKind* = enum
    RibPlain
    RibReadline

  ReadlineProc = proc(prompt: cstring): cstring {.cdecl.}
  AddHistoryProc = proc(line: cstring) {.cdecl.}
  HistoryInitProc = proc() {.cdecl.}

  ReplInputReader* = ref object
    backend*: ReplInputBackendKind
    input_file: File
    close_input: bool
    readline_lib: LibHandle
    history_lib: LibHandle
    readline_fn: ReadlineProc
    add_history_fn: AddHistoryProc
    using_history_fn: HistoryInitProc
    clear_history_fn: HistoryInitProc
    last_history_entry: string

proc c_free(mem: pointer) {.importc: "free", header: "<stdlib.h>".}

proc should_use_readline_backend*(stdin_is_tty: bool, backend_available: bool): bool =
  stdin_is_tty and backend_available

proc should_record_repl_history_entry*(entry: string, last_entry: string): bool =
  entry.len > 0 and entry != last_entry

proc readline_candidates(): seq[string] =
  when defined(macosx) or defined(macos):
    @[
      "/opt/homebrew/opt/readline/lib/libreadline.8.dylib",
      "/opt/homebrew/opt/readline/lib/libreadline.dylib",
      "/usr/local/opt/readline/lib/libreadline.8.dylib",
      "/usr/local/opt/readline/lib/libreadline.dylib",
      "libreadline.8.dylib",
      "libreadline.dylib",
    ]
  elif defined(linux):
    @["libreadline.so.8", "libreadline.so"]
  else:
    @[]

proc history_candidates(): seq[string] =
  when defined(macosx) or defined(macos):
    @[
      "/opt/homebrew/opt/readline/lib/libhistory.8.dylib",
      "/opt/homebrew/opt/readline/lib/libhistory.dylib",
      "/usr/local/opt/readline/lib/libhistory.8.dylib",
      "/usr/local/opt/readline/lib/libhistory.dylib",
      "libhistory.8.dylib",
      "libhistory.dylib",
    ]
  elif defined(linux):
    @["libhistory.so.8", "libhistory.so"]
  else:
    @[]

proc load_first_library(candidates: seq[string]): LibHandle =
  for candidate in candidates:
    result = loadLib(candidate)
    if not result.isNil:
      return result

proc unload_handle(handle: var LibHandle) =
  if not handle.isNil:
    unloadLib(handle)
    handle = nil

proc resolve_symbol(handles: openArray[LibHandle], name: cstring): pointer =
  for handle in handles:
    if handle.isNil:
      continue
    result = handle.symAddr(name)
    if not result.isNil:
      return result

proc try_enable_readline(reader: ReplInputReader): bool =
  reader.readline_lib = load_first_library(readline_candidates())
  if reader.readline_lib.isNil:
    return false

  reader.history_lib = load_first_library(history_candidates())

  let handles =
    if reader.history_lib.isNil or reader.history_lib == reader.readline_lib:
      @[reader.readline_lib]
    else:
      @[reader.readline_lib, reader.history_lib]

  let readline_sym = resolve_symbol(handles, "readline")
  let add_history_sym = resolve_symbol(handles, "add_history")
  let using_history_sym = resolve_symbol(handles, "using_history")
  let clear_history_sym = resolve_symbol(handles, "clear_history")

  if readline_sym.isNil or add_history_sym.isNil or
      using_history_sym.isNil or clear_history_sym.isNil:
    unload_handle(reader.history_lib)
    unload_handle(reader.readline_lib)
    return false

  reader.readline_fn = cast[ReadlineProc](readline_sym)
  reader.add_history_fn = cast[AddHistoryProc](add_history_sym)
  reader.using_history_fn = cast[HistoryInitProc](using_history_sym)
  reader.clear_history_fn = cast[HistoryInitProc](clear_history_sym)
  reader.using_history_fn()
  reader.clear_history_fn()
  reader.backend = RibReadline
  return true

proc init_plain_input(reader: ReplInputReader) =
  reader.backend = RibPlain
  reader.input_file = stdin
  reader.close_input = false

  if isatty(stdin):
    var tty: File
    if open(tty, "/dev/tty", fmRead):
      reader.input_file = tty
      reader.close_input = true

proc new_repl_input_reader*(): ReplInputReader =
  new(result)
  if should_use_readline_backend(isatty(stdin), true) and result.try_enable_readline():
    return result
  result.init_plain_input()

proc close*(reader: ReplInputReader) =
  if reader.isNil:
    return

  if reader.backend == RibReadline and not reader.clear_history_fn.isNil:
    reader.clear_history_fn()

  if reader.close_input:
    reader.input_file.close()
    reader.close_input = false

  if not reader.history_lib.isNil and reader.history_lib != reader.readline_lib:
    unload_handle(reader.history_lib)
  unload_handle(reader.readline_lib)
  reader.history_lib = nil

proc read_line*(reader: ReplInputReader, prompt: string, input: var string): bool =
  if reader.isNil:
    return false

  case reader.backend
  of RibReadline:
    let raw_line = reader.readline_fn(prompt.cstring)
    if raw_line.isNil:
      if prompt.len > 0:
        echo ""
      return false

    input = $raw_line
    c_free(raw_line)

    let trimmed = input.strip()
    if should_record_repl_history_entry(trimmed, reader.last_history_entry):
      reader.add_history_fn(trimmed.cstring)
      reader.last_history_entry = trimmed
    return true
  of RibPlain:
    stdout.write(prompt)
    stdout.flushFile()
    if not reader.input_file.readLine(input):
      if prompt.len > 0:
        echo ""
      return false
    return true

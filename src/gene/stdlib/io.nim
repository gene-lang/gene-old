import tables, os, strutils
import ../types
import ../wasm_host_abi

# I/O functions for the Gene standard library

# File instance type - stores the path
type
  FileInstance* = ref object
    path*: string

# File constructor
proc io_file_constructor*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File constructor requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File constructor requires a string path")

  # Create instance with path property
  let instance = new_instance_value(App.app.file_class.ref.class)
  instance_props(instance)["path".to_key()] = path_arg
  return instance

# File instance method: read
proc io_file_read_instance*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "read requires self")

  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkInstance:
    raise new_exception(types.Exception, "read must be called on a File instance")

  let path_value = instance_props(self_arg)["path".to_key()]
  if path_value.kind != VkString:
    raise new_exception(types.Exception, "File instance has no path")

  let path = path_value.str
  let read_result = host_read_text_file(path)
  if read_result.ok:
    return read_result.content.to_value()
  raise new_exception(types.Exception, "Failed to read file '" & path & "': " & read_result.error)

# File static method: each_line (for File/each_line "path" callback)
proc io_file_each_line*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if get_positional_count(arg_count, has_keyword_args) < 2:
    raise new_exception(types.Exception, "File/each_line requires path and callback")
  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  let callback = get_positional_arg(args, 1, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/each_line requires a string path")
  let f = open(path_arg.str)
  defer: f.close()
  var line: string
  while f.readLine(line):
    {.cast(gcsafe).}:
      discard vm_exec_callable(vm, callback, @[line.to_value()])
  return NIL

# FileReader: streaming line reader with .read_line method (no callback overhead)
type
  FileReaderState = ref object
    file: File
    eof: bool

var file_reader_class: Class

proc init_file_reader_class_impl(object_class: Class) =
  file_reader_class = new_class("FileReader")
  file_reader_class.parent = object_class

  proc reader_read_line(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let state_val = instance_props(self_val)["__state__".to_key()]
    let state = cast[FileReaderState](cast[pointer](state_val.raw and PAYLOAD_MASK))
    if state.eof:
      return NIL
    var line: string
    if state.file.readLine(line):
      return line.to_value()
    else:
      state.eof = true
      return NIL

  proc reader_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    let state_val = instance_props(self_val)["__state__".to_key()]
    let state = cast[FileReaderState](cast[pointer](state_val.raw and PAYLOAD_MASK))
    if not state.eof:
      state.file.close()
      state.eof = true
    return NIL

  file_reader_class.def_native_method("read_line", reader_read_line)
  file_reader_class.def_native_method("close", reader_close)

  let fr_ref = new_ref(VkClass)
  fr_ref.class = file_reader_class
  App.app.global_ns.ns["FileReader".to_key()] = fr_ref.to_ref_value()

proc open_file_reader*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    not_allowed("File/reader requires a string path")
  let state = FileReaderState(file: open(path_arg.str), eof: false)
  GC_ref(state)
  {.cast(gcsafe).}:
    let cls = App.app.global_ns.ns["FileReader".to_key()].ref.class
    var props = initTable[Key, Value]()
    props["__state__".to_key()] = cast[pointer](state).to_value()
    return new_instance_value(cls, props)

# File static method: read_lines (returns array of lines without callback)
proc io_file_read_lines*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "File/read_lines requires a path")
  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/read_lines requires a string path")
  var lines: seq[Value] = @[]
  let f = open(path_arg.str)
  defer: f.close()
  var line: string
  while f.readLine(line):
    lines.add(line.to_value())
  return new_array_value(lines)

# File static method: read (for File/read "path" syntax)
proc io_file_read*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File/read requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/read requires a string path")

  let path = path_arg.str
  let read_result = host_read_text_file(path)
  if read_result.ok:
    return read_result.content.to_value()
  raise new_exception(types.Exception, "Failed to read file '" & path & "': " & read_result.error)

# File instance method: write
proc io_file_write_instance*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "write requires self and content")

  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkInstance:
    raise new_exception(types.Exception, "write must be called on a File instance")

  let path_value = instance_props(self_arg)["path".to_key()]
  if path_value.kind != VkString:
    raise new_exception(types.Exception, "File instance has no path")

  let path = path_value.str
  let content_arg = get_positional_arg(args, 1, has_keyword_args)
  let content = content_arg.str_no_quotes()

  let write_result = host_write_text_file(path, content)
  if write_result.ok:
    return NIL
  raise new_exception(types.Exception, "Failed to write file '" & path & "': " & write_result.error)

# File static method: write
proc io_file_write*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "File/write requires 2 arguments (path, content)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  let content_arg = get_positional_arg(args, 1, has_keyword_args)

  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/write requires a string path")

  let path = path_arg.str
  let content = content_arg.str_no_quotes()

  let write_result = host_write_text_file(path, content)
  if write_result.ok:
    return NIL
  raise new_exception(types.Exception, "Failed to write file '" & path & "': " & write_result.error)

proc io_file_append*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "File/append requires 2 arguments (path, content)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  let content_arg = get_positional_arg(args, 1, has_keyword_args)

  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/append requires a string path")

  let path = path_arg.str
  let content = content_arg.str_no_quotes()

  when defined(gene_wasm):
    let existing = host_read_text_file(path)
    if not existing.ok:
      raise new_exception(types.Exception, "Failed to append to file '" & path & "': " & existing.error)
    let write_result = host_write_text_file(path, existing.content & content)
    if write_result.ok:
      return NIL
    raise new_exception(types.Exception, "Failed to append to file '" & path & "': " & write_result.error)
  else:
    try:
      let file = open(path, fmAppend)
      file.write(content)
      file.close()
      return NIL
    except IOError as e:
      raise new_exception(types.Exception, "Failed to append to file '" & path & "': " & e.msg)

proc io_file_exists*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File/exists requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/exists requires a string path")

  let path = path_arg.str
  return host_file_exists(path).to_value()

proc io_file_delete*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File/delete requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/delete requires a string path")

  let path = path_arg.str
  when defined(gene_wasm):
    raise_wasm_unsupported("file_delete")
  else:
    try:
      removeFile(path)
      return NIL
    except OSError as e:
      raise new_exception(types.Exception, "Failed to delete file '" & path & "': " & e.msg)

# Dir class methods
proc io_dir_exists*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Dir/exists requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "Dir/exists requires a string path")

  let path = path_arg.str
  when defined(gene_wasm):
    raise_wasm_unsupported("directory_ops")
  else:
    return dirExists(path).to_value()

proc io_dir_create*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Dir/create requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "Dir/create requires a string path")

  let path = path_arg.str
  when defined(gene_wasm):
    raise_wasm_unsupported("directory_ops")
  else:
    try:
      createDir(path)
      return NIL
    except OSError as e:
      raise new_exception(types.Exception, "Failed to create directory '" & path & "': " & e.msg)

proc io_dir_delete*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Dir/delete requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "Dir/delete requires a string path")

  let path = path_arg.str
  when defined(gene_wasm):
    raise_wasm_unsupported("directory_ops")
  else:
    try:
      removeDir(path)
      return NIL
    except OSError as e:
      raise new_exception(types.Exception, "Failed to delete directory '" & path & "': " & e.msg)

proc io_dir_list*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "Dir/list requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "Dir/list requires a string path")

  let path = path_arg.str
  when defined(gene_wasm):
    raise_wasm_unsupported("directory_ops")
  else:
    try:
      var files: seq[Value] = @[]
      for kind, file_path in walkDir(path):
        files.add(file_path.to_value())
      return new_array_value(files)
    except OSError as e:
      raise new_exception(types.Exception, "Failed to list directory '" & path & "': " & e.msg)

# Path operations
proc io_path_join*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "path_join requires at least 2 arguments")

  var parts: seq[string] = @[]
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let part = get_positional_arg(args, i, has_keyword_args)
    if part.kind != VkString:
      raise new_exception(types.Exception, "path_join requires string arguments")
    parts.add(part.str)

  return joinPath(parts).to_value()

proc io_path_abs*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "path_abs requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "path_abs requires a string path")

  let path = path_arg.str
  return absolutePath(path).to_value()

proc io_path_basename*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "path_basename requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "path_basename requires a string path")

  let path = path_arg.str
  return extractFilename(path).to_value()

proc io_path_dirname*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "path_dirname requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "path_dirname requires a string path")

  let path = path_arg.str
  return parentDir(path).to_value()

proc io_path_ext*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "path_ext requires 1 argument (path)")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "path_ext requires a string path")

  let path = path_arg.str
  return splitFile(path).ext.to_value()

# Register all I/O functions in a namespace
proc init_io_namespace*(global_ns: Namespace) =
  let io_ns = new_namespace("io")

  # File class with constructor, instance methods, and static methods
  let file_class = new_class("File")
  file_class.def_native_constructor(io_file_constructor)
  file_class.def_native_method("read", io_file_read_instance)
  file_class.def_native_method("write", io_file_write_instance)

  # Add static methods to class members
  file_class.def_static_method("read", io_file_read)
  file_class.def_static_method("each_line", io_file_each_line)
  file_class.def_static_method("read_lines", io_file_read_lines)
  file_class.def_static_method("reader", open_file_reader)

  init_file_reader_class_impl(App.app.object_class.ref.class)
  file_class.def_static_method("write", io_file_write)
  file_class.def_static_method("append", io_file_append)
  file_class.def_static_method("exists", io_file_exists)
  file_class.def_static_method("delete", io_file_delete)

  let file_class_ref = new_ref(VkClass)
  file_class_ref.class = file_class
  let file_class_value = file_class_ref.to_ref_value()
  App.app.file_class = file_class_value
  io_ns["File".to_key()] = file_class_value

  # Dir namespace with static methods (keep as namespace for now)
  let dir_ns = new_namespace("Dir")
  dir_ns["exists".to_key()] = io_dir_exists.to_value()
  dir_ns["create".to_key()] = io_dir_create.to_value()
  dir_ns["delete".to_key()] = io_dir_delete.to_value()
  dir_ns["list".to_key()] = io_dir_list.to_value()
  io_ns["Dir".to_key()] = dir_ns.to_value()

  # Path functions
  io_ns["path_join".to_key()] = io_path_join.to_value()
  io_ns["path_abs".to_key()] = io_path_abs.to_value()
  io_ns["path_basename".to_key()] = io_path_basename.to_value()
  io_ns["path_dirname".to_key()] = io_path_dirname.to_value()
  io_ns["path_ext".to_key()] = io_path_ext.to_value()

  global_ns["io".to_key()] = io_ns.to_value()

  # Also add to global namespace for convenience
  global_ns["File".to_key()] = file_class_value
  global_ns["Dir".to_key()] = dir_ns.to_value()

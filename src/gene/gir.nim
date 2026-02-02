# Gene Intermediate Representation (GIR) serialization/deserialization
import streams, hashes, os, times, json, strutils, tables
import ./types

const
  GIR_MAGIC = "GENE"
  GIR_VERSION* = 2'u32
  COMPILER_VERSION = "0.1.0"
  VALUE_ABI_VERSION* = 2'u32  # Version 2: Value is object wrapper with GC
  
type
  GirHeader* = object
    magic*: array[4, char]
    version*: uint32
    compiler_version*: string
    vm_abi*: string
    timestamp*: int64
    debug*: bool
    published*: bool
    source_hash*: Hash

  SerializedTraceNode = object
    parent_index*: int32
    filename*: string
    line*: int32
    column*: int32
    
  GirFile* = object
    header*: GirHeader
    constants*: seq[Value]
    symbols*: seq[string]
    instructions*: seq[Instruction]
    trace_nodes*: seq[SerializedTraceNode]
    instruction_trace_indices*: seq[int32]
    metadata*: JsonNode
    kind*: string
    unit_id*: Id
    skip_return*: bool

# Serialization helpers
proc write_string(stream: Stream, s: string) =
  stream.write(s.len.uint32)
  if s.len > 0:
    stream.write(s)

proc read_string(stream: Stream): string =
  let len = stream.readUint32()
  if len > 0:
    result = newString(len)
    discard stream.readData(result[0].addr, len.int)

proc writeScopeTrackerSnapshot(stream: Stream, snapshot: ScopeTrackerSnapshot) =
  if snapshot == nil:
    stream.write(0'u8)
    return

  stream.write(1'u8)
  stream.write(snapshot.next_index)
  stream.write(snapshot.parent_index_max)
  stream.write(if snapshot.scope_started: 1'u8 else: 0'u8)
  stream.write(snapshot.mappings.len.uint32)
  for pair in snapshot.mappings:
    stream.write(cast[int64](pair[0]))
    stream.write(pair[1])

  writeScopeTrackerSnapshot(stream, snapshot.parent)

proc readScopeTrackerSnapshot(stream: Stream): ScopeTrackerSnapshot =
  if stream.readUint8() == 0:
    return nil

  result = ScopeTrackerSnapshot(
    next_index: stream.readInt16(),
    parent_index_max: stream.readInt16(),
    scope_started: stream.readUint8() == 1,
    mappings: @[]
  )

  let map_len = stream.readUint32()
  for _ in 0..<map_len:
    let key = cast[Key](stream.readInt64())
    let value = stream.readInt16()
    result.mappings.add((key, value))

  result.parent = readScopeTrackerSnapshot(stream)

proc writeCompilationUnitBlock(stream: Stream, cu: CompilationUnit)

proc readCompilationUnitBlock(stream: Stream): CompilationUnit

proc write_value(stream: Stream, v: Value)
proc read_value(stream: Stream): Value

proc writeFunctionDef(stream: Stream, info: FunctionDefInfo) =
  write_value(stream, info.input)
  writeScopeTrackerSnapshot(stream, snapshot_scope_tracker(info.scope_tracker))
  if info.compiled_body.kind == VkCompiledUnit:
    stream.write(1'u8)
    writeCompilationUnitBlock(stream, info.compiled_body.ref.cu)
  else:
    stream.write(0'u8)

proc readFunctionDef(stream: Stream): FunctionDefInfo =
  let input = read_value(stream)
  let snapshot = readScopeTrackerSnapshot(stream)
  var compiled_value = NIL
  if stream.readUint8() == 1:
    let compiled = readCompilationUnitBlock(stream)
    let ref_value = new_ref(VkCompiledUnit)
    ref_value.cu = compiled
    compiled_value = ref_value.to_ref_value()
  result = FunctionDefInfo(
    input: input,
    scope_tracker: materialize_scope_tracker(snapshot),
    compiled_body: compiled_value
  )

proc write_value(stream: Stream, v: Value) =
  # Special handling for scope trackers - write NIL instead
  if v.kind == VkScopeTracker:
    stream.write(VkNil.uint16)
    return
  
  # Write value kind
  stream.write(v.kind.uint16)
  
  case v.kind:
  of VkNil, VkVoid, VkPlaceholder:
    # No data
    discard
  of VkBool:
    stream.write(if v == TRUE: 1'u8 else: 0'u8)
  of VkInt:
    stream.write(v.int64)
  of VkFloat:
    stream.write(v.float64)
  of VkString:
    stream.write_string(v.str)
  of VkSymbol:
    stream.write_string(v.str)
  of VkChar:
    # Extract char from NaN-boxed value
    stream.write((v.raw and 0xFF).uint32)
  of VkRegex:
    stream.write_string(v.ref.regex_pattern)
    stream.write(v.ref.regex_flags)
    stream.write(if v.ref.regex_has_replacement: 1'u8 else: 0'u8)
    stream.write_string(v.ref.regex_replacement)
  of VkFunctionDef:
    writeFunctionDef(stream, v.ref.function_def)
  of VkCompiledUnit:
    writeCompilationUnitBlock(stream, v.ref.cu)
  else:
    not_allowed("GIR serialization not implemented for kind " & $v.kind)

proc read_value(stream: Stream): Value =
  let kind = cast[ValueKind](stream.readUint16())
  
  case kind:
  of VkNil:
    result = NIL
  of VkVoid:
    result = VOID
  of VkPlaceholder:
    result = PLACEHOLDER
  of VkBool:
    result = if stream.readUint8() == 1: TRUE else: FALSE
  of VkInt:
    result = stream.readInt64().to_value()
  of VkFloat:
    result = stream.readFloat64().to_value()
  of VkString:
    result = stream.read_string().to_value()
  of VkSymbol:
    result = stream.read_string().to_symbol_value()
  of VkChar:
    result = stream.readUint32().char.to_value()
  of VkRegex:
    let pattern = stream.read_string()
    let flags = stream.readUint8()
    let has_replacement = stream.readUint8() == 1'u8
    let replacement = stream.read_string()
    result = new_regex_value(pattern, flags, replacement, has_replacement)
  of VkFunctionDef:
    let info = readFunctionDef(stream)
    result = info.to_value()
  of VkCompiledUnit:
    let compiled = readCompilationUnitBlock(stream)
    let ref_value = new_ref(VkCompiledUnit)
    ref_value.cu = compiled
    result = ref_value.to_ref_value()
  else:
    not_allowed("GIR read not implemented for kind " & $kind)

proc collect_trace_nodes(node: SourceTrace, buffer: var seq[SourceTrace])
proc build_trace_index(nodes: seq[SourceTrace]): Table[pointer, int]

proc writeCompilationUnitBlock(stream: Stream, cu: CompilationUnit) =
  stream.write(cu.kind.int8)
  stream.write(if cu.skip_return: 1'u8 else: 0'u8)
  stream.write(cu.instructions.len.uint32)
  for inst in cu.instructions:
    stream.write(inst.kind.uint16)
    stream.write(inst.label.uint32)
    write_value(stream, inst.arg0)
    stream.write(inst.arg1)

  cu.ensure_trace_capacity()
  var flattened_trace: seq[SourceTrace] = @[]
  if not cu.trace_root.is_nil:
    collect_trace_nodes(cu.trace_root, flattened_trace)
  stream.write(flattened_trace.len.uint32)
  let trace_index = build_trace_index(flattened_trace)
  for node in flattened_trace:
    let parent_idx = if node.parent.is_nil: -1 else: trace_index.getOrDefault(cast[pointer](node.parent), -1)
    stream.write(parent_idx.int32)
    stream.write_string(node.filename)
    stream.write(node.line.int32)
    stream.write(node.column.int32)

  stream.write(cu.instruction_traces.len.uint32)
  for trace in cu.instruction_traces:
    var idx = -1
    if not trace.is_nil:
      idx = trace_index.getOrDefault(cast[pointer](trace), -1)
    stream.write(idx.int32)

proc readCompilationUnitBlock(stream: Stream): CompilationUnit =
  let kind = cast[CompilationUnitKind](stream.readInt8())
  let skip = stream.readUint8() == 1
  let count = stream.readUint32()
  result = new_compilation_unit()
  result.kind = kind
  result.skip_return = skip
  for _ in 0..<count:
    var inst: Instruction
    inst.kind = cast[InstructionKind](stream.readUint16())
    inst.label = stream.readUint32().Label
    inst.arg0 = read_value(stream)
    inst.arg1 = stream.readInt32()
    result.add_instruction(inst)

  let trace_node_count = stream.readUint32()
  var serialized_nodes: seq[SerializedTraceNode] = @[]
  for _ in 0..<trace_node_count:
    serialized_nodes.add(SerializedTraceNode(
      parent_index: stream.readInt32(),
      filename: stream.read_string(),
      line: stream.readInt32(),
      column: stream.readInt32(),
    ))

  if serialized_nodes.len > 0:
    var node_refs: seq[SourceTrace] = @[]
    for node_info in serialized_nodes:
      node_refs.add(new_source_trace(node_info.filename, node_info.line.int, node_info.column.int))
    for idx, node_info in serialized_nodes:
      let parent_idx = node_info.parent_index.int
      if parent_idx >= 0 and parent_idx < node_refs.len:
        attach_child(node_refs[parent_idx], node_refs[idx])
    result.trace_root = node_refs[0]
  else:
    result.trace_root = nil

  let trace_indices_count = stream.readUint32()
  var trace_indices: seq[int32] = @[]
  for _ in 0..<trace_indices_count:
    trace_indices.add(stream.readInt32())

  if trace_indices.len > 0:
    var node_refs: seq[SourceTrace] = @[]
    if result.trace_root != nil:
      collect_trace_nodes(result.trace_root, node_refs)
    for idx in 0..<result.instructions.len:
      if idx < trace_indices.len:
        let node_index = trace_indices[idx]
        if node_index >= 0 and node_index < node_refs.len:
          result.instruction_traces[idx] = node_refs[node_index]
        else:
          result.instruction_traces[idx] = nil
      else:
        result.instruction_traces[idx] = nil

proc write_instruction(stream: Stream, inst: Instruction) =
  stream.write(inst.kind.uint16)
  stream.write(inst.label.uint32)
  stream.write_value(inst.arg0)
  stream.write(inst.arg1)

proc read_instruction(stream: Stream): Instruction =
  result.kind = cast[InstructionKind](stream.readUint16())
  result.label = stream.readUint32().Label
  result.arg0 = stream.read_value()
  result.arg1 = stream.readInt32()

proc collect_trace_nodes(node: SourceTrace, buffer: var seq[SourceTrace]) =
  if node.is_nil:
    return
  buffer.add(node)
  for child in node.children:
    collect_trace_nodes(child, buffer)

proc build_trace_index(nodes: seq[SourceTrace]): Table[pointer, int] =
  result = initTable[pointer, int]()
  for idx, node in nodes:
    result[cast[pointer](node)] = idx

# Main serialization functions
proc save_gir*(cu: CompilationUnit, path: string, source_path: string = "", debug: bool = false) =
  ## Save a compilation unit to a GIR file
  let dir = path.parentDir()
  if dir != "" and not dirExists(dir):
    createDir(dir)
  
  var stream = newFileStream(path, fmWrite)
  if stream == nil:
    raise new_exception(types.Exception, "Failed to open file for writing: " & path)
  defer: stream.close()
  
  # Write header
  var header: GirHeader
  header.magic = ['G', 'E', 'N', 'E']
  header.version = GIR_VERSION
  header.compiler_version = COMPILER_VERSION
  header.vm_abi = "nim-" & NimVersion & "-" & $sizeof(pointer) & "bit-valueabi" & $VALUE_ABI_VERSION
  header.timestamp = 0'i64  # TODO: Fix epochTime conversion
  header.debug = debug
  header.published = false
  
  # Calculate source hash if provided
  if source_path != "" and fileExists(source_path):
    let source_content = readFile(source_path)
    let raw_hash = cast[uint64](hash(source_content))
    let truncated = raw_hash and 0x7FFF_FFFF_FFFF_FFFF'u64
    header.source_hash = cast[Hash](truncated.int)
    let info = getFileInfo(source_path)
    header.timestamp = info.lastWriteTime.toUnix()
  else:
    header.timestamp = now().toTime().toUnix()
  
  # Write header fields
  stream.write(header.magic)
  stream.write(header.version)
  stream.write_string(header.compiler_version)
  stream.write_string(header.vm_abi)
  stream.write(header.timestamp)
  stream.write(header.debug)
  stream.write(header.published)
  let stored_hash = cast[int64](header.source_hash)
  stream.write(stored_hash)
  
  # Collect constants from instructions
  var constants: seq[Value] = @[]
  # Skip constant collection for now - causing issues
  # TODO: Fix constant pooling
  
  # Write constants
  stream.write(constants.len.uint32)
  for c in constants:
    stream.write_value(c)
  
  # Write symbol table (for now empty - will be populated from global symbols)
  stream.write(0'u32)  # symbol count
  
  # Write instructions
  stream.write(cu.instructions.len.uint32)
  for inst in cu.instructions:
    stream.writeInstruction(inst)

  cu.ensure_trace_capacity()
  var flattened_trace: seq[SourceTrace] = @[]
  if not cu.trace_root.is_nil:
    collect_trace_nodes(cu.trace_root, flattened_trace)
  stream.write(flattened_trace.len.uint32)
  let trace_index = build_trace_index(flattened_trace)
  for node in flattened_trace:
    let parent_idx = if node.parent.is_nil: -1 else: trace_index.getOrDefault(cast[pointer](node.parent), -1)
    stream.write(parent_idx.int32)
    stream.write_string(node.filename)
    stream.write(node.line.int32)
    stream.write(node.column.int32)

  stream.write(cu.instruction_traces.len.uint32)
  for trace in cu.instruction_traces:
    var idx = -1
    if not trace.is_nil:
      idx = trace_index.getOrDefault(cast[pointer](trace), -1)
    stream.write(idx.int32)
  
  # Write metadata as simple values for now
  stream.write_string($cu.kind)
  stream.write(cast[int64](cu.id))
  stream.write(cu.skip_return)

proc load_gir_file*(path: string): GirFile =
  ## Load a GIR file and return its structured contents
  if not fileExists(path):
    raise new_exception(types.Exception, "GIR file not found: " & path)

  var stream = newFileStream(path, fmRead)
  if stream == nil:
    raise new_exception(types.Exception, "Failed to open GIR file: " & path)
  defer: stream.close()

  var header: GirHeader
  discard stream.readData(header.magic[0].addr, 4)
  if header.magic != ['G', 'E', 'N', 'E']:
    raise new_exception(types.Exception, "Invalid GIR file: bad magic")

  header.version = stream.readUint32()
  if header.version != GIR_VERSION:
    raise new_exception(types.Exception, "Unsupported GIR version: " & $header.version)

  header.compiler_version = stream.read_string()
  header.vm_abi = stream.read_string()

  # Validate VALUE_ABI version to prevent loading incompatible GIR files
  let expected_abi_marker = "-valueabi" & $VALUE_ABI_VERSION
  if not header.vm_abi.contains(expected_abi_marker):
    raise new_exception(types.Exception,
      "Incompatible GIR file: VALUE_ABI mismatch. " &
      "Expected valueabi" & $VALUE_ABI_VERSION & " but got: " & header.vm_abi &
      ". Please recompile the source file.")

  header.timestamp = stream.readInt64()
  header.debug = stream.readBool()
  header.published = stream.readBool()
  header.source_hash = stream.readInt64().Hash

  let constant_count = stream.readUint32()
  var constants: seq[Value] = @[]
  for _ in 0..<constant_count:
    constants.add(stream.read_value())

  let symbol_count = stream.readUint32()
  var symbols: seq[string] = @[]
  for _ in 0..<symbol_count:
    symbols.add(stream.read_string())

  let instruction_count = stream.readUint32()
  var instructions: seq[Instruction] = @[]
  for _ in 0..<instruction_count:
    instructions.add(stream.readInstruction())

  let trace_node_count = stream.readUint32()
  var trace_nodes: seq[SerializedTraceNode] = @[]
  for _ in 0..<trace_node_count:
    let parent_index = stream.readInt32()
    let filename = stream.read_string()
    let line = stream.readInt32()
    let column = stream.readInt32()
    trace_nodes.add(SerializedTraceNode(
      parent_index: parent_index,
      filename: filename,
      line: line,
      column: column,
    ))

  let trace_index_count = stream.readUint32()
  var trace_indices: seq[int32] = @[]
  for _ in 0..<trace_index_count:
    trace_indices.add(stream.readInt32())

  let kind_str = stream.read_string()
  let unit_id = stream.readInt64()
  let skip_return = stream.readBool()

  result.header = header
  result.constants = constants
  result.symbols = symbols
  result.instructions = instructions
  result.trace_nodes = trace_nodes
  result.instruction_trace_indices = trace_indices
  result.metadata = newJObject()
  result.metadata["kind"] = newJString(kind_str)
  result.metadata["id"] = newJInt(unit_id)
  result.metadata["skipReturn"] = newJBool(skip_return)
  result.metadata["timestamp"] = newJInt(header.timestamp)
  result.kind = kind_str
  result.unit_id = unit_id.Id
  result.skip_return = skip_return

proc load_gir*(path: string): CompilationUnit =
  ## Load a compilation unit from a GIR file
  let gir_file = load_gir_file(path)
  result = new_compilation_unit()
  result.instructions = gir_file.instructions
  result.ensure_trace_capacity()

  if gir_file.kind.len > 0:
    result.kind = parseEnum[CompilationUnitKind](gir_file.kind)
  result.id = gir_file.unit_id
  result.skip_return = gir_file.skip_return

  if gir_file.trace_nodes.len > 0:
    var node_refs: seq[SourceTrace] = @[]
    for node_info in gir_file.trace_nodes:
      node_refs.add(new_source_trace(node_info.filename, node_info.line.int, node_info.column.int))
    for idx, node_info in gir_file.trace_nodes:
      let parent_idx = node_info.parent_index.int
      if parent_idx >= 0 and parent_idx < node_refs.len:
        attach_child(node_refs[parent_idx], node_refs[idx])
    result.trace_root = node_refs[0]
  else:
    result.trace_root = nil

  if gir_file.instruction_trace_indices.len > 0:
    result.instruction_traces.setLen(result.instructions.len)
    var node_refs: seq[SourceTrace] = @[]
    if result.trace_root != nil:
      collect_trace_nodes(result.trace_root, node_refs)
    for idx in 0..<result.instructions.len:
      if idx < gir_file.instruction_trace_indices.len:
        let node_index = gir_file.instruction_trace_indices[idx]
        if node_index >= 0 and node_index < node_refs.len:
          result.instruction_traces[idx] = node_refs[node_index]
        else:
          result.instruction_traces[idx] = nil
      else:
        result.instruction_traces[idx] = nil

proc is_gir_up_to_date*(gir_path: string, source_path: string): bool =
  ## Check if a GIR file is up-to-date with its source
  if not fileExists(gir_path):
    return false
  
  if not fileExists(source_path):
    return true  # No source to compare against
  
  # Check modification times
  let gir_info = getFileInfo(gir_path)
  let source_info = getFileInfo(source_path)
  
  if source_info.lastWriteTime > gir_info.lastWriteTime:
    return false
  
  # TODO: Check source hash from GIR header
  return true

proc get_gir_path*(source_path: string, out_dir: string = "build"): string =
  ## Get the output path for a GIR file based on source path
  let (dir, name, _) = splitFile(source_path)
  let rel_dir = if dir.startsWith("/"): dir[1..^1] else: dir
  result = out_dir / rel_dir / name & ".gir"

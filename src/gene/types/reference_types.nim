## Reference type, inline data types (ArrayObj, MapObj, InstanceObj),
## and related constants.
## Included from type_defs.nim — shares its scope.

const INST_SIZE* = sizeof(Instruction)
const
  REGEX_FLAG_IGNORE_CASE* = 0x1'u8
  REGEX_FLAG_MULTILINE* = 0x2'u8

type
  # Extended Reference type supporting all ValueKind variants
  Reference* = object
    ref_count*: int  # Reference count for GC
    case kind*: ValueKind
      # Basic string-like types
      of VkString, VkSymbol:
        str*: string
      of VkComplexSymbol:
        csymbol*: seq[string]

      # Numeric and binary types
      of VkInt:
        int_data*: int64
      of VkRatio:
        ratio_num*: int64
        ratio_denom*: int64
      of VkBin:
        bin_data*: seq[uint8]
        bin_bit_size*: uint
      of VkBin64:
        bin64_data*: uint64
        bin64_bit_size*: uint
      of VkByte:
        byte_data*: uint8
        byte_bit_size*: uint
      of VkBytes:
        bytes_data*: seq[uint8]

      # Pattern and regex types
      of VkRegex:
        regex_pattern*: string
        regex_flags*: uint8
        regex_replacement*: string
        regex_has_replacement*: bool
      of VkRegexMatch:
        regex_match_value*: string
        regex_match_captures*: seq[string]
        regex_match_named_captures*: Table[Key, Value]
        regex_match_start*: int64
        regex_match_end*: int64
        regex_match_pre*: string
        regex_match_post*: string
      of VkRange:
        range_start*: Value
        range_end*: Value
        range_step*: Value
      of VkSelector:
        selector_pattern*: string
        selector_path*: seq[Value]

      # Date and time types
      of VkDate:
        date_year*: int16
        date_month*: int8
        date_day*: int8
      of VkDateTime:
        dt_year*: int16
        dt_month*: int8
        dt_day*: int8
        dt_hour*: int8
        dt_minute*: int8
        dt_second*: int8
        dt_microsecond*: int32
        dt_timezone*: int16    # offset in minutes, 0 for naive/UTC
        dt_tz_name*: string    # IANA zone name, "" if not specified
      of VkTime:
        time_hour*: int8
        time_minute*: int8
        time_second*: int8
        time_microsecond*: int32
        time_tz_offset*: int16  # offset in minutes, 0 if unresolved
        time_tz_name*: string   # IANA zone name, "" if not specified
      of VkTimezone:
        tz_offset*: int16
        tz_name*: string

      # Collection types
      of VkSet:
        set_items*: seq[Value]
        set_buckets*: OrderedTable[Hash, seq[int]]
      of VkMap:
        map*: Table[Key, Value]
      of VkHashMap:
        hash_map_frozen*: bool
        hash_map_items*: seq[Value]
        hash_map_buckets*: OrderedTable[Hash, seq[int]]
      of VkStream:
        stream*: seq[Value]
        stream_index*: int64
        stream_ended*: bool
      of VkDocument:
        doc*: Document
      # File system types
      of VkFile:
        file_path*: string
        file_content*: seq[uint8]
        file_permissions*: uint16
      of VkArchiveFile:
        arc_path*: string
        arc_members*: Table[string, Value]
      of VkDirectory:
        dir_path*: string
        dir_members*: Table[string, Value]

      # Meta-programming types
      of VkQuote:
        quote*: Value
      of VkUnquote:
        unquote*: Value
        unquote_discard*: bool
      of VkReference:
        ref_target*: Value
      of VkRefTarget:
        target_id*: int64
      of VkFuture:
        future*: FutureObj
      of VkGenerator:
        generator*: GeneratorObj  # Store the generator ref object directly
      of VkThread:
        thread*: Thread
      of VkThreadMessage:
        thread_message*: ThreadMessage

      # Language constructs
      of VkApplication:
        app*: Application
      of VkPackage:
        pkg*: Package
      of VkModule:
        module*: Module
      of VkNamespace:
        ns*: Namespace
      of VkFunction:
        fn*: Function
      of VkBlock:
        `block`*: Block
      of VkClass:
        class*: Class
      of VkMethod:
        `method`*: Method
      of VkBoundMethod:
        bound_method*: BoundMethod
      of VkSuper:
        super_instance*: Value
        super_class*: Class
      of VkCast:
        cast_value*: Value
        cast_class*: Class
      of VkEnum:
        enum_def*: EnumDef
      of VkEnumMember:
        enum_member*: EnumMember
      of VkInterface:
        gene_interface*: GeneInterface
      of VkAdapter:
        adapter*: Adapter
      of VkAdapterInternal:
        adapter_internal*: Adapter  # Reference to adapter for internal data access
      of VkNativeFn:
        native_fn*: NativeFn
      of VkNativeMacro:
        native_macro*: NativeMacroFn
      of VkNativeMethod:
        native_method*: NativeFn

      of VkException:
        exception_data*: ExceptionData
      of VkInterception:
        interception*: Interception
      of VkAspect:
        aspect*: Aspect

      # Concurrency types

      # JSON and file types
      of VkJson:
        json_data*: string  # Serialized JSON
      of VkNativeFile:
        native_file*: File

      # Internal VM types
      of VkCompiledUnit:
        cu*: CompilationUnit
      of VkInstruction:
        instr*: Instruction
      of VkScopeTracker:
        scope_tracker*: ScopeTracker
      of VkFunctionDef:
        function_def*: FunctionDefInfo
      of VkScope:
        scope*: Scope
      of VkFrame:
        frame*: Frame
      of VkNativeFrame:
        native_frame*: NativeFrame

      # Any and Custom types
      of VkAny:
        any_data*: pointer
        any_class*: Class
      of VkCustom:
        custom_data*: CustomValue
        custom_class*: Class

      else:
        discard

  ArrayObj* = object
    ref_count*: int
    frozen*: bool
    arr*: seq[Value]

  MapObj* = object
    ref_count*: int
    frozen*: bool
    map*: Table[Key, Value]

  InstanceObj* = object
    ref_count*: int
    instance_class*: Class
    instance_props*: Table[Key, Value]
    module_path*: string
    internal_path*: string

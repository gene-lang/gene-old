# Forward declarations for new types
import tables, sets, asyncdispatch

when defined(gene_wasm):
  type
    LibHandle* = pointer
else:
  import dynlib

const
  NO_TYPE_ID* = -1'i32

type
  Value* {.bycopy.} = object
    ## NaN-boxed value with automatic reference counting
    ## Size: 8 bytes (same as distinct int64)
    ## Enables =copy/=destroy hooks for GC
    raw*: uint64

  CustomValue* = ref object of RootObj
    materialize_hook*: proc(data: CustomValue): Value {.gcsafe.}

  EnumDef* = ref object
    name*: string
    members*: Table[string, EnumMember]
    module_path*: string
    internal_path*: string

  EnumMember* = ref object
    parent*: Value  # The enum this member belongs to
    name*: string
    value*: int
    module_path*: string
    internal_path*: string

  FutureState* = enum
    FsPending
    FsSuccess
    FsFailure
    FsCancelled

  FutureObj* = ref object
    state*: FutureState
    value*: Value              # Result value or exception
    success_callbacks*: seq[Value]  # Success callback functions
    failure_callbacks*: seq[Value]  # Failure callback functions
    nim_future*: Future[Value]  # Underlying Nim async future (nil for sync futures)

  PubSubSubscription* = ref object
    id*: int
    event_key*: string
    callback*: Value
    active*: bool

  PubSubEvent* = ref object
    event_type*: Value
    event_key*: string
    payload*: Value
    has_payload*: bool
    combine*: bool

  GeneratorState* = enum
    GsPending            # Not yet started
    GsRunning            # Currently executing
    GsSuspended          # Suspended at yield
    GsDone               # Exhausted

  ExceptionData* = ref object
  
  Interception* = ref object
    original*: Value      # Original callable (method/function)
    aspect*: Value        # The aspect that created this interception
    param_name*: string   # Which aspect param this method maps to
    active*: bool         # Whether this interception is active

  # AOP Aspect type
  AopAfterAdvice* = object
    callable*: Value
    replace_result*: bool
    user_arg_count*: int  # Number of user-declared args (excluding implicit self), -1 if unknown

  Aspect* = ref object
    name*: string
    param_names*: seq[string]                  # Method placeholders [m1, m2]
    before_advices*: Table[string, seq[Value]] # param -> [advice fns]
    invariant_advices*: Table[string, seq[Value]]
    after_advices*: Table[string, seq[AopAfterAdvice]]
    around_advices*: Table[string, Value]      # param -> single around advice
    before_filter_advices*: Table[string, seq[Value]]
    enabled*: bool

  AopContext* = object
    wrapped*: Value
    instance*: Value
    args*: seq[Value]
    kw_pairs*: seq[(Key, Value)]
    in_around*: bool
    caller_context*: Frame
    handler_depth*: int
    exception_escaped*: bool

  # Threading support types
  ThreadMessageType* = enum
    MtSend          # Send data, no reply expected
    MtSendExpectReply # Send data, expect reply
    MtRun           # Run code, no reply expected
    MtRunExpectReply  # Run code, expect reply
    MtReply         # Reply to previous message
    MtTerminate     # Terminate thread

  ThreadState* = enum
    TsUninitialized  # Thread slot not initialized
    TsFree           # Thread slot available
    TsBusy           # Thread is running

  Thread* = ref object
    id*: int              # Thread ID (index in THREADS array)
    secret*: int          # Secret for validation

  ThreadPayload* = object
    bytes*: seq[byte]

  ThreadMessage* = ref object
    id*: int                    # Unique message ID
    msg_type*: ThreadMessageType    # Type of message (renamed to avoid 'type' keyword)
    payload*: Value             # Data payload
    payload_bytes*: ThreadPayload  # Serialized payload for cross-thread isolation
    code*: Value                # Gene AST to compile and execute (not bytecode!)
    from_message_id*: int       # For MtReply
    from_thread_id*: int        # Sender thread ID
    from_thread_secret*: int    # Sender thread secret
    handled*: bool              # For user callbacks

  ValueKind* {.size: sizeof(int16) .} = enum
    # Core types
    VkNil = 0
    VkVoid
    VkPlaceholder
    VkPointer

    # Any and Custom types for extensibility
    VkAny
    VkCustom

    # Basic data types
    VkBool
    VkInt
    VkRatio              # Rational numbers
    VkFloat
    VkBin                # Binary data with bit size
    VkBin64              # 64-bit binary with bit size
    VkByte               # Single byte with bit size
    VkBytes              # Byte sequences
    VkChar               # Unicode characters
    VkString
    VkSymbol
    VkComplexSymbol

    # Pattern and regex types
    VkRegex
    VkRegexMatch
    VkRange
    VkSelector

    # Async types
    VkFuture             # Async future/promise
    VkGenerator          # Generator instance
    VkThread             # Thread reference
    VkThreadMessage      # Thread message

    # Date and time types
    VkDate               # Date only
    VkDateTime           # Date + time + timezone
    VkTime               # Time only
    VkTimezone           # Timezone info

    # Collection types
    VkArray             # Sequence type
    VkSet
    VkMap
    VkGene
    VkStream
    VkDocument

    # File system types
    VkFile
    VkArchiveFile
    VkDirectory

    # Meta-programming types
    VkQuote
    VkUnquote
    VkReference
    VkRefTarget

    # Language construct types
    VkApplication
    VkPackage
    VkModule
    VkNamespace
    VkFunction
    VkBlock
    VkClass
    VkMethod
    VkBoundMethod
    VkSuper
    VkInstance
    VkCast               # Type casting
    VkEnum
    VkEnumMember
    VkInterface          # Interface definition
    VkAdapter            # Adapter wrapper
    VkAdapterInternal    # Adapter internal data accessor
    VkNativeFn
    VkNativeMacro    # Native macro (receives unevaluated args)
    VkNativeMethod

    # Exception handling
    VkException = 128    # Start exceptions at 128
    VkInterception       # AOP interception
    VkAspect             # AOP aspect definition

    # Concurrency types

    # JSON integration
    VkJson               # JSON values
    VkNativeFile         # Native file handles

    # Internal VM types
    VkCompiledUnit
    VkInstruction
    VkScopeTracker
    VkFunctionDef
    VkScope
    VkFrame
    VkNativeFrame

  Key* = distinct int64

  TypeId* = int32

  TypeDescKind* {.size: sizeof(int8).} = enum
    TdkAny
    TdkNamed
    TdkApplied
    TdkUnion
    TdkFn
    TdkVar

  TypeDesc* = object
    module_path*: string  # "stdlib" for built-ins, "" for local module-scoped types
    case kind*: TypeDescKind
    of TdkAny:
      discard
    of TdkNamed:
      name*: string
    of TdkApplied:
      ctor*: string
      args*: seq[TypeId]
    of TdkUnion:
      members*: seq[TypeId]
    of TdkFn:
      params*: seq[TypeId]
      ret*: TypeId
      effects*: seq[string]
    of TdkVar:
      var_id*: int32

  ModuleTypeRegistry* = ref object
    module_path*: string
    descriptors*: OrderedTable[TypeId, TypeDesc]
    builtin_types*: OrderedTable[string, TypeId]
    named_types*: OrderedTable[string, TypeId]
    applied_types*: OrderedTable[string, TypeId]
    union_types*: OrderedTable[string, TypeId]
    function_types*: OrderedTable[string, TypeId]

  GlobalTypeRegistry* = ref object
    modules*: OrderedTable[string, ModuleTypeRegistry]

  RtImplLoader* = proc(): Value

  RtTypeObj* = ref object
    type_id*: TypeId
    descriptor*: TypeDesc
    constructor*: Value
    initializer*: Value
    methods*: Table[Key, Value]
    constructor_hook*: RtImplLoader
    initializer_hook*: RtImplLoader
    method_hooks*: Table[Key, RtImplLoader]

  RuntimeTypeValueData* = ref object of CustomValue
    runtime_type*: RtTypeObj
    type_descs*: seq[TypeDesc]

  ScopeTracker* = ref object
    parent*: ScopeTracker   # If parent is nil, the scope is the top level scope.
    parent_index_max*: int16
    next_index*: int16      # If next_index is 0, the scope is empty
    mappings*: Table[Key, int16]
    scope_started*: bool    # Track if we've added a ScopeStart instruction
    type_expectation_ids*: seq[TypeId]

  ScopeTrackerSnapshot* = ref object
    next_index*: int16
    parent_index_max*: int16
    scope_started*: bool
    mappings*: seq[(Key, int16)]
    type_expectation_ids*: seq[TypeId]
    parent*: ScopeTrackerSnapshot

  FunctionDefInfo* = ref object
    input*: Value
    scope_tracker*: ScopeTracker
    compiled_body*: Value
    type_expectation_ids*: seq[TypeId]
    return_type_id*: TypeId

  SourceTrace* = ref object
    parent*: SourceTrace
    children*: seq[SourceTrace]
    filename*: string
    line*: int
    column*: int
    child_index*: int

  Gene* = object
    ref_count*: int
    frozen*: bool
    `type`*: Value
    trace*: SourceTrace
    props*: Table[Key, Value]
    children*: seq[Value]

  String* = object
    ref_count*: int
    str*: string

  Document* = ref object
    `type`: Value
    props*: Table[Key, Value]
    children*: seq[Value]
    # references*: References # Uncomment this when it's needed.

  ScopeObj* = object
    ref_count*: int
    tracker*: ScopeTracker
    parent*: Scope
    members*:  seq[Value]
    # Below fields are replacement of seq[Value] to achieve better performance
    #   Have to benchmark to see if it's worth it.
    # vars*: ptr UncheckedArray[Value]
    # vars_in_use*: int16
    # vars_max*: int16

  Scope* = ptr ScopeObj

  ## This is the root of a running application
  Application* = ref object
    name*: string         # Default to base name of command, can be changed, e.g. ($set_app_name "...")
    pkg*: Package         # Entry package for the application
    ns*: Namespace
    cmd*: string
    args*: seq[string]
    main_module*: Module
    # dep_root*: DependencyRoot
    props*: Table[Key, Value]  # Additional properties

    global_ns*     : Value
    gene_ns*       : Value
    genex_ns*      : Value

    object_class*   : Value
    nil_class*      : Value
    void_class*     : Value
    bool_class*     : Value
    int_class*      : Value
    float_class*    : Value
    char_class*     : Value
    string_class*   : Value
    symbol_class*   : Value
    complex_symbol_class*: Value
    array_class*    : Value
    map_class*      : Value
    set_class*      : Value
    gene_class*     : Value
    stream_class*   : Value
    document_class* : Value
    regex_class*    : Value
    range_class*    : Value
    date_class*     : Value
    datetime_class* : Value
    time_class*     : Value
    timezone_class* : Value
    selector_class* : Value
    exception_class*: Value
    class_class*    : Value
    mixin_class*    : Value
    application_class*: Value
    package_class*  : Value
    file_class*     : Value
    dir_class*      : Value
    module_class*   : Value
    namespace_class*: Value
    function_class* : Value
    macro_class*    : Value
    block_class*    : Value
    future_class*   : Value
    generator_class*: Value
    thread_class*   : Value
    thread_message_class* : Value
    thread_message_type_class* : Value
    aspect_class*   : Value
    interface_class*: Value
    adapter_class*  : Value

  Package* = ref object
    dir*: string          # Where the package assets are installed
    adhoc*: bool          # Adhoc package is created when package.gene is not found
    ns*: Namespace
    name*: string
    version*: Value
    license*: Value
    globals*: seq[string] # Global variables defined by this package
    # dependencies*: Table[Key, Dependency]
    homepage*: string
    src_path*: string     # Default to "src"
    test_path*: string    # Default to "tests"
    asset_path*: string   # Default to "assets"
    build_path*: string   # Default to "build"
    load_paths*: seq[string]
    init_modules*: seq[string]    # Modules that should be loaded when the package is used the first time
    props*: Table[Key, Value]  # Additional properties
    # doc*: Document        # content of package.gene

  SourceType* = enum
    StFile
    StVirtualFile # e.g. a file embeded in the source code or an archive file.
    StInline
    StRepl
    StEval

  Module* = ref object
    source_type*: SourceType
    source*: Value
    pkg*: Package         # Package in which the module is defined
    name*: string
    ns*: Namespace
    handle*: LibHandle    # Optional handle for dynamic lib
    props*: Table[Key, Value]  # Additional properties

  Namespace* = ref object
    module*: Module
    parent*: Namespace
    stop_inheritance*: bool  # When set to true, stop looking up for members from parent namespaces
    name*: string
    module_path*: string
    internal_path*: string
    members*: Table[Key, Value]
    on_member_missing*: seq[Value]
    version*: uint64  # Incremented on any mutation for cache invalidation

  Class* = ref object
    parent*: Class
    name*: string
    module_path*: string
    internal_path*: string
    constructor*: Value
    runtime_type*: RtTypeObj
    methods*: Table[Key, Method]
    members*: Table[Key, Value]  # Static members - class acts as namespace
    on_extended*: Value
    # method_missing*: Value
    ns*: Namespace # Class can act like a namespace
    for_singleton*: bool # if it's the class associated with a single object, can not be extended
    version*: uint64  # Incremented when methods are mutated
    has_macro_constructor*: bool  # Track if class has macro constructor for validation
    prop_types*: Table[Key, TypeId]  # property name → TypeId
    prop_type_descs*: seq[TypeDesc]  # type descriptors for property types
    implementations*: Table[Key, Implementation]  # interface name → Implementation

  Method* = ref object
    class*: Class
    name*: string
    callable*: Value
    # public*: bool
    is_macro*: bool
    native_signature_known*: bool
    native_param_types*: seq[(string, Value)]  # (param_name, class_value) for native methods
    native_return_type*: Value                  # class value; NIL means Any

  ## GeneInterface definition - defines the visible face (properties, methods)
  ## An interface specifies what members an adapter must expose.
  GeneInterface* = ref object
    name*: string
    module_path*: string
    internal_path*: string
    methods*: Table[Key, InterfaceMethod]  # Method signatures
    props*: Table[Key, InterfaceProp]      # Property signatures
    ns*: Namespace  # Interface can act like a namespace for static access

  InterfaceMethod* = ref object
    name*: string
    callable*: Value      # Default implementation (can be NIL for abstract)
    type_id*: TypeId      # Return type (NO_TYPE_ID if unspecified)

  InterfaceProp* = ref object
    name*: string
    type_id*: TypeId      # Property type (NO_TYPE_ID if unspecified)
    readonly*: bool       # If true, property cannot be set

  ## Adapter mapping kind - how to map interface members to wrapped object
  AdapterMappingKind* = enum
    AmkRename
    AmkComputed
    AmkHidden

  ## Adapter mapping - how to map interface members to wrapped object
  AdapterMapping* = ref object
    case kind*: AdapterMappingKind
      of AmkRename:        # Rename: redirect to inner property/method
        inner_name*: Key
      of AmkComputed:      # Computed: call function on access
        compute_fn*: Value
      of AmkHidden:        # Hidden: property doesn't exist
        discard

  ## Implementation - connects a class to an interface with mappings
  Implementation* = ref object
    gene_interface*: GeneInterface
    target_class*: Class   # The class being adapted (nil for external adapters on built-ins)
    target_kind*: ImplementationTargetKind
    is_inline*: bool       # True if class natively satisfies the interface
    method_mappings*: Table[Key, AdapterMapping]
    prop_mappings*: Table[Key, AdapterMapping]
    own_data*: Table[Key, Value]  # Adapter's own supplementary data
    ctor*: Value           # Constructor for adapter (if it has own data)

  ImplementationTargetKind* = enum
    ItkClass               # Implementation for a specific class
    ItkBuiltin             # Implementation for a built-in type (Array, Map, etc.)
    ItkAny                 # Implementation for any value

  ## Adapter - wrapper that changes object's visible behavior without mutation
  Adapter* = ref object
    gene_interface*: GeneInterface
    inner*: Value          # The wrapped value
    implementation*: Implementation  # The implementation providing mappings
    own_data*: Table[Key, Value]  # Adapter's own supplementary data

  BoundMethod* = object
    self*: Value
    # class*: Class       # Note that class may be different from method.class
    `method`*: Method

  CallArgType* = enum
    CatInt64
    CatFloat64
    CatValue

  CallReturnType* = enum
    CrtInt64
    CrtFloat64
    CrtValue

  CallDescriptor* = object
    callable*: Value
    argTypes*: seq[CallArgType]
    returnType*: CallReturnType

  FunctionExampleKind* = enum
    FekReturn
    FekAnyReturn
    FekThrows

  FunctionExample* = object
    args*: seq[Value]
    expectation_kind*: FunctionExampleKind
    expected*: Value
    source*: string
    trace*: SourceTrace

  Function* = ref object
    async*: bool
    is_generator*: bool  # True for generator functions
    is_macro_like*: bool  # True for macro-like functions (defined with (fn f!))
    name*: string
    module_path*: string
    internal_path*: string
    intent*: string
    ns*: Namespace  # the namespace of the module wherein this is defined.
    scope_tracker*: ScopeTracker  # the root scope tracker of the function
    parent_scope*: Scope  # this could be nil if parent scope is empty.
    matcher*: RootMatcher
    # matching_hint*: MatchingHint
    body*: seq[Value]
    body_compiled*: CompilationUnit
    native_entry*: pointer  # JIT entry point (NativeFnPtr)
    native_ready*: bool
    native_failed*: bool
    native_return_float*: bool  # True if native return value should be interpreted as float64
    native_return_string*: bool # True if native return value is a String* payload
    native_return_value*: bool  # True if native return value is an already-boxed Value
    native_descriptors*: seq[CallDescriptor]
    pre_conditions*: seq[Value]
    post_conditions*: seq[Value]
    examples*: seq[FunctionExample]
    # ret*: Expr

  Block* = ref object
    frame*: Frame # The frame wherein the block is defined
    ns*: Namespace
    scope_tracker*: ScopeTracker
    matcher*: RootMatcher
    # matching_hint*: MatchingHint
    body*: seq[Value]
    body_compiled*: CompilationUnit

  MatchingMode* {.size: sizeof(int16) .} = enum
    MatchArguments # (fn f [a b] ...)

  # Match the whole input or the first child (if running in ArgumentMode)
  # Can have name, match nothing, or have group of children
  RootMatcher* = ref object
    mode*: MatchingMode
    hint_mode*: MatchingHintMode
    children*: seq[Matcher]
    has_type_annotations*: bool  # True if any child has a type annotation
    type_check*: bool  # Whether runtime type validation is enabled
    return_type_id*: TypeId
    type_descriptors*: seq[TypeDesc]
    type_aliases*: Table[string, TypeId]

  MatchingHintMode* {.size: sizeof(int16) .} = enum
    MhDefault
    MhNone
    MhSimpleData  # E.g. [a b]

  # MatchingHint* = object
  #   mode*: MatchingHintMode

  MatcherKind* = enum
    MatchType
    MatchProp
    MatchData
    MatchLiteral

  Matcher* = ref object
    root*: RootMatcher
    kind*: MatcherKind
    next*: Matcher  # if kind is MatchData and is_splat is true, we may need to check next matcher
    name_key*: Key
    is_prop*: bool
    literal*: Value # if kind is MatchLiteral, this is required
    # match_name*: bool # Match symbol to name - useful for (myif true then ... else ...)
    default_value*: Value
    # default_value_expr*: Expr
    is_splat*: bool
    min_left*: int # Minimum number of args following this
    children*: seq[Matcher]
    type_id*: TypeId
    # required*: bool # computed property: true if splat is false and default value is not given

  # MatchedFieldKind* = enum
  #   MfMissing
  #   MfSuccess
  #   MfTypeMismatch # E.g. map is passed but array or gene is expected

  # MatchResult* = object
  #   fields*: seq[MatchedFieldKind]

  Id* = distinct int64
  Label* = int16

  LoopInfo* = object
    start_label*: Label
    end_label*: Label
    scope_depth*: int16

  MethodAccessMode* = enum
    MamAutoCall
    MamReference

  Compiler* = ref object
    output*: CompilationUnit
    quote_level*: int
    scope_trackers*: seq[ScopeTracker]
    declared_names*: seq[Table[Key, bool]]
    skip_root_scope_start*: bool
    loop_stack*: seq[LoopInfo]
    started_scope_depth*: int16
    tail_position*: bool  # Track if we're in tail position for tail call optimization
    module_init_mode*: bool  # True when compiling module __init__ body
    preserve_root_scope*: bool  # Leave root scope open (module globals)
    local_definitions*: bool  # Treat defs as local bindings (module/ns/class bodies)
    eager_functions*: bool
    trace_stack*: seq[SourceTrace]
    last_error_trace*: SourceTrace
    method_access_mode*: MethodAccessMode
    contract_fn_name*: string
    contract_post_conditions*: seq[Value]
    contract_result_slot*: int16

  InstructionKind* {.size: sizeof(int16).} = enum
    IkNoop
    IkData    # Data for the previous instruction

    IkStart   # start a compilation unit
    IkEnd     # end a compilation unit

    IkScopeStart
    IkScopeEnd

    IkPushValue   # push value to the next slot
    IkPushNil
    IkPushTypeValue
    IkPop
    IkDup         # duplicate top stack element
    IkDup2        # duplicate top two stack elements
    IkDupSecond   # duplicate second element (under top)
    IkSwap        # swap top two stack elements
    IkOver        # copy second element to top: [a b] -> [a b a]
    IkLen         # get length of collection

    IkVar
    IkVarValue
    IkVarResolve
    IkVarResolveInherited
    IkVarAssign
    IkVarAssignInherited

    IkAssign      # TODO: rename to IkSetMemberOnCurrentNS

    IkJump        # unconditional jump
    IkJumpIfFalse

    IkJumpIfMatchSuccess  # Special instruction for argument matching

    IkLoopStart
    IkLoopEnd
    IkContinue    # is added automatically before the loop end
    IkBreak

    IkAdd
    IkAddValue    # args: literal value
    IkVarAddValue # variable + literal value
    IkIncVar      # Increment variable by 1
    IkSub
    IkSubValue
    IkVarSubValue # variable - literal value
    IkDecVar      # Decrement variable by 1
    IkNeg          # Unary negation
    IkMul
    IkVarMulValue # variable * literal value
    IkDiv
    IkVarDivValue # variable / literal value
    IkMod
    IkVarModValue # variable % literal value
    IkPow

    IkLt
    IkLtValue
    IkVarLtValue
    IkLe
    IkGt
    IkGe
    IkEq
    IkNe

    IkAnd
    IkOr
    IkXor
    IkNot
    IkTypeOf
    IkIsType      # (x is Type) — check if value is an instance of type

    IkCreateRange
    IkCreateEnum
    IkEnumAddMember

    IkCompileInit

    IkThrow
    IkTryStart    # mark start of try block
    IkTryEnd      # mark end of try block
    IkCatchStart  # mark start of catch block
    IkCatchEnd    # mark end of catch block
    IkFinally     # mark start of finally block
    IkFinallyEnd  # mark end of finally block
    IkGetClass    # get the class of a value
    IkIsInstance  # check if value is instance of class
    IkCatchRestore # restore exception for next catch clause

    # IkApplication
    # IkPackage
    # IkModule

    IkNamespace
    IkImport
    IkNamespaceStore

    IkFunction
    IkReturn
    IkYield        # Suspend generator and yield value

    IkBlock

    IkClass
    IkSubClass
    IkNew
    IkResolveMethod

    # Interface and Adapter
    IkInterface          # Define an interface
    IkInterfaceMethod    # Define an interface method signature
    IkInterfaceProp      # Define an interface property signature
    IkImplement          # Register implementation (inline or external)
    IkImplementMethod    # Define an external implementation method mapping
    IkAdapter            # Create adapter wrapper (InterfaceName obj)

    IkCallInit
    IkDefineMethod      # Define a method on a class
    IkDefineConstructor # Define a constructor on a class
    IkDefineProp        # Define a typed property on a class
    IkCallSuperMethod   # Call superclass eager method
    IkCallSuperMethodMacro # Call superclass macro method
    IkCallSuperMethodKw # Call superclass method with keyword args (macro inferred from method name suffix)
    IkCallSuperCtor     # Call superclass constructor (eager)
    IkCallSuperCtorMacro # Call superclass constructor (macro)
    IkCallSuperCtorKw   # Call superclass constructor with keyword args (macro inferred from method name suffix)
    IkSuper             # Push the parent method as a bound method (legacy proxy)

    IkMapStart
    IkMapSetProp        # args: key
    IkMapSetPropValue   # args: key, literal value
    IkMapSpread         # Spread map key-value pairs into current map
    IkMapEnd

    IkArrayStart
    IkArrayAddSpread    # Spread add - pop array and push all elements onto stack
    IkArrayEnd
    IkStreamStart
    IkStreamAddSpread
    IkStreamEnd

    IkGeneStart
    IkGeneStartDefault
    IkGeneSetType
    IkGeneSetProp
    IkGeneSetPropValue        # args: key, literal value
    IkGenePropsSpread         # Spread map key-value pairs into gene properties
    IkGeneAddChild            # Normal add (legacy name, same as IkGeneAdd)
    IkGeneAdd                 # Normal add - add single child to gene
    IkGeneAddChildValue       # args: literal value
    IkGeneAddSpread           # Spread add - unpack array and add all elements as children
    IkGeneEnd

    IkRepeatInit
    IkRepeatDecCheck

    # Legacy tail call instruction (kept for compatibility)
    IkTailCall        # Tail call optimization

    # Unified call instructions
    IkUnifiedCall0      # Zero-argument unified call
    IkUnifiedCall1      # Single-argument unified call
    IkUnifiedCall       # Multi-argument unified call
    IkUnifiedCallKw     # Multi-argument unified call with keyword args (arg0=kwCount, arg1=total items)
    IkUnifiedCallDynamic # dynamic-arity unified call (when spreads present)
    IkUnifiedMethodCall0 # Zero-argument method call
    IkUnifiedMethodCall1 # Single-argument method call
    IkUnifiedMethodCall2 # Two-argument method call
    IkUnifiedMethodCall  # Multi-argument method call
    IkUnifiedMethodCallKw # Method call with keyword arguments
    IkDynamicMethodCall   # Dynamic method call: method name evaluated at runtime (stack: obj, method_name, args...)
    IkCallArgsStart      # mark start of call arguments (for dynamic arg counting)
    IkCallArgSpread      # spread argument values onto the stack for calls

    IkResolveSymbol
    IkSetMember
    IkGetMember
    IkGetMemberOrNil    # Get member or return NIL if not found
    IkGetMemberDefault  # Get member or return default value
    IkSetChild
    IkGetChild
    IkGetChildDynamic  # Get child using index from stack

    IkSelf
    IkSetSelf      # Set new self value
    IkRotate       # Rotate top 3 stack elements: [a, b, c] -> [c, a, b]
    IkParse        # Parse string to Gene value
    IkEval         # Evaluate a value
    IkCallerEval   # Evaluate expression in caller's context
    IkRender       # Render a template
    IkAsync        # Wrap value in a Future
    IkAsyncStart   # Start async block with exception handling
    IkAsyncEnd     # End async block and create future
    IkAwait        # Wait for Future to complete
    IkTryUnwrap    # ? operator: unwrap Ok/Some or return early with Err/None

    # Pattern matching
    IkMatchGeneType  # Check if value matches Gene type (arg0=type symbol), pushes bool
    IkGetGeneChild   # Get gene.children[arg0], pushes child value

    # Threading
    IkSpawnThread  # Spawn a new thread (pops: return_value flag, CompilationUnit; pushes: thread ref or future)

    # Superinstructions for common patterns
    IkPushCallPop      # PUSH; CALL; POP (common for void function calls)
    IkLoadCallPop      # LOADK; CALL1; POP
    IkGetLocal         # Optimized local variable access
    IkSetLocal         # Optimized local variable set
    IkAddLocal         # GETLOCAL x; ADD; SETLOCAL y
    IkIncLocal         # Increment local variable
    IkDecLocal         # Decrement local variable
    IkReturnNil        # Common pattern: return nil
    IkReturnTrue       # Common pattern: return true
    IkReturnFalse      # Common pattern: return false
    IkResume
    IkVarLeValue
    IkVarGtValue
    IkVarGeValue
    IkVarEqValue

    # Selector helpers
    IkAssertValue  # Throw if top-of-stack is not a regular value (void/nil/placeholder)
    IkValidateSelectorSegment # Throw unless top-of-stack is string/symbol/int
    IkCreateSelector # Build selector from N segments on stack (arg1 = count)
    IkSetMemberDynamic # Set member using key/index from stack

    # Module helpers
    IkExport         # Export names from module scope into namespace

    # VM builtins
    IkVmDurationStart
    IkVmDuration
    IkVarDestructure  # Matcher-based var destructuring (arg0=[pattern, [target-indices]])

  # Keep the size of Instruction to 2*8 = 16 bytes
  Instruction* = object
    kind*: InstructionKind
    label*: Label
    arg1*: int32
    arg0*: Value

  VarIndex* = object
    local_index*: int32
    parent_index*: int32

  CompilationUnitKind* {.size: sizeof(int8).} = enum
    CkDefault
    CkFunction
    CkBlock
    CkModule
    CkInit      # namespace / class / object initialization
    CkInline    # evaluation during execution

  ModuleTypeKind* {.size: sizeof(int8).} = enum
    MtkUnknown
    MtkNamespace
    MtkClass
    MtkEnum
    MtkInterface
    MtkAlias
    MtkObject

  ModuleTypeNode* = ref object
    name*: string
    kind*: ModuleTypeKind
    children*: seq[ModuleTypeNode]

  CompilationUnit* = ref object
    id*: Id
    kind*: CompilationUnitKind
    module_path*: string
    skip_return*: bool
    type_check*: bool  # Whether runtime type validation is enabled
    matcher*: RootMatcher
    instructions*: seq[Instruction]
    trace_root*: SourceTrace
    instruction_traces*: seq[SourceTrace]
    labels*: Table[Label, int]
    inline_caches*: seq[InlineCache]  # Inline caches indexed by PC
    module_exports*: seq[string]
    module_imports*: seq[string]
    module_types*: seq[ModuleTypeNode]
    type_descriptors*: seq[TypeDesc]
    type_registry*: ModuleTypeRegistry  # Phase 4: module-scoped type registry
    type_aliases*: Table[string, TypeId]

  # Used by the compiler to keep track of scopes and variables
  #
  # Scopes should be created on demand (when the first variable is defined)
  # Scopes should be destroyed when they are no longer needed
  # Scopes should stay alive when they are referenced by child scopes
  # Function/macro/block/if/loop/switch/do/eval inherit parent scope
  # Class/namespace do not inherit parent scope

  Address* = object
    cu*: CompilationUnit
    pc*: int

  # Virtual machine and its data can be separated however it doesn't
  # bring much benefit. So we keep them together.
  ExceptionHandler* = object
    catch_pc*: int
    finally_pc*: int
    frame*: Frame
    scope*: Scope
    cu*: CompilationUnit
    saved_value*: Value  # Value to restore after finally block
    has_saved_value*: bool
    in_finally*: bool

  FunctionProfile* = object
    name*: string
    call_count*: int64
    total_time*: float64  # Total time in seconds
    self_time*: float64   # Time excluding sub-calls
    min_time*: float64
    max_time*: float64

  InstructionProfile* = object
    count*: int64
    total_time*: float64  # Total time in seconds
    min_time*: float64
    max_time*: float64

  # Inline cache for symbol resolution
  InlineCache* = object
    version*: uint64      # Namespace version when cached
    value*: Value         # Cached value
    ns*: Namespace        # Namespace where value was found
    class*: Class         # Cached class for method lookup
    class_version*: uint64
    cached_method*: Method       # Cached method reference

  ThreadMetadata* = object
    id*: int
    secret*: int              # Random token for validation
    state*: ThreadState
    in_use*: bool
    parent_id*: int           # Parent thread ID
    parent_secret*: int       # Parent thread secret
    # Note: thread and channel fields will be added in vm/thread.nim module
    # which will properly import std/channels and std/locks with --threads:on

  NativeCompileTier* {.size: sizeof(int8).} = enum
    NctNever
    NctGuarded
    NctFullyTyped

  VirtualMachine* = object
    cu*: CompilationUnit
    pc*: int
    frame*: Frame
    trace*: bool
    exec_depth*: int           # Tracks nested exec() invocations
    exec_handler_base_stack*: seq[int]  # Exception handler base per exec() depth
    exception_handlers*: seq[ExceptionHandler]
    current_exception*: Value
    repl_exception*: Value
    repl_on_error*: bool
    repl_active*: bool
    repl_skip_on_throw*: bool
    repl_ran*: bool
    repl_resume_value*: Value
    current_generator*: GeneratorObj  # Currently executing generator
    symbols*: ptr ManagedSymbols  # Pointer to global symbol table
    # Profiling
    profiling*: bool
    profile_data*: Table[string, FunctionProfile]
    profile_stack*: seq[tuple[name: string, start_time: float64]]
    duration_start_us*: float64
    # Instruction profiling
    instruction_profiling*: bool
    instruction_profile*: array[InstructionKind, InstructionProfile]
    # Async/Event Loop support
    event_loop_counter*: int  # Counter for periodic event loop polling (poll every N instructions)
    poll_enabled*: bool       # Set when async/thread work is pending; skip polling otherwise
    pending_futures*: seq[FutureObj]  # List of futures with pending Nim futures
    pending_pubsub_events*: seq[PubSubEvent]
    pubsub_payloadless_index*: Table[string, int]
    pubsub_combinable_index*: Table[string, seq[int]]
    pubsub_subscriptions*: Table[int, PubSubSubscription]
    pubsub_subscribers_by_event*: Table[string, seq[int]]
    next_pubsub_subscription_id*: int
    pubsub_draining*: bool
    # Thread support
    thread_futures*: Table[int, FutureObj]  # Map message_id -> future for spawn_return
    message_callbacks*: seq[Value]  # List of callbacks for incoming messages
    thread_local_ns*: Namespace  # Thread-local namespace for $thread, $main_thread, etc.
    # Scheduler mode
    scheduler_running*: bool  # Set to true when run_forever is active, false to stop
    aop_contexts*: seq[AopContext]  # Stack of active around advice contexts
    missing_method_depth*: int  # Recursion guard for on_method_missing dispatch
    native_tier*: NativeCompileTier  # Native dispatch policy
    native_code*: bool  # Enable native code execution when available
    type_check*: bool  # Whether runtime type validation is enabled (set from --no-type-check)
    contracts_enabled*: bool  # Whether runtime pre/post contract checks are enabled

  NativeContext* = object
    vm*: ptr VirtualMachine
    trampoline*: pointer
    descriptors*: ptr UncheckedArray[CallDescriptor]
    descriptor_count*: int32

  VmCallback* = proc() {.gcsafe.}

  ReplOnThrowCallback* = proc(vm: ptr VirtualMachine, exception_value: Value): Value {.nimcall.}
  
  # Scheduler callback - extensions register poll handlers here
  SchedulerCallback* = proc(vm: ptr VirtualMachine) {.gcsafe.}

  FrameKind* {.size: sizeof(int16).} = enum
    FkPristine      # not initialized
    FrModule
    FrBody          # namespace/class/... body
    FrEval
    FkFunction
    FkMacro
    FkBlock
    # FkNativeFn
    # FkNativeMacro
    FkNew
    FkMethod
    FkMacroMethod
    # FkNativeMethod
    # FkNativeMacroMethod
    # FkSuper
    # FkMacroSuper
    # FkBoundMethod
    # FkBoundNativeMethod

  CallBaseStack* = object
    data*: seq[uint16]

  FrameObj* = object
    ref_count*: int
    kind*: FrameKind
    caller_frame*: Frame
    caller_address*: Address
    caller_context*: Frame  # For $caller_eval in macros
    ns*: Namespace
    scope*: Scope
    target*: Value  # target of the invocation
    args*: Value
    stack*: array[256, Value]
    stack_index*: uint16
    stack_max*: uint16  # Track highest stack position for GC cleanup
    call_bases*: CallBaseStack
    collection_bases*: CallBaseStack
    from_exec_function*: bool  # Set when frame is created by exec_function
    is_generator*: bool  # Set when executing in generator context

  Frame* = ptr FrameObj

  GeneratorObj* = ref object
    function*: Function          # The generator function definition
    state*: GeneratorState       # Current execution state
    frame*: Frame                # Saved execution frame
    cu*: CompilationUnit         # Saved compilation unit
    pc*: int                     # Program counter position
    scope*: Scope                # Captured scope
    stack*: seq[Value]           # Saved stack state
    done*: bool                  # Whether generator is exhausted
    has_peeked*: bool            # Whether we have a peeked value
    peeked_value*: Value         # The peeked value from has_next

  NativeFrameKind* {.size: sizeof(int16).} = enum
    NfFunction
    NfMacro
    NfMethod
    NfMacroMethod

  # NativeFrame is used to call native functions etc
  NativeFrame* = ref object
    kind*: NativeFrameKind
    target*: Value
    args*: Value

  # InvocationKind* {.size: sizeof(int16).} = enum
  #   IvDefault   # E.g. when the gene type is not invokable
  #   IvFunction
  #   IvMacro
  #   IvBlock
  #   IvNativeFn
  #   IvNew
  #   IvMethod
  #   # IvSuper
  #   IvBoundMethod

  # Invocation* = ref object
  #   case kind*: InvocationKind
  #     of IvFunction:
  #       fn*: Value
  #       fn_scope*: Scope
  #     of IvMacro:
  #       `macro`*: Value
  #       macro_scope*: Scope
  #     of IvBlock:
  #       `block`*: Value
  #       block_scope*: Scope
  #       compile_fn*: Value
  #       compile_fn_scope*: Scope
  #     of IvNativeFn:
  #       native_fn*: Value
  #       native_fn_args*: Value
  #     else:
  #       data: Value

  # No symbols should be removed.
  ManagedSymbols* = object
    store*: seq[string]
    map*:  Table[string, int64]

  Exception* = object of CatchableError
    instance*: Value  # instance of Gene exception class

  NotDefinedException* = object of Exception

  # Types related to command line argument parsing
  ArgumentError* = object of Exception

  NativeFn* = proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.}

  # Native macro function - receives unevaluated Gene AST and caller frame for context
  # gene_value: The raw Gene value with unevaluated children (args)
  # caller_frame: The frame from which the macro was called (for $caller_eval-like evaluation)
  NativeMacroFn* = proc(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe, nimcall.}

  # Unified Callable System
  CallableKind* = enum
    CkFunction          # Regular Gene function
    CkNativeFunction    # Nim function
    CkMethod            # Gene method
    CkNativeMethod      # Nim method
    CkBlock             # Lambda/block

  CallableFlags* = enum
    CfEvaluateArgs      # Should arguments be evaluated?
    CfNeedsSelf         # Does this callable need a self parameter?
    CfIsNative          # Is this implemented in Nim?
    CfIsMacro           # Is this a macro (unevaluated args)?
    CfIsMethod          # Is this a method (needs receiver)?
    CfCanInline         # Can this be inlined?
    CfIsPure            # Is this a pure function (no side effects)?

  Callable* = ref object
    case kind*: CallableKind
    of CkFunction, CkMethod:
      fn*: Function
    of CkNativeFunction, CkNativeMethod:
      native_fn*: NativeFn
    of CkBlock:
      block_fn*: Block

    flags*: set[CallableFlags]
    arity*: int                    # Number of required arguments
    name*: string                  # For debugging and profiling

include ./reference_types

include ./memory

include ./descriptors

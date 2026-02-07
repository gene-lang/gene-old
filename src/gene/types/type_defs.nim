# Forward declarations for new types
import tables, sets, asyncdispatch, dynlib

const
  TC_BINDING_TYPE_KEY* = "__tc_binding_type"
  TC_BINDING_TYPE_ID_KEY* = "__tc_binding_type_id"
  TC_PARAM_TYPES_KEY* = "__tc_param_types"
  TC_PARAM_TYPE_IDS_KEY* = "__tc_param_type_ids"
  TC_RETURN_TYPE_KEY* = "__tc_return_type"
  TC_RETURN_TYPE_ID_KEY* = "__tc_return_type_id"
  TC_EFFECTS_KEY* = "__tc_effects"
  NO_TYPE_ID* = -1'i32

type
  Value* {.bycopy.} = object
    ## NaN-boxed value with automatic reference counting
    ## Size: 8 bytes (same as distinct int64)
    ## Enables =copy/=destroy hooks for GC
    raw*: uint64

  CustomValue* = ref object of RootObj

  EnumDef* = ref object
    name*: string
    members*: Table[string, EnumMember]

  EnumMember* = ref object
    parent*: Value  # The enum this member belongs to
    name*: string
    value*: int

  FutureState* = enum
    FsPending
    FsSuccess
    FsFailure

  FutureObj* = ref object
    state*: FutureState
    value*: Value              # Result value or exception
    success_callbacks*: seq[Value]  # Success callback functions
    failure_callbacks*: seq[Value]  # Failure callback functions
    nim_future*: Future[Value]  # Underlying Nim async future (nil for sync futures)

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

  # AOP Aspect type
  AopAfterAdvice* = object
    callable*: Value
    replace_result*: bool

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

  ScopeTracker* = ref object
    parent*: ScopeTracker   # If parent is nil, the scope is the top level scope.
    parent_index_max*: int16
    next_index*: int16      # If next_index is 0, the scope is empty
    mappings*: Table[Key, int16]
    scope_started*: bool    # Track if we've added a ScopeStart instruction
    type_expectations*: seq[string]
    type_expectation_ids*: seq[TypeId]

  ScopeTrackerSnapshot* = ref object
    next_index*: int16
    parent_index_max*: int16
    scope_started*: bool
    mappings*: seq[(Key, int16)]
    type_expectations*: seq[string]
    type_expectation_ids*: seq[TypeId]
    parent*: ScopeTrackerSnapshot

  FunctionDefInfo* = ref object
    input*: Value
    scope_tracker*: ScopeTracker
    compiled_body*: Value

  SourceTrace* = ref object
    parent*: SourceTrace
    children*: seq[SourceTrace]
    filename*: string
    line*: int
    column*: int
    child_index*: int

  Gene* = object
    ref_count*: int
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
    members*: Table[Key, Value]
    on_member_missing*: seq[Value]
    version*: uint64  # Incremented on any mutation for cache invalidation

  Class* = ref object
    parent*: Class
    name*: string
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

  Method* = ref object
    class*: Class
    name*: string
    callable*: Value
    # public*: bool
    is_macro*: bool

  BoundMethod* = object
    self*: Value
    # class*: Class       # Note that class may be different from method.class
    `method`*: Method

  CallArgType* = enum
    CatInt64
    CatFloat64

  CallReturnType* = enum
    CrtInt64
    CrtFloat64
    CrtValue

  CallDescriptor* = object
    callable*: Value
    argTypes*: seq[CallArgType]
    returnType*: CallReturnType

  Function* = ref object
    async*: bool
    is_generator*: bool  # True for generator functions
    is_macro_like*: bool  # True for macro-like functions (defined with (fn f!))
    name*: string
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
    native_descriptors*: seq[CallDescriptor]
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
    MatchExpression # (match [a b] input): a and b will be defined
    MatchAssignment # ([a b] = input): a and b must be defined first

  # Match the whole input or the first child (if running in ArgumentMode)
  # Can have name, match nothing, or have group of children
  RootMatcher* = ref object
    mode*: MatchingMode
    hint_mode*: MatchingHintMode
    children*: seq[Matcher]
    has_type_annotations*: bool  # True if any child has a type annotation
    return_type_name*: string  # Return type annotation from -> (e.g. "Int", "Float")
    return_type_id*: TypeId
    type_descriptors*: seq[TypeDesc]

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
    type_name*: string  # Runtime type annotation (e.g. "Int", "String", "Any")
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

  InstructionKind* {.size: sizeof(int16).} = enum
    IkNoop
    IkData    # Data for the previous instruction

    IkStart   # start a compilation unit
    IkEnd     # end a compilation unit

    IkScopeStart
    IkScopeEnd

    IkPushValue   # push value to the next slot
    IkPushNil
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
    IkNot

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

    IkCallInit
    IkDefineMethod      # Define a method on a class
    IkDefineConstructor # Define a constructor on a class
    IkCallSuperMethod   # Call superclass eager method
    IkCallSuperMethodMacro # Call superclass macro method
    IkCallSuperCtor     # Call superclass constructor (eager)
    IkCallSuperCtorMacro # Call superclass constructor (macro)
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
    IkAssertNotVoid  # Throw if top-of-stack is VOID (selector not found)
    IkCreateSelector # Build selector from N segments on stack (arg1 = count)
    IkSetMemberDynamic # Set member using key/index from stack

    # Module helpers
    IkExport         # Export names from module scope into namespace

    # VM builtins
    IkVmDurationStart
    IkVmDuration

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
    skip_return*: bool
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
    # Thread support
    thread_futures*: Table[int, FutureObj]  # Map message_id -> future for spawn_return
    message_callbacks*: seq[Value]  # List of callbacks for incoming messages
    thread_local_ns*: Namespace  # Thread-local namespace for $thread, $main_thread, etc.
    # Scheduler mode
    scheduler_running*: bool  # Set to true when run_forever is active, false to stop
    aop_contexts*: seq[AopContext]  # Stack of active around advice contexts
    native_code*: bool  # Enable native code execution when available

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
        regex_match_start*: int64
        regex_match_end*: int64
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
        dt_timezone*: int16
      of VkTime:
        time_hour*: int8
        time_minute*: int8
        time_second*: int8
        time_microsecond*: int32
      of VkTimezone:
        tz_offset*: int16
        tz_name*: string

      # Collection types
      of VkSet:
        set*: HashSet[Value]
      of VkMap:
        map*: Table[Key, Value]
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
    arr*: seq[Value]

  MapObj* = object
    ref_count*: int
    map*: Table[Key, Value]

  InstanceObj* = object
    ref_count*: int
    instance_class*: Class
    instance_props*: Table[Key, Value]

# Global list of scheduler poll callbacks - extensions register handlers here
var scheduler_callbacks*: seq[SchedulerCallback] = @[]

var repl_on_throw_callback*: ReplOnThrowCallback = nil

proc register_scheduler_callback*(callback: SchedulerCallback) =
  ## Register a callback to be called during run_forever scheduler loop.
  ## Extensions like HTTP use this to process pending requests.
  scheduler_callbacks.add(callback)

#################### GC Infrastructure (must be after type defs, before Value usage) #################

# NaN Boxing constants
const PAYLOAD_MASK* = 0x0000_FFFF_FFFF_FFFFu64
const TAG_SHIFT* = 48

# Primary type tags in NaN space (reorganized for GC)
# DESIGN: All managed types (need ref-counting) have tags >= 0xFFF8
#         All non-managed types (immediate/global) have tags < 0xFFF8

# Non-managed types (< 0xFFF8)
const SPECIAL_TAG*   = 0xFFF1_0000_0000_0000u64
const SMALL_INT_TAG* = 0xFFF2_0000_0000_0000u64
const SYMBOL_TAG*    = 0xFFF3_0000_0000_0000u64
const POINTER_TAG*   = 0xFFF4_0000_0000_0000u64

# Managed types (>= 0xFFF8)
const ARRAY_TAG*     = 0xFFF8_0000_0000_0000u64
const MAP_TAG*       = 0xFFF9_0000_0000_0000u64
const INSTANCE_TAG*  = 0xFFFA_0000_0000_0000u64
const GENE_TAG*      = 0xFFFB_0000_0000_0000u64
const REF_TAG*       = 0xFFFC_0000_0000_0000u64
const STRING_TAG*    = 0xFFFD_0000_0000_0000u64

# Fast managed check
template isManaged*(v: Value): bool =
  ## Returns true if value is a managed (heap-allocated, ref-counted) type
  ## All managed types have tags >= 0xFFF8
  (v.raw and 0xFFF8_0000_0000_0000'u64) == 0xFFF8_0000_0000_0000'u64

# Destroy helpers
template destroyAndDealloc[T](p: ptr T) =
  ## Safely destroy and deallocate a heap object
  if p != nil:
    reset(p[])   # Run Nim destructors on all fields
    dealloc(p)   # Free memory

proc destroy_string(s: ptr String) =
  destroyAndDealloc(s)

proc destroy_array(arr: ptr ArrayObj) =
  destroyAndDealloc(arr)

proc destroy_map(m: ptr MapObj) =
  destroyAndDealloc(m)

proc destroy_gene(g: ptr Gene) =
  destroyAndDealloc(g)

proc destroy_instance(inst: ptr InstanceObj) =
  destroyAndDealloc(inst)

proc destroy_reference(ref_obj: ptr Reference) =
  destroyAndDealloc(ref_obj)

# Core GC operations
proc retainManaged*(raw: uint64) {.gcsafe.} =
  ## Increment reference count for a managed value
  if raw == 0:
    return

  let tag = raw shr 48
  case tag:
    of 0xFFF8:  # ARRAY_TAG
      let arr = cast[ptr ArrayObj](raw and PAYLOAD_MASK)
      if arr != nil:
        # atomicInc(arr.ref_count)
        arr.ref_count.inc()
    of 0xFFF9:  # MAP_TAG
      let m = cast[ptr MapObj](raw and PAYLOAD_MASK)
      if m != nil:
        # atomicInc(m.ref_count)
        m.ref_count.inc()
    of 0xFFFA:  # INSTANCE_TAG
      let inst = cast[ptr InstanceObj](raw and PAYLOAD_MASK)
      if inst != nil:
        # atomicInc(inst.ref_count)
        inst.ref_count.inc()
    of 0xFFFB:  # GENE_TAG
      let g = cast[ptr Gene](raw and PAYLOAD_MASK)
      if g != nil:
        # atomicInc(g.ref_count)
        g.ref_count.inc()
    of 0xFFFC:  # REF_TAG
      let ref_obj = cast[ptr Reference](raw and PAYLOAD_MASK)
      if ref_obj != nil:
        # atomicInc(ref_obj.ref_count)
        ref_obj.ref_count.inc()
    of 0xFFFD:  # STRING_TAG
      let s = cast[ptr String](raw and PAYLOAD_MASK)
      if s != nil:
        # atomicInc(s.ref_count)
        s.ref_count.inc()
    else:
      discard

proc releaseManaged*(raw: uint64) {.gcsafe.} =
  ## Decrement reference count, destroy at 0
  ## CRITICAL: Must validate pointer before dereferencing to avoid SIGSEGV on garbage
  if raw == 0:
    return

  let tag = raw shr 48

  # Validate tag is exactly in managed range
  if tag < 0xFFF8 or tag > 0xFFFD:
    return

  # Validate payload is not null
  let payload = raw and PAYLOAD_MASK
  if payload == 0:
    return

  # Validate pointer looks reasonable (not obviously garbage)
  # Check if it's aligned (pointers should be 8-byte aligned on most platforms)
  if (payload and 0x7) != 0:
    return  # Not 8-byte aligned, likely garbage

  # We cannot safely validate ref_count without dereferencing,
  # and try-except doesn't catch SIGSEGV in Nim.
  # Our best defense is tag + alignment validation above.
  # Unfortunately, this means we may still crash on cleverly-aligned garbage.

  case tag:
    of 0xFFF8:  # ARRAY_TAG
      let arr = cast[ptr ArrayObj](payload)
      let old_count = atomicDec(arr.ref_count)
      if old_count == 1:
        destroy_array(arr)
    of 0xFFF9:  # MAP_TAG
      let m = cast[ptr MapObj](payload)
      let old_count = atomicDec(m.ref_count)
      if old_count == 1:
        destroy_map(m)
    of 0xFFFA:  # INSTANCE_TAG
      let inst = cast[ptr InstanceObj](payload)
      let old_count = atomicDec(inst.ref_count)
      if old_count == 1:
        destroy_instance(inst)
    of 0xFFFB:  # GENE_TAG
      let g = cast[ptr Gene](payload)
      let old_count = atomicDec(g.ref_count)
      if old_count == 1:
        destroy_gene(g)
    of 0xFFFC:  # REF_TAG
      let ref_obj = cast[ptr Reference](payload)
      let old_count = atomicDec(ref_obj.ref_count)
      if old_count == 1:
        destroy_reference(ref_obj)
    of 0xFFFD:  # STRING_TAG
      let s = cast[ptr String](payload)
      let old_count = atomicDec(s.ref_count)
      if old_count == 1:
        destroy_string(s)
    else:
      discard

# Lifecycle hooks for automatic GC

proc `=default`*(v: var Value) {.inline.} =
  ## Default constructor - initializes all Values to NIL
  ## This ensures no uninitialized garbage, making =copy safe
  v.raw = 0

proc `=destroy`*(v: var Value) =
  ## Called when Value goes out of scope
  ## Decrements ref count for managed types
  if isManaged(v):
    releaseManaged(v.raw)

proc `=copy`*(dest: var Value; src: Value) =
  ## Called on assignment: dest = src
  ## Must destroy old dest, copy bits, then retain new value

  # Release old dest value if it's a managed type
  if isManaged(dest):
    releaseManaged(dest.raw)

  # Bitwise copy
  dest.raw = src.raw

  # Retain new value (if managed)
  if isManaged(src):
    retainManaged(src.raw)

proc `=sink`*(dest: var Value; src: Value) =
  ## Called on move/sink: dest = move(src)
  ## Transfers ownership without retain/release

  # Release old dest value if it's a managed type
  if isManaged(dest):
    releaseManaged(dest.raw)

  # Transfer ownership (no retain - src won't be destroyed)
  dest.raw = src.raw

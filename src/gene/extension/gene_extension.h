/**
 * Gene VM C Extension API
 *
 * This header provides the C interface for creating Gene VM extensions.
 * Extensions must export one function:
 *   - int32_t gene_init(GeneHostAbi* host)
 */

#ifndef GENE_EXTENSION_H
#define GENE_EXTENSION_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========== Opaque Types ========== */

/**
 * VirtualMachine - The Gene VM instance
 * Opaque pointer - internal structure not exposed to extensions
 */
typedef struct VirtualMachine VirtualMachine;

/**
 * Namespace - A Gene namespace (collection of key-value pairs)
 * Opaque pointer - use gene_namespace_* functions to manipulate
 */
typedef struct Namespace Namespace;

/* ========== Value Type ========== */

/**
 * Value - A Gene value (NaN-boxed 64-bit value)
 * Can represent integers, floats, strings, objects, etc.
 * Use gene_to_* and gene_from_* functions to convert
 */
typedef uint64_t Value;

/**
 * Key - A symbol key for namespace lookups
 * Opaque 64-bit value - use gene_to_key() to create
 */
typedef uint64_t Key;

/* ========== ABI Types ========== */

#define GENE_EXT_ABI_VERSION 8u

typedef enum GeneExtStatus {
    GENE_EXT_OK = 0,
    GENE_EXT_ERR = 1,
    GENE_EXT_ABI_MISMATCH = 2,
    GENE_EXT_OVERLOADED = 3,
    GENE_EXT_STOPPED = 4,
    GENE_EXT_INVALID_TARGET = 5,
    GENE_EXT_LIMIT_EXCEEDED = 6
} GeneExtStatus;

typedef void (*GeneHostLogFn)(int32_t level, const char* logger_name, const char* message);
typedef void (*GeneHostSchedulerTickFn)(void* vm_user_data, void* callback_user_data);
typedef int32_t (*GeneHostRegisterSchedulerCallbackFn)(GeneHostSchedulerTickFn callback, void* callback_user_data);
typedef int32_t (*GeneHostRegisterPortFn)(const char* name, int32_t kind, int32_t pool_size,
                                          Value handler, Value init_state, Value* out_handle);
typedef int32_t (*GeneHostRegisterPortWithOptionsFn)(const char* name, int32_t kind, int32_t pool_size,
                                                     Value handler, Value init_state,
                                                     int32_t queue_limit, Value* out_handle);
typedef int32_t (*GeneHostCallPortFn)(Value port_handle, Value msg, int32_t timeout_ms,
                                      Value* out_value);
typedef int32_t (*GeneHostCallPortAsyncFn)(Value port_handle, Value msg,
                                           Value* out_future);
typedef int32_t (*GeneHostActorReplyFn)(Value ctx, Value payload);
typedef int32_t (*GeneHostActorReplySerializedFn)(Value ctx, const char* payload_ser);
typedef int32_t (*GeneHostPollVmFn)(void* vm_user_data);

/**
 * Host ABI passed to gene_init.
 */
typedef struct GeneHostAbi {
    uint32_t abi_version;
    void* user_data;               /* host-provided context (VirtualMachine*) */
    uint64_t app_value;            /* host App value */
    void* symbols_data;            /* host symbol table pointer */
    GeneHostLogFn log_message_fn;  /* optional host logging callback */
    GeneHostRegisterSchedulerCallbackFn register_scheduler_callback_fn; /* optional scheduler registration hook */
    GeneHostRegisterPortFn register_port_fn; /* optional extension port registration hook */
    GeneHostRegisterPortWithOptionsFn register_port_with_options_fn; /* optional extension port registration with queue limits */
    GeneHostCallPortFn call_port_fn;         /* optional extension port call hook */
    GeneHostCallPortAsyncFn call_port_async_fn; /* optional async extension port call hook */
    GeneHostActorReplyFn actor_reply_fn; /* optional host actor reply hook */
    GeneHostActorReplySerializedFn actor_reply_serialized_fn; /* optional host actor reply hook for serialized payloads */
    GeneHostPollVmFn poll_vm_fn; /* optional host VM/event-loop poll hook */
    Namespace** result_namespace;  /* extension sets this to its namespace */
} GeneHostAbi;

/* ========== Function Types ========== */

/**
 * NativeFn - Function pointer type for native functions
 *
 * @param vm - The VM instance
 * @param args - Array of argument values
 * @param arg_count - Number of arguments
 * @param has_keyword_args - Whether keyword arguments are present
 * @return Value - The return value
 */
typedef Value (*NativeFn)(VirtualMachine* vm, Value* args,
                          int arg_count, bool has_keyword_args);

typedef int32_t (*GeneExtensionInitFn)(GeneHostAbi* host);

/* ========== Value Conversion Functions ========== */

/**
 * Convert C int64 to Gene Value
 */
extern Value gene_to_value_int(int64_t i);

/**
 * Convert C double to Gene Value
 */
extern Value gene_to_value_float(double f);

/**
 * Convert C string to Gene Value
 * Note: String is copied, caller retains ownership of input
 */
extern Value gene_to_value_string(const char* s);

/**
 * Convert a length-delimited UTF-8 buffer to Gene Value
 * Returns NIL on NULL input, negative length, or invalid UTF-8
 */
extern Value gene_to_value_string_n(const char* s, int64_t len);

/**
 * Convert C bool to Gene Value
 */
extern Value gene_to_value_bool(bool b);

/**
 * Get NIL value
 */
extern Value gene_nil(void);

/**
 * Convert Gene Value to C int64
 * Returns 0 if value is not an integer
 */
extern int64_t gene_to_int(Value v);

/**
 * Convert Gene Value to C double
 * Returns 0.0 if value is not a number
 */
extern double gene_to_float(Value v);

/**
 * Convert Gene Value to C string
 * Returns NULL if value is not a string or contains an embedded NUL byte
 * Note: Returned pointer is owned by Gene VM, do not free
 */
extern const char* gene_to_string(Value v);

/**
 * Return the number of UTF-8 bytes in a Gene string
 * Returns 0 if value is not a string
 */
extern int64_t gene_string_len(Value v);

/**
 * Convert Gene Value to C bool
 * Returns false for NIL and false, true for everything else
 */
extern bool gene_to_bool(Value v);

/**
 * Check if value is NIL
 */
extern bool gene_is_nil(Value v);

/* ========== Namespace Functions ========== */

/**
 * Create a new namespace with given name
 */
extern Namespace* gene_new_namespace(const char* name);

/**
 * Set a value in a namespace
 *
 * @param ns - The namespace
 * @param key - The key (symbol name as string)
 * @param value - The value to set
 */
extern void gene_namespace_set(Namespace* ns, const char* key, Value value);

/**
 * Get a value from a namespace
 * Returns NIL if key not found
 */
extern Value gene_namespace_get(Namespace* ns, const char* key);

/* ========== Function Wrapping ========== */

/**
 * Wrap a C function pointer as a Gene Value
 * The returned Value can be stored in a namespace
 */
extern Value gene_wrap_native_fn(NativeFn fn);

/* ========== Argument Helpers ========== */

/**
 * Get positional argument at index
 * Handles keyword arguments correctly
 * Returns NIL if index out of bounds
 */
extern Value gene_get_arg(Value* args, int arg_count, bool has_keyword_args, int index);

/* ========== Error Handling ========== */

/**
 * Raise an exception with given message
 * Does not return
 */
extern void gene_raise_error(const char* message);

#ifdef __cplusplus
}
#endif

#endif /* GENE_EXTENSION_H */

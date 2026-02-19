#ifndef GENE_API_H
#define GENE_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GENE_ABI_VERSION 1u

typedef uint64_t AirValue;

typedef enum AirNativeStatus {
  AIR_NATIVE_OK = 0,
  AIR_NATIVE_ERR = 1,
  AIR_NATIVE_TRAP = 2
} AirNativeStatus;

typedef struct AirNativeCtx {
  void* vm;
  uint64_t task_id;
  uint64_t caps_mask;
  uint64_t trace_id;
} AirNativeCtx;

typedef AirNativeStatus (*AirNativeFn)(
  AirNativeCtx* ctx,
  const AirValue* args,
  uint16_t argc,
  AirValue* out_result,
  AirValue* out_error
);

typedef struct AirNativeRegistration {
  const char* name;
  int16_t arity;
  uint64_t caps_mask;
  AirNativeFn fn;
} AirNativeRegistration;

typedef int32_t (*GeneRegisterNativeFn)(const AirNativeRegistration* reg, void* user_data);

typedef struct GeneHostApi {
  uint32_t abi_version;
  void* user_data;
  GeneRegisterNativeFn register_native;
} GeneHostApi;

typedef int32_t (*GeneExtensionInitFn)(GeneHostApi* host);

/*
 * Memory safety contract:
 * - `args` are borrowed and valid only during the call.
 * - `out_result` and `out_error` return owned `AirValue` handles.
 * - Extensions must not retain raw VM pointers across suspension points.
 */

#ifdef __cplusplus
}
#endif

#endif /* GENE_API_H */

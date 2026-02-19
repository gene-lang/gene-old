#include "../../include/gene_api.h"

static AirNativeStatus ext_add(
  AirNativeCtx* ctx,
  const AirValue* args,
  uint16_t argc,
  AirValue* out_result,
  AirValue* out_error
) {
  (void)ctx;
  (void)out_error;
  if (argc < 1) {
    return AIR_NATIVE_ERR;
  }
  *out_result = args[0];
  return AIR_NATIVE_OK;
}

int32_t gene_extension_init(GeneHostApi* host) {
  if (host == 0 || host->register_native == 0 || host->abi_version != GENE_ABI_VERSION) {
    return -1;
  }

  AirNativeRegistration reg;
  reg.name = "ext_id";
  reg.arity = 1;
  reg.caps_mask = 0;
  reg.fn = ext_add;
  return host->register_native(&reg, host->user_data);
}

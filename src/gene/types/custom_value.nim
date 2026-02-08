import ./type_defs
import ./core

#################### Custom Value #################

proc new_custom_value*(custom_class: Class, data: CustomValue): Value =
  ## Create a VkCustom value backed by a Gene class.
  if custom_class.is_nil:
    raise new_exception(type_defs.Exception, "Custom values require a class")
  let ref_val = new_ref(VkCustom)
  ref_val.custom_class = custom_class
  ref_val.custom_data = data
  ref_val.to_ref_value()

proc get_custom_data*(val: Value, context: string = "Custom value expected"): CustomValue =
  ## Retrieve the CustomValue payload from a VkCustom value.
  if val.kind != VkCustom:
    raise new_exception(type_defs.Exception, context)
  if val.ref.custom_data.is_nil:
    raise new_exception(type_defs.Exception, context & ": missing payload")
  val.ref.custom_data

import times

import ../types
when defined(gene_wasm):
  import ../wasm_host_abi
import ./classes

proc init_date_classes*(object_class: Class) =
  var r: ptr Reference
  let date_class = new_class("Date")
  date_class.parent = object_class
  date_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = date_class
  App.app.date_class = r.to_ref_value()
  App.app.gene_ns.ns["Date".to_key()] = App.app.date_class
  App.app.global_ns.ns["Date".to_key()] = App.app.date_class

  proc date_year(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.year requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.year must be called on a date")
    self_val.ref.date_year.int.to_value()

  proc date_month(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.month requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.month must be called on a date")
    self_val.ref.date_month.int.to_value()

  proc date_day(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.day requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.day must be called on a date")
    self_val.ref.date_day.int.to_value()

  date_class.def_native_method("year", date_year)
  date_class.def_native_method("month", date_month)
  date_class.def_native_method("day", date_day)

  let datetime_class = new_class("DateTime")
  datetime_class.parent = object_class
  datetime_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = datetime_class
  App.app.datetime_class = r.to_ref_value()
  App.app.gene_ns.ns["DateTime".to_key()] = App.app.datetime_class
  App.app.global_ns.ns["DateTime".to_key()] = App.app.datetime_class

  proc datetime_year(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.year requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.year must be called on a datetime")
    self_val.ref.dt_year.int.to_value()

  proc datetime_month(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.month requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.month must be called on a datetime")
    self_val.ref.dt_month.int.to_value()

  proc datetime_day(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.day requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.day must be called on a datetime")
    self_val.ref.dt_day.int.to_value()

  proc datetime_hour(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.hour requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.hour must be called on a datetime")
    self_val.ref.dt_hour.int.to_value()

  proc datetime_minute(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.minute requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.minute must be called on a datetime")
    self_val.ref.dt_minute.int.to_value()

  proc datetime_second(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.second requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.second must be called on a datetime")
    self_val.ref.dt_second.int.to_value()

  proc datetime_to_i(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.to_i requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.to_i must be called on a datetime")
    let r = self_val.ref
    let dt = dateTime(
      r.dt_year.int, Month(r.dt_month), MonthdayRange(r.dt_day),
      r.dt_hour.int, r.dt_minute.int, r.dt_second.int,
      zone = utc()
    )
    let epoch_secs = dt.toTime().toUnix()
    (epoch_secs * 1000).to_value()

  proc datetime_microsecond(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.microsecond requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.microsecond must be called on a datetime")
    self_val.ref.dt_microsecond.int.to_value()

  proc datetime_offset(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.offset requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.offset must be called on a datetime")
    if self_val.ref.dt_tz_name.len == 0 and self_val.ref.dt_timezone == 0:
      return NIL  # Naive datetime has no offset
    self_val.ref.dt_timezone.int.to_value()

  proc datetime_timezone(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.timezone requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.timezone must be called on a datetime")
    if self_val.ref.dt_tz_name.len == 0:
      return NIL
    self_val.ref.dt_tz_name.to_value()

  datetime_class.def_native_method("year", datetime_year)
  datetime_class.def_native_method("month", datetime_month)
  datetime_class.def_native_method("day", datetime_day)
  datetime_class.def_native_method("hour", datetime_hour)
  datetime_class.def_native_method("minute", datetime_minute)
  datetime_class.def_native_method("second", datetime_second)
  datetime_class.def_native_method("microsecond", datetime_microsecond)
  datetime_class.def_native_method("offset", datetime_offset)
  datetime_class.def_native_method("timezone", datetime_timezone)
  datetime_class.def_native_method("to_i", datetime_to_i)

  # Time class
  let time_class = new_class("Time")
  time_class.parent = object_class
  time_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = time_class
  App.app.time_class = r.to_ref_value()
  App.app.gene_ns.ns["Time".to_key()] = App.app.time_class
  App.app.global_ns.ns["Time".to_key()] = App.app.time_class

  proc time_hour(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.hour must be called on a time")
    self_val.ref.time_hour.int.to_value()

  proc time_minute(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.minute must be called on a time")
    self_val.ref.time_minute.int.to_value()

  proc time_second(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.second must be called on a time")
    self_val.ref.time_second.int.to_value()

  proc time_microsecond(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.microsecond must be called on a time")
    self_val.ref.time_microsecond.int.to_value()

  proc time_offset(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.offset must be called on a time")
    if self_val.ref.time_tz_name.len == 0 and self_val.ref.time_tz_offset == 0:
      return NIL
    self_val.ref.time_tz_offset.int.to_value()

  proc time_timezone(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkTime: not_allowed("Time.timezone must be called on a time")
    if self_val.ref.time_tz_name.len == 0:
      return NIL
    self_val.ref.time_tz_name.to_value()

  time_class.def_native_method("hour", time_hour)
  time_class.def_native_method("minute", time_minute)
  time_class.def_native_method("second", time_second)
  time_class.def_native_method("microsecond", time_microsecond)
  time_class.def_native_method("offset", time_offset)
  time_class.def_native_method("timezone", time_timezone)

proc init_date_functions*() =
  proc host_now_datetime(): DateTime {.inline.} =
    when defined(gene_wasm):
      fromUnix(host_now_unix()).local()
    else:
      times.now()

  proc gene_today_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = host_now_datetime()
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  proc gene_now_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = host_now_datetime()
    new_datetime_value(dt)

  proc gene_yesterday_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = host_now_datetime() - initDuration(days = 1)
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  proc gene_tomorrow_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = host_now_datetime() + initDuration(days = 1)
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  var today_fn = new_ref(VkNativeFn)
  today_fn.native_fn = gene_today_native
  App.app.gene_ns.ns["today".to_key()] = today_fn.to_ref_value()

  var now_fn = new_ref(VkNativeFn)
  now_fn.native_fn = gene_now_native
  App.app.gene_ns.ns["now".to_key()] = now_fn.to_ref_value()

  var yesterday_fn = new_ref(VkNativeFn)
  yesterday_fn.native_fn = gene_yesterday_native
  App.app.gene_ns.ns["yesterday".to_key()] = yesterday_fn.to_ref_value()

  var tomorrow_fn = new_ref(VkNativeFn)
  tomorrow_fn.native_fn = gene_tomorrow_native
  App.app.gene_ns.ns["tomorrow".to_key()] = tomorrow_fn.to_ref_value()

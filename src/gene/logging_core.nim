import os, times, strutils, strformat, tables, locks, terminal
import std/json

import ./types

type
  LogLevel* = enum
    LlError
    LlWarn
    LlInfo
    LlDebug
    LlTrace

  ConsoleStream* = enum
    CsStdout
    CsStderr

  LogFormat* = enum
    LfVerbose
    LfConcise
    LfRecord

  LogSinkKind* = enum
    LskConsole
    LskFile

  LogSink* = ref object
    name*: string
    render_format*: LogFormat
    case kind*: LogSinkKind
    of LskConsole:
      stream*: ConsoleStream
      color*: bool
    of LskFile:
      path*: string
      file*: File

  LogRoute* = object
    level*: LogLevel
    targets*: seq[string]

  LogRouteOverride* = object
    has_level*: bool
    level*: LogLevel
    has_targets*: bool
    targets*: seq[string]

  LoggingState* = ref object
    root_route*: LogRoute
    logger_overrides*: Table[string, LogRouteOverride]
    route_cache*: Table[string, LogRoute]
    sinks*: Table[string, LogSink]

  LogEvent* = object
    thr*: int
    level*: LogLevel
    time*: DateTime
    name*: string
    value*: string
    rendered_cache: array[LogFormat, string]
    rendered_ready: array[LogFormat, bool]

  LoggingLoaderHook* = proc() {.gcsafe.}

const
  DefaultRootLevel* = LlInfo
  DefaultConsoleSinkName* = "console"
  UnknownLoggerName = "unknown"

var logging_loaded* = false
var last_log_line* = ""

var active_logging_state: LoggingState = nil
var default_root_level_override = DefaultRootLevel
var logging_loader_hook: LoggingLoaderHook = nil
var logging_load_in_progress = false

var config_lock: Lock
var log_lock: Lock
initLock(config_lock)
initLock(log_lock)

var verbose_time_format {.threadvar.}: TimeFormat
var verbose_time_format_ready {.threadvar.}: bool
var concise_time_format {.threadvar.}: TimeFormat
var concise_time_format_ready {.threadvar.}: bool
var record_time_format {.threadvar.}: TimeFormat
var record_time_format_ready {.threadvar.}: bool

proc level_rank(level: LogLevel): int =
  case level
  of LlError: 0
  of LlWarn: 1
  of LlInfo: 2
  of LlDebug: 3
  of LlTrace: 4

proc level_to_string*(level: LogLevel): string =
  case level
  of LlError: "ERROR"
  of LlWarn: "WARN "
  of LlInfo: "INFO "
  of LlDebug: "DEBUG"
  of LlTrace: "TRACE"

proc canonical_level_to_string*(level: LogLevel): string =
  case level
  of LlError: "ERROR"
  of LlWarn: "WARN"
  of LlInfo: "INFO"
  of LlDebug: "DEBUG"
  of LlTrace: "TRACE"

proc parse_log_level*(name: string, out_level: var LogLevel): bool =
  case name.toUpperAscii()
  of "ERROR":
    out_level = LlError
    true
  of "WARN", "WARNING":
    out_level = LlWarn
    true
  of "INFO":
    out_level = LlInfo
    true
  of "DEBUG":
    out_level = LlDebug
    true
  of "TRACE":
    out_level = LlTrace
    true
  else:
    false

proc parse_log_format*(name: string, out_format: var LogFormat): bool =
  case name.toLowerAscii()
  of "verbose":
    out_format = LfVerbose
    true
  of "concise":
    out_format = LfConcise
    true
  of "record":
    out_format = LfRecord
    true
  else:
    false

proc normalize_logger_name(logger_name: string): string =
  if logger_name.len == 0:
    return ""
  logger_name.replace('\\', '/')

proc new_console_sink*(name = DefaultConsoleSinkName, stream = CsStderr, color = true, render_format = LfVerbose): LogSink =
  LogSink(name: name, render_format: render_format, kind: LskConsole, stream: stream, color: color)

proc new_file_sink*(name, path: string, render_format = LfVerbose): LogSink =
  proc try_open(handle: var File, sink_path: string, mode: FileMode): bool =
    try:
      open(handle, sink_path, mode)
    except CatchableError:
      false

  let expanded_path = absolutePath(path)
  let dir = parentDir(expanded_path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  var handle: File
  if not try_open(handle, expanded_path, fmAppend):
    if try_open(handle, expanded_path, fmWrite):
      close(handle)
    if not try_open(handle, expanded_path, fmAppend):
      raise newException(IOError, "Failed to open log file sink: " & expanded_path)

  LogSink(name: name, render_format: render_format, kind: LskFile, path: expanded_path, file: handle)

proc default_targets_for_sinks*(sinks: Table[string, LogSink]): seq[string] =
  if sinks.hasKey(DefaultConsoleSinkName):
    return @[DefaultConsoleSinkName]
  result = @[]
  for name in sinks.keys:
    result.add(name)

proc default_logging_state*(root_level = DefaultRootLevel): LoggingState =
  result = LoggingState(
    root_route: LogRoute(level: root_level, targets: @[DefaultConsoleSinkName]),
    logger_overrides: initTable[string, LogRouteOverride](),
    route_cache: initTable[string, LogRoute](),
    sinks: initTable[string, LogSink]()
  )
  result.sinks[DefaultConsoleSinkName] = new_console_sink()

proc close_logging_state(state: LoggingState) =
  if state == nil:
    return
  for sink in state.sinks.values:
    if sink == nil:
      continue
    case sink.kind
    of LskConsole:
      discard
    of LskFile:
      if sink.file != nil:
        try:
          close(sink.file)
        except CatchableError:
          discard

proc install_logging_state*(state: LoggingState) {.gcsafe.} =
  {.cast(gcsafe).}:
    var previous_state: LoggingState = nil
    acquire(config_lock)
    try:
      previous_state = active_logging_state
      active_logging_state = state
      logging_loaded = state != nil
      logging_load_in_progress = false
    finally:
      release(config_lock)
    close_logging_state(previous_state)

proc set_logging_loader_hook*(hook: LoggingLoaderHook) =
  acquire(config_lock)
  try:
    logging_loader_hook = hook
  finally:
    release(config_lock)

proc begin_logging_load*(): bool =
  acquire(config_lock)
  try:
    if logging_load_in_progress:
      return false
    logging_load_in_progress = true
    true
  finally:
    release(config_lock)

proc finish_logging_load*() =
  acquire(config_lock)
  try:
    logging_load_in_progress = false
  finally:
    release(config_lock)

proc set_default_root_level*(level: LogLevel) =
  acquire(config_lock)
  try:
    default_root_level_override = level
  finally:
    release(config_lock)

proc current_default_root_level*(): LogLevel =
  acquire(config_lock)
  try:
    default_root_level_override
  finally:
    release(config_lock)

proc initialize_default_logging*(root_level: LogLevel = DefaultRootLevel) =
  install_logging_state(default_logging_state(root_level))

proc reset_logging_config*() =
  var previous_state: LoggingState = nil
  acquire(config_lock)
  try:
    previous_state = active_logging_state
    active_logging_state = nil
    logging_loaded = false
    logging_load_in_progress = false
    default_root_level_override = DefaultRootLevel
  finally:
    release(config_lock)
  close_logging_state(previous_state)

  acquire(log_lock)
  try:
    last_log_line = ""
  finally:
    release(log_lock)

proc apply_override(route: var LogRoute, override: LogRouteOverride) =
  if override.has_level:
    route.level = override.level
  if override.has_targets:
    route.targets = override.targets

proc resolve_route_locked(state: LoggingState, logger_name: string): LogRoute =
  result = state.root_route
  if logger_name.len == 0:
    return

  if state.route_cache.hasKey(logger_name):
    return state.route_cache[logger_name]

  for i, ch in logger_name:
    if ch == '/':
      let prefix = logger_name[0..<i]
      if state.logger_overrides.hasKey(prefix):
        result.apply_override(state.logger_overrides[prefix])

  if state.logger_overrides.hasKey(logger_name):
    result.apply_override(state.logger_overrides[logger_name])

  state.route_cache[logger_name] = result

proc ensure_logging_loaded*() =
  var should_load = false
  var hook: LoggingLoaderHook = nil
  var root_level = DefaultRootLevel

  acquire(config_lock)
  try:
    should_load = not logging_loaded and not logging_load_in_progress
    hook = logging_loader_hook
    root_level = default_root_level_override
  finally:
    release(config_lock)

  if not should_load:
    return

  if hook != nil:
    hook()

  acquire(config_lock)
  try:
    if logging_loaded or logging_load_in_progress:
      return
    root_level = default_root_level_override
  finally:
    release(config_lock)

  initialize_default_logging(root_level)

proc route_for*(logger_name: string): LogRoute {.gcsafe.} =
  {.cast(gcsafe).}:
    ensure_logging_loaded()
    let normalized = normalize_logger_name(logger_name)

    acquire(config_lock)
    try:
      if active_logging_state == nil:
        return LogRoute(level: default_root_level_override, targets: @[DefaultConsoleSinkName])
      active_logging_state.resolve_route_locked(normalized)
    finally:
      release(config_lock)

proc effective_level*(logger_name: string): LogLevel {.gcsafe.} =
  route_for(logger_name).level

proc effective_targets*(logger_name: string): seq[string] {.gcsafe.} =
  route_for(logger_name).targets

proc log_enabled*(level: LogLevel, logger_name: string): bool {.gcsafe.} =
  level_rank(level) <= level_rank(effective_level(logger_name))

proc verbose_log_time_format(): TimeFormat =
  if not verbose_time_format_ready:
    verbose_time_format = init_time_format("yy-MM-dd ddd HH:mm:ss'.'fff")
    verbose_time_format_ready = true
  verbose_time_format

proc concise_log_time_format(): TimeFormat =
  if not concise_time_format_ready:
    concise_time_format = init_time_format("MM-dd HH:mm:ss'.'fff")
    concise_time_format_ready = true
  concise_time_format

proc record_log_time_format(): TimeFormat =
  if not record_time_format_ready:
    record_time_format = init_time_format("yyyy-MM-dd'T'HH:mm:ss'.'fffzzz")
    record_time_format_ready = true
  record_time_format

proc reset_render_cache(event: var LogEvent) =
  for render_format in LogFormat:
    event.rendered_ready[render_format] = false
    event.rendered_cache[render_format].setLen(0)

proc init_log_event*(event: var LogEvent, level: LogLevel, logger_name: string, message: string, timestamp: DateTime) =
  event.thr = current_thread_id
  event.level = level
  event.time = timestamp
  event.name = if logger_name.len > 0: logger_name else: UnknownLoggerName
  event.value = message
  reset_render_cache(event)

proc init_log_event*(event: var LogEvent, level: LogLevel, logger_name: string, message: string) =
  init_log_event(event, level, logger_name, message, now())

proc render_verbose_log_line(event: LogEvent): string =
  let thread_label = fmt"T{event.thr:02d}"
  let level_label = level_to_string(event.level)
  let time_label = event.time.format(verbose_log_time_format())
  result = thread_label & " " & level_label & " " & time_label & " " & event.name
  if event.value.len > 0:
    result &= " " & event.value

proc render_concise_log_line(event: LogEvent): string =
  let level_label = canonical_level_to_string(event.level)
  let time_label = event.time.format(concise_log_time_format())
  result = level_label & " " & time_label & " " & event.name
  if event.value.len > 0:
    result &= " " & event.value

proc render_record_log_line(event: LogEvent): string =
  let time_label = event.time.format(record_log_time_format())
  result = "{^thr " & $event.thr &
    " ^lvl " & escapeJson(canonical_level_to_string(event.level)) &
    " ^time " & escapeJson(time_label) &
    " ^name " & escapeJson(event.name) &
    " ^value " & escapeJson(event.value) &
    "}"

proc render_log_event*(event: var LogEvent, render_format: LogFormat): string =
  if event.rendered_ready[render_format]:
    return event.rendered_cache[render_format]

  let rendered =
    case render_format
    of LfVerbose:
      render_verbose_log_line(event)
    of LfConcise:
      render_concise_log_line(event)
    of LfRecord:
      render_record_log_line(event)

  event.rendered_cache[render_format] = rendered
  event.rendered_ready[render_format] = true
  rendered

proc format_log_line*(level: LogLevel, logger_name: string, message: string, timestamp: DateTime): string {.gcsafe.} =
  var event: LogEvent
  init_log_event(event, level, logger_name, message, timestamp)
  render_log_event(event, LfVerbose)

proc format_log_line*(level: LogLevel, logger_name: string, message: string): string {.gcsafe.} =
  format_log_line(level, logger_name, message, now())

proc format_concise_log_line*(level: LogLevel, logger_name: string, message: string, timestamp: DateTime): string {.gcsafe.} =
  var event: LogEvent
  init_log_event(event, level, logger_name, message, timestamp)
  render_log_event(event, LfConcise)

proc format_concise_log_line*(level: LogLevel, logger_name: string, message: string): string {.gcsafe.} =
  format_concise_log_line(level, logger_name, message, now())

proc format_record_log_line*(level: LogLevel, logger_name: string, message: string, timestamp: DateTime): string {.gcsafe.} =
  var event: LogEvent
  init_log_event(event, level, logger_name, message, timestamp)
  render_log_event(event, LfRecord)

proc format_record_log_line*(level: LogLevel, logger_name: string, message: string): string {.gcsafe.} =
  format_record_log_line(level, logger_name, message, now())

proc log_color_enabled(sink: LogSink): bool =
  if sink == nil or sink.kind != LskConsole or not sink.color:
    return false
  if existsEnv("NO_COLOR"):
    return false
  let term_name = getEnv("TERM", "")
  if term_name.len == 0 or term_name.toLowerAscii() == "dumb":
    return false
  try:
    let handle = if sink.stream == CsStdout: stdout else: stderr
    isatty(handle)
  except CatchableError:
    false

proc log_color_prefix(level: LogLevel): string =
  case level
  of LlError: "\e[31m"
  of LlWarn: "\e[33m"
  of LlInfo: "\e[32m"
  of LlDebug: "\e[36m"
  of LlTrace: "\e[90m"

proc colorize_log_line(sink: LogSink, level: LogLevel, line: string): string =
  if line.len == 0 or not log_color_enabled(sink):
    return line
  log_color_prefix(level) & line & "\e[0m"

proc write_to_sink(sink: LogSink, event: var LogEvent): string =
  if sink == nil:
    return ""
  let rendered = render_log_event(event, sink.render_format)
  case sink.kind
  of LskConsole:
    let colored = colorize_log_line(sink, event.level, rendered)
    if sink.stream == CsStdout:
      stdout.writeLine(colored)
      stdout.flushFile()
    else:
      stderr.writeLine(colored)
      stderr.flushFile()
  of LskFile:
    if sink.file == nil:
      return rendered
    sink.file.writeLine(rendered)
    sink.file.flushFile()
  rendered

proc log_message*(level: LogLevel, logger_name: string, message: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    ensure_logging_loaded()
    let normalized_name = normalize_logger_name(logger_name)
    let route = route_for(normalized_name)
    if level_rank(level) > level_rank(route.level):
      return

    var sinks: seq[LogSink] = @[]
    acquire(config_lock)
    try:
      if active_logging_state == nil:
        return
      for target in route.targets:
        if active_logging_state.sinks.hasKey(target):
          sinks.add(active_logging_state.sinks[target])
    finally:
      release(config_lock)

    if sinks.len == 0:
      return

    let timestamp = now()
    var event: LogEvent
    init_log_event(event, level, normalized_name, message, timestamp)
    acquire(log_lock)
    try:
      last_log_line = ""
      for i, sink in sinks:
        let rendered = write_to_sink(sink, event)
        if i == 0:
          last_log_line = rendered
    finally:
      release(log_lock)

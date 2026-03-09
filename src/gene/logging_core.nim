import os, times, strutils, strformat, tables, locks, terminal

import ./types
import ./parser

type LogLevel* = enum
  LlError
  LlWarn
  LlInfo
  LlDebug
  LlTrace

const DefaultRootLevel = LlInfo

var logging_loaded* = false
var root_level* = DefaultRootLevel
var logger_levels* = initTable[string, LogLevel]()
var last_log_line* = ""

var config_lock: Lock  # Protects logging_loaded, root_level, logger_levels
var log_lock: Lock     # Protects echo and last_log_line
initLock(config_lock)
initLock(log_lock)

proc reset_logging_config*() =
  acquire(config_lock)
  try:
    root_level = DefaultRootLevel
    logger_levels = initTable[string, LogLevel]()
    logging_loaded = false
  finally:
    release(config_lock)
  # last_log_line is protected by log_lock, not config_lock
  acquire(log_lock)
  try:
    last_log_line = ""
  finally:
    release(log_lock)

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

proc parse_log_level(name: string, out_level: var LogLevel): bool =
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

proc log_level_from_value(val: Value, fallback: LogLevel): LogLevel =
  case val.kind
  of VkString, VkSymbol:
    var parsed: LogLevel
    if parse_log_level(val.str, parsed):
      return parsed
  else:
    discard
  fallback

proc key_to_string(key: Key): string =
  let symbol_value = cast[Value](key)
  let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
  get_symbol(symbol_index.int)

proc load_logging_config*(config_path: string = "") =
  let path =
    if config_path.len > 0:
      config_path
    else:
      joinPath(getCurrentDir(), "config", "logging.gene")

  acquire(config_lock)
  try:
    root_level = DefaultRootLevel
    logger_levels = initTable[string, LogLevel]()
    logging_loaded = true
  finally:
    release(config_lock)

  if not fileExists(path):
    # Silent if using default path, warning if explicit path provided
    if config_path.len > 0:
      stderr.writeLine("Warning: Logging config file not found: " & path)
    return

  let content = readFile(path)
  var nodes: seq[Value]
  try:
    nodes = read_all(content)
  except CatchableError as e:
    stderr.writeLine("Warning: Failed to parse logging config: " & path & " - " & e.msg)
    return
  if nodes.len == 0:
    stderr.writeLine("Warning: Empty logging config: " & path)
    return
  let config_val = nodes[0]
  if config_val.kind != VkMap:
    stderr.writeLine("Warning: Logging config must be a map: " & path)
    return

  let config_map = map_data(config_val)
  var new_root_level = DefaultRootLevel
  var new_logger_levels = initTable[string, LogLevel]()

  new_root_level = log_level_from_value(config_map.getOrDefault("level".to_key(), NIL), new_root_level)

  let loggers_val = config_map.getOrDefault("loggers".to_key(), NIL)
  if loggers_val.kind == VkMap:
    for key, entry in map_data(loggers_val):
      let logger_name = key_to_string(key)
      var level = new_root_level
      case entry.kind
      of VkMap:
        let entry_level = map_data(entry).getOrDefault("level".to_key(), NIL)
        level = log_level_from_value(entry_level, new_root_level)
      of VkString, VkSymbol:
        level = log_level_from_value(entry, new_root_level)
      else:
        discard
      new_logger_levels[logger_name] = level

  # Update globals atomically under lock
  acquire(config_lock)
  try:
    root_level = new_root_level
    logger_levels = new_logger_levels
  finally:
    release(config_lock)

proc ensure_logging_loaded() =
  acquire(config_lock)
  let loaded = logging_loaded
  release(config_lock)
  if not loaded:
    load_logging_config()

proc effective_level*(logger_name: string): LogLevel =
  ensure_logging_loaded()
  acquire(config_lock)
  defer: release(config_lock)

  if logger_name.len == 0:
    return root_level

  var name = logger_name
  while true:
    if logger_levels.hasKey(name):
      return logger_levels[name]
    let idx = name.rfind("/")
    if idx < 0:
      break
    name = name[0..<idx]

  root_level

proc log_enabled*(level: LogLevel, logger_name: string): bool =
  let effective = effective_level(logger_name)
  level_rank(level) <= level_rank(effective)

proc format_log_line*(level: LogLevel, logger_name: string, message: string, timestamp: DateTime): string {.gcsafe.} =
  let thread_label = fmt"T{current_thread_id:02d}"
  let level_label = level_to_string(level)
  let time_format = init_time_format("yy-MM-dd ddd HH:mm:ss'.'fff")
  let time_label = timestamp.format(time_format)
  let name = if logger_name.len > 0: logger_name else: "unknown"
  result = thread_label & " " & level_label & " " & time_label & " " & name
  if message.len > 0:
    result &= " " & message

proc format_log_line*(level: LogLevel, logger_name: string, message: string): string {.gcsafe.} =
  format_log_line(level, logger_name, message, now())

proc log_color_enabled(): bool =
  if existsEnv("NO_COLOR"):
    return false
  let term_name = getEnv("TERM", "")
  if term_name.len == 0 or term_name.toLowerAscii() == "dumb":
    return false
  try:
    isatty(stdout)
  except CatchableError:
    false

proc log_color_prefix(level: LogLevel): string =
  case level
  of LlError: "\e[31m"
  of LlWarn: "\e[33m"
  of LlInfo: "\e[32m"
  of LlDebug: "\e[36m"
  of LlTrace: "\e[90m"

proc colorize_log_line(level: LogLevel, line: string): string =
  if line.len == 0 or not log_color_enabled():
    return line
  log_color_prefix(level) & line & "\e[0m"

proc log_message*(level: LogLevel, logger_name: string, message: string) {.gcsafe.} =
  # log_enabled() internally acquires config_lock, so it's thread-safe
  {.cast(gcsafe).}:
    if not log_enabled(level, logger_name):
      return

  let line = format_log_line(level, logger_name, message)
  acquire(log_lock)
  try:
    {.cast(gcsafe).}:
      last_log_line = line
    echo colorize_log_line(level, line)
  finally:
    release(log_lock)

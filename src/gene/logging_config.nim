import os, strutils, tables

import ./types
import ./parser
import ./logging_core

proc key_to_string(key: Key): string =
  let symbol_value = cast[Value](key)
  let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
  get_symbol(symbol_index.int)

proc warn_config(message: string) =
  stderr.writeLine("Warning: " & message)

proc value_to_string(value: Value): string =
  case value.kind
  of VkString, VkSymbol:
    value.str
  else:
    ""

proc log_level_from_value(value: Value, fallback: LogLevel, found: var bool): LogLevel =
  let name = value_to_string(value)
  if name.len == 0:
    return fallback
  var parsed: LogLevel
  if parse_log_level(name, parsed):
    found = true
    return parsed
  fallback

proc parse_targets_value(value: Value): tuple[defined: bool, targets: seq[string]] =
  case value.kind
  of VkNil:
    (defined: false, targets: @[])
  of VkString, VkSymbol:
    (defined: true, targets: @[value.str])
  of VkArray:
    var targets: seq[string] = @[]
    for item in array_data(value):
      let name = value_to_string(item)
      if name.len > 0 and name notin targets:
        targets.add(name)
    (defined: true, targets: targets)
  else:
    (defined: false, targets: @[])

proc filter_targets(targets: seq[string], sinks: Table[string, LogSink], context: string): seq[string] =
  result = @[]
  for target in targets:
    if sinks.hasKey(target):
      result.add(target)
    else:
      warn_config(context & " references unknown sink '" & target & "'")

proc parse_console_stream(name: string): ConsoleStream =
  case name.toLowerAscii()
  of "", "stderr":
    CsStderr
  of "stdout":
    CsStdout
  else:
    warn_config("Unknown console stream '" & name & "', defaulting to stderr")
    CsStderr

proc parse_sink_format(sink_name: string, sink_map: Table[Key, Value], found: var bool): LogFormat =
  found = true
  let format_name = value_to_string(sink_map.getOrDefault("format".to_key(), NIL))
  if format_name.len == 0:
    return LfVerbose

  var parsed: LogFormat
  if parse_log_format(format_name, parsed):
    found = true
    return parsed

  warn_config("Unsupported sink format '" & format_name & "' for sink '" & sink_name & "'")
  found = false
  LfVerbose

proc load_logging_config*(config_path: string = "") {.gcsafe.} =
  {.cast(gcsafe).}:
    let owns_load = begin_logging_load()
    if not owns_load:
      return

    try:
      let path =
        if config_path.len > 0:
          config_path
        else:
          joinPath(getCurrentDir(), "config", "logging.gene")

      var state = default_logging_state(current_default_root_level())

      if not fileExists(path):
        if config_path.len > 0:
          warn_config("Logging config file not found: " & path)
        install_logging_state(state)
        return

      let content = readFile(path)
      let nodes =
        try:
          read_all(content)
        except CatchableError as e:
          warn_config("Failed to parse logging config: " & path & " - " & e.msg)
          install_logging_state(state)
          return

      if nodes.len == 0:
        warn_config("Empty logging config: " & path)
        install_logging_state(state)
        return

      let config_val = nodes[0]
      if config_val.kind != VkMap:
        warn_config("Logging config must be a map: " & path)
        install_logging_state(state)
        return

      let config_map = map_data(config_val)

      var level_found = false
      state.root_route.level = log_level_from_value(
        config_map.getOrDefault("level".to_key(), NIL),
        current_default_root_level(),
        level_found
      )

      var parsed_sinks = initTable[string, LogSink]()
      let sinks_val = config_map.getOrDefault("sinks".to_key(), NIL)
      if sinks_val.kind == VkMap:
        for key, entry in map_data(sinks_val):
          let sink_name = key_to_string(key)
          if sink_name.len == 0:
            continue
          if entry.kind != VkMap:
            warn_config("Sink '" & sink_name & "' must be a map")
            continue

          let sink_map = map_data(entry)
          var format_found = true
          let sink_format = parse_sink_format(sink_name, sink_map, format_found)
          if not format_found:
            continue
          let sink_type = value_to_string(sink_map.getOrDefault("type".to_key(), NIL)).toLowerAscii()
          case sink_type
          of "console":
            let stream_name = value_to_string(sink_map.getOrDefault("stream".to_key(), NIL))
            let color_val = sink_map.getOrDefault("color".to_key(), TRUE)
            parsed_sinks[sink_name] = new_console_sink(
              name = sink_name,
              stream = parse_console_stream(stream_name),
              color = color_val.to_bool(),
              render_format = sink_format
            )
          of "file":
            let file_path = value_to_string(sink_map.getOrDefault("path".to_key(), NIL))
            if file_path.len == 0:
              warn_config("File sink '" & sink_name & "' requires ^path")
              continue
            try:
              parsed_sinks[sink_name] = new_file_sink(sink_name, file_path, render_format = sink_format)
            except CatchableError as e:
              warn_config(e.msg)
          else:
            warn_config("Unsupported sink type '" & sink_type & "' for sink '" & sink_name & "'")

      if parsed_sinks.len == 0:
        parsed_sinks[DefaultConsoleSinkName] = new_console_sink()
      state.sinks = parsed_sinks

      let root_targets = parse_targets_value(config_map.getOrDefault("targets".to_key(), NIL))
      if root_targets.defined:
        state.root_route.targets = filter_targets(root_targets.targets, state.sinks, "Root targets")
      else:
        state.root_route.targets = default_targets_for_sinks(state.sinks)

      let loggers_val = config_map.getOrDefault("loggers".to_key(), NIL)
      if loggers_val.kind == VkMap:
        for key, entry in map_data(loggers_val):
          let logger_name = key_to_string(key)
          if logger_name.len == 0:
            continue

          var route_override = LogRouteOverride()
          case entry.kind
          of VkMap:
            let entry_map = map_data(entry)

            var entry_level_found = false
            let level = log_level_from_value(
              entry_map.getOrDefault("level".to_key(), NIL),
              state.root_route.level,
              entry_level_found
            )
            if entry_level_found:
              route_override.has_level = true
              route_override.level = level

            let targets = parse_targets_value(entry_map.getOrDefault("targets".to_key(), NIL))
            if targets.defined:
              route_override.has_targets = true
              route_override.targets = filter_targets(
                targets.targets,
                state.sinks,
                "Logger '" & logger_name & "'"
              )
          of VkString, VkSymbol:
            var entry_level_found = false
            let level = log_level_from_value(entry, state.root_route.level, entry_level_found)
            if entry_level_found:
              route_override.has_level = true
              route_override.level = level
          else:
            warn_config("Logger '" & logger_name & "' must be a level or map")

          if route_override.has_level or route_override.has_targets:
            state.logger_overrides[logger_name] = route_override

      install_logging_state(state)
    finally:
      finish_logging_load()

proc register_logging_config_loader*() =
  set_logging_loader_hook(proc() {.gcsafe.} =
    load_logging_config()
  )

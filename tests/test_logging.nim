import unittest, os, strutils, tables

import ../src/gene/vm
import ../src/gene/logging_core
import ../src/gene/logging_config
import ../src/commands/base
import ../src/gene/parser
import ../src/gene/types except Exception
import ../src/genex/ai/openai_client
import ./helpers

test "Logging defaults when config missing":
  reset_logging_config()
  load_logging_config(joinPath(getTempDir(), "missing_logging.gene"))
  check effective_level("any/logger") == LlInfo

test "Logging resolves longest prefix":
  let dir = joinPath(getTempDir(), "gene_logging_test")
  createDir(dir)
  let config_path = joinPath(dir, "logging.gene")
  writeFile(config_path, """
{^level "INFO"
 ^loggers {
  ^examples {^level "WARN"}
  ^examples/app.gene {^level "DEBUG"}
  ^examples/app.gene/Http {^level "TRACE"}
  ^examples/app.gene/Http/Todo {^level "ERROR"}
 }}
""")

  reset_logging_config()
  load_logging_config(config_path)
  check effective_level("examples/app.gene/Http/Todo") == LlError
  check effective_level("examples/app.gene/Http/Other") == LlTrace
  check effective_level("examples/app.gene/Other") == LlDebug
  check effective_level("examples/other.gene") == LlWarn
  check effective_level("other") == LlInfo

test "Logging format includes level and name":
  # Save and restore global state to avoid test pollution
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    let line = format_log_line(LlInfo, "examples/app.gene", "hello")
    # Verify pattern: "T## INFO <timestamp> <logger_name> <message>"
    check line.startsWith("T00 INFO ")
    check line.contains(" examples/app.gene ")
    check line.endsWith(" hello")
  finally:
    current_thread_id = saved_thread_id

test "Concise logging format omits thread prefix":
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    let line = format_concise_log_line(LlDebug, "src/tools.gene", "hello")
    check line.startsWith("DEBUG ")
    check not line.startsWith("T00 ")
    check line.contains(" src/tools.gene ")
    check line.endsWith(" hello")
  finally:
    current_thread_id = saved_thread_id

test "Record logging format writes stable keys":
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    let line = format_record_log_line(LlDebug, "src/tools.gene", "hello")
    check line.startsWith("{^thr 0 ^lvl \"DEBUG\" ^time ")
    check line.contains(" ^name \"src/tools.gene\"")
    check line.contains(" ^value \"hello\"}")
  finally:
    current_thread_id = saved_thread_id

test "Logging parses sink formats":
  var render_format: LogFormat
  check parse_log_format("verbose", render_format)
  check render_format == LfVerbose
  check parse_log_format("concise", render_format)
  check render_format == LfConcise
  check parse_log_format("record", render_format)
  check render_format == LfRecord
  check not parse_log_format("bogus", render_format)

test "Gene Logger emits log line":
  init_all_with_extensions()
  reset_logging_config()
  load_logging_config(joinPath(getTempDir(), "missing_logging.gene"))
  # Save and restore global state to avoid test pollution
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    last_log_line = ""
    discard VM.exec("""
    (class A
      (/logger = (new genex/logging/Logger self))
      (method m []
        (logger .info "hello")
      )
    )
    (var a (new A))
    (a .m)
    """, "test_code.gene")
    check last_log_line.contains(" INFO ")
    check last_log_line.contains("test_code.gene/A")
    check last_log_line.endsWith(" hello")
  finally:
    current_thread_id = saved_thread_id

test "Gene Logger accepts string names":
  init_all_with_extensions()
  reset_logging_config()
  load_logging_config(joinPath(getTempDir(), "missing_logging.gene"))
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    last_log_line = ""
    discard VM.exec("""
    (var logger (new genex/logging/Logger "gene/custom"))
    (logger .info "hello")
    """, "test_code.gene")
    check last_log_line.contains(" gene/custom ")
    check last_log_line.endsWith(" hello")
  finally:
    current_thread_id = saved_thread_id

test "Logging file sink appends across reloads":
  let dir = joinPath(getTempDir(), "gene_logging_file_sink")
  createDir(dir)
  let log_path = joinPath(dir, "gene.log")
  let config_path = joinPath(dir, "logging.gene")
  if fileExists(log_path):
    removeFile(log_path)
  writeFile(config_path, """
{^sinks {
   ^file {^type "file" ^path "$1"}
 }
 ^targets ["file"]}
""" % [log_path])

  reset_logging_config()
  load_logging_config(config_path)
  log_message(LlInfo, "tests/file", "first")

  reset_logging_config()
  load_logging_config(config_path)
  log_message(LlInfo, "tests/file", "second")

  let content = readFile(log_path)
  check content.contains(" tests/file first")
  check content.contains(" tests/file second")

test "Logging fans out one event to sinks with different formats":
  let dir = joinPath(getTempDir(), "gene_logging_multi_format")
  createDir(dir)
  let concise_path = joinPath(dir, "concise.log")
  let record_path = joinPath(dir, "record.log")
  let config_path = joinPath(dir, "logging.gene")
  for path in [concise_path, record_path]:
    if fileExists(path):
      removeFile(path)
  writeFile(config_path, """
{^level "DEBUG"
 ^sinks {
   ^concise_file {^type "file" ^path "$1" ^format "concise"}
   ^record_file {^type "file" ^path "$2" ^format "record"}
 }
 ^targets ["concise_file" "record_file"]}
""" % [concise_path, record_path])

  reset_logging_config()
  load_logging_config(config_path)
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    log_message(LlDebug, "src/tools.gene", "hello")
  finally:
    current_thread_id = saved_thread_id

  let concise_content = readFile(concise_path)
  let record_content = readFile(record_path)
  check concise_content.startsWith("DEBUG ")
  check concise_content.contains(" src/tools.gene hello")
  check not concise_content.startsWith("T00 ")
  check record_content.startsWith("{^thr 0 ^lvl \"DEBUG\" ^time ")
  check record_content.contains(" ^name \"src/tools.gene\"")
  check record_content.contains(" ^value \"hello\"}")

test "Invalid sink format does not break valid sinks":
  let dir = joinPath(getTempDir(), "gene_logging_invalid_format")
  createDir(dir)
  let log_path = joinPath(dir, "good.log")
  let config_path = joinPath(dir, "logging.gene")
  if fileExists(log_path):
    removeFile(log_path)
  writeFile(config_path, """
{^sinks {
   ^bad_sink {^type "file" ^path "$1" ^format "bogus"}
   ^good_sink {^type "file" ^path "$2" ^format "record"}
 }
 ^targets ["good_sink"]}
""" % [joinPath(dir, "bad.log"), log_path])

  reset_logging_config()
  load_logging_config(config_path)
  log_message(LlInfo, "tests/file", "hello")

  let content = readFile(log_path)
  check content.contains(" ^name \"tests/file\"")
  check content.contains(" ^value \"hello\"}")

test "setup_logger loads logging config from cwd":
  let original_dir = getCurrentDir()
  let dir = joinPath(getTempDir(), "gene_logging_setup_logger")
  let config_dir = joinPath(dir, "config")
  let log_path = joinPath(dir, "home", "logs", "main.log")
  createDir(dir)
  createDir(config_dir)
  if fileExists(log_path):
    removeFile(log_path)
  writeFile(joinPath(config_dir, "logging.gene"), """
{^sinks {
   ^main_file {^type "file" ^path "./home/logs/main.log"}
 }
 ^targets ["main_file"]}
""")

  try:
    setCurrentDir(dir)
    setup_logger(false)
    log_message(LlInfo, "tests/cwd", "hello")
    check fileExists(log_path)
    let content = readFile(log_path)
    check content.contains(" tests/cwd hello")
  finally:
    setCurrentDir(original_dir)
    reset_logging_config()

test "VM logging loads config from cwd without manual loader import":
  init_all_with_extensions()
  let original_dir = getCurrentDir()
  let dir = joinPath(getTempDir(), "gene_logging_vm_cwd")
  let config_dir = joinPath(dir, "config")
  let log_path = joinPath(dir, "home", "logs", "main.log")
  createDir(dir)
  createDir(config_dir)
  if fileExists(log_path):
    removeFile(log_path)
  writeFile(joinPath(config_dir, "logging.gene"), """
{^sinks {
   ^main_file {^type "file" ^path "./home/logs/main.log"}
 }
 ^targets ["main_file"]}
""")

  try:
    setCurrentDir(dir)
    reset_logging_config()
    discard VM.exec("""
    (var logger (new genex/logging/Logger "geneclaw/test"))
    (logger .info "hello")
    """, "test_code.gene")
    check fileExists(log_path)
    let content = readFile(log_path)
    check content.contains(" geneclaw/test hello")
  finally:
    setCurrentDir(original_dir)
    reset_logging_config()

test "Parser debug output uses shared logger":
  reset_logging_config()
  set_default_root_level(LlDebug)
  load_logging_config(joinPath(getTempDir(), "missing_logging.gene"))
  let saved_thread_id = current_thread_id
  try:
    current_thread_id = 0
    last_log_line = ""
    var parser = new_parser()
    parser.options["debug"] = TRUE
    parser.open("(foo 1)", "parser_test.gene")
    discard parser.read()
    parser.close()
    check last_log_line.contains(" gene/parser ")
  finally:
    current_thread_id = saved_thread_id

test "OpenAI debug header logging redacts secrets":
  var headers = initTable[string, string]()
  headers["Authorization"] = "Bearer sk-test-secret-123456"
  headers["X-API-Key"] = "test-api-key-abcdef"
  headers["X-Trace-Id"] = "trace-123"

  let rendered = redactHeadersForLog(headers)
  check rendered.contains("Authorization: Bearer ")
  check rendered.contains("X-API-Key: ")
  check rendered.contains("X-Trace-Id: trace-123")
  check not rendered.contains("sk-test-secret-123456")
  check not rendered.contains("test-api-key-abcdef")

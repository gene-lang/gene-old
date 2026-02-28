import std/json

proc infer_diag_code*(message: string): string =
  let lower = message.toLowerAscii()
  if lower.contains("division by zero") or lower.contains("divide"):
    return "GENE.ARITH.DIV_ZERO"
  if lower.contains("method not found") or lower.contains("no method"):
    return "GENE.OOP.METHOD_NOT_FOUND"
  if lower.contains("undefined variable") or lower.contains("not defined"):
    return "GENE.SCOPE.UNDEFINED_VAR"
  if lower.contains("stack overflow"):
    return "GENE.VM.STACK_OVERFLOW"
  if lower.contains("failed to load extension"):
    return "GENE.EXT.LOAD_FAILED"
  "GENE.RUNTIME.ERROR"

proc make_diagnostic_message*(
  code, message: string;
  stage = "runtime";
  file = "";
  line = 0;
  column = 0;
  hints: seq[string] = @[]
): string =
  var root = newJObject()
  root["code"] = %code
  root["severity"] = %"error"
  root["stage"] = %stage
  root["span"] = %*{"file": file, "line": line, "column": column}
  root["message"] = %message

  var hints_arr = newJArray()
  for hint in hints:
    hints_arr.add(%hint)
  root["hints"] = hints_arr

  var tags_arr = newJArray()
  tags_arr.add(%"runtime")
  root["repair_tags"] = tags_arr

  $root

proc is_diagnostic_envelope*(message: string): bool =
  let trimmed = message.strip()
  if trimmed.len == 0 or trimmed[0] != '{':
    return false
  try:
    let parsed = parseJson(trimmed)
    parsed.kind == JObject and parsed.hasKey("code") and parsed.hasKey("message")
  except CatchableError:
    false

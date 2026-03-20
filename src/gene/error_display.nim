import ./vm/diagnostics
import ./stdlib/json
import ./serdes

proc render_error_message*(message: string): string =
  if not is_diagnostic_envelope(message):
    return message

  try:
    return value_to_gene_str(parse_json_string(message))
  except CatchableError:
    return message

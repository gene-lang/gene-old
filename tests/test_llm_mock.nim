import unittest

import strutils, tables

import gene/types except Exception
import gene/vm

import ./helpers

when not defined(GENE_LLM_MOCK):
  {.error: "tests/test_llm_mock.nim must be compiled with -d:GENE_LLM_MOCK".}

const MockModelPath = "./tests/fixtures/llm/mock-model.gguf"
const MockModelPathLiteral = "\"" & MockModelPath & "\""

proc eval(code: string): Value =
  let snippet = cleanup(code)
  VM.exec(snippet, "llm_mock_test")

suite "LLM Mock Backend":
  init_all()
  if App.kind == VkApplication and App.app.global_ns.kind == VkNamespace:
    App.app.global_ns.ref.ns["genex".to_key()] = App.app.genex_ns

  test "model instances expose classes":
    let model_value = eval("""
      (genex/llm/load_model """ & MockModelPathLiteral & """ {^allow_missing true})
    """)
    check model_value.kind == VkCustom
    check model_value.ref.custom_class.name == "Model"

  test "infer returns completion map":
    let response = eval("""
      (var model (genex/llm/load_model """ & MockModelPathLiteral & """ {^allow_missing true}))
      (var session (model .new_session {^max_tokens 1}))
      (session .infer "ping pong" {^max_tokens 1})
    """)
    check response.kind == VkMap
    let text = map_data(response)["text".to_key()]
    check text.kind == VkString
    check text.str.endsWith("[mock]")
    let finish = map_data(response)["finish_reason".to_key()]
    check finish.kind == VkSymbol
    check finish.str == ":length"

  test "timeout option raises":
    expect Exception:
      discard eval("""
        (var model (genex/llm/load_model """ & MockModelPathLiteral & """ {^allow_missing true}))
        (var session (model .new_session {}))
        (session .infer "hi" {^timeout 1})
      """)

  test "model close blocked while sessions open":
    expect Exception:
      discard eval("""
        (var model (genex/llm/load_model """ & MockModelPathLiteral & """ {^allow_missing true}))
        (var session (model .new_session {}))
        (model .close)
      """)

    let success = eval("""
      (var model (genex/llm/load_model """ & MockModelPathLiteral & """ {^allow_missing true}))
      (var session (model .new_session {}))
      (session .close)
      (model .close)
      `ok
    """)
    check success.kind == VkSymbol
    check success.str == "ok"

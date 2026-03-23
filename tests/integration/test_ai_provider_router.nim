import unittest
import std/json

import ../src/genex/ai/provider_router
import ../src/genex/ai/utils

suite "AI provider router":
  test "fallback uses second provider when first fails":
    let router = new_provider_router()

    proc provider_fail(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      raise newException(ValueError, "boom")

    proc provider_ok(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "final", "message": "ok"}

    router.add_provider("primary", provider_fail)
    router.add_provider("secondary", provider_ok)

    let result = router.call_with_fallback("run-1", new_command_envelope(command_id = "c1"), @[])
    check result.ok
    check result.provider_name == "secondary"
    check result.response["message"].getStr() == "ok"

  test "disabled provider is skipped":
    let router = new_provider_router()

    proc provider_a(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "final", "message": "a"}

    proc provider_b(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "final", "message": "b"}

    router.add_provider("a", provider_a)
    router.add_provider("b", provider_b)
    discard router.set_provider_enabled("a", false)

    let result = router.call_with_fallback("run-2", new_command_envelope(command_id = "c2"), @[])
    check result.ok
    check result.provider_name == "b"

  test "returns error response when no provider succeeds":
    let router = new_provider_router()

    proc provider_bad(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"message": "missing action"}

    router.add_provider("bad", provider_bad)

    let result = router.call_with_fallback("run-3", new_command_envelope(command_id = "c3"), @[])
    check not result.ok
    check result.response["action"].getStr() == "error"

import unittest
import std/json
import std/strutils

import ../src/genex/ai/agent_runtime
import ../src/genex/ai/utils
import ../src/genex/ai/tools

suite "AI agent runtime":
  test "run completes with final provider response":
    let runtime = new_agent_runtime()
    let cmd = new_command_envelope(command_id = "c1", source = CsSlack, text = "hello")
    let run_id = runtime.start_run(cmd)

    proc provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "final", "message": "done"}

    let result = runtime.step_run(run_id, provider)
    check result.state == ArsCompleted
    check result.message == "done"

  test "run executes tool then finalizes":
    let registry = new_tool_registry()

    proc echo_exec(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
      discard config
      discard ctx
      args

    registry.register_tool(ToolDef(
      name: "echo",
      description: "",
      config: newJObject(),
      executor: echo_exec
    ))

    let runtime = new_agent_runtime(registry)
    let run_id = runtime.start_run(new_command_envelope(command_id = "c2", text = "tool"))

    var call_count = 0
    proc provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      inc call_count
      if call_count == 1:
        %*{"action": "tool", "tool": "echo", "args": {"message": "hi"}}
      else:
        %*{"action": "final", "message": "ok"}

    let step1 = runtime.step_run(run_id, provider)
    check step1.state == ArsRunning
    check step1.tool_result["ok"].getBool() == true

    let step2 = runtime.step_run(run_id, provider)
    check step2.state == ArsCompleted
    check step2.message == "ok"

  test "run fails when tool denied":
    let registry = new_tool_registry()

    proc noop_exec(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
      discard config
      discard ctx
      discard args
      %*{"v": 1}

    proc deny_policy(ctx: ToolContext; tool_name: string; args: JsonNode): ToolPolicyDecision {.gcsafe.} =
      discard ctx
      discard tool_name
      discard args
      deny_decision("denied")

    registry.register_tool(ToolDef(
      name: "noop",
      description: "",
      config: newJObject(),
      executor: noop_exec
    ))
    registry.set_tool_policy(deny_policy)

    let runtime = new_agent_runtime(registry)
    let run_id = runtime.start_run(new_command_envelope(command_id = "c3", text = "blocked"))

    proc provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "tool", "tool": "noop", "args": {}}

    let step = runtime.step_run(run_id, provider)
    check step.state == ArsFailed
    check step.message.contains("denied")

  test "max tool calls is enforced":
    let registry = new_tool_registry()

    proc ok_exec(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
      discard config
      discard ctx
      discard args
      %*{"ok": true}

    registry.register_tool(ToolDef(
      name: "ok",
      description: "",
      config: newJObject(),
      executor: ok_exec
    ))

    let runtime = new_agent_runtime(registry)
    let run_id = runtime.start_run(
      new_command_envelope(command_id = "c4", text = "limit"),
      config = AgentRunConfig(max_steps: 10, max_tool_calls: 1)
    )

    proc provider(run_id: string; envelope: CommandEnvelope; history: seq[JsonNode]): JsonNode {.gcsafe.} =
      discard run_id
      discard envelope
      discard history
      %*{"action": "tool", "tool": "ok", "args": {}}

    let first = runtime.step_run(run_id, provider)
    check first.state == ArsRunning

    let second = runtime.step_run(run_id, provider)
    check second.state == ArsFailed
    check second.message.contains("max_tool_calls")

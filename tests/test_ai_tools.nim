import unittest
import std/json
import std/os
import std/strutils
import std/times

import ../src/genex/ai/tools

suite "AI Tools Runtime":
  test "register and invoke a custom tool":
    let registry = new_tool_registry()

    proc echo_exec(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
      discard config
      discard ctx
      args

    registry.register_tool(ToolDef(
      name: "echo",
      description: "echo args",
      config: newJObject(),
      executor: echo_exec
    ))

    let ctx = new_tool_context(run_id = "run-1", workspace_id = "ws-1", user_id = "u-1")
    let result = registry.invoke_tool(ctx, "echo", %*{"message": "hello"})

    check result["ok"].getBool() == true
    check result["result"]["message"].getStr() == "hello"
    check registry.audit_events.len == 1
    check registry.audit_events[0].status == "success"

  test "policy can deny tool execution":
    let registry = new_tool_registry()

    proc noop_exec(config: JsonNode; ctx: ToolContext; args: JsonNode): JsonNode {.gcsafe.} =
      discard config
      discard ctx
      discard args
      %*{"value": 1}

    proc deny_policy(ctx: ToolContext; tool_name: string; args: JsonNode): ToolPolicyDecision {.gcsafe.} =
      discard ctx
      discard tool_name
      discard args
      deny_decision("blocked by policy")

    registry.register_tool(ToolDef(
      name: "noop",
      description: "",
      config: newJObject(),
      executor: noop_exec
    ))
    registry.set_tool_policy(deny_policy)

    let result = registry.invoke_tool(new_tool_context(), "noop", newJObject())
    check result["ok"].getBool() == false
    check result["code"].getStr() == ToolCodeDenied
    check result["error"].getStr().contains("blocked")
    check registry.audit_events.len == 1
    check registry.audit_events[0].status == "denied"

  test "builtin shell tool enforces allowlist":
    let registry = new_tool_registry()
    registry.register_builtin_shell_tool(@["echo"])

    let ok_result = registry.invoke_tool(new_tool_context(), "shell", %*{"argv": ["echo", "hello"]})
    check ok_result["ok"].getBool() == true
    check ok_result["result"]["exit_code"].getInt() == 0
    check ok_result["result"]["output"].getStr().contains("hello")

    let denied = registry.invoke_tool(new_tool_context(), "shell", %*{"argv": ["uname"]})
    check denied["ok"].getBool() == false
    check denied["code"].getStr() == ToolCodeExecFailed

  test "builtin filesystem tool enforces workspace scope":
    let root = getTempDir() / ("gene-ai-tools-" & $epochTime().int)
    createDir(root)
    defer:
      if dirExists(root):
        removeDir(root)

    let registry = new_tool_registry()
    registry.register_builtin_filesystem_tool(root)

    let write_result = registry.invoke_tool(
      new_tool_context(),
      "filesystem",
      %*{"action": "write", "path": "notes/todo.txt", "content": "hello"}
    )
    check write_result["ok"].getBool() == true

    let read_result = registry.invoke_tool(
      new_tool_context(),
      "filesystem",
      %*{"action": "read", "path": "notes/todo.txt"}
    )
    check read_result["ok"].getBool() == true
    check read_result["result"]["content"].getStr() == "hello"

    let escape_result = registry.invoke_tool(
      new_tool_context(),
      "filesystem",
      %*{"action": "read", "path": "../outside.txt"}
    )
    check escape_result["ok"].getBool() == false
    check escape_result["code"].getStr() == ToolCodeExecFailed

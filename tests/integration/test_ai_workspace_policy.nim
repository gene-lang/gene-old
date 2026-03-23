import unittest
import std/json
import std/strutils

import ../src/genex/ai/tools
import ../src/genex/ai/workspace_policy


suite "Workspace policy engine":
  test "allows by default when no permissions set":
    let engine = new_workspace_policy_engine()
    let ctx = new_tool_context(run_id = "r1", workspace_id = "ws1", user_id = "u1")
    let decision = engine.workspace_policy_check(ctx, "shell", newJObject())
    check decision.allowed

  test "denies when workspace_id missing":
    let engine = new_workspace_policy_engine()
    let ctx = new_tool_context(run_id = "r1", workspace_id = "", user_id = "u1")
    let decision = engine.workspace_policy_check(ctx, "shell", newJObject())
    check not decision.allowed
    check decision.reason.contains("missing workspace_id")

  test "denies globally denied tools":
    let engine = new_workspace_policy_engine()
    engine.default_denied_tools = @["dangerous_tool"]

    let ctx = new_tool_context(workspace_id = "ws1")
    let d1 = engine.workspace_policy_check(ctx, "dangerous_tool", newJObject())
    check not d1.allowed
    check d1.reason.contains("globally denied")

    # Other tools still allowed
    let d2 = engine.workspace_policy_check(ctx, "shell", newJObject())
    check d2.allowed

  test "enforces workspace tool allowlist":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      allowed_tools: @["shell", "filesystem"]
    ))

    let ctx = new_tool_context(workspace_id = "ws1")

    # Allowed tools pass
    check engine.workspace_policy_check(ctx, "shell", newJObject()).allowed
    check engine.workspace_policy_check(ctx, "filesystem", newJObject()).allowed

    # Unlisted tool is denied
    let d = engine.workspace_policy_check(ctx, "http_fetch", newJObject())
    check not d.allowed
    check d.reason.contains("not in workspace allowlist")

  test "workspace denied_tools overrides":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      denied_tools: @["shell"]
    ))

    let ctx = new_tool_context(workspace_id = "ws1")
    let d = engine.workspace_policy_check(ctx, "shell", newJObject())
    check not d.allowed
    check d.reason.contains("denied for workspace")

  test "filesystem root enforcement":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      filesystem_roots: @["/home/ws1/data"]
    ))

    let ctx = new_tool_context(workspace_id = "ws1")

    # Path within root is allowed
    let d1 = engine.workspace_policy_check(ctx, "filesystem",
      %*{"path": "/home/ws1/data/file.txt"})
    check d1.allowed

    # Path outside root is denied
    let d2 = engine.workspace_policy_check(ctx, "filesystem",
      %*{"path": "/etc/passwd"})
    check not d2.allowed
    check d2.reason.contains("outside allowed roots")

  test "shell command allowlist per workspace":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      shell_allowlist: @["ls", "cat", "echo"]
    ))

    let ctx = new_tool_context(workspace_id = "ws1")

    let d1 = engine.workspace_policy_check(ctx, "shell",
      %*{"argv": ["ls", "-la"]})
    check d1.allowed

    let d2 = engine.workspace_policy_check(ctx, "shell",
      %*{"argv": ["rm", "-rf", "/"]})
    check not d2.allowed
    check d2.reason.contains("not in workspace shell allowlist")

  test "cross-workspace isolation":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      allowed_tools: @["shell"],
      filesystem_roots: @["/data/ws1"]
    ))
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws2",
      allowed_tools: @["filesystem"],
      filesystem_roots: @["/data/ws2"]
    ))

    let ctx1 = new_tool_context(workspace_id = "ws1")
    let ctx2 = new_tool_context(workspace_id = "ws2")

    # ws1 can use shell but not filesystem
    check engine.workspace_policy_check(ctx1, "shell", newJObject()).allowed
    check not engine.workspace_policy_check(ctx1, "filesystem", newJObject()).allowed

    # ws2 can use filesystem but not shell
    check engine.workspace_policy_check(ctx2, "filesystem", newJObject()).allowed
    check not engine.workspace_policy_check(ctx2, "shell", newJObject()).allowed

    # ws2 cannot access ws1's filesystem root
    let d = engine.workspace_policy_check(ctx2, "filesystem",
      %*{"path": "/data/ws1/secret.txt"})
    check not d.allowed

  test "make_tool_policy creates compatible closure":
    let engine = new_workspace_policy_engine()
    engine.set_workspace_permission(WorkspacePermission(
      workspace_id: "ws1",
      denied_tools: @["shell"]
    ))

    let policy = engine.make_tool_policy()
    let registry = new_tool_registry()
    registry.set_tool_policy(policy)

    # The policy is now usable as a ToolPolicy
    let ctx = new_tool_context(workspace_id = "ws1")
    let decision = policy(ctx, "shell", newJObject())
    check not decision.allowed

  test "secret redaction in text":
    let engine = new_workspace_policy_engine()
    let text = """{"api_key":"sk-1234567890","name":"test"}"""
    let redacted = engine.redact_secrets(text)
    check not redacted.contains("sk-1234567890")
    check redacted.contains("REDACTED")

import unittest
import std/json
import std/strutils

import ../src/genex/ai/utils
import ../src/genex/ai/conversation

suite "AI runtime contracts":
  test "CommandEnvelope JSON roundtrip":
    let cmd = new_command_envelope(
      command_id = "c-1",
      source = CsSlack,
      workspace_id = "ws-1",
      user_id = "u-1",
      channel_id = "ch-1",
      thread_id = "th-1",
      text = "run tool",
      metadata = %*{"priority": "high"}
    )

    let decoded = command_from_json(command_to_json(cmd))
    check decoded.command_id == "c-1"
    check decoded.source == CsSlack
    check decoded.workspace_id == "ws-1"
    check decoded.metadata["priority"].getStr() == "high"

  test "AgentRun state machine accepts valid transitions":
    var run = new_agent_run("run-1")
    check run.state == ArsQueued

    run.apply_event(AreStart)
    check run.state == ArsRunning

    run.apply_event(AreWaitTool)
    check run.state == ArsWaitingTool

    run.apply_event(AreToolResult)
    check run.state == ArsRunning

    run.apply_event(AreComplete)
    check run.state == ArsCompleted

  test "AgentRun rejects invalid transitions":
    var run = new_agent_run("run-2")
    expect(ValueError):
      run.apply_event(AreComplete)

    run.apply_event(AreStart)
    run.apply_event(AreFail, "boom")
    check run.state == ArsFailed
    check run.error_message.contains("boom")

    expect(ValueError):
      run.apply_event(AreStart)

suite "Conversation store":
  test "append/recent/prune":
    let store = new_conversation_store()
    store.append_message("s-1", "user", "hello")
    store.append_message("s-1", "assistant", "hi")
    store.append_message("s-1", "user", "next")

    let recent2 = store.get_recent("s-1", 2)
    check recent2.len == 2
    check recent2[0].content == "hi"
    check recent2[1].content == "next"

    let summary = store.summarize_recent("s-1", 3)
    check summary.contains("user: hello")
    check summary.contains("assistant: hi")

    store.prune_session("s-1", 1)
    let after = store.get_recent("s-1", 10)
    check after.len == 1
    check after[0].content == "next"

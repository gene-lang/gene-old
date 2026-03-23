import unittest
import std/json
import std/os
import std/strutils

import ../src/genex/ai/memory_store


const TEST_DB = "/tmp/test_memory_store.db"

proc fresh_store(): MemoryStore =
  if fileExists(TEST_DB):
    removeFile(TEST_DB)
  new_memory_store(TEST_DB)


suite "Memory store (SQLite)":
  test "append and retrieve recent events":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "hello")
    store.append_event("ws1", "s1", "assistant", "hi there")
    store.append_event("ws1", "s1", "user", "how are you?")

    let recent = store.get_recent("s1", 10)
    check recent.len == 3
    check recent[0].role == "user"
    check recent[0].content == "hello"
    check recent[2].role == "user"
    check recent[2].content == "how are you?"

  test "recent respects limit":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "msg1")
    store.append_event("ws1", "s1", "user", "msg2")
    store.append_event("ws1", "s1", "user", "msg3")

    let recent = store.get_recent("s1", 2)
    check recent.len == 2
    check recent[0].content == "msg2"
    check recent[1].content == "msg3"

  test "retrieve by workspace scope":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "ws1 msg")
    store.append_event("ws2", "s2", "user", "ws2 msg")
    store.append_event("ws1", "s3", "user", "ws1 other")

    let ws1_events = store.retrieve("ws1")
    check ws1_events.len == 2

    let ws2_events = store.retrieve("ws2")
    check ws2_events.len == 1
    check ws2_events[0].content == "ws2 msg"

  test "retrieve with query filter":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "deploy to production")
    store.append_event("ws1", "s1", "assistant", "deploying now")
    store.append_event("ws1", "s1", "user", "check status")

    let deploy_events = store.retrieve("ws1", query = "deploy")
    check deploy_events.len == 2
    check deploy_events[0].content == "deploy to production"
    check deploy_events[1].content == "deploying now"

  test "prune keeps only recent events":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "old1")
    store.append_event("ws1", "s1", "user", "old2")
    store.append_event("ws1", "s1", "user", "keep1")
    store.append_event("ws1", "s1", "user", "keep2")

    store.prune_session("s1", 2)

    let remaining = store.get_recent("s1", 10)
    check remaining.len == 2
    check remaining[0].content == "keep1"
    check remaining[1].content == "keep2"

  test "summarize produces transcript":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "what time is it?")
    store.append_event("ws1", "s1", "assistant", "it is noon")

    let summary = store.summarize_recent("s1", 10)
    check summary.contains("user: what time is it?")
    check summary.contains("assistant: it is noon")

  test "summary checkpoints":
    let store = fresh_store()
    defer: store.close()

    store.save_summary("s1", "discussed deployment plans", 1000, 2000)
    store.save_summary("s1", "resolved auth issue", 2000, 3000)

    let summaries = store.get_summaries("s1", 5)
    check summaries.len == 2
    check summaries[0]["summary"].getStr() == "resolved auth issue"
    check summaries[1]["summary"].getStr() == "discussed deployment plans"

  test "event count":
    let store = fresh_store()
    defer: store.close()

    check store.event_count("s1") == 0
    store.append_event("ws1", "s1", "user", "msg1")
    store.append_event("ws1", "s1", "user", "msg2")
    check store.event_count("s1") == 2

  test "persistence across reopen":
    block:
      let store = fresh_store()
      store.append_event("ws1", "s1", "user", "persistent msg")
      store.close()

    block:
      let store = new_memory_store(TEST_DB)
      defer: store.close()
      let recent = store.get_recent("s1", 10)
      check recent.len == 1
      check recent[0].content == "persistent msg"

  test "metadata preserved":
    let store = fresh_store()
    defer: store.close()

    store.append_event("ws1", "s1", "user", "with meta",
      %*{"user_id": "U1", "priority": "high"})

    let recent = store.get_recent("s1", 1)
    check recent.len == 1
    check recent[0].metadata["user_id"].getStr() == "U1"
    check recent[0].metadata["priority"].getStr() == "high"

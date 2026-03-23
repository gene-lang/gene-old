import unittest
import std/json
import std/os

import ../src/genex/ai/scheduler

suite "AI scheduler":
  test "interval job dispatch and persistence":
    let store_file = getTempDir() / "gene-ai-scheduler-test.json"
    if fileExists(store_file):
      removeFile(store_file)
    defer:
      if fileExists(store_file):
        removeFile(store_file)

    let store = new_scheduler_store(store_file)
    discard store.create_interval_job(
      job_id = "job-1",
      workspace_id = "ws-1",
      payload = %*{"task": "run"},
      interval_ms = 1000,
      first_run_ms = 5000
    )

    # Re-open from disk to verify durability.
    let reopened = new_scheduler_store(store_file)
    let loaded = reopened.get_job("job-1")
    check loaded.job_id == "job-1"
    check loaded.workspace_id == "ws-1"

    let due = reopened.tick(now_ms = 5000)
    check due.len == 1
    check due[0].job_id == "job-1"

    let updated = reopened.get_job("job-1")
    check updated.next_run_ms == 6000

  test "pause resume and cancel":
    let store = new_scheduler_store()
    discard store.create_interval_job(
      job_id = "job-2",
      workspace_id = "ws-1",
      payload = newJObject(),
      interval_ms = 1000,
      first_run_ms = 0
    )

    check store.pause_job("job-2")
    check store.get_job("job-2").state == SjsPaused

    check store.resume_job("job-2")
    check store.get_job("job-2").state == SjsActive

    check store.cancel_job("job-2")
    check store.get_job("job-2").state == SjsCancelled

  test "retry and dead-letter policy":
    let store = new_scheduler_store()
    discard store.create_interval_job(
      job_id = "job-3",
      workspace_id = "ws-1",
      payload = newJObject(),
      interval_ms = 1000,
      first_run_ms = 0,
      retry_policy = RetryPolicy(max_retries: 1, backoff_ms: 2000)
    )

    check store.mark_job_failure("job-3", "first", now_ms = 10000)
    var job = store.get_job("job-3")
    check job.state == SjsActive
    check job.retry_count == 1
    check job.next_run_ms == 12000

    check store.mark_job_failure("job-3", "second", now_ms = 13000)
    job = store.get_job("job-3")
    check job.state == SjsDeadLetter

  test "tick ignores paused and cancelled jobs":
    let store = new_scheduler_store()
    discard store.create_interval_job("job-a", "ws", newJObject(), 1000, 0)
    discard store.create_interval_job("job-b", "ws", newJObject(), 1000, 0)
    discard store.create_interval_job("job-c", "ws", newJObject(), 1000, 0)

    discard store.pause_job("job-b")
    discard store.cancel_job("job-c")

    let due = store.tick(now_ms = 5000)
    check due.len == 1
    check due[0].job_id == "job-a"

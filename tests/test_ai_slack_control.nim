import unittest
import std/json

import ../src/genex/ai/control_slack
import ../src/genex/ai/utils

suite "Slack control adapter":
  test "signature verify accepts valid signature":
    let secret = "slack-secret"
    let body = "{\"type\":\"event_callback\",\"event_id\":\"Ev1\"}"
    let ts = "1700000000"
    let sig = compute_slack_signature(secret, ts, body)

    let result = verify_slack_signature(
      signing_secret = secret,
      timestamp_sec = ts,
      provided_signature = sig,
      raw_body = body,
      now_ms = 1700000000'i64 * 1000,
      max_skew_sec = 300
    )

    check result.ok

  test "signature verify rejects mismatch and stale timestamp":
    let bad_sig = verify_slack_signature(
      signing_secret = "s",
      timestamp_sec = "1700000000",
      provided_signature = "v0=deadbeef",
      raw_body = "{}",
      now_ms = 1700000000'i64 * 1000,
      max_skew_sec = 300
    )
    check not bad_sig.ok

    let stale = verify_slack_signature(
      signing_secret = "s",
      timestamp_sec = "1690000000",
      provided_signature = compute_slack_signature("s", "1690000000", "{}"),
      raw_body = "{}",
      now_ms = 1700000000'i64 * 1000,
      max_skew_sec = 300
    )
    check not stale.ok
    check stale.reason == "stale timestamp"

  test "url verification helpers":
    let payload = %*{"type": "url_verification", "challenge": "abc123"}
    check is_slack_url_verification(payload)
    check slack_url_challenge(payload) == "abc123"

  test "event callback maps to CommandEnvelope":
    let payload = %*{
      "type": "event_callback",
      "team_id": "T123",
      "event_id": "Ev123",
      "event_time": 1700000000,
      "event": {
        "type": "message",
        "user": "U123",
        "text": "run build",
        "channel": "C123",
        "ts": "1700000000.001",
        "thread_ts": "1700000000.000"
      }
    }

    let cmd = slack_event_to_command(payload)
    check cmd.source == CsSlack
    check cmd.command_id == "Ev123"
    check cmd.workspace_id == "T123"
    check cmd.user_id == "U123"
    check cmd.channel_id == "C123"
    check cmd.thread_id == "1700000000.000"
    check cmd.text == "run build"
    check cmd.metadata["event_type"].getStr() == "message"

  test "file attachments are normalized into attachments":
    let payload = %*{
      "type": "event_callback",
      "team_id": "T123",
      "event_id": "EvFile",
      "event": {
        "type": "message",
        "subtype": "file_share",
        "user": "U123",
        "text": "please review",
        "channel": "C123",
        "ts": "1700000000.001",
        "files": [
          {
            "id": "F123",
            "name": "spec.pdf",
            "title": "spec.pdf",
            "mimetype": "application/pdf",
            "size": 1234,
            "url_private": "https://files.slack.test/spec.pdf"
          }
        ]
      }
    }

    let cmd = slack_event_to_command(payload)
    check cmd.attachments.kind == JArray
    check cmd.attachments.len == 1
    check cmd.attachments[0]["file_id"].getStr() == "F123"
    check cmd.attachments[0]["filename"].getStr() == "spec.pdf"
    check cmd.attachments[0]["download_url"].getStr() == "https://files.slack.test/spec.pdf"
    check cmd.metadata["attachments_count"].getInt() == 1

  test "file only messages are accepted":
    let payload = %*{
      "type": "event_callback",
      "team_id": "T123",
      "event_id": "EvFileOnly",
      "event": {
        "type": "message",
        "subtype": "file_share",
        "user": "U123",
        "text": "",
        "channel": "C123",
        "ts": "1700000000.001",
        "file": {
          "id": "F999",
          "name": "notes.txt",
          "mimetype": "text/plain",
          "size": 12,
          "url_private_download": "https://files.slack.test/notes.txt"
        }
      }
    }

    let cmd = slack_event_to_command(payload)
    check cmd.text == ""
    check cmd.attachments.len == 1
    check cmd.attachments[0]["file_id"].getStr() == "F999"

  test "bot messages are ignored":
    let payload = %*{
      "type": "event_callback",
      "event_id": "EvBot",
      "event": {
        "type": "message",
        "bot_id": "B123",
        "text": "ignored",
        "channel": "C123"
      }
    }

    expect(ValueError):
      discard slack_event_to_command(payload)

  test "replay guard deduplicates event ids":
    let guard = new_slack_replay_guard(ttl_sec = 10)
    check not guard.mark_or_is_duplicate("Ev1", now_ms = 1000)
    check guard.mark_or_is_duplicate("Ev1", now_ms = 2000)

    # After ttl, event id is expired and can be accepted again.
    guard.cleanup_replay_guard(now_ms = 12000)
    check not guard.mark_or_is_duplicate("Ev1", now_ms = 12000)

  test "reply target from envelope":
    let cmd = new_command_envelope(
      command_id = "c-1",
      source = CsSlack,
      channel_id = "C-chan",
      thread_id = "1700000000.000"
    )
    let target = reply_target_from_envelope(cmd)
    check target.channel == "C-chan"
    check target.thread_ts == "1700000000.000"

  test "slack reply rejects invalid inputs":
    # nil client
    let r0 = slack_reply(nil, SlackReplyTarget(channel: "C1"), "hello")
    check not r0.ok
    check r0.error == "missing bot token"

    let client = new_slack_client(bot_token = "xoxb-test")

    # missing channel
    let r1 = client.slack_reply(SlackReplyTarget(channel: ""), "hello")
    check not r1.ok
    check r1.error == "missing channel"

    # empty message
    let r2 = client.slack_reply(SlackReplyTarget(channel: "C1"), "")
    check not r2.ok
    check r2.error == "empty message"

  test "slack ack json":
    let ack = slack_ack_json()
    check ack["ok"].getBool() == true

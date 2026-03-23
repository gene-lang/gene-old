import unittest
import std/strutils

import ../src/genex/websocket

suite "WebSocket frame encoding":
  test "encode small text frame (server, no mask)":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let frame = encode_frame(ws, WsOpText, "Hello")
    # Byte 0: 0x81 (FIN + opcode 1)
    # Byte 1: 0x05 (no mask, length 5)
    # Bytes 2-6: "Hello"
    check frame.len == 2 + 5
    check uint8(frame[0]) == 0x81'u8
    check uint8(frame[1]) == 0x05'u8
    check frame[2..^1] == "Hello"

  test "encode empty frame":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let frame = encode_frame(ws, WsOpText, "")
    check frame.len == 2
    check uint8(frame[0]) == 0x81'u8
    check uint8(frame[1]) == 0x00'u8

  test "encode close frame":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let frame = encode_frame(ws, WsOpClose, "")
    check uint8(frame[0]) == 0x88'u8  # FIN + opcode 8
    check uint8(frame[1]) == 0x00'u8

  test "encode ping frame":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let frame = encode_frame(ws, WsOpPing, "ping")
    check uint8(frame[0]) == 0x89'u8  # FIN + opcode 9
    check frame[2..^1] == "ping"

  test "client frame has mask bit set":
    let ws = WebSocket(socket: nil, is_client: true, closed: false)
    let frame = encode_frame(ws, WsOpText, "Hi")
    # Byte 1 should have mask bit (0x80) set
    check (uint8(frame[1]) and 0x80'u8) == 0x80'u8
    # Payload length should be 2
    check (uint8(frame[1]) and 0x7F'u8) == 2'u8
    # Total: 2 header + 4 mask key + 2 payload = 8
    check frame.len == 8

  test "encode medium payload (126-65535 bytes)":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let payload = repeat('A', 300)
    let frame = encode_frame(ws, WsOpText, payload)
    # Byte 1: 126 (extended 16-bit length follows)
    check (uint8(frame[1]) and 0x7F'u8) == 126'u8
    # Bytes 2-3: 16-bit length (300 = 0x012C)
    check uint8(frame[2]) == 0x01'u8
    check uint8(frame[3]) == 0x2C'u8
    check frame.len == 4 + 300

suite "WebSocket frame decoding":
  test "decode small unmasked text frame":
    var data = ""
    data.add(char(0x81))  # FIN + text
    data.add(char(0x05))  # no mask, length 5
    data.add("Hello")

    let (frame, consumed) = decode_frame(data)
    check consumed == 7
    check frame.fin == true
    check frame.opcode == WsOpText
    check frame.payload == "Hello"

  test "decode masked text frame":
    let mask: array[4, byte] = [0x37'u8, 0xfa'u8, 0x21'u8, 0x3d'u8]
    let plain = "Hello"
    var masked_payload = ""
    for i in 0..<plain.len:
      masked_payload.add(char(byte(plain[i]) xor mask[i mod 4]))

    var data = ""
    data.add(char(0x81))  # FIN + text
    data.add(char(0x85))  # mask bit + length 5
    for b in mask:
      data.add(char(b))
    data.add(masked_payload)

    let (frame, consumed) = decode_frame(data)
    check consumed == 2 + 4 + 5
    check frame.payload == "Hello"

  test "decode returns 0 for incomplete data":
    let (_, consumed) = decode_frame("x")
    check consumed == 0

  test "decode returns 0 when payload incomplete":
    var data = ""
    data.add(char(0x81))
    data.add(char(0x05))  # expects 5 bytes
    data.add("Hi")        # only 2

    let (_, consumed) = decode_frame(data)
    check consumed == 0

  test "decode close frame":
    var data = ""
    data.add(char(0x88))  # FIN + close
    data.add(char(0x00))  # no payload

    let (frame, consumed) = decode_frame(data)
    check consumed == 2
    check frame.opcode == WsOpClose
    check frame.payload == ""

  test "decode medium-length frame":
    var data = ""
    data.add(char(0x82))  # FIN + binary
    data.add(char(0x7E))  # 126 = extended 16-bit length
    data.add(char(0x01))  # high byte
    data.add(char(0x00))  # low byte → 256
    let payload = repeat('B', 256)
    data.add(payload)

    let (frame, consumed) = decode_frame(data)
    check consumed == 4 + 256
    check frame.opcode == WsOpBinary
    check frame.payload.len == 256

suite "WebSocket round-trip":
  test "server encode -> decode round-trip":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let original = "Hello, WebSocket!"
    let encoded = encode_frame(ws, WsOpText, original)
    let (decoded, consumed) = decode_frame(encoded)
    check consumed == encoded.len
    check decoded.fin == true
    check decoded.opcode == WsOpText
    check decoded.payload == original

  test "client encode -> decode round-trip (with masking)":
    let ws = WebSocket(socket: nil, is_client: true, closed: false)
    let original = "Masked message"
    let encoded = encode_frame(ws, WsOpText, original)
    let (decoded, consumed) = decode_frame(encoded)
    check consumed == encoded.len
    check decoded.fin == true
    check decoded.opcode == WsOpText
    check decoded.payload == original

  test "multiple frames in buffer":
    let ws = WebSocket(socket: nil, is_client: false, closed: false)
    let frame1 = encode_frame(ws, WsOpText, "first")
    let frame2 = encode_frame(ws, WsOpText, "second")
    let combined = frame1 & frame2

    let (f1, c1) = decode_frame(combined)
    check f1.payload == "first"
    check c1 == frame1.len

    let remaining = combined[c1..^1]
    let (f2, c2) = decode_frame(remaining)
    check f2.payload == "second"
    check c2 == frame2.len

suite "WebSocket handshake":
  test "compute_accept_key known vector":
    # Verified with OpenSSL: echo -n "key+GUID" | openssl sha1 -binary | base64
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    let accept = compute_accept_key(key)
    check accept == "QxKaYlvJFtzGNk9DG2KcnywDxSQ="

  test "generate_ws_key returns base64":
    let key = generate_ws_key()
    # Base64 of 16 bytes = 24 chars (with padding)
    check key.len == 24
    # Should only contain base64 characters
    for c in key:
      check c in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}

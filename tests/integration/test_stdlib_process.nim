import ../helpers

test_vm """
  (var p (system/Process/start "echo" "hello"))
  (assert (p/pid > 0))
  (var output (p .read_line ^timeout 5))
  (assert (output == "hello"))
  (var code (p .wait ^timeout 5))
  (assert (code == 0))
  p/exit_code
""", 0

test_vm """
  (var p (system/Process/start "cat" ^stderr_to_stdout true))
  (p .write_line "test")
  (var line (p .read_line ^timeout 5))
  (assert (line == "test"))
  (p .close_stdin)
  (var code (p .wait ^timeout 5))
  (assert (code == 0))
  code
""", 0

test_vm """
  (var p (system/Process/start "sleep" "1"))
  (var first (p .wait ^timeout 0.05))
  (assert (first == nil))
  (assert (p .alive?))
  (p .signal "KILL")
  (var code (p .wait ^timeout 5))
  (assert (code == 137))
  code
""", 137

test_vm """
  (var p (system/Process/start "sh" "-c" "exit 42"))
  (var code (p .wait ^timeout 5))
  (assert (code == 42))
  p/exit_code
""", 42

test_vm """
  (var p (system/Process/start "sh" "-c" "echo err >&2"))
  (var err (p .read_stderr ^timeout 5))
  (assert (err .contain "err"))
  (var code (p .wait ^timeout 5))
  (assert (code == 0))
  code
""", 0

test_vm """
  (var p (system/Process/start "cat"))
  (var code (p .shutdown ^timeout 5))
  (assert (code == 0))
  code
""", 0

test_vm """
  (var p (system/Process/start "sh" "-c" "exec sleep 5"))
  (var code (p .shutdown ^timeout 1))
  (assert (code == 143))
  code
""", 143

test_vm """
  (var p (system/Process/start "sh" "-c" "trap '' TERM; exec sleep 5"))
  (var code (p .shutdown ^timeout 1))
  (assert (code == 137))
  code
""", 137

test_vm """
  (var p (system/Process/start "sh" "-c" "echo err >&2; echo out" ^stderr_to_stdout true))
  (var line1 (p .read_line ^timeout 5))
  (var line2 (p .read_line ^timeout 5))
  (var combined #"#{line1} #{line2}")
  (assert (combined .contain "err"))
  (assert (combined .contain "out"))
  (var code (p .wait ^timeout 5))
  (assert (code == 0))
  code
""", 0

test_vm """
  (var p (system/Process/start "sh" "-c" "printf 'helloXworldX'"))
  (var first (p .read_until "X" ^timeout 5))
  (assert (first == "helloX"))
  (var second (p .read_until "X" ^timeout 5))
  (assert (second == "worldX"))
  (var code (p .wait ^timeout 5))
  (assert (code == 0))
  second
""", "worldX"

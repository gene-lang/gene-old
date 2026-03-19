import std/[os, osproc, streams, strutils, times, unittest]

when not defined(windows):
  import posix

const ReadChunkSize = 256

proc geneBin(): string =
  absolutePath("bin/gene")

proc makeTempScript(name: string, body: string): string =
  let dir = getTempDir() / ("gene-stdio-" & $(epochTime() * 1_000_000.0).int64 & "-" & $name.len)
  createDir(dir)
  let path = dir / name
  writeFile(path, body)
  path

proc startGene(scriptPath: string): Process =
  startProcess(
    command = geneBin(),
    args = @["run", "--no-gir-cache", scriptPath],
    options = {poUsePath}
  )

when not defined(windows):
  proc waitForReadable(handle: FileHandle, timeoutMs: int): bool =
    var readFds: TFdSet = default(TFdSet)
    FD_ZERO(readFds)
    FD_SET(cint(handle), readFds)
    var tv = Timeval(
      tv_sec: posix.Time(timeoutMs div 1000),
      tv_usec: Suseconds((timeoutMs mod 1000) * 1000)
    )
    let rc = posix.select(cint(handle) + 1, addr(readFds), nil, nil, addr(tv))
    rc > 0 and FD_ISSET(cint(handle), readFds) != 0'i32

  proc readUntil(handle: FileHandle, delimiter: string, timeoutMs: int): string =
    var buffer = ""
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while epochTime() < deadline:
      let remaining = max(0, int((deadline - epochTime()) * 1000.0))
      if not waitForReadable(handle, remaining):
        break

      var chunk = newString(ReadChunkSize)
      let readBytes = posix.read(handle, addr chunk[0], ReadChunkSize)
      if readBytes <= 0:
        break
      buffer.add(chunk[0 ..< readBytes])
      if delimiter.len == 0 or buffer.contains(delimiter):
        break
    buffer

suite "Stdlib console IO":
  test "flush exposes prompt before stdin is read":
    let script = makeTempScript("flush_readline.gene", """
(stdout .write "ready>")
(flush stdout)
(var input (readline))
(if (input == nil)
  (println "EOF")
else
  (println #"line=#{input}")
)
""")
    defer:
      try:
        removeFile(script)
        removeDir(parentDir(script))
      except CatchableError:
        discard

    check fileExists(geneBin())
    let p = startGene(script)
    defer:
      try:
        close(p)
      except CatchableError:
        discard

    let prompt = readUntil(outputHandle(p), "ready>", 2000)
    check prompt == "ready>"

    let input = inputStream(p)
    input.write("hello\n")
    input.flush()

    let line = readUntil(outputHandle(p), "\n", 2000)
    check line == "line=hello\n"
    check waitForExit(p, 2000) == 0

  test "readline returns nil on EOF":
    let script = makeTempScript("readline_eof.gene", """
(var input (readline))
(if (input == nil)
  (println "EOF")
else
  (println #"line=#{input}")
)
""")
    defer:
      try:
        removeFile(script)
        removeDir(parentDir(script))
      except CatchableError:
        discard

    check fileExists(geneBin())
    let p = startGene(script)
    defer:
      try:
        close(p)
      except CatchableError:
        discard

    inputStream(p).close()
    let line = readUntil(outputHandle(p), "\n", 2000)
    check line == "EOF\n"
    check waitForExit(p, 2000) == 0

  test "on_signal dispatches INT handler while readline is blocked":
    let script = makeTempScript("signal_handler.gene", """
(on_signal "INT" (fn []
  (stdout .write_line "INT")
  (flush stdout)
  (exit 0)
))
(stdout .write "wait>")
(flush stdout)
(readline)
""")
    defer:
      try:
        removeFile(script)
        removeDir(parentDir(script))
      except CatchableError:
        discard

    check fileExists(geneBin())
    let p = startGene(script)
    defer:
      try:
        close(p)
      except CatchableError:
        discard

    let prompt = readUntil(outputHandle(p), "wait>", 2000)
    check prompt == "wait>"

    discard kill(Pid(processID(p)), SIGINT)
    let line = readUntil(outputHandle(p), "\n", 2000)
    check line == "INT\n"
    check waitForExit(p, 2000) == 0

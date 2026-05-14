## Integration test for bash tool streaming via pty + stub model.
##
## Spawns 3code (built with -d:providerStub) inside a pty, feeds a stub
## response that triggers a bash tool call with slow output, and checks
## that bash lines arrive incrementally over time.
##
## Build the stub binary first:
##   nim c -d:providerStub --threads:on -o:/tmp/3code-stub src/threecode.nim
##
## Run:
##   nim r tests/test_streaming.nim

import std/[os, posix, strformat, strutils, times]

proc openpty(masterFd, slaveFd: ptr cint; name: pointer; termp: pointer; winp: pointer): cint
  {.cdecl, importc: "openpty", header: "<pty.h>".}

proc login_tty(fd: cint): cint
  {.cdecl, importc: "login_tty", header: "<utmp.h>".}

proc die(msg: string) =
  stderr.writeLine msg
  quit 1

# Stub response: bash tool that emits 5 lines with 0.3s delays,
# then a final text reply.
const StubJson = """[{
  "role": "assistant",
  "content": null,
  "tool_calls": [{
    "id": "call_stub_1",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\": \"for i in 1 2 3 4 5; do echo LINE_$i; sleep 0.3; done\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "Done."
}]"""

proc main() =
  let testDir = getTempDir() / "3code_stream_test"
  removeDir(testDir)
  createDir(testDir)
  writeFile(testDir / "stub_responses.json", StubJson)

  let bin = "/tmp/3code-stub"
  if not fileExists(bin):
    die "Build stub binary first:\n  nim c -d:providerStub --threads:on -o:/tmp/3code-stub src/threecode.nim"

  var masterFd, slaveFd: cint
  if openpty(addr masterFd, addr slaveFd, nil, nil, nil) != 0:
    die "openpty failed"

  let pid = fork()
  if pid < 0:
    die "fork failed"

  if pid == 0:
    discard close(masterFd)
    discard login_tty(slaveFd)
    putEnv("TERM", "xterm-256color")
    setCurrentDir(testDir)
    discard execl(bin.cstring, "3code".cstring, "echo hello".cstring, nil)
    quit 1

  # Parent
  discard close(slaveFd)

  var bashLineTimes: seq[float] = @[]
  var allClean = ""  # plaintext output (stripped of escapes)
  var lastLine = ""
  let t0 = epochTime()
  let deadline = t0 + 15.0
  var buf: array[4096, char]
  var childDead = false

  while epochTime() < deadline:
    var pfd: TPollfd
    pfd.fd = masterFd
    pfd.events = POLLIN
    let r = poll(addr pfd, 1, 200.cint)
    if r > 0 and (pfd.revents and POLLIN) != 0:
      let n = posix.read(masterFd, addr buf[0], buf.len)
      if n <= 0: break
      for i in 0 ..< n:
        let ch = buf[i]
        if ch == '\n':
          let plain = lastLine.strip()
          allClean.add plain & "\n"
          if "LINE_" in plain:
            let now = epochTime() - t0
            bashLineTimes.add(now)
            echo &"  bash line at t={now:.3f}s: {plain}"
          lastLine.setLen(0)
        elif ch != '\r':
          lastLine.add ch
    elif not childDead:
      var status: cint = 0
      if waitpid(pid, status, WNOHANG) > 0:
        childDead = true
        # drain remaining
        while true:
          var p2: TPollfd
          p2.fd = masterFd
          p2.events = POLLIN
          if poll(addr p2, 1, 100.cint) <= 0: break
          let n = posix.read(masterFd, addr buf[0], buf.len)
          if n <= 0: break
          for i in 0 ..< n:
            let ch = buf[i]
            if ch == '\n':
              let plain = lastLine.strip()
              allClean.add plain & "\n"
              if "LINE_" in plain:
                let now = epochTime() - t0
                bashLineTimes.add(now)
                echo &"  bash line at t={now:.3f}s: {plain}"
              lastLine.setLen(0)
            elif ch != '\r':
              lastLine.add ch
        break

  discard close(masterFd)
  var status: cint = 0
  discard waitpid(pid, status, 0)

  echo &"\nBash lines received: {bashLineTimes.len}"

  # Check: at least 5 unique LINE_N markers during streaming
  let uniqueLines = bashLineTimes.len
  if uniqueLines < 5:
    die &"FAIL: expected >= 5 streaming bash lines, got {uniqueLines}"

  # Check: lines arrived spread over time, not all at once
  if bashLineTimes.len >= 2:
    let spread = bashLineTimes[^1] - bashLineTimes[0]
    echo &"Spread: {spread:.3f}s"
    if spread < 0.5:
      die &"FAIL: bash lines arrived too fast ({spread:.3f}s), not streaming"

  # Check: final model text "Done." appeared
  if "Done." notin allClean:
    die "FAIL: final model text 'Done.' not found in output"

  echo "PASS"
main()

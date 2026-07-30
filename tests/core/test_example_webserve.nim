discard """
  targets: "c"
  matrix: ""
"""
## End-to-end test for example/webserve.nim: the library's web frontend
## running against the stub provider, no network, no terminal.
##
## Builds the example with `-d:providerStub`, starts it with XDG roots and
## stub responses redirected into a fixture, then drives the HTTP
## endpoints: the page loads, a prompt turn streams its reply over SSE,
## and a colon command returns its body.

import std/[httpclient, json, nativesockets, net, os, osproc, posix, streams, strtabs,
            strutils,
            times, unittest]
import ../stub_helpers

const WebPort = 18991  # the example's own default is 8501; keep the test
                       # off it so a dev instance doesn't collide

proc buildExample(): string =
  ## Compile example/webserve.nim with the stub provider into build/,
  ## cached by mtime like the stub binary.
  result = getCurrentDir() / "build" / "example_webserve_stub"
  when defined(windows):
    result.add ".exe"
  if fileExists(result):
    let binMtime = getLastModificationTime(result)
    var stale = false
    for f in [getCurrentDir() / "example" / "webserve.nim"]:
      if getLastModificationTime(f) > binMtime: stale = true
    if not stale:
      for f in walkDirRec(getCurrentDir() / "src"):
        if f.endsWith(".nim") and getLastModificationTime(f) > binMtime:
          stale = true
          break
    if not stale: return
    removeFile(result)
  createDir(result.parentDir)
  var cmd = "nim c -d:ssl -d:providerStub --threads:on"
  cmd.add " " & nimbleDepFlags()
  cmd.add " --path:src --nimcache:" & (getCurrentDir() / "build" / "example_cache").quoteShell
  cmd.add " -o:" & result.quoteShell
  cmd.add " example/webserve.nim"
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp

proc newFixture(): string =
  result = getTempDir() / ("3code_webtest_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")
  writeFile(result / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")
  writeFile(result / "run" / "stub_responses.json", $(%*[
    {"content": "web reply", "contentChunks": ["web ", "reply"]}
  ]))

proc waitForPort(path: string; timeoutS = 15): bool =
  ## Poll until the server answers or the deadline passes.
  let deadline = epochTime() + timeoutS.float
  while epochTime() < deadline:
    try:
      let c = newHttpClient(timeout = 500)
      discard c.getContent(path)
      c.close()
      return true
    except CatchableError:
      sleep 100
  false

suite "example: webserve":
  test "page, prompt over SSE, and colon command":
    let bin = buildExample()
    let root = newFixture()
    var p = startProcess(bin, workingDir = root / "run",
      args = ["--port", $WebPort, "-x"],
      env = newStringTable({
        "XDG_CONFIG_HOME": root / "xdg",
        "XDG_DATA_HOME": root / "data",
        "THREECODE_STUB_RESPONSES": root / "run" / "stub_responses.json",
      }),
      options = {poStdErrToStdOut, poUsePath})
    defer:
      if p.running: p.terminate()
      discard p.waitForExit(3000)
      p.close()

    check waitForPort("http://localhost:" & $WebPort & "/")

    let client = newHttpClient(timeout = 10_000)
    defer: client.close()

    # The page loads.
    let page = client.getContent("http://localhost:" & $WebPort & "/")
    check page.contains("3code web")

    # A colon command runs on the session thread and returns its body.
    check client.post("http://localhost:" & $WebPort & "/command",
                      ":help").body.contains(":tokens")

    # A prompt turn streams over SSE. Open the event stream first, then
    # fire the prompt from a second connection.
    # Read SSE at the socket level: httpclient wants a complete body,
    # but an event stream never ends.
    var ss = newSocket()
    ss.connect("localhost", WebPort.Port, timeout = 10_000)
    ss.send("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var headers = ""
    while "\r\n\r\n" notin headers:
      headers.add ss.recv(1, timeout = 10_000)
    check headers.contains("200")
    check client.post("http://localhost:" & $WebPort & "/prompt",
                      "hello web").code == Http202
    # Read the stream until the turn end arrives (or timeout).
    var acc = ""
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not acc.contains("\"turnend\""):
      let chunk = try: ss.recv(256, timeout = 1_000)
        except TimeoutError: ""
        except CatchableError: break
      acc.add chunk
    ss.close()
    check acc.contains("web reply")
    check acc.contains("\"delta\"")
    check acc.contains("\"done\"")

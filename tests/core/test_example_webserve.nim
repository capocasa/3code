discard """
  targets: "c"
  matrix: ""
"""
## End-to-end test for docs/dev/example/webserve.nim: the library's web
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

proc freePort(): int =
  # Ephemeral, not a fixed number: two suite runs on one box (a second
  # worktree, another agent session) collide on a fixed port and fail or
  # cross-talk. Same pattern as test_oauth_loopback.
  let probe = newSocket()
  defer: probe.close()
  probe.bindAddr(Port(0), "127.0.0.1")
  probe.getLocalAddr()[1].int

proc buildExample(): string =
  ## Compile docs/dev/example/webserve.nim with the stub provider into
  ## cached by mtime like the stub binary.
  result = getCurrentDir() / "build" / "example_webserve_stub"
  when defined(windows):
    result.add ".exe"
  if fileExists(result):
    let binMtime = getLastModificationTime(result)
    var stale = false
    for f in [getCurrentDir() / "docs" / "dev" / "example" / "webserve.nim",
              getCurrentDir() / "tests" / "core" / "test_example_webserve.nim"]:
      if getLastModificationTime(f) > binMtime: stale = true
    if not stale:
      for f in walkDirRec(getCurrentDir() / "src"):
        if f.endsWith(".nim") and getLastModificationTime(f) > binMtime:
          stale = true
          break
    if not stale: return
    removeFile(result)
  createDir(result.parentDir)
  var cmd = "nim c --skipParentCfg:on -d:ssl -d:testPlainHttp -d:providerStub --threads:on"
  cmd.add " " & nimbleDepFlags()
  cmd.add " --path:" & (getCurrentDir() / "src").quoteShell
  cmd.add " --nimcache:" & (getCurrentDir() / "build" / "example_cache").quoteShell
  cmd.add " -o:" & result.quoteShell
  cmd.add " docs/dev/example/webserve.nim"
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
    {"content": "web reply", "contentChunks": ["web ", "reply"]},
    {"content": "second reply"}
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
    let webPort = freePort()
    var p = startProcess(bin, workingDir = root / "run",
      args = ["--port", $webPort, "-x"],
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

    check waitForPort("http://localhost:" & $webPort & "/")

    let client = newHttpClient(timeout = 10_000)
    defer: client.close()

    # The page loads.
    let page = client.getContent("http://localhost:" & $webPort & "/")
    check page.contains("3code web")

    # A colon command runs on the session thread and returns its body.
    check client.post("http://localhost:" & $webPort & "/command",
                      ":help").body.contains(":tokens")

    # A prompt turn streams over SSE. Open the event stream first, then
    # fire the prompt from a second connection.
    # Read SSE at the socket level: httpclient wants a complete body,
    # but an event stream never ends.
    var ss = newSocket()
    ss.connect("localhost", webPort.Port, timeout = 10_000)
    ss.send("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var headers = ""
    while "\r\n\r\n" notin headers:
      headers.add ss.recv(1, timeout = 10_000)
    check headers.contains("200")
    check client.post("http://localhost:" & $webPort & "/prompt",
                      "hello web").code == Http202
    # Read the stream until the turn end arrives (or timeout).
    var acc = ""
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not acc.contains("\"turnend\""):
      let chunk = try: ss.recv(1, timeout = 1_000)
        except TimeoutError: ""
        except CatchableError: break
      acc.add chunk
    check acc.contains("web reply")
    check acc.contains("\"delta\"")
    check acc.contains("\"done\"")

    # Discover a skill after the first request. Its listing must travel in
    # the next user message, not by rewriting the already-sent system prompt.
    createDir(root / "run" / ".3code" / "skills")
    writeFile(root / "run" / ".3code" / "skills" / "late.md", "PRIVATE SKILL BODY")
    check client.post("http://localhost:" & $webPort & "/prompt",
                      "continue").code == Http202
    acc = ""
    let secondDeadline = epochTime() + 10.0
    while epochTime() < secondDeadline and not acc.contains("\"turnend\""):
      let chunk = try: ss.recv(1, timeout = 1_000)
        except TimeoutError: ""
        except CatchableError: break
      acc.add chunk
    ss.close()
    check acc.contains("second reply")
    check acc.contains("\"turnend\"")
    var saved = ""
    for path in walkDirRec(root / "data"):
      if path.endsWith(".3log"): saved.add readFile(path)
    check saved.contains("<available_skills>")
    check saved.contains("late.md")
    check not saved.contains("PRIVATE SKILL BODY")

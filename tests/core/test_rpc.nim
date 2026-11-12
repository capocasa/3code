discard """
  action: "run"
  targets: "c"
  disabled: "win"
"""
## `3code --rpc` regressions for session lifecycle and failed frontend
## switching (finding 5). A failed `/session/new` must leave the server
## sessionless: no closed AgentSession answering `/prompt`, no stale
## session id or scrollback under a dead identity, and a later valid open
## (including the directory whose switch failed) must succeed.

import std/[httpclient, json, locks, os, osproc, streams, strtabs,
            strutils, times, unittest, uri]
import stub_helpers

type
  RpcProc = ref object
    p: Process
    port: int
    errLines: string
    errGate: Lock

proc drainErr(rpc: RpcProc) {.thread.} =
  var line = ""
  while rpc.p.errorStream.readLine(line):
    withLock rpc.errGate:
      rpc.errLines.add line & "\n"

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/core" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")
  createDir(result / "tmp"); createDir(result / "proj")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
sandbox = off

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc writeResponses(root, name: string; responses: JsonNode) =
  writeFile(root / "run" / name, $responses)

proc spawnRpc(bin, root, workDir, responses: string): RpcProc =
  new(result)
  let env = newStringTable()
  env["XDG_DATA_HOME"] = root / "data"
  env["XDG_CONFIG_HOME"] = root / "xdg"
  env["XDG_CACHE_HOME"] = root / "xdg" / "cache"
  env["TMPDIR"] = root / "tmp"
  env["HOME"] = root
  env["TERM"] = "dumb"
  env["PATH"] = getEnv("PATH")
  env["THREECODE_STUB_RESPONSES"] = responses
  result.p = startProcess(bin, workingDir = workDir, args = ["--rpc"],
                          env = env, options = {})
  initLock(result.errGate)
  var th: Thread[RpcProc]
  th.createThread(drainErr, result)
  # Startup line: `3code rpc listening on 127.0.0.1:PORT cwd=...`, printed
  # after the session open attempt (including its failure).
  let line = result.p.outputStream.readLine()
  doAssert line.startsWith("3code rpc listening on"), line
  let marker = "127.0.0.1:"
  let a = line.find(marker) + marker.len
  var b = a
  while b < line.len and line[b] in {'0'..'9'}: inc b
  result.port = parseInt(line[a ..< b])

proc closeRpc(rpc: RpcProc): int =
  if rpc.p == nil: return 0
  rpc.p.terminate()
  result = rpc.p.waitForExit(timeout = 10000)
  if rpc.p.running:
    rpc.p.kill()
    discard rpc.p.waitForExit(timeout = 5000)
  rpc.p.close()
  rpc.p = nil
  withLock rpc.errGate:
    if rpc.errLines.len > 0:
      checkpoint("subprocess stderr: " & rpc.errLines)

proc req(rpc: RpcProc; meth, path, body: string): tuple[code: int,
    text: string] =
  let client = newHttpClient(timeout = 40000)
  let resp = client.request(
    "http://127.0.0.1:" & $rpc.port & path, httpMethod = meth, body = body)
  result.code = resp.code.int
  result.text = resp.body

proc idRow(rpc: RpcProc): seq[string] =
  let (code, body) = rpc.req("GET", "/id", "")
  doAssert code == 200, body
  body.replace("\n", "").split('\t')

proc waitMarker(path: string; timeoutMs = 10000): bool =
  ## The stub writes `markerPath` when it has selected the response, just
  ## before its pre-stream delay: waiting for it puts the cancel inside
  ## the turn's parked window (a cancel that lands before runTurns starts
  ## is legitimately cleared by the turn's own clearInterrupted).
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    if fileExists(path): return true
    sleep 20
  false

proc waitForEnd(rpc: RpcProc; want: string; timeoutMs = 30000): bool =
  ## Poll /events until an `end` row with `want` arrives (or the budget
  ## runs out). The server long-polls, so each call parks until new rows.
  let deadline = epochTime() + timeoutMs / 1000
  var after = 0'i64
  var seen = ""
  while epochTime() < deadline:
    let (code, respBody) = rpc.req("GET", "/events?after=" & $after, "")
    doAssert code == 200, respBody
    seen.add respBody
    for line in respBody.splitLines:
      if line.len == 0: continue
      let cells = line.split('\t')
      if cells.len >= 3:
        after = max(after, parseInt(cells[0]).int64)
        if cells[1] == "end" and cells[2] == want: return true
    sleep 50
  checkpoint("all events seen: [" & seen & "]")
  false

suite "rpc frontend":
  let stub = ensureStubBinary()

  test "failed session switch leaves the server sessionless, not serving a closed session":
    let root = newFixture("rpc_switch")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    # Padding: a pre-fix build would wrongly run turns on the closed
    # object; the stub must not quit(1) on an out-of-range index there.
    writeResponses(root, "rpc.json", %*[
      {"role": "assistant", "content": "pad"}, {"content": "pad"},
      {"content": "pad"}])
    let rpc = spawnRpc(stub, root, root / "proj", root / "run" / "rpc.json")
    defer: discard closeRpc(rpc)

    # A second live instance holds the dir lock on `locked`, so the
    # switch below fails during initialization - after the old session
    # has been torn down.
    createDir(root / "locked")
    writeResponses(root, "holder.json", %*[{"content": "unused"}])
    let holder = spawnRpc(stub, root, root / "locked",
                          root / "run" / "holder.json")

    let cells = rpc.idRow()
    check cells[1] == root / "proj"        # cwd from the startup session
    check cells[5].len > 0                 # sessionid live
    check cells[6].len == 0                # error empty
    let origSid = cells[5]

    let attempted = root / "locked"
    let (code, body) = rpc.req("POST",
      "/session/new?dir=" & encodeUrl(attempted), "")
    check code == 500
    check body.strip.startsWith("error:")

    let after = rpc.idRow()
    check after[1] == attempted            # identity moved to the attempt
    check after[5].len == 0                # sessionless: no session id
    check after[6].len > 0                 # initError surfaced
    check after[5] != origSid

    # No stale scrollback under a dead identity.
    let (scCode, scBody) = rpc.req("GET", "/scrollback", "")
    check scCode == 200
    check scBody.strip.len == 0

    # The closed object must not answer prompts.
    let (pCode, pBody) = rpc.req("POST", "/prompt", "hello")
    check pCode == 500
    check pBody.strip.startsWith("error:")

    # The registry describes the failed state (pid row from /id).
    let regPath = root / "data" / "3code" / "rpc" / after[0]
    check fileExists(regPath)
    let reg = readFile(regPath).strip.split('\t')
    check reg[2] == attempted

    # A later valid open succeeds - including the very directory whose
    # switch failed, proving the failed switch leaked no lock (the holder
    # is gone by then; only the failed switch could still hold it).
    discard closeRpc(holder)
    writeResponses(root, "rpc.json", %*[
      {"content": "pad"}, {"content": "pad"}, {"content": "pad"},
      {"content": "second reply"}])
    let (code2, sid2) = rpc.req("POST",
      "/session/new?dir=" & encodeUrl(root / "proj2"), "")
    check code2 == 200
    check sid2.strip.len > 0

    let (code3, sid3) = rpc.req("POST",
      "/session/new?dir=" & encodeUrl(attempted), "")
    check code3 == 200
    check sid3.strip.len > 0

    # The reopened session is live end to end.
    let (pCode2, pBody2) = rpc.req("POST", "/prompt", "again")
    check pCode2 == 200
    check pBody2.strip == "started"
    check waitForEnd(rpc, "end_turn")

  test "a running turn answers busy and /cancel still ends it":
    let root = newFixture("rpc_busy")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    # Content must be non-empty: an empty model reply triggers the
    # length-retry escalation, not a clean cancellable turn.
    writeResponses(root, "busy.json", %*[
      {"role": "assistant", "content": "slow reply", "preStreamDelayMs": 4000,
       "markerPath": root / "run" / "in_flight"},
      {"role": "assistant", "content": "done after cancel"}])
    let rpc = spawnRpc(stub, root, root / "proj", root / "run" / "busy.json")
    defer: discard closeRpc(rpc)

    let (code, body) = rpc.req("POST", "/prompt", "go")
    check code == 200
    check body.strip == "started"
    check waitMarker(root / "run" / "in_flight")
    # Exactly one admitted turn: everything else answers busy.
    let (code2, body2) = rpc.req("POST", "/prompt", "second")
    check code2 == 409
    check body2.strip == "busy"
    let (code3, _) = rpc.req("POST", "/session/new?dir=x", "")
    check code3 == 409
    let (scCode, _) = rpc.req("GET", "/scrollback", "")
    check scCode == 409
    let cells = rpc.idRow()
    check cells[3] == "1"
    # /cancel interrupts the admitted turn instead of queueing another.
    let (cCode, cBody) = rpc.req("POST", "/cancel", "")
    check cCode == 200
    check cBody.strip == "ok"
    check waitForEnd(rpc, "cancelled")
    # Busy reset survived the exception path: a new turn is admitted.
    let (code4, body4) = rpc.req("POST", "/prompt", "continue")
    check code4 == 200
    check body4.strip == "started"
    check waitForEnd(rpc, "end_turn")

  test "a failed transcript save is reported as an error, never end_turn":
    let root = newFixture("rpc_savefail")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "savefail.json", %*[
      {"role": "assistant", "content": "", "tool_calls": [{
        "id": "call_s1", "type": "function",
        "function": {"name": "bash", "arguments": $(%*{"command":
          "for f in " & (root / "data") & "/3code/sessions/*.3log; do " &
          "rm \"$f\"; mkdir \"$f\"; done"})}}],
       "usage": {"promptTokens": 1, "completionTokens": 1}},
      {"role": "assistant", "content": "after sabotage"},
      {"role": "assistant", "content": "still works"}])
    let rpc = spawnRpc(stub, root, root / "proj",
                       root / "run" / "savefail.json")
    defer: discard closeRpc(rpc)

    # The tool turns the transcript file into a directory mid-turn, so the
    # turn-final save raises SessionSaveError.
    let (code, body) = rpc.req("POST", "/prompt", "sabotage")
    check code == 200
    check body.strip == "started"
    check waitForEnd(rpc, "error")
    # No successful end_turn was emitted for the failing turn.
    let (evCode, evBody) = rpc.req("GET", "/events?after=0", "")
    check evCode == 200
    for line in evBody.splitLines:
      if line.len == 0: continue
      let cells = line.split('\t')
      check not (cells.len >= 3 and cells[1] == "end" and
                 cells[2] == "end_turn")
    # The worker's busy reset is exception-safe: the next prompt admits.
    let (code2, body2) = rpc.req("POST", "/prompt", "again")
    check code2 == 200
    check body2.strip == "started"
    discard waitForEnd(rpc, "error")

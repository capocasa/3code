discard """
  action: run
  disabled: "win"
"""
## `3code --rpc` speaks the plain-text REST surface over loopback. These
## tests drive the real binary end to end against the stub provider (no
## external network): identity, prompt turns, and — the lifecycle
## contract — a failed session replacement that must leave the frontend
## sessionless and truthful, with a subsequent valid open succeeding.
import std/[httpclient, json, os, osproc, streams, strscans, strtabs,
            strutils, unittest]
import stub_helpers
import threecode/session

type
  RpcProc = ref object
    p: Process
    port: int

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

proc spawnRpc(bin, root, workDir: string; responses: string): RpcProc =
  let env = newStringTable()
  env["XDG_DATA_HOME"] = root / "xdg"
  env["XDG_CONFIG_HOME"] = root / "xdg"
  env["XDG_CACHE_HOME"] = root / "xdg" / "cache"
  env["TMPDIR"] = root / "tmp"
  env["HOME"] = root
  env["PATH"] = getEnv("PATH")
  env["THREECODE_STUB_RESPONSES"] = responses
  new(result)
  result.p = startProcess(bin, workingDir = workDir, args = ["--rpc=0"],
                          env = env, options = {})
  # The single stdout line names the bound port.
  let line = result.p.outputStream.readLine()
  if not line.scanf("3code rpc listening on 127.0.0.1:$i", result.port):
    result.port = 0

proc stopRpc(s: RpcProc) =
  s.p.terminate()
  discard s.p.waitForExit(timeout = 10000)
  s.p.close()

proc req(port: int; meth, path: string;
         body = ""): tuple[code: int, body: string] =
  ## One loopback request. The wire is plain text; the status code is
  ## part of the contract (200 ok, 409 busy, 500 sessionless error).
  let client = newHttpClient(timeout = 30000)
  try:
    let r = client.request("http://127.0.0.1:" & $port & path,
                           httpMethod = meth, body = body)
    result.code = r.code.int
    result.body = r.body
  finally:
    client.close()

proc idRow(port: int): seq[string] =
  ## GET /id as TSV cells: pid cwd model busy version sessionid error.
  ## Line-split, not strip: the trailing error cell is often empty and
  ## its tab must survive, or the row loses a field.
  let r = req(port, $HttpGet, "/id")
  check r.code == 200
  result = r.body.splitLines()[0].split('\t')

proc waitEvent(port: int; kind: string;
               timeoutMs = 20000): tuple[seqNum: int64, text: string] =
  ## Poll /events until a row of `kind` arrives (or timeout).
  result = (0, "")
  var after: int64 = 0
  var waited = 0
  while waited < timeoutMs:
    let rows = req(port, $HttpGet, "/events?after=" & $after).body
    for line in rows.strip.splitLines:
      if line.len == 0: continue
      let cells = line.split('\t')
      if cells.len >= 3:
        after = cells[0].parseBiggestInt
        if cells[1] == kind:
          return (after, cells[2].multiReplace(("\\n", "\n"), ("\\t", "\t")))
    sleep 50
    inc waited, 50
  check false  # surfaces the timeout with context in the test output

suite "rpc frontend":
  let stub = ensureStubBinary()

  test "open, prompt, end_turn, identity":
    let root = newFixture("rpc_plain")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let responses = root / "run" / "plain.json"
    writeFile(responses, $(%*[
      {"role": "assistant", "content": "Hello from the stub agent.",
       "contentChunks": ["Hello ", "from the stub agent."],
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}]))
    let s = spawnRpc(stub, root, root / "proj", responses)
    defer: stopRpc(s)
    check s.port > 0

    let row = idRow(s.port)
    check row[3] == "0"          # busy
    check row[5].len > 0         # session id present at startup
    check row[6].len == 0        # no error: the session is live

    let dir = root / "proj"
    let newResp = req(s.port, $HttpPost, "/session/new?dir=" & dir)
    check newResp.code == 200
    let sid = newResp.body.strip
    check sid.len > 0
    check idRow(s.port)[5] == sid

    check req(s.port, $HttpPost, "/prompt", body = "say hello").body.strip ==
      "started"
    check waitEvent(s.port, "user").text == "say hello"
    check waitEvent(s.port, "delta").text.len > 0
    check waitEvent(s.port, "end").text == "end_turn"
    check idRow(s.port)[3] == "0"
    let scroll = req(s.port, $HttpGet, "/scrollback")
    check scroll.code == 200
    check "say hello" in scroll.body

  test "failed replacement leaves a sessionless, truthful frontend":
    let root = newFixture("rpc_switchfail")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let responses = root / "run" / "plain.json"
    writeFile(responses, $(%*[
      {"role": "assistant", "content": "first reply",
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}},
      {"role": "assistant", "content": "second reply",
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}]))
    # The replacement target is locked by THIS test process, so the
    # instance's init there must fail (same TMPDIR as the child).
    putEnv("TMPDIR", root / "tmp")
    let lockedDir = root / "switchfail"
    createDir(lockedDir)
    acquireDirLock(lockedDir)

    let s = spawnRpc(stub, root, root / "proj", responses)
    defer: stopRpc(s)
    check s.port > 0
    let oldSid = idRow(s.port)[5]
    check oldSid.len > 0
    let oldCwd = idRow(s.port)[1]
    check oldCwd == root / "proj"

    let failResp = req(s.port, $HttpPost, "/session/new?dir=" & lockedDir)
    check failResp.code == 500
    check failResp.body.startsWith("error:")

    # Identity is truthful about the failed, sessionless state.
    let row = idRow(s.port)
    check row[5].len == 0                    # no session id
    check row[6].len > 0                     # initError surfaces
    check row[3] == "0"                      # not busy
    check row[1] == lockedDir                # cwd names the attempt

    # The registry row moved with the attempt, not the stale cwd. The
    # fixture's registry dir holds exactly one row: the child's.
    var regRow = ""
    for f in walkFiles(root / "xdg" / "3code" / "rpc" / "*"):
      regRow = readFile(f)
    check regRow.len > 0
    check regRow.split('\t')[2] == lockedDir

    # No usable old session: prompts are refused, scrollback is empty —
    # the transcript must not serve under the failed identity.
    let promptResp = req(s.port, $HttpPost, "/prompt", body = "again")
    check promptResp.code == 500
    check promptResp.body.startsWith("error:")
    let scroll = req(s.port, $HttpGet, "/scrollback")
    check scroll.code == 200
    check scroll.body.strip.len == 0

    # The switch itself released the old session's locks before the
    # failing init: the old directory is free.
    check probeDirLockHeld(oldCwd) == ""

    releaseDirLock(lockedDir)

    # A subsequent valid open succeeds and serves the new session.
    let proj2 = root / "proj2"
    createDir(proj2)
    let ok = req(s.port, $HttpPost, "/session/new?dir=" & proj2)
    check ok.code == 200
    let newSid = ok.body.strip
    check newSid.len > 0 and newSid != oldSid
    check idRow(s.port)[5] == newSid
    check idRow(s.port)[6].len == 0
    check req(s.port, $HttpPost, "/prompt", body = "go").body.strip == "started"
    check waitEvent(s.port, "end").text == "end_turn"
    let scroll2 = req(s.port, $HttpGet, "/scrollback")
    check scroll2.code == 200
    check "go" in scroll2.body

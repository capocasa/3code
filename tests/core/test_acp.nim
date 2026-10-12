discard """
  action: run
  disabled: "win"
"""
## `3code acp` speaks Agent Client Protocol v1 over stdio. These tests
## drive the real binary end to end through pipes against the stub
## provider (no network): initialize negotiation, session lifecycle,
## prompt streaming (message chunks, tool cards, echo suppression),
## cancellation, error shapes, and session/load replay.
import std/[json, locks, os, osproc, streams, strtabs, strutils, unittest]
import stub_helpers

type
  Shared = ref object
    lines: seq[string]
    atEof: bool
    gate: Lock

  ReadJob = tuple[f: Stream, sh: Shared]

  Session = ref object
    p: Process
    sh: Shared
    th: Thread[ReadJob]
    history: seq[JsonNode]
    closed: bool

proc readerProc(job: ReadJob) {.thread.} =
  var line: string
  while job.f.readLine(line):
    withLock job.sh.gate:
      job.sh.lines.add line
  withLock job.sh.gate:
    job.sh.atEof = true

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

proc spawnAcp(bin, root: string; responses: string): Session =
  new(result)
  let env = newStringTable()
  env["XDG_DATA_HOME"] = root / "xdg"
  env["XDG_CONFIG_HOME"] = root / "xdg"
  env["XDG_CACHE_HOME"] = root / "xdg" / "cache"
  env["TMPDIR"] = root / "tmp"
  env["HOME"] = root
  env["TERM"] = "dumb"
  env["PATH"] = getEnv("PATH")
  env["THREECODE_STUB_RESPONSES"] = responses
  result.p = startProcess(bin, args = ["acp"], env = env, options = {})
  result.sh = Shared()
  initLock(result.sh.gate)
  let job: ReadJob = (f: result.p.outputStream, sh: result.sh)
  createThread(result.th, readerProc, job)

proc send(s: Session; node: JsonNode) =
  s.p.inputStream.writeLine $node
  s.p.inputStream.flush()

proc frame(id: int; meth: string; params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params}

proc pump(s: Session) =
  ## Move arrived lines from the reader thread into `history`.
  var got: seq[string]
  withLock s.sh.gate:
    got = s.sh.lines
    s.sh.lines = @[]
  for line in got:
    s.history.add parseJson(line)

proc waitFor(s: Session; wantId: int; timeoutMs = 20000): JsonNode =
  ## First response with the given request id; notifications collected
  ## along the way stay inspectable via `updatesOf`.
  var waited = 0
  while waited < timeoutMs:
    s.pump()
    for m in s.history:
      let idNode = m{"id"}
      if m.kind == JObject and idNode != nil and idNode.kind == JInt and
          idNode.getBiggestInt == wantId:
        return m
    sleep 25
    waited += 25
  result = %*{"error": "timeout waiting for id " & $wantId}

proc seenUpdates(s: Session): seq[JsonNode] =
  s.pump()
  for m in s.history:
    let meth = m{"method"}
    if m.kind == JObject and meth != nil and
        meth.getStr == "session/update":
      result.add m{"params"}{"update"}

proc updatesOf(s: Session; kind: string): seq[JsonNode] =
  for u in s.seenUpdates():
    if u{"sessionUpdate"}.getStr == kind: result.add u

proc closeAcp(s: Session): int =
  if s.closed: return 0
  s.closed = true
  s.p.inputStream.close()
  result = s.p.waitForExit(timeout = 15000)
  s.p.close()
  joinThread(s.th)

suite "acp frontend":
  let stub = ensureStubBinary()

  test "initialize, session/new, plain prompt, end_turn":
    let root = newFixture("acp_plain")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "plain.json", %*[
      {"role": "assistant", "content": "Hello from the stub agent.",
       "contentChunks": ["Hello ", "from the stub agent."],
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}])
    let s = spawnAcp(stub, root, root / "run" / "plain.json")
    defer: discard closeAcp(s)

    s.send(frame(1, "initialize", %*{
      "protocolVersion": 1, "clientCapabilities": {},
      "clientInfo": {"name": "test", "version": "0"}}))
    let init = s.waitFor(1)
    check init{"result"}{"protocolVersion"}.getBiggestInt == 1
    check init{"result"}{"agentCapabilities"}{"loadSession"}.getBool
    check init{"result"}{"agentInfo"}{"name"}.getStr == "3code"

    s.send(frame(2, "session/new",
      %*{"cwd": root / "proj", "mcpServers": []}))
    let newResp = s.waitFor(2)
    let sid = newResp{"result"}{"sessionId"}.getStr
    check sid.len > 0

    s.send(frame(3, "session/prompt", %*{
      "sessionId": sid, "prompt": [{"type": "text", "text": "say hello"}]}))
    let done = s.waitFor(3)
    check done{"result"}{"stopReason"}.getStr == "end_turn"
    let chunks = s.updatesOf("agent_message_chunk")
    check chunks.len >= 2
    var text = ""
    for c in chunks: text.add c{"content"}{"text"}.getStr
    check text == "Hello from the stub agent."
    # The committed assistant echo and the user echo are transcript items
    # too; they must not surface as tool cards.
    check s.updatesOf("tool_call").len == 0

  test "tool turn emits a completed tool card before the closing message":
    let root = newFixture("acp_tool")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "tool.json", %*[
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_1", "function": {
         "name": "bash",
         "arguments": "{\"command\": \"echo acp-tool-ran\"}"}}],
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}},
      {"role": "assistant", "content": "The command ran.",
       "usage": {"promptTokens": 20, "completionTokens": 4,
                 "totalTokens": 24, "cachedTokens": 0}}])
    let s = spawnAcp(stub, root, root / "run" / "tool.json")
    defer: discard closeAcp(s)
    s.send(frame(1, "initialize", %*{"protocolVersion": 1}))
    discard s.waitFor(1)
    s.send(frame(2, "session/new", %*{"cwd": root / "proj"}))
    let sid = s.waitFor(2){"result"}{"sessionId"}.getStr
    s.send(frame(3, "session/prompt", %*{
      "sessionId": sid, "prompt": [{"type": "text", "text": "run it"}]}))
    check s.waitFor(3){"result"}{"stopReason"}.getStr == "end_turn"
    let cards = s.updatesOf("tool_call")
    check cards.len == 1
    check "acp-tool-ran" in cards[0]{"title"}.getStr
    check cards[0]{"status"}.getStr == "completed"

  test "session/cancel answers the prompt with cancelled":
    let root = newFixture("acp_cancel")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "slow.json", %*[
      {"role": "assistant", "preStreamDelayMs": 30000, "content": "late",
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}])
    let s = spawnAcp(stub, root, root / "run" / "slow.json")
    defer: discard closeAcp(s)
    s.send(frame(1, "initialize", %*{"protocolVersion": 1}))
    discard s.waitFor(1)
    s.send(frame(2, "session/new", %*{"cwd": root / "proj"}))
    let sid = s.waitFor(2){"result"}{"sessionId"}.getStr
    s.send(frame(3, "session/prompt", %*{
      "sessionId": sid, "prompt": [{"type": "text", "text": "stall"}]}))
    sleep 500
    s.send(%*{"jsonrpc": "2.0", "method": "session/cancel",
              "params": {"sessionId": sid}})
    check s.waitFor(3){"result"}{"stopReason"}.getStr == "cancelled"
    check closeAcp(s) == 0

  test "unknown method and unknown session are JSON-RPC errors":
    let root = newFixture("acp_errors")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "none.json", %*[
      {"role": "assistant", "content": "x",
       "usage": {"promptTokens": 1, "completionTokens": 1,
                 "totalTokens": 2, "cachedTokens": 0}}])
    let s = spawnAcp(stub, root, root / "run" / "none.json")
    defer: discard closeAcp(s)
    # before initialize: refused
    s.send(frame(9, "session/new", %*{"cwd": root / "proj"}))
    let pre = s.waitFor(9)
    check pre{"error"}{"code"}.getInt == -32000
    s.send(frame(1, "initialize", %*{"protocolVersion": 1}))
    discard s.waitFor(1)
    s.send(frame(2, "session/set_mode", %*{"sessionId": "x", "modeId": "y"}))
    check s.waitFor(2){"error"}{"code"}.getInt == -32601
    s.send(frame(3, "session/new", %*{"cwd": root / "proj"}))
    let sid = s.waitFor(3){"result"}{"sessionId"}.getStr
    check sid.len > 0
    s.send(frame(4, "session/prompt", %*{
      "sessionId": "nope", "prompt": [{"type": "text", "text": "x"}]}))
    let unk = s.waitFor(4)
    check unk{"error"}{"code"}.getInt == -32000
    check "unknown session" in unk{"error"}{"message"}.getStr

  test "session/load replays the stored conversation without harness scaffolding":
    let root = newFixture("acp_load")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeResponses(root, "plain.json", %*[
      {"role": "assistant", "content": "Hello from the stub agent.",
       "contentChunks": ["Hello from the stub agent."],
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}])
    block: # process 1: create the session and one turn
      let s = spawnAcp(stub, root, root / "run" / "plain.json")
      s.send(frame(1, "initialize", %*{"protocolVersion": 1}))
      discard s.waitFor(1)
      s.send(frame(2, "session/new", %*{"cwd": root / "proj"}))
      let sid = s.waitFor(2){"result"}{"sessionId"}.getStr
      s.send(frame(3, "session/prompt", %*{
        "sessionId": sid,
        "prompt": [{"type": "text", "text": "say hello"}]}))
      discard s.waitFor(3)
      writeFile(root / "run" / "sid.txt", sid)
      check closeAcp(s) == 0
    block: # process 2: load it and replay
      let sid = readFile(root / "run" / "sid.txt")
      let s = spawnAcp(stub, root, root / "run" / "plain.json")
      defer: discard closeAcp(s)
      s.send(frame(1, "initialize", %*{"protocolVersion": 1}))
      discard s.waitFor(1)
      s.send(frame(2, "session/load",
        %*{"sessionId": sid, "cwd": root / "proj", "mcpServers": []}))
      check s.waitFor(2){"result"}.kind == JObject
      var userText = ""
      var agentText = ""
      for u in s.seenUpdates():
        case u{"sessionUpdate"}.getStr
        of "user_message_chunk":
          userText.add u{"content"}{"text"}.getStr
        of "agent_message_chunk":
          agentText.add u{"content"}{"text"}.getStr
        else: discard
      check userText == "say hello"
      check agentText == "Hello from the stub agent."

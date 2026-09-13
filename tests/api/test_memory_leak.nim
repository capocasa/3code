discard """
  targets: "c"
"""
## Regression test for issue #35 (RSS grows forever on long sessions).
##
## Drives a headless AgentSession through ~120 REAL threaded-transport turns
## against a local HTTP server whose usage numbers trip the compaction
## threshold every ~10 turns, then asserts the RSS slope between turn 30
## (warmed up) and the end is flat.
##
## This catches three leak classes at once:
##   - the per-summarizer `newContext` SSL_CTX leak (~0.8 MB per
##     compaction: `SslContext` has no `=destroy`, so each uncached
##     context strands its parsed CA trust store in the C heap);
##   - worker-thread ORC leaks (cross-thread string ownership, and
##     cycle-registered refs of a thread that exits uncollected strand
##     their entries in the global cycle table);
##   - anything else that quietly accumulates per turn.
##
## Must run the real transport: the stub provider bypasses the network
## worker entirely, so it can never reproduce these. posix-only (reads
## /proc/self/status); skipped elsewhere.

import std/[json, net, os, strutils, unittest]
import threecode/[library, types]

when not defined(windows):
  import std/posix

const
  Turns = 120
  WarmupTurn = 30
  RssSlopeCeilingKb = 5_000

when not defined(windows):
  proc rssKb(): int =
    ## VmRSS in kB; 0 when unavailable (test skips when 0 at first probe).
    try:
      for line in readFile("/proc/self/status").splitLines():
        if line.startsWith("VmRSS:"):
          return line.splitWhitespace()[1].parseInt
    except CatchableError:
      discard
    0

when not defined(windows):
  # -------------------------------------------------------------------------
  # Local provider: plain HTTP, SSE streams for chat, plain JSON for the
  # summarizer (stream:false) and any non-stream request. usage.prompt_tokens
  # grows with the message count so decideContextAction crosses its 0.8
  # threshold of stub-model's 12000-token window every ~10 turns.
  # -------------------------------------------------------------------------

  type LeakServer = ref object
    sock: Socket
    port: Port
    running: bool

  proc setSockTimeoutMs(sock: Socket; ms: int) =
    var tv: Timeval
    tv.tv_sec = Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                       addr tv, sizeof(tv).SockLen)

  proc readHead(client: Socket): int =
    ## Request head up to the blank line; returns Content-Length.
    while true:
      let line = client.recvLine(timeout = 10_000)
      if line.len == 0: return result
      let s = line.strip()
      if s.len == 0: return result
      if s.toLowerAscii.startsWith("content-length:"):
        result = try: parseInt(s.split(":")[1].strip) except ValueError: 0

  proc readBody(client: Socket; n: int): string =
    if n <= 0: return ""
    result = newString(n)
    var got = 0
    while got < n:
      let r = client.recv(result, n - got, timeout = 10_000)
      if r == 0: break
      got += r
    result.setLen(got)

  proc jsonReply(client: Socket; body: string) =
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
      "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n"
    client.send(head & body)

  proc sseReply(client: Socket; body: string) =
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
      "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n"
    client.send(head & body)

  proc handleRequest(server: LeakServer; client: Socket) =
    let bodyLen = client.readHead()
    let body = client.readBody(bodyLen)
    var nMsgs = 0
    var isSummarizer = false
    var wantsStream = true
    try:
      let j = parseJson(body)
      if j.kind == JObject:
        if j{"messages"}.kind == JArray: nMsgs = j{"messages"}.len
        if j{"messages"}.len > 0 and
            j{"messages"}[0]{"content"}.getStr.find("You are summarizing") >= 0:
          isSummarizer = true
        if j{"stream"}.kind == JBool: wantsStream = j{"stream"}.getBool
    except CatchableError:
      discard
    if isSummarizer or not wantsStream:
      client.jsonReply($ (%*{"choices": [{"index": 0,
        "finish_reason": "stop",
        "message": {"role": "assistant",
                    "content": "recap: files touched, tests green"}}],
        "usage": {"prompt_tokens": 100, "completion_tokens": 10,
                  "total_tokens": 110}}))
      return
    var sse = ""
    for i in 1 .. 400:
      sse.add "data: " & $(%*{"choices":[{"index":0,
        "delta":{"reasoning_content": "word" & $i & " "}}],"id":"t"}) & "\n\n"
    for i in 1 .. 200:
      sse.add "data: " & $(%*{"choices":[{"index":0,
        "delta":{"content": "content-" & $i & " "}}],"id":"t"}) & "\n\n"
    sse.add "data: " & $(%*{"choices":[{"index":0,"delta":{},
      "finish_reason":"stop"}],"id":"t",
      "usage":{"prompt_tokens": 100 + nMsgs * 400,
               "completion_tokens": 100,
               "total_tokens": 200 + nMsgs * 400}}) & "\n\n"
    sse.add "data: [DONE]\n\n"
    client.sseReply(sse)

  proc serveLoop(server: LeakServer) {.thread.} =
    var served = 0
    while server.running:
      served += 1
      if served mod 20 == 0: GC_fullCollect()  # keep this thread's heap flat

      var client: Socket
      try:
        server.sock.accept(client)
      except OSError:
        continue  # accept timeout wake: re-check running
      if client == nil: continue
      try:
        server.handleRequest(client)
      except CatchableError:
        discard
      try:
        client.close()
      except CatchableError:
        discard

  proc newLeakServer(): LeakServer =
    result = LeakServer(sock: newSocket(), running: true)
    result.sock.setSockOpt(OptReuseAddr, true)
    result.sock.bindAddr(Port(0))
    result.sock.listen()
    result.sock.setSockTimeoutMs(200)
    let (_, p) = result.sock.getLocalAddr()
    result.port = p

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_leaktest_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")
  createDir(result / "tmp")

when not defined(windows):
  suite "memory: long-session RSS slope":
    test "threaded turns + compaction stay flat (issue #35)":
      when not fileExists("/proc/self/status"):
        skip()
      else:
        let root = newFixture("loop")
        putEnv("XDG_CONFIG_HOME", root / "xdg")
        putEnv("XDG_DATA_HOME", root / "data")
        putEnv("TMPDIR", root / "tmp")
        let server = newLeakServer()
        var serveThread: Thread[LeakServer]
        createThread(serveThread, serveLoop, server)
        writeFile(root / "xdg" / "3code" / "config",
          "[settings]\ncurrent = \"stub.stub-model\"\nsandbox = off\n\n" &
          "[provider]\nname = \"stub\"\n" &
          "url = \"http://127.0.0.1:" & $server.port.uint16 & "\"\n" &
          "key = \"stub\"\nfamily = \"glm\"\nmodels = \"stub-model\"\n")
        let big = "0123456789".repeat(100)
        let s = initAgentSession(AgentOptions(cwd: root / "run",
                                              experimental: true))
        var rssWarmup = -1
        var maxMsgs = 0
        var compacted = false
        var prevMsgs = 0
        for i in 1 .. Turns:
          discard s.prompt("turn " & $i & " " & big)
          let n = s.messages.len
          if prevMsgs > n + 4: compacted = true  # history dropped: summarize fired
          prevMsgs = n
          maxMsgs = max(maxMsgs, n)
          if i == WarmupTurn:
            GC_fullCollect()
            rssWarmup = rssKb()
        s.close()
        GC_fullCollect()
        let rssEnd = rssKb()
        server.running = false
        server.sock.close()
        joinThread(serveThread)
        check compacted  # the compaction path (per-summarizer SSL ctx) ran
        check maxMsgs <= 40  # history stayed bounded
        let slope = rssEnd - rssWarmup
        checkpoint "rss warmup " & $rssWarmup & "kB end " & $rssEnd &
                   "kB slope " & $slope & "kB over " & $(Turns - WarmupTurn) & " turns"
        check slope < RssSlopeCeilingKb
        if rssWarmup <= 0:
          skip()  # /proc unreadable: surface the checkpoints but don't gate

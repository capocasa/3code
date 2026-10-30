## `:btw` asks the model a side question about the conversation: one
## meta-call over the live history, the answer displayed to the user only.
## Neither the question nor the answer may enter `messages` — that is the
## whole feature — so these tests pin the payload shape, the untouched
## history, and the command wiring against a local HTTP server.
import std/[json, strutils, unittest]
import std/net except send
import threecode/[compact, minline, types, ui]

when defined(posix):
  import std/posix except SocketHandle

type
  BtwSrv = ref object
    listener: Socket
    stop: bool
    payloads: seq[string]  # request bodies, in arrival order
    thread: Thread[BtwSrv]  # inside the ref: the OS trampoline keeps a
                           # pointer to this object, so it must not move

proc send(client: Socket; data: string) =
  # flags = {}: raise on a client that already hung up instead of std/net's
  # EPIPE retry spin (nim-lang/Nim#23455).
  net.send(client, data, flags = {})

proc setListenerTimeoutMs(sock: Socket; ms: int) =
  # SO_RCVTIMEO wakes the blocking accept so the serve loop can re-check
  # `stop` (the same trick tests/mock_server.nim uses).
  when defined(posix):
    var tv: Timeval
    tv.tv_sec = Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                       addr tv, sizeof(tv).SockLen)

proc serve(s: BtwSrv) {.thread.} =
  {.cast(gcsafe).}:
    s.listener.setListenerTimeoutMs(300)
    while not s.stop:
      var client: Socket
      try:
        s.listener.accept(client)
      except CatchableError:
        continue
      try:
        var contentLength = 0
        while true:
          let line = client.recvLine(5000)
          if line.len == 0 or line.strip.len == 0: break
          if line.toLowerAscii.startsWith("content-length:"):
            contentLength = parseInt(line.split(":")[1].strip)
        var body = ""
        while body.len < contentLength:
          let chunk = client.recv(min(4096, contentLength - body.len))
          if chunk.len == 0: break
          body.add chunk
        if body.len == 0: continue
        s.payloads.add body
        let reply = """{"choices":[{"message":{"role":"assistant","content":"SIDE ANSWER"}}]}"""
        send(client, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
          "Content-Length: " & $reply.len & "\r\nConnection: close\r\n\r\n" &
          reply)
      except CatchableError:
        discard
      finally:
        try: client.close() except OSError: discard

type BtwHarness = tuple[srv: BtwSrv, prof: Profile]

proc startBtwSrv(): BtwHarness =
  let s = BtwSrv(listener: newSocket())
  s.listener.setSockOpt(OptReuseAddr, true)
  s.listener.bindAddr(Port(0), "127.0.0.1")
  s.listener.listen()
  let (_, port) = s.listener.getLocalAddr()
  createThread(s.thread, serve, s)
  # Provider name with a dot but not openai/chatgpt, so the meta-call takes
  # the /chat/completions branch the canned reply above speaks.
  result = (s, Profile(name: "test.provider", url: "http://127.0.0.1:" &
    $port.uint16, key: "k", model: "stub-chat"))

proc stopBtwSrv(h: BtwHarness) =
  h.srv.stop = true
  joinThread(h.srv.thread)
  try: h.srv.listener.close() except OSError: discard

proc history(): JsonNode =
  result = %* [
    {"role": "system", "content": "sysprompt"},
    {"role": "user", "content": "read foo.nim"},
    {"role": "assistant", "content": "foo.nim has 3 procs"},
  ]

suite ":btw side questions":
  test "classification and prefix resolution":
    check canonicalCommandName(":btw") == (":btw", "")
    check canonicalCommandName(":b") == (":btw", "")
    check classifyCommand(":btw") == ckSafeImmediate
    check classifyCommand(":btw why?") == ckMutating
    check classifyCommand(":b why?") == ckMutating

  test "bare :btw is a usage hint":
    var messages = history()
    var session = Session()
    var prof = Profile()
    var editor: LineEditor
    let r = handleCommandResult(":btw", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "usage: :btw" in r.body
    check messages.len == 3

  test ":btw without a provider fails like :summarize":
    var messages = history()
    var session = Session()
    var prof = Profile()
    var editor: LineEditor
    let r = handleCommandResult(":btw why?", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "no provider configured" in r.body

  test "askBtw payload: aside prompt, live history, trailing question":
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    var messages = history()
    let before = $messages
    let answer = askBtw("what did foo.nim have?", messages, h.prof)
    check answer == "SIDE ANSWER"
    # The live conversation is the caller's, byte for byte.
    check $messages == before
    check h.srv.payloads.len == 1
    let sent = parseJson(h.srv.payloads[0])
    let msgs = sent["messages"]
    check msgs.len == 4
    check msgs[0]{"role"}.getStr == "system"
    check msgs[0]{"content"}.getStr == BtwSystemPrompt
    check msgs[1]{"content"}.getStr == "read foo.nim"
    check msgs[2]{"content"}.getStr == "foo.nim has 3 procs"
    check msgs[3]{"role"}.getStr == "user"
    check msgs[3]{"content"}.getStr == "what did foo.nim have?"
    check sent["model"].getStr == h.prof.model
    check sent["max_tokens"].getInt == BtwMaxTokens

  test "command path answers without touching messages":
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    var messages = history()
    var session = Session()
    var prof = h.prof
    var editor: LineEditor
    let r = handleCommandResult(":btw what did foo.nim have?", messages,
                                session, prof, editor)
    check r.recognized and r.ok
    check r.name == "btw"
    check "SIDE ANSWER" in r.body
    # The contract: no question, no answer, nothing new in the context.
    check messages.len == 3
    check messages[0]{"content"}.getStr == "sysprompt"
    check messages[^1]{"content"}.getStr == "foo.nim has 3 procs"
    # ...and the request carried the question as a trailing user message,
    # not as an edit of the shared history.
    let sent = parseJson(h.srv.payloads[0])
    check sent["messages"].len == 4
    check sent["messages"][^1]{"content"}.getStr == "what did foo.nim have?"

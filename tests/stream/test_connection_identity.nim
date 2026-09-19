## Exercise the real connection cache against a loopback listener. A scheme
## switch must open a new socket and attempt TLS, never return the plain one.
include threecode/api
import std/[net, unittest]

proc rejectTls(listener: Socket) {.thread.} =
  var plain, tls: Socket
  listener.accept(plain)
  listener.accept(tls)
  # A TLS handshake begins with a handshake record, not an HTTP request.
  let record = tls.recv(1)
  doAssert record.len == 1 and record[0] == '\x16'
  tls.close()
  plain.close()
  listener.close()

suite "transport connection identity":
  test "same mode reuses socket; switching to TLS reconnects":
    let listener = newSocket()
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1]
    var server: Thread[Socket]
    createThread(server, rejectTls, listener)
    let plain = acquireStreamConn("127.0.0.1", port, true)
    check acquireStreamConn("127.0.0.1", port, true) == plain
    var rejected = false
    try:
      discard acquireStreamConn("127.0.0.1", port, false)
    except CatchableError:
      rejected = true
    check rejected
    check cachedStreamConn == nil
    # Also wake the listener on a regressed cache hit so failure cannot hang.
    if not rejected:
      let wake = newSocket()
      wake.connect("127.0.0.1", port)
      try: net.send(wake, "\x16", flags = {})
      except CatchableError: discard
      wake.close()
    closeCachedStreamConn()
    joinThread(server)

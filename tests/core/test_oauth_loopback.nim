## Blocking OAuth loopback: one-shot TCP callback without async.
##
## Spins awaitLoopbackCode on a worker thread, hits it with a synthetic
## browser redirect, checks the code comes back and a 200 is returned.

import std/[atomics, locks, net, os, strutils, times, unittest, uri]
import threecode/oauth

type
  Shared = ref object
    port: int
    expectState: string
    timeoutSec: int
    got, err: string
    lock: Lock
    listening: Atomic[bool]
    cancel: Atomic[bool]

proc worker(s: Shared) {.thread.} =
  try:
    let code = awaitLoopbackCode(s.port, s.expectState, s.timeoutSec,
      cancelFlag = addr s.cancel,
      onListening = proc() {.gcsafe.} =
        s.listening.store(true, moRelease))
    withLock s.lock:
      s.got = code
  except CatchableError as e:
    withLock s.lock:
      s.err = e.msg

proc waitListening(s: Shared; ms = 2000) =
  let deadline = epochTime() + ms.float / 1000
  while not s.listening.load(moAcquire):
    if epochTime() >= deadline:
      raise newException(IOError, "listener never became ready")
    sleep(10)

proc fetchCallback(port: int, path: string): string =
  let s = newSocket()
  defer: s.close()
  s.connect("127.0.0.1", Port(port))
  s.send("GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
  result = ""
  while true:
    let chunk = s.recv(4096)
    if chunk.len == 0: break
    result.add chunk

proc freePort(): int =
  let probe = newSocket()
  defer: probe.close()
  probe.bindAddr(Port(0), "127.0.0.1")
  probe.getLocalAddr()[1].int

suite "oauth loopback":
  test "awaitLoopbackCode returns code and replies 200":
    let port = freePort()
    let s = Shared(port: port, expectState: "test-state-xyz", timeoutSec: 5)
    initLock(s.lock)
    var t: Thread[Shared]
    createThread(t, worker, s)
    waitListening(s)
    let path = "/callback?code=" & encodeUrl("auth-code-abc") &
               "&state=" & encodeUrl("test-state-xyz")
    let resp = fetchCallback(port, path)
    joinThread(t)
    check resp.startsWith("HTTP/1.1 200")
    check "Authorization received" in resp
    withLock s.lock:
      check s.err == ""
      check s.got == "auth-code-abc"

  test "awaitLoopbackCode rejects state mismatch":
    let port = freePort()
    let s = Shared(port: port, expectState: "good-state", timeoutSec: 5)
    initLock(s.lock)
    var t: Thread[Shared]
    createThread(t, worker, s)
    waitListening(s)
    discard fetchCallback(port, "/callback?code=c&state=bad-state")
    joinThread(t)
    withLock s.lock:
      check s.got == ""
      check "state mismatch" in s.err

  test "awaitLoopbackCode times out":
    let port = freePort()
    expect OAuthError:
      discard awaitLoopbackCode(port, "s", timeoutSec = 1)

  test "awaitLoopbackCode cancels via flag":
    let port = freePort()
    let s = Shared(port: port, expectState: "s", timeoutSec: 30)
    initLock(s.lock)
    var t: Thread[Shared]
    createThread(t, worker, s)
    waitListening(s)
    s.cancel.store(true, moRelease)
    joinThread(t)
    withLock s.lock:
      check s.got == ""
      check "cancelled" in s.err

  test "awaitLoopbackCode cancels after hung browser connect":
    ## Browser opens TCP (local-network permission / stalled tab) but never
    ## sends the request line. Cancel must still unwind promptly; a long
    ## post-accept recvLine would pin the worker until timeout.
    let port = freePort()
    let s = Shared(port: port, expectState: "s", timeoutSec: 30)
    initLock(s.lock)
    var t: Thread[Shared]
    createThread(t, worker, s)
    waitListening(s)
    let hung = newSocket()
    hung.connect("127.0.0.1", Port(port))
    # Give accept a moment to complete so the worker is inside request read.
    sleep(100)
    let t0 = epochTime()
    s.cancel.store(true, moRelease)
    joinThread(t)
    hung.close()
    check epochTime() - t0 < 2.0
    withLock s.lock:
      check s.got == ""
      check "cancelled" in s.err

  test "onListening fires before accept":
    let port = freePort()
    var heard: Atomic[bool]
    # Hit the listener from another thread after onListening runs.
    type Hit = ref object
      port: int
      lock: Lock
      resp, err: string
    let h = Hit(port: port)
    initLock(h.lock)
    proc hitter(hh: Hit) {.thread.} =
      try:
        let r = fetchCallback(hh.port,
          "/callback?code=c&state=st")
        withLock hh.lock: hh.resp = r
      except CatchableError as e:
        withLock hh.lock: hh.err = e.msg
    var ht: Thread[Hit]
    # Capture by pointer so the gcsafe callback does not close over a ref.
    let hPtr = cast[pointer](h)
    let htPtr = addr ht
    let code = awaitLoopbackCode(port, "st", timeoutSec = 5,
      onListening = proc() {.gcsafe.} =
        heard.store(true, moRelease)
        createThread(htPtr[], hitter, cast[Hit](hPtr)))
    joinThread(ht)
    check heard.load(moAcquire)
    check code == "c"
    withLock h.lock:
      check h.err == ""
      check h.resp.startsWith("HTTP/1.1 200")

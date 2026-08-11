## Blocking OAuth loopback: one-shot TCP callback without async.
##
## Spins awaitLoopbackCode on a worker thread, hits it with a synthetic
## browser redirect, checks the code comes back and a 200 is returned.

import std/[locks, net, os, strutils, unittest, uri]
import threecode/oauth

type
  Shared = ref object
    port: int
    expectState: string
    timeoutSec: int
    got, err: string
    lock: Lock

proc worker(s: Shared) {.thread.} =
  try:
    let code = awaitLoopbackCode(s.port, s.expectState, s.timeoutSec)
    withLock s.lock:
      s.got = code
  except CatchableError as e:
    withLock s.lock:
      s.err = e.msg

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
    sleep(100)
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
    sleep(100)
    discard fetchCallback(port, "/callback?code=c&state=bad-state")
    joinThread(t)
    withLock s.lock:
      check s.got == ""
      check "state mismatch" in s.err

  test "awaitLoopbackCode times out":
    let port = freePort()
    expect OAuthError:
      discard awaitLoopbackCode(port, "s", timeoutSec = 1)

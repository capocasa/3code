discard """
  # The tty_expect harness uses openpty/fork/execv (POSIX only).
  disabled: "win"
"""
## Regression: Ctrl-C / ESC during the network connect or streaming-body
## phase must return to the prompt promptly, not wait for the network call
## to finish.
##
## The stub provider short-circuits the network entirely, so it cannot
## exercise the blocking connect/recv phases where this bug lived. This test
## builds a non-stub 3code binary and points it at a local mock HTTP server
## (`tests/mock_server.nim`) that simulates a black-holed edge (accept TCP,
## never reply) and a mid-body stall.
##
## Before the fix, `cachedStreamFd` was only set after a successful connect,
## so `shutdownCachedStreamFd()` was a no-op during connect/handshake and a
## slow network pinned the caller for the full connect budget. With the
## `onConnectingFd` hook the fd is published before the blocking connect, so a
## Ctrl-C shutdown wakes it within milliseconds.
import std/[json, os, strutils, times, unittest]
import tty_expect, stub_helpers, mock_server

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeProviderConfig(root, url: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "mock.glm"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "mock"
url = "$#"
key = "mock"
family = "glm"
models = "glm"
""" % url)

proc env(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

proc ensureRealBinary(): string =
  ## Non-stub 3code binary with plain-HTTP transport enabled so it can talk to
  ## the local mock server over `http://127.0.0.1`.
  const defines = "-d:ssl -d:testPlainHttp --threads:on"
  buildBinary(defines, "3code_real")

let realBin = ensureRealBinary()

suite "interrupt during real network connect/stream":
  test "Ctrl-C during connect (silent server) returns to prompt":
    let root = newFixture("interrupt_connect_ctrlc")
    let srv = startMockServer(msSilentAfterAccept)
    defer: stopMockServer(srv)
    writeProviderConfig(root, srv.url)
    let tty = newTtySession(realBin,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = env(root))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # Connect is now in flight against a silent server; no bytes will ever
    # arrive. Wait for the request to reach the server, then interrupt.
    tty.drain(500)
    let t0 = epochTime()
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    let elapsed = epochTime() - t0
    # The connect budget is 30s; before the fix this took the full budget
    # (or hung). With the hook, shutdown wakes the connect in milliseconds.
    doAssert elapsed < 5.0,
      "Ctrl-C during connect took " & formatFloat(elapsed, ffDecimal, 1) &
      "s; expected < 5s (connect was not interruptible)"
    tty.expectAlive()
    tty.drain(300)
    let f = tty.frames[^1]
    check f.rows[f.cursorRow].contains("\u276f")
    echo "  PASS: Ctrl-C during connect returned in ",
      formatFloat(elapsed, ffDecimal, 2), "s"

  test "Ctrl-C during streaming body (slow server) returns to prompt":
    let root = newFixture("interrupt_stream_ctrlc")
    let srv = startMockServer(msSlowStream)
    defer: stopMockServer(srv)
    writeProviderConfig(root, srv.url)
    let tty = newTtySession(realBin,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = env(root))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # The server sends the head + first chunk, then stalls mid-body.
    tty.drain(800)
    let t0 = epochTime()
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    let elapsed = epochTime() - t0
    doAssert elapsed < 5.0,
      "Ctrl-C during stream took " & formatFloat(elapsed, ffDecimal, 1) &
      "s; expected < 5s"
    tty.expectAlive()
    tty.drain(300)
    let f = tty.frames[^1]
    check f.rows[f.cursorRow].contains("\u276f")
    echo "  PASS: Ctrl-C during stream returned in ",
      formatFloat(elapsed, ffDecimal, 2), "s"

  test "follow-up turn after interrupt works (happy path server)":
    let root = newFixture("interrupt_followup_ok")
    let srv = startMockServer(msOk)
    defer: stopMockServer(srv)
    writeProviderConfig(root, srv.url)
    let tty = newTtySession(realBin,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = env(root))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "hi"
    tty.expect "hi"
    tty.send "\n"
    # Happy path: the server replies with a complete SSE response.
    tty.expectInHistory "hi"
    tty.expectAlive()
    echo "  PASS: happy-path response rendered after prior interrupt state"

  test "Ctrl-C after full response tears down promptly (black-holed teardown)":
    # The response lands completely, but the link then dies (the mock holds
    # the socket open without sending anything). The client's stream loop
    # returns cleanly, then `closeCachedStreamConn` tears the connection
    # down. Against a black-holed peer a graceful TLS `close_notify` would
    # hang forever - the teardown deadlock threecode hit on flaky links,
    # where the network worker leaked a thread stuck in close()/sigwait and
    # Ctrl-C/ESC could not cancel it. This test asserts the turn still comes
    # back to the prompt (the worker's teardown close is now abrupt and
    # bounded), not that the user interrupt cancels an in-flight recv.
    let root = newFixture("interrupt_teardown")
    let srv = startMockServer(msStallAfterDone)
    defer: stopMockServer(srv)
    writeProviderConfig(root, srv.url)
    let tty = newTtySession(realBin,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = env(root))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # The full response should render (the mock sends a complete SSE body).
    tty.expectInHistory "hi"
    # The turn should return to the prompt without hanging in teardown
    # close(). The connect budget is 30s; before the fix the worker leaked
    # a thread stuck in close()/sigwait for the life of the process.
    let t0 = epochTime()
    tty.expectIdleCaret(5000)
    let elapsed = epochTime() - t0
    doAssert elapsed < 6.0,
      "turn did not return after full response: " &
      formatFloat(elapsed, ffDecimal, 1) &
      "s; teardown close() hung on black-holed peer"
    let f = tty.frames[^1]
    check f.rows[f.cursorRow].contains("\u276f")
    echo "  PASS: teardown after full response returned in ",
      formatFloat(elapsed, ffDecimal, 2), "s"

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

proc ensureQuietBinary(): string =
  ## As `ensureRealBinary` but with a shrunk `QuietTooLongMs` so a black-holed
  ## link surfaces the network-quiet timeout in ~3s instead of the production
  ## 45s. The production value is an intdefine for exactly this.
  const defines = "-d:ssl -d:testPlainHttp --threads:on -d:QuietTooLongMs=3000"
  buildBinary(defines, "3code_quiet")

let realBin = ensureRealBinary()
let quietBin = ensureQuietBinary()

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

  test "Ctrl-C during content stream (no usage) emits no `· Xs` line":
    # Regression: providers send usage as a separate end-of-stream SSE event.
    # Interrupting mid-stream after content arrived but before usage left
    # `callModel` with `usage.totalTokens == 0`, so it fell through to
    # `hookNoUsage` and printed a spurious `· Xs` timing line above the
    # magenta `interrupted by user` message. The fix makes callModel skip
    # the usage/elapsed emission entirely when interrupted. This test sends
    # a content delta with no usage object, then stalls — the exact shape —
    # and asserts the timing line never appears in the rendered transcript.
    let root = newFixture("interrupt_no_usage_line")
    let srv = startMockServer(msSlowStreamNoUsage)
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
    # Content arrives ("fi"), then the server stalls mid-body. The usage
    # event never comes, so an interrupt here hits the no-usage path.
    tty.drain(800)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    # The spurious line looks like `· 3s` — a middle dot, a space, then a
    # number and `s`. The interrupt path must own the render; no timing
    # line should precede the magenta interrupt message.
    let hist = tty.cleanRaw()
    const middleDot = "\u00b7"
    for line in hist.splitLines():
      let stripped = line.strip()
      if stripped.len > 0 and stripped.startsWith(middleDot) and stripped.endsWith("s"):
        # Allow the real interrupt message through; it does not start with ·.
        doAssert false,
          "REGRESSION (spurious timing line): found `" & stripped &
          "` in transcript after interrupt; callModel emitted `· Xs` " &
          "on the no-usage interrupt path\n" & tty.dumpFramesAround(stripped)
    tty.expectAlive()
    let f = tty.frames[^1]
    check f.rows[f.cursorRow].contains("\u276f")
    echo "  PASS: interrupt during content stream emitted no `· Xs` line"

suite "network-quiet timeout on threaded transport (no interrupt)":
  test "black-holed server surfaces network-quiet error and retries":
    # Regression for the silent count-up bug (cell tower drop). The threaded
    # transport (callModelThreaded) delegates the blocking recv/send to a
    # worker thread and polls shared state. When the provider goes silent,
    # the quiet-watch thread fires at QuietTooLongMs and the worker's bounded
    # recv loop breaks, but two fixes make this robust end-to-end:
    #   1. streamhttp now sets SO_SNDTIMEO alongside SO_RCVTIMEO, so a send
    #      wedged mid-upload on a black-holed link (the real cell-tower case:
    #      the FIN cannot leave, so shutdown() does not wake it) is bounded
    #      by the kernel instead of TCP's ~15min retransmission budget.
    #   2. callModelThreaded's poll loop now also checks isNetworkQuiet(), so
    #      even a worker wedged in an unbounded path surfaces as a retryable
    #      transport error instead of spinning forever.
    # Before these fixes a black-holed provider made the GUI's elapsed
    # counter climb silently (227s, 2000s) with no retry notice, because the
    # worker never returned and callModel's retry loop was never reached.
    # This test asserts a retry notice appears within the shrunk quiet
    # window — impossible before the fix.
    let root = newFixture("quiet_timeout_retry")
    let srv = startMockServer(msSilentAfterAccept)
    defer: stopMockServer(srv)
    writeProviderConfig(root, srv.url)
    let tty = newTtySession(quietBin,
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
    # No user interrupt. The server accepted the connection and will never
    # reply. Before the fix this hung silently past the quiet window; with
    # the fix a retry notice must appear within a bounded time of the quiet
    # flag firing (QuietTooLongMs=3s here + a margin).
    let t0 = epochTime()
    let seen = tty.expectInHistory("retry", timeoutMs = 12000)
    let elapsed = epochTime() - t0
    doAssert seen,
      "no retry notice appeared after " & formatFloat(elapsed, ffDecimal, 1) &
      "s against a black-holed server; the threaded transport did not " &
      "surface the network-quiet timeout\n" & tty.dumpFramesAround("retry")
    tty.expectAlive()
    echo "  PASS: network-quiet surfaced and retried in ",
      formatFloat(elapsed, ffDecimal, 2), "s"

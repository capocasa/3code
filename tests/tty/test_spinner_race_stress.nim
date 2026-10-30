discard """
  disabled: "win"
  ## Hangs under ConPTY: the long retry-backoff window + continuous typing
  ## stress hits a ConPTY output-pipe buffer-full deadlock that doesn't
  ## manifest on POSIX (POSIX PTY writes don't block the writer the same
  ## way). Not a product bug; a harness/ConPTY throughput limitation.
"""
## Stress: type continuously into the buffered editor while the spinner is
## running through a 429 retry backoff. The spinner thread repaints the live
## editor (via renderFooter -> redrawBytes) while the input thread mutates the
## same LineEditor (typing). Without synchronization this is a data race that
## corrupts the heap and crashes with SIGSEGV in the allocator. Repeated
## runs across many backoff windows surface the crash reliably.
import std/[json, os, posix, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubEnv(root, responsesPath: string; guiLive = false): seq[EnvVar] =
  let data = root / "data"
  createDir(root / "tmp")
  result = @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]
  if guiLive:
    # Keep the gui thread's real 80ms cadence: the cancel-vs-repaint
    # interleaving under test needs the free-running spinner ticks.
    result.add (key: "THREECODE_TEST_GUI_LIVE", val: "1")

proc rawSend(s: TtySession; text: string) =
  if text.len == 0: return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)

suite "spinner runs through backoff while typing":
  test "no SIGSEGV when typing during backoff backoff":
    for iteration in 1 .. 20:
      let root = newFixture("spinner_race_" & $iteration)
      writeConfiguredProvider(root)
      var responses = newJArray()
      # Several 429s so the backoff window is long enough to type into.
      for _ in 0 ..< 3:
        responses.add %*{"failure": "429", "body": "{\"error\":\"rate limit\"}"}
      responses.add %*{"role": "assistant", "preStreamDelayMs": 50,
                      "content": "recovered", "contentChunks": ["recovered"],
                      "usage": {"promptTokens": 5, "completionTokens": 1,
                                "totalTokens": 6, "cachedTokens": 0}}
      writeFile(root / "run" / "stub_responses.json", $responses)
      let stub = ensureStubBinary(extraDefines = "-d:fastStubRetries")
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer:
        tty.close()
      tty.expect "\u276f"
      tty.send "go"
      tty.expect "go"
      tty.send "\n"
      tty.expectNoticeRow("429")
      # Hammer the buffered editor with keystrokes throughout the backoff.
      for burst in 1 .. 40:
        tty.send "abcdefghij"
        tty.advanceTicker()
        tty.drain(5, recordFrame = false)
      tty.expectAlive()
      tty.send "\x03"
      tty.drain(200)
      # The child must survive the backoff without crashing.
      tty.expectAlive()
    echo "  PASS: spinner + typing during backoff did not crash"

  test "no SIGSEGV when cancelling a queued prompt during live stream repaint":
    # The guiLoop spinner repaints the volatile block through
    # repaintLiveContent while live content streams, the input thread
    # cancels a queued prompt (ESC/CTRL-C clears the draft editor state)
    # and the debounced draft save snapshots the editor buffer, all
    # against the same LineEditor. The save path used to read `line.text` under
    # inputStateLock instead of the terminal write lock, racing the
    # string payload's refcount with the input thread's mutation and
    # corrupting the heap (guiLoop repaintLiveContent SIGSEGV in
    # eqStrings). Repeated queued-prompt cancels during streaming surface
    # the race; the child must survive every iteration.
    for iteration in 1 .. 12:
      let root = newFixture("cancel_stream_" & $iteration)
      writeConfiguredProvider(root)
      var chunks = newJArray()
      for i in 0 ..< 80:
        chunks.add %*("chunk-" & $i & " ")
      let responses = %*[
        {"role": "assistant", "preStreamDelayMs": 200,
         "content": "done", "contentChunks": chunks,
         "contentChunkDelayMs": 80,
         "usage": {"promptTokens": 5, "completionTokens": 1,
                   "totalTokens": 6, "cachedTokens": 0}}]
      writeFile(root / "run" / "stub_responses.json", $responses)
      let stub = ensureStubBinary()
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json",
                                            guiLive = true))
      defer:
        tty.close()
      tty.expect "\u276f"
      tty.send "go"
      tty.expect "go"
      tty.send "\n"
      # Wait until the stream is live: the first chunks are visible.
      tty.expect "chunk-1"
      # Queue a prompt (pending caret), keep typing, then cancel with
      # ESC/CTRL-C while the stream repaint keeps flowing.
      for burst in 1 .. 8:
        rawSend(tty, "followup text ")
        tty.drain(60, recordFrame = false)
        rawSend(tty, "\n")
        tty.drain(60, recordFrame = false)
        rawSend(tty, "abcd")
        tty.drain(40, recordFrame = false)
        if burst mod 2 == 1:
          rawSend(tty, "\x1b")
        else:
          rawSend(tty, "\x03")
        tty.drain(120, recordFrame = false)
        tty.expectAlive()
      # Let the turn finish and the idle prompt return.
      tty.drain(2000, recordFrame = false)
      tty.expectAlive()
    echo "  PASS: cancel during live stream did not crash"

  test "no SIGSEGV when buffered-text cancel resets editor during live ticks":
    # Same family, the next window over: cancelling buffered text mid-turn
    # runs in the input thread's `except InputCancelled` handler, OUTSIDE
    # readLineWith's preMutate..postMutate terminal-lock window. The handler
    # reassigns `ed.line`, `renderSuffix`, `renderSuffixCursor`, `renderRow`
    # unlocked; the gui tick's repaintLiveContent walks those same fields
    # (renderRowSpans, editorSig, prevRowSpans reassignment at the paint's
    # editor block) under the terminal write lock. The unlocked reassign
    # decs the old string payloads' ORC cells while the gui thread holds
    # uncounted borrows of them, freeing rows mid-walk: SIGSEGV in
    # visualCols/diffRowBytes on the gui thread (release manifests; dev
    # raises a Defect or survives on timing). Each cancel is one window,
    # so every iteration is a fresh turn driven to a dense cancel.
    for iteration in 1 .. 12:
      let root = newFixture("cancel_reset_" & $iteration)
      writeConfiguredProvider(root)
      let chunks = block:
        var cs = newJArray()
        for i in 0 ..< 40:
          cs.add %*("chunk-" & $i & " ")
        cs
      let responses = %*[
        {"role": "assistant", "preStreamDelayMs": 100,
         "content": "done", "contentChunks": chunks,
         "contentChunkDelayMs": 80,
         "usage": {"promptTokens": 5, "completionTokens": 1,
                   "totalTokens": 6, "cachedTokens": 0}}]
      writeFile(root / "run" / "stub_responses.json", $responses)
      let tty = newTtySession(ensureStubBinary(),
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json",
                                            guiLive = true))
      defer:
        tty.close()
      tty.expect "\u276f"
      tty.send "go"
      tty.expect "go"
      tty.send "\n"
      tty.expect "chunk-1"
      # Type buffered text, cancel it (mid-turn: prefill stash + reset),
      # retype, cancel with the other chord. Tight cycles so each 80ms
      # gui tick overlaps an except-handler window as often as possible.
      for burst in 1 .. 6:
        rawSend(tty, "buffered draft text " & $burst)
        tty.drain(40, recordFrame = false)
        rawSend(tty, if burst mod 2 == 1: "\x1b" else: "\x03")
        tty.drain(40, recordFrame = false)
        tty.expectAlive()
        rawSend(tty, "retyped " & $burst)
        tty.drain(40, recordFrame = false)
        rawSend(tty, if burst mod 2 == 1: "\x03" else: "\x1b")
        tty.drain(40, recordFrame = false)
        tty.expectAlive()
      tty.drain(1500, recordFrame = false)
      tty.expectAlive()
    echo "  PASS: buffered-cancel reset during live ticks did not crash"

  test "no SIGSEGV on resize redraw while the bash viewport streams":
    # The input thread's resize path (getCh raises IOError ->
    # consumeResizePending -> fullRedraw -> diffEditorFrame ->
    # paintVolatileRegion) iterates a by-value snapshot of
    # `engine.toolViewportRows` under the terminal write lock while the
    # controller streams tool-output lines into the frame model and the
    # gui tick repaints the viewport composite. Any unlocked reassign of
    # the engine's row seqs (or of strings aliased into them) races that
    # iteration and frees rows mid-copy: SIGSEGV in vrText at
    # paintVolatileRegion's `cur.add vrText(row)`. Drive the exact
    # geometry: a real streaming bash viewport, free-running gui ticks,
    # continuous typing, and a resize churn that fires the input
    # thread's resize fullRedraw.
    proc liveEnv(root, responsesPath: string): seq[EnvVar] =
      # The real bash tool needs PATH; TERM makes the pty a normal xterm
      # for the child's terminal-width probes.
      stubEnv(root, responsesPath, guiLive = true) &
        @[(key: "TERM", val: "xterm-256color"),
          (key: "PATH", val: getEnv("PATH"))]

    for iteration in 1 .. 6:
      let root = newFixture("viewport_resize_" & $iteration)
      writeConfiguredProvider(root)
      let watchArgs = $ %*{"command": "for i in $(seq 1 140); " &
        "do echo 'watch line ' $i ' of the stream, padded to wrap'; " &
        "sleep 0.04; done"}
      let responses = %*[
        {"role": "assistant",
         "content": "Running the watch.",
         "tool_calls": [
           {"id": "c_watch", "type": "function",
            "function": {"name": "bash", "arguments": watchArgs}}],
         "usage": {"promptTokens": 10, "completionTokens": 6,
                   "totalTokens": 16, "cachedTokens": 0}},
        {"role": "assistant", "content": "done",
         "contentChunks": ["done"],
         "usage": {"promptTokens": 40, "completionTokens": 4,
                   "totalTokens": 44, "cachedTokens": 0}}]
      writeFile(root / "run" / "stub_responses.json", $responses)
      let tty = newTtySession(ensureStubBinary(),
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = liveEnv(root,
                                            root / "run" / "stub_responses.json"),
                              cols = 80, rows = 24)
      defer:
        tty.close()
      tty.expect "\u276f"
      tty.send "go"
      tty.expect "go"
      tty.send "\n"
      # The tool viewport is live once its banner (the wrapped command)
      # lands; the streamed lines scroll a tail window, so no specific
      # line number is stable to wait for.
      tty.expect "seq 1 140"
      for burst in 1 .. 60:
        rawSend(tty, "typing during the stream " & $burst)
        tty.drain(20, recordFrame = false)
        # Width churn fires SIGWINCH; every few bursts also change height
        # so the row geometry (not just the wrap) shifts under the painter.
        tty.resize(60 + 40 * (burst and 1),
                   24 - 8 * ((burst div 3) and 1))
        tty.drain(20, recordFrame = false)
        if burst mod 10 == 0:
          tty.expectAlive()
      # The turn must finish and the child survive it.
      tty.drain(3000, recordFrame = false)
      tty.expectAlive()
    echo "  PASS: resize churn during viewport stream did not crash"

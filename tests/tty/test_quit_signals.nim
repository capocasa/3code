## Quit-signalling behaviour at the prompt and during a turn.
##
## The fat prompt honours several ways out, and each must do *only* what its
## readline contract promises — nothing more, nothing less:
##
##   * Ctrl-D on an *empty* prompt line quits (exactly like `:q`).
##   * Ctrl-D with text present is a *no-op*: the text stays, it never
##     quits and never edits.
##   * Ctrl-D never interrupts an ongoing turn.
##   * Ctrl-C with text on the prompt clears the text and does NOT
##     interrupt; Ctrl-C on an empty prompt interrupts an ongoing turn.
##   * ESC always interrupts an ongoing turn and never touches the text.
##   * `:q`, `:quit` and `:exit` quit from an idle prompt.
##   * No quit path leaves a stack trace or internal-error notice behind.
##
## The "traceback after Ctrl-D" report was the trigger for this file: a quit
## must be clean. The raw byte stream (which carries stderr, since the PTY
## slave is the child's stderr) is asserted to contain no `Traceback` /
## `internal error` after every exit.
import std/[json, os, strutils, times, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc startStub(root: string; args: openArray[string] = ["-x", "-i"]): TtySession =
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"))

proc assertNoTrace(tty: TtySession) =
  ## The PTY slave is the child's stderr, so any Nim stack trace or
  ## "3code: internal error" notice lands in the raw byte stream. A clean
  ## quit must leave neither.
  let raw = tty.cleanRaw()
  check "Traceback" notin raw
  check "internal error" notin raw
  check "Error: unhandled exception" notin raw

proc fastResponses(): JsonNode =
  %*[{"role": "assistant", "preStreamDelayMs": 100, "content": "ok.",
      "contentChunks": ["ok."],
      "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}]

proc slowResponses(): JsonNode =
  ## Long enough that Ctrl-D lands mid-turn with the buffered editor empty.
  %*[{"role": "assistant", "preStreamDelayMs": 4000, "content": "done.",
      "contentChunks": ["done."],
      "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}]

suite "quit signals":
  test "Ctrl-D on an empty prompt quits like :q":
    let root = newFixture("ctrl_d_empty_quits")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"           # idle prompt is up
    tty.send "\x04"               # Ctrl-D on an empty line
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: Ctrl-D on empty prompt quit cleanly (exit 0)"

  test "Ctrl-D with text present is a no-op (does not quit)":
    let root = newFixture("ctrl_d_with_text_noop")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "hello":
      tty.send($ch); tty.drain(10)
    tty.expect "\u276f hello"
    tty.send "\x04"               # no-op mid-text
    tty.drain(300)
    tty.expectAlive()             # must NOT have quit
    tty.expect "\u276f hello"     # text still intact
    assertNoTrace(tty)
    echo "  PASS: Ctrl-D with text present was a no-op"

  test "Ctrl-D during an active turn does NOT interrupt; Ctrl-C then quits":
    when defined(windows):
      # Under the ConPTY harness the buffered-editor mid-turn path wedges
      # on the inert \x04: the Windows getCh has no poll, so the input
      # thread cannot tell a mid-turn keystroke from stdin EOF the way the
      # POSIX poll-based reader can. The quit-side semantics are covered
      # by the idle Ctrl-D test on Windows; the mid-turn semantics are
      # POSIX-only here. See docs/windows-testing.md.
      skip()
    let root = newFixture("ctrl_d_during_turn_noop")
    writeConfiguredProvider(root)
    # The response never arrives on its own (30s pre-stream delay), so the
    # turn stays open across the whole assertion sequence regardless of
    # CI latency; only the interrupt can end it.
    writeStubResponses(root, %*[{"role": "assistant", "preStreamDelayMs": 30000,
        "content": "done.", "contentChunks": ["done."],
        "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}])
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    # Wait for the turn to actually start: the spinner frame's
    # `○0%` token-bar text is emitted only after beginTurn set
    # inputTurnActive, so matching it in the raw stream is a hard sync
    # point. A fixed sleep races turn startup under load: the inert
    # \x04 below would then land at an idle prompt and quit the process
    # instead.
    tty.expect "○0%"
    tty.drain(200)               # spinner up, turn running
    tty.send "\x04"              # Ctrl-D during a turn: inert, no interrupt
    tty.drain(300)
    tty.expectNo "interrupted by user"
    tty.expectNo "done."         # the turn is still open
    tty.expectAlive()            # ...and no quit either
    # Ctrl-C on the empty buffered editor interrupts the turn. Via
    # `ctrlC()` because raw \x03 is swallowed by conhost under the
    # Windows ConPTY harness; there it sends ESC (the always-interrupt
    # key), which exercises the same code path.
    tty.ctrlC()
    tty.expectInHistory "interrupted by user"
    # Do NOT use expectIdleCaret here: under load the first prompt
    # repaint after the interrupt can land between grid polls, leaving
    # the caret row glyph-less in the snapshot (the documented tty
    # wall-clock flake; see plan-flakiness.md). The functional proof
    # that the prompt is back is that a quit key works at all: if the
    # turn were still active or the editor dead, the \x04 below would
    # do nothing and expectExit would fail.
    tty.expectAlive()
    tty.send "\x04"
    tty.expectExit(0, timeoutMs = 8000)
    assertNoTrace(tty)
    echo "  PASS: Ctrl-D during a turn was inert; Ctrl-C interrupted; Ctrl-D quit"

  test "Ctrl-C with text clears the prompt without interrupting the turn":
    let root = newFixture("ctrl_c_clears_during_turn")
    writeConfiguredProvider(root)
    writeStubResponses(root, slowResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    tty.drain(400)               # turn running
    for ch in "draft":           # type into the buffered editor mid-turn
      tty.send($ch); tty.drain(10)
    tty.send "\x03"              # Ctrl-C with text: clear only, no interrupt
    tty.drain(300)
    tty.expectNo "interrupted by user"
    # The typed draft must be gone from the live prompt row (it remains in
    # the raw byte history from when it was echoed while typing, so check
    # the settled screen, not the byte stream).
    check "draft" notin tty.screenText()
    # The turn is still running: a bare ESC interrupts it (ESC never edits).
    tty.send "\x1b"
    tty.expectInHistory "interrupted by user"
    tty.expectIdleCaret()
    tty.expectAlive()
    assertNoTrace(tty)
    echo "  PASS: Ctrl-C cleared the draft without interrupting; ESC interrupted"

  test ":q quits from an idle prompt":
    let root = newFixture("colon_q_quits")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: :q quit cleanly (exit 0)"

  test ":quit quits from an idle prompt":
    let root = newFixture("colon_quit_quits")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    tty.send ":quit\n"
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: :quit quit cleanly (exit 0)"

  test ":exit quits from an idle prompt":
    let root = newFixture("colon_exit_quits")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    tty.send ":exit\n"
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: :exit quit cleanly (exit 0)"

  test "Ctrl-C during an active turn interrupts and stays alive":
    let root = newFixture("ctrl_c_interrupts_turn")
    writeConfiguredProvider(root)
    writeStubResponses(root, slowResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    tty.drain(400)               # let the turn start (spinner up)
    tty.send "\x03"              # Ctrl-C on the empty buffered editor
    tty.expectInHistory "interrupted by user"
    tty.expectIdleCaret()        # prompt returns after the interrupt
    tty.expectAlive()            # the process did NOT exit
    assertNoTrace(tty)
    echo "  PASS: Ctrl-C during a turn interrupted it and the prompt returned"

  test ":q queued during an active turn is honoured after it ends":
    let root = newFixture("colon_q_queued_during_turn")
    writeConfiguredProvider(root)
    writeStubResponses(root, fastResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    tty.drain(300)               # turn running
    # Queue a quit while the turn is still active; the controller must drain
    # it after the turn ends and exit cleanly.
    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 8000)
    assertNoTrace(tty)
    echo "  PASS: :q queued during a turn exited cleanly after the turn"

  test "Ctrl-C during retry backoff then Ctrl-D quits (inputTurnActive reset)":
    # Regression: an interrupt raised while the transport is sleeping off a
    # retry backoff surfaces as `ApiError "interrupted by user during retry
    # backoff"`. `runTurns` matched only the bare `"interrupted by user"`
    # string, so the suffixed message fell through to the generic-error path
    # (`endTurnAfterTranscriptAppend`), which skips `onTurnInterrupted`'s
    # `stopTurnInputForFinalRender`. `inputTurnActive` stayed true, so every
    # later Ctrl-D was misrouted to the turn-interrupt branch (a no-op at
    # idle) and the prompt could not be quit via the keyboard.
    let root = newFixture("interrupt_backoff_then_ctrl_d")
    writeConfiguredProvider(root)
    # 2x 429 (StubMaxAttempts=2 via -d:fastStubRetries) then a reply. We
    # Ctrl-C during the first 429's backoff to take the
    # "interrupted by user during retry backoff" raise.
    writeStubResponses(root, %*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"role": "assistant", "preStreamDelayMs": 50, "content": "recovered",
       "contentChunks": ["recovered"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                  "totalTokens": 6, "cachedTokens": 0}}
    ])
    let stub = ensureStubBinary(extraDefines = "-d:fastStubRetries")
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    # Wait for the first retry notice so the transport is mid-backoff.
    tty.expectInHistory "429"
    tty.drain(50)
    tty.send "\x03"               # Ctrl-C during the retry backoff
    tty.expectInHistory "interrupted by user"
    tty.expectIdleCaret()         # prompt returns after the interrupt
    tty.expectAlive()             # interrupt did not exit the process
    # Now at an idle, empty prompt: Ctrl-D must quit like `:q` would. Before
    # the fix this did nothing because inputTurnActive was still true.
    tty.send "\x04"
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: Ctrl-C during retry backoff then Ctrl-D quit cleanly"

  test "Ctrl-C interrupt then Ctrl-D quits (inputTurnActive must reset)":
    # Regression: a user interrupt (Ctrl-C/ESC) during an active turn left
    # `inputTurnActive` stuck true because `runTurns` skips its deferred
    # `endTurn` on interrupt and `onTurnInterrupted` never reset the flag.
    # With the flag stuck, every later Ctrl-D was misrouted to the turn-
    # interrupt branch instead of the quit branch, so Ctrl-D silently did
    # nothing and the prompt was impossible to leave via the keyboard.
    let root = newFixture("interrupt_then_ctrl_d")
    writeConfiguredProvider(root)
    writeStubResponses(root, slowResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    tty.drain(400)               # turn running
    tty.ctrlC()                  # user interrupt
    tty.expectInHistory "interrupted by user"
    tty.expectIdleCaret()        # prompt returns after the interrupt
    tty.expectAlive()            # interrupt did not exit the process
    # Now at an idle, empty prompt: Ctrl-D must quit like `:q` would.
    tty.send "\x04"
    tty.expectExit(0, timeoutMs = 5000)
    assertNoTrace(tty)
    echo "  PASS: Ctrl-C interrupt then Ctrl-D quit cleanly"

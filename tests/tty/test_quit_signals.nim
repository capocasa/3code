discard """
  # See docs/windows-testing.md. The tty_expect harness uses openpty/fork/
  # execv (POSIX only). A ConPTY port is the path to re-enable on Windows.
  disabled: "win"
  # On macOS the harness compiles but hangs deterministically: the expect*
  # procs poll on wall-clock deadlines (plan-flakiness.md) and starve under
  # the OSX runner's scheduler, so a subtest never returns. Re-enable after
  # the frame-event sync rewrite lands.
  disabled: "osx"
"""
## Quit-signalling behaviour at the prompt and during a turn.
##
## The fat prompt honours several ways out, and each must do *only* what its
## readline contract promises — nothing more, nothing less:
##
##   * Ctrl-D on an *empty* prompt line quits (exactly like `:q`).
##   * Ctrl-D with text present is a *no-op* at line end (it is delete-char,
##     so at the end of the line there is nothing to delete); it never quits.
##   * `:q`, `:quit` and `:exit` quit from an idle prompt.
##   * Ctrl-D during an *active* turn (empty buffered editor) interrupts the
##     turn; the process stays alive and the prompt returns.
##   * No quit path leaves a stack trace or internal-error notice behind.
##
## The "traceback after Ctrl-D" report was the trigger for this file: a quit
## must be clean. The raw byte stream (which carries stderr, since the PTY
## slave is the child's stderr) is asserted to contain no `Traceback` /
## `internal error` after every exit.
import std/[json, os, strutils, unittest]
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
search-url = "http://127.0.0.1:1/?q="

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
    tty.send "\x04"               # at line end: delete-char does nothing
    tty.drain(300)
    tty.expectAlive()             # must NOT have quit
    tty.expect "\u276f hello"     # text still intact
    assertNoTrace(tty)
    echo "  PASS: Ctrl-D with text present was a no-op"

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

  test "Ctrl-D during an active turn interrupts and stays alive":
    let root = newFixture("ctrl_d_interrupts_turn")
    writeConfiguredProvider(root)
    writeStubResponses(root, slowResponses())
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "\u276f"
    for ch in "go":
      tty.send($ch); tty.drain(10)
    tty.send "\n"
    tty.drain(400)               # let the turn start (spinner up)
    tty.send "\x04"              # Ctrl-D on the empty buffered editor
    tty.expectInHistory "interrupted by user"
    tty.expectIdleCaret()        # prompt returns after the interrupt
    tty.expectAlive()            # the process did NOT exit
    assertNoTrace(tty)
    echo "  PASS: Ctrl-D during a turn interrupted it and the prompt returned"

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

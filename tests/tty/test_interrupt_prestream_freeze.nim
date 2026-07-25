discard """
  disabled: "win"
  ## Sends raw \x03 (Ctrl-C) and \x1b (ESC) to interrupt an in-flight call.
  ## Under ConPTY, \x03 is silently consumed by conhost (see tty_expect.ctrlC)
  ## and ESC-based interrupt during a non-wizard turn is not yet wired
  ## through the Windows ESCAPES path for this scenario. The core interrupt
  ## path is covered on Windows by test_quit_signals (Ctrl-D / ctrlC surrogate).
"""
## Targeted regression: pressing Ctrl-C or ESC while a model call is in
## flight but has produced NO answer yet (the pre-stream delay / thinking
## phase) used to leave the prompt in a state where typing worked but Enter
## only inserted a newline and never sent. The input thread and the
## controller disagreed about whether a turn was still active, so a queued
## idle submit was never consumed.
import std/[json, os, unittest, strutils]
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

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  let data = root / "data"
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

suite "interrupt during pre-stream freeze regression":
  test "ESC during in-flight call (no answer) then a real prompt sends":
    let root = newFixture("interrupt_prestream_esc")
    writeConfiguredProvider(root)
    # First response: long pre-stream delay so the call is in flight with no
    # answer when we interrupt. Second response: a normal reply for the
    # follow-up prompt that must actually be sent after the interrupt.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 30000,
       "content": "should not appear", "contentChunks": ["should not appear"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "ok.", "contentChunks": ["ok."],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # Call is now in flight with no answer. Interrupt with ESC.
    tty.drain(300)
    tty.send "\x1b"
    tty.expectInHistory "interrupted by user"
    tty.drain 300  # let the post-interrupt prompt frame settle
    # Regression: cancel must leave the prompt glyph on the caret row
    # with the caret at col 2. A passing `expect "❯"` is not enough —
    # the earlier `❯` from the submitted prompt row can match. See the
    # matching assertion in the waitForTestContinue-based tests for the
    # full bug description.
    let fEsc = tty.frames[^1]
    doAssert not fEsc.cursorHidden,
      "REGRESSION (interrupted-by-user): caret hidden after ESC; expected col 2 on prompt row"
    doAssert fEsc.cursorCol == 2,
      "REGRESSION (interrupted-by-user): expected caret at col 2 after ❯, got " & $fEsc.cursorCol
    doAssert fEsc.rows[fEsc.cursorRow].contains("❯"),
      "REGRESSION (interrupted-by-user): prompt glyph ❯ missing from caret row " &
        $fEsc.cursorRow & ", got: '" & fEsc.rows[fEsc.cursorRow] & "'"

    # The prompt must come back and accept a real prompt.
    tty.expect "\u276f"
    tty.expectAlive()  # ESC during in-flight call must not exit
    tty.send "hello model"
    tty.expect "hello model"
    tty.send "\n"
    # expect() has a 5s timeout; if Enter wedges into a newline-only state,
    # this never appears and the test fails instead of hanging the suite.
    tty.expectInHistory "ok."
    echo "  PASS: ESC during in-flight call did not freeze the prompt"

  test "Ctrl-C during in-flight call (no answer) then a real prompt sends":
    let root = newFixture("interrupt_prestream_ctrlc")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 30000,
       "content": "should not appear", "contentChunks": ["should not appear"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "ok.", "contentChunks": ["ok."],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    tty.drain(300)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain 300  # let the post-interrupt prompt frame settle
    # Same interrupted-by-user prompt contract as the ESC case — glyph
    # on the caret row, caret at col 2. See the matching assertion in
    # the ESC test for the bug being locked out.
    let fCtlc = tty.frames[^1]
    doAssert not fCtlc.cursorHidden,
      "REGRESSION (interrupted-by-user): caret hidden after Ctrl-C; expected col 2 on prompt row"
    doAssert fCtlc.cursorCol == 2,
      "REGRESSION (interrupted-by-user): expected caret at col 2 after ❯, got " & $fCtlc.cursorCol
    doAssert fCtlc.rows[fCtlc.cursorRow].contains("❯"),
      "REGRESSION (interrupted-by-user): prompt glyph ❯ missing from caret row " &
        $fCtlc.cursorRow & ", got: '" & fCtlc.rows[fCtlc.cursorRow] & "'"

    tty.expect "\u276f"
    tty.expectAlive()  # Ctrl-C during in-flight call must not exit
    tty.send "hello model"
    tty.expect "hello model"
    tty.send "\n"
    tty.expectInHistory "ok."
    echo "  PASS: Ctrl-C during in-flight call did not freeze the prompt"

  test "ESC then immediate follow-up during in-flight call (race window)":
    # The fragile window: ESC requests the interrupt, but the main thread
    # is still blocked in the model call. Typing the next prompt before the
    # turn fully ends must not wedge the editor into a state where Enter
    # only inserts newlines. The prompt may queue (hourglass) and send once
    # the turn ends, but it must eventually send.
    let root = newFixture("interrupt_prestream_race")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 30000,
       "content": "should not appear", "contentChunks": ["should not appear"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "ok.", "contentChunks": ["ok."],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    tty.drain(200)
    # ESC then immediately type the follow-up, before the turn ends.
    tty.send "\x1b"
    tty.send "hello model"
    tty.send "\n"
    # Whatever path it took (queued-then-sent, or sent after interrupt), the
    # follow-up must produce the second response. A freeze shows up as a
    # timeout here.
    tty.expectInHistory "ok."
    tty.expectAlive()  # the ESC+follow-up race must not exit the process
    echo "  PASS: ESC + immediate follow-up did not freeze"

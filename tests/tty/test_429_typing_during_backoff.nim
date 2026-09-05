discard """
  disabled: "win"
  ## Hangs under ConPTY (same throughput deadlock as test_spinner_race_stress;
  ## the long backoff window + typing stress fills the ConPTY output pipe).
"""
## Regression: text typed into the buffered editor while a 429 retry is in
## flight must survive both ending paths of the retry block — ESC
## cancelling the backoff and the retry budget exhausting cleanly. The
## earlier behavior wiped `ed.line.text` on the InputCancelled path so the
## prompt came back empty (`❯ `) and the user had to retype the whole
## follow-up. The visual anchor then landed at column 2 of an empty
## editor, which read as "the caret is on the wrong column" to anyone
## looking at the screen.
##
## The empty-editor case is already covered by `test_retry_exhaustion`
## (3x 503) and the Ctrl-C case by `test_interrupt_prestream_freeze`. The
## thing those tests do NOT cover is "text the user typed during the
## backoff must still be on the prompt row after the cancel/exhaust
## resolves". This file covers that gap on the 429 path specifically,
## which has its own backoff schedule (rateRetryLevel, capped at 90s) and
## is the path users actually hit.
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

suite "429 backoff with buffered typing":
  test "ESC during 429 backoff preserves the typed follow-up prompt":
    let root = newFixture("429_typed_esc")
    writeConfiguredProvider(root)
    # 2x 429 (StubMaxAttempts=2 with -d:fastStubRetries) then a normal
    # reply. The 2nd 429 is the one that would exhaust the budget if we
    # did not Ctrl-C; we Ctrl-C during the first backoff to take the
    # "interrupted during retry backoff" path.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "recovered", "contentChunks": ["recovered"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                  "totalTokens": 6, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary(extraDefines = "-d:fastStubRetries")
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
    # Wait for the retry notice to land in scrollback so the spinner is
    # mid-backoff when we type. Generous budget: on the slow macOS CI
    # runner the app's submit-to-notice latency alone approached the 5s
    # default (two OSX flakes).
    tty.expectInHistory("429", timeoutMs = 15_000)
    tty.drain(50)
    # Type the follow-up. The text lives in `ed.line.text` while a turn
    # is running; the editor paints it on top of the spinner so the
    # user can see what they're typing.
    tty.send "next prompt"
    tty.expect "next prompt"
    tty.drain(100)
    # ESC. The interrupt should preserve the buffered text and leave
    # the caret at the end of the typed string (ESC never edits; a
    # Ctrl-C here would clear the draft instead of interrupting).
    tty.send "\x1b"
    tty.expectInHistory "interrupted by user"
    tty.drain(500)
    tty.expectAlive()
    # Post-cancel prompt contract: the prompt glyph and the typed text
    # are both on the caret row, and the caret sits past the typed text
    # (so the user can hit Enter to send it as the next prompt).
    let f = tty.frames[^1]
    doAssert not f.cursorHidden,
      "REGRESSION: caret hidden after 429+ESC with buffered text"
    let caretRow = f.rows[f.cursorRow]
    doAssert caretRow.contains("next prompt"),
      "REGRESSION: buffered 'next prompt' not on caret row " &
        $f.cursorRow & ", got: '" & caretRow & "'"
    doAssert caretRow.contains("\u276f"),
      "REGRESSION: prompt glyph \u276f missing from caret row " &
        $f.cursorRow & ", got: '" & caretRow & "'"
    # The caret must sit past the typed text, not at column 2 of an
    # empty editor. The exact column is a cell count, not a byte count
    # (the `❯` is a 3-byte UTF-8 glyph but 1 cell), so we only assert
    # the lower bound.
    doAssert f.cursorCol > 12,
      "REGRESSION: caret at col " & $f.cursorCol &
        " but should be past the typed 'next prompt' (>= 13); row: '" &
        caretRow & "'"
    # The preserved follow-up must actually be sent on Enter.
    tty.send "\n"
    tty.expectInHistory "recovered"
    echo "  PASS: 429+ESC kept the buffered follow-up on the prompt row"

  test "429 budget exhaustion preserves the typed follow-up prompt":
    let root = newFixture("429_typed_exhaust")
    writeConfiguredProvider(root)
    # 3x 429 = StubMaxAttempts (2, via -d:fastStubRetries) + 1 follow-up.
    # The 2nd 429 exhausts the budget and surfaces an ApiError; the
    # controller's catch path renders the error and finalizes the turn.
    # A clean retry-budget-exhaust (no Ctrl-C) is the second of the two
    # ending paths the user reported: "either cancelling backoff with
    # Ctrl-C or waiting for it to complete".
    var responses = newJArray()
    for _ in 0 ..< 2:
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
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # Wait long enough for the first retry notice to land AND for the
    # user to type a follow-up while the spinner is still ticking
    # through the second backoff.
    tty.expectInHistory "429"
    tty.drain(50)
    tty.send "next prompt"
    tty.expect "next prompt"
    # Now wait for the budget to exhaust. 2 retries with rateRetryLevel
    # backoffs (1s, then 1s) take ~2s; allow a generous ceiling for
    # busy CI runners.
    tty.drain(4000)
    tty.expectAlive()
    tty.drain(500)
    # Same contract as the Ctrl-C case: typed text + glyph on the caret
    # row, caret past the typed text.
    let f = tty.frames[^1]
    doAssert not f.cursorHidden,
      "REGRESSION: caret hidden after 429 budget exhaustion with buffered text"
    let caretRow = f.rows[f.cursorRow]
    doAssert caretRow.contains("next prompt"),
      "REGRESSION: buffered 'next prompt' not on caret row " &
        $f.cursorRow & " after 429 budget exhaustion, got: '" & caretRow & "'"
    doAssert caretRow.contains("\u276f"),
      "REGRESSION: prompt glyph \u276f missing from caret row " &
        $f.cursorRow & " after 429 budget exhaustion, got: '" & caretRow & "'"
    doAssert f.cursorCol > 12,
      "REGRESSION: caret at col " & $f.cursorCol &
        " but should be past the typed 'next prompt' (>= 13); row: '" &
        caretRow & "'"
    # The preserved follow-up must actually be sent on Enter.
    tty.send "\n"
    tty.expectInHistory "recovered"
    echo "  PASS: 429 budget exhaustion kept the buffered follow-up"
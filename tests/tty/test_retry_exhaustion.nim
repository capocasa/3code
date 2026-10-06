## Regression: when `callModel` exhausts its retry budget (e.g. provider keeps
## returning 503), the session should land back at a clean prompt glyph. The
## earlier behavior crashed with a SIGSEGV or wedged the input thread.
import std/[json, os, strutils, unittest]
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

# ConPTY re-synthesizes the output stream: erase-to-EOL becomes padding
# spaces and every trailing cursor-only move (the CR+CUF park, and even an
# absolute CUP) is dropped, so the physical cursor parks wherever ConPTY's
# last cell write ended, at the row's right edge, never at the app's target
# column. The caret column is therefore only assertable against a raw PTY
# stream. Verified with a ConPTY capture probe on a real Windows box: both
# park forms vanish from the synthesized stream.
const rawPtyCaretCol = not defined(windows)

func promptSettled(f: TtyFrame): bool =
  ## Typing-ready: cursor hidden, prompt glyph on the caret row, and on a
  ## raw PTY also the physical caret parked at the glyph.
  f.cursorHidden and f.cursorRow < f.rows.len and
    "\u276f" in f.rows[f.cursorRow] and
    (not rawPtyCaretCol or f.cursorCol == 2)

suite "retry exhaustion regression":
  test "baseline: a successful turn leaves the prompt in the typing-ready state":
    # Sanity check: after a normal successful turn, the prompt glyph sits on
    # the caret row with the caret at col 2. If this fails too, the
    # retry-exhaustion test below is useless because the test harness can't
    # detect a broken prompt at all.
    let root = newFixture("retry_exhaust_baseline")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "hi", "contentChunks": ["hi"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                 "totalTokens": 6, "cachedTokens": 0}}
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
    tty.send "\n"
    tty.expectInHistory "hi"
    # A loaded CI runner can lag the spinner→prompt repaint well past any
    # fixed sleep, so poll for the settled prompt (test_selection's cut
    # needed the same treatment).
    var settled = false
    for _ in 0 ..< 60:
      tty.drain(250)
      if tty.frames[^1].promptSettled():
        settled = true
        break
    let f = tty.frames[^1]
    doAssert settled,
      "baseline: prompt never settled after success; last frame: col=" &
      $f.cursorCol & " row=" & $f.cursorRow & " hidden=" & $f.cursorHidden
    when rawPtyCaretCol:
      doAssert f.cursorCol == 2,
        "baseline: expected caret at col 2 after ❯, got " & $f.cursorCol
    echo "  PASS: baseline prompt geometry"

  test "stub always 503 lands at a clean prompt and accepts a new prompt":
    let root = newFixture("retry_exhaust_503")
    writeConfiguredProvider(root)
    # 3 responses = StubMaxAttempts (2, via -d:fastStubRetries) + 1 follow-up.
    # Each returns 503 so the retry loop walks the full budget. With backoff
    # capped at min(1 shl serverRetryLevel, 16) and decay=0 (decayLevel only
    # ticks across minutes), the budget finishes in seconds. The 4th is a
    # normal reply that the test asserts reaches the user.
    var responses = newJArray()
    for _ in 0 ..< 3:
      responses.add %*{"failure": "http-503"}
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
    # The stub walks all 12 retries with growing backoff. 2s covers it
    # even on a busy CI runner with no decay.
    # StubMaxAttempts=2 → at most 2 retries with a 1s+2s backoff. 5s is plenty.
    tty.drain(5000)
    # Process must still be alive after the budget is exhausted.
    tty.expectAlive()
    # Same settle poll as the baseline: the retry backoff and the final
    # repaint can both overrun a fixed sleep on a loaded runner.
    var settled = false
    for _ in 0 ..< 60:
      tty.drain(250)
      if tty.frames[^1].promptSettled():
        settled = true
        break
    # Prompt glyph must be back on the caret row.
    let f = tty.frames[^1]
    doAssert settled,
      "REGRESSION (retry-exhaust): prompt never settled after exhaustion; " &
      "last frame: col=" & $f.cursorCol & " row=" & $f.cursorRow &
      " hidden=" & $f.cursorHidden
    when rawPtyCaretCol:
      doAssert f.cursorCol == 2,
        "REGRESSION (retry-exhaust): expected caret at col 2 after ❯, got " & $f.cursorCol
    doAssert f.rows[f.cursorRow].contains("❯"),
      "REGRESSION (retry-exhaust): prompt glyph ❯ missing from caret row " &
      $f.cursorRow & ", got: '" & f.rows[f.cursorRow] & "'"
    # The next prompt must be accepted and answered.
    tty.send "hello model"
    tty.expect "hello model"
    tty.send "\n"
    tty.expectInHistory "recovered"
    echo "  PASS: retry exhaustion returned to a usable prompt"

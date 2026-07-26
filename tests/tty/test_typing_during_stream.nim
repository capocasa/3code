discard """
  disabled: "win"
  disabled: "osx"
"""
## Regression: typing during an ongoing turn must land on the caret row
## at the position past the prompt glyph, not one row above at column 0.
## Reproduction for the gui-thread-refactor regression where the buffered
## editor repaint walks up one row too far, so typed text briefly lands
## on the row above and is then overwritten.
import std/[json, os, posix, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
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

proc rawSend(s: TtySession; text: string) =
  ## Write bytes directly to the PTY without the harness's printable-echo
  ## wait or frame-pause logic, so the resulting screen state is observable.
  if text.len == 0: return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)

proc snapshot(s: TtySession; label: string) =
  s.drain(40, recordFrame = true)
  let f = s.frames[^1]
  echo "  [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol,
       " hidden=", f.cursorHidden
  for i, row in f.rows:
    if row.strip.len == 0: continue
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo "    row ", i, mark, ": '", row, "'"

suite "typing during active stream":
  test "typed text lands on caret row, not one row above":
    let root = newFixture("typing_during_stream")
    writeConfiguredProvider(root)
    let chunkList = ["alpha ", "beta ", "gamma ", "delta ", "epsilon ",
                     "zeta ", "eta ", "theta ", "iota ", "kappa ",
                     "lambda ", "mu ", "nu ", "xi "]
    let chunks = %* chunkList
    let joined = chunkList.join("").strip()
    # Small content + a real usage block so the response completes cleanly
    # (no finish_reason:length retry) while the per-chunk delay keeps content
    # streaming across the whole typed burst, exercising the GUI thread's
    # live-content repaint concurrently with the input thread's redraws.
    let responses = %*[
      {"content": joined,
       "contentChunks": chunks,
       "contentChunkDelayMs": 100,
       "usage": {"promptTokens": 20, "completionTokens": 14,
                 "totalTokens": 34, "cachedTokens": 0}}
    ]
    writeFile(root / "run" / "stub_responses.json", $responses)
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
    tty.expectInHistory "alpha"
    tty.drain(100)
    # Drive each keystroke with a settle long enough to capture the GUI
    # thread's intervening streaming repaint, not just the keystroke frame.
    # While typing during a stream the caret must stay visible between
    # keystrokes: the GUI thread repaints the footer every ~80ms and must
    # not hide the caret while the editor is accepting buffered input.
    # (Regression: the streaming repaint path hid the caret and never
    # re-showed it, so the caret flickered off between keystrokes.)
    var hiddenOnPromptRow = 0
    var since = tty.frames.len
    for ch in "hello":
      rawSend(tty, $ch)
      tty.drain(60)
      # Scan every frame captured since this keystroke, not just the last:
      # the flicker lives in the transient frames the GUI thread paints
      # between keystrokes while content is streaming.
      for fi in since ..< tty.frames.len:
        let f = tty.frames[fi]
        block findPrompt:
          for i in countdown(f.rows.high, 0):
            if f.rows[i].startsWith("\u276f"):
              if f.cursorRow == i and f.cursorHidden:
                inc hiddenOnPromptRow
              break findPrompt
      since = tty.frames.len
    check hiddenOnPromptRow == 0
    if hiddenOnPromptRow != 0:
      echo "caret flickered off the prompt row ", hiddenOnPromptRow,
           " frames while typing during the stream"
    tty.drain(2000)
    tty.expectAlive()
    snapshot(tty, "final")

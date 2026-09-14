discard """
  disabled: "win"
  disabled: "osx"
"""
## Regression: typing during an ongoing turn must land on the caret row
## at the position past the prompt glyph, not one row above at column 0.
## Reproduction for the gui-thread-refactor regression where the buffered
## editor repaint walks up one row too far, so typed text briefly lands
## on the row above and is then overwritten.
##
## Second regression (same keystroke path): the editor repaint rebuilds
## the live footer frame from the frame model, whose `elapsed` field is
## never updated by the GUI thread (it computes its own clock), so every
## keystroke repaints the spinner bar with a stale `0s` until the next
## 80ms GUI tick restores the real elapsed. Typed keystrokes must never
## show an elapsed counter older than the frames around them.
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
    # Keep the gui thread's real 80ms cadence and turn clock: the frame
    # channel stays up, but test-frame mode would freeze the elapsed
    # counter at 0, hiding exactly the stale-elapsed flicker under test.
    (key: "THREECODE_TEST_GUI_LIVE", val: "1"),
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

proc barElapsedSecs(row: string): int =
  ## The trailing turn clock of a LIVE streaming bar row, in whole
  ## seconds, or -1. The format is clockDuration's (`4`, `2:08`,
  ## `1:12:21`; leading zero fields dropped). Only spinner-led rows are
  ## considered: committed receipts also end in a clock now (the turn's
  ## final elapsed), and those must not count as live frames.
  ## Harness rows carry full-width trailing padding; drop it first.
  result = -1
  let led = row.strip(leading = true, trailing = false)
  var live = false
  for g in ["\u280b", "\u2819", "\u2839", "\u2838", "\u283c", "\u2834",
            "\u2826", "\u2827", "\u2807", "\u280f"]:
    if led.startsWith(g): live = true; break
  if not live: return
  let s = row.strip(leading = false, trailing = true)
  let sp = s.rfind(' ')
  if sp < 0: return
  var mult = 1
  try:
    let parts = s[sp + 1 .. ^1].split(':')
    for i in countdown(parts.high, 0):
      if parts[i].len == 0: return -1
      inc result, parseInt(parts[i]) * mult
      mult *= 60
  except ValueError:
    result = -1

suite "typing during active stream":
  test "no cursor visibility toggles while a turn runs":
    ## The caret is a drawn cell inside the editor rows; the physical
    ## terminal cursor stays hidden for the whole interactive session.
    ## Any per-paint `?25l`/`?25h` pair is immediate-mode residue: it makes
    ## the caret flicker per keystroke (Linux) and per 80ms GUI tick
    ## (continuous on Windows Terminal, which recomposites the cursor on
    ## every visibility change). One hide at startup and one show at exit
    ## are the only legal visibility bytes.
    let root = newFixture("typing_during_stream_notoggles")
    writeConfiguredProvider(root)
    let chunks = ["aa ", "bb ", "cc ", "dd ", "ee ", "ff ", "gg ",
                  "hh ", "ii ", "jj ", "kk ", "ll ", "mm ", "nn "]
    let responses = %*[
      {"content": chunks.join("").strip(),
       "contentChunks": %* chunks,
       "contentChunkDelayMs": 150,
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
    tty.expectInHistory "aa"
    tty.drain(100)
    # Count window opens mid-turn: everything before it is startup paint
    # (the one legal session-start hide), everything after is close/cleanup.
    let mark = tty.raw.len
    for ch in "typing":
      rawSend(tty, $ch)
      tty.drain(90)
    # Hold the turn open long enough for several GUI ticks with no input.
    tty.drain(600)
    let tail = tty.raw[mark .. ^1]
    let hides = tail.count("\x1b[?25l")
    let shows = tail.count("\x1b[?25h")
    check hides == 0
    check shows == 0
    if hides != 0 or shows != 0:
      echo "cursor visibility toggled mid-turn: hides=", hides,
           " shows=", shows, " over ", tail.len, " bytes"
    tty.drain(4500)
    tty.expectAlive()

  test "typed text lands on caret row, not one row above":
    let root = newFixture("typing_during_stream")
    writeConfiguredProvider(root)
    let chunkList = ["alpha ", "beta ", "gamma ", "delta ", "epsilon ",
                     "zeta ", "eta ", "theta ", "iota ", "kappa ",
                     "lambda ", "mu ", "nu ", "xi ", "omicron ",
                     "pi ", "rho ", "sigma ", "tau ", "upsilon ",
                     "phi ", "chi ", "psi ", "omega "]
    let chunks = %* chunkList
    let joined = chunkList.join("").strip()
    # Small content + a real usage block so the response completes cleanly
    # (no finish_reason:length retry) while the per-chunk delay keeps content
    # streaming across the whole typed burst, exercising the GUI thread's
    # live-content repaint concurrently with the input thread's redraws.
    let responses = %*[
      {"content": joined,
       "contentChunks": chunks,
       "contentChunkDelayMs": 150,
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

    # Elapsed-counter regression: once the turn clock is past 1s, keep
    # typing and scan every captured frame. The keystroke repaint and
    # the GUI tick must agree: after the bar has shown >= 1s no later
    # frame may fall back to `0` (the stale frame-model elapsed).
    var liveSecs = -1
    var waitedMs = 0
    while liveSecs < 1 and waitedMs < 10000:
      tty.drain(100)
      inc waitedMs, 100
      block clockSeen:
        for fi in countdown(tty.frames.high, 0):
          for row in tty.frames[fi].rows:
            let secs = barElapsedSecs(row)
            if secs >= 1:
              liveSecs = secs
              break clockSeen
    check liveSecs >= 1
    var staleZeroFrames: seq[string]
    since = tty.frames.len
    for ch in "world":
      rawSend(tty, $ch)
      tty.drain(60)
      for fi in since ..< tty.frames.len:
        for row in tty.frames[fi].rows:
          if barElapsedSecs(row) == 0:
            staleZeroFrames.add "frame " & $fi & ": '" & row & "'"
      since = tty.frames.len
    check staleZeroFrames.len == 0
    for hit in staleZeroFrames:
      echo "stale 0 bar frame while typing: ", hit
    tty.drain(4500)
    tty.expectAlive()
    snapshot(tty, "final")

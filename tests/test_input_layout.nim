import std/[locks, os, unittest, strutils]
import ttty/grid
import threecode/[api, types, minline, util, screen]
import harness
import minline_testutils
when defined(posix):
  import posix

## Functional tests for input-thread prompt layout during turns.
##
## These tests exercise real code paths through a PTY+pipe harness:
## production code writes to stdout (captured by pipe -> grid),
## reads from stdin (fed by PTY master with synthetic keystrokes).
## The grid is then asserted on for correct row/column placement.

proc lastRow(g: Grid, needle: string): int =
  result = -1
  for r in 0..<g.rows.len:
    if needle in rowText(g, r):
      result = r

proc captureUntil(ft: FakeTerm, needle: string): int =
  result = -1
  for _ in 0..<20:
    sleep 20
    ft.capture()
    result = lastRow(ft.grid, needle)
    if result >= 0:
      return

proc feedKeyBytes(ft: FakeTerm, keys: openArray[int]; delayMs = 0) =
  if delayMs == 0:
    var s = newStringOfCap(keys.len)
    for k in keys:
      s.add char(k)
    when defined(posix):
      let n = posix.write(ft.ptm, s[0].addr, s.len)
      doAssert n == s.len
    else:
      harness.feedKeys(ft, s)
    return
  for k in keys:
    when defined(posix):
      var ch = char(k)
      let n = posix.write(ft.ptm, addr ch, 1)
      doAssert n == 1
    else:
      harness.feedKeys(ft, $char(k))
    if delayMs > 0:
      sleep delayMs

proc waitForQueuedText(expected: string; timeoutMs = 6000): bool =
  var waited = 0
  while waited < timeoutMs:
    acquire inputStateLock
    try:
      if inputState.queuedText == expected:
        return true
    finally:
      release inputStateLock
    sleep 20
    waited += 20

proc waitForInterrupt(timeoutMs = 2000): bool =
  var waited = 0
  while waited < timeoutMs:
    if interrupted:
      return true
    sleep 20
    waited += 20

suite "input thread layout during turns":
  test "beginTurn input thread echoes typed text on prompt row":
    ## Exercise the production path, not just a hand-built escape
    ## sequence. This catches the real regression where the buffered
    ## prompt was rendered one row too high and overwrote the token bar.
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()

    let promptRow = captureUntil(ft, "❯")
    let barRow = promptRow - 1
    ft.feedKeys("h")
    let typedPromptRow = captureUntil(ft, "❯ h")
    let typedOnPromptRow =
      typedPromptRow == promptRow and "❯ h" in rowText(ft.grid, promptRow)
    let typedOnBarRow =
      barRow >= 0 and "h" in rowText(ft.grid, barRow)
    let cursorOnPromptRow = ft.grid.row == promptRow
    syncTurnFooterWrite barFooterBytes("LBL  4s", DimPromptColor)
    ft.feedKeys("i")
    let tickPromptRow = captureUntil(ft, "❯ hi")
    let tickTypedOnPromptRow =
      tickPromptRow == promptRow and "❯ hi" in rowText(ft.grid, promptRow)
    let tickTypedOnBarRow =
      barRow >= 0 and "hi" in rowText(ft.grid, barRow)
    let tickCursorOnPromptRow = ft.grid.row == promptRow

    ft.feedKeys("\r")
    sleep 100
    endTurn()

    ft.drain()
    check inputState.queuedText == "hi"
    check promptRow >= 1
    check barRow >= 0
    check typedOnPromptRow
    check not typedOnBarRow
    check cursorOnPromptRow
    check tickTypedOnPromptRow
    check not tickTypedOnBarRow
    check tickCursorOnPromptRow

  test "beginTurn input thread keeps prompt below token bar after submit":
    ## This final-grid check covers the submitted state. It is not a
    ## substitute for the half-typed assertion above, which catches the
    ## visible flicker.
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    ft.feedKeys("hi\r")
    beginTurn()
    sleep 200
    endTurn()

    ft.drain()
    check inputState.queuedText == "hi"
    check "LBL" in rowText(ft.grid, 1)
    check "❯" notin rowText(ft.grid, 1)
    check "hi" notin rowText(ft.grid, 1)
    check "❯" in rowText(ft.grid, 2)

  test "typing during turn: prompt and text on caret row":
    ## Real-world scenario: the model is streaming a response. The bar
    ## is visible. The input thread starts and paints a bright-white
    ## prompt below the bar. The user types "hi" and hits Enter.
    ## The typed text must appear on the prompt row (row 1), not on
    ## the bar row (row 0).
    var ft = newFakeTerm()
    defer: ft.close()

    # Main thread painted the bar before the turn
    paintBarPrompt("LBL  3s", DimPromptColor)

    # Input thread starts: clears, repaints bar+prompt, and parks on
    # the prompt row through the same helper used by production.
    emitScreenEvent setBarEvent("LBL  3s")
    enterPromptInput(TurnPromptColor)

    # readLineWith runs: user types "hi" and Enter
    var ed = minline.initEditor()
    ed.width = 80
    ft.feedKeys("hi\r")

    let getCh: minline.GetChProc = proc(): int =
      try: stdin.readChar().ord
      except: -1
    let writeProc: minline.WriteProc = proc(s: string) =
      stdout.write s
      stdout.flushFile
    let text = minline.readLineWith(ed, "\xe2\x9d\xaf ", getCh, writeProc,
                                     hidechars = false)

    ft.drain()
    check text == "hi"
    check "LBL" in rowText(ft.grid, 0)     # bar on row 0
    check "❯" in rowText(ft.grid, 1)       # prompt on row 1
    check "hi" in rowText(ft.grid, 1)       # typed text on row 1
    check "❯" notin rowText(ft.grid, 0)    # prompt NOT on bar row
    check "hi" notin rowText(ft.grid, 0)    # typed text NOT on bar row

  test "enterPromptInput parks buffered editor on prompt row":
    var ft = newFakeTerm()
    defer: ft.close()

    paintBarPrompt("LBL  3s", DimPromptColor)
    emitScreenEvent setBarEvent("LBL  3s")
    enterPromptInput(TurnPromptColor)

    var ed = minline.initEditor()
    ed.width = 80
    ft.feedKeys("h\r")

    let getCh: minline.GetChProc = proc(): int =
      try: stdin.readChar().ord
      except: -1
    let writeProc: minline.WriteProc = proc(s: string) =
      stdout.write s
      stdout.flushFile
    discard minline.readLineWith(ed, "\xe2\x9d\xaf ", getCh, writeProc,
                                  hidechars = false)

    ft.drain()
    check "LBL" in rowText(ft.grid, 0)
    check "❯" in rowText(ft.grid, 1)
    check "h" in rowText(ft.grid, 1)
    check "h" notin rowText(ft.grid, 0)

  test "submit during turn shows icon at end of text, not below":
    ## After pressing Enter during an active spinner, a clock/hourglass
    ## icon should appear at the end of the submitted text on the same
    ## row, not on a separate row below pushing the text up.
    var ft = newFakeTerm()
    defer: ft.close()

    paintBarPrompt("LBL  3s", DimPromptColor)
    emitScreenEvent setBarEvent("LBL  3s")
    enterPromptInput(TurnPromptColor)

    var ed = minline.initEditor()
    ed.width = 80
    ed.submitIcon = DeferredSubmitMarker
    ft.feedKeys("hi\r")

    let getCh: minline.GetChProc = proc(): int =
      try: stdin.readChar().ord
      except: -1
    let writeProc: minline.WriteProc = proc(s: string) =
      stdout.write s
      stdout.flushFile
    let text = minline.readLineWith(ed, "\xe2\x9d\xaf ", getCh, writeProc,
                                     hidechars = false)

    ft.drain()
    check text == "hi"
    # The icon must be on the same row as the text, not below
    check DeferredSubmitMarker in rowText(ft.grid, 1)   # icon on text row (row 1)
    check "hi" in rowText(ft.grid, 1)   # text also on row 1
    check DeferredSubmitMarker notin rowText(ft.grid, 2)  # icon NOT on the row below

  test "transcript append preserves live buffered editor":
    var ft = newFakeTerm()
    defer: ft.close()

    paintBarPrompt("LBL  3s", DimPromptColor)
    emitScreenEvent setBarEvent("LBL  3s")
    enterPromptInput(TurnPromptColor)

    var ed = minline.initEditor()
    ed.line = minline.Line(text: "draft", position: "draft".len)
    ed.prompt = "❯ "
    ed.contPrompt = "  "
    ed.promptW = minline.visualCols(ed.prompt)
    ed.contPromptW = minline.visualCols(ed.contPrompt)
    ed.width = 80
    stdout.write ed.redrawBytes()
    stdout.flushFile()

    inputEditor = addr(ed)
    inputThreadRunning = true
    inputState = InputState(turnActive: true)
    defer:
      inputEditor = nil
      inputThreadRunning = false
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    screenWriteTranscript:
      stdout.write "OUT\n"

    ft.drain()
    check rowText(ft.grid, 0).startsWith("OUT")
    check "LBL" in rowText(ft.grid, 1)
    check "❯ draft" in rowText(ft.grid, 2)

  test "footer frame preserves multiline live editor height":
    var ft = newFakeTerm()
    defer: ft.close()

    stdout.write "OUT\n"
    paintBarPrompt("LBL  3s", DimPromptColor)
    emitScreenEvent setBarEvent("LBL  3s")
    stdout.write "\x1b[1B"

    var ed = minline.initEditor()
    ed.line = minline.Line(text: "one\ntwo", position: "one\ntwo".len)
    ed.prompt = "❯ "
    ed.contPrompt = "  "
    ed.promptW = minline.visualCols(ed.prompt)
    ed.contPromptW = minline.visualCols(ed.contPrompt)
    ed.width = 80
    stdout.write ed.redrawBytes()
    stdout.flushFile()

    inputEditor = addr(ed)
    inputThreadRunning = true
    inputState = InputState(turnActive: true)
    defer:
      inputEditor = nil
      inputThreadRunning = false
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    screenRenderFooterFrame spinnerBarFrameBytes("⠋", "LBL  4s", "", 4)

    ft.drain()
    check rowText(ft.grid, 0).startsWith("OUT")
    check "LBL  4s" in rowText(ft.grid, 1)
    check "❯ one" in rowText(ft.grid, 2)
    check "  two" in rowText(ft.grid, 3)

  test "beginTurn input thread handles Shift-Enter as multiline":
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()
    discard captureUntil(ft, "❯")
    sleep 100
    check ed.deferSubmit
    ft.feedKeys("and othe")
    feedKeyBytes(ft, @[27, 91, 50, 55, 59, 50, 59, 49, 51, 126], 0)
    ft.feedKeys("dff\r")
    check waitForQueuedText("and othe\ndff")
    endTurn()

    ft.drain()
    check ed.line.text == "and othe\ndff"
    check inputState.autoSend
    check inputState.queuedText == "and othe\ndff"
    check "27;2;13" notin inputState.queuedText
    for r in 0..<ft.grid.rows.len:
      check "27;2;13" notin rowText(ft.grid, r)

  test "beginTurn input thread handles delayed Shift-Enter tail":
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()
    discard captureUntil(ft, "❯")
    sleep 100
    check ed.deferSubmit
    ft.feedKeys("and othe")
    feedKeyBytes(ft, @[27, 91, 50, 55, 59, 50, 59, 49, 51, 126], 10)
    ft.feedKeys("dff\r")
    check waitForQueuedText("and othe\ndff")
    endTurn()

    ft.drain()
    check ed.line.text == "and othe\ndff"
    check inputState.autoSend
    check inputState.queuedText == "and othe\ndff"
    check "27;2;13" notin inputState.queuedText
    for r in 0..<ft.grid.rows.len:
      check "27;2;13" notin rowText(ft.grid, r)

  test "beginTurn input thread handles Ctrl-C cancel":
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    interrupted = false
    defer:
      inputEditor = nil
      inputState = InputState()
      interrupted = false
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()
    discard captureUntil(ft, "❯")
    ft.feedKeys("\x03")
    check waitForInterrupt()
    endTurn()

    ft.drain()
    check interrupted
    check not inputState.autoSend

  test "beginTurn input thread handles empty Ctrl-D as exit":
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    interrupted = false
    defer:
      inputEditor = nil
      inputState = InputState()
      interrupted = false
      emitScreenEvent clearBarEvent()

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()
    discard captureUntil(ft, "❯")
    ft.feedKeys("\x04")
    check waitForInterrupt()
    endTurn()

    ft.drain()
    check inputState.cmdWasQuit
    check interrupted

  test "submitIcon + multiline: parkAtEnd leaves cursor one row below":
    # Regression: parkAtEnd used to skip \r\n after the submit icon,
    # leaving the cursor on the last input row instead of one below.
    # submitTransitionBytes assumes the cursor is one row below,
    # so the walkback overshot by one, destroying the row above
    # the bar (assistant output or gap row).
    var ed = minline.initEditor()
    ed.width = 80
    ed.submitIcon = DeferredSubmitMarker
    let d = newDriver()
    d.pushString "line1"
    d.push AltEnter
    d.pushString "line2"
    d.push AltEnter
    d.pushString "line3"
    d.push Enter
    let text = d.run(ed, "> ")
    check text == "line1\nline2\nline3"
    check ed.echoRows == 3
    # After parkAtEnd: icon on last text row, cursor at col 0 one row below.
    check d.grid.row == 3
    check d.grid.col == 0
    check "line3" in rowText(d.grid, 2)
    check DeferredSubmitMarker in rowText(d.grid, 2)
